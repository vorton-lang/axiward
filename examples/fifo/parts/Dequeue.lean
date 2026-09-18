import Axiward.Spec
import Axiward.Queue

namespace Axiward

universe u
variable {α : Type u} {n : Nat}

theorem dequeue_some (q : Queue α n) :
    Q0.DequeueSome q.items q.dequeue.1 q.dequeue.2.items := by
  intro head tail contents
  rcases q with ⟨items, bound⟩
  change items = head :: tail at contents
  subst items
  exact ⟨rfl, rfl⟩

theorem dequeue_empty (q : Queue α n) :
    Q0.DequeueEmpty q.items q.dequeue.1 q.dequeue.2.items := by
  intro contents
  rcases q with ⟨items, bound⟩
  change items = [] at contents
  subst items
  exact ⟨rfl, rfl⟩

theorem measured (q : Queue α n) :
    Q0.Measured n q.capacity q.length q.items :=
  ⟨rfl, Nat.zero_le _, q.bounded, rfl⟩

end Axiward
