import Axiward.Verifier

namespace Axiward.FlowIO

open Lean System

def candidateFile (action : Action) : String :=
  if action == .explore then "exploration.json" else "question.json"

def importCandidate (repo directory : FilePath) (action : Action) : IO Candidate := do
  let marker ← Git.hashText repo "axiward-workflow-v1"
  let mut blobs : Array Git.Blob := #[⟨"submission.txt", marker⟩]
  let name := candidateFile action
  if ← (directory / name).pathExists then
    blobs := blobs.push ⟨name, ← Git.hashFile repo (directory / name)⟩
  return ⟨← Git.tree repo none blobs⟩

def check (repo : FilePath) (scope : Scope) (p : Package) (candidate : Candidate) (usable : Bool) :
    IO WorkflowCommand := do
  if p.input != scope || !usable then return .reject p.serial "scope changed"
  try
    let oid ← Git.resolve repo s!"{candidate.tree}:{candidateFile p.action}"
    let json ← Git.decode (Json.parse (← Git.readBlob repo oid))
    if p.action == .explore then
      let plan : ExplorePlan ← Git.decode (fromJson? json)
      unless validPlan plan do throw (IO.userError "invalid exploration plan: question, 0..8 trials, stopWhen required")
      return .prepare p.serial plan
    else
      let question : Question ← Git.decode (fromJson? json)
      unless validQuestion question do throw (IO.userError "invalid question: concrete subject and 1..4 distinct choices required")
      return .ask p.serial question
  catch error => return .reject p.serial error.toString

/-- The caller may run a checker only when it owns the newly committed intent.
    Replayed launch requests are returned as pending, never executed again. -/
def startExperiment (repo : FilePath) (id owner : String) (node serial : Nat) (directory : FilePath) : IO Json := do
  let loaded ← Git.load repo
  let some target := loaded.state.nodes[node]? | throw (IO.userError "unknown node")
  let candidate ← Verifier.importCandidate repo directory
  if let some entry := loaded.state.journal.entries.find? (fun e => e.request.id == id) then
    unless entry.request.node == node && entry.request.command == .workflow (.launch serial id candidate) do
      throw (IO.userError "request ID conflict")
    let original := loaded.state.journal.entries.find? (fun e =>
      e.request.node == node && e.reply == .acquired serial)
    unless original.any (fun e => e.request.command == .begin owner .explore) do
      throw (IO.userError "wrong worker/package")
    return Json.mkObj [("replayed", toJson true), ("operation", toJson
      (target.domain.workflow.operations.find? (fun op => op.id == id)))]
  let some p := target.domain.active | throw (IO.userError "no active package")
  unless p.owner == owner && p.serial == serial do throw (IO.userError "wrong worker/package")
  let tx ← Git.transactDetailed repo ⟨id, .controller, .workflow (.launch serial id candidate), node⟩
  if !tx.change.changed then
    return Json.mkObj [("replayed", toJson true), ("operation", toJson id),
      ("message", toJson "intent already exists; consult observation or reconcile; never blindly rerun")]
  return Json.mkObj [("replayed", toJson false), ("operation", toJson id),
    ("input", toJson p.input), ("candidate", toJson candidate)]

def runExperiment (repo : FilePath) (node : Nat) (id : String) : IO Json := do
  let loaded ← Git.load repo
  let some target := loaded.state.nodes[node]? | throw (IO.userError "unknown node")
  let some op := target.domain.workflow.operations.find? (fun o => o.id == id)
    | throw (IO.userError "operation not admitted")
  unless op.result.isNone do throw (IO.userError "operation already observed")
  let result ← Verifier.check repo op.input op.candidate
  return Json.mkObj [("verdict", toJson result.verdict), ("evidence", toJson result.evidence),
    ("input", toJson op.input), ("candidate", toJson op.candidate)]

structure NativeCapture where
  source : String
  command : Array String
  completed : Bool
  capped : Bool
  exitCode : Int
  stdout : String
  stderr : String
  deriving FromJson

def windowsPathKey (path : String) : String :=
  path.replace "\\\\?\\" "" |>.replace "/" "\\" |>.toLower

/-- This input file is provided only by the protected adapter, never by a tool's
    worker arguments. A transport failure leaves the intent outstanding. -/
def recordExperiment (repo : FilePath) (node : Nat) (id : String) (captureFile : FilePath) : IO Reply := do
  let raw ← IO.FS.readFile captureFile
  let capture : NativeCapture ← Git.decode (fromJson? (← Git.decode (Json.parse raw)))
  let expected := #[(← IO.appPath).toString, "run-experiment", repo.toString, toString node, id]
  let bound := capture.command.size == 5 && (List.range 5).all (fun i =>
    let actual := capture.command[i]?.getD ""
    let wanted := expected[i]?.getD ""
    if i == 0 || i == 2 then windowsPathKey actual == windowsPathKey wanted else actual == wanted)
  unless capture.source == "codex-command-exec" && capture.completed &&
      bound do
    throw (IO.userError "native execution binding or completion missing; reconcile before retry")
  let nativeBlob ← Git.hashText repo raw
  let (verdict, subtrees) ← if !capture.capped && capture.exitCode == 0 then do
      let output ← Git.decode (Json.parse capture.stdout)
      let verdict : Verdict ← Git.decode (output.getObjValAs? Verdict "verdict")
      let evidence ← Git.decode (output.getObjValAs? String "evidence")
      pure (verdict, #[("verifier", evidence)])
    else pure (Verdict.unknown "native command failed or output was truncated", #[])
  let evidence ← Git.tree repo none #[⟨"native.json", nativeBlob⟩] subtrees
  Git.transact repo ⟨id ++ "/result", .controller, .workflow (.observe id verdict evidence), node⟩

def reconcile (repo : FilePath) (id : String) (node : Nat) (operationId reason : String) : IO Reply := do
  -- This user/controller operation is only valid after the owning harness process
  -- has stopped. It records UNKNOWN and never retries the candidate.
  if reason.trimAscii.toString.isEmpty then throw (IO.userError "reconciliation reason required")
  let blob ← Git.hashText repo reason
  let evidence ← Git.tree repo none #[⟨"reconciliation.txt", blob⟩]
  Git.transact repo ⟨id, .controller, .workflow (.observe operationId
    (.unknown ("user confirmed runner stopped; " ++ reason)) evidence), node⟩

def conclude (repo : FilePath) (id owner : String) (node serial : Nat) (report : FilePath) : IO Reply := do
  if (← IO.FS.readFile report).length > 64000 then throw (IO.userError "report exceeds 64000 characters")
  let blob ← Git.hashFile repo report
  Git.transact repo ⟨id, .worker owner, .workflow (.conclude serial blob), node⟩

end Axiward.FlowIO
