import Axiward.Model

namespace Axiward

def begin (s : Domain) (owner : String) (action : Action) : Except Fault (Domain × Reply) :=
  if owner.isEmpty then .error .invalidInput
  else if s.active.isSome then .error .occupied
  else if s.published.isSome then .error .closed
  else .ok ({ s with
    nextSerial := s.nextSerial + 1
    active := some ⟨s.nextSerial, owner, s.scope, .drafting, action⟩ }, .acquired s.nextSerial)

def submit (s : Domain) (owner : String) (serial : Nat) (candidate : Candidate) :
    Except Fault (Domain × Reply) :=
  match s.active with
  | none => .error .wrongPackage
  | some p =>
    if p.serial ≠ serial then .error .wrongPackage
    else if p.owner ≠ owner then .error .forbidden
    else match p.phase with
    | .checking _ => .error .wrongPhase
    | .drafting =>
      if candidate.tree.isEmpty then
        .ok ({ s with active := none }, .rejected serial "missing candidate")
      else .ok ({ s with active := some { p with phase := .checking candidate } },
        .sealed serial)

def finish (s : Domain) (serial : Nat) (verdict : Verdict) :
    Except Fault (Domain × Reply) :=
  match s.active with
  | none => .error .wrongPackage
  | some p =>
    if p.serial ≠ serial then .error .wrongPackage
    else match p.phase with
    | .drafting => .error .wrongPhase
    | .checking candidate =>
      if p.input ≠ s.scope then
        .ok ({ s with active := none }, .rejected serial "scope changed; revalidation required")
      else match verdict with
      | .rejected reason => .ok ({ s with active := none }, .rejected serial reason)
      | .unknown reason => .ok ({ s with active := none }, .unresolved serial reason)
      | .passed output =>
        if output.scope ≠ s.scope ∨ output.candidate ≠ candidate ∨
            output.product.isEmpty ∨ output.receipt.isEmpty then
          .ok ({ s with active := none }, .rejected serial "verifier binding mismatch")
        else .ok ({ s with
          active := none
          published := some ⟨s.scope, candidate, output.product, output.receipt⟩ },
          .accepted serial)

def cancel (s : Domain) (actor : Actor) (serial : Nat) (reason : String) :
    Except Fault (Domain × Reply) :=
  match s.active with
  | none => .error .wrongPackage
  | some p =>
    if p.serial ≠ serial then .error .wrongPackage
    else if actor ≠ .controller ∧ actor ≠ .user ∧ actor ≠ .worker p.owner then
      .error .forbidden
    else .ok ({ s with active := none }, .cancelled serial reason)

def revise (s : Domain) (expected replacement : Scope) :
    Except Fault (Domain × Reply) :=
  if s.scope ≠ expected then .error .staleRevision
  else if replacement.specification.isEmpty || replacement.policy.isEmpty ||
      !validRequirements replacement.requirements then .error .invalidInput
  else .ok ({ s with
    scope := { replacement with revision := s.scope.revision + 1 }
    published := none }, .revised (s.scope.revision + 1))

/-- This is the reducer called by both the live CLI and journal recovery. -/
def run (s : Domain) (actor : Actor) (command : Command) :
    Except Fault (Domain × Reply) :=
  match command, actor with
  | .begin owner action, .controller => begin s owner action
  | .submit serial candidate, .worker owner => submit s owner serial candidate
  | .finish serial verdict _, .controller => finish s serial verdict
  | .cancel serial reason, actor => cancel s actor serial reason
  | .revise expected replacement, .user => revise s expected replacement
  | _, _ => .error .forbidden

end Axiward
