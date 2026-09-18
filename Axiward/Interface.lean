import Axiward.Controller

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

def inbox (s : State) (owner : String) : Json :=
  toJson (s.nodes.toList.zipIdx.flatMap fun (n, id) => n.domain.workflow.decisions.filterMap fun q =>
    if q.owner == owner && q.answer.isSome && !q.acknowledged then
      some (Json.mkObj [("node", toJson id), ("decision", toJson q)]) else none)

def status (loaded : Git.Loaded) : Json :=
  Json.mkObj [("head", toJson loaded.head), ("complete", toJson (complete loaded.state)),
    ("rootClosed", toJson loaded.state.domain.published.isSome),
    ("paused", toJson loaded.state.domain.workflow.paused),
    ("pauseReason", toJson loaded.state.domain.workflow.pauseReason),
    ("pendingOperations", toJson (pendingOperations loaded.state)),
    ("map", toJson (loaded.state.nodes.toList.zipIdx.map (fun (n, id) => mapNode loaded.state id n))),
    ("transitions", toJson loaded.state.journal.entries.length)]

structure Recommendation where
  action : Action
  allowed : Bool
  score : Nat
  reason : String
  deriving ToJson

/-- Replaceable, deterministic R0 navigator. Scores express heuristics, never
    mathematical confidence or authority to bypass admission checks. -/
def recommendations (s : State) (id : Nat) (n : Node) : List Recommendation := Id.run do
  let available := !s.domain.workflow.paused && n.domain.active.isNone && n.domain.published.isNone &&
    scopeUsable s.nodes n.domain.scope
  let attempts := s.journal.entries.filter (fun e => e.request.node == id)
  let recent := (attempts.reverse.takeWhile (fun e => match e.reply with
    | .explored _ | .answered _ true => false | _ => true))
  let failures := recent.filter (fun e => match e.reply with
    | .rejected _ _ | .unresolved _ _ | .compositionFailed _ => true | _ => false)
  let lastAction := (attempts.reverse.find? (fun e => match e.request.command with
    | .begin _ _ => true | _ => false)).bind (fun e => match e.request.command with
      | .begin _ a => some a | _ => none)
  let explored := lastAction == some .explore
  return [
    ⟨.execute, available && n.route.isNone, if failures.isEmpty || explored then 80 else 35,
      "Generate one implementation plus proof when this goal fits one attempt."⟩,
    ⟨.refine, available, if n.route.isSome then 75 else if n.domain.scope.requirements.length > 3 then 90 else 50,
      "Decompose or replace the route; every new obligation and implication is checked."⟩,
    ⟨.explore, available, if !failures.isEmpty && !explored then 95 else 40,
      s!"{failures.length} prior unsuccessful attempts; gather information before another implementation."⟩,
    ⟨.requestDecision, available, if failures.length ≥ 3 then 100 else 20,
      "Ask a concrete bounded question when a user preference or repeated lack of progress blocks work."⟩]

def navigation (s : State) : Json :=
  toJson ((currentNodes s.nodes).filterMap fun id => s.nodes[id]?.map fun n =>
    Json.mkObj [("node", toJson id), ("recommendations", toJson (recommendations s id n))])

def allocated (s : State) (node serial : Nat) : Option Package := do
  let entry ← s.journal.entries.find? (fun e => e.request.node == node && e.reply == .acquired serial)
  let .begin owner action := entry.request.command | none
  -- The snapshot supplies the input; this function authenticates allocation only.
  return ⟨serial, owner, s.domain.scope, .drafting, action⟩

def packageSnapshot (repo : FilePath) (s : State) (node serial : Nat) : IO String := do
  let some event := s.journal.entries.find? (fun e => e.request.node == node && e.reply == .acquired serial)
    | throw (IO.userError "unknown allocation")
  let position := (s.journal.entries.takeWhile (· != event)).length + 1
  -- Transition numbers are hints only; verify the matching journal before use.
  let commits ← Git.checked repo #["log", "--first-parent", "--format=%H",
    s!"--grep=^Axiward transition {position}$", "refs/heads/main"]
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
  !current.domain.workflow.deniedResources.any (fun denied => id == denied || id.startsWith (denied ++ "/"))

def rawEvidence (repo : FilePath) (tree : String) : IO String := do
  let names ← Git.checked repo #["ls-tree", "-r", "--name-only", tree]
  let mut records : List Json := []
  for name in names.splitOn "\n" do
    if name.endsWith ".json" || name.endsWith ".txt" then
      let oid ← Git.resolve repo s!"{tree}:{name}"
      records := records ++ [Json.mkObj [("file", toJson name), ("raw", toJson (← Git.readBlob repo oid))]]
  return (toJson records).pretty

def packageRecords (repo : FilePath) (s : State) (node serial : Nat) : IO (List Json) := do
  let some n := s.nodes[node]? | throw (IO.userError "unknown node")
  let mut records : List Json := []
  for entry in s.journal.entries do
    if entry.request.node != node then continue
    match entry.request.command with
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

/-- The catalog is generated from the allocation snapshot. There is no arbitrary
    Git path, object ID, filesystem path or controller configuration read API. -/
def resources (repo : FilePath) (current : State) (owner : String) (node serial : Nat) : IO (List Resource) := do
  let some allocation := allocated current node serial | throw (IO.userError "unknown allocation")
  unless allocation.owner == owner do throw (IO.userError "wrong worker")
  let head ← packageSnapshot repo current node serial
  let snapshot ← snapshotState repo head
  let mut result : List Resource := []
  for (n, i) in snapshot.nodes.toList.zipIdx do
    let add (name description content : String) : List Resource :=
      let id := s!"node/{i}/{name}"
      if readable current id then [⟨id, description, content⟩] else []
    result := result ++ add "spec" "Formal requirement definitions" (← Git.readBlob repo n.domain.scope.specification)
    let claims ← Git.resolve repo s!"{n.domain.scope.policy}:claims.json"
    result := result ++ add "claims" "Required clauses for this goal" (← Git.readBlob repo claims)
    let gate ← Git.resolve repo s!"{n.domain.scope.policy}:Gate.lean"
    result := result ++ add "goal" "Exact theorem names and statements the checker requires" (← Git.readBlob repo gate)
    result := result ++ add "route" "Current refinement and child goals" (toJson n.route).pretty
    let attempts := snapshot.journal.entries.filter (fun e => e.request.node == i)
    result := result ++ add "history" "Prior actions, failures, observations and decisions" (toJson attempts).pretty
    for (entry, j) in attempts.zipIdx do
      if let .acquired ticket := entry.reply then
        let id := s!"node/{i}/package-{ticket}-evidence"
        if readable current id then
          result := result ++ [⟨id, "Raw records of this package", (toJson (← packageRecords repo snapshot i ticket)).pretty⟩]
      if let .compose _ _ tree := entry.request.command then
        let id := s!"node/{i}/composition-{j}"
        if readable current id then
          result := result ++ [⟨id, "Raw controller/harness records; model interpretation is separate", ← rawEvidence repo tree⟩]
    for name in ["Queue.lean", "Proofs.lean"] do
      let previousCandidate := (attempts.reverse.find? (fun e => match e.request.command with
        | .submit _ _ => true | _ => false)).bind (fun e => match e.request.command with
          | .submit _ c => some c | _ => none)
      if let some candidate := previousCandidate then
        let path := s!"Axiward/{name}"
        let resolved ← Git.call repo #["rev-parse", "--verify", s!"{candidate.tree}:{path}"]
        if resolved.exitCode == 0 then
          result := result ++ add s!"previous-{name}" "Previous sealed source (may have failed)"
            (← Git.readBlob repo resolved.stdout.trimAscii.toString)
    for (ticket, report) in n.domain.workflow.reports do
      result := result ++ add s!"report-{ticket}" "Model interpretation; not verified fact" (← Git.readBlob repo report)
  return result

def viewDirectory (root : FilePath) (node serial : Nat) : FilePath := root / "work" / "packages" / s!"{node}-{serial}"

def actionGuide : Action → String
  | .execute =>
    "# Execute\n\nRead Spec.lean, Goal.lean and claims.json. Write candidate/Queue.lean and candidate/Proofs.lean. The controller mounts them as Axiward.Queue and Axiward.Proofs alongside the frozen Axiward.Spec. Proofs.lean should import Axiward.Queue and Axiward.Spec and define the exact theorem names/types shown in Goal.lean (in namespace Axiward). Implement the API referenced by those predicates; no sorry, added axioms, unsafe or runtime replacements.\n\nSubmit once with submit. A rejection ends the package: read evidence.json and call next. Resume only continues a sealed check. Exploration requires a separate explore package. Child proof files should normally contain only the assigned claims so distinct modules do not redefine the same declarations.\n"
  | .refine =>
    "# Refine\n\nWrite candidate/plan.json. Fresh children are arrays of clause indices from claims.json; they must be nonempty, disjoint and cover the parent. Existing nodes use {\"reuse\": nodeId}. Example for the full root:\n\n```json\n{\"children\":[[0,1,2],[3,4,5]],\"direct\":false}\n```\n\nOptionally set \"implementation\" to a child SLOT (0-based, not a node ID) when combining different implementations. All proofs are rechecked against that chosen implementation. Without it, child implementations must have identical content.\n\nWrite candidate/Refinement.lean:\n\n```lean\nimport Plan\nnamespace Refinement\ntheorem valid (facts : Nat → Prop) :\n    (∀ child ∈ Plan.children, Holds child facts) → Holds Plan.parent facts := by\n  simp_all [Plan.children, Plan.parent, Holds, and_assoc]\nend Refinement\n```\n\nThe controller generates Plan and Holds from the sealed plan and current parent. You cannot replace those inputs. Submit once. To restore direct implementation while leaving the goal open, use {\"direct\":true}. For an already admitted historical product use {\"result\":{\"node\":nodeId,\"receipt\":\"receipt hash\"}}; it must match this exact goal. Search the snapshot history for available nodes and receipts.\n"
  | .explore =>
    "# Explore\n\nWrite candidate/exploration.json:\n\n```json\n{\"question\":\"What uncertainty blocks this goal?\",\"maxRuns\":2,\"stopWhen\":\"Compare at most two candidates, then report a next step\"}\n```\n\nCall prepare before any experiment. maxRuns is 0..8; zero permits analysis without project execution. R0 permits only the registered checker applied to immutable candidates. Write Queue.lean and Proofs.lean under trials/<name>/; experiment accepts that simple name, never arbitrary commands. Each call consumes one admitted run. A lost response is not permission to run again: retry the SAME request ID for status, or ask the user to reconcile the outstanding operation.\n\nUse evidence to inspect raw observations. External research and reasoning may inform your report, but citations and interpretations are not machine facts. Finish candidate/report.md with observations, interpretation and next-step recommendation kept distinct, then call conclude. No findings is also a valid conclusion. All in-flight operations must first be reconciled. Neither a passing trial nor a report closes this product goal.\n"
  | .requestDecision =>
    "# Request a user decision\n\nWrite candidate/question.json:\n\n```json\n{\"prompt\":\"Which implementation approach should be tried?\",\"subject\":\"Current FIFO goal; this records a preference only\",\"options\":[{\"key\":\"list\",\"label\":\"Use an immutable list\"},{\"key\":\"explore\",\"label\":\"Compare alternatives first\"}]}\n```\n\nUse a short concrete question, a specific subject and 1..4 distinct choices. All branches only record a preference bound to the current scope. They do not change the root, authorize arbitrary actions or prove code. Call submit to register, then ask_user to reach the user through the independent channel. Never supply an answer or invoke the admin CLI yourself. After receiving a durable answer, read whether it is applicable, acknowledge it, and call next. Stale and off-branch replies remain historical input only.\n"

def exportView (repo root : FilePath) (owner : String) (node serial : Nat) : IO Json := do
  let loaded ← Git.load repo
  let some p := allocated loaded.state node serial | throw (IO.userError "unknown package")
  unless p.owner == owner do throw (IO.userError "wrong worker")
  let directory := viewDirectory root node serial
  let candidate := directory / "candidate"
  IO.FS.createDirAll candidate
  let catalog ← resources repo loaded.state owner node serial
  for r in catalog do
    if r.id == s!"node/{node}/spec" then IO.FS.writeFile (directory / "Spec.lean") r.content
    if r.id == s!"node/{node}/claims" then IO.FS.writeFile (directory / "claims.json") r.content
    if r.id == s!"node/{node}/goal" then IO.FS.writeFile (directory / "Goal.lean") r.content
  let currentPhase := ((loaded.state.nodes[node]?).map (fun n =>
    if n.domain.active.any (fun a => a.serial == serial) then phaseName n.domain else "ended")).getD "ended"
  let summary := Json.mkObj [("node", toJson node), ("serial", toJson serial),
    ("action", toJson p.action), ("snapshot", toJson (← packageSnapshot repo loaded.state node serial)),
    ("guide", toJson (directory / "ACTION.md").toString),
    ("goal", toJson (directory / "Goal.lean").toString),
    ("phase", toJson currentPhase),
    ("candidateDirectory", toJson candidate.toString),
    ("resources", toJson (catalog.map (fun r => Json.mkObj [("id", toJson r.id), ("description", toJson r.description)]))),
    ("inbox", inbox loaded.state owner)]
  IO.FS.writeFile (directory / "view.json") summary.pretty
  IO.FS.writeFile (directory / "ACTION.md") (actionGuide p.action)
  IO.FS.writeFile (directory / "WORK.md")
    s!"# Package {node}/{serial}\n\nAction: {repr p.action}. Edit candidate/ only.\n\nUse Axiward tools for project state and additional materials. Never access the canonical repository, controller binary/configuration, or other packages directly. External research is allowed; your notes are not machine evidence. No package expiry.\n\nexecute: Queue.lean + Proofs.lean. refine: plan.json + Refinement.lean. explore: exploration.json, prepare, experiment, report.md, conclude. requestDecision: question.json, submit, ask_user; never fabricate an answer.\n\nA sealed candidate cannot be edited and resubmitted. After rejection acquire a new package. Use resume to finish an interrupted check. Follow next after an ended package.\n"
  return summary

def next (repo root : FilePath) (id owner : String) (selection : Option (Nat × Action) := none) : IO Json := do
  let _ ← Controller.propagate repo
  let loaded ← Git.load repo
  if let some entry := loaded.state.journal.entries.find? (fun e => e.request.id == id) then
    let .begin originalOwner action := entry.request.command | throw (IO.userError "request ID conflict")
    unless originalOwner == owner && selection.all (fun x => x == (entry.request.node, action)) do
      throw (IO.userError "request ID conflict")
    let .acquired serial := entry.reply | throw (IO.userError "invalid allocation reply")
    return ← exportView repo root owner entry.request.node serial
  if selection.isNone then
    for (n, node) in loaded.state.nodes.toList.zipIdx do
      if let some p := n.domain.active then
        if p.owner == owner then return ← exportView repo root owner node p.serial
  if complete loaded.state || loaded.state.domain.workflow.paused then
    return status loaded
  let choice := selection.orElse fun _ => Id.run do
    let mut best : Option (Nat × Action × Nat) := none
    for node in (currentNodes loaded.state.nodes).reverse do
      if let some n := loaded.state.nodes[node]? then
        for r in recommendations loaded.state node n do
          if r.allowed && best.all (fun b => r.score > b.2.2) then best := some (node, r.action, r.score)
    return best.map (fun b => (b.1, b.2.1))
  let some (node, action) := choice | return Json.mkObj [("waiting", toJson true), ("status", status loaded)]
  let reply ← Git.transact repo ⟨id, .controller, .begin owner action, node⟩
  let .acquired serial := reply | throw (IO.userError "allocation failed")
  exportView repo root owner node serial

def search (repo : FilePath) (owner : String) (node serial : Nat) (query : String) : IO Json := do
  let loaded ← Git.load repo
  let catalog ← resources repo loaded.state owner node serial
  let found := catalog.filter (fun r => query.isEmpty ||
    (r.content.toLower.splitOn query.toLower).length > 1 || (r.id.toLower.splitOn query.toLower).length > 1)
  return toJson (found.map (fun r => Json.mkObj [("id", toJson r.id), ("description", toJson r.description),
    ("excerpt", toJson (String.ofList (r.content.toList.take 240)))]))

def readResource (repo : FilePath) (owner : String) (node serial : Nat) (id : String) : IO Json := do
  let loaded ← Git.load repo
  let catalog ← resources repo loaded.state owner node serial
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
  let _ ← Git.load repo
  unless view.isAbsolute && python.isAbsolute && adapter.isAbsolute do
    throw (IO.userError "session paths must be absolute")
  if ← view.pathExists then throw (IO.userError "session requires a new view directory")
  let repoText := repo.normalize.toString.toLower.replace "\\" "/"
  let viewText := view.normalize.toString.toLower.replace "\\" "/"
  if viewText.startsWith (repoText ++ "/") || repoText.startsWith (viewText ++ "/") || repoText == viewText then
    throw (IO.userError "repository and worker view must be separate directories")
  unless (← python.pathExists) && (← adapter.pathExists) do throw (IO.userError "Python or adapter not found")
  let exe ← IO.appPath
  for privatePath in [Sandbox.workRoot repo, exe.parent.getD exe, adapter.parent.getD adapter] do
    let text := privatePath.normalize.toString.toLower.replace "\\" "/"
    if viewText == text || viewText.startsWith (text ++ "/") || text.startsWith (viewText ++ "/") then
      throw (IO.userError "worker view must be separate from protected controller and checker directories")
  let worker ← Git.hashText repo s!"{view}\n{← IO.monoNanosNow}"
  let profileName := "axiward_" ++ String.ofList (worker.toList.take 16)
  IO.FS.createDirAll (view / ".codex")
  IO.FS.createDirAll (view / "work")
  IO.FS.createDirAll (view / "tmp")
  let argv := #["-E", "-s", adapter.toString, "--exe", exe.toString, "--repo", repo.toString,
    "--view", view.toString, "--worker", worker]
  let rules := ["\":root\" = \"read\"", Sandbox.pathRule view "read",
    Sandbox.pathRule (view / "work") "write", Sandbox.pathRule (view / "tmp") "write",
    Sandbox.pathRule repo "deny", Sandbox.pathRule (exe.parent.getD exe) "deny",
    Sandbox.pathRule (Sandbox.workRoot repo) "deny",
    Sandbox.pathRule (adapter.parent.getD adapter) "deny"]
  let inventory ← IO.Process.output { cmd := "codex", args := #["mcp", "list", "--json"] }
  unless inventory.exitCode == 0 do throw (IO.userError "cannot inspect MCP configuration; no unrestricted fallback")
  let services ← Git.decode ((← Git.decode (Json.parse inventory.stdout)).getArr?)
  let mut otherServers := ""
  for service in services do
    let name ← Git.decode (service.getObjValAs? String "name")
    if name != "axiward" then
      let transport ← Git.decode (service.getObjVal? "transport")
      let kind ← Git.decode (transport.getObjValAs? String "type")
      -- Some native defaults are not backed by a user-config transport table.
      -- A complete inert definition avoids inheriting a privileged transport or
      -- writing its credentials into the readable project configuration.
      let disabled := if kind == "stdio" then
          s!"command = {Sandbox.quote exe.toString}\nargs = [\"--version\"]\n"
        else "url = \"https://disabled.invalid\"\n"
      otherServers := otherServers ++
        s!"\n[mcp_servers.{Sandbox.quote name}]\nenabled = false\n" ++ disabled
  let config := "# Axiward: this worker must use the named native profile.\ndefault_permissions = " ++ Sandbox.quote profileName ++
    "\napproval_policy = { granular = { sandbox_approval = false, rules = false, mcp_elicitations = true, request_permissions = false, skill_approval = false } }\n\n" ++
    "[windows]\nsandbox = \"elevated\"\n\n[features]\napps = false\nplugins = false\nhooks = false\nbrowser_use = false\ncomputer_use = false\n\n" ++
    "[permissions." ++ profileName ++ "]\ndescription = \"Axiward project worker\"\nfilesystem = { " ++ String.intercalate ", " rules ++
    " }\nnetwork = { enabled = true }\n\n[shell_environment_policy.set]\n" ++
    "TMP = " ++ Sandbox.quote (view / "tmp").toString ++ "\nTEMP = " ++ Sandbox.quote (view / "tmp").toString ++ "\n\n" ++
    s!"[mcp_servers.axiward]\ncommand = {(toJson python.toString).compress}\nargs = {(toJson argv).compress}\nstartup_timeout_sec = 30\ntool_timeout_sec = 600\ndefault_tools_approval_mode = \"approve\"\n" ++ otherServers
  IO.FS.writeFile (view / ".codex" / "config.toml") config
  IO.FS.writeFile (view / "AGENTS.md")
    "# Axiward worker\n\nUse the Axiward MCP tools for project state. Start with status and next, then read the assigned ACTION.md. Editable package files live under work/packages/; temporary external research files belong in tmp/. This view's unique native Axiward profile denies direct access to the canonical repository and protected controller. The thin adapter provides only permitted views and operations. Do not change permissions or invoke admin commands. External research remains available through native shell/network/web search; unrelated privileged MCP/browser/computer surfaces are disabled for this view.\n\nFollow the assigned action. execute: implementation + proof, submit once. refine: plan.json + Refinement.lean, submit. explore: exploration.json, prepare, experiments as needed, report.md, conclude. requestDecision: question.json, submit, ask_user, read answer, acknowledge. After an ended package call next. Resume sealed checks after interruption; never blindly replay a pending experiment. Keep request IDs stable on retries.\n\nUse one native task per view. Separate tasks use separate views/worker identities against the same managed repository. Never self-approve user questions. Completion requires status.complete=true.\n"
  IO.FS.writeFile (view / "START.md")
    "# Start here\n\nOpen this directory as a trusted Codex project. Confirm the Axiward MCP tools are available. Ask the agent: ‘Use Axiward to advance this project; follow next, ask me when a registered decision needs an answer, and continue until complete.’\n\nOnly this project uses the generated configuration. Restart the task after setup. Reopen the same view to resume; packages never expire.\n"
  return Json.mkObj [("view", toJson view.toString), ("worker", toJson worker),
    ("configuration", toJson (view / ".codex" / "config.toml").toString),
    ("message", toJson "Open this view as a trusted Codex project; no global configuration changed.")]

end Axiward.Interface
