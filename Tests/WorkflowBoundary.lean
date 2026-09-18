import Axiward

open Axiward Lean System

def require (condition : Bool) (message : String) : IO Unit :=
  unless condition do throw (IO.userError message)

def routeCase (repo : FilePath) (scope : Scope) (certificate : String) : IO Unit := do
  let advance (s : State) (actor : Actor) (command : Axiward.Command) (node : Nat := 0) : IO State := do
    return (← Git.decode ((step s ⟨s!"fixture-{s.journal.entries.length}", actor, command, node⟩).mapError reprStr)).after
  let mut s ← Git.decode (restore { initial := scope })
  s ← advance s .controller (.begin "planner" .refine)
  s ← advance s (.worker "planner") (.submit 0 ⟨certificate⟩)
  s ← advance s .controller (.finishRefinement 0
    (.passed ⟨scope, ⟨certificate⟩, [.fresh scope, .fresh scope], certificate, none⟩) certificate)
  s ← advance s .controller (.begin "worker-a" .execute) 1
  s ← advance s .controller (.begin "worker-b" .execute) 2
  s ← advance s .controller (.begin "planner-2" .refine)
  s ← advance s (.worker "planner-2") (.submit 1 ⟨certificate⟩)
  let before ← Git.load repo
  let journal ← Git.hashText repo (toJson s.journal).compress
  let tree ← Git.tree repo (some before.head) #[⟨".axiward/state.json", journal⟩]
    #[(".axiward/route", certificate), (".axiward/candidate", certificate),
      (".axiward/nodes/1/policy", scope.policy), (".axiward/nodes/2/policy", scope.policy)]
  let head ← Git.commitTree repo tree (some before.head) "route-change fixture\n"
  require (← Git.compareAndSwap repo (some before.head) head) "fixture commit failed"
  let _ ← Git.transact repo ⟨"replace-route", .controller, .finishRefinement 1
    (.passed ⟨scope, ⟨certificate⟩, [.reuse ⟨2, scope⟩, .fresh scope], certificate, none⟩) certificate, 0⟩
  let loaded ← Git.load repo
  let alerts : List Json ← Git.decode (fromJson? (Controller.invalidatedPackages loaded.state))
  require (alerts.length == 1 && alerts.head?.any (fun alert =>
    (alert.getObjValAs? Nat "node").toOption == some 1 &&
    (alert.getObjValAs? Nat "serial").toOption == some 0 &&
    (alert.getObjValAs? String "owner").toOption == some "worker-a"))
    "route invalidation missed A or incorrectly stopped the reused shared node B"
  -- End the root by a different direct route. Old workers remain recorded, but
  -- must not make the interface postpone an otherwise complete project.
  let mut doneState := loaded.state
  doneState ← advance doneState .controller (.begin "direct" .refine)
  doneState ← advance doneState (.worker "direct") (.submit 2 ⟨certificate⟩)
  doneState ← advance doneState .controller (.finishRefinement 2
    (.passed ⟨scope, ⟨certificate⟩, [], certificate, none⟩) certificate)
  doneState ← advance doneState .controller (.begin "closer" .execute)
  doneState ← advance doneState (.worker "closer") (.submit 3 ⟨certificate⟩)
  doneState ← advance doneState .controller (.finish 3
    (.passed ⟨scope, ⟨certificate⟩, certificate, scope.specification⟩) certificate)
  require (complete doneState && (obsoletePackages doneState).length == 2)
    "obsolete workers delayed completion"
  let executable := (← IO.appPath).parent.getD repo / "axiward.exe"
  let output ← IO.Process.output {
    cmd := executable.toString
    args := #["reclaim", repo.toString, "reclaim-a", "1", "0", "Codex worker stopped by discussion agent"] }
  require (output.exitCode == 0) output.stdout
  let after ← Git.load repo
  require ((obsoletePackages after.state).isEmpty &&
    after.state.nodes[2]?.any (fun n => n.domain.active.any (fun p => p.owner == "worker-b")))
    "controller reclaim disturbed the retained shared worker"

/-- Synthetic verifier values exercise IO retention, never mathematical acceptance.
    Actual Lean acceptance/rejection is checked by verifier_boundary. -/
def main (args : List String) : IO UInt32 := do
  try
    let [kind, repoName] := args | throw (IO.userError "workflow_boundary <late|intent> <repo>")
    let repo : FilePath := repoName
    Git.initRepository repo
    let spec ← Git.hashText repo "protocol fixture, not a proof\n"
    let policy ← Git.tree repo none #[⟨"Axiward/Spec.lean", spec⟩]
    let scope : Scope := ⟨0, spec, policy, []⟩
    Git.create repo scope
    if kind == "route" then
      routeCase repo scope policy
      IO.println "PASS: route invalidation projection and controller reclaim; proof values are fixtures"
      return 0
    let plan : ExplorePlan := ⟨"test transport recovery", 1, "one observation"⟩
    let planBlob ← Git.hashText repo (toJson plan).compress
    let candidate : Candidate := ⟨← Git.tree repo none #[⟨"exploration.json", planBlob⟩]⟩
    let action := if kind == "late" then Action.execute else .explore
    let _ ← Git.transact repo ⟨"begin", .controller, .begin "worker" action, 0⟩
    let _ ← Git.transact repo ⟨"submit", .worker "worker", .submit 0 candidate, 0⟩
    if kind == "late" then
      let product ← Git.tree repo none #[⟨"artifact.txt", spec⟩]
      let receipt ← Git.hashText repo "synthetic receipt for retention only"
      let evidence ← Git.tree repo none #[⟨"process.txt", spec⟩]
      let output : CheckedOutput := ⟨scope, candidate, product, receipt⟩
      let command := Command.finish 0 (.passed output) evidence
      -- A real short process waits for cancellation, then returns its controlled
      -- result. No sleeps or races with a compiler determine test correctness.
      let child ← IO.Process.spawn {
        cmd := "python"
        args := #["-c", "import sys; sys.stdin.readline(); print(sys.argv[1])", (toJson command).compress]
        stdin := .piped
        stdout := .piped
        stderr := .piped }
      let _ ← Git.transact repo ⟨"cancel", .worker "worker", .cancel 0 "process still in flight", 0⟩
      child.stdin.putStrLn "return result"
      child.stdin.flush
      let raw ← child.stdout.readToEnd
      require ((← child.wait) == 0) "controlled process failed"
      let returned : Axiward.Command ← Git.decode (fromJson? (← Git.decode (Json.parse raw)))
      let reply ← Controller.recordCheck repo "late" 0 0 candidate returned
      require (reply == .archived 0) "late result was not archived"
      let loaded ← Git.load repo
      let path := s!"{loaded.head}:.axiward/late-checks/4"
      require ((← Git.resolve repo s!"{path}/product") == product &&
        (← Git.resolve repo s!"{path}/receipt.json") == receipt &&
        (← Git.resolve repo s!"{path}/check") == evidence) "late artifacts were lost"
      require ((← Git.readBlob repo (← Git.resolve repo s!"{path}/late-result.json")) == (toJson returned).compress)
        "late command bytes changed"
      require (loaded.state.domain.active.isNone && loaded.state.domain.published.isNone)
        "late result was published"
      require ((← Controller.recordedCheck repo "late" 0 0) == some reply) "late replay lost its result"
      require ((← Git.load repo).head == loaded.head) "late replay wrote another event"
    else
      require ((← Controller.check repo "prepare" 0 0) == .prepared 0) "plan admission failed"
      let trial := repo / ".view/worker/trials/trial"
      IO.FS.createDirAll trial
      IO.FS.writeFile (trial / "Queue.lean") "protocol fixture"
      let first ← FlowIO.startExperiment repo "worker/trial" "worker" 0 0 trial
      require ((first.getObjValAs? Bool "replayed").toOption == some false) "new intent was not dispatched once"
      let _ ← Git.transact repo ⟨"cancel", .worker "worker", .cancel 0 "disconnected", 0⟩
      let replay ← FlowIO.startExperiment repo "worker/trial" "worker" 0 0 trial
      require ((replay.getObjValAs? Bool "replayed").toOption == some true) "lost intent was restarted"
      let before ← Git.load repo
      let captureFile := repo / ".view" / "capture.json"
      let command := #[(← IO.appPath).toString, "run-experiment", repo.toString, "0", "worker/trial"]
      let capture (completed : Bool) := Json.mkObj [
        ("source", toJson "codex-command-exec"), ("command", toJson command),
        ("completed", toJson completed), ("capped", toJson false), ("exitCode", toJson (1 : Int)),
        ("stdout", toJson ""), ("stderr", toJson "controlled transport failure")]
      IO.FS.writeFile captureFile (capture false).compress
      let refused ← try
        let _ ← FlowIO.recordExperiment repo 0 "worker/trial" captureFile
        pure false
      catch _ => pure true
      require refused "incomplete process capture was admitted"
      require ((← Git.load repo).head == before.head) "rejected capture changed the journal"
      IO.FS.writeFile captureFile (capture true).compress
      require ((← FlowIO.recordExperiment repo 0 "worker/trial" captureFile) == .observed "worker/trial")
        "completed failure was not recorded"
      let after ← Git.load repo
      require (pendingOperations after.state == 0) "completed failure left an outstanding intent"
      let blob ← Git.resolve repo s!"{after.head}:.axiward/operations/0/evidence/native.json"
      require ((← Git.readBlob repo blob) == (capture true).compress) "native capture was not retained exactly"
    IO.println s!"PASS: workflow IO {kind} (synthetic verdict; no mathematical claim)"
    return 0
  catch error =>
    IO.eprintln error.toString
    return 1
