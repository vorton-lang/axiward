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

-- The root binds every requirement to the actual executable definitions.
-- Each clause is universal over all states/values, not a finite list of tests.
def SatisfiesQ0 (α : Type u) (n : Nat) : Prop :=
  Q0.Created n (Queue.empty α n).capacity (Queue.empty α n).items ∧
  (∀ (q : Queue α n) (item : α),
    Q0.EnqueueRoom n q.items item (q.enqueue item).1 (q.enqueue item).2.items) ∧
  (∀ (q : Queue α n) (item : α),
    Q0.EnqueueFull n q.items (q.enqueue item).1 (q.enqueue item).2.items) ∧
  (∀ q : Queue α n, Q0.DequeueSome q.items q.dequeue.1 q.dequeue.2.items) ∧
  (∀ q : Queue α n, Q0.DequeueEmpty q.items q.dequeue.1 q.dequeue.2.items) ∧
  (∀ q : Queue α n, Q0.Measured n q.capacity q.length q.items)

theorem satisfies_Q0 (α : Type u) (n : Nat) : SatisfiesQ0 α n :=
  ⟨created α n, enqueue_room, enqueue_full, dequeue_some, dequeue_empty, measured⟩

end Axiward
