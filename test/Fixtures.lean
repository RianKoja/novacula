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


/- Citing a famous lemma costs less than reproving it locally. -/
theorem citesFamous (a b : Nat) : a + b = b + a := Nat.add_comm a b

theorem myAddComm : ∀ n m : Nat, n + m = m + n
  | n, 0 => (Nat.zero_add n).symm
  | n, m + 1 => by rw [Nat.add_succ, myAddComm n m, Nat.succ_add]

theorem citesLocal (a b : Nat) : a + b = b + a := myAddComm a b

/- A citation that is not needed still costs. -/
theorem twoCites (a b : Nat) : a + b = b + a :=
  have _unused := Nat.mul_comm a b
  Nat.add_comm a b

/- Two results sharing a local lemma: scored together, the lemma is charged once. -/
theorem shared (n : Nat) : n * 1 + 0 = n := by rw [Nat.mul_one, Nat.add_zero]

theorem usesA (n : Nat) : n * 1 + 0 + 0 = n := (Nat.add_zero _).trans (shared n)

theorem usesB (n : Nat) : 0 + (n * 1 + 0) = n := (Nat.zero_add _).trans (shared n)

end Fixtures
