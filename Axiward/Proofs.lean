import Axiward.Transition

namespace Axiward

theorem initial_integrity (scope : Scope) : Integrity (initialDomain scope) := by
  simp [Integrity, initialDomain]

theorem begin_preserves (s : Domain) (owner : String) (action : Action) (t : Domain) (reply : Reply)
    (_hs : Integrity s) (h : begin s owner action = .ok (t, reply)) : Integrity t := by
  unfold begin at h
  repeat first | split at h | contradiction
  all_goals
    simp only [Except.ok.injEq, Prod.mk.injEq] at h
    rcases h with ⟨rfl, rfl⟩
    simp_all [Integrity]

theorem submit_preserves (s : Domain) (owner : String) (serial : Nat)
    (candidate : Candidate) (t : Domain) (reply : Reply)
    (hs : Integrity s) (h : submit s owner serial candidate = .ok (t, reply)) :
    Integrity t := by
  unfold submit at h
  repeat first | split at h | contradiction
  all_goals
    simp only [Except.ok.injEq, Prod.mk.injEq] at h
    rcases h with ⟨rfl, rfl⟩
    simp_all [Integrity]

theorem finish_preserves (s : Domain) (serial : Nat) (verdict : Verdict)
    (t : Domain) (reply : Reply) (hs : Integrity s)
    (h : finish s serial verdict = .ok (t, reply)) : Integrity t := by
  cases ha : s.active with
  | none => simp [finish, ha] at h
  | some p =>
    by_cases hid : p.serial = serial
    · cases hp : p.phase with
      | drafting => simp [finish, ha, hid, hp] at h
      | checking candidate =>
        by_cases hi : p.input = s.scope
        · cases verdict with
          | rejected reason =>
            simp [finish, ha, hid, hp, hi] at h
            rcases h with ⟨rfl, rfl⟩
            simp_all [Integrity]
          | unknown reason =>
            simp [finish, ha, hid, hp, hi] at h
            rcases h with ⟨rfl, rfl⟩
            simp_all [Integrity]
          | passed output =>
            by_cases hb : output.scope ≠ s.scope ∨ output.candidate ≠ candidate ∨
                output.product.isEmpty = true ∨ output.receipt.isEmpty = true
            · simp only [finish, ha, hid, hp, hi, ne_eq, not_true_eq_false, ite_false] at h
              simp only [hb, ite_true, Except.ok.injEq, Prod.mk.injEq] at h
              rcases h with ⟨rfl, rfl⟩
              simp_all [Integrity]
            · simp only [finish, ha, hid, hp, hi, ne_eq, not_true_eq_false, ite_false] at h
              simp only [hb, ite_false, Except.ok.injEq, Prod.mk.injEq] at h
              rcases h with ⟨rfl, rfl⟩
              simp_all [Integrity]
        · simp [finish, ha, hid, hp, hi] at h
          rcases h with ⟨rfl, rfl⟩
          simp_all [Integrity]
    · simp [finish, ha, hid] at h
theorem cancel_preserves (s : Domain) (actor : Actor) (serial : Nat) (reason : String)
    (t : Domain) (reply : Reply) (hs : Integrity s)
    (h : cancel s actor serial reason = .ok (t, reply)) : Integrity t := by
  unfold cancel at h
  repeat first | split at h | contradiction
  all_goals
    simp only [Except.ok.injEq, Prod.mk.injEq] at h
    rcases h with ⟨rfl, rfl⟩
    simp_all [Integrity]

theorem cancel_preserves_obligations (s t : Domain) (actor : Actor) (serial : Nat) (reason : String)
    (reply : Reply) (h : cancel s actor serial reason = .ok (t, reply)) :
    t.workflow = s.workflow := by
  unfold cancel at h
  repeat first | split at h | contradiction
  all_goals
    simp only [Except.ok.injEq, Prod.mk.injEq] at h
    rcases h with ⟨rfl, rfl⟩
    rfl

theorem revise_preserves (s : Domain) (expected replacement : Scope)
    (t : Domain) (reply : Reply) (hs : Integrity s)
    (h : revise s expected replacement = .ok (t, reply)) : Integrity t := by
  unfold revise at h
  repeat first | split at h | contradiction
  all_goals
    simp only [Except.ok.injEq, Prod.mk.injEq] at h
    rcases h with ⟨rfl, rfl⟩
    simp_all [Integrity]

theorem run_preserves (s : Domain) (actor : Actor) (command : Command)
    (t : Domain) (reply : Reply) (hs : Integrity s)
    (h : run s actor command = .ok (t, reply)) : Integrity t := by
  cases command <;> cases actor <;> simp only [run] at h
  all_goals first
    | exact begin_preserves _ _ _ _ _ hs h
    | exact submit_preserves _ _ _ _ _ _ hs h
    | exact finish_preserves _ _ _ _ _ hs h
    | exact cancel_preserves _ _ _ _ _ _ hs h
    | exact revise_preserves _ _ _ _ _ hs h
    | contradiction

theorem worker_cannot_finish (s : Domain) (owner : String) (serial : Nat)
    (verdict : Verdict) (evidence : String) : run s (.worker owner) (.finish serial verdict evidence) =
      .error .forbidden := rfl

theorem worker_cannot_revise (s : Domain) (owner : String) (expected replacement : Scope) :
    run s (.worker owner) (.revise expected replacement) = .error .forbidden := rfl

theorem ended_cannot_publish (s : Domain) (serial : Nat) (verdict : Verdict)
    (h : s.active = none) : finish s serial verdict = .error .wrongPackage := by
  simp [finish, h]

theorem sealed_cannot_be_replaced (s : Domain) (p : Package) (old new : Candidate)
    (h : s.active = some p) (hp : p.phase = .checking old) :
    submit s p.owner p.serial new = .error .wrongPhase := by
  simp [submit, h, hp]

theorem rejection_releases (s : Domain) (p : Package) (candidate : Candidate)
    (reason : String) (h : s.active = some p) (hp : p.phase = .checking candidate)
    (hc : p.input = s.scope) :
    finish s p.serial (.rejected reason) =
      .ok ({ s with active := none }, .rejected p.serial reason) := by
  simp [finish, h, hp, hc]

theorem current_result (s : Domain) (p : Publication) (hs : Integrity s)
    (hp : s.published = some p) : p.scope = s.scope := hs.2.1 p hp

/-- Publication requires a passing adapter result for the exact sealed candidate
    and current scope. The adapter's mathematical checking is an external contract. -/
theorem accepted_binding (s t : Domain) (serial acceptedSerial : Nat) (verdict : Verdict)
    (h : finish s serial verdict = .ok (t, .accepted acceptedSerial)) :
    ∃ p candidate output,
      s.active = some p ∧ p.serial = serial ∧ p.phase = .checking candidate ∧
      p.input = s.scope ∧ verdict = .passed output ∧
      output.scope = s.scope ∧ output.candidate = candidate ∧
      output.product.isEmpty = false ∧ output.receipt.isEmpty = false := by
  cases ha : s.active with
  | none => simp [finish, ha] at h
  | some p =>
    by_cases hid : p.serial = serial
    · cases hp : p.phase with
      | drafting => simp [finish, ha, hid, hp] at h
      | checking candidate =>
        by_cases hi : p.input = s.scope
        · cases verdict with
          | rejected reason => simp [finish, ha, hid, hp, hi] at h
          | unknown reason => simp [finish, ha, hid, hp, hi] at h
          | passed output =>
            by_cases hb : output.scope ≠ s.scope ∨ output.candidate ≠ candidate ∨
                output.product.isEmpty = true ∨ output.receipt.isEmpty = true
            · simp only [finish, ha, hid, hp, hi, ne_eq, not_true_eq_false, ite_false] at h
              simp only [hb, ite_true, Except.ok.injEq, Prod.mk.injEq] at h
              obtain ⟨_, impossible⟩ := h
              contradiction
            · refine ⟨p, candidate, output, rfl, hid, hp, hi, rfl, ?_⟩
              simpa only [not_or, ne_eq, Decidable.not_not, Bool.not_eq_true] using hb
        · simp [finish, ha, hid, hp, hi] at h
    · simp [finish, ha, hid] at h

theorem changed_scope_rejects (s : Domain) (p : Package) (candidate : Candidate)
    (verdict : Verdict) (ha : s.active = some p) (hp : p.phase = .checking candidate)
    (changed : p.input ≠ s.scope) :
    finish s p.serial verdict = .ok ({ s with active := none },
      .rejected p.serial "scope changed; revalidation required") := by
  simp [finish, ha, hp, changed]

end Axiward
