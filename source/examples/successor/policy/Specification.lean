import Init

namespace Successor

-- Contracts about every Nat input, independent of the candidate implementation.
def Required (next : Nat → Nat) : Prop := ∀ n, next n = n + 1

def Positive (next : Nat → Nat) : Prop := ∀ n, 0 < next n

end Successor
