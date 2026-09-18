import Lean.Data.Json

namespace Axiward

open Lean

structure Requirement where
  id : String
  version : String
  deriving Repr, BEq, ReflBEq, LawfulBEq, DecidableEq, ToJson, FromJson

def validRequirements (requirements : List Requirement) : Bool :=
  requirements.all (fun r => !r.id.isEmpty && !r.version.isEmpty) &&
  (requirements.map (·.id)).eraseDups.length == requirements.length

/-- Content addresses name immutable objects in the protected Git object store. -/
structure Scope where
  revision : Nat
  specification : String
  policy : String
  requirements : List Requirement
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

def compatible (subject current : Scope) : Bool :=
  subject.requirements.all (fun r => decide (r ∈ current.requirements))

theorem compatible_iff (subject current : Scope) : compatible subject current = true ↔
    ∀ r ∈ subject.requirements, r ∈ current.requirements := by
  simp [compatible, List.all_eq_true]

def sameGoal (a b : Scope) : Bool :=
  decide (a.specification = b.specification ∧ a.policy = b.policy ∧ a.requirements = b.requirements)

structure Candidate where
  tree : String
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

inductive Action where
  | execute
  | refine
  | explore
  | requestDecision
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

inductive Phase where
  | drafting
  | checking (candidate : Candidate)
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

structure Package where
  serial : Nat
  owner : String
  input : Scope
  phase : Phase
  action : Action
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

/-- Only the controller's verifier adapter supplies this value to `finish`. -/
structure CheckedOutput where
  scope : Scope
  candidate : Candidate
  product : String
  receipt : String
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

inductive Verdict where
  | passed (output : CheckedOutput)
  | rejected (reason : String)
  | unknown (reason : String)
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

structure Publication where
  scope : Scope
  candidate : Candidate
  product : String
  receipt : String
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

structure ChildGoal where
  node : Nat
  scope : Scope
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

inductive ChildTarget where
  | fresh (scope : Scope)
  | reuse (goal : ChildGoal)
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

structure CheckedRefinement where
  scope : Scope
  candidate : Candidate
  children : List ChildTarget
  certificate : String
  implementation : Option Nat
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

structure CheckedReuse where
  scope : Scope
  proposal : Candidate
  sourceNode : Nat
  source : Publication
  receipt : String
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

inductive RefinementVerdict where
  | passed (output : CheckedRefinement)
  | reused (output : CheckedReuse)
  | rejected (reason : String)
  | unknown (reason : String)
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

structure Route where
  scope : Scope
  candidate : Candidate
  children : List ChildGoal
  certificate : String
  implementation : Option Nat
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

structure ChildResult where
  node : Nat
  publication : Publication
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

structure Composition where
  scope : Scope
  route : Route
  children : List ChildResult
  candidate : Candidate
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

/-- R0 exploration can evaluate immutable candidates with the registered checker.
    All outputs remain observations; the contract never authorizes publication. -/
structure ExplorePlan where
  question : String
  maxRuns : Nat
  stopWhen : String
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

structure Exploration where
  serial : Nat
  input : Scope
  candidate : Candidate
  plan : ExplorePlan
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

structure Operation where
  id : String
  serial : Nat
  input : Scope
  candidate : Candidate
  result : Option Verdict := none
  evidence : String := ""
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

structure DecisionOption where
  key : String
  label : String
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

/-- The only R0 question effect is a version-bound user preference. Root changes
    continue to use the separate reviewed revision command. -/
structure Question where
  prompt : String
  subject : String
  options : List DecisionOption
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

structure Answer where
  choice : String
  comment : String
  applicable : Bool
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

structure Decision where
  serial : Nat
  owner : String
  input : Scope
  candidate : Candidate
  question : Question
  answer : Option Answer := none
  acknowledged : Bool := false
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

structure WorkflowState where
  paused : Bool := false
  pauseReason : String := ""
  deniedResources : List String := []
  explorations : List Exploration := []
  operations : List Operation := []
  decisions : List Decision := []
  reports : List (Nat × String) := []
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

inductive WorkflowCommand where
  | reject (serial : Nat) (reason : String)
  | prepare (serial : Nat) (plan : ExplorePlan)
  | launch (serial : Nat) (operationId : String) (candidate : Candidate)
  | observe (operationId : String) (result : Verdict) (evidence : String)
  | conclude (serial : Nat) (report : String)
  | ask (serial : Nat) (question : Question)
  | answer (serial : Nat) (choice comment : String)
  | acknowledge (serial : Nat)
  | pause (paused : Bool) (reason : String)
  | access (resource : String) (allowed : Bool)
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

structure Domain where
  scope : Scope
  nextSerial : Nat := 0
  active : Option Package := none
  published : Option Publication := none
  workflow : WorkflowState := {}
  deriving Repr, BEq, DecidableEq, ToJson

inductive Actor where
  | controller
  | worker (identity : String)
  | user
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

inductive Command where
  | begin (owner : String) (action : Action)
  | submit (serial : Nat) (candidate : Candidate)
  | finish (serial : Nat) (verdict : Verdict) (evidenceTree : String)
  | cancel (serial : Nat) (reason : String)
  | revise (expected replacement : Scope)
  | finishRefinement (serial : Nat) (verdict : RefinementVerdict) (evidenceTree : String)
  | compose (input : Composition) (verdict : Verdict) (evidenceTree : String)
  | workflow (command : WorkflowCommand)
  | archive (serial : Nat) (candidate : Candidate) (evidenceTree : String)
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

inductive Reply where
  | acquired (serial : Nat)
  | sealed (serial : Nat)
  | accepted (serial : Nat)
  | rejected (serial : Nat) (reason : String)
  | unresolved (serial : Nat) (reason : String)
  | cancelled (serial : Nat) (reason : String)
  | revised (revision : Nat)
  | refined (serial : Nat) (children : List Nat)
  | reused (serial : Nat) (sourceReceipt : String)
  | composed
  | compositionFailed (reason : String)
  | prepared (serial : Nat)
  | launched (operationId : String)
  | observed (operationId : String)
  | explored (serial : Nat)
  | waitingUser (serial : Nat)
  | answered (serial : Nat) (applicable : Bool)
  | acknowledged (serial : Nat)
  | paused (value : Bool)
  | accessChanged (resource : String)
  | archived (serial : Nat)
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

inductive Fault where
  | forbidden
  | occupied
  | closed
  | wrongPackage
  | wrongPhase
  | invalidInput
  | requestConflict
  | wrongNode
  | wrongAction
  | dependenciesOpen
  | invalidGraph
  | obsoleteScope
  | staleRevision
  | paused
  | budgetExhausted
  | operationsPending
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

/-- Actor is supplied by the trusted entry point, never parsed from worker JSON.
    Its JSON instance is for the protected journal only. -/
structure Request where
  id : String
  actor : Actor
  command : Command
  node : Nat
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

structure Entry where
  request : Request
  reply : Reply
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

/-- Only successful admissions can serve as historical reuse evidence. -/
def admittedPublication (entry : Entry) : Option Publication :=
  match entry.request.actor, entry.request.command, entry.reply with
  | .controller, .finish _ (.passed output) _, .accepted _
  | .controller, .compose _ (.passed output) _, .composed =>
    some ⟨output.scope, output.candidate, output.product, output.receipt⟩
  | .controller, .finishRefinement _ (.reused output) _, .reused _ _ =>
    some ⟨output.scope, output.source.candidate, output.source.product, output.receipt⟩
  | _, _, _ => none

def priorAdmission (history : List Entry) (node : Nat) (publication : Publication) : Bool :=
  history.any (fun entry => decide (entry.request.node = node ∧ admittedPublication entry = some publication))

theorem priorAdmission_iff (history : List Entry) (node : Nat) (publication : Publication) :
    priorAdmission history node publication = true ↔
      ∃ entry ∈ history, entry.request.node = node ∧ admittedPublication entry = some publication := by
  simp [priorAdmission, List.any_eq_true]

structure Journal where
  schema : Nat := 3
  initial : Scope
  entries : List Entry := []
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

/-- Current results match the current scope; occupancy and closure cannot overlap;
    every active package uses an already allocated, non-reusable serial. -/
def Integrity (s : Domain) : Prop :=
  (s.active = none ∨ s.published = none) ∧
  (∀ p, s.published = some p → p.scope = s.scope) ∧
  (∀ p, s.active = some p → p.serial < s.nextSerial)

def initialDomain (scope : Scope) : Domain := { scope }

def isClosed (s : Domain) : Bool := s.published.isSome

end Axiward
