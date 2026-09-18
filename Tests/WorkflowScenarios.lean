import Axiward

open Axiward

def ensure (condition : Bool) (message : String) : IO Unit :=
  unless condition do throw (IO.userError message)

def advance (s : State) (actor : Actor) (command : Command) (node : Nat := 0) : IO State := do
  let request : Request := ⟨s!"event-{s.journal.entries.length}", actor, command, node⟩
  return (← Git.decode ((step s request).mapError (fun e => s!"{repr e}"))).after

def refused (s : State) (actor : Actor) (command : Command) (fault : Fault) : IO Unit := do
  let result := step s ⟨"refusal", actor, command, 0⟩
  match result with
  | .error actual => ensure (actual == fault) s!"expected {repr fault}, received {repr actual}"
  | .ok _ => throw (IO.userError "forbidden transition succeeded")

def handoffCases : IO Unit := do
  -- Checked refinement is a protocol fixture, as in StoreScenarios. Actual
  -- refinement proofs and descendant handoff are also exercised by workflow.py.
  let a : Requirement := ⟨"a", "one"⟩
  let b : Requirement := ⟨"b", "one"⟩
  let root : Scope := ⟨0, "spec", "policy", [a, b]⟩
  let childA : Scope := ⟨0, "spec-a", "policy-a", [a]⟩
  let childB : Scope := ⟨0, "spec-b", "policy-b", [b]⟩
  let question : Question := ⟨"Which approach?", "this exact goal", [⟨"list", "list"⟩]⟩
  let ask (s : State) (node serial : Nat) : IO State := do
    let s ← advance s .controller (.begin "original" .requestDecision) node
    let s ← advance s (.worker "original") (.submit serial ⟨"question"⟩) node
    let s ← advance s .controller (.workflow (.ask serial question)) node
    advance s .user (.workflow (.answer serial "list" "scoped preference")) node
  let mut s ← Git.decode (restore { initial := root })
  s ← ask s 0 0
  s ← advance s .controller (.begin "planner" .refine)
  s ← advance s (.worker "planner") (.submit 1 ⟨"plan"⟩)
  s ← advance s .controller (.finishRefinement 1
    (.passed ⟨root, ⟨"plan"⟩, [.fresh childA, .fresh childB], "certificate", none⟩) "fixture")
  s ← ask s 1 0
  s ← ask s 2 0
  s ← advance s .controller (.begin "fresh" .execute) 1
  let snapshot := s
  let before := Interface.handoff ⟨"before", s⟩ (some (1, snapshot, "input"))
  let decisions : List Lean.Json ← Git.decode (before.getObjValAs? _ "decisions")
  ensure (decisions.map (fun q => (q.getObjValAs? Nat "node").toOption) == [some 1, some 0])
    "handoff omitted the ancestor or included an unrelated sibling decision"
  ensure (decisions.all (fun q => (q.getObjValAs? Bool "applicableNow").toOption == some true))
    "current scoped preferences were not supplied to the fresh worker"
  s ← advance s .user (.revise root ⟨0, "spec-new", "policy-new", [⟨"a", "two"⟩, b]⟩)
  let after := Interface.handoff ⟨"after", s⟩ (some (1, snapshot, "input"))
  let decisions : List Lean.Json ← Git.decode (after.getObjValAs? _ "decisions")
  ensure (decisions.length == 1 && decisions.all (fun q =>
    (q.getObjValAs? Bool "recordedApplicable").toOption == some true &&
    (q.getObjValAs? Bool "applicableNow").toOption == some false))
    "unchanged child scope bypassed a changed root requirement dependency"
  let unaffected := Interface.handoff ⟨"after", s⟩ (some (2, snapshot, "input"))
  let decisions : List Lean.Json ← Git.decode (unaffected.getObjValAs? _ "decisions")
  ensure (decisions.length == 1 && decisions.all (fun q =>
    (q.getObjValAs? Bool "applicableNow").toOption == some true))
    "unaffected requirement dependency lost its applicable preference"

def main : IO Unit := do
  handoffCases
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
  let decisionsBefore := s.domain.workflow.decisions
  -- Legacy events still produce their original reply during journal replay,
  -- but no read/delivery state survives in the current model.
  s ← advance s (.worker "worker") (.workflow (.acknowledge 2))
  ensure (s.domain.workflow.decisions == decisionsBefore) "legacy acknowledgement mutated current decisions"
  let legacy : Journal ← Git.decode (Lean.fromJson? (Lean.toJson s.journal))
  let recoveredLegacy ← Git.decode (restore legacy)
  ensure (recoveredLegacy.domain == s.domain && recoveredLegacy.journal == legacy)
    "legacy acknowledgement history did not decode and replay exactly"
  s ← advance s .controller (.begin "worker" .explore)
  s ← advance s (.worker "worker") (.submit 3 ⟨"plan2"⟩)
  s ← advance s .controller (.workflow (.prepare 3 ⟨"analysis only", 0, "report alternatives"⟩))
  refused s .controller (.workflow (.launch 3 "no-budget" ⟨"candidate"⟩)) .budgetExhausted
  s ← advance s (.worker "worker") (.workflow (.conclude 3 "analysis-report"))
  ensure (!complete s) "notes were treated as a product proof"
  let recovered ← Git.decode (restore s.journal)
  ensure (recovered.domain == s.domain) "complete replay lost decisions or observations"
  IO.println "PASS: workflow faults, cancellation, late results, stale/freeform answers, pause, budget and replay"
