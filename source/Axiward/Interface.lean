import Axiward.Controller
import Axiward.Diagnostics

namespace Axiward.Interface

open Lean System

def phaseName (d : Domain) : String :=
  match d.active with
  | none => "ended"
  | some p =>
    if d.workflow.decisions.any (fun q => q.serial == p.serial && q.answer.isNone) then "waiting-user"
    else if d.workflow.explorations.any (fun e => e.serial == p.serial) then "exploring"
    else match p.phase with | .drafting => "drafting" | .checking _ => "checking"

def mapNode (s : State) (id : Nat) (n : Node) : Json :=
  Json.mkObj [("node", toJson id), ("requirements", toJson (n.domain.scope.requirements.map (·.id))),
    ("current", toJson (scopeUsable s.nodes n.domain.scope)),
    ("closed", toJson n.domain.published.isSome), ("package", toJson n.domain.active),
    ("phase", toJson (phaseName n.domain)),
    ("children", toJson (n.route.toList.flatMap (fun r => r.children.map (·.node))))]

def status (loaded : Git.Loaded) : Json :=
  Json.mkObj [("head", toJson loaded.head), ("complete", toJson (complete loaded.state)),
    ("scope", toJson loaded.state.domain.scope),
    ("rootClosed", toJson loaded.state.domain.published.isSome),
    ("paused", toJson loaded.state.domain.workflow.paused),
    ("pauseReason", toJson loaded.state.domain.workflow.pauseReason),
    ("pendingOperations", toJson (pendingOperations loaded.state)),
    ("invalidatedPackages", Controller.invalidatedPackages loaded.state),
    ("map", toJson (loaded.state.nodes.toList.zipIdx.map (fun (n, id) => mapNode loaded.state id n))),
    ("transitions", toJson loaded.state.journal.entries.length)]

def allocated (s : State) (node serial : Nat) : Option Package := do
  let entry ← s.journal.entries.find? (fun e => e.request.node == node && e.reply == .acquired serial)
  let entries := s.journal.entries.takeWhile (· != entry) ++ [entry]
  let snapshot ← (restore { s.journal with entries }).toOption
  let target ← snapshot.nodes[node]?
  -- Replay the actual allocation prefix so acceptance and input never follow a
  -- later specification change in the current project state.
  target.domain.active

/-- The session identity reserves one workspace for exactly one
    allocation. The journal, rather than a writable workspace marker, binds it. -/
def sessionPackage (s : State) (owner : String) : Option (Nat × Nat) := do
  let entry ← s.journal.entries.find? (fun e => match e.request.command with
    | .begin worker _ => worker == owner
    | _ => false)
  let .acquired serial := entry.reply | none
  return (entry.request.node, serial)

def packageSnapshot (repo : FilePath) (loaded : Git.Loaded) (node serial : Nat) : IO String := do
  let some event := loaded.state.journal.entries.find? (fun e => e.request.node == node && e.reply == .acquired serial)
    | throw (IO.userError "unknown allocation")
  let position := (loaded.state.journal.entries.takeWhile (· != event)).length + 1
  -- Transition numbers are hints only; verify the matching journal before use.
  let commits ← Git.checked repo #["log", "--first-parent", "--format=%H",
    s!"--grep=^Axiward transition {position}$", loaded.head]
  for head in commits.splitOn "\n" do
    if head.isEmpty then continue
    let oid ← Git.resolve repo s!"{head}:.axiward/state.json"
    let journal : Journal ← Git.decode (fromJson? (← Git.decode (Json.parse (← Git.readBlob repo oid))))
    if journal.entries.length == position && journal.entries.getLast? == some event then return head
  throw (IO.userError "allocation snapshot missing")

def readable (current : State) (id : String) : Bool :=
  let base := if id.startsWith "current/" then String.ofList (id.toList.drop 8) else id
  !current.domain.workflow.deniedResources.any (fun denied =>
    id == denied || id.startsWith (denied ++ "/") || base == denied || base.startsWith (denied ++ "/"))

def acceptanceReadable (current : State) (node : Nat) (resourcePrefix : String := "") : Bool :=
  readable current s!"{resourcePrefix}node/{node}/acceptance" &&
    readable current s!"{resourcePrefix}node/{node}/material/acceptance.json"

def specificationReadable (current : State) (node : Nat) (path : String) : Bool :=
  readable current s!"node/{node}/spec" && readable current s!"node/{node}/material/{path}"

def packageInfo (repo : FilePath) (owner : String) (node serial : Nat) : IO Json := do
  let loaded ← Git.load repo
  let some p := allocated loaded.state node serial | throw (IO.userError "unknown allocation")
  unless p.owner == owner do throw (IO.userError "wrong worker")
  unless sessionPackage loaded.state owner == some (node, serial) do
    throw (IO.userError "workspace is bound to another package")
  let some n := loaded.state.nodes[node]? | throw (IO.userError "unknown node")
  let acceptance ← if acceptanceReadable loaded.state node then do
      pure (toJson (← Policy.readManifest repo p.input.policy))
    else pure Json.null
  return Json.mkObj [("domain", toJson n.domain), ("action", toJson p.action),
    ("input", toJson p.input), ("acceptance", acceptance)]

def snapshotState (repo : FilePath) (head : String) : IO State := do
  let oid ← Git.resolve repo s!"{head}:.axiward/state.json"
  let journal : Journal ← Git.decode (fromJson? (← Git.decode (Json.parse (← Git.readBlob repo oid))))
  Git.decode (restore journal)

structure Resource where
  id : String
  description : String
  content : String
  deriving ToJson

/-- Follow actual route dependencies, including reused children. The graph is
    finite and acyclic; this also works for an allocation's immutable snapshot. -/
def dependencies (s : State) (node : Nat) : List Nat := Id.run do
  let mut seen := [node]
  for _ in [:s.nodes.size] do
    for id in seen do
      if let some n := s.nodes[id]? then
        seen := (seen ++ n.route.toList.flatMap (fun r => r.children.map (·.node))).eraseDups
  return seen

def packageContextNodes (current snapshot : State) (node : Nat) : List Nat :=
  ([node] ++ (currentNodes current.nodes).filter (fun parent => (dependencies current parent).contains node) ++
    dependencies current node ++ dependencies snapshot node).eraseDups

def dependenciesCurrent (s : State) (node : Nat) : Bool :=
  (dependencies s node).all fun id => s.nodes[id]?.any fun n =>
    scopeUsable s.nodes n.domain.scope && n.route.all (fun r => r.children.all fun child =>
      s.nodes[child.node]?.any (fun dependency => dependency.domain.scope == child.scope))

def decisionContext (s : State) (node : Nat) (n : Node) (q : Decision) : Json :=
  let current := q.input == n.domain.scope && scopeUsable s.nodes q.input && dependenciesCurrent s node
  let applicable := current && q.answer.any (fun a => a.applicable &&
    q.question.options.any (fun option => option.key == a.choice))
  let pending := q.answer.isNone && n.domain.active.any (fun p => p.serial == q.serial)
  Json.mkObj [("node", toJson node), ("serial", toJson q.serial),
    ("sourceOwner", toJson q.owner), ("scope", toJson q.input),
    ("question", toJson q.question), ("candidate", toJson q.candidate),
    ("answer", toJson (q.answer.map (fun a => Json.mkObj [
      ("choice", toJson a.choice), ("comment", toJson a.comment)]))),
    ("recordedApplicable", toJson (q.answer.map (·.applicable))),
    ("applicableNow", toJson applicable), ("pending", toJson pending),
    ("effect", toJson "Preference for the recorded node and scope only; displaying it grants no new authority."),
    ("reason", toJson (if !current then "scope or requirement dependency changed; historical context only"
      else if applicable then "current preference for the recorded scope"
      else if pending then "awaiting the independent user channel"
      else "not an applicable instruction; historical input only"))]

def commandSerial : Axiward.Command → Option Nat
  | .submit serial _ | .finish serial _ _ | .finishRefinement serial _ _
  | .cancel serial _ | .archive serial _ _ | .integrate serial _ _ => some serial
  | .workflow (.reject serial _) | .workflow (.prepare serial _)
  | .workflow (.launch serial _ _) | .workflow (.conclude serial _)
  | .workflow (.ask serial _) | .workflow (.answer serial _ _) => some serial
  | _ => none

/-- Preserve every formal attempt's outcome and reason, without embedding raw
    logs or treating a past answer's admission result as a current instruction. -/
def attempts (s : State) (node : Nat) (snapshot : Option State) : List Json :=
  let history := s.journal.entries.filter (fun e => e.request.node == node)
  let packages := history.filterMap fun allocation => do
    let .acquired serial := allocation.reply | none
    let .begin owner action := allocation.request.command | none
    let events := history.filterMap fun e =>
      if commandSerial e.request.command != some serial then none else
      let details := match e.request.command with
        | .submit _ candidate => [("candidate", toJson candidate),
            ("candidateResource", toJson s!"node/{node}/package-{serial}-candidate"),
            ("availableInInputSnapshot", toJson (snapshot.map (fun input => input.journal.entries.contains e)))]
        | .finishRefinement _ (.reused output) tree => [("evidence", toJson tree),
            ("sourceNode", toJson output.sourceNode), ("sourcePublication", toJson output.source)]
        | .finish _ _ tree | .finishRefinement _ _ tree | .archive _ _ tree | .integrate _ _ tree => [("evidence", toJson tree)]
        | .cancel _ reason => [("reason", toJson reason)]
        | .workflow (.conclude _ report) => [("report", toJson report),
            ("reportResource", toJson s!"current/node/{node}/report-{serial}")]
        | _ => []
      some (Json.mkObj ([("request", toJson e.request.id), ("recordedOutcome", toJson e.reply)] ++ details))
    return Json.mkObj [("node", toJson node), ("serial", toJson serial),
      ("owner", toJson owner), ("action", toJson action), ("events", toJson events),
      ("historyResource", toJson s!"current/node/{node}/history"),
      ("evidenceResource", toJson s!"current/node/{node}/package-{serial}-evidence")]
  let compositions := history.zipIdx.filterMap fun (e, index) => do
    let .compose input _ evidence := e.request.command | none
    return Json.mkObj [("node", toJson node), ("action", toJson "compose"),
      ("recordedOutcome", toJson e.reply), ("input", toJson input), ("evidence", toJson evidence),
      ("evidenceResource", toJson s!"current/node/{node}/composition-{index}")]
  packages ++ compositions

def nextStep (s : State) (n : Node) : String :=
  match n.domain.active with
  | none => if n.domain.published.isSome then "Current admitted result; retain its scope and receipt."
      else "Goal remains open. Choose a node and action from the project state and handoff, then request a new package."
  | some p =>
    if n.domain.workflow.operations.any (fun op => op.serial == p.serial && op.result.isNone) then
      "An operation is outstanding. Do not repeat it; recover its record or request user reconciliation."
    else if p.input != n.domain.scope || !scopeUsable s.nodes p.input then
      "The allocated input is obsolete. It cannot publish for the current goal; end the old attempt before acquiring current inputs."
    else if phaseName n.domain == "waiting-user" then
      "The owning worker may ask the registered question through the independent user channel."
    else if phaseName n.domain == "exploring" then
      "Follow the admitted exploration plan and remaining run budget, then conclude with a report."
    else match p.phase with
      | .drafting => "The owning worker prepares the assigned action's files, then submits once."
      | .checking _ => "Resume verification of the sealed candidate; changes require a new package."

/-- A projection of one loaded Git version, never a delivery/read ledger.
    Package context includes its fixed input dependencies and current ancestors;
    each decision retains its own scope instead of inheriting the target's. -/
def handoff (loaded : Git.Loaded) (input : Option (Nat × State × String) := none) : Json := Id.run do
  let s := loaded.state
  let route := currentNodes s.nodes
  let target := input.map (·.1)
  let ancestors := target.toList.flatMap fun node =>
    route.filter (fun parent => parent != node && (dependencies s parent).contains node)
  let currentDependencies := target.toList.flatMap (dependencies s)
  let inputDependencies := input.toList.flatMap (fun (node, snapshot, _) => dependencies snapshot node)
  let obligations := s.nodes.toList.zipIdx.filterMap fun (n, id) =>
    if n.domain.active.isSome || n.domain.workflow.operations.any (·.result.isNone) then some id else none
  let related := if target.isNone then (route ++ obligations).eraseDups
    else input.toList.flatMap (fun (node, snapshot, _) => packageContextNodes s snapshot node)
  let mut contexts : List Json := []
  let mut decisions : List Json := []
  let mut work : List Json := []
  let mut history : List Json := []
  let mut missing : List Json := []
  for node in related do
    let some n := s.nodes[node]? | continue
    let relation := if target.isNone then
        if route.contains node then "current-route" else "outstanding-work"
      else if target == some node then "target"
      else if ancestors.contains node then "current-ancestor"
      else if currentDependencies.contains node then "current-dependency" else "input-dependency"
    for name in ["spec", "acceptance", "claims", "goal", "route", "history"] do
      let id := s!"current/node/{node}/{name}"
      unless readable s id do
        missing := missing ++ [Json.mkObj [("resource", toJson id),
          ("reason", toJson "necessary context is inaccessible; restore access before relying on a complete handoff")]]
    let canReadScope := readable s s!"current/node/{node}/spec" && readable s s!"current/node/{node}/acceptance" && readable s s!"current/node/{node}/claims" &&
      readable s s!"current/node/{node}/goal"
    let canReadHistory := readable s s!"current/node/{node}/history"
    contexts := contexts ++ [Json.mkObj [("node", toJson node), ("relation", toJson relation),
      ("scope", if canReadScope then toJson n.domain.scope else Json.null),
      ("usable", toJson (scopeUsable s.nodes n.domain.scope)),
      ("publication", if canReadHistory then toJson n.domain.published else Json.null),
      ("route", if readable s s!"current/node/{node}/route" then toJson n.route else Json.null),
      ("package", if canReadHistory then toJson n.domain.active else Json.null),
      ("explorations", if canReadHistory then toJson n.domain.workflow.explorations else Json.null),
      ("reports", if canReadHistory then toJson (n.domain.workflow.reports.map fun (serial, blob) =>
        Json.mkObj [("serial", toJson serial), ("blob", toJson blob),
          ("resource", toJson s!"current/node/{node}/report-{serial}"),
          ("authority", toJson "model interpretation, not a verified fact")]) else Json.null),
      ("phase", toJson (phaseName n.domain)),
      ("next", toJson (nextStep s n)),
      ("inputMaterialsAvailable", toJson (input.any (fun (_, snapshot, _) => snapshot.nodes[node]?.isSome))),
      ("materials", toJson (["spec", "acceptance", "claims", "goal", "route", "history"].map (fun name => s!"node/{node}/{name}")))]]
    if canReadHistory then
      decisions := decisions ++ n.domain.workflow.decisions.map (decisionContext s node n)
      history := history ++ attempts s node (input.map (·.2.1))
      work := work ++ n.domain.workflow.operations.map (fun op => Json.mkObj [
        ("node", toJson node), ("operation", toJson op),
        ("next", toJson (if op.result.isNone then "Do not rerun. Inspect the original execution or ask the user to reconcile after it stops."
          else "Recorded observation only; it does not publish a product.")),
        ("evidenceResource", toJson s!"current/node/{node}/package-{op.serial}-evidence")])
  let frozen := input.map fun (node, snapshot, head) =>
    let n : Option Node := snapshot.nodes[node]?
    Json.mkObj [("head", toJson head), ("node", toJson node),
      ("scope", if readable s s!"node/{node}/spec" then toJson (n.map (fun (value : Node) => value.domain.scope)) else Json.null),
      ("route", if readable s s!"node/{node}/route" then toJson (n.bind (·.route)) else Json.null),
      ("dependencies", toJson inputDependencies),
      ("contexts", toJson (inputDependencies.filterMap fun id => snapshot.nodes[id]?.map fun (original : Node) =>
        Json.mkObj [("node", toJson id),
          ("scope", if readable s s!"node/{id}/spec" then toJson original.domain.scope else Json.null),
          ("publication", if readable s s!"node/{id}/history" then toJson original.domain.published else Json.null),
          ("route", if readable s s!"node/{id}/route" then toJson original.route else Json.null)])),
      ("stillCurrent", toJson (n.any (fun (original : Node) => s.nodes[node]?.any (fun (current : Node) =>
        original.domain.scope == current.domain.scope && scopeUsable s.nodes original.domain.scope))))]
  return Json.mkObj [("currentHead", toJson loaded.head), ("inputSnapshot", toJson frozen),
    ("invalidatedPackages", Controller.invalidatedPackages s),
    ("contextComplete", toJson missing.isEmpty), ("blockedByMissingContext", toJson (!missing.isEmpty)),
    ("missing", toJson missing), ("paused", toJson s.domain.workflow.paused),
    ("pauseReason", toJson s.domain.workflow.pauseReason),
    ("contexts", toJson contexts), ("decisions", toJson decisions),
    ("attempts", toJson history), ("operations", toJson work),
    ("instructions", toJson [
      "Read this handoff on every acquisition or recovery, even if a previous worker read it.",
      "If blockedByMissingContext is true, restore the necessary access before relying on this handoff to proceed.",
      "Input files and node/ materials stay at inputSnapshot.head; current/ records and currentHead describe current formal state.",
      "Only applicableNow decisions are current preferences, for their recorded node and scope; ancestor/dependency context grants no additional authority.",
      "Only the allocated owner may write to an active package. An ended attempt needs a new package for changes; resume only checks the original sealed candidate."])]

def rawEvidence (repo : FilePath) (tree : String) : IO String := do
  let names ← Git.checked repo #["ls-tree", "-r", "--name-only", tree]
  let mut records : List Json := []
  for name in names.splitOn "\n" do
    if name.endsWith ".json" || name.endsWith ".txt" then
      let oid ← Git.resolve repo s!"{tree}:{name}"
      records := records ++ [Json.mkObj [("file", toJson name), ("raw", toJson (← Git.readBlob repo oid))]]
  return (toJson records).pretty

def candidateRecords (repo : FilePath) (current : State) (node : Nat) (candidate : Candidate) : IO String := do
  let mut files : List Json := []
  let entries ← Git.checked repo #["ls-tree", "-r", "-z", candidate.tree]
  for entry in entries.splitOn "\x00" do
    let [metadata, path] := entry.splitOn "\t" | continue
    let [_, "blob", oid] := metadata.splitOn " " | continue
    if path == "submission.txt" then continue
    unless Git.safePath path do continue
    let name := (path.splitOn "/").getLast!
    -- Preserve exact old previous-file denials as well as the new package ID.
    let content ← if readable current s!"node/{node}/previous-{name}" &&
        readable current s!"node/{node}/previous-{path}" then
        pure (Json.mkObj [("raw", toJson (← Git.readBlob repo oid))])
      else pure (Json.mkObj [("unavailable", toJson "access revoked")])
    files := files ++ [Json.mkObj [("file", toJson path), ("content", content)]]
  return (toJson files).pretty

private structure FailedCheck where
  name : String
  tree : String
  submitted : Option Nat

private def failedChecks (s : State) (node : Nat) : List FailedCheck :=
  (s.journal.entries.filter (fun e => e.request.node == node)).zipIdx.filterMap fun (e, index) =>
    let failed := match e.reply with
      | .rejected _ _ | .unresolved _ _ | .compositionFailed _ | .archived _ => true
      | _ => false
    if !failed then none else
    match e.request.command with
    | .finish serial _ tree | .finishRefinement serial _ tree | .integrate serial _ tree | .archive serial _ tree =>
      some ⟨s!"package-{serial}-evidence", tree, some serial⟩
    | .compose _ _ tree => some ⟨s!"composition-{index}", tree, none⟩
    | _ => none

/-- The diagnostic input, rather than the current or submitted candidate, names
    these files. Each source category retains the existing resource guard. -/
private def checkedSnapshot (repo : FilePath) (current : State) (node : Nat) (diagnostic : Json) : IO Json := do
  let checks := (diagnostic.getObjValAs? (List Json) "checks").toOption.getD []
  let mut snapshots : List Json := []
  for check in checks do
    let some input := ((check.getObjVal? "input").bind (·.getObjVal? "record")).toOption | continue
    let some candidate := (input.getObjValAs? Candidate "candidate").toOption | continue
    let mut fields := [("input", input), ("candidateFiles", ← Git.decode (Json.parse
      (← candidateRecords repo current node candidate)))]
    if let some scope := (input.getObjValAs? Scope "scope").toOption then
      let acceptance ← Policy.readManifest repo scope.policy
      for (resource, path) in [("goal", "Goal.md"), ("spec", acceptance.specificationPath),
          ("acceptance", "acceptance.json")] do
        let available := readable current s!"node/{node}/{resource}" &&
          (resource != "acceptance" || acceptanceReadable current node) &&
          (resource != "spec" || specificationReadable current node path)
        let value ← if available then
            pure (toJson (← Git.readBlob repo (← Git.resolve repo s!"{scope.policy}:{path}")))
          else pure (Json.mkObj [("unavailable", toJson "access revoked")])
        fields := fields ++ [(path, value)]
    snapshots := snapshots ++ [Json.mkObj fields]
  return toJson snapshots

def handoffWithDiagnostics (repo : FilePath) (loaded : Git.Loaded)
    (input : Option (Nat × State × String) := none) : IO Json := do
  let base := handoff loaded input
  let contexts := (base.getObjValAs? (List Json) "contexts").toOption.getD []
  let mut diagnostics : List Json := []
  let mut missing := (base.getObjValAs? (List Json) "missing").toOption.getD []
  for context in contexts do
    let some node := (context.getObjValAs? Nat "node").toOption | continue
    let contextPolicies := loaded.state.nodes[node]?.toList.map (fun target => (target.domain.scope.policy, "current/")) ++
      input.toList.flatMap (fun (_, snapshot, _) => snapshot.nodes[node]?.toList.map (fun target => (target.domain.scope.policy, "")))
    for (policy, resourcePrefix) in contextPolicies.eraseDups do
      let acceptance ← Policy.readManifest repo policy
      for name in "acceptance.json" :: acceptance.files.toList do
        let resource := s!"{resourcePrefix}node/{node}/material/{name}"
        unless readable loaded.state resource do
          missing := missing ++ [Json.mkObj [("resource", toJson resource),
            ("reason", toJson "frozen acceptance material is inaccessible")]]
    for failure in failedChecks loaded.state node do
      let resource := s!"current/node/{node}/{failure.name}"
      let snapshot := resource ++ "-checked-snapshot"
      let mut fields := [("node", toJson node), ("evidenceResource", toJson resource),
        ("checkedSnapshotResource", toJson snapshot),
        ("submittedCandidateResource", toJson (failure.submitted.map (fun serial => s!"node/{node}/package-{serial}-candidate")))]
      if readable loaded.state resource && readable loaded.state s!"node/{node}/history" then
        fields := fields ++ [("diagnostic", ← Diagnostics.read repo failure.tree resource)]
      else
        fields := fields ++ [("unavailable", toJson "access revoked")]
        missing := missing ++ [Json.mkObj [("resource", toJson resource),
          ("reason", toJson "failure evidence is inaccessible")]]
      diagnostics := diagnostics ++ [Json.mkObj fields]
  let currentAcceptance ← if acceptanceReadable loaded.state 0 "current/" then do
      pure (toJson (← Policy.readManifest repo loaded.state.domain.scope.policy))
    else pure Json.null
  let mut inputAcceptance := Json.null
  if let some (node, snapshot, _) := input then
    if let some target := snapshot.nodes[node]? then
      if acceptanceReadable loaded.state node then
        inputAcceptance := toJson (← Policy.readManifest repo target.domain.scope.policy)
  return base.setObjVal! "diagnostics" (toJson diagnostics)
    |>.setObjVal! "currentAcceptance" currentAcceptance
    |>.setObjVal! "inputAcceptance" inputAcceptance
    |>.setObjVal! "missing" (toJson missing)
    |>.setObjVal! "contextComplete" (toJson missing.isEmpty)
    |>.setObjVal! "blockedByMissingContext" (toJson (!missing.isEmpty))

def workerStatus (repo : FilePath) (loaded : Git.Loaded) : IO Json := do
  return Json.mkObj [("status", status loaded), ("handoff", ← handoffWithDiagnostics repo loaded)]

private def failedSnapshotResources (repo : FilePath) (current snapshot : State) (node : Nat)
    (resourcePrefix : String) (wanted : String → Bool) : IO (List Resource) := do
  let mut result := []
  for failure in failedChecks snapshot node do
    let evidence := s!"{resourcePrefix}node/{node}/{failure.name}"
    let id := evidence ++ "-checked-snapshot"
    if readable current id && readable current evidence && readable current s!"node/{node}/history" &&
        failure.submitted.all (fun serial => readable current s!"node/{node}/package-{serial}-candidate") then
      let content ← if wanted id then do
          let diagnostic ← Diagnostics.read repo failure.tree evidence
          pure (← checkedSnapshot repo current node diagnostic).pretty
        else pure ""
      result := result ++ [⟨id, "Actual failed verification input: candidate files and registered goal; sealed submission may differ", content⟩]
  return result

def packageRecords (repo : FilePath) (s : State) (node serial : Nat) : IO (List Json) := do
  let some n := s.nodes[node]? | throw (IO.userError "unknown node")
  let mut records : List Json := []
  for entry in s.journal.entries do
    if entry.request.node != node then continue
    match entry.request.command with
    | .integrate ticket check tree =>
      if ticket == serial then records := records ++ [Json.mkObj [("merge", toJson check), ("raw", toJson (← rawEvidence repo tree))]]
    | .finish ticket verdict tree =>
      if ticket == serial then records := records ++ [Json.mkObj [("verdict", toJson verdict), ("raw", toJson (← rawEvidence repo tree))]]
    | .finishRefinement ticket verdict tree =>
      if ticket == serial then records := records ++ [Json.mkObj [("verdict", toJson verdict), ("raw", toJson (← rawEvidence repo tree))]]
    | .archive ticket _ tree =>
      if ticket == serial then records := records ++ [Json.mkObj [("late", toJson true), ("raw", toJson (← rawEvidence repo tree))]]
    | _ => pure ()
  for op in n.domain.workflow.operations do
    if op.serial == serial then
      let raw ← if op.evidence.isEmpty then pure "pending: reconcile before retry" else rawEvidence repo op.evidence
      records := records ++ [Json.mkObj [("operation", toJson op),
        ("raw", toJson raw)]]
  return records

/-- Inputs come from the allocation snapshot; current/ adds relevant formal
    records from loaded.head. There is no arbitrary Git path, object ID,
    filesystem path or controller configuration read API. -/
def resources (repo : FilePath) (loaded : Git.Loaded) (owner : String) (node serial : Nat)
    (contentWanted : String → Bool := fun _ => true) : IO (List Resource) := do
  let current := loaded.state
  let some allocation := allocated current node serial | throw (IO.userError "unknown allocation")
  unless allocation.owner == owner do throw (IO.userError "wrong worker")
  let head ← packageSnapshot repo loaded node serial
  let snapshot ← snapshotState repo head
  let mut result : List Resource := []
  if let some source := sourceAt snapshot.journal.entries snapshot.journal.initialSource then
    let id := s!"node/{node}/source"
    if readable current id then
      let content ← if contentWanted id then candidateRecords repo current node source else pure ""
      result := result ++ [⟨id, "Shared source fixed at this package's acquisition; file permissions still apply", content⟩]
  for (n, i) in snapshot.nodes.toList.zipIdx do
    let acceptance ← Policy.readManifest repo n.domain.scope.policy
    result := result ++ (← failedSnapshotResources repo current snapshot i "" contentWanted)
    let add (name description content : String) : List Resource :=
      let id := s!"node/{i}/{name}"
      if readable current id then [⟨id, description, content⟩] else []
    if specificationReadable current i acceptance.specificationPath then
      result := result ++ add "spec" "User-confirmed specification bytes fixed at this package's acquisition"
        (← if contentWanted s!"node/{i}/spec" then Git.readBlob repo n.domain.scope.specification else pure "")
    let claims ← Git.resolve repo s!"{n.domain.scope.policy}:claims.json"
    result := result ++ add "claims" "Required clauses for this goal"
      (← if contentWanted s!"node/{i}/claims" then Git.readBlob repo claims else pure "")
    let gate ← Git.resolve repo s!"{n.domain.scope.policy}:Goal.md"
    result := result ++ add "goal" "Required obligations and their registered checking boundary"
      (← if contentWanted s!"node/{i}/goal" then Git.readBlob repo gate else pure "")
    if acceptanceReadable current i then
      result := result ++ add "acceptance" "Frozen specification version, candidate mapping and proof obligations"
        (← if contentWanted s!"node/{i}/acceptance" then pure (toJson acceptance).pretty else pure "")
    for path in "acceptance.json" :: acceptance.files.toList do
      let name := "material/" ++ path
      if path == acceptance.specificationPath && !specificationReadable current i path then continue
      if path == "acceptance.json" && !acceptanceReadable current i then continue
      result := result ++ add name "Frozen acceptance material; candidate drafts cannot replace this input"
        (← if contentWanted s!"node/{i}/{name}" then
          Git.readBlob repo (← Git.resolve repo s!"{n.domain.scope.policy}:{path}") else pure "")
    result := result ++ add "route" "Current refinement and child goals" (toJson n.route).pretty
    let attempts := snapshot.journal.entries.filter (fun e => e.request.node == i)
    result := result ++ add "history" "Prior actions, failures, observations and decisions" (toJson attempts).pretty
    for (entry, j) in attempts.zipIdx do
      if let .acquired ticket := entry.reply then
        let id := s!"node/{i}/package-{ticket}-evidence"
        if readable current id then
          let content ← if contentWanted id then pure (toJson (← packageRecords repo snapshot i ticket)).pretty else pure ""
          result := result ++ [⟨id, "Raw records of this package", content⟩]
      if let .compose _ _ tree := entry.request.command then
        let id := s!"node/{i}/composition-{j}"
        if readable current id then
          let content ← if contentWanted id then rawEvidence repo tree else pure ""
          result := result ++ [⟨id, "Raw controller/harness records; model interpretation is separate", content⟩]
      if let .submit ticket candidate := entry.request.command then
        let id := s!"node/{i}/package-{ticket}-candidate"
        if readable current id && readable current s!"node/{i}/history" then
          let content ← if contentWanted id then candidateRecords repo current i candidate else pure ""
          result := result ++ [⟨id, "Sealed attempt files in the fixed input snapshot; may have failed", content⟩]
    for (ticket, report) in n.domain.workflow.reports do
      result := result ++ add s!"report-{ticket}" "Model interpretation; not verified fact"
        (← if contentWanted s!"node/{i}/report-{ticket}" then Git.readBlob repo report else pure "")
    if let some publication := n.domain.published then
      for file in acceptance.candidateFiles do
        let resolved ← Git.call repo #["rev-parse", "--verify", s!"{publication.candidate.tree}:{file.target}"]
        if resolved.exitCode == 0 then
          result := result ++ add s!"published-{file.source}" "Accepted source in the fixed input snapshot"
            (← if contentWanted s!"node/{i}/published-{file.source}" then Git.readBlob repo resolved.stdout.trimAscii.toString else pure "")
  -- Live records are named separately from frozen inputs. They use the same
  -- resource permissions; a current/ alias cannot bypass a node/ denial.
  for i in packageContextNodes current snapshot node do
    result := result ++ (← failedSnapshotResources repo current current i "current/" contentWanted)
    let some n := current.nodes[i]? | continue
    let history := current.journal.entries.filter (fun e => e.request.node == i)
    let historyId := s!"current/node/{i}/history"
    if readable current historyId then
      result := result ++ [⟨historyId, s!"Formal history at current head {loaded.head}", (toJson history).pretty⟩]
    for (entry, index) in history.zipIdx do
      if let .acquired ticket := entry.reply then
        let id := s!"current/node/{i}/package-{ticket}-evidence"
        if readable current id then
          let content ← if contentWanted id then pure (toJson (← packageRecords repo current i ticket)).pretty else pure ""
          result := result ++ [⟨id, s!"Raw package records at current head {loaded.head}", content⟩]
      if let .compose _ _ evidence := entry.request.command then
        let id := s!"current/node/{i}/composition-{index}"
        if readable current id then
          let content ← if contentWanted id then rawEvidence repo evidence else pure ""
          result := result ++ [⟨id, s!"Raw composition records at current head {loaded.head}", content⟩]
    for (ticket, report) in n.domain.workflow.reports do
      let id := s!"current/node/{i}/report-{ticket}"
      if readable current id then
        let content ← if contentWanted id then Git.readBlob repo report else pure ""
        result := result ++ [⟨id, "Current model interpretation; not verified fact", content⟩]
  return result

def workerGuide : String :=
  "# Axiward worker\n\nThis task uses the current user-approved full-access mode. The workspace rules below are operating instructions, not OS-enforced isolation.\n\nUse the Axiward MCP tools for all project state changes and project materials. First read status and its complete handoff, choose a node and one of the four actions, then call next with explicit node and action. Read the returned handoff and complete actionInstructions every time, even when Codex has already read AGENTS.md. AGENTS.md is the only generated instruction file. In an already bound workspace, next without a choice recovers the same package. This workspace binds to its first package. Write the assigned candidate files directly in this package root; keep the generated specification, goal, instructions and .codex configuration unchanged; temporary external research files belong in .axiward/tmp/. The claims field in each package response and .axiward/view.json contains this package snapshot's clause numbers; null means access is unavailable. The view file is a generated copy, not project authority. Full raw evidence is exported to .axiward/evidence.json only by the explicit evidence tool; failure diagnostics remain in handoff. Added materials belong in .axiward/materials/. Do not directly read other package spaces, change the formal project files or Git state, alter the running controller or its active adapter, edit the session configuration, or invoke admin commands. External research remains available.\n\nFollow the assigned action. execute: implementation + proof, submit once. refine: plan.json + Refinement.lean, submit. explore: exploration.json, prepare, experiments as needed, report.md, conclude. requestDecision: question.json, submit, ask_user, read the scoped decision in handoff. After an ended package, new work requires a new session in another .view/ workspace. Resume sealed checks after interruption; never blindly replay a pending experiment. Keep request IDs stable on retries.\n\nUse one active native task per view. Every new package uses a separate workspace and session identity. Each status and package view supplies complete handoff without prior memory. Recover an existing active package through its owning view; another identity cannot take it over through the Axiward tools. Packages do not expire. Never self-approve user questions. If invalidatedPackages lists your owner, stop generating work and report it to the discussion agent; you may cancel only your own package. Completion requires status.complete=true, regardless of obsolete workers still awaiting reclamation.\n"

def actionGuide : Action → String
  | .execute =>
    "# Execute\n\nRead the frozen specification, Goal.md and acceptance.json in .axiward/policy/, together with the fixed-input claims and handoff. The acceptance manifest names the candidate source files, their module paths, actual propositions, proof declarations and required artifacts. Write only those candidate source files in this package root. Preserve generated policy inputs. Editing any draft specification does not change the active version. Only a user-confirmed revision can do that.\n\nThe initial candidate comes from the source fixed when this package was allocated. Submit once. The controller merges the sealed submission with the latest admitted source and checks the result against this goal and all current accepted guarantees. A rejection ends the package; inspect handoff.diagnostics and use a new session for changes. Resume only continues checking the sealed submission. Restore missing material or source access before continuing. Successful checking establishes the registered formal proposition and artifact binding; it does not confirm that its meaning matches an unconfirmed product requirement.\n"
  | .refine =>
    "# Refine\n\nWrite plan.json with children as arrays of selection indices from the fixed-input claims field, or {\"reuse\": nodeId} for existing goals. Each fresh selection must be nonempty and belong to this parent. These indices select the actual formal propositions named by the manifest; their grouping, disjointness or coverage is not a semantic proof.\n\nWrite Refinement.lean with `import Plan` and a theorem named `Refinement.valid : Plan.Relation`. The controller generates Plan.Relation from the frozen specification: universally quantified shared subject parameters, followed by the actual child propositions implying the actual parent propositions. Prove that implication using the specification definitions. The trusted kernel checker independently checks the theorem against those propositions. Candidate files cannot replace the generated relation or frozen specification. The parent later rechecks the actual merged source before it can close.\n\nSubmit once. To restore direct implementation while leaving the goal open, use {\"direct\":true}. To reuse an admitted historical product, use {\"result\":{\"node\":nodeId,\"receipt\":\"receipt hash\"}}; it must match this exact goal and version. Search the fixed history for nodes and receipts.\n"
  | .explore =>
    "# Explore\n\nWrite exploration.json with a concrete question, maxRuns from 0 to 8 and stopWhen, then call prepare. Zero runs permits analysis. Each trial uses the candidate file paths in frozen acceptance.json under trials/<name>/. experiment accepts a simple trial name and invokes only the frozen checker. Each call consumes one admitted run. After a lost response, retry the same request ID for status or ask the user to reconcile the operation.\n\nInspect evidence, then finish report.md with observations, interpretation and recommendations separated. Reconcile outstanding operations before conclude. Neither a passing trial nor the report publishes a product or closes the goal.\n"
  | .requestDecision =>
    "# Request a user decision\n\nWrite question.json with prompt, subject and 1..4 options, each with a distinct key and label. Ask a short concrete question about the current goal. Choices record a scoped preference; they do not revise the specification, authorize unrelated actions or prove code. Call submit to register, then ask_user through the independent channel. Never supply an answer or invoke admin commands. Read the durable answer's scope and applicableNow in handoff before continuing in a new session. Historical or obsolete replies do not apply to a new specification version.\n"

def packageActionGuide (acceptance : Policy.Manifest) (action : Action) : String :=
  s!"# Frozen project inputs\n\nProject: {acceptance.name}. Version: {acceptance.version}. Read the specification at .axiward/policy/{acceptance.specificationPath} and the complete frozen acceptance.json. Specification meaning requires the user's confirmation; compilation is only a formal check. The package input scope and policy content address bind every subsequent check to these materials.\n\n" ++ actionGuide action

def exportViewLoaded (repo root : FilePath) (loaded : Git.Loaded) (owner : String) (node serial : Nat)
    (writeFiles : Bool := true) (initializeCandidate : Bool := false) : IO Json := do
  let some p := allocated loaded.state node serial | throw (IO.userError "unknown package")
  unless p.owner == owner do throw (IO.userError "wrong worker")
  unless sessionPackage loaded.state owner == some (node, serial) do
    throw (IO.userError "workspace is bound to another package; create a new session")
  let acceptance ← Policy.readManifest repo p.input.policy
  let directory := root
  let metadata := directory / ".axiward"
  let inputs := metadata / "policy"
  let viewPath := metadata / "view.json"
  if writeFiles then IO.FS.createDirAll inputs
  let catalog ← resources repo loaded owner node serial (fun id =>
    [s!"node/{node}/spec", s!"node/{node}/claims", s!"node/{node}/goal", s!"node/{node}/acceptance"].contains id ||
      id.startsWith s!"node/{node}/material/")
  let mut claims := Json.null
  for r in catalog do
    if r.id == s!"node/{node}/claims" then claims ← Git.decode (Json.parse r.content)
    if writeFiles then
      if r.id == s!"node/{node}/goal" then IO.FS.writeFile (inputs / "Goal.md") r.content
      for path in "acceptance.json" :: acceptance.files.toList do
        if r.id == s!"node/{node}/material/{path}" then
          let destination := inputs / path
          IO.FS.createDirAll (destination.parent.getD inputs)
          IO.FS.writeFile destination r.content
  let currentPhase := ((loaded.state.nodes[node]?).map (fun n =>
    if n.domain.active.any (fun a => a.serial == serial) then phaseName n.domain else "ended")).getD "ended"
  let head ← packageSnapshot repo loaded node serial
  let snapshot ← snapshotState repo head
  let mut blockedSourceFiles : List String := []
  if p.action == .execute then
    if let some source := sourceAt snapshot.journal.entries snapshot.journal.initialSource then
      let entries ← Git.checked repo #["ls-tree", "-r", "-z", source.tree]
      for entry in entries.splitOn "\x00" do
        let [entryMetadata, path] := entry.splitOn "\t" | continue
        let [mode, "blob", oid] := entryMetadata.splitOn " " | continue
        unless mode == "100644" || mode == "100755" do continue
        let exported := (acceptance.candidateFiles.find? (fun file => file.target == path)).map (·.source)
        let some name := exported | continue
        let resource := s!"node/{node}/previous-{name}"
        let legacy := s!"node/{node}/previous-{(path.splitOn "/").getLast!}"
        let fullPath := s!"node/{node}/previous-{path}"
        unless readable loaded.state resource && readable loaded.state legacy &&
            readable loaded.state fullPath &&
            readable loaded.state s!"node/{node}/source" do
          blockedSourceFiles := blockedSourceFiles ++
            [if readable loaded.state fullPath then resource else fullPath]
          continue
        if writeFiles && initializeCandidate && !(← (directory / name).pathExists) then
          let mut parent := directory
          for part in (name.splitOn "/").dropLast do
            parent := parent / part
            if ← parent.pathExists then
              let actual ← IO.FS.realPath parent
              unless (actual.normalize.toString.toLower.replace "\\" "/") ==
                  (parent.normalize.toString.toLower.replace "\\" "/") do
                throw (IO.userError "candidate parent directory is redirected")
            else IO.FS.createDir parent
          IO.FS.writeFile (directory / name) (← Git.readBlob repo oid)
  let instructions := s!"# Package {node}/{serial}\n\nCurrent phase: {currentPhase}. An ended package cannot be changed or submitted again; use a new session for new work when the project is incomplete. Read the returned full handoff before acting.\n\n" ++
    if acceptanceReadable loaded.state node then packageActionGuide acceptance p.action
    else "Frozen acceptance materials are unavailable. Restore access before continuing.\n"
  let summary := Json.mkObj [("node", toJson node), ("serial", toJson serial),
    ("action", toJson p.action), ("acceptance", if acceptanceReadable loaded.state node then toJson acceptance else Json.null), ("input", toJson p.input),
    ("snapshot", toJson head),
    ("sourceBase", toJson (sourceAt snapshot.journal.entries snapshot.journal.initialSource)),
    ("sourceResource", toJson s!"node/{node}/source"),
    ("blockedSourceFiles", toJson blockedSourceFiles),
    ("guide", toJson (directory / "AGENTS.md").toString),
    ("actionInstructions", toJson instructions),
    ("claims", claims), ("claimsResource", toJson s!"node/{node}/claims"),
    ("viewPath", toJson viewPath.toString),
    ("evidencePath", toJson (metadata / "evidence.json").toString),
    ("materialsDirectory", toJson (metadata / "materials").toString),
    ("tempDirectory", toJson (metadata / "tmp").toString),
    ("specification", toJson (inputs / acceptance.specificationPath).toString),
    ("goal", toJson (inputs / "Goal.md").toString),
    ("acceptancePath", toJson (inputs / "acceptance.json").toString),
    ("phase", toJson currentPhase),
    ("requiresNewSession", toJson (currentPhase == "ended" && !complete loaded.state)),
    ("candidateDirectory", toJson directory.toString),
    ("resources", toJson (catalog.map (fun r => Json.mkObj [("id", toJson r.id), ("description", toJson r.description)]))),
    ("status", status loaded),
    ("handoff", ← handoffWithDiagnostics repo loaded (some (node, snapshot, head)))]
  if writeFiles then
    IO.FS.writeFile viewPath summary.pretty
    IO.FS.writeFile (directory / "AGENTS.md") (workerGuide ++ "\n" ++ instructions)
  return summary

def exportView (repo root : FilePath) (owner : String) (node serial : Nat) : IO Json := do
  exportViewLoaded repo root (← Git.load repo) owner node serial

private def nextUnlocked (repo root : FilePath) (id owner : String) (selection : Option (Nat × Action)) : IO Json := do
  Git.synchronize repo
  let _ ← Controller.propagate repo
  let loaded ← Git.load repo
  if let some entry := loaded.state.journal.entries.find? (fun e => e.request.id == id) then
    let .begin originalOwner action := entry.request.command | throw (IO.userError "request ID conflict")
    unless originalOwner == owner && selection.all (fun x => x == (entry.request.node, action)) do
      throw (IO.userError "request ID conflict")
    let .acquired serial := entry.reply | throw (IO.userError "invalid allocation reply")
    return ← exportViewLoaded repo root loaded owner entry.request.node serial
  if let some (node, serial) := sessionPackage loaded.state owner then
    let some p := allocated loaded.state node serial | throw (IO.userError "unknown package")
    unless selection.all (fun choice => choice == (node, p.action)) do
      throw (IO.userError "workspace already belongs to another package; use a new session for new work")
    return ← exportViewLoaded repo root loaded owner node serial
  if complete loaded.state || loaded.state.domain.workflow.paused then
    return ← workerStatus repo loaded
  let some (node, action) := selection
    | throw (IO.userError "choose a node and action from status and handoff before requesting a new package")
  Sandbox.requireCodex
  let reply ← Git.transact repo ⟨id, .controller, .begin owner action, node⟩
  let .acquired serial := reply | throw (IO.userError "allocation failed")
  -- Only a new allocation initializes source files. Recovery must not use a
  -- generated view marker to overwrite drafts or restore deleted candidates.
  exportViewLoaded repo root (← Git.load repo) owner node serial (initializeCandidate := true)

def next (repo root : FilePath) (id owner : String) (selection : Option (Nat × Action) := none) : IO Json := do
  -- Two concurrent next calls from one session must not bind different nodes
  -- to the same fixed native sandbox directory.
  let gate ← IO.FS.Handle.mk (root / ".codex" / "allocation.lock") .append
  gate.lock
  try nextUnlocked repo root id owner selection
  finally gate.unlock

def search (repo : FilePath) (owner : String) (node serial : Nat) (query : String) : IO Json := do
  let loaded ← Git.load repo
  let catalog ← resources repo loaded owner node serial
  let found := catalog.filter (fun r => query.isEmpty ||
    (r.content.toLower.splitOn query.toLower).length > 1 || (r.id.toLower.splitOn query.toLower).length > 1)
  return toJson (found.map (fun r => Json.mkObj [("id", toJson r.id), ("description", toJson r.description),
    ("excerpt", toJson (String.ofList (r.content.toList.take 240)))]))

def readResource (repo : FilePath) (owner : String) (node serial : Nat) (id : String) : IO Json := do
  let loaded ← Git.load repo
  let catalog ← resources repo loaded owner node serial (· == id)
  let some r := catalog.find? (fun r => r.id == id) | throw (IO.userError "resource unavailable or access revoked")
  return toJson r

def addResource (repo root : FilePath) (owner : String) (node serial : Nat) (id : String) : IO Json := do
  let json ← readResource repo owner node serial id
  let resource : String ← Git.decode (json.getObjValAs? String "content")
  let directory := root / ".axiward" / "materials"
  IO.FS.createDirAll directory
  let path := directory / (id.replace "/" "_" ++ ".txt")
  IO.FS.writeFile path resource
  return Json.mkObj [("resource", toJson id), ("path", toJson path.toString)]

def evidence (repo root : FilePath) (owner : String) (node serial : Nat) : IO Json := do
  let loaded ← Git.load repo
  let some p := allocated loaded.state node serial | throw (IO.userError "unknown allocation")
  unless p.owner == owner do throw (IO.userError "wrong worker")
  let resourceId := s!"node/{node}/package-{serial}-evidence"
  unless readable loaded.state resourceId do throw (IO.userError "access revoked")
  let some n := loaded.state.nodes[node]? | throw (IO.userError "unknown node")
  let records ← packageRecords repo loaded.state node serial
  let directory := root / ".axiward"
  IO.FS.createDirAll directory
  let path := directory / "evidence.json"
  IO.FS.writeFile path (toJson records).pretty
  return Json.mkObj [("path", toJson path.toString), ("records", toJson records.length),
    ("operations", toJson (n.domain.workflow.operations.filter (fun o => o.serial == serial)))]

def delivery (repo : FilePath) (requested : FilePath := "delivery") : IO Json := do
  let repo ← IO.FS.realPath repo
  let destination := (if requested.isAbsolute then requested else repo / requested).normalize
  let key (path : FilePath) := path.normalize.toString.toLower.replace "\\" "/"
  let parts := (key destination).splitOn "/"
  let relative := ((key destination).drop ((key repo).length + 1)).toString
  let first := (relative.splitOn "/").headD ""
  if [".git", ".axiward", "source", "product", ".view", ".checks"].contains first then
    throw (IO.userError "delivery output must not use a reserved project directory")
  unless (key destination).startsWith (key repo ++ "/") &&
      !parts.any (fun part => part == "." || part == "..") do
    throw (IO.userError "delivery output must be a new directory inside the project root")
  let mut ancestor := destination.parent.getD repo
  for _ in [:destination.toString.length] do
    if ← ancestor.pathExists then break
    let some parent := ancestor.parent | throw (IO.userError "delivery parent is unavailable")
    ancestor := parent
  unless key (← IO.FS.realPath ancestor) == key ancestor do
    throw (IO.userError "delivery parent must not redirect outside its project path")
  let loaded ← Git.load repo
  unless complete loaded.state do throw (IO.userError "delivery blocked: root proof or process obligations remain open")
  let some publication := loaded.state.domain.published | throw (IO.userError "no product")
  if ← destination.pathExists then throw (IO.userError "delivery requires a new directory")
  Git.materialize repo publication.product destination
  IO.FS.writeFile (destination / "axiward-receipt.json") (← Git.readBlob repo publication.receipt)
  let manifest := Json.mkObj [("directory", toJson destination.toString),
    ("commit", toJson loaded.head), ("scope", toJson publication.scope),
    ("product", toJson publication.product), ("receipt", toJson publication.receipt),
    ("complete", toJson true)]
  IO.FS.writeFile (destination / "axiward-delivery.json") manifest.pretty
  return manifest

def session (repo view python adapter : FilePath) : IO Json := do
  Sandbox.requireCodex
  let _ ← Git.load repo
  unless view.isAbsolute && python.isAbsolute && adapter.isAbsolute do
    throw (IO.userError "session paths must be absolute")
  if ← view.pathExists then throw (IO.userError "session requires a new view directory")
  let repo ← IO.FS.realPath repo
  let repoText := repo.normalize.toString.toLower.replace "\\" "/"
  let parentText := (view.parent.getD view).normalize.toString.toLower.replace "\\" "/"
  unless parentText == repoText ++ "/.view" && view.fileName.isSome do
    throw (IO.userError "worker workspace must be a new direct child of the project's .view directory")
  IO.FS.createDirAll (repo / ".view")
  let viewRoot ← IO.FS.realPath (repo / ".view")
  unless viewRoot.normalize.toString.toLower.replace "\\" "/" == parentText do
    throw (IO.userError ".view must not redirect outside its project")
  unless (← python.pathExists) && (← adapter.pathExists) do throw (IO.userError "Python or adapter not found")
  let exe ← IO.appPath
  let worker ← Git.hashText repo s!"{view}\n{← IO.monoNanosNow}"
  IO.FS.createDirAll (view / ".codex")
  IO.FS.createDirAll (view / ".axiward" / "tmp")
  let argv := #["-E", "-s", adapter.toString, "--exe", exe.toString, "--repo", repo.toString,
    "--view", view.toString, "--worker", worker]
  let config := "# Axiward: user-approved full-access mode; workspace limits are operating instructions.\nsandbox_mode = \"danger-full-access\"\n" ++
    "approval_policy = { granular = { sandbox_approval = false, rules = false, mcp_elicitations = true, request_permissions = false, skill_approval = false } }\n\n" ++
    "[shell_environment_policy.set]\n" ++
    "TMP = " ++ Sandbox.quote (view / ".axiward" / "tmp").toString ++ "\nTEMP = " ++ Sandbox.quote (view / ".axiward" / "tmp").toString ++ "\n\n" ++
    s!"[mcp_servers.axiward]\ncommand = {(toJson python.toString).compress}\nargs = {(toJson argv).compress}\nstartup_timeout_sec = 30\ntool_timeout_sec = 600\ndefault_tools_approval_mode = \"approve\"\n"
  IO.FS.writeFile (view / ".codex" / "config.toml") config
  IO.FS.writeFile (view / "AGENTS.md") workerGuide
  return Json.mkObj [("view", toJson view.toString), ("worker", toJson worker),
    ("configuration", toJson (view / ".codex" / "config.toml").toString),
    ("guide", toJson (view / "AGENTS.md").toString),
    ("viewPath", toJson (view / ".axiward" / "view.json").toString),
    ("tempDirectory", toJson (view / ".axiward" / "tmp").toString),
    ("message", toJson "Open this workspace in its trusted Codex project using the generated full-access configuration. Workspace limits are instructions; no global configuration changed.")]

end Axiward.Interface
