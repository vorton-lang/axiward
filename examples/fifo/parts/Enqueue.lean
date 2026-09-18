import Axiward.Spec
import Axiward.Queue

namespace Axiward

universe u
variable {α : Type u} {n : Nat}

theorem created (α : Type u) (n : Nat) :
    Q0.Created n (Queue.empty α n).capacity (Queue.empty α n).items :=
  ⟨rfl, rfl⟩

theorem enqueue_room (q : Queue α n) (item : α) :
    Q0.EnqueueRoom n q.items item (q.enqueue item).1 (q.enqueue item).2.items := by
  intro room
  simp [Queue.enqueue, room]

theorem enqueue_full (q : Queue α n) (item : α) :
    Q0.EnqueueFull n q.items (q.enqueue item).1 (q.enqueue item).2.items := by
  intro full
  simp [Queue.enqueue, Nat.not_lt.mpr full]

end Axiward
