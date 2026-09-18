import Lean.Data.Json

open Lean
open System (FilePath)

-- The controller owns these paths. The worker supplies only a candidate ID.
def workspace : FilePath :=
  "LEGACY_WORKSPACE"
def policyRoot : FilePath := workspace / "outputs" / "axiward-m0-l2" / "trusted"
def workRoot : FilePath := workspace / "work" / "m0-l2"
def toolchainDir : FilePath := workspace / "work" / "m0-l1" / "lean-4.34.0-windows"

def policyNames : Array String :=
  #["Axiward/Spec.lean", "Gate.lean", "Audit.lean", "Main.lean", "lakefile.toml", "lean-toolchain"]
def toolNames : Array String :=
  #["bin/lean.exe", "bin/lake.exe", "bin/leanchecker.exe", "bin/clang.exe", "bin/ld.lld.exe"]
def artifactNames : Array String := policyNames ++ #[
  "Axiward/Queue.lean", "Axiward/Proofs.lean", "audit.json",
  ".lake/build/lib/lean/Axiward/Queue.olean",
  ".lake/build/lib/lean/Axiward/Proofs.olean", ".lake/build/lib/lean/Gate.olean",
  ".lake/build/ir/Axiward/Queue.c", ".lake/build/ir/Main.c",
  ".lake/build/bin/fifo_demo.exe"]

structure Binding where
  path : String
  sha256 : String
  deriving BEq, ToJson, FromJson

structure Receipt where
  schema : Nat
  candidate : String
  policy : Array Binding
  tools : Array Binding
  verifier : String
  artifacts : Array Binding
  deriving ToJson, FromJson

def requireId (id : String) : IO Unit := do
  unless !id.isEmpty && id.length ≤ 80 &&
      id.toList.all (fun c => c.isAlphanum || c == '-' || c == '_') do
    throw <| IO.userError "Invalid identifier"

def decode {α : Type} (value : Except String α) : IO α :=
  match value with
  | .ok a => pure a
  | .error e => throw <| IO.userError e

def sha256 (file : FilePath) : IO String := do
  let result ← IO.Process.output {
    cmd := "C:/Windows/System32/certutil.exe"
    args := #["-hashfile", file.toString, "SHA256"] }
  if result.exitCode != 0 then
    throw <| IO.userError s!"Hash failed: {file}: {result.stderr} {result.stdout}"
  let hashes := (result.stdout.splitOn "\n").filterMap fun line =>
    let value := line.trimAscii.toString.toLower
    if value.length == 64 && value.toList.all (fun c => c.isDigit || ('a' ≤ c && c ≤ 'f'))
    then some value else none
  match hashes with
  | [value] => return value
  | _ => throw <| IO.userError s!"Unrecognized SHA-256 response: {file}"

def bindings (base : FilePath) (names : Array String) : IO (Array Binding) :=
  names.mapM fun (name : String) => do
    let hash ← sha256 (base / name)
    return (⟨name, hash⟩ : Binding)

def copyFile (source destination : FilePath) : IO Unit := do
  IO.FS.writeBinFile destination (← IO.FS.readBinFile source)

def step (run snapshot : FilePath) (name : String) (arguments : Array String) : IO Unit := do
  IO.eprintln s!"L2 {name}"
  let start ← IO.monoMsNow
  let result ← IO.Process.output {
    cmd := (toolchainDir / "bin" / "lake.exe").toString
    args := arguments
    cwd := some snapshot }
  let log := Json.mkObj [
    ("arguments", toJson arguments), ("cwd", toJson snapshot.toString),
    ("exitCode", toJson result.exitCode.toNat),
    ("durationMs", toJson ((← IO.monoMsNow) - start)),
    ("stdout", toJson result.stdout), ("stderr", toJson result.stderr)]
  IO.FS.writeFile (run / s!"{name}.json") log.compress
  if result.exitCode != 0 then
    throw <| IO.userError s!"{name} did not pass; evidence: {run}"

def checkCandidate (id : String) : IO String := do
  requireId id
  let candidate := workRoot / "candidates" / id
  for name in #["Spec.lean", "Axiward/Spec.lean", "Gate.lean", "Audit.lean",
      "Main.lean", "lakefile.toml", "lean-toolchain"] do
    if ← (candidate / name).pathExists then
      throw <| IO.userError s!"Candidate tried to supply controller-owned file: {name}"
  let rootBefore ← bindings policyRoot policyNames
  let toolsBefore ← bindings toolchainDir toolNames
  let verifierBefore ← sha256 (← IO.appPath)
  let runId := s!"run-{← IO.monoNanosNow}"
  let run := workRoot / "runs" / runId
  let snapshot := run / "snapshot"
  IO.FS.createDirAll (snapshot / "Axiward")
  for name in policyNames do copyFile (policyRoot / name) (snapshot / name)
  for name in #["Queue.lean", "Proofs.lean"] do
    copyFile (candidate / name) (snapshot / "Axiward" / name)
  let sourceNames := policyNames ++ #["Axiward/Queue.lean", "Axiward/Proofs.lean"]
  let sourcesBefore ← bindings snapshot sourceNames
  IO.FS.writeFile (run / "inputs.json") (toJson sourcesBefore).compress
  -- Candidate caches/build scripts are never copied into this fresh snapshot.
  step run snapshot "01-fixed-goal-build" #["--no-cache", "build", "Gate", "fifo_demo"]
  step run snapshot "02-environment-audit" #["env", "lean", "Audit.lean"]
  -- The fixed toolchain's library was rechecked in L1; replay every local module.
  step run snapshot "03-kernel-replay" #["env", "leanchecker", "Axiward", "Gate"]
  unless (← bindings snapshot sourceNames) == sourcesBefore do
    throw <| IO.userError s!"Source snapshot changed while checking: {run}"
  unless (← bindings policyRoot policyNames) == rootBefore &&
      (← bindings toolchainDir toolNames) == toolsBefore &&
      (← sha256 (← IO.appPath)) == verifierBefore do
    throw <| IO.userError s!"Controller inputs changed while checking: {run}"
  let receipt : Receipt := {
    schema := 1, candidate := id, policy := rootBefore, tools := toolsBefore,
    verifier := verifierBefore, artifacts := ← bindings snapshot artifactNames }
  -- Only this controller creates an acceptance receipt; failed runs retain logs only.
  IO.FS.writeFile (run / "receipt.json") (toJson receipt).compress
  return runId

def verifyReceipt (id : String) : IO Unit := do
  requireId id
  let run := workRoot / "runs" / id
  let receipt : Receipt ← decode <| fromJson? (← decode <| Json.parse (← IO.FS.readFile (run / "receipt.json")))
  unless receipt.schema == 1 do throw <| IO.userError "Unsupported receipt schema"
  unless receipt.policy == (← bindings policyRoot policyNames) do
    throw <| IO.userError "Receipt belongs to a different policy version"
  unless receipt.tools == (← bindings toolchainDir toolNames) &&
      receipt.verifier == (← sha256 (← IO.appPath)) do
    throw <| IO.userError "Receipt belongs to a different verifier/tool version"
  unless receipt.artifacts == (← bindings (run / "snapshot") artifactNames) do
    throw <| IO.userError "Source or artifact no longer matches the accepted receipt"

def main (args : List String) : IO UInt32 := do
  try
    match args with
    | ["check", id] =>
      let runId ← checkCandidate id
      IO.println (Json.mkObj [("status", toJson "accepted"), ("run", toJson runId)]).compress
      return 0
    | ["verify", id] =>
      verifyReceipt id
      IO.println (Json.mkObj [("status", toJson "receipt-valid"), ("run", toJson id)]).compress
      return 0
    | _ =>
      throw <| IO.userError "Usage: axiward_l2 check CANDIDATE_ID | verify RUN_ID"
  catch error =>
    IO.println (Json.mkObj [("status", toJson "not-accepted"), ("reason", toJson error.toString)]).compress
    return 1
