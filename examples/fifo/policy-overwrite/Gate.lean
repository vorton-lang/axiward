import Axiward.Spec
import Axiward.Queue
import Axiward.Proofs

namespace Gate
universe u

-- The acceptance goal is controlled here, not supplied by the candidate.
theorem accepted (α : Type u) (n : Nat) :
    Axiward.Q0.Created n (Axiward.Queue.empty α n).capacity (Axiward.Queue.empty α n).items ∧
    (∀ (q : Axiward.Queue α n) (x : α),
      Axiward.Q0.EnqueueRoom n q.items x (q.enqueue x).1 (q.enqueue x).2.items) ∧
    (∀ (q : Axiward.Queue α n) (x : α),
      Axiward.Q0.EnqueueFull n q.items x (q.enqueue x).1 (q.enqueue x).2.items) ∧
    (∀ q : Axiward.Queue α n,
      Axiward.Q0.DequeueSome q.items q.dequeue.1 q.dequeue.2.items) ∧
    (∀ q : Axiward.Queue α n,
      Axiward.Q0.DequeueEmpty q.items q.dequeue.1 q.dequeue.2.items) ∧
    (∀ q : Axiward.Queue α n, Axiward.Q0.Measured n q.capacity q.length q.items) :=
  Axiward.satisfies_Q0 α n

end Gate
