import Init

namespace Axiward.Q0

-- Every element type in Type 0, capacity, state and item is quantified.
-- The example has no free universe parameters; this includes the String program.
structure Model where
  State : Type → Nat → Type
  empty : (α : Type) → (n : Nat) → State α n
  contents : {α : Type} → {n : Nat} → State α n → List α
  capacity : {α : Type} → {n : Nat} → State α n → Nat
  length : {α : Type} → {n : Nat} → State α n → Nat
  enqueue : {α : Type} → {n : Nat} → State α n → α → Bool × State α n
  dequeue : {α : Type} → {n : Nat} → State α n → Option α × State α n

def Created (m : Model) : Prop :=
  ∀ (α : Type) (n : Nat), m.capacity (m.empty α n) = n ∧ m.contents (m.empty α n) = []

def EnqueueRoom (m : Model) : Prop :=
  ∀ {α : Type} {n : Nat} (q : m.State α n) (item : α),
    (m.contents q).length < n →
      (m.enqueue q item).1 = true ∧ m.contents (m.enqueue q item).2 = m.contents q ++ [item]

def EnqueueFull (m : Model) : Prop :=
  ∀ {α : Type} {n : Nat} (q : m.State α n) (item : α),
    n ≤ (m.contents q).length →
      if n = 0 then (m.enqueue q item).1 = false ∧ m.contents (m.enqueue q item).2 = m.contents q
      else (m.enqueue q item).1 = true ∧ m.contents (m.enqueue q item).2 = (m.contents q).tail ++ [item]

def DequeueSome (m : Model) : Prop :=
  ∀ {α : Type} {n : Nat} (q : m.State α n) (head : α) (tail : List α),
    m.contents q = head :: tail →
      (m.dequeue q).1 = some head ∧ m.contents (m.dequeue q).2 = tail

def DequeueEmpty (m : Model) : Prop :=
  ∀ {α : Type} {n : Nat} (q : m.State α n), m.contents q = [] →
    (m.dequeue q).1 = none ∧ m.contents (m.dequeue q).2 = []

def Measured (m : Model) : Prop :=
  ∀ {α : Type} {n : Nat} (q : m.State α n),
    m.capacity q = n ∧ 0 ≤ (m.contents q).length ∧
      (m.contents q).length ≤ n ∧ m.length q = (m.contents q).length

end Axiward.Q0
