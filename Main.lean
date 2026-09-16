import Novacula

open Lean Novacula

structure Report where
  decl : Name
  gate : GateResult
  metrics : TermMetrics
  deps : Nat

def Report.toJson (r : Report) : Json := Json.mkObj
  [("leanVersion", Lean.versionString),
   ("decl", r.decl.toString),
   ("gate", r.gate.toJson),
   ("directDeps", r.deps),
   ("term", ToJson.toJson r.metrics)]

def analyze (mod : Name) (decl : Name) : IO Report := do
  let env ← loadEnv #[mod]
  let some ci := env.find? decl | throw (IO.userError s!"unknown declaration: {decl}")
  return { decl, gate := ← gate env mod decl
           metrics := termMetrics env ci, deps := (directDeps ci).size }

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
  let results := #[
    (← check "sorry is unsanctioned" (badSorry.any (· == ``sorryAx))),
    (← check "custom axiom is unsanctioned" (badAxiom.any (· == `Fixtures.myAxiom))),
    (← check "plain proof passes the axiom gate" cleanAx.isEmpty),
    (← check "native_decide passes the axiom gate" natAx.isEmpty),
    (← check "native_decide is costed" (native.size > 0)),
    (← check "range size does not change the cost" (small == big)),
    (← check "case split shows up as a branch" (branchy.branches > flat.branches)),
    (← check "two runs give identical output"
      ((← analyze `Fixtures `Fixtures.branchy).toJson.compress
        == (← analyze `Fixtures `Fixtures.branchy).toJson.compress))]
  for r in results do
    unless r do failures := failures + 1
  if failures == 0 then IO.println "all checks passed" else IO.println s!"{failures} check(s) failed"
  return if failures == 0 then 0 else 1

def csvHeader : String :=
  "date,novaculaRev,module,decl,gateOk,axiomsOk,size,consts,binderDepth,branches,directDeps,leanVersion"

/-- Read a targets file: one `Module Decl` per line, `#` comments and blank lines ignored. -/
def readTargets (path : System.FilePath) : IO (Array (Name × Name)) := do
  let mut targets := #[]
  for line in (← IO.FS.lines path) do
    let s := line.trimAscii.toString
    if s.isEmpty || s.startsWith "#" then continue
    match (s.splitOn " ").filter (!·.isEmpty) with
    | [m, d] => targets := targets.push (m.toName, d.toName)
    | _ => throw (IO.userError s!"bad target line: {s}")
  return targets

/-- One CSV row per target. The date comes from the caller: the tool never reads a clock,
so a rerun of an old commit reproduces old rows exactly. -/
def csvRun (date rev : String) (path : System.FilePath) : IO UInt32 := do
  let targets ← readTargets path
  let mut failures := 0
  for mod in (targets.map (·.1)).toList.eraseDups do
    let env ← loadEnv #[mod]
    for (m, decl) in targets do
      if m != mod then continue
      match env.find? decl with
      | none =>
        IO.eprintln s!"missing declaration: {mod} {decl}"
        failures := failures + 1
      | some ci =>
        let g ← gate env mod decl
        let t := termMetrics env ci
        IO.println s!"{date},{rev},{mod},{decl},{g.ok},{g.unsanctioned.isEmpty},{t.size},{t.consts},{t.binderDepth},{t.branches},{(directDeps ci).size},{Lean.versionString}"
  return if failures == 0 then 0 else 1

def usage : String :=
  "usage:\n  novacula score <Module> <Decl>\n  novacula selftest\n  novacula csv <date> <novacula-rev> <targets-file>\n  novacula csv-header\n  novacula chart <history.csv> <out.svg> [metric]"

def main (args : List String) : IO UInt32 := do
  match args with
  | ["score", mod, decl] =>
    let r ← analyze mod.toName decl.toName
    IO.println (r.toJson.pretty)
    return if r.gate.unsanctioned.isEmpty then 0 else 1
  | ["selftest"] => selftest
  | ["csv", date, rev, path] => csvRun date rev path
  | ["csv-header"] => IO.println csvHeader; return 0
  | ["chart", csv, svg] => chartCmd csv svg "size"
  | ["chart", csv, svg, metric] => chartCmd csv svg metric
  | _ => IO.eprintln usage; return 2
