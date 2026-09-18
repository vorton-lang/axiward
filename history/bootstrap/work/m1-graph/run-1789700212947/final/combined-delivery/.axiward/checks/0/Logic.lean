def Holds (claims : List Nat) (facts : Nat → Prop) : Prop :=
  ∀ c ∈ claims, facts c
