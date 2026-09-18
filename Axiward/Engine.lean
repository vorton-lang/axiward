import Axiward.Proofs
import Axiward.Workflow

namespace Axiward

structure Node where
  domain : Domain
  route : Option Route := none
  support : Option Composition := none
  deriving Lean.ToJson

def domainCheck (d : Domain) : Bool :=
  (d.active.isNone || d.published.isNone) &&
  d.published.all (fun p => decide (p.scope = d.scope)) &&
  d.active.all (fun p => p.serial < d.nextSerial)

theorem domainCheck_iff (d : Domain) : domainCheck d = true ↔ Integrity d := by
  cases ha : d.active <;> cases hp : d.published <;> simp_all [domainCheck, Integrity]

def childResults (nodes : Array Node) (route : Route) : Option (List ChildResult) :=
  route.children.mapM fun goal => do
    let n ← nodes[goal.node]?
    if n.domain.scope ≠ goal.scope then none else do
      let p ← n.domain.published
      return ⟨goal.node, p⟩

def scopeUsable (nodes : Array Node) (scope : Scope) : Bool :=
  nodes[0]?.any (fun root => compatible scope root.domain.scope)

def advanceHeights (nodes : Array Node) (previous : Array Nat) : Array Nat :=
  nodes.map fun node => match node.route with
    | none => 0
    | some route => 1 + route.children.foldl (fun rank c => max rank (previous[c.node]?.getD 0)) 0

def heightPasses (nodes : Array Node) : Nat → Array Nat
  | 0 => Array.replicate nodes.size 0
  | n + 1 => advanceHeights nodes (heightPasses nodes n)

def height (nodes : Array Node) (index : Nat) : Nat :=
  (heightPasses nodes nodes.size)[index]?.getD 0

def edgesValid (nodes : Array Node) (index : Nat) (node : Node) : Bool :=
  node.route.all (fun r => decide (r.scope = node.domain.scope) &&
    r.implementation.all (· < r.children.length) &&
    r.children.all (fun c => c.node < nodes.size && height nodes c.node < height nodes index))

def topologyValid (nodes : Array Node) : Bool :=
  nodes.toList.zipIdx.all (fun (node, i) => edgesValid nodes i node)

def publicationValid (nodes : Array Node) (node : Node) : Bool :=
  match node.domain.published with
  | none => true
  | some p => scopeUsable nodes node.domain.scope &&
    match node.route, node.support with
    | none, none => true
    | some route, some input =>
      decide (input.scope = node.domain.scope ∧ input.route = route ∧
        input.candidate = p.candidate ∧ childResults nodes route = some input.children)
    | _, _ => false

def GraphIntegrity (nodes : Array Node) : Prop :=
  0 < nodes.size ∧ ∀ i : Fin nodes.size,
    domainCheck nodes[i].domain = true ∧ edgesValid nodes i nodes[i] = true ∧
    publicationValid nodes nodes[i] = true ∧ validRequirements nodes[i].domain.scope.requirements = true

instance (nodes : Array Node) : Decidable (GraphIntegrity nodes) := inferInstanceAs
  (Decidable (0 < nodes.size ∧ ∀ i : Fin nodes.size,
    domainCheck nodes[i].domain = true ∧ edgesValid nodes i nodes[i] = true ∧
    publicationValid nodes nodes[i] = true ∧ validRequirements nodes[i].domain.scope.requirements = true))

/-- Only current-result fields are invalidated. Frozen packages and original
    scopes are preserved, including packages whose old inputs have become stale. -/
def clearInvalid (nodes : Array Node) : Array Node :=
  nodes.map fun n => if publicationValid nodes n then n
    else { n with domain := { n.domain with published := none }, support := none }

def normalizePasses : Nat → Array Node → Array Node
  | 0, nodes => nodes
  | n + 1, nodes => normalizePasses n (clearInvalid nodes)

def normalize (nodes : Array Node) : Array Node := normalizePasses nodes.size nodes

def packageFrames (nodes : Array Node) : Array (Nat × Option Package) :=
  nodes.map (fun n => (n.domain.nextSerial, n.domain.active))

theorem clearInvalid_preserves_packages (nodes : Array Node) :
    packageFrames (clearInvalid nodes) = packageFrames nodes := by
  simp only [packageFrames, clearInvalid, Array.map_map]
  congr 1
  funext n
  simp only [Function.comp_apply]
  split <;> rfl

theorem normalize_preserves_packages (count : Nat) (nodes : Array Node) :
    packageFrames (normalizePasses count nodes) = packageFrames nodes := by
  induction count generalizing nodes with
  | zero => rfl
  | succ count ih =>
    rw [normalizePasses, ih, clearInvalid_preserves_packages]
structure State where
  nodes : Array Node
  integrity : GraphIntegrity nodes
  journal : Journal

def State.domain (s : State) : Domain := (s.nodes[0]'s.integrity.1).domain

def currentNodes (nodes : Array Node) : List Nat := Id.run do
  let mut seen := [0]
  for _ in [:nodes.size] do
    for id in seen do
      if let some n := nodes[id]? then
        if let some r := n.route then
          seen := (seen ++ r.children.map (·.node)).eraseDups
  return seen

def pendingOperations (s : State) : Nat :=
  s.nodes.foldl (fun n node => n + (node.domain.workflow.operations.filter (·.result.isNone)).length) 0

def complete (s : State) : Bool :=
  s.domain.published.isSome && pendingOperations s == 0 &&
  (currentNodes s.nodes).all (fun id => s.nodes[id]?.all (fun n => n.domain.active.isNone))

theorem complete_requires_proof_and_settlement (s : State) (h : complete s = true) :
    s.domain.published.isSome = true ∧ pendingOperations s = 0 := by
  simp only [complete, Bool.and_eq_true, beq_iff_eq] at h
  exact h.1

def newState (scope : Scope) (valid : validRequirements scope.requirements = true) : State :=
  ⟨#[{ domain := initialDomain scope }], by
    simp [GraphIntegrity, domainCheck, edgesValid, publicationValid, initialDomain, valid],
    { initial := scope }⟩
structure Change (before : State) where
  after : State
  reply : Reply
  changed : Bool
  historyPrefix : ∃ suffix, after.journal.entries = before.journal.entries ++ suffix

def refineNode (nodes : Array Node) (id serial : Nat) (verdict : RefinementVerdict) :
    Except Fault (Array Node × Reply) := do
  let some n := nodes[id]? | throw .wrongNode
  let some p := n.domain.active | throw .wrongPackage
  if p.serial ≠ serial then throw .wrongPackage
  if p.action ≠ .refine then throw .wrongAction
  let .checking candidate := p.phase | throw .wrongPhase
  let ended := { n with domain := { n.domain with active := none } }
  let reject (reason : String) := .ok (nodes.set! id ended, Reply.rejected serial reason)
  if p.input ≠ n.domain.scope ∨ scopeUsable nodes n.domain.scope = false then
    return ← reject "scope changed"
  match verdict with
  | .rejected reason => reject reason
  | .unknown reason => return (nodes.set! id ended, .unresolved serial reason)
  | .reused output =>
    if n.domain.workflow.operations.any (fun op => op.result.isNone) then
      return ← reject "operation reconciliation required"
    unless output.scope = n.domain.scope ∧ output.proposal = candidate ∧
        sameGoal output.source.scope n.domain.scope = true ∧
        !output.receipt.isEmpty ∧ !output.source.product.isEmpty do
      return ← reject "reuse binding mismatch"
    let publication : Publication := ⟨n.domain.scope, output.source.candidate,
      output.source.product, output.receipt⟩
    let adopted : Node := { ended with
      domain := { ended.domain with published := some publication }
      route := none
      support := none }
    return (nodes.set! id adopted, .reused serial output.source.receipt)
  | .passed output =>
    if output.scope ≠ n.domain.scope ∨ output.candidate ≠ candidate ∨ output.certificate.isEmpty then
      return ← reject "refinement binding mismatch"
    if output.implementation.any (· ≥ output.children.length) then
      return ← reject "invalid implementation source"
    let mut expanded := nodes
    let mut children : List ChildGoal := []
    for child in output.children do
      match child with
      | .fresh scope =>
        unless !scope.specification.isEmpty && !scope.policy.isEmpty &&
            validRequirements scope.requirements && scopeUsable nodes scope do
          return ← reject "invalid or obsolete child scope"
        children := children ++ [⟨expanded.size, scope⟩]
        expanded := expanded.push { domain := initialDomain scope }
      | .reuse goal =>
        let some existing := nodes[goal.node]? | return ← reject "unknown reused node"
        unless existing.domain.scope = goal.scope ∧ scopeUsable nodes goal.scope = true do
          return ← reject "reused goal changed or is obsolete"
        children := children ++ [goal]
    let route : Option Route := if children.isEmpty then none else
      some ⟨n.domain.scope, candidate, children, output.certificate, output.implementation⟩
    let updated := expanded.set! id { ended with route, support := none }
    unless topologyValid updated do return ← reject "refinement would create an invalid or cyclic graph"
    return (updated, .refined serial (children.map (·.node)))
def canCompose (nodes : Array Node) (id : Nat) (input : Composition) : Bool :=
  match nodes[id]? with
  | none => false
  | some n =>
    n.domain.active.isNone && n.domain.published.isNone && scopeUsable nodes n.domain.scope &&
    n.domain.workflow.operations.all (fun op => op.result.isSome) &&
    decide (n.domain.scope = input.scope ∧ n.route = some input.route ∧
      childResults nodes input.route = some input.children)

def composeNode (nodes : Array Node) (id : Nat) (input : Composition) (verdict : Verdict) :
    Except Fault (Array Node × Reply) := do
  unless canCompose nodes id input do
    return (nodes, .compositionFailed "composition inputs changed or dependencies are not ready")
  let some n := nodes[id]? | throw .wrongNode
  match verdict with
  | .rejected reason | .unknown reason => return (nodes, .compositionFailed reason)
  | .passed output =>
    if output.scope ≠ input.scope ∨ output.candidate ≠ input.candidate ∨
        output.product.isEmpty ∨ output.receipt.isEmpty then
      return (nodes, .compositionFailed "composition binding mismatch")
    let publication : Publication := ⟨input.scope, input.candidate, output.product, output.receipt⟩
    let updated : Node := { n with
      domain := { n.domain with published := some publication }
      support := some input }
    return (nodes.set! id updated, .composed)

def runGraph (nodes : Array Node) (request : Request) : Except Fault (Array Node × Reply) := do
  let some n := nodes[request.node]? | throw .wrongNode
  match request.command with
  | .archive serial _ _ =>
    unless request.actor == .controller do throw .forbidden
    return (nodes, .archived serial)
  | .workflow command =>
    match command with
    | .pause _ _ | .access _ _ => unless request.node == 0 do throw .forbidden
    | _ => pure ()
    let (domain, reply) ← runWorkflow n.domain request.actor command (scopeUsable nodes n.domain.scope)
    return (nodes.set! request.node { n with domain }, reply)
  | .finishRefinement serial verdict _ =>
    unless request.actor = .controller do throw .forbidden
    refineNode nodes request.node serial verdict
  | .compose input verdict _ =>
    unless request.actor = .controller do throw .forbidden
    composeNode nodes request.node input verdict
  | command =>
    if let .begin _ _ := command then
      unless scopeUsable nodes n.domain.scope do throw .obsoleteScope
    if let .begin _ .execute := command then
      if n.route.isSome then throw .wrongAction
    if let .finish _ _ _ := command then
      if n.domain.active.any (fun p => p.action != .execute) then throw .wrongAction
    if let .revise _ _ := command then
      unless request.node == 0 do throw .forbidden
    let effective := match command with
      | .finish serial _ evidence => if scopeUsable nodes n.domain.scope then command
          else .finish serial (.rejected "root requirements changed; old evidence is not current") evidence
      | _ => command
    let effective := match effective with
      | .finish serial (.passed _) evidence =>
        if n.domain.workflow.operations.any (fun op => op.result.isNone) then
          .finish serial (.unknown "operation reconciliation required") evidence else effective
      | _ => effective
    let (domain, reply) ← run n.domain request.actor effective
    let updated := match command with
      | .revise _ _ => { n with domain, route := none, support := none }
      | _ => { n with domain }
    return (nodes.set! request.node updated, reply)

def step (s : State) (request : Request) : Except Fault (Change s) := do
  if request.id.isEmpty then throw .invalidInput
  if let .archive serial candidate _ := request.command then
    unless s.journal.entries.any (fun e => e.request.node == request.node &&
        e.request.command == .submit serial candidate) do throw .invalidInput
  if let .finishRefinement _ (.reused output) _ := request.command then
    unless priorAdmission s.journal.entries output.sourceNode output.source do throw .invalidInput
  match s.journal.entries.find? (fun e => e.request.id == request.id) with
  | some entry =>
    if entry.request = request then
      return ⟨s, entry.reply, false, ⟨[], by simp⟩⟩
    else throw .requestConflict
  | none =>
    let startsWork := match request.command with
      | .begin _ _ | .workflow (.launch _ _ _) => true
      | _ => false
    if s.domain.workflow.paused && startsWork then throw .paused
    let (candidate, reply) ← runGraph s.nodes request
    let nodes := normalize candidate
    if valid : GraphIntegrity nodes then
      let entry : Entry := ⟨request, reply⟩
      let after : State := ⟨nodes, valid,
        { s.journal with entries := s.journal.entries ++ [entry] }⟩
      return ⟨after, reply, true, ⟨[entry], rfl⟩⟩
    else throw .invalidGraph

def restore (journal : Journal) : Except String State := do
  if journal.schema != 3 then throw "unsupported journal schema; this prototype requires schema 3"
  if journal.initial.specification.isEmpty || journal.initial.policy.isEmpty then
    throw "missing initial scope"
  if valid : validRequirements journal.initial.requirements = true then
    journal.entries.foldlM (init := newState journal.initial valid) fun s entry => do
      let result ← (step s entry.request).mapError (fun e => s!"invalid transition: {repr e}")
      unless result.changed do throw "duplicate entry in journal"
      unless result.reply = entry.reply do throw "recorded reply differs from the transition"
      return result.after
  else throw "invalid requirement references"

theorem pause_blocks_new_package (s : State) (id owner : String) (action : Action) (node : Nat)
    (nonempty : id.isEmpty = false) (paused : s.domain.workflow.paused = true)
    (fresh : s.journal.entries.find? (fun e => e.request.id == id) = none) :
    step s ⟨id, .controller, .begin owner action, node⟩ = .error .paused := by
  simp [step, nonempty, paused, fresh, pure, Except.pure, Bind.bind, Except.bind, throw]
  rfl

theorem step_preserves_history (s : State) (request : Request) (change : Change s)
    (_h : step s request = .ok change) :
    ∃ suffix, change.after.journal.entries = s.journal.entries ++ suffix := change.historyPrefix

/-- A successful replay returns the recorded reply without changing state or
    creating another event, including when the original package has ended. -/
theorem replay_preserves_state (s : State) (request : Request) (entry : Entry) (change : Change s)
    (nonempty : request.id.isEmpty = false) (same : entry.request = request)
    (found : s.journal.entries.find? (fun e => e.request.id == request.id) = some entry)
    (h : step s request = .ok change) :
    change.after = s ∧ change.reply = entry.reply ∧ change.changed = false := by
  cases hc : request.command <;>
    simp only [step, nonempty, found, same, hc, ite_true,
      pure, Except.pure, Bind.bind, Except.bind] at h
  all_goals
    repeat first | split at h | contradiction
    all_goals simp_all
    all_goals cases h <;> exact ⟨rfl, rfl, rfl⟩

theorem graph_node_integrity (s : State) (i : Fin s.nodes.size) : Integrity s.nodes[i].domain :=
  (domainCheck_iff _).mp (s.integrity.2 i).1

theorem published_scope_usable (nodes : Array Node) (n : Node) (p : Publication)
    (published : n.domain.published = some p) (valid : publicationValid nodes n = true) :
    scopeUsable nodes n.domain.scope = true := by
  simp only [publicationValid, published, Bool.and_eq_true] at valid
  exact valid.1

theorem published_requirements_current (s : State) (i : Fin s.nodes.size) (p : Publication)
    (published : s.nodes[i].domain.published = some p) :
    ∀ r ∈ s.nodes[i].domain.scope.requirements, r ∈ s.domain.scope.requirements := by
  have h := published_scope_usable s.nodes s.nodes[i] p published (s.integrity.2 i).2.2.1
  simp only [scopeUsable, Array.getElem?_eq_getElem s.integrity.1, Option.any_some] at h
  exact (compatible_iff _ _).mp h

theorem route_rank_decreases (s : State) (i : Fin s.nodes.size) (r : Route)
    (hr : s.nodes[i].route = some r) (c : ChildGoal) (hc : c ∈ r.children) :
    c.node < s.nodes.size ∧ height s.nodes c.node < height s.nodes i := by
  have h := (s.integrity.2 i).2.1
  simp only [edgesValid, hr, Option.all_some, Bool.and_eq_true] at h
  have h' := List.all_eq_true.mp h.2 c hc
  simpa using h'

inductive Reach (nodes : Array Node) : Nat → Nat → Prop where
  | edge (i : Fin nodes.size) (r : Route) (c : ChildGoal)
      (route : nodes[i].route = some r) (member : c ∈ r.children) : Reach nodes i c.node
  | trans {a b c : Nat} : Reach nodes a b → Reach nodes b c → Reach nodes a c

theorem reachable_decreases (s : State) {a b : Nat} (path : Reach s.nodes a b) :
    height s.nodes b < height s.nodes a := by
  induction path with
  | edge i r c route member => exact (route_rank_decreases s i r route c member).2
  | trans _ _ hab hbc => exact Nat.lt_trans hbc hab

theorem graph_acyclic (s : State) (node : Nat) : ¬ Reach s.nodes node node := by
  intro path
  exact (Nat.lt_irrefl (height s.nodes node)) (reachable_decreases s path)
theorem publication_has_current_children (nodes : Array Node) (n : Node)
    (p : Publication) (route : Route) (hp : n.domain.published = some p)
    (hr : n.route = some route) (valid : publicationValid nodes n = true) :
    ∃ input, n.support = some input ∧ input.scope = n.domain.scope ∧
      input.route = route ∧ input.candidate = p.candidate ∧
      childResults nodes route = some input.children := by
  cases hs : n.support with
  | none => simp [publicationValid, hp, hr, hs] at valid
  | some input =>
    refine ⟨input, rfl, ?_⟩
    have both : scopeUsable nodes n.domain.scope = true ∧
        (input.scope = n.domain.scope ∧ input.route = route ∧ input.candidate = p.candidate ∧
          childResults nodes route = some input.children) := by
      simpa only [publicationValid, hp, hr, hs, Bool.and_eq_true, decide_eq_true_eq] using valid
    exact both.2

theorem composed_result_has_current_children (s : State) (i : Fin s.nodes.size)
    (p : Publication) (route : Route) (hp : s.nodes[i].domain.published = some p)
    (hr : s.nodes[i].route = some route) :
    ∃ input, s.nodes[i].support = some input ∧ input.scope = s.nodes[i].domain.scope ∧
      input.route = route ∧ input.candidate = p.candidate ∧
      childResults s.nodes route = some input.children :=
  publication_has_current_children _ _ _ _ hp hr (s.integrity.2 i).2.2.1

theorem worker_cannot_install_refinement (nodes : Array Node) (node serial : Nat)
    (target : Node) (owner id evidence : String) (verdict : RefinementVerdict)
    (existsNode : nodes[node]? = some target) :
    runGraph nodes ⟨id, .worker owner, .finishRefinement serial verdict evidence, node⟩ =
      .error .forbidden := by
  simp [runGraph, existsNode]
  rfl

theorem worker_cannot_compose (nodes : Array Node) (node : Nat) (target : Node)
    (owner id evidence : String) (input : Composition) (verdict : Verdict)
    (existsNode : nodes[node]? = some target) :
    runGraph nodes ⟨id, .worker owner, .compose input verdict evidence, node⟩ =
      .error .forbidden := by
  simp [runGraph, existsNode]
  rfl

theorem composition_requires_checked_output (nodes after : Array Node) (node : Nat)
    (input : Composition) (verdict : Verdict)
    (accepted : composeNode nodes node input verdict = .ok (after, .composed)) :
    canCompose nodes node input = true ∧ ∃ output, verdict = .passed output ∧
      output.scope = input.scope ∧ output.candidate = input.candidate ∧
      output.product.isEmpty = false ∧ output.receipt.isEmpty = false := by
  by_cases ready : canCompose nodes node input = true
  · refine ⟨ready, ?_⟩
    cases hn : nodes[node]? with
    | none => simp [composeNode, ready, hn] at accepted
    | some target =>
      cases verdict with
      | rejected reason => simp [composeNode, ready, hn, pure, Except.pure] at accepted
      | unknown reason => simp [composeNode, ready, hn, pure, Except.pure] at accepted
      | passed output =>
        by_cases invalid : output.scope ≠ input.scope ∨ output.candidate ≠ input.candidate ∨
            output.product.isEmpty = true ∨ output.receipt.isEmpty = true
        · simp at invalid
          simp [composeNode, ready, hn, invalid, pure, Except.pure] at accepted
        · refine ⟨output, rfl, ?_⟩
          simpa only [not_or, ne_eq, Decidable.not_not, Bool.not_eq_true] using invalid
  · simp [composeNode, ready, pure, Except.pure] at accepted

end Axiward
