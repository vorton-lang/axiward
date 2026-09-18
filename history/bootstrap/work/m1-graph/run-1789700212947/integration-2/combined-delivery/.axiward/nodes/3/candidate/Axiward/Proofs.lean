import Axiward.Spec
import Axiward.Queue

namespace Axiward

universe u
variable {α : Type u} {n : Nat}

theorem created (α : Type u) (n : Nat) :
    Q0.Created n (Queue.empty α n).capacity (Queue.empty α n).items :=
  ⟨rfl, rfl⟩

end Axiward
