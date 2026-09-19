import Axiward.Interface

open Axiward Lean System

def emit (json : Json) : IO Unit := IO.println json.compress

def serialOf (text : String) : IO Nat :=
  match text.toNat? with
  | some n => pure n
  | none => throw (IO.userError "node/package ID must be a natural number")

def actionOf (text : String) : IO Action :=
  match text with
  | "execute" => pure .execute
  | "refine" => pure .refine
  | "explore" => pure .explore
  | "requestDecision" => pure .requestDecision
  | _ => throw (IO.userError "supported actions: execute, refine, explore, requestDecision")

def send (repo : String) (id : String) (actor : Actor) (command : Axiward.Command)
    (node : Nat) : IO Unit := do
  emit (toJson (← Git.transact repo ⟨id, actor, command, node⟩))

def usage : String := "axiward init <new-absolute-project-directory> <trusted-policy-dir> <lean-toolchain>\n\
  axiward session <repo> <repo/.view/new-package-space> <python.exe> <adapter/server.py>\n\
  axiward overview <repo>\n\
  axiward worker-status <repo> <worker-id> [view]\n\
  axiward next <repo> <request-id> <worker-id> <view> <node> <action>\n\
  axiward next <repo> <request-id> <worker-id> <view> (resume bound package only)\n\
  axiward search <repo> <worker-id> <node> <serial> <query>\n\
  axiward view-add <repo> <worker-id> <view> <node> <serial> <resource-id>\n\
  axiward decide <repo> <request-id> <node> <serial> <choice> <comment> (user-only)\n\
  axiward pause <repo> <request-id> <reason> | resume <repo> <request-id> (user-only)\n\
  axiward deliver <repo> [new-project-relative-directory=delivery]\n\
  axiward reconcile <repo> <request-id> <node> <operation-id> <runner-stopped-reason> (user-only)\n\
  axiward access <repo> <request-id> <resource-id> allow|deny (user-only)\n\
  axiward status <repo>\n\
  axiward begin <repo> <request-id> <worker-id> [node=0 action=execute]\n\
  axiward submit <repo> <request-id> <worker-id> <serial> <candidate-dir> [node=0]\n\
  axiward check <repo> <request-id> <serial> [node=0]\n\
  axiward compose <repo> <node> [new-request-id-for-retry]\n\
  axiward revise-preview <repo> <request-id> <registered-policy-dir>\n\
  axiward revise <repo> <request-id> <registered-policy-dir> <review-token> (user-only)\n\
  axiward cancel <repo> <request-id> <worker-id> <serial> <reason> [node=0]\n\
  axiward reclaim <repo> <request-id> <node> <serial> <reason> (controller-only; stop worker first)\n\
  Controller CLI: protect this entry point; worker identity comes from its harness adapter."

def main (args : List String) : IO UInt32 := do
  try
    let args := match args with
      | ["begin", repo, id, owner] => ["begin", repo, id, owner, "0", "execute"]
      | ["submit", repo, id, owner, serial, directory] => ["submit", repo, id, owner, serial, directory, "0"]
      | ["check", repo, id, serial] => ["check", repo, id, serial, "0"]
      | ["cancel", repo, id, owner, serial, reason] => ["cancel", repo, id, owner, serial, reason, "0"]
      | other => other
    match args with
    | ["init", repo, policy, toolchain] =>
      Sandbox.requireCodex
      let _ ← FifoPolicy.validateRoot policy
      Git.initRepository repo
      let scope ← Verifier.importPolicy repo policy toolchain
      Git.create repo scope
      emit (Json.mkObj [("initialized", toJson repo), ("scope", toJson scope)])
    | ["status", repo] =>
      let loaded ← Git.load repo
      let obsolete := loaded.state.nodes.toList.zipIdx.filterMap fun (node, i) =>
        if scopeUsable loaded.state.nodes node.domain.scope then none else some i
      emit (Json.mkObj [("head", toJson loaded.head), ("state", toJson loaded.state.domain),
        ("nodes", toJson loaded.state.nodes), ("rootClosed", toJson loaded.state.domain.published.isSome),
        ("complete", toJson (complete loaded.state)),
        ("invalidatedPackages", Controller.invalidatedPackages loaded.state),
        ("obsoleteGoals", toJson obsolete),
        ("transitions", toJson loaded.state.journal.entries.length)])
    | ["begin", repo, id, owner, node, action] =>
      let loaded ← Git.load repo
      unless loaded.state.journal.entries.any (fun entry => entry.request.id == id) do
        Sandbox.requireCodex
      send repo id .controller (.begin owner (← actionOf action)) (← serialOf node)
    | ["submit", repo, id, owner, serial, directory, node] =>
      let node ← serialOf node
      let serial ← serialOf serial
      let loaded ← Git.load repo
      let some action := Controller.submissionAction loaded.state node serial
        | throw (IO.userError "unknown package")
      if (action == .execute || action == .refine) &&
          !loaded.state.journal.entries.any (fun entry => entry.request.id == id) then
        Sandbox.requireCodex
      let candidate ← match action with
        | .execute => Verifier.importCandidate repo directory
        | .refine => Refinement.importCandidate repo directory
        | .explore | .requestDecision => FlowIO.importCandidate repo directory action
      send repo id (.worker owner) (.submit serial candidate) node
    | ["cancel", repo, id, owner, serial, reason, node] =>
      send repo id (.worker owner) (.cancel (← serialOf serial) reason) (← serialOf node)
    | ["reclaim", repo, id, node, serial, reason] =>
      send repo id .controller (.cancel (← serialOf serial) reason) (← serialOf node)
    | ["check", repo, id, serial, node] =>
      let reply ← Controller.check repo id (← serialOf node) (← serialOf serial)
      let parents ← try Controller.propagate repo catch error => do
        IO.eprintln s!"Parent propagation pending: {error}"
        pure []
      unless parents.isEmpty do IO.eprintln s!"Composed parent nodes: {parents}"
      Git.synchronize repo
      let current ← Git.load repo
      unless (obsoletePackages current.state).isEmpty do
        IO.eprintln (Json.mkObj [("invalidatedPackages", Controller.invalidatedPackages current.state)]).compress
      emit (toJson reply)
    | ["compose", repo, node] => emit (toJson (← Controller.compose repo (← serialOf node)))
    | ["compose", repo, node, id] => emit (toJson (← Controller.compose repo (← serialOf node) (some id)))
    | ["revise-preview", repo, id, policy] => emit (← Controller.revision repo id policy)
    | ["revise", repo, id, policy, base] => emit (← Controller.revision repo id policy (some base))
    | ["overview", repo] => emit (Interface.status (← Git.load repo))
    | ["worker-status", repo, owner, view] =>
      let loaded ← Git.load repo
      if let some (node, serial) := Interface.sessionPackage loaded.state owner then
        emit (← Interface.exportViewLoaded repo view loaded owner node serial false)
      else
        let result ← Interface.workerStatus repo loaded
        emit (result.setObjVal! "guide" (toJson (FilePath.mk view / "AGENTS.md").toString))
    | ["worker-status", repo, _owner] =>
      let loaded ← Git.load repo
      emit (← Interface.workerStatus repo loaded)
    | ["session", repo, view, python, adapter] => emit (← Interface.session repo view python adapter)
    | ["package-info", repo, owner, node, serial] =>
      emit (← Interface.packageInfo repo owner (← serialOf node) (← serialOf serial))
    | ["package-view", repo, owner, view, node, serial] =>
      emit (← Interface.exportView repo view owner (← serialOf node) (← serialOf serial))
    | ["next", repo, id, owner, view] => emit (← Interface.next repo view id owner)
    | ["next", repo, id, owner, view, node, action] =>
      emit (← Interface.next repo view id owner (some (← serialOf node, ← actionOf action)))
    | ["search", repo, owner, node, serial, query] =>
      emit (← Interface.search repo owner (← serialOf node) (← serialOf serial) query)
    | ["read", repo, owner, node, serial, resource] =>
      emit (← Interface.readResource repo owner (← serialOf node) (← serialOf serial) resource)
    | ["view-add", repo, owner, view, node, serial, resource] =>
      emit (← Interface.addResource repo view owner (← serialOf node) (← serialOf serial) resource)
    | ["evidence", repo, owner, view, node, serial] =>
      emit (← Interface.evidence repo view owner (← serialOf node) (← serialOf serial))
    | ["start-experiment", repo, id, owner, node, serial, directory] =>
      emit (← FlowIO.startExperiment repo id owner (← serialOf node) (← serialOf serial) directory)
    | ["run-experiment", repo, node, id] => emit (← FlowIO.runExperiment repo (← serialOf node) id)
    | ["record-experiment", repo, node, id, capture] =>
      emit (toJson (← FlowIO.recordExperiment repo (← serialOf node) id capture))
    | ["conclude", repo, id, owner, node, serial, report] =>
      emit (toJson (← FlowIO.conclude repo id owner (← serialOf node) (← serialOf serial) report))
    | ["decide", repo, id, node, serial, choice, comment] =>
      send repo id .user (.workflow (.answer (← serialOf serial) choice comment)) (← serialOf node)
    | ["pause", repo, id, reason] => send repo id .user (.workflow (.pause true reason)) 0
    | ["resume", repo, id] => send repo id .user (.workflow (.pause false "")) 0
    | ["access", repo, id, resource, permission] =>
      unless permission == "allow" || permission == "deny" do throw (IO.userError "expected allow or deny")
      send repo id .user (.workflow (.access resource (permission == "allow"))) 0
    | ["reconcile", repo, id, node, operation, reason] =>
      emit (toJson (← FlowIO.reconcile repo id (← serialOf node) operation reason))
    | ["deliver", repo] => emit (← Interface.delivery repo)
    | ["deliver", repo, directory] => emit (← Interface.delivery repo directory)
    | ["--version"] => IO.println "Axiward 0.2.0 (R0; Lean 4.34.0; Windows; FIFO verifier)"
    | ["--help"] | [] => IO.println usage
    | _ => throw (IO.userError usage)
    return 0
  catch error =>
    emit (Json.mkObj [("error", toJson error.toString)])
    return 1
