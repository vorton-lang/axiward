import Std

/- Q0: declarative conditions on observable sequences, independent of Queue. -/
namespace Axiward.Q0

universe u
variable {α : Type u}

-- 1. Creation preserves the requested capacity and starts empty.
def Created (requested actual : Nat) (items : List α) : Prop :=
  actual = requested ∧ items = []

-- 2. With room available, append the unchanged value at the tail.
def EnqueueRoom (capacity : Nat) (before : List α) (item : α)
    (accepted : Bool) (after : List α) : Prop :=
  before.length < capacity → accepted = true ∧ after = before ++ [item]

-- 3. When full, overwrite the oldest item; zero capacity still rejects.
def EnqueueFull (capacity : Nat) (before : List α) (item : α)
    (accepted : Bool) (after : List α) : Prop :=
  capacity ≤ before.length →
    if capacity = 0 then accepted = false ∧ after = before
    else accepted = true ∧ after = before.tail ++ [item]
-- 4. A successful dequeue returns exactly the old head and keeps the tail.
def DequeueSome (before : List α) (returned : Option α) (after : List α) : Prop :=
  ∀ head tail, before = head :: tail → returned = some head ∧ after = tail

-- 5. Empty dequeue reports none and leaves the sequence unchanged.
def DequeueEmpty (before : List α) (returned : Option α) (after : List α) : Prop :=
  before = [] → returned = none ∧ after = before

-- 6. The reported length is exact and bounded; capacity is unchanged.
def Measured (requested actual reported : Nat) (items : List α) : Prop :=
  reported = items.length ∧ 0 ≤ reported ∧ reported ≤ requested ∧ actual = requested

end Axiward.Q0
