import Axiward.Spec
import Axiward.Queue
import Axiward.Proofs

namespace Gate
universe u
theorem accepted (α : Type u) (n : Nat) :
  (∀ q : Axiward.Queue α n, Axiward.Q0.DequeueSome q.items q.dequeue.1 q.dequeue.2.items) ∧
  (∀ q : Axiward.Queue α n, Axiward.Q0.DequeueEmpty q.items q.dequeue.1 q.dequeue.2.items) ∧
  (∀ q : Axiward.Queue α n, Axiward.Q0.Measured n q.capacity q.length q.items) ∧
  True :=
  ⟨Axiward.dequeue_some, ⟨Axiward.dequeue_empty, ⟨Axiward.measured, True.intro⟩⟩⟩
end Gate
