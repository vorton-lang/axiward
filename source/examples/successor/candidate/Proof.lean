import Specification
import Implementation

theorem implementation_correct : Successor.Required Implementation.next := by
  intro n
  rfl

theorem implementation_positive : Successor.Positive Implementation.next := by
  intro n
  exact Nat.zero_lt_succ n
