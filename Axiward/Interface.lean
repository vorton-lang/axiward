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
    ("rootClosed", toJson loaded.state.domain.published.isSome),
    ("paused", toJson loaded.state.domain.workflow.paused),
    ("pauseReason", toJson loaded.state.domain.workflow.pauseReason),
    ("pendingOperations", toJson (pendingOperations loaded.state)),
    ("invalidatedPackages", Controller.invalidatedPackages loaded.state),
    ("map", toJson (loaded.state.nodes.toList.zipIdx.map (fun (n, id) => mapNode loaded.state id n))),
    ("transitions", toJson loaded.state.journal.entries.length)]

def allocated (s : State) (node serial : Nat) : Option Package := do
  let entry ← s.journal.entries.find? (fun e => e.request.node == node && e.reply == .acquired serial)
  let .begin owner action := entry.request.command | none
  -- The snapshot supplies the input; this function authenticates allocation only.
  return ⟨serial, owner, s.domain.scope, .drafting, action⟩

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

def packageInfo (repo : FilePath) (owner : String) (node serial : Nat) : IO Json := do
  let loaded ← Git.load repo
  let some p := allocated loaded.state node serial | throw (IO.userError "unknown allocation")
  unless p.owner == owner do throw (IO.userError "wrong worker")
  unless sessionPackage loaded.state owner == some (node, serial) do
    throw (IO.userError "workspace is bound to another package")
  let some n := loaded.state.nodes[node]? | throw (IO.userError "unknown node")
  return Json.mkObj [("domain", toJson n.domain), ("action", toJson p.action)]

def snapshotState (repo : FilePath) (head : String) : IO State := do
  let oid ← Git.resolve repo s!"{head}:.axiward/state.json"
  let journal : Journal ← Git.decode (fromJson? (← Git.decode (Json.parse (← Git.readBlob repo oid))))
  Git.decode (restore journal)

structure Resource where
  id : String
  description : String
  content : String
  deriving ToJson

def readable (current : State) (id : String) : Bool :=
  let base := if id.startsWith "current/" then String.ofList (id.toList.drop 8) else id
  !current.domain.workflow.deniedResources.any (fun denied =>
    id == denied || id.startsWith (denied ++ "/") || base == denied || base.startsWith (denied ++ "/"))

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
    for name in ["spec", "claims", "goal", "route", "history"] do
      let id := s!"current/node/{node}/{name}"
      unless readable s id do
        missing := missing ++ [Json.mkObj [("resource", toJson id),
          ("reason", toJson "necessary context is inaccessible; restore access before relying on a complete handoff")]]
    let canReadScope := readable s s!"current/node/{node}/spec" && readable s s!"current/node/{node}/claims" &&
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
      ("materials", toJson (["spec", "claims", "goal", "route", "history"].map (fun name => s!"node/{node}/{name}")))]]
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
    unless path.endsWith ".lean" || ["plan.json", "question.json", "exploration.json"].contains path do continue
    let name := (path.splitOn "/").getLast!
    -- Preserve exact old previous-file denials as well as the new package ID.
    let content ← if readable current s!"node/{node}/previous-{name}" then
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
      for (resource, path) in [("goal", "Gate.lean"), ("spec", "Axiward/Spec.lean")] do
        let value ← if readable current s!"node/{node}/{resource}" then
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
  return base.setObjVal! "diagnostics" (toJson diagnostics)
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
  if let some source := sourceAt snapshot.journal.entries then
    let id := s!"node/{node}/source"
    if readable current id then
      let content ← if contentWanted id then candidateRecords repo current node source else pure ""
      result := result ++ [⟨id, "Shared source fixed at this package's acquisition; file permissions still apply", content⟩]
  for (n, i) in snapshot.nodes.toList.zipIdx do
    result := result ++ (← failedSnapshotResources repo current snapshot i "" contentWanted)
    let add (name description content : String) : List Resource :=
      let id := s!"node/{i}/{name}"
      if readable current id then [⟨id, description, content⟩] else []
    result := result ++ add "spec" "Formal requirement definitions"
      (← if contentWanted s!"node/{i}/spec" then Git.readBlob repo n.domain.scope.specification else pure "")
    let claims ← Git.resolve repo s!"{n.domain.scope.policy}:claims.json"
    result := result ++ add "claims" "Required clauses for this goal"
      (← if contentWanted s!"node/{i}/claims" then Git.readBlob repo claims else pure "")
    let gate ← Git.resolve repo s!"{n.domain.scope.policy}:Gate.lean"
    result := result ++ add "goal" "Exact theorem names and statements the checker requires"
      (← if contentWanted s!"node/{i}/goal" then Git.readBlob repo gate else pure "")
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
      for name in ["Queue.lean", "Proofs.lean"] do
        let resolved ← Git.call repo #["rev-parse", "--verify", s!"{publication.product}:Axiward/{name}"]
        if resolved.exitCode == 0 then
          result := result ++ add s!"published-{name}" "Accepted source in the fixed input snapshot"
            (← if contentWanted s!"node/{i}/published-{name}" then Git.readBlob repo resolved.stdout.trimAscii.toString else pure "")
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

def viewDirectory (root : FilePath) (_node _serial : Nat) : FilePath := root / "work"

def actionGuide : Action → String
  | .execute =>
    "# Execute\n\nRead Spec.lean, Goal.lean and claims.json. Write candidate/Queue.lean and candidate/Proofs.lean. They start from the shared source at package acquisition when one exists. Your sealed submission is kept unchanged; the controller merges it with the latest source and checks the merged snapshot against this goal and every current accepted guarantee. The controller mounts them as Axiward.Queue and Axiward.Proofs alongside the frozen Axiward.Spec. Proofs.lean should import Axiward.Queue and Axiward.Spec and define the exact theorem names/types shown in Goal.lean (in namespace Axiward). Implement the API referenced by those predicates; no sorry, added axioms, unsafe or runtime replacements.\n\nSubmit once with submit. A rejection ends the package: read evidence.json and continue in a new session. Resume only continues a sealed check. Exploration requires a separate explore package. Preserve the baseline declarations and proofs when adding your assigned claims; every current accepted guarantee must still hold on the merged source. After failure, handoff.diagnostics provides the retained Lean messages and a checkedSnapshotResource for the actual tested code. If source initialization reports blockedSourceFiles, restore access and read sourceResource before continuing.\n"
  | .refine =>
    "# Refine\n\nWrite candidate/plan.json. Fresh children are arrays of clause indices from claims.json; they must be nonempty, disjoint and cover the parent. Existing nodes use {\"reuse\": nodeId}. Example for the full root:\n\n```json\n{\"children\":[[0,1,2],[3,4,5]],\"direct\":false}\n```\n\nImplementation and proof changes enter the shared source through three-way merging and joint verification. The parent checks that shared source; implementation child selection is unavailable.\n\nWrite candidate/Refinement.lean:\n\n```lean\nimport Plan\nnamespace Refinement\ntheorem valid (facts : Nat → Prop) :\n    (∀ child ∈ Plan.children, Holds child facts) → Holds Plan.parent facts := by\n  simp_all [Plan.children, Plan.parent, Holds, and_assoc]\nend Refinement\n```\n\nThe controller generates Plan and Holds from the sealed plan and current parent. You cannot replace those inputs. Submit once. To restore direct implementation while leaving the goal open, use {\"direct\":true}. For an already admitted historical product use {\"result\":{\"node\":nodeId,\"receipt\":\"receipt hash\"}}; it must match this exact goal. Search the snapshot history for available nodes and receipts.\n"
  | .explore =>
    "# Explore\n\nWrite candidate/exploration.json:\n\n```json\n{\"question\":\"What uncertainty blocks this goal?\",\"maxRuns\":2,\"stopWhen\":\"Compare at most two candidates, then report a next step\"}\n```\n\nCall prepare before any experiment. maxRuns is 0..8; zero permits analysis without project execution. R0 permits only the registered checker applied to immutable candidates. Write Queue.lean and Proofs.lean under trials/<name>/; experiment accepts that simple name, never arbitrary commands. Each call consumes one admitted run. A lost response is not permission to run again: retry the SAME request ID for status, or ask the user to reconcile the outstanding operation.\n\nUse evidence to inspect raw observations. External research and reasoning may inform your report, but citations and interpretations are not machine facts. Finish candidate/report.md with observations, interpretation and next-step recommendation kept distinct, then call conclude. No findings is also a valid conclusion. All in-flight operations must first be reconciled. Neither a passing trial nor a report closes this product goal.\n"
  | .requestDecision =>
    "# Request a user decision\n\nWrite candidate/question.json:\n\n```json\n{\"prompt\":\"Which implementation approach should be tried?\",\"subject\":\"Current FIFO goal; this records a preference only\",\"options\":[{\"key\":\"list\",\"label\":\"Use an immutable list\"},{\"key\":\"explore\",\"label\":\"Compare alternatives first\"}]}\n```\n\nUse a short concrete question, a specific subject and 1..4 distinct choices. All branches only record a preference bound to the current scope. They do not change the root, authorize arbitrary actions or prove code. Call submit to register, then ask_user to reach the user through the independent channel. Never supply an answer or invoke the admin CLI yourself. After receiving a durable answer, read its scope and applicableNow in handoff, then continue in a new session. Every new package receives the necessary decisions again. Stale and off-branch replies remain historical input only.\n"

def exportViewLoaded (repo root : FilePath) (loaded : Git.Loaded) (owner : String) (node serial : Nat)
    (includeEvidence : Bool := false) : IO Json := do
  let some p := allocated loaded.state node serial | throw (IO.userError "unknown package")
  unless p.owner == owner do throw (IO.userError "wrong worker")
  unless sessionPackage loaded.state owner == some (node, serial) do
    throw (IO.userError "workspace is bound to another package; create a new session")
  let directory := viewDirectory root node serial
  let candidate := directory / "candidate"
  let initializeCandidate := !(← candidate.pathExists)
  IO.FS.createDirAll candidate
  let catalog ← resources repo loaded owner node serial (fun id =>
    [s!"node/{node}/spec", s!"node/{node}/claims", s!"node/{node}/goal"].contains id)
  for r in catalog do
    if r.id == s!"node/{node}/spec" then IO.FS.writeFile (directory / "Spec.lean") r.content
    if r.id == s!"node/{node}/claims" then IO.FS.writeFile (directory / "claims.json") r.content
    if r.id == s!"node/{node}/goal" then IO.FS.writeFile (directory / "Goal.lean") r.content
  let currentPhase := ((loaded.state.nodes[node]?).map (fun n =>
    if n.domain.active.any (fun a => a.serial == serial) then phaseName n.domain else "ended")).getD "ended"
  let head ← packageSnapshot repo loaded node serial
  let snapshot ← snapshotState repo head
  let mut blockedSourceFiles : List String := []
  if initializeCandidate && p.action == .execute then
    if let some source := sourceAt snapshot.journal.entries then
      for name in Verifier.candidateFiles do
        let resource := s!"node/{node}/previous-{name}"
        unless readable loaded.state resource && readable loaded.state s!"node/{node}/source" do
          blockedSourceFiles := blockedSourceFiles ++ [resource]
          continue
        let blob ← Git.call repo #["rev-parse", "--verify", s!"{source.tree}:Axiward/{name}"]
        if blob.exitCode == 0 then
          IO.FS.writeFile (candidate / name) (← Git.readBlob repo blob.stdout.trimAscii.toString)
  let mut extra : List (String × Json) := []
  if includeEvidence then
    if readable loaded.state s!"node/{node}/package-{serial}-evidence" then
      let records ← packageRecords repo loaded.state node serial
      let path := directory / "evidence.json"
      IO.FS.writeFile path (toJson records).pretty
      extra := [("evidence", Json.mkObj [("path", toJson path.toString), ("records", toJson records.length)])]
    else extra := [("evidence", Json.mkObj [("unavailable", toJson "access revoked")])]
  let summary := Json.mkObj ([("node", toJson node), ("serial", toJson serial),
    ("action", toJson p.action), ("snapshot", toJson head),
    ("sourceBase", toJson (sourceAt snapshot.journal.entries)),
    ("sourceResource", toJson s!"node/{node}/source"),
    ("blockedSourceFiles", toJson blockedSourceFiles),
    ("guide", toJson (directory / "ACTION.md").toString),
    ("goal", toJson (directory / "Goal.lean").toString),
    ("phase", toJson currentPhase),
    ("requiresNewSession", toJson (currentPhase == "ended" && !complete loaded.state)),
    ("candidateDirectory", toJson candidate.toString),
    ("resources", toJson (catalog.map (fun r => Json.mkObj [("id", toJson r.id), ("description", toJson r.description)]))),
    ("status", status loaded),
    ("handoff", ← handoffWithDiagnostics repo loaded (some (node, snapshot, head)))] ++ extra)
  IO.FS.writeFile (directory / "view.json") summary.pretty
  IO.FS.writeFile (directory / "ACTION.md") (actionGuide p.action)
  IO.FS.writeFile (directory / "WORK.md")
    s!"# Package {node}/{serial}\n\nAction: {repr p.action}. Edit candidate/ only.\n\nRead view.json handoff for decisions, prior outcomes and outstanding operations. Its currentHead is current state; snapshot is the fixed input version. Use Axiward tools for project state and additional materials. Never access the canonical repository, controller binary/configuration, or other packages directly. External research is allowed; your notes are not machine evidence. No package expiry.\n\nexecute: Queue.lean + Proofs.lean. refine: plan.json + Refinement.lean. explore: exploration.json, prepare, experiment, report.md, conclude. requestDecision: question.json, submit, ask_user; never fabricate an answer.\n\nA sealed candidate cannot be edited and resubmitted. After rejection acquire a new package in a new session. Use resume to finish an interrupted check. This workspace stays bound to this package after it ends; next returns requiresNewSession when more work remains.\n"
  return summary

def exportView (repo root : FilePath) (owner : String) (node serial : Nat) : IO Json := do
  exportViewLoaded repo root (← Git.load repo) owner node serial true

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
    return ← exportViewLoaded repo root loaded owner node serial true
  if complete loaded.state || loaded.state.domain.workflow.paused then
    return ← workerStatus repo loaded
  let some (node, action) := selection
    | throw (IO.userError "choose a node and action from status and handoff before requesting a new package")
  Sandbox.requireCodex
  let reply ← Git.transact repo ⟨id, .controller, .begin owner action, node⟩
  let .acquired serial := reply | throw (IO.userError "allocation failed")
  exportView repo root owner node serial

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
  let directory := viewDirectory root node serial / "materials"
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
  let directory := viewDirectory root node serial
  IO.FS.createDirAll directory
  let path := directory / "evidence.json"
  IO.FS.writeFile path (toJson records).pretty
  return Json.mkObj [("path", toJson path.toString), ("records", toJson records.length),
    ("operations", toJson (n.domain.workflow.operations.filter (fun o => o.serial == serial)))]

def delivery (repo destination : FilePath) : IO Json := do
  let loaded ← Git.load repo
  unless complete loaded.state do throw (IO.userError "delivery blocked: root proof or process obligations remain open")
  let some publication := loaded.state.domain.published | throw (IO.userError "no product")
  if ← destination.pathExists then throw (IO.userError "delivery requires a new directory")
  Git.materialize repo publication.product destination
  IO.FS.writeFile (destination / "axiward-receipt.json") (← Git.readBlob repo publication.receipt)
  let manifest := Json.mkObj [("commit", toJson loaded.head), ("scope", toJson publication.scope),
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
  IO.FS.createDirAll (view / "work")
  IO.FS.createDirAll (view / "tmp")
  let argv := #["-E", "-s", adapter.toString, "--exe", exe.toString, "--repo", repo.toString,
    "--view", view.toString, "--worker", worker]
  let config := "# Axiward: user-approved full-access mode; workspace limits are operating instructions.\nsandbox_mode = \"danger-full-access\"\n" ++
    "approval_policy = { granular = { sandbox_approval = false, rules = false, mcp_elicitations = true, request_permissions = false, skill_approval = false } }\n\n" ++
    "[shell_environment_policy.set]\n" ++
    "TMP = " ++ Sandbox.quote (view / "tmp").toString ++ "\nTEMP = " ++ Sandbox.quote (view / "tmp").toString ++ "\n\n" ++
    s!"[mcp_servers.axiward]\ncommand = {(toJson python.toString).compress}\nargs = {(toJson argv).compress}\nstartup_timeout_sec = 30\ntool_timeout_sec = 600\ndefault_tools_approval_mode = \"approve\"\n"
  IO.FS.writeFile (view / ".codex" / "config.toml") config
  IO.FS.writeFile (view / "AGENTS.md")
    "# Axiward worker\n\nThis task uses the current user-approved full-access mode. The workspace rules below are operating instructions, not OS-enforced isolation.\n\nUse the Axiward MCP tools for all project state changes and project materials. First read status and its complete handoff, choose a node and one of the four actions, then call next with explicit node and action. Read the returned handoff and ACTION.md. In an already bound workspace, next without a choice recovers the same package. This workspace binds to its first package. Write candidates only in this package's work/ area; temporary external research files belong in tmp/. Do not directly read other package spaces, change the formal project files or Git state, alter the controller or adapter, edit the session configuration, or invoke admin commands. External research remains available.\n\nFollow the assigned action. execute: implementation + proof, submit once. refine: plan.json + Refinement.lean, submit. explore: exploration.json, prepare, experiments as needed, report.md, conclude. requestDecision: question.json, submit, ask_user, read the scoped decision in handoff. After an ended package, new work requires a new session in another .view/ workspace. Resume sealed checks after interruption; never blindly replay a pending experiment. Keep request IDs stable on retries.\n\nUse one active native task per view. Every new package uses a separate workspace and session identity. Each status and package view supplies complete handoff without prior memory. Recover an existing active package through its owning view; another identity cannot take it over through the Axiward tools. Never self-approve user questions. If invalidatedPackages lists your owner, stop generating work and report it to the discussion agent; you may cancel only your own package. Completion requires status.complete=true, regardless of obsolete workers still awaiting reclamation.\n"
  IO.FS.writeFile (view / "START.md")
    "# Start here\n\nOpen this workspace in Codex and trust its containing project so the generated configuration is loaded. Confirm the Axiward MCP tools are available. This is the current user-approved full-access mode: workspace restrictions are instructions, not an operating-system sandbox guarantee. Keep the generated approval policy so registered questions can use the independent user channel.\n\nAsk the agent: ‘Read status and handoff, choose a node and action, pass both to next, and work through that package. Write candidates only in your package workspace. Use Axiward for project changes; do not directly alter the formal repository, Git state, controller or other package spaces. Ask me when a registered decision needs an answer.’\n\nOnly this project uses the generated configuration. Restart the task after setup. This initially empty workspace binds to one package on its first allocation. Start each new package with another session under the project .view/ directory. To recover an existing active package, reopen its owning view and call next without a new choice; prior conversation context is unnecessary. Packages never expire.\n\nDiscussion agent: after every route change, read invalidatedPackages in the returned handoff or overview. Immediately stop each listed owner through Codex, then call the controller CLI reclaim with its node and serial. Reclaim releases occupancy but does not settle registered in-flight operations; reconcile those only after their execution has stopped. Axiward reports invalidation and does not manage Codex processes.\n"
  return Json.mkObj [("view", toJson view.toString), ("worker", toJson worker),
    ("configuration", toJson (view / ".codex" / "config.toml").toString),
    ("message", toJson "Open this workspace in its trusted Codex project using the generated full-access configuration. Workspace limits are instructions; no global configuration changed.")]

end Axiward.Interface
