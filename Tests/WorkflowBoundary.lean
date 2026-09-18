import Axiward

open Axiward Lean System

def require (condition : Bool) (message : String) : IO Unit :=
  unless condition do throw (IO.userError message)

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
      let trial := repo / ".view/worker/work/trials/trial"
      IO.FS.createDirAll trial
      IO.FS.writeFile (trial / "Queue.lean") "protocol fixture"
      let first ← FlowIO.startExperiment repo "worker/trial" "worker" 0 0 trial
      require ((first.getObjValAs? Bool "replayed").toOption == some false) "new intent was not dispatched once"
      let _ ← Git.transact repo ⟨"cancel", .worker "worker", .cancel 0 "disconnected", 0⟩
      let replay ← FlowIO.startExperiment repo "worker/trial" "worker" 0 0 trial
      require ((replay.getObjValAs? Bool "replayed").toOption == some true) "lost intent was restarted"
      let before ← Git.load repo
      let captureFile := repo.parent.getD repo / "capture.json"
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
