import Novacula.Graph

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

def axiomsOf (env : Environment) (root : Name) : Array Name :=
  let names := (closure env #[root]).fold (fun (acc : Array Name) n _ =>
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

/-- Run an external checker once per argument list, if its executable is configured, e.g.
`LEAN4CHECKER=/path/to/exe`. Passes only if every run exits 0. -/
def runChecker (envVar : String) (runs : Array (Array String)) : IO CheckerResult := do
  let some exe ← IO.getEnv envVar | return .notConfigured
  for args in runs do
    let out ← IO.Process.output { cmd := exe, args }
    if out.exitCode != 0 then
      return .fail s!"{args}: {(out.stderr ++ out.stdout).take 500}"
  return .pass

structure Checkers where
  lean4checker : CheckerResult
  nanoda : CheckerResult

/-- Run both checkers for the targets of one module. lean4checker replays every module of the
scored package, `exe <Module>`. nanoda is called as `exe <Module> <Decl>...`, a wrapper that
exports those declarations with their dependencies (lean4export) and checks the export. -/
def runCheckers (env : Environment) (mod : Name) (targets : Array Name) : IO Checkers := do
  let pkgMods := (← localModules env).toArray
  return {
    lean4checker := ← runChecker "LEAN4CHECKER" (pkgMods.map fun m => #[m.toString])
    nanoda := ← runChecker "NANODA" #[#[mod.toString] ++ targets.map (·.toString)] }

structure GateResult where
  axioms : Array Name
  unsanctioned : Array Name
  checkers : Checkers

def GateResult.ok (g : GateResult) : Bool :=
  g.unsanctioned.isEmpty && g.checkers.lean4checker == .pass && g.checkers.nanoda == .pass

def GateResult.toJson (g : GateResult) : Json := Json.mkObj
  [("axioms", Json.arr (g.axioms.map (Json.str ·.toString))),
   ("unsanctioned", Json.arr (g.unsanctioned.map (Json.str ·.toString))),
   ("lean4checker", g.checkers.lean4checker.toJson),
   ("nanoda", g.checkers.nanoda.toJson),
   ("ok", g.ok)]

def gate (env : Environment) (root : Name) (checkers : Checkers) : GateResult :=
  let axioms := axiomsOf env root
  { axioms, unsanctioned := axioms.filter (!isSanctioned ·), checkers }

end Novacula
