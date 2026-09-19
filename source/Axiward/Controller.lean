import Axiward.Refinement
import Axiward.FlowIO

namespace Axiward.Controller

open Lean System

/-- The allocation record remains available after completion, allowing a submit
    retry to recover its assigned action without reviving the old package. -/
def submissionAction (s : State) (node serial : Nat) : Option Action := do
  let entry ← s.journal.entries.find? (fun e =>
    e.request.node == node && e.reply == .acquired serial)
  match entry.request.command with
  | .begin _ action => some action
  | _ => none

private def recordedCheckIn (repo : FilePath) (loaded : Git.Loaded) (id : String)
    (node serial : Nat) : IO (Option Reply) := do
  if let some entry := loaded.state.journal.entries.find? (fun e => e.request.id == id) then
    unless entry.request.node == node && entry.request.actor == .controller do
      throw (IO.userError "request ID conflict")
    match entry.request.command with
    | .finish ticket _ _ | .finishRefinement ticket _ _ | .integrate ticket _ _
    | .archive ticket _ _
    | .workflow (.prepare ticket _) | .workflow (.ask ticket _) | .workflow (.reject ticket _) =>
      unless ticket == serial do throw (IO.userError "request ID conflict")
      Git.synchronize repo
      return some entry.reply
    | _ => throw (IO.userError "request ID conflict")
  return none

def recordedCheck (repo : FilePath) (id : String) (node serial : Nat) : IO (Option Reply) := do
  recordedCheckIn repo (← Git.load repo) id node serial

/-- Admission is bound to the exact formal commit used for merging and checking.
    A competing commit requires a fresh check, never replay of the old verdict. -/
def commitChecked (repo : FilePath) (loaded : Git.Loaded) (request : Request) : IO Reply := do
  let change ← Git.decode ((step loaded.state request).mapError (fun e => s!"{repr e}"))
  unless ← Git.commitChange repo loaded change do
    throw (IO.userError "formal state changed during verification; resume to merge and verify the latest snapshot")
  return change.reply

def checkMerged (repo : FilePath) (loaded : Git.Loaded) (node serial : Nat)
    (scope : Scope) (submitted : Candidate) (reuse : Option CheckedReuse := none) :
    IO (MergeCheck × String) := do
  let base := packageSource loaded.state.journal.entries node serial loaded.state.journal.initialSource
  let current := sourceAt loaded.state.journal.entries loaded.state.journal.initialSource
  let proposed := reuse.map (·.source.candidate) |>.getD submitted
  let merged ← Git.mergeSource repo base current proposed
  let candidate : Candidate := ⟨merged.tree⟩
  let required := requiredResults loaded.state.nodes
  let binding ← Git.hashText repo (Json.mkObj [
    ("head", toJson loaded.head), ("base", toJson base), ("current", toJson current),
    ("submitted", toJson submitted), ("proposed", toJson proposed), ("merged", toJson candidate),
    ("required", toJson required), ("clean", toJson merged.clean), ("report", toJson merged.report)]).compress
  let initial : MergeCheck := ⟨base, current, submitted, candidate, [],
    .rejected "source conflict; start a new package from the current HEAD", reuse⟩
  unless merged.clean do
    return (initial, ← Git.tree repo none #[⟨"merge.json", binding⟩] #[("conflict", candidate.tree)])
  -- The frozen acceptance package checks the union of current guarantees. It does not
  -- add obligations belonging only to unfinished goals.
  let scopes := scope :: required.map (·.publication.scope)
  let mut claims : List Nat := []
  for input in scopes do claims := (claims ++ (← Policy.readClaims repo input.policy)).eraseDups
  let joint ← Policy.restrictScope repo loaded.state.domain.scope claims
  unless scopes.all (fun input => compatible input joint) do
    throw (IO.userError "combined verifier scope does not cover the required guarantees")
  let result ← Verifier.check repo joint candidate
  let evidence ← Git.tree repo none #[⟨"merge.json", binding⟩]
    #[("verification", result.evidence), ("merged", candidate.tree)]
  match result.verdict with
  | .passed output =>
    let project (goal : Scope) : IO CheckedOutput := do
      if goal == joint then return output
      let receipt ← Git.hashText repo (Json.mkObj [
        ("kind", toJson "joint-verification"), ("scope", toJson goal), ("candidate", toJson candidate),
        ("product", toJson output.product), ("verificationScope", toJson joint),
        ("verificationReceipt", toJson output.receipt)]).compress
      return ⟨goal, candidate, output.product, receipt⟩
    let rechecked ← required.mapM fun previous => do
      return (⟨previous, ← project previous.publication.scope⟩ : Rechecked)
    let admitted ← project scope
    let receipts := #[⟨"receipt.json", admitted.receipt⟩] ++ rechecked.toArray.map
      (fun r => (⟨s!"receipts/{r.previous.node}.json", r.output.receipt⟩ : Git.Blob))
    let evidence ← Git.tree repo (some evidence) receipts #[("product", output.product)]
    return ({ initial with verdict := .passed admitted, rechecked }, evidence)
  | verdict => return ({ initial with verdict }, evidence)

/-- Persist a completed check, retaining its evidence even if the package ended
    while the external verifier was running. -/
def recordCheck (repo : FilePath) (id : String) (node serial : Nat)
    (candidate : Candidate) (command : Axiward.Command) (checkedAt : Option Git.Loaded := none) : IO Reply := do
  try
    match checkedAt with
    | some loaded => commitChecked repo loaded ⟨id, .controller, command, node⟩
    | none =>
      if let .integrate _ _ _ := command then throw (IO.userError "merged check requires its exact input commit")
      Git.transact repo ⟨id, .controller, command, node⟩
  catch error =>
    match ← recordedCheck repo id node serial with
    | some reply => return reply
    | none =>
      let current ← Git.load repo
      if current.state.nodes[node]?.any (fun n => n.domain.active.any (fun p => p.serial == serial)) then
        throw error
      let raw ← Git.hashText repo (toJson command).compress
      let mut trees : Array (String × String) := #[]
      let mut blobs : Array Git.Blob := #[⟨"late-result.json", raw⟩]
      match command with
      | .integrate _ _ evidence => trees := trees.push ("check", evidence)
      | .finish _ verdict evidence =>
        trees := trees.push ("check", evidence)
        if let .passed output := verdict then
          trees := trees.push ("product", output.product)
          blobs := blobs.push ⟨"receipt.json", output.receipt⟩
      | .finishRefinement _ _ evidence => trees := trees.push ("check", evidence)
      | _ => pure ()
      let evidence ← Git.tree repo none blobs trees
      Git.transact repo ⟨id, .controller, .archive serial candidate evidence, node⟩


def check (repo : FilePath) (id : String) (node serial : Nat) : IO Reply := do
  let loaded ← Git.load repo
  if let some reply ← recordedCheckIn repo loaded id node serial then return reply
  if loaded.state.domain.workflow.paused then throw (IO.userError "project paused; submission retained for resume")
  let some target := loaded.state.nodes[node]? | throw (IO.userError "unknown node")
  let some package := target.domain.active | throw (IO.userError "no active package")
  unless package.serial == serial do throw (IO.userError "wrong package")
  let .checking candidate := package.phase | throw (IO.userError "no sealed submission")
  let stale := decide (package.input ≠ target.domain.scope) || !scopeUsable loaded.state.nodes target.domain.scope
  let staleEvidence ← if stale then do
      let blob ← Git.hashText repo (Json.mkObj [("input", toJson package.input),
        ("current", toJson target.domain.scope), ("reason", toJson "root requirements changed")]).compress
      Git.tree repo none #[⟨"stale.json", blob⟩]
    else pure ""
  let command : Axiward.Command ← match package.action with
    | .execute => do
      if stale then pure (.finish serial (.rejected "root requirements changed") staleEvidence) else do
        let (result, evidence) ← checkMerged repo loaded node serial target.domain.scope candidate
        pure (.integrate serial result evidence)
    | .refine => do
      if stale then pure (.finishRefinement serial (.rejected "root requirements changed") staleEvidence) else do
        let result ← Refinement.check repo target.domain.scope candidate loaded.state
        match result.verdict with
        | .reused reuse =>
          let (checked, evidence) ← checkMerged repo loaded node serial target.domain.scope candidate (some reuse)
          let combined ← Git.tree repo none #[] #[("reuse", result.evidence), ("merge", evidence)]
          pure (.integrate serial checked combined)
        | _ => pure (Command.finishRefinement serial result.verdict result.evidence)
    | .explore | .requestDecision => do
      pure (.workflow (← FlowIO.check repo target.domain.scope package candidate (!stale)))
  recordCheck repo id node serial candidate command (some loaded)


def compositionIdentity (repo : FilePath) (scope : Scope) (route : Route)
    (children : List ChildResult) : IO String :=
  Git.hashText repo (Json.mkObj [("scope", toJson scope), ("route", toJson route),
    ("children", toJson children)]).compress

def matchesComposition (entry : Entry) (node : Nat) (scope : Scope) (route : Route)
    (children : List ChildResult) : Bool :=
  entry.request.actor == .controller && entry.request.node == node &&
  match entry.request.command with
  | .compose input _ _ => input.scope == scope && input.route == route && input.children == children
  | _ => false

def compose (repo : FilePath) (node : Nat) (requestId : Option String := none)
    (initial : Option Git.Loaded := none) : IO Reply := do
  let loaded ← match initial with | some loaded => pure loaded | none => Git.load repo
  if loaded.state.domain.workflow.paused then throw (IO.userError "project paused; composition pending")
  let some target := loaded.state.nodes[node]? | throw (IO.userError "unknown node")
  let some route := target.route | throw (IO.userError "no refinement route")
  let some children := childResults loaded.state.nodes route | throw (IO.userError "children are not closed")
  let id := requestId.getD ("compose-" ++ (← compositionIdentity repo target.domain.scope route children))
  if let some entry := loaded.state.journal.entries.find? (fun e => e.request.id == id) then
    unless matchesComposition entry node target.domain.scope route children do
      throw (IO.userError "request ID conflict")
    Git.synchronize repo
    return entry.reply
  unless target.domain.active.isNone && target.domain.published.isNone do
    throw (IO.userError "parent is occupied or already closed")
  unless scopeUsable loaded.state.nodes target.domain.scope do
    throw (IO.userError "parent depends on obsolete requirements")
  let (candidate, verdict, evidence) ← try
    let some candidate := sourceAt loaded.state.journal.entries loaded.state.journal.initialSource
      | throw (IO.userError "no admitted shared source")
    let result ← Verifier.check repo target.domain.scope candidate
    pure (candidate, result.verdict, result.evidence)
  catch error =>
    let binding ← Git.hashText repo (Json.mkObj [("scope", toJson target.domain.scope),
      ("route", toJson route), ("children", toJson children), ("error", toJson error.toString)]).compress
    let evidence ← Git.tree repo none #[⟨"assembly-error.json", binding⟩]
    pure (⟨""⟩, Verdict.rejected error.toString, evidence)
  let input : Composition := ⟨target.domain.scope, route, children, candidate⟩
  try commitChecked repo loaded ⟨id, .controller, .compose input verdict evidence, node⟩
  catch error =>
    let current ← Git.load repo
    if let some entry := current.state.journal.entries.find? (fun e => e.request.id == id) then
      unless matchesComposition entry node target.domain.scope route children do throw error
      Git.synchronize repo
      return entry.reply
    throw error

/-- Automatically propagates available proofs upward. Failed bindings are retained
    and are not retried without a new route or changed child results. -/
def propagate (repo : FilePath) : IO (List Nat) := do
  let initial ← Git.load repo
  if initial.state.domain.workflow.paused then return []
  let mut loaded := initial
  let mut completed := []
  for _ in [:initial.state.nodes.size] do
    let mut next : Option Nat := none
    for (target, node) in loaded.state.nodes.toList.zipIdx do
      if next.isSome || target.domain.active.isSome || target.domain.published.isSome ||
          !scopeUsable loaded.state.nodes target.domain.scope then continue
      let some route := target.route | continue
      let some children := childResults loaded.state.nodes route | continue
      let id := "compose-" ++ (← compositionIdentity repo target.domain.scope route children)
      match loaded.state.journal.entries.find? (fun e => e.request.id == id) with
      | none => next := some node
      | some entry =>
        unless matchesComposition entry node target.domain.scope route children do
          throw (IO.userError "automatic composition request ID conflict")
    let some node := next | break
    match ← compose repo node (initial := some loaded) with
    | .composed => completed := completed ++ [node]
    | _ => pure ()
    loaded ← Git.load repo
  return completed

def invalidatedPackages (s : State) : Json :=
  toJson ((obsoletePackages s).map fun (node, p, reason) => Json.mkObj [
    ("node", toJson node), ("serial", toJson p.serial), ("owner", toJson p.owner),
    ("reason", toJson reason),
    ("next", toJson "Discussion agent: stop this owner's Codex worker, then use reclaim to cancel this package. Settle registered operations separately.")])

def revisionImpact (before after : State) : Json := Id.run do
  let previous := before.domain.scope.requirements
  let current := after.domain.scope.requirements
  let changed := ((previous.filter (fun r => !current.contains r)) ++
    (current.filter (fun r => !previous.contains r))).map (·.id) |>.eraseDups
  let mut invalidated : List Nat := []
  let mut retained : List Nat := []
  let mut obsolete : List Nat := []
  let mut stalePackages : List Nat := []
  for (node, id) in after.nodes.toList.zipIdx do
    let old := before.nodes[id]?.bind (·.domain.published)
    if old.isSome && node.domain.published.isNone then invalidated := invalidated ++ [id]
    if old.isSome && old == node.domain.published then retained := retained ++ [id]
    unless scopeUsable after.nodes node.domain.scope do obsolete := obsolete ++ [id]
    if node.domain.active.any (fun p => decide (p.input ≠ node.domain.scope) ||
        !scopeUsable after.nodes node.domain.scope) then stalePackages := stalePackages ++ [id]
  return Json.mkObj [("beforeRevision", toJson before.domain.scope.revision),
    ("afterRevision", toJson after.domain.scope.revision), ("changedRequirements", toJson changed),
    ("invalidatedResults", toJson invalidated), ("retainedResults", toJson retained),
    ("obsoleteGoals", toJson obsolete), ("stalePackages", toJson stalePackages),
    ("invalidatedPackages", invalidatedPackages after)]

def revisionToken (repo : FilePath) (expected replacement : Scope) : IO String :=
  Git.hashText repo (Json.mkObj [("expected", toJson expected), ("replacement", toJson replacement)]).compress

def revisionRequest (repo : FilePath) (id : String) (directory : FilePath)
    (approvedBase : Option String) : IO (Git.Loaded × Request) := do
  let loaded ← Git.load repo
  if let some entry := loaded.state.journal.entries.find? (fun e => e.request.id == id) then
    unless entry.request.actor == .user && entry.request.node == 0 do throw (IO.userError "request ID conflict")
    let .revise expected replacement := entry.request.command | throw (IO.userError "request ID conflict")
    if let some approved := approvedBase then
      unless approved == (← revisionToken repo expected replacement) do throw (IO.userError "request ID conflict")
    let config ← Git.resolve repo s!"{replacement.policy}:controller-toolchain.json"
    let proposed ← Verifier.importPolicyWithConfig repo directory config
    unless sameGoal proposed replacement do throw (IO.userError "request ID conflict")
    return (loaded, entry.request)
  let current := loaded.state.domain.scope
  let config ← Git.resolve repo s!"{current.policy}:controller-toolchain.json"
  let replacement ← Verifier.importPolicyWithConfig repo directory config
  if let some approved := approvedBase then
    unless approved == (← revisionToken repo current replacement) do
      throw (IO.userError "reviewed change no longer matches the root or proposed specification; preview again")
  return (loaded, ⟨id, .user, .revise current replacement, 0⟩)

/-- Preview runs the same pure transition as application. Only the user entry
    commits it; the affected-node list is computed, never supplied by a model. -/
def revision (repo : FilePath) (id : String) (directory : FilePath)
    (approvedBase : Option String := none) : IO Json := do
  let (loaded, request) ← revisionRequest repo id directory approvedBase
  let .revise expected replacement := request.command | throw (IO.userError "not a revision request")
  let versions := Json.mkObj [
    ("expectedScope", toJson expected), ("replacementScope", toJson replacement),
    ("expectedAcceptance", toJson (← Policy.readManifest repo expected.policy)),
    ("replacementAcceptance", toJson (← Policy.readManifest repo replacement.policy))]
  let preview ← Git.decode ((step loaded.state request).mapError (fun e => s!"{repr e}"))
  let impact := revisionImpact loaded.state preview.after
  if approvedBase.isSome then
    let committed ← Git.transactDetailed repo request (some loaded)
    let actualImpact := if committed.change.changed then
      revisionImpact committed.before.state committed.change.after else Json.null
    return Json.mkObj [("applied", toJson true), ("reply", toJson committed.change.reply),
      ("alreadyApplied", toJson (!committed.change.changed)), ("versions", versions), ("impact", actualImpact)]
  return Json.mkObj [("applied", toJson false), ("alreadyApplied", toJson (!preview.changed)),
    ("baseCommit", toJson loaded.head), ("versions", versions),
    ("reviewToken", toJson (← revisionToken repo expected replacement)),
    ("confirmation", toJson "User must confirm both specification meaning and formal acceptance materials before applying this token."),
    ("impact", if preview.changed then impact else Json.null)]

end Axiward.Controller
