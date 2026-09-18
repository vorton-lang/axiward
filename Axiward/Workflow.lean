import Axiward.Model

namespace Axiward

def sealedFor (s : Domain) (serial : Nat) (action : Action) : Except Fault (Package × Candidate) := do
  let some p := s.active | throw .wrongPackage
  unless p.serial == serial do throw .wrongPackage
  unless p.action == action do throw .wrongAction
  let .checking candidate := p.phase | throw .wrongPhase
  return (p, candidate)

def validPlan (p : ExplorePlan) : Bool :=
  !p.question.trimAscii.toString.isEmpty && p.question.length ≤ 2000 &&
  p.maxRuns ≤ 8 && !p.stopWhen.trimAscii.toString.isEmpty && p.stopWhen.length ≤ 2000

def validQuestion (q : Question) : Bool :=
  !q.prompt.trimAscii.toString.isEmpty && q.prompt.length ≤ 2000 &&
  !q.subject.trimAscii.toString.isEmpty && q.subject.length ≤ 2000 &&
  1 ≤ q.options.length && q.options.length ≤ 4 &&
  q.options.all (fun o => !o.key.isEmpty && o.key.length ≤ 80 && !o.label.isEmpty && o.label.length ≤ 500) &&
  (q.options.map (·.key)).eraseDups.length == q.options.length

/-- The Boolean says to end this package. Observations and decisions never return
    a product, proof, changed goal or new route. -/
def workflowStep (s : Domain) (actor : Actor) (command : WorkflowCommand) (usable : Bool) :
    Except Fault (WorkflowState × Bool × Reply) := do
  let w := s.workflow
  match command, actor with
  | .reject serial reason, .controller =>
    let some p := s.active | throw .wrongPackage
    unless p.serial == serial do throw .wrongPackage
    unless p.action == .explore || p.action == .requestDecision do throw .wrongAction
    return (w, true, .rejected serial reason)
  | .prepare serial plan, .controller =>
    let (p, candidate) ← sealedFor s serial .explore
    unless p.input == s.scope && usable do return (w, true, .rejected serial "scope changed")
    unless validPlan plan do throw .invalidInput
    if w.explorations.any (fun x => x.serial == serial) then throw .wrongPhase
    return ({ w with explorations := w.explorations ++ [⟨serial, p.input, candidate, plan⟩] },
      false, .prepared serial)
  | .launch serial id candidate, .controller =>
    let (p, _) ← sealedFor s serial .explore
    unless p.input == s.scope && usable do throw .obsoleteScope
    let some plan := w.explorations.find? (fun x => x.serial == serial) | throw .wrongPhase
    if id.isEmpty || candidate.tree.isEmpty || w.operations.any (fun x => x.id == id) then
      throw .invalidInput
    if w.operations.any (fun x => x.serial == serial && x.result.isNone) then throw .operationsPending
    if (w.operations.filter (fun x => x.serial == serial)).length ≥ plan.plan.maxRuns then
      throw .budgetExhausted
    return ({ w with operations := w.operations ++ [⟨id, serial, p.input, candidate, none, ""⟩] },
      false, .launched id)
  | .observe id result evidence, .controller =>
    let some op := w.operations.find? (fun x => x.id == id) | throw .invalidInput
    if op.result.isSome || evidence.isEmpty then throw .wrongPhase
    if let .passed output := result then
      unless output.scope == op.input && output.candidate == op.candidate do throw .invalidInput
    let operations := w.operations.map (fun x => if x.id == id then
      { x with result := some result, evidence } else x)
    return ({ w with operations }, false, .observed id)
  | .conclude serial report, .worker owner =>
    let (p, _) ← sealedFor s serial .explore
    unless p.owner == owner do throw .forbidden
    unless w.explorations.any (fun x => x.serial == serial) do throw .wrongPhase
    if report.isEmpty then throw .invalidInput
    if w.operations.any (fun x => x.serial == serial && x.result.isNone) then throw .operationsPending
    return ({ w with reports := w.reports ++ [(serial, report)] }, true, .explored serial)
  | .ask serial question, .controller =>
    let (p, candidate) ← sealedFor s serial .requestDecision
    unless p.input == s.scope && usable do return (w, true, .rejected serial "scope changed")
    unless validQuestion question do throw .invalidInput
    if w.decisions.any (fun x => x.serial == serial) then throw .wrongPhase
    return ({ w with decisions := w.decisions ++ [⟨serial, p.owner, p.input, candidate, question, none⟩] },
      false, .waitingUser serial)
  | .answer serial choice comment, .user =>
    let some question := w.decisions.find? (fun x => x.serial == serial) | throw .invalidInput
    if question.answer.isSome then throw .wrongPhase
    if choice.length > 2000 || comment.length > 8000 then throw .invalidInput
    let isActive := s.active.any (fun p => p.serial == serial)
    let applicable := isActive && usable && question.input == s.scope &&
      question.question.options.any (fun x => x.key == choice)
    let answer : Answer := ⟨choice, comment, applicable⟩
    let decisions := w.decisions.map (fun x => if x.serial == serial then { x with answer := some answer } else x)
    return ({ w with decisions }, isActive, .answered serial applicable)
  | .acknowledge serial, .worker owner =>
    let some question := w.decisions.find? (fun x => x.serial == serial) | throw .invalidInput
    unless question.owner == owner do throw .forbidden
    unless question.answer.isSome do throw .wrongPhase
    -- Retain the original reply so schema-3 journals replay exactly. Reading has
    -- no live state: old acknowledgement events no longer mutate decisions.
    return (w, false, .acknowledged serial)
  | .pause value reason, .user =>
    return ({ w with paused := value, pauseReason := reason }, false, .paused value)
  | .access resource allowed, .user =>
    if resource.isEmpty then throw .invalidInput
    let denied := w.deniedResources.filter (· != resource)
    return ({ w with deniedResources := if allowed then denied else denied ++ [resource] },
      false, .accessChanged resource)
  | _, _ => throw .forbidden

def runWorkflow (s : Domain) (actor : Actor) (command : WorkflowCommand) (usable : Bool) :
    Except Fault (Domain × Reply) := do
  let (workflow, ended, reply) ← workflowStep s actor command usable
  return ({ s with workflow, active := if ended then none else s.active }, reply)

theorem workflow_preserves (s t : Domain) (actor : Actor) (command : WorkflowCommand)
    (usable : Bool) (reply : Reply) (hs : Integrity s)
    (h : runWorkflow s actor command usable = .ok (t, reply)) : Integrity t := by
  unfold runWorkflow at h
  cases hw : workflowStep s actor command usable with
  | error e => simp [hw, Bind.bind, Except.bind] at h
  | ok output =>
    rcases output with ⟨w, ended, r⟩
    simp [hw, Bind.bind, Except.bind, pure, Except.pure] at h
    rcases h with ⟨rfl, rfl⟩
    cases ended <;> simp_all [Integrity]

theorem workflow_never_publishes (s t : Domain) (actor : Actor) (command : WorkflowCommand)
    (usable : Bool) (reply : Reply)
    (h : runWorkflow s actor command usable = .ok (t, reply)) :
    t.published = s.published ∧ t.scope = s.scope ∧ t.nextSerial = s.nextSerial := by
  unfold runWorkflow at h
  cases hw : workflowStep s actor command usable with
  | error e => simp [hw, Bind.bind, Except.bind] at h
  | ok output =>
    rcases output with ⟨w, ended, r⟩
    simp [hw, Bind.bind, Except.bind, pure, Except.pure] at h
    rcases h with ⟨rfl, rfl⟩
    exact ⟨rfl, rfl, rfl⟩

theorem worker_cannot_answer (s : Domain) (owner choice comment : String) (serial : Nat)
    (usable : Bool) : workflowStep s (.worker owner) (.answer serial choice comment) usable =
      .error .forbidden := rfl

theorem worker_cannot_forge_observation (s : Domain) (owner id evidence : String)
    (result : Verdict) (usable : Bool) :
    workflowStep s (.worker owner) (.observe id result evidence) usable = .error .forbidden := rfl

theorem observation_preserves_occupancy (s : Domain) (id evidence : String) (result : Verdict)
    (usable : Bool) (w : WorkflowState) (ended : Bool) (reply : Reply)
    (h : workflowStep s .controller (.observe id result evidence) usable = .ok (w, ended, reply)) :
    ended = false := by
  cases result <;> simp only [workflowStep] at h
  all_goals
    repeat first | split at h | contradiction
    all_goals simp_all [pure, Except.pure, Bind.bind, Except.bind, throw]

theorem late_observation_never_revives (s t : Domain) (id evidence : String) (result : Verdict)
    (usable : Bool) (reply : Reply)
    (h : runWorkflow s .controller (.observe id result evidence) usable = .ok (t, reply)) :
    t.active = s.active := by
  unfold runWorkflow at h
  cases hw : workflowStep s .controller (.observe id result evidence) usable with
  | error e => simp [hw, Bind.bind, Except.bind] at h
  | ok output =>
    rcases output with ⟨w, ended, r⟩
    have endedFalse := observation_preserves_occupancy s id evidence result usable w ended r hw
    subst ended
    simp [hw, Bind.bind, Except.bind, pure, Except.pure] at h
    rcases h with ⟨rfl, rfl⟩
    rfl

theorem launch_requires_admitted_plan (s : Domain) (serial : Nat) (id : String) (candidate : Candidate)
    (usable : Bool) (w : WorkflowState) (ended : Bool) (reply : Reply)
    (h : workflowStep s .controller (.launch serial id candidate) usable = .ok (w, ended, reply)) :
    (s.workflow.explorations.find? (fun x => x.serial == serial)).isSome = true := by
  cases hp : sealedFor s serial .explore with
  | error e => simp [workflowStep, hp, Bind.bind, Except.bind] at h
  | ok pair =>
    rcases pair with ⟨p, input⟩
    cases plan : s.workflow.explorations.find? (fun x => x.serial == serial) with
    | some value => rfl
    | none =>
      simp only [workflowStep, hp, plan, Bind.bind, Except.bind] at h
      split at h <;> contradiction

end Axiward
