import Axiward

open Axiward Lean System

def require (condition : Bool) (message : String) : IO Unit :=
  unless condition do throw (IO.userError message)

def expectFailure (operation : IO α) (message : String) : IO Unit := do
  let failed ← try let _ ← operation; pure false catch _ => pure true
  require failed message

/-- Protocol fixtures simulate checked outputs; actual Lean proofs are exercised
    by integration.py. These cases cover revision while packages are in flight. -/
def protocolCases : IO Unit := do
  let a : Requirement := ⟨"a", "one"⟩
  let b : Requirement := ⟨"b", "one"⟩
  let root : Scope := ⟨0, "root", "root-policy", [a, b]⟩
  let scopeA : Scope := ⟨0, "a", "a-policy", [a]⟩
  let scopeB : Scope := ⟨0, "b", "b-policy", [b]⟩
  let mut state ← Git.decode (restore { initial := root })
  let advance (s : State) (r : Request) : IO State := do
    return (← Git.decode ((step s r).mapError (fun e => s!"{repr e}"))).after
  state ← advance state ⟨"plan-begin", .controller, .begin "planner" .refine, 0⟩
  state ← advance state ⟨"plan-submit", .worker "planner", .submit 0 ⟨"plan"⟩, 0⟩
  state ← advance state ⟨"plan-check", .controller, .finishRefinement 0
    (.passed ⟨root, ⟨"plan"⟩, [.fresh scopeA, .fresh scopeB], "fixture-certificate", none⟩) "fixture", 0⟩
  state ← advance state ⟨"a-begin", .controller, .begin "worker-a" .execute, 1⟩
  state ← advance state ⟨"b-begin", .controller, .begin "worker-b" .execute, 2⟩
  state ← advance state ⟨"a-submit", .worker "worker-a", .submit 0 ⟨"candidate-a"⟩, 1⟩
  state ← advance state ⟨"b-submit", .worker "worker-b", .submit 0 ⟨"candidate-b"⟩, 2⟩
  let frames := packageFrames state.nodes
  let replacement : Scope := ⟨0, "root-two", "policy-two", [⟨"a", "two"⟩, b]⟩
  state ← advance state ⟨"change-root", .user, .revise root replacement, 0⟩
  require (packageFrames state.nodes == frames) "revision changed outstanding packages"
  require ((step state ⟨"stale-root-change", .user, .revise root replacement, 0⟩).toOption.isNone)
    "stale root confirmation overwrote a later revision"
  state ← advance state ⟨"a-result", .controller, .finish 0
    (.passed ⟨scopeA, ⟨"candidate-a"⟩, "a-product", "a-receipt"⟩) "fixture", 1⟩
  state ← advance state ⟨"b-result", .controller, .finish 0
    (.passed ⟨scopeB, ⟨"candidate-b"⟩, "b-product", "b-receipt"⟩) "fixture", 2⟩
  let some nodeA := state.nodes[1]? | throw (IO.userError "missing node A")
  let some nodeB := state.nodes[2]? | throw (IO.userError "missing node B")
  require (nodeA.domain.published.isNone && nodeA.domain.active.isNone) "stale result was published"
  require nodeB.domain.published.isSome "unaffected outstanding package could not finish"
  state ← advance state ⟨"reuse-begin", .controller, .begin "planner" .refine, 0⟩
  state ← advance state ⟨"reuse-submit", .worker "planner", .submit 1 ⟨"reuse"⟩, 0⟩
  let fake : Publication := ⟨state.domain.scope, ⟨"fake"⟩, "fake-product", "fake-receipt"⟩
  require ((step state ⟨"forged-admission", .controller, .finishRefinement 1
    (.reused ⟨state.domain.scope, ⟨"reuse"⟩, 99, fake, "new-receipt"⟩) "fixture", 0⟩).toOption.isNone)
    "unadmitted historical evidence passed the kernel guard"

def main (args : List String) : IO UInt32 := do
  try
    protocolCases
    let [path] := args | throw (IO.userError "store_scenarios <new-absolute-project-directory>")
    let repo : FilePath := path
    Git.initRepository repo
    let spec ← Git.hashText repo "-- storage fixture, not a proof certificate\n"
    let policy ← Git.tree repo none #[⟨"Axiward/Spec.lean", spec⟩]
    Git.create repo ⟨0, spec, policy, []⟩
    require ((← IO.FS.readFile (repo / ".gitignore")) == "/.view/\n") "worker spaces are not ignored"
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
    let replay ← Git.transact repo request
    require (replay == .acquired 0) "idempotent request changed result"
    require ((← Git.load repo).head == after.head) "replay created another commit"
    expectFailure (Git.transact repo ⟨"begin", .controller, .begin "different" .execute, 0⟩)
      "same request ID accepted different content"
    expectFailure (Git.transact repo ⟨"attack", .worker "worker-b", .cancel 0 "attack", 0⟩)
      "foreign worker cancelled a package"
    let candidate ← Git.tree repo none #[⟨"Axiward/Queue.lean", spec⟩]
    let _ ← Git.transact repo ⟨"submit", .worker "worker-a", .submit 0 ⟨candidate⟩, 0⟩
    let restored ← Git.load repo
    require (restored.state.domain.active.any (fun p => p.phase == .checking ⟨candidate⟩))
      "sealed package was not recovered"
    let _ ← Git.transact repo ⟨"revision", .user, .revise restored.state.domain.scope ⟨0, spec, policy, []⟩, 0⟩
    let verdict := Verdict.unknown "simulated verifier disconnect"
    let _ ← Git.transact repo ⟨"stale-result", .controller, .finish 0 verdict policy, 0⟩
    let rejected ← Git.load repo
    require (rejected.state.domain.active.isNone && rejected.state.domain.published.isNone)
      "stale verification retained occupancy or published a result"
    let journal := rejected.state.journal
    let badEntries := journal.entries.map fun e =>
      if e.request.id == "submit" then { e with reply := .accepted 0 } else e
    let badBlob ← Git.hashText repo (toJson { journal with entries := badEntries }).compress
    let badTree ← Git.tree repo (some rejected.head) #[⟨".axiward/state.json", badBlob⟩]
    let badCommit ← Git.commitTree repo badTree (some rejected.head) "injected journal corruption\n"
    require (← Git.compareAndSwap repo (some rejected.head) badCommit) "corruption fixture failed"
    expectFailure (Git.load repo) "corrupt journal was loaded"
    IO.println "PASS: stale CAS, source preservation, replay, request conflict, owner check, sealed recovery, stale scope, corrupt journal"
    return 0
  catch error =>
    IO.eprintln error.toString
    return 1
