import Plan

namespace Refinement

-- Knowing the exact successor is enough to establish positivity as well.
-- Claim 1 need not appear as a child: this is implication, not index coverage.
theorem valid : Plan.Relation := by
  intro next child
  refine ⟨child.1, ?_, True.intro⟩
  intro n
  rw [child.1 n]
  exact Nat.zero_lt_succ n

end Refinement
