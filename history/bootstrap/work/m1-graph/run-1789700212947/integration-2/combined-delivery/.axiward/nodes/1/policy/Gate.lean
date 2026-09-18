import Axiward.Spec
import Axiward.Queue
import Axiward.Proofs

namespace Gate
universe u
theorem accepted (α : Type u) (n : Nat) :
  Axiward.Q0.Created n (Axiward.Queue.empty α n).capacity (Axiward.Queue.empty α n).items ∧
  (∀ (q : Axiward.Queue α n) (x : α), Axiward.Q0.EnqueueRoom n q.items x (q.enqueue x).1 (q.enqueue x).2.items) ∧
  (∀ (q : Axiward.Queue α n) (x : α), Axiward.Q0.EnqueueFull n q.items (q.enqueue x).1 (q.enqueue x).2.items) ∧
  True :=
  ⟨Axiward.created α n, ⟨Axiward.enqueue_room, ⟨Axiward.enqueue_full, True.intro⟩⟩⟩
end Gate
