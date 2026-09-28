import Novacula

open Lean Novacula

structure Report where
  decl : Name
  gate : GateResult
  metrics : TermMetrics
  deps : Nat
  cost : Option Json
  params : CostParams

def Report.toJson (r : Report) : Json := Json.mkObj
  [("leanVersion", Lean.versionString),
   ("params", r.params.toJson),
   ("decl", r.decl.toString),
   ("gate", r.gate.toJson),
   ("directDeps", r.deps),
   ("term", ToJson.toJson r.metrics),
   ("cost", r.cost.getD Json.null)]

/-- Score one declaration. The cost is reported only when the gate passes: an unchecked proof is
rejected, never scored. -/
def analyze (params : CostParams) (mod : Name) (decl : Name) : IO Report := do
  let env ← loadEnv (#[mod] ++ params.corpus)
  let some ci := env.find? decl | throw (IO.userError s!"unknown declaration: {decl}")
  let gate := gate env decl (← runCheckers env mod #[decl])
  let cost ← if gate.ok then do
      let g ← prepare env #[decl] params
      pure (some ((g.cost #[decl]).toJson g))
    else pure none
  return { decl, gate, metrics := termMetrics env ci, deps := (directDeps ci).size, cost, params }

/-- Analyze a fixture declaration, failing loudly if it is missing. -/
def fixture (env : Environment) (n : Name) : IO (TermMetrics × Array Name) := do
  let some ci := env.find? n | throw (IO.userError s!"missing fixture: {n}")
  return (termMetrics env ci, (axiomsOf env n).filter (!isSanctioned ·))

def selftest : IO UInt32 := do
  let env ← loadEnv #[`Fixtures]
  let mut failures := 0
  let check (name : String) (ok : Bool) : IO Bool := do
    IO.println s!"{if ok then "ok  " else "FAIL"} {name}"
    return ok
  let (_, badSorry) ← fixture env `Fixtures.withSorry
  let (_, badAxiom) ← fixture env `Fixtures.viaCustomAxiom
  let (_, cleanAx) ← fixture env `Fixtures.addComm
  let (small, _) ← fixture env `Fixtures.decSmall
  let (big, _) ← fixture env `Fixtures.decBig
  let (native, natAx) ← fixture env `Fixtures.natively
  let (flat, _) ← fixture env `Fixtures.noBranch
  let (branchy, _) ← fixture env `Fixtures.branchy
  let costs := #[`Fixtures.citesFamous, `Fixtures.citesLocal, `Fixtures.twoCites,
    `Fixtures.usesA, `Fixtures.usesB, `Fixtures.decSmall, `Fixtures.decBig]
  let g ← prepare env costs
  let cost (ns : Array Name) := (g.cost ns).total
  let g' ← prepare env costs
  let results := #[
    (← check "sorry is unsanctioned" (badSorry.any (· == ``sorryAx))),
    (← check "custom axiom is unsanctioned" (badAxiom.any (· == `Fixtures.myAxiom))),
    (← check "plain proof passes the axiom gate" cleanAx.isEmpty),
    (← check "native_decide passes the axiom gate" natAx.isEmpty),
    (← check "native_decide is costed" (native.size > 0)),
    (← check "range size does not change the cost" (small == big)),
    (← check "range size does not change the recursive cost"
      (cost #[`Fixtures.decSmall] == cost #[`Fixtures.decBig])),
    (← check "case split shows up as a branch" (branchy.branches > flat.branches)),
    (← check "famous citation costs less than a local reproof"
      (cost #[`Fixtures.citesFamous] < cost #[`Fixtures.citesLocal])),
    (← check "citing two results where one suffices costs more"
      (cost #[`Fixtures.citesFamous] < cost #[`Fixtures.twoCites])),
    (← check "a shared dependency is charged once"
      (cost #[`Fixtures.usesA, `Fixtures.usesB]
        < cost #[`Fixtures.usesA] + cost #[`Fixtures.usesB])),
    (← check "cached raw metrics give the same cost"
      (costs.all fun n => cost #[n] == (g'.cost #[n]).total)),
    (← check "two runs give identical output"
      ((← analyze {} `Fixtures `Fixtures.branchy).toJson.compress
        == (← analyze {} `Fixtures `Fixtures.branchy).toJson.compress))]
  for r in results do
    unless r do failures := failures + 1
  if failures == 0 then IO.println "all checks passed" else IO.println s!"{failures} check(s) failed"
  return if failures == 0 then 0 else 1

def csvHeader : String :=
  "date,novaculaRev,module,decl,gateOk,axiomsOk,size,consts,binderDepth,branches,directDeps,leanVersion,cost"

/-- Read a targets file: one `Module Decl` per line, `#` comments and blank lines ignored.
`Module *` stands for every theorem declared in `Module` and its submodules. -/
def readTargets (path : System.FilePath) : IO (Array (Name × String)) := do
  let mut targets := #[]
  for line in (← IO.FS.lines path) do
    let s := line.trimAscii.toString
    if s.isEmpty || s.startsWith "#" then continue
    match (s.splitOn " ").filter (!·.isEmpty) with
    | [m, d] => targets := targets.push (m.toName, d)
    | _ => throw (IO.userError s!"bad target line: {s}")
  return targets

/-- CSV rows for the targets of one module: one per declaration and, when there are several, a
`*` row scoring them as one set. The date comes from the caller: the tool never reads a clock,
so a rerun of an old commit reproduces old rows exactly. -/
def csvModule (params : CostParams) (date rev : String) (mod : Name) (specs : Array String) : IO UInt32 := do
  let env ← loadEnv (#[mod] ++ params.corpus)
  let mut decls := #[]
  let mut failures := 0
  for s in specs do
    if s == "*" then decls := decls ++ theoremsUnder env mod
    else if env.contains s.toName then decls := decls.push s.toName
    else
      IO.eprintln s!"missing declaration: {mod} {s}"
      failures := failures + 1
  if decls.isEmpty then return failures
  let checks ← runCheckers env mod decls
  let g ← prepare env decls params
  let gates := decls.map (gate env · checks)
  let costCol (ok : Bool) (roots : Array Name) :=
    if ok then toString (roundNat (g.cost roots).total) else ""
  for (d, gt) in decls.zip gates do
    let some ci := env.find? d | continue
    let t := termMetrics env ci
    IO.println s!"{date},{rev},{mod},{d},{gt.ok},{gt.unsanctioned.isEmpty},{t.size},{t.consts},{t.binderDepth},{t.branches},{(directDeps ci).size},{Lean.versionString},{costCol gt.ok #[d]}"
  if decls.size > 1 then
    let ok := gates.all (·.ok)
    IO.println s!"{date},{rev},{mod},*,{ok},{gates.all (·.unsanctioned.isEmpty)},,,,,,{Lean.versionString},{costCol ok decls}"
  return failures

def csvRun (params : CostParams) (date rev : String) (path : System.FilePath) : IO UInt32 := do
  let targets ← readTargets path
  let mut failures := 0
  for mod in (targets.map (·.1)).toList.eraseDups do
    let specs := (targets.filter (·.1 == mod)).map (·.2)
    failures := failures + (← csvModule params date rev mod specs)
  return if failures == 0 then 0 else 1

def usage : String :=
  "usage:\n  novacula score <Module> <Decl>\n  novacula selftest\n  novacula csv <date> <novacula-rev> <targets-file>\n  novacula csv-header\n  novacula chart <history.csv> <out.svg> [metric]\n  novacula badge <history.csv> <out.svg>"

def main (args : List String) : IO UInt32 := do
  match args with
  | ["score", mod, decl] =>
    let r ← analyze (← CostParams.fromEnv) mod.toName decl.toName
    IO.println (r.toJson.pretty)
    return if r.gate.ok then 0 else 1
  | ["selftest"] => selftest
  | ["csv", date, rev, path] => csvRun (← CostParams.fromEnv) date rev path
  | ["csv-header"] => IO.println csvHeader; return 0
  | ["chart", csv, svg] => chartCmd csv svg "size"
  | ["chart", csv, svg, metric] => chartCmd csv svg metric
  | ["badge", csv, svg] => badgeCmd csv svg
  | _ => IO.eprintln usage; return 2
