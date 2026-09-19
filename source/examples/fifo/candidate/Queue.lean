import Init

namespace Axiward

universe u

-- Capacity is a type index; an over-capacity queue cannot be constructed
-- without a proof of a false proposition. The proof field is erased at runtime.
structure Queue (α : Type u) (capacity : Nat) where
  items : List α
  bounded : items.length ≤ capacity

namespace Queue

variable {α : Type u} {n : Nat}

def empty (α : Type u) (n : Nat) : Queue α n :=
  ⟨[], Nat.zero_le n⟩

def capacity (_q : Queue α n) : Nat := n

def length (q : Queue α n) : Nat := q.items.length

def enqueue (q : Queue α n) (item : α) : Bool × Queue α n :=
  if h : q.items.length < n then
    let nextItems := q.items ++ [item]
    (true, ⟨nextItems, by simp [nextItems]; omega⟩)
  else
    (false, q)

def dequeue (q : Queue α n) : Option α × Queue α n :=
  match q with
  | ⟨[], bound⟩ => (none, ⟨[], bound⟩)
  | ⟨head :: tail, bound⟩ =>
    (some head, ⟨tail, Nat.le_trans (Nat.le_succ _) bound⟩)

end Queue
end Axiward
