import Axiward.Spec
import Axiward.Queue

namespace Axiward

-- This subject uses the same definitions called by Main.lean.
def subject : Q0.Model where
  State := Queue
  empty := Queue.empty
  contents := Queue.items
  capacity := Queue.capacity
  length := Queue.length
  enqueue := Queue.enqueue
  dequeue := Queue.dequeue

theorem created : Q0.Created subject := by
  intro α n
  exact ⟨rfl, rfl⟩

theorem enqueue_room : Q0.EnqueueRoom subject := by
  intro α n q item room
  change q.items.length < n at room
  simp [subject, Queue.enqueue, room]

theorem enqueue_full : Q0.EnqueueFull subject := by
  intro α n q item full
  change n ≤ q.items.length at full
  by_cases zero : n = 0
  · simp [subject, Queue.enqueue, zero]
  · have positive : 0 < n := Nat.pos_of_ne_zero zero
    simp [subject, Queue.enqueue, Nat.not_lt.mpr full, zero, positive]

theorem dequeue_some : Q0.DequeueSome subject := by
  intro α n q head tail contents
  rcases q with ⟨items, bound⟩
  change items = head :: tail at contents
  subst items
  exact ⟨rfl, rfl⟩

theorem dequeue_empty : Q0.DequeueEmpty subject := by
  intro α n q contents
  rcases q with ⟨items, bound⟩
  change items = [] at contents
  subst items
  exact ⟨rfl, rfl⟩

theorem measured : Q0.Measured subject := by
  intro α n q
  exact ⟨rfl, Nat.zero_le _, q.bounded, rfl⟩

end Axiward
