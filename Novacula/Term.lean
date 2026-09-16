import Novacula.Compat

/-! Term metrics: everything computable from a kernel `Expr`, for local and compiled
declarations alike (DESIGN.md 7.1). No source text, no runtime measurement. -/

namespace Novacula
open Lean

structure TermMetrics where
  /-- Distinct nodes of the term seen as a DAG (shared subterms counted once). -/
  size : Nat := 0
  /-- Distinct constants the declaration refers to, type and value together. -/
  consts : Nat := 0
  /-- Deepest chain of binders (lambda, forall, let). -/
  binderDepth : Nat := 0
  /-- Distinct case splits: recursors, `casesOn`, matchers. -/
  branches : Nat := 0
  deriving Repr, Inhabited, BEq

instance : ToJson TermMetrics where
  toJson m := Json.mkObj
    [("size", m.size), ("consts", m.consts),
     ("binderDepth", m.binderDepth), ("branches", m.branches)]

/-- Does this constant introduce a case split? -/
def isBranchConst (env : Environment) (n : Name) : Bool :=
  match env.find? n with
  | some (.recInfo _) => true
  | _ =>
    if Lean.Meta.isMatcherCore env n then true
    else match n with
      | .str _ s =>
        s.endsWith "casesOn" || s.endsWith "casesAuxOn" || s.endsWith "recOn"
          || s.endsWith "brecOn" || s.endsWith "binductionOn"
      | _ => false

private structure St where
  seen : Std.HashSet ExprStructEq := {}
  consts : NameSet := {}
  size : Nat := 0
  branches : Nat := 0
  binderDepth : Nat := 0

private partial def visit (env : Environment) (e : Expr) (depth : Nat) : StateM St Unit := do
  if (← get).seen.contains ⟨e⟩ then return
  modify fun s => { s with
    seen := s.seen.insert ⟨e⟩
    size := s.size + 1
    binderDepth := max s.binderDepth depth }
  match e with
  | .const n _ =>
    modify fun s => { s with
      consts := s.consts.insert n
      branches := if isBranchConst env n then s.branches + 1 else s.branches }
  | .app f a => visit env f depth; visit env a depth
  | .lam _ t b _ | .forallE _ t b _ => visit env t depth; visit env b (depth + 1)
  | .letE _ t v b _ => visit env t depth; visit env v depth; visit env b (depth + 1)
  | .mdata _ b => visit env b depth
  | .proj _ _ b => visit env b depth
  | _ => pure ()

/-- Metrics of one declaration's own term, its dependencies excluded. -/
def termMetrics (env : Environment) (ci : ConstantInfo) : TermMetrics :=
  let run := do
    visit env ci.type 0
    match ci.value? (allowOpaque := true) with
    | some v => visit env v 0
    | none => pure ()
  let st := (run.run {}).2
  { size := st.size, consts := st.consts.size
    binderDepth := st.binderDepth, branches := st.branches }

/-- Constants a declaration refers to, type and value together. -/
def directDeps (ci : ConstantInfo) : NameSet :=
  let add (s : NameSet) (e : Expr) := e.getUsedConstants.foldl (·.insert ·) s
  let s := add {} ci.type
  match ci.value? (allowOpaque := true) with
  | some v => add s v
  | none => s

end Novacula
