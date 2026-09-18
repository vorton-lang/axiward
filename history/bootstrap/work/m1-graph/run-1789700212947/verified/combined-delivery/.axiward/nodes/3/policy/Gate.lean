import Axiward.Spec
import Axiward.Queue
import Axiward.Proofs

namespace Gate
universe u
theorem accepted (α : Type u) (n : Nat) :
  Axiward.Q0.Created n (Axiward.Queue.empty α n).capacity (Axiward.Queue.empty α n).items ∧
  True :=
  ⟨Axiward.created α n, True.intro⟩
end Gate
