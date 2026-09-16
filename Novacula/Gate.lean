import Novacula.Term

/-! Correctness gate (DESIGN.md 5). Novacula never judges correctness itself: it walks the
kernel terms for axioms and delegates checking to lean4checker and nanoda. -/

namespace Novacula
open Lean

def sanctionedAxioms : NameSet :=
  [``propext, ``Quot.sound, ``Classical.choice,
   `Lean.ofReduceBool, `Lean.trustCompiler].foldl (·.insert ·) {}

/-- `native_decide` mints one axiom per use, named `<decl>._native.native_decide.ax_N`, which
asserts the result of a compiled evaluation. Sanctioned by decision (DESIGN.md 5): its code is
costed like `decide`, per principle 9. -/
def isNativeAxiom (n : Name) : Bool :=
  let comps := n.components
  comps.any (· == `_native) && (match comps[comps.length - 1]? with
    | some (.str _ s) => s.startsWith "ax"
    | _ => false)

def isSanctioned (n : Name) : Bool := sanctionedAxioms.contains n || isNativeAxiom n

/-- Every constant reachable from `root` through kernel terms. -/
partial def reachable (env : Environment) (root : Name) : NameSet :=
  go root {}
where
  go (n : Name) (acc : NameSet) : NameSet :=
    if acc.contains n then acc
    else
      let acc := acc.insert n
      match env.find? n with
      | none => acc
      | some ci => (directDeps ci).foldl (fun acc d => go d acc) acc

def axiomsOf (env : Environment) (root : Name) : Array Name :=
  let names := (reachable env root).foldl (fun (acc : Array Name) n =>
    match env.find? n with
    | some (.axiomInfo _) => acc.push n
    | _ => acc) #[]
  names.qsort (·.toString < ·.toString)

inductive CheckerResult where
  | pass | fail (msg : String) | notConfigured
  deriving Repr, BEq

def CheckerResult.toJson : CheckerResult → Json
  | .pass => "pass"
  | .fail m => Json.mkObj [("fail", m)]
  | .notConfigured => "not-configured"

/-- Run an external checker if its executable path is configured, e.g. `LEAN4CHECKER=/path/to/exe`.
`ponytail:` invocation only, no output parsing beyond the exit code; refine when a checker needs it. -/
def runChecker (envVar : String) (mod : Name) : IO CheckerResult := do
  match (← IO.getEnv envVar) with
  | none => return .notConfigured
  | some exe =>
    let out ← IO.Process.output { cmd := exe, args := #[mod.toString] }
    if out.exitCode == 0 then return .pass
    else return .fail (out.stderr.take 500).toString

structure GateResult where
  axioms : Array Name
  unsanctioned : Array Name
  lean4checker : CheckerResult
  nanoda : CheckerResult

def GateResult.ok (g : GateResult) : Bool :=
  g.unsanctioned.isEmpty && g.lean4checker == .pass && g.nanoda == .pass

def GateResult.toJson (g : GateResult) : Json := Json.mkObj
  [("axioms", Json.arr (g.axioms.map (Json.str ·.toString))),
   ("unsanctioned", Json.arr (g.unsanctioned.map (Json.str ·.toString))),
   ("lean4checker", g.lean4checker.toJson),
   ("nanoda", g.nanoda.toJson),
   ("ok", g.ok)]

def gate (env : Environment) (mod : Name) (root : Name) : IO GateResult := do
  let axioms := axiomsOf env root
  return {
    axioms
    unsanctioned := axioms.filter (!isSanctioned ·)
    lean4checker := ← runChecker "LEAN4CHECKER" mod
    nanoda := ← runChecker "NANODA" mod }

end Novacula
