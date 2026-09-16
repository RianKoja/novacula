/-! Toy fixtures for the selftest (DESIGN.md 11). No Mathlib, must stay fast to build. -/

namespace Fixtures

theorem addComm (a b : Nat) : a + b = b + a := Nat.add_comm a b

theorem withSorry (a b : Nat) : a + b = b + a := by sorry

axiom myAxiom (a b : Nat) : a + b = b + a

theorem viaCustomAxiom (a b : Nat) : a + b = b + a := myAxiom a b

/- Same check over a range 10 times bigger: the code is the same, so the cost must be too. -/
set_option maxRecDepth 100000 in
theorem decSmall : ∀ n, n < 20 → n + 0 = n := by decide

set_option maxRecDepth 100000 in
theorem decBig : ∀ n, n < 200 → n + 0 = n := by decide

theorem natively : ∀ n, n < 200 → n + 0 = n := by native_decide

theorem noBranch (a : Nat) : a + 0 = a := rfl

theorem branchy (n : Nat) : n = 0 ∨ 0 < n := by
  cases n with
  | zero => exact Or.inl rfl
  | succ k => exact Or.inr (Nat.succ_pos k)

end Fixtures
