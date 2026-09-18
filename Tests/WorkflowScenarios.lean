import Axiward

open Axiward

def ensure (condition : Bool) (message : String) : IO Unit :=
  unless condition do throw (IO.userError message)

def advance (s : State) (actor : Actor) (command : Command) : IO State := do
  let request : Request := ⟨s!"event-{s.journal.entries.length}", actor, command, 0⟩
  return (← Git.decode ((step s request).mapError (fun e => s!"{repr e}"))).after

def refused (s : State) (actor : Actor) (command : Command) (fault : Fault) : IO Unit := do
  let result := step s ⟨"refusal", actor, command, 0⟩
  match result with
  | .error actual => ensure (actual == fault) s!"expected {repr fault}, received {repr actual}"
  | .ok _ => throw (IO.userError "forbidden transition succeeded")

def main : IO Unit := do
  let scope : Scope := ⟨0, "spec", "policy", [⟨"root", "v1"⟩]⟩
  let mut s ← Git.decode (restore { initial := scope })
  s ← advance s .controller (.begin "worker" .explore)
  s ← advance s (.worker "worker") (.submit 0 ⟨"plan"⟩)
  let mut stale ← advance s .user (.revise scope ⟨0, "other-spec", "other-policy", [⟨"root", "v2"⟩]⟩)
  stale ← advance stale .controller (.workflow (.prepare 0 ⟨"old plan", 1, "stop"⟩))
  ensure (stale.domain.active.isNone && stale.domain.workflow.explorations.isEmpty)
    "scope race during admission did not reject and end the formal attempt"
  refused s .controller (.workflow (.launch 0 "op" ⟨"candidate"⟩)) .wrongPhase
  s ← advance s .controller (.workflow (.prepare 0 ⟨"compare algorithms", 1, "stop after one trial"⟩))
  s ← advance s .controller (.workflow (.launch 0 "op" ⟨"candidate"⟩))
  refused s (.worker "worker") (.workflow (.observe "op" (.rejected "fake") "fake")) .forbidden
  refused s (.worker "worker") (.workflow (.conclude 0 "report")) .operationsPending
  s ← advance s .user (.workflow (.pause true "user away"))
  refused s .controller (.workflow (.launch 0 "op2" ⟨"candidate"⟩)) .paused
  s ← advance s (.worker "worker") (.cancel 0 "stop work; operation still outstanding")
  ensure (pendingOperations s == 1) "cancel erased external obligation"
  refused s .controller (.begin "worker" .execute) .paused
  let mut blocked ← advance s .user (.workflow (.pause false ""))
  blocked ← advance blocked .controller (.begin "worker" .execute)
  blocked ← advance blocked (.worker "worker") (.submit 1 ⟨"valid-candidate"⟩)
  blocked ← advance blocked .controller (.finish 1
    (.passed ⟨scope, ⟨"valid-candidate"⟩, "product", "receipt"⟩) "evidence")
  ensure (blocked.domain.published.isNone && !complete blocked) "pending external operation allowed publication"
  s ← advance s .controller (.workflow (.observe "op" (.rejected "actual result arrived late") "evidence"))
  ensure (s.domain.active.isNone && s.domain.published.isNone) "late result revived package"
  ensure (pendingOperations s == 0) "late result was not reconciled"
  let recovered ← Git.decode (restore s.journal)
  ensure (recovered.domain == s.domain) "workflow recovery changed state"
  s ← advance s .user (.workflow (.pause false ""))
  s ← advance s .controller (.begin "worker" .requestDecision)
  s ← advance s (.worker "worker") (.submit 1 ⟨"question"⟩)
  let question : Question := ⟨"Which representation?", "current root", [⟨"list", "immutable list"⟩]⟩
  s ← advance s .controller (.workflow (.ask 1 question))
  refused s (.worker "worker") (.workflow (.answer 1 "list" "pretending to be user")) .forbidden
  s ← advance s .user (.revise scope ⟨0, "spec2", "policy2", [⟨"root", "v2"⟩]⟩)
  s ← advance s .user (.workflow (.answer 1 "list" "old answer"))
  ensure ((s.domain.workflow.decisions[0]?.bind (·.answer)).any (fun a => !a.applicable))
    "stale answer applied to a new root"
  ensure (s.domain.active.isNone && s.domain.published.isNone) "answer closed goal"
  s ← advance s .controller (.begin "worker" .requestDecision)
  s ← advance s (.worker "worker") (.submit 2 ⟨"question2"⟩)
  s ← advance s .controller (.workflow (.ask 2 question))
  s ← advance s .user (.workflow (.answer 2 "please rewrite everything" "freeform input"))
  ensure ((s.domain.workflow.decisions[1]?.bind (·.answer)).any (fun a => !a.applicable))
    "freeform input was promoted to authority"
  refused s (.worker "intruder") (.workflow (.acknowledge 2)) .forbidden
  s ← advance s (.worker "worker") (.workflow (.acknowledge 2))
  s ← advance s .controller (.begin "worker" .explore)
  s ← advance s (.worker "worker") (.submit 3 ⟨"plan2"⟩)
  s ← advance s .controller (.workflow (.prepare 3 ⟨"analysis only", 0, "report alternatives"⟩))
  refused s .controller (.workflow (.launch 3 "no-budget" ⟨"candidate"⟩)) .budgetExhausted
  s ← advance s (.worker "worker") (.workflow (.conclude 3 "analysis-report"))
  ensure (!complete s) "notes were treated as a product proof"
  let recovered ← Git.decode (restore s.journal)
  ensure (recovered.domain == s.domain) "complete replay lost decisions or observations"
  IO.println "PASS: workflow faults, cancellation, late results, stale/freeform answers, pause, budget and replay"
