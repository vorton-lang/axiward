import Plan

namespace Refinement

-- Universal over the facts: no queue implementation is assumed to be correct.
theorem valid (facts : Nat → Prop) :
    (∀ child ∈ Plan.children, Holds child facts) → Holds Plan.parent facts := by
  simp_all [Plan.children, Plan.parent, Holds, and_assoc]

end Refinement
