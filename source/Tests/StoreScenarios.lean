import Axiward

open Axiward Lean System

def require (condition : Bool) (message : String) : IO Unit :=
  unless condition do throw (IO.userError message)

def expectFailure (operation : IO α) (message : String) : IO Unit := do
  let failed ← try let _ ← operation; pure false catch _ => pure true
  require failed message

def batchCase (repo : FilePath) : IO Unit := do
  let first := "标题：队列 🧪\nsecond line\n"
  let last := "\nλ → 最后一个对象"
  let a ← Git.hashText repo first
  let b ← Git.hashText repo ""
  let c ← Git.hashText repo last
  let tree ← Git.tree repo none #[⟨"a.txt", a⟩, ⟨"empty.txt", b⟩, ⟨"c.txt", c⟩]
  let refs := #[s!"{tree}:c.txt", a, s!"{tree}:a.txt", s!"{tree}:empty.txt"]
  require ((← Git.resolveMany repo refs (some "blob")) == #[c, a, a, b])
    "batch resolution lost order, duplicate references or object identity"
  require ((← Git.readBlobs repo refs) == #[last, first, first, ""])
    "batch reads changed Unicode bytes, whitespace, order or duplicate objects"
  require ((← Git.resolveMany repo #[]).isEmpty && (← Git.readBlobs repo #[]).isEmpty)
    "an empty query manufactured an object"
  expectFailure (Git.resolveMany repo #[a, s!"{tree}:absent"] (some "blob"))
    "a partially missing resolution batch was accepted"
  expectFailure (Git.readBlobs repo #[a, s!"{tree}:absent"])
    "a partially missing blob batch was accepted"
  expectFailure (Git.resolveMany repo #[a, tree] (some "blob"))
    "batch resolution accepted a tree where a blob was required"
  expectFailure (Git.readBlobs repo #[a, tree])
    "batch blob reading accepted a tree"
  expectFailure (Git.resolveMany repo #[a ++ "\n" ++ c] (some "blob"))
    "a newline changed the number of requested objects"
  expectFailure (Git.readBlobs repo #[a ++ "\n" ++ c])
    "a newline redirected a blob request"

def main (args : List String) : IO UInt32 := do
  try
    let [kind, path] := args | throw (IO.userError "store_scenarios <batch|cas|sealed|checked-race|corruption> <new-absolute-project-directory>")
    unless ["batch", "cas", "sealed", "checked-race", "corruption"].contains kind do throw (IO.userError "unknown storage case")
    let repo : FilePath := path
    Git.initRepository repo
    expectFailure (Git.initRepository repo) "initialization overwrote an existing checkout"
    if kind == "batch" then
      batchCase repo
      IO.println "PASS: ordered batch identity, exact Unicode blobs, missing objects and wrong types"
      return 0
    let spec ← Git.hashText repo "-- storage fixture, not a proof certificate\n"
    let policy ← Git.tree repo none #[⟨"Axiward/Spec.lean", spec⟩,
      ⟨"acceptance.json", ← Git.hashText repo "{\"specificationPath\":\"Axiward/Spec.lean\"}"⟩]
    Git.create repo ⟨0, spec, policy, []⟩
    require ((← IO.FS.readFile (repo / ".gitignore")) == "/.view/\n/.checks/\n/delivery/\n") "worker spaces are not ignored"
    if kind == "cas" then
      let initial ← Git.load repo
      let marker ← Git.hashText repo "preserve this unrelated source file\n"
      let seeded ← Git.tree repo (some initial.head) #[⟨"existing.txt", marker⟩]
      let seededCommit ← Git.commitTree repo seeded (some initial.head) "test fixture\n"
      require (← Git.compareAndSwap repo (some initial.head) seededCommit) "seed failed"
      require ((← IO.FS.readFile (repo / "existing.txt")) == "preserve this unrelated source file\n")
        "authoritative source was not checked out"
      let a ← Git.load repo
      let b ← Git.load repo
      let request : Request := ⟨"begin", .controller, .begin "worker-a" .execute, 0⟩
      let ca ← Git.decode ((step a.state request).mapError (fun e => s!"{repr e}"))
      let cb ← Git.decode ((step b.state ⟨"other", .controller, .begin "worker-b" .execute, 0⟩).mapError
        (fun e => s!"{repr e}"))
      require (← Git.commitChange repo a ca) "first CAS failed"
      require (!(← Git.commitChange repo b cb)) "stale CAS overwrote the winner"
      let after ← Git.load repo
      require ((← Git.resolve repo s!"{after.head}:existing.txt") == marker) "unrelated source lost"
      let competing : Request := ⟨"competing-loaded", .controller, .begin "worker-b" .execute, 0⟩
      let error ← try
          let _ ← Git.transact repo competing (some b)
          pure ""
        catch error => pure error.toString
      require ((error.splitOn "occupied").length > 1 &&
        (← Git.resolve repo "HEAD") == after.head &&
        after.state.domain.active.any (fun package => package.owner == "worker-a"))
        s!"a transaction reused the stale state after losing CAS: {error}"
      let replay ← Git.transact repo request
      require (replay == .acquired 0) "idempotent request changed result"
      require ((← Git.load repo).head == after.head) "replay created another commit"
      expectFailure (Git.transact repo ⟨"begin", .controller, .begin "different" .execute, 0⟩)
        "same request ID accepted different content"
      expectFailure (Git.transact repo ⟨"attack", .worker "worker-b", .cancel 0 "attack", 0⟩)
        "foreign worker cancelled a package"
      IO.println "PASS: storage CAS, source preservation and request replay"
      return 0
    let _ ← Git.transact repo ⟨"begin", .controller, .begin "worker-a" .execute, 0⟩
    let candidate ← Git.tree repo none #[⟨"Axiward/Queue.lean", spec⟩]
    let _ ← Git.transact repo ⟨"submit", .worker "worker-a", .submit 0 ⟨candidate⟩, 0⟩
    if kind == "checked-race" then
      let checkedAt ← Git.load repo
      let receipt ← Git.hashText repo "synthetic checked result; only the stale-HEAD guard is under test"
      let _ ← Git.transact repo ⟨"competing-pause", .user, .workflow (.pause true "race fixture"), 0⟩
      let competingHead ← Git.resolve repo "HEAD"
      let command := Command.finish 0
        (.passed ⟨checkedAt.state.domain.scope, ⟨candidate⟩, candidate, receipt⟩) policy
      let error ← try
          let _ ← Controller.recordCheck repo "stale-checked" 0 0 ⟨candidate⟩ command (some checkedAt)
          pure ""
        catch error => pure error.toString
      require ((error.splitOn "formal state changed during verification").length > 1)
        s!"a checked result escaped the exact-HEAD guard: {error}"
      let current ← Git.load repo
      require (current.head == competingHead && current.state.domain.workflow.paused &&
        current.state.domain.published.isNone && current.state.domain.active.any
          (fun package => package.phase == .checking ⟨candidate⟩))
        "a stale checked result changed the current commit, publication or sealed input"
      IO.println "PASS: a checked result cannot publish after its loaded HEAD changes"
      return 0
    if kind == "sealed" then
      let restored ← Git.load repo
      require (restored.state.domain.active.any (fun p => p.phase == .checking ⟨candidate⟩))
        "sealed package was not recovered"
      let _ ← Git.transact repo ⟨"revision", .user, .revise restored.state.domain.scope ⟨0, spec, policy, []⟩, 0⟩
      let verdict := Verdict.unknown "simulated verifier disconnect"
      let _ ← Git.transact repo ⟨"stale-result", .controller, .finish 0 verdict policy, 0⟩
      let rejected ← Git.load repo
      require (rejected.state.domain.active.isNone && rejected.state.domain.published.isNone)
        "stale verification retained occupancy or published a result"
      IO.println "PASS: sealed recovery and stale-version refusal"
      return 0
    -- A protocol publication isolates storage binding from Lean proof checking.
    let product ← Git.tree repo none #[⟨"result.txt", spec⟩]
    let receipt ← Git.hashText repo "synthetic receipt for storage binding"
    let current ← Git.load repo
    let _ ← Git.transact repo ⟨"publish", .controller, .finish 0
      (.passed ⟨current.state.domain.scope, ⟨candidate⟩, product, receipt⟩) policy, 0⟩
    let published ← Git.load repo
    let changed ← Git.hashText repo "changed after publication"
    let changedTree ← Git.tree repo (some published.head) #[⟨"product/result.txt", changed⟩]
    let changedCommit ← Git.commitTree repo changedTree (some published.head) "artifact corruption fixture\n"
    require (← Git.compareAndSwap repo (some published.head) changedCommit) "artifact corruption fixture failed"
    expectFailure (Git.load repo) "changed published bytes passed the receipt binding"
    require (← Git.compareAndSwap repo (some changedCommit) published.head) "fixture restore failed"
    let missing ← Git.tree repo none #[]
      #[(".axiward/policy", policy), ("product", product)]
    expectFailure (Git.verifyBindings repo missing published.state.nodes) "missing receipt passed batch bindings"
    let wrongKind ← Git.tree repo none #[]
      #[(".axiward/policy", policy), ("product", product), (".axiward/receipt.json", product)]
    let wrongNodes := published.state.nodes.map fun node =>
      { node with domain := { node.domain with published := node.domain.published.map fun p =>
        { p with receipt := product } } }
    expectFailure (Git.verifyBindings repo wrongKind wrongNodes) "tree object was accepted as a receipt blob"
    let journal := published.state.journal
    let badEntries := journal.entries.map fun e =>
      if e.request.id == "submit" then { e with reply := .accepted 0 } else e
    let badBlob ← Git.hashText repo (toJson { journal with entries := badEntries }).compress
    let badTree ← Git.tree repo (some published.head) #[⟨".axiward/state.json", badBlob⟩]
    let badCommit ← Git.commitTree repo badTree (some published.head) "injected journal corruption\n"
    require (← Git.compareAndSwap repo (some published.head) badCommit) "corruption fixture failed"
    expectFailure (Git.load repo) "corrupt journal was loaded"
    IO.println "PASS: product/receipt object binding and corrupt journal refusal"
    return 0
  catch error =>
    IO.eprintln error.toString
    return 1
