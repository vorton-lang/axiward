import Plan
import Refinement
namespace Gate
theorem accepted (facts : Nat → Prop) :
  (∀ child ∈ Plan.children, Holds child facts) → Holds Plan.parent facts :=
  Refinement.valid facts
end Gate
