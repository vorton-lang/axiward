import Axiward.Diagnostics

open Axiward Lean System

private def require (condition : Bool) (message : String) : IO Unit :=
  unless condition do throw (IO.userError message)

private def dataAt (value : Json) (keys : List String) : IO Json :=
  keys.foldlM (fun current key => Git.decode (current.getObjVal? key)) value

/-- A captured Lean/Lake message shape. This checks evidence projection and Git
    binding only; it is not a new execution of the mathematical verifier. -/
private def failedOutput : String :=
  "✖ [4/10] Building Axiward.Proofs (891ms)\n" ++
  "trace: retained compiler command\n" ++
  "error: Axiward/Proofs.lean:14:81: unsolved goals\n" ++
  "α : Type u\nn : Nat\nq : Queue α n\nitem : α\n" ++
  "room : q.items.length < n\n⊢ item :: q.items = q.items ++ [item]\n" ++
  "✔ [7/10] Built Main (945ms)\nSome required targets logged failures:\n- Axiward.Proofs\n"

def main (args : List String) : IO Unit := do
  let [output] := args | throw (IO.userError "usage: Diagnostics.lean <new-output-directory>")
  let directory : FilePath := output
  unless directory.isAbsolute do throw (IO.userError "absolute output directory required")
  if ← directory.pathExists then throw (IO.userError "use a fresh output directory")
  let started ← IO.monoMsNow
  IO.FS.createDirAll directory
  let repo := directory / "project"
  Git.initRepository repo
  let submitted ← Git.tree repo none #[⟨"source.txt", ← Git.hashText repo "sealed package source"⟩]
  let merged ← Git.tree repo none #[⟨"source.txt", ← Git.hashText repo "actual merged source"⟩]
  let input := Json.mkObj [("candidate", toJson (Candidate.mk merged)),
    ("scope", Json.mkObj [("policy", toJson "joint checked policy")]),
    ("controller", toJson "recorded controller")]
  let inputBlob ← Git.hashText repo input.compress
  let stage := Json.mkObj [("name", toJson "01-build"), ("arguments", toJson ["build", "Gate"]),
    ("exitCode", toJson (1 : Nat)), ("elapsedMs", toJson (3015 : Nat)),
    ("stdout", toJson failedOutput), ("stderr", toJson "error: build failed\n")]
  let stageBlob ← Git.hashText repo stage.compress
  let verification ← Git.tree repo none #[⟨"input.json", inputBlob⟩, ⟨"01-build.json", stageBlob⟩]
  let mergeBinding ← Git.hashText repo (Json.mkObj [("head", toJson "formal head at checking"),
    ("submitted", toJson (Candidate.mk submitted)), ("merged", toJson (Candidate.mk merged))]).compress
  let checked ← Git.tree repo none #[⟨"merge.json", mergeBinding⟩]
    #[("verification", verification), ("merged", merged)]
  let reused ← Git.tree repo none #[] #[("merge", checked)]
  let late ← Git.tree repo none #[] #[("check", reused)]
  let resource := "current/node/1/package-0-evidence"
  let diagnostics ← Diagnostics.read repo late resource
  let checks : Array Json ← Git.decode (diagnostics.getObjValAs? _ "checks")
  require (checks.size == 1) "known evidence wrappers lost or duplicated the actual check"
  let check := checks[0]!
  require ((← dataAt check ["prefix"]) == toJson "check/merge/verification/")
    "diagnostic source path is not bound to the retained nested check"
  require ((← dataAt check ["input", "blob"]) == toJson inputBlob &&
    (← dataAt check ["input", "record"]) == input && merged != submitted)
    "diagnostics substituted a submitted candidate or current state for the actual check input"
  let stages : Array Json ← Git.decode (check.getObjValAs? _ "stages")
  require (stages.size == 1 && (← dataAt stages[0]! ["record"]) == stage &&
    (← dataAt stages[0]! ["blob"]) == toJson stageBlob)
    "diagnostics truncated or changed the retained tool output"
  let messages : Array Json ← Git.decode (stages[0]!.getObjValAs? _ "messages")
  require (messages.size == 2) "Lean error or stderr was lost"
  require ((← dataAt messages[0]! ["location"]) == Json.mkObj [("file", toJson "Axiward/Proofs.lean"),
    ("line", toJson (14 : Nat)), ("column", toJson (81 : Nat))]) "Lean source position was not extracted"
  let raw : String ← Git.decode (messages[0]!.getObjValAs? _ "raw")
  require (raw == "error: Axiward/Proofs.lean:14:81: unsolved goals\n" ++
    "α : Type u\nn : Nat\nq : Queue α n\nitem : α\n" ++
    "room : q.items.length < n\n⊢ item :: q.items = q.items ++ [item]")
    "Lean local context or unproved goal changed during projection"
  require ((← dataAt diagnostics ["sourceResource"]) == toJson resource &&
    (← dataAt diagnostics ["evidenceTree"]) == toJson late)
    "diagnostics lost its complete raw-evidence entry"
  let missing := Diagnostics.messages "stdout"
    ("error: no such file or directory (error code: 4058)\n  file: C:\\snapshot\\Axiward\\Proofs.lean\n" ++
     "✖ [3/10] Running Gate\nerror: Gate.lean: bad import 'Axiward.Proofs'\n")
  require (missing.size == 2 && missing.all (fun message => message.getObjValD "location" == Json.null))
    "missing-file/import errors acquired a fabricated source position"
  let windows := Diagnostics.messages "stdout" "error: C:\\snapshot\\Proofs.lean:2:3: unsolved goals\n⊢ False"
  require ((← dataAt windows[0]! ["location", "file"]) == toJson "C:\\snapshot\\Proofs.lean")
    "a Windows drive colon corrupted the Lean source position"
  IO.FS.writeFile (directory / "diagnostics.json") diagnostics.pretty
  IO.println s!"PASS: immutable merged input, complete failure output, Lean context and no invented positions ({(← IO.monoMsNow) - started} ms)"
