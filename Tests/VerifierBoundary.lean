import Axiward

open Axiward Lean System

def require (condition : Bool) (message : String) : IO Unit :=
  unless condition do throw (IO.userError message)

def expectRefusal (operation : IO α) (reason : String) : IO Unit := do
  let error ← try let _ ← operation; pure "" catch error => pure error.toString
  require ((error.splitOn reason).length > 1) s!"expected {reason}, received {error}"

/-- Only setup certificates are fixtures. Tests below run the production merge,
    verifier, controller commit and content bindings on these frozen inputs. -/
def saveFixture (repo : FilePath) (state : State) : IO Unit := do
  let mut blobs : Array Git.Blob := #[⟨".axiward/state.json", ← Git.hashText repo (toJson state.journal).compress⟩]
  let mut trees : Array (String × String) := #[]
  for (n, id) in state.nodes.toList.zipIdx do
    let path := Git.nodePath id
    trees := trees.push (s!"{path}/policy", n.domain.scope.policy)
    if let some r := n.route then trees := trees.push (s!"{path}/route", r.certificate)
    if let some p := n.domain.published then
      trees := trees.push (Git.productPath id, p.product)
      blobs := blobs.push ⟨s!"{path}/receipt.json", p.receipt⟩
    if let some p := n.domain.active then
      if let .checking c := p.phase then trees := trees.push (s!"{path}/candidate", c.tree)
  if let some source := sourceAt state.journal.entries then trees := trees.push ("source", source.tree)
  let tree ← Git.tree repo none blobs trees
  let head ← Git.commitTree repo tree none "frozen boundary fixture\n"
  require (← Git.compareAndSwap repo none head) "fixture commit failed"

def mergeCase (repo : FilePath) (scope : Scope) (queue proofs kind : String) : IO Unit := do
  let proofs := (proofs.splitOn "theorem dequeue_some").head! ++ "end Axiward\n"
  let source (code proof : String) : IO Candidate := do
    return ⟨← Git.tree repo none #[⟨"Axiward/Queue.lean", ← Git.hashText repo code⟩,
      ⟨"Axiward/Proofs.lean", ← Git.hashText repo proof⟩]⟩
  let base ← source queue proofs
  let current ← source ("-- accepted A\n" ++ queue) proofs
  let proposedQueue := if kind == "merge-conflict" then "-- proposed B\n" ++ queue
    else queue ++ "\n-- proposed B\n"
  let proposedProof := if kind == "merge-breaks-prior" then
      (proofs.splitOn "theorem enqueue_room").head! ++ "theorem enqueue_full" ++
        (proofs.splitOn "theorem enqueue_full").getLast!
    else proofs
  let submitted ← source proposedQueue proposedProof
  let seedScope ← FifoPolicy.restrictScope repo scope [0]
  let aScope ← FifoPolicy.restrictScope repo scope [1]
  let bScope ← FifoPolicy.restrictScope repo scope [2]
  let todoScope ← FifoPolicy.restrictScope repo scope [3, 4, 5]
  let receipt ← Git.hashText repo "setup fixture; actual revalidation follows"
  let certificate ← Git.tree repo none #[⟨"fixture.txt", receipt⟩]
  let advance (s : State) (actor : Actor) (command : Axiward.Command) (node : Nat := 0) : IO State := do
    return (← Git.decode ((step s ⟨s!"setup-{s.journal.entries.length}", actor, command, node⟩).mapError reprStr)).after
  let mut s ← Git.decode (restore { initial := scope })
  s ← advance s .controller (.begin "planner" .refine)
  s ← advance s (.worker "planner") (.submit 0 ⟨certificate⟩)
  s ← advance s .controller (.finishRefinement 0 (.passed ⟨scope, ⟨certificate⟩,
    [.fresh seedScope, .fresh aScope, .fresh bScope, .fresh todoScope], certificate, none⟩) certificate)
  s ← advance s .controller (.begin "seed" .execute) 1
  s ← advance s (.worker "seed") (.submit 0 base) 1
  s ← advance s .controller (.finish 0 (.passed ⟨seedScope, base, base.tree, receipt⟩) certificate) 1
  s ← advance s .controller (.begin "a" .execute) 2
  s ← advance s .controller (.begin "b" .execute) 3
  s ← advance s (.worker "a") (.submit 0 current) 2
  s ← advance s .controller (.finish 0 (.passed ⟨aScope, current, current.tree, receipt⟩) certificate) 2
  s ← advance s (.worker "b") (.submit 0 submitted) 3
  saveFixture repo s
  let domain (state : State) (id : Nat) : IO Domain := do
    let some n := state.nodes[id]? | throw (IO.userError "missing fixture node")
    return n.domain
  if kind == "merge-race" then
    let loaded ← Git.load repo
    let merged ← Git.mergeSource repo (some base) (some current) submitted
    require merged.clean "race fixture unexpectedly conflicted"
    let candidate : Candidate := ⟨merged.tree⟩
    let required := requiredResults s.nodes
    let check : MergeCheck := ⟨some base, some current, submitted, candidate,
      required.map (fun p => ⟨p, ⟨p.publication.scope, candidate, candidate.tree, receipt⟩⟩),
      .passed ⟨bScope, candidate, candidate.tree, receipt⟩, none⟩
    let _ ← Git.transact repo ⟨"race", .user, .workflow (.pause true "race fixture"), 0⟩
    expectRefusal (Controller.recordCheck repo "merge" 3 0 submitted (.integrate 0 check certificate) (some loaded))
      "formal state changed during verification"
    let after ← Git.load repo
    require (sourceAt after.state.journal.entries == some current && (← domain after.state 3).active.isSome)
      "stale verdict published or discarded the sealed package"
    return
  let reply ← Controller.check repo "merge" 3 0
  let after ← Git.load repo
  require ((← Git.resolve repo s!"{after.head}:.axiward/nodes/3/candidate") == submitted.tree)
    "source merging replaced the original sealed candidate"
  if kind == "merged" then
    require (reply == .accepted 0) s!"disjoint merge rejected: {repr reply}"
    let some accepted := (← domain after.state 3).published | throw (IO.userError "missing merged result")
    let code ← Git.readBlob repo (← Git.resolve repo s!"{accepted.candidate.tree}:Axiward/Queue.lean")
    require (code.startsWith "-- accepted A" && code.endsWith "-- proposed B\n") "one merge side was lost"
    for node in [1, 2] do
      require ((← domain after.state node).published.any (fun p => p.candidate == accepted.candidate))
        "old guarantee was not rebound to the merged source"
    let claims : List Nat ← Git.decode (fromJson? (← Git.decode (Json.parse
      (← Git.readBlob repo (← Git.resolve repo s!"{accepted.product}:claims.json")))))
    require (claims == [2, 0, 1] && (← domain after.state 4).published.isNone)
      "joint verification included unfinished goals or omitted an accepted guarantee"
  else
    let .rejected _ reason := reply | throw (IO.userError "unsafe candidate was not rejected")
    require ((reason.splitOn (if kind == "merge-conflict" then "source conflict" else "01-build")).length > 1)
      "wrong merge rejection"
    require (sourceAt after.state.journal.entries == some current &&
      (← domain after.state 1).published == (← domain s 1).published &&
      (← domain after.state 2).published == (← domain s 2).published &&
      (← domain after.state 3).active.isNone) "failed merge changed formal source or prior guarantees"

def metadataCase (repo source : FilePath) (scope : Scope) (kind : String) : IO Unit := do
  if kind == "revision" then
    Git.create repo scope
    let before ← Git.resolve repo "HEAD"
    let directory := source / "examples/fifo/policy-overwrite"
    let preview ← Controller.revision repo "change" directory
    let token : String ← Git.decode (preview.getObjValAs? String "reviewToken")
    let impact ← Git.decode (preview.getObjVal? "impact")
    require ((impact.getObjValAs? (List String) "changedRequirements").toOption == some ["fifo/2"])
      "policy adapter changed unrelated requirement identities"
    expectRefusal (Controller.revision repo "change" (source / "examples/fifo/policy") (some token))
      "reviewed change no longer matches"
    require ((← Git.resolve repo "HEAD") == before) "preview or wrong confirmation changed state"
    let applied ← Controller.revision repo "change" directory (some token)
    require ((applied.getObjVal? "impact").toOption == some impact) "preview and applied impacts differ"
    let after ← Git.resolve repo "HEAD"
    let replay ← Controller.revision repo "change" directory (some token)
    require ((replay.getObjValAs? Bool "alreadyApplied").toOption == some true &&
      (← Git.resolve repo "HEAD") == after) "revision replay was applied twice"
    expectRefusal (Controller.revision repo "stale" (source / "examples/fifo/policy") (some token))
      "reviewed change no longer matches"
    let altered := repo.parent.getD repo / "altered-policy"
    for path in Verifier.policyFiles do
      let target := altered / path
      IO.FS.createDirAll (target.parent.getD altered)
      let text ← IO.FS.readFile (source / "examples/fifo/policy" / path)
      IO.FS.writeFile target (if path == "Gate.lean" then
        text.replace "Axiward.Q0.Created n" "False ∧ Axiward.Q0.Created n" else text)
    expectRefusal (FifoPolicy.validateRoot altered) "unsupported root policy"
  else
    -- The prior acceptance is a protocol fixture. This checks receipt bytes,
    -- object existence and admission lookup, not the fixture's mathematics.
    let blob ← Git.hashText repo "historically admitted fixture artifact"
    let product ← Git.tree repo none #[⟨"artifact.txt", blob⟩]
    let candidate : Candidate := ⟨product⟩
    let receiptJson := Json.mkObj [("scope", toJson scope), ("candidate", toJson candidate),
      ("product", toJson product)]
    let receipt ← Git.hashText repo receiptJson.compress
    let admitted (receipt : String) : IO State := do
      let initial ← Git.decode (restore { initial := scope })
      let a ← Git.decode ((step initial ⟨"begin", .controller, .begin "worker" .execute, 0⟩).mapError reprStr)
      let b ← Git.decode ((step a.after ⟨"submit", .worker "worker", .submit 0 candidate, 0⟩).mapError reprStr)
      let c ← Git.decode ((step b.after ⟨"accept", .controller, .finish 0
        (.passed ⟨scope, candidate, product, receipt⟩) product, 0⟩).mapError reprStr)
      return c.after
    let state ← admitted receipt
    let result ← Refinement.reuseResult repo { scope with revision := 1 } candidate ⟨0, receipt⟩ state
    let .reused output := result.verdict | throw (IO.userError "compatible historical receipt was rejected")
    require (output.source.product == product) "reuse rebuilt or replaced the historic artifact"
    let unadmitted ← Refinement.reuseResult repo scope candidate ⟨0, "not-admitted"⟩ state
    require (unadmitted.verdict == .rejected "source was never admitted") "unadmitted history reused"
    let changed ← Refinement.reuseResult repo { scope with specification := "changed" } candidate ⟨0, receipt⟩ state
    require (changed.verdict == .rejected "historical result has a different checked goal") "changed goal reused old proof"
    let forged ← Git.hashText repo (Json.mkObj [("scope", toJson scope), ("candidate", toJson candidate),
      ("product", toJson "wrong-product")]).compress
    let forgedState ← admitted forged
    let mismatch ← Refinement.reuseResult repo scope candidate ⟨0, forged⟩ forgedState
    require (mismatch.verdict == .rejected "historical receipt binding mismatch") "receipt mismatch reused"
    require (!(← (Sandbox.workRoot repo).pathExists)) "compatible historical reuse unnecessarily reran verification"

/-- Child certificates are fixtures; shared-source parent checking, propagation,
    atomic publication and the committed executable are real. -/
def compositionCase (repo : FilePath) (scope : Scope) (queue proofs : String) : IO Unit := do
  let source ← Git.tree repo none #[⟨"Axiward/Queue.lean", ← Git.hashText repo queue⟩,
    ⟨"Axiward/Proofs.lean", ← Git.hashText repo proofs⟩]
  let receipt ← Git.hashText repo "protocol fixture child receipt"
  let certificate ← Git.tree repo none #[⟨"fixture.txt", receipt⟩]
  let left ← FifoPolicy.restrictScope repo scope [0, 1, 2]
  let right ← FifoPolicy.restrictScope repo scope [3, 4, 5]
  let advance (s : State) (actor : Actor) (command : Axiward.Command) (node : Nat := 0) : IO State := do
    return (← Git.decode ((step s ⟨s!"fixture-{s.journal.entries.length}", actor, command, node⟩).mapError reprStr)).after
  let mut state ← Git.decode (restore { initial := scope })
  state ← advance state .controller (.begin "planner" .refine)
  state ← advance state (.worker "planner") (.submit 0 ⟨certificate⟩)
  state ← advance state .controller (.finishRefinement 0
    (.passed ⟨scope, ⟨certificate⟩, [.fresh left, .fresh right], certificate, none⟩) certificate)
  for (node, goal) in [(1, left), (2, right)] do
    state ← advance state .controller (.begin "worker" .execute) node
    state ← advance state (.worker "worker") (.submit 0 ⟨source⟩) node
    state ← advance state .controller (.finish 0
      (.passed ⟨goal, ⟨source⟩, source, receipt⟩) certificate) node
  saveFixture repo state
  require ((← Controller.propagate repo) == [0]) "ready parent did not automatically compose"
  let head ← Git.resolve repo "HEAD"
  let _ ← Git.resolve repo s!"{head}:.axiward/compositions/10/03-replay.json"
  let run ← IO.Process.output {
    cmd := (repo / "product/.lake/build/bin/fifo_demo.exe").toString
    args := #["2", "a", "b"] }
  require (run.exitCode == 0 && (run.stdout.splitOn "dequeue: value=a").length == 2)
    "committed shared-source program did not run"

/-- Each invocation builds one new real candidate with the production verifier.
    There is no cached verdict or chain of unrelated lifecycle scenarios. -/
def main (args : List String) : IO UInt32 := do
  try
    let [kind, repoName, sourceName, toolchainName] := args
      | throw (IO.userError "verifier_boundary <case> <repo> <source> <toolchain>")
    let repo : FilePath := repoName
    let source : FilePath := sourceName
    let toolchain : FilePath := toolchainName
    Git.initRepository repo
    let scope ← Verifier.importPolicy repo (source / "examples/fifo/policy") toolchain
    let directory := repo.parent.getD repo / "candidate"
    IO.FS.createDirAll directory
    if kind == "revision" || kind == "reuse" then
      metadataCase repo source scope kind
      IO.println s!"PASS: production policy/receipt IO {kind}"
      return 0
    if kind == "refinement" || kind == "omitted-clause" then
      let plan := (if kind == "refinement" then "{\"children\":[[0,1,2],[3,4,5]]"
        else "{\"children\":[[0,1,2],[3,4]]") ++ ",\"direct\":false,\"implementation\":null,\"result\":null}"
      IO.FS.writeFile (directory / "plan.json") plan
      IO.FS.writeFile (directory / "Refinement.lean")
        (← IO.FS.readFile (source / "examples/fifo/refinement/Refinement.lean"))
      let candidate ← Refinement.importCandidate repo directory
      let state ← Git.decode (restore { initial := scope })
      let result ← Refinement.check repo scope candidate state
      if kind == "refinement" then
        let .passed output := result.verdict | throw (IO.userError s!"refinement rejected: {repr result.verdict}")
        require (output.children.length == 2) "refinement lost its child partition"
        let _ ← Git.resolve repo s!"{output.certificate}:Gate.olean"
        let _ ← Git.resolve repo s!"{output.certificate}:03-replay.json"
      else
        require (result.verdict == .rejected "01-build did not pass") "omitted goal did not fail real proof checking"
        let _ ← Git.resolve repo s!"{result.evidence}:01-build.json"
      IO.println s!"PASS: real refinement verifier {kind}"
      return 0
    let original := source / "examples/fifo/candidate"
    let queue ← IO.FS.readFile (original / "Queue.lean")
    let proofs ← IO.FS.readFile (original / "Proofs.lean")
    if kind.startsWith "merge" then
      mergeCase repo scope queue proofs kind
      IO.println s!"PASS: shared source {kind}"
      return 0
    if kind == "assembled" then
      compositionCase repo scope queue proofs
      IO.println s!"PASS: production composition {kind}"
      return 0
    IO.FS.writeFile (directory / "Queue.lean")
      (if kind == "wrong-fifo" then queue.replace "q.items ++ [item]" "item :: q.items" else queue)
    if kind != "missing-proof" then
      IO.FS.writeFile (directory / "Proofs.lean")
        (if kind == "sorry" then proofs.replace "  intro room\n  simp [Queue.enqueue, room]" "  sorry" else proofs)
    let candidate ← Verifier.importCandidate repo directory
    -- Prepare a valid sealed journal in one fixture commit. CLI allocation and
    -- sealing persistence are independently covered by store/handoff checks.
    let initial ← Git.decode (restore { initial := scope })
    let begin ← Git.decode ((step initial ⟨"begin", .controller, .begin "worker" .execute, 0⟩).mapError reprStr)
    let sealed ← Git.decode ((step begin.after ⟨"submit", .worker "worker", .submit 0 candidate, 0⟩).mapError reprStr)
    let journal ← Git.hashText repo (toJson sealed.after.journal).compress
    let tree ← Git.tree repo none #[⟨".axiward/state.json", journal⟩]
      #[(".axiward/policy", scope.policy), (".axiward/candidate", candidate.tree)]
    let head ← Git.commitTree repo tree none "sealed verifier input fixture\n"
    require (← Git.compareAndSwap repo none head) "fixture commit failed"
    -- Local draft mutation must not alter the object passed to the verifier.
    IO.FS.writeFile (directory / "Queue.lean") "unsubmitted replacement"
    let reply ← Controller.check repo "check" 0 0
    let loaded ← Git.load repo
    let evidence ← Git.resolve repo s!"{loaded.head}:.axiward/checks/0"
    let binding ← Git.decode (Json.parse (← Git.readBlob repo (← Git.resolve repo s!"{evidence}:verification/input.json")))
    require ((binding.getObjValAs? Candidate "candidate").toOption == some candidate)
      "raw check evidence is not bound to the sealed candidate"
    if kind == "accepted" then
      require (reply == .accepted 0) s!"valid candidate rejected: {repr reply}"
      let destination := repo.parent.getD repo / "delivery"
      let _ ← Interface.delivery repo destination
      let run ← IO.Process.output {
        cmd := (destination / ".lake/build/bin/fifo_demo.exe").toString
        args := #["2", "a", "b", "c"] }
      require (run.exitCode == 0 && (run.stdout.splitOn "enqueue c: accepted=false").length == 2 &&
        (run.stdout.splitOn "dequeue: value=a").length == 2 &&
        (run.stdout.splitOn "dequeue: value=b").length == 2) "committed delivery does not run"
    else
      let .rejected _ reason := reply | throw (IO.userError s!"expected rejection: {repr reply}")
      let expected := if kind == "sorry" then "02-audit" else "01-build"
      require ((reason.splitOn expected).length == 2) s!"wrong rejection stage: {reason}"
      let log ← Git.resolve repo s!"{evidence}:verification/{expected}.json"
      let raw ← Git.readBlob repo log
      require (!raw.isEmpty && loaded.state.domain.active.isNone && loaded.state.domain.published.isNone)
        "rejection lost evidence, occupancy or publication guard"
    IO.println s!"PASS: real verifier {kind}"
    return 0
  catch error =>
    IO.eprintln error.toString
    return 1
