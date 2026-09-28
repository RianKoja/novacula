import Std.Data.TreeSet
import Novacula.Term

/-! The recursive cost (DESIGN.md 4.2), computed in three phases:

1. raw metrics of every declaration reachable from the targets, read from the cache when the
   module's olean and the Lean version are unchanged (DESIGN.md 9);
2. fame of every reached declaration, measured on the loaded corpus (DESIGN.md 6);
3. the fame-weighted walk, which charges each declaration once, at the largest weight it is
   reached with.

Fame is applied only after every raw value it discounts is known. -/

namespace Novacula
open Lean

/-- Cost parameters until weight profiles land (DESIGN.md 7.3). Echoed in every report. -/
structure CostParams where
  /-- Modules imported only to measure fame on, e.g. `Mathlib`, so that fame does not depend on
  which part of a library the targets happen to import. -/
  corpus : Array Name := #[]
  /-- Users outside the declaring module at which fame reaches one half. -/
  famePivot : Nat := 4
  /-- Steepness of the log-sigmoid: fame is `n^k / (n^k + pivot^k)` for `n` users. -/
  fameExp : Nat := 1
  /-- Weights below `1 / cutoffInv` are neither charged nor expanded. -/
  cutoffInv : Nat := 1000000
  deriving Inhabited

def CostParams.toJson (p : CostParams) : Json :=
  Json.mkObj [("corpus", Json.arr (p.corpus.map (Json.str ·.toString))),
    ("famePivot", p.famePivot), ("fameExp", p.fameExp), ("cutoffInv", p.cutoffInv)]

/-- Parameters from `NOVACULA_CORPUS` (space separated modules), `NOVACULA_FAME_PIVOT` and
`NOVACULA_FAME_EXP`. `ponytail:` environment variables stand in for profile files (DESIGN.md 7.3). -/
def CostParams.fromEnv : IO CostParams := do
  let nat (v : String) (d : Nat) : IO Nat := do
    return ((← IO.getEnv v).bind (·.toNat?)).getD d
  let corpus := ((← IO.getEnv "NOVACULA_CORPUS").getD "").splitOn " " |>.filter (!·.isEmpty)
  return { corpus := corpus.toArray.map (·.toName)
           famePivot := ← nat "NOVACULA_FAME_PIVOT" 4, fameExp := ← nat "NOVACULA_FAME_EXP" 1 }

/-- Edges of the walk: constants in the type and value, plus the constructors of an inductive
type, since understanding a type means knowing how its values are built. -/
def edges (ci : ConstantInfo) : Array Name :=
  let s := directDeps ci
  let s := match ci with
    | .inductInfo v => v.ctors.foldl (fun (acc : NameSet) c => acc.insert c) s
    | _ => s
  s.toArray

/-- Every constant reachable from `roots`, with its edges. A worklist rather than recursion, so
deep developments do not overflow the stack. -/
def closure (env : Environment) (roots : Array Name) : Std.HashMap Name (Array Name) := Id.run do
  let mut seen : Std.HashMap Name (Array Name) := {}
  let mut todo := roots
  repeat
    let some n := todo.back? | break
    todo := todo.pop
    if seen.contains n then continue
    let es := (env.find? n).map edges |>.getD #[]
    seen := seen.insert n es
    todo := todo ++ es.filter (!seen.contains ·)
  return seen

/-! ## Phase 1: raw metrics, cached per module -/

/-- Bump whenever `termMetrics` changes, so stale cache entries are never read. -/
def metricsVersion : Nat := 1

def cacheDir : IO System.FilePath := do
  let base := (← IO.getEnv "NOVACULA_CACHE").getD ".lake/novacula-cache"
  return System.FilePath.mk base / Lean.versionString / s!"metrics-v{metricsVersion}"

/-- Cache key of a module. Toolchain modules are fixed by the Lean version; Lake builds carry an
`.olean.hash`. A module with neither is recomputed every time. -/
def moduleKey? (mod : Name) : IO (Option String) := do
  let olean ← oleanOf mod
  let hashFile : System.FilePath := olean.toString ++ ".hash"
  if ← hashFile.pathExists then
    return some (← IO.FS.readFile hashFile).trimAscii.toString
  let core := (← findSysroot) / "lib" / "lean"
  return if olean.toString.startsWith core.toString then some "core" else none

private def parseCache (s : String) (n : Nat) : Option (Array TermMetrics) := do
  let .arr rows ← (Json.parse s).toOption | none
  guard (rows.size == n)
  rows.mapM fun
    | .arr xs => do TermMetrics.ofArray? (← xs.mapM (·.getNat?.toOption))
    | _ => none

/-- Raw metrics of every constant a module declares, in olean order. The cache stores only raw
metrics, never costs, so a change of fame or parameters never invalidates it. -/
def moduleMetrics (env : Environment) (mod : Name) (consts : Array Name) :
    IO (Array TermMetrics) := do
  let compute := fun (_ : Unit) => consts.map fun n => (env.find? n).map (termMetrics env) |>.getD {}
  let some key ← moduleKey? mod | return compute ()
  let dir ← cacheDir
  let file := dir / s!"{mod}.{key}.json"
  if ← file.pathExists then
    if let some ms := parseCache (← IO.FS.readFile file) consts.size then return ms
  let ms := compute ()
  IO.FS.createDirAll dir
  let tmp : System.FilePath := file.toString ++ ".tmp"
  IO.FS.writeFile tmp (Json.arr (ms.map fun m => Json.arr (m.toArray.map toJson))).compress
  IO.FS.rename tmp file
  return ms

/-- Phase 1. Axioms are the foundation, not proof work, so they cost nothing (DESIGN.md 4.3). -/
def rawMetrics (env : Environment) (reached : Std.HashMap Name (Array Name)) :
    IO (Std.HashMap Name TermMetrics) := do
  let mut raw := {}
  for (mod, consts) in modulesWithConsts env do
    unless consts.any reached.contains do continue
    for (n, m) in consts.zip (← moduleMetrics env mod consts) do
      if reached.contains n then
        raw := raw.insert n (if env.find? n matches some (.axiomInfo _) then {} else m)
  return raw

/-! ## Phase 2: fame -/

/-- The declaration a generated auxiliary belongs to: `Foo.proof_1`, `Foo.match_2`, `Foo._f` and
private helpers of `Foo` all belong to `Foo`. Auxiliaries never earn fame of their own (DESIGN.md
6, caps) but share their owner's: they are part of its proof, and a famous declaration's proof is
not charged, so neither are its pieces. -/
partial def owner (n : Name) : Name :=
  go (privateToUserName n)
where
  go : Name → Name
    | n@(.str p s) => if (Name.str .anonymous s).isInternalDetail && !p.isAnonymous then go p else n
    | .num p _ => go p
    | n => n

/-- Users of each owner in `mods`, see `fameOf`. -/
private def usersIn (env : Environment) (ownerOf : Std.HashMap Name Name)
    (mods : Array ((Name × Array Name) × Nat)) : Std.HashMap Name Nat := Id.run do
  let mut users : Std.HashMap Name Nat := {}
  for ((_, consts), idx) in mods do
    -- Automation hides most uses in auxiliaries (`_proof_1`, `omega_nat_1`, `_auxLemma`), so they
    -- count for their owner. An owner and its auxiliaries share a module: dedupe per module.
    let mut pairs : Std.HashSet (Name × Name) := {}
    for u in consts do
      let some ci := env.find? u | continue
      let ou := owner u
      for d in directDeps ci do
        if let some o := ownerOf[d]? then
          if (env.getModuleIdxFor? d).map (·.toNat) != some idx then pairs := pairs.insert (ou, o)
    for (_, o) in pairs do
      users := users.insert o (users.getD o 0 + 1)
  return users

/-- Fame of each reached declaration, measured on the loaded corpus. A user of `d` is a distinct
declaration outside the scored package and outside `d`'s own module, so a package cannot make
its own lemmas famous. Uses by and of auxiliaries count for their owner. `n` users give fame
`n^k / (n^k + pivot^k)`, a log-sigmoid in `n`. Declarations of the scored package have fame 0.
The corpus scan runs in parallel over modules; counts are sums, so the result does not depend
on scheduling.
`ponytail:` corpus is whatever the targets and `CostParams.corpus` import; a frozen snapshot
with repository stars replaces it once DESIGN.md 6 is built. -/
def fameOf (env : Environment) (locals : NameSet) (p : CostParams)
    (reached : Std.HashMap Name (Array Name)) : Std.HashMap Name Float := Id.run do
  let ownerOf : Std.HashMap Name Name := reached.fold (fun m d _ => m.insert d (owner d)) {}
  let mods := (modulesWithConsts env).zipIdx.filter (!locals.contains ·.1.1)
  let chunk := mods.size / 64 + 1
  let tasks := (List.range 64).map fun i =>
    Task.spawn fun _ => usersIn env ownerOf (mods.extract (i * chunk) ((i + 1) * chunk))
  let mut users : Std.HashMap Name Nat := {}
  for t in tasks do
    for (o, n) in t.get do
      users := users.insert o (users.getD o 0 + n)
  -- Integer powers by multiplication: exact up to 2^53 and independent of libm.
  let pow (x : Float) : Float := (List.replicate p.fameExp x).foldl (· * ·) 1
  let pivot := pow p.famePivot.toFloat
  let mut fame := {}
  for (d, o) in ownerOf do
    let local_ := ((moduleOf? env d).map locals.contains).getD true
    if local_ then continue
    let n := pow (users.getD o 0).toFloat
    if n > 0 then fame := fame.insert d (n / (n + pivot))
  return fame

/-! ## Phase 3: the walk -/

/-- Everything the walk needs, computed once for a set of targets. -/
structure Graph where
  edges : Std.HashMap Name (Array Name)
  raw : Std.HashMap Name TermMetrics
  fame : Std.HashMap Name Float
  params : CostParams

/-- Modules of the scored project: those built into its own `.lake/build`, as opposed to the
toolchain and dependencies under `.lake/packages`. One project can have several roots. -/
def localModules (env : Environment) : IO NameSet := do
  let core := ((← findSysroot) / "lib" / "lean").toString
  env.header.moduleNames.foldlM (init := {}) fun s m => do
    let p := (← oleanOf m).toString
    return if p.startsWith core || (p.splitOn "/.lake/packages/").length > 1 then s else s.insert m

/-- Phases 1 and 2 for every declaration reachable from `targets`. -/
def prepare (env : Environment) (targets : Array Name) (params : CostParams := {}) :
    IO Graph := do
  let edges := closure env targets
  let raw ← rawMetrics env edges
  return { edges, raw, fame := fameOf env (← localModules env) params edges, params }

structure Cost where
  total : Float
  /-- Declarations charged, i.e. reached with weight above the cutoff. -/
  charged : Nat
  /-- Largest contributors, largest first. -/
  top : Array (Float × Name)

def roundNat (x : Float) : Nat := x.round.toUInt64.toNat

def Cost.toJson (c : Cost) (g : Graph) : Json := Json.mkObj
  [("cost", roundNat c.total), ("charged", c.charged),
   ("top", Json.arr (c.top.map fun (x, n) => Json.mkObj
     [("decl", n.toString), ("charge", roundNat x),
      ("famePermille", roundNat (1000 * g.fame.getD n 0))]))]

/-- Larger weight first, ties by name, so the walk order and the float sums are deterministic. -/
private def byWeight (a b : Float × Name) : Ordering :=
  if a.1 > b.1 then .lt else if a.1 < b.1 then .gt else a.2.cmp b.2

/-- Phase 3 (DESIGN.md 4.2). `w(root) = 1`, `w(v) = max over edges u → v of w(u) · (1 − fame u)`,
and each reached `d` is charged `w(d) · (fame(d) · cite(d) + (1 − fame(d)) · body(d))` once.
`body` is the declaration's DAG term size, `cite` its statement's. The max-product path is a
Dijkstra walk: weights only shrink along edges. Several roots score them as one set, sharing
what they have in common. -/
def Graph.cost (g : Graph) (roots : Array Name) (topN := 10) : Cost := Id.run do
  let cutoff := 1 / g.params.cutoffInv.toFloat
  let mut best : Std.HashMap Name Float := roots.foldl (·.insert · 1) {}
  let mut queue : Std.TreeSet (Float × Name) byWeight := roots.foldl (fun q r => q.insert (1, r)) {}
  let mut done : Std.HashSet Name := {}
  let mut total := 0.0
  let mut charges : Array (Float × Name) := #[]
  repeat
    let some (w, u) := queue.min? | break
    queue := queue.erase (w, u)
    if done.contains u then continue
    done := done.insert u
    let f := g.fame.getD u 0
    let m := g.raw.getD u {}
    let c := w * (f * m.typeSize.toFloat + (1 - f) * m.size.toFloat)
    total := total + c
    charges := charges.push (c, u)
    let w' := w * (1 - f)
    if w' < cutoff then continue
    for v in g.edges.getD u #[] do
      if w' > best.getD v 0 then
        best := best.insert v w'
        queue := queue.insert (w', v)
  let top := (charges.qsort (byWeight · · == .lt)).extract 0 topN
  return { total, charged := done.size, top }

/-- User-written theorems declared in `mod` or its submodules: the "all results" selection. -/
def theoremsUnder (env : Environment) (mod : Name) : Array Name := Id.run do
  let mut out := #[]
  for (m, consts) in modulesWithConsts env do
    unless mod.isPrefixOf m do continue
    for n in consts do
      if !n.isInternalDetail && hasDeclRange env n && env.find? n matches some (.thmInfo _) then
        out := out.push n
  return out.qsort Name.lt

end Novacula
