import Axiward.FifoPolicy
import Axiward.Sandbox

namespace Axiward.Verifier

open Lean System

/-- This first adapter is the fixed FIFO policy established in M0, not a generic
    worker-programmable build runner. The initializer is a controller-only entry. -/
def policyFiles : Array String := #[
  "Axiward/Spec.lean", "Gate.lean", "Audit.lean", "Main.lean", "lakefile.toml", "lean-toolchain"]

def candidateFiles : Array String := #["Queue.lean", "Proofs.lean"]

def toolFiles : Array String := #[
  "bin/lean.exe", "bin/lake.exe", "bin/leanchecker.exe", "bin/clang.exe", "bin/ld.lld.exe"]

def buildEnvironment : Array (String × Option String) :=
  #["LEAN_PATH", "LEAN_SRC_PATH", "LEAN_SYSROOT", "LEAN", "LEAN_GITHASH",
    "LEAN_CC", "LEAN_AR", "LAKE", "LAKE_HOME", "LAKE_CONFIG", "LAKE_OVERRIDE_LEAN",
    "ELAN_TOOLCHAIN"].map (fun key => (key, none))

structure FileBinding where
  path : String
  oid : String
  deriving BEq, ToJson, FromJson

structure Toolchain where
  root : String
  files : Array FileBinding
  deriving ToJson, FromJson

def digestFile (repo file : FilePath) : IO String :=
  Git.checked repo #["hash-object", "--no-filters", "--", file.toString]

def toolBindings (repo root : FilePath) : IO (Array FileBinding) :=
  toolFiles.mapM fun (path : String) => return ⟨path, ← digestFile repo (root / path)⟩

def importPolicyWithConfig (repo directory : FilePath) (config : String) : IO Scope := do
  let overflow ← FifoPolicy.validateRoot directory
  let mut blobs := #[]
  for path in policyFiles do
    let oid ← Git.hashFile repo (directory / path)
    FifoPolicy.validateRootText overflow path (← Git.readBlob repo oid)
    blobs := blobs.push (⟨path, oid⟩ : Git.Blob)
  blobs := blobs.push ⟨"controller-toolchain.json", config⟩
  blobs := blobs.push ⟨"overflow.json", ← Git.hashText repo (toJson overflow).compress⟩
  let policy ← Git.tree repo none blobs
  FifoPolicy.selectClaims repo policy FifoPolicy.allClaims

def importPolicy (repo directory toolchain : FilePath) : IO Scope := do
  let tools : Toolchain := ⟨toolchain.toString, ← toolBindings repo toolchain⟩
  let config ← Git.hashText repo (toJson tools).compress
  importPolicyWithConfig repo directory config

def importCandidate (repo directory : FilePath) : IO Candidate := do
  -- The marker keeps even an incomplete submission representable as a Git tree.
  let marker ← Git.hashText repo "{\"format\":\"axiward-fifo-candidate-v1\"}\n"
  let mut blobs : Array Git.Blob := #[⟨"submission.json", marker⟩]
  for name in candidateFiles do
    let file := directory / name
    if ← file.pathExists then
      blobs := blobs.push ⟨s!"Axiward/{name}", ← Git.hashFile repo file⟩
  return ⟨← Git.tree repo none blobs⟩

structure ToolResult where
  name : String
  arguments : Array String
  exitCode : Nat
  elapsedMs : Nat
  stdout : String
  stderr : String
  deriving ToJson

structure Receipt where
  schema : Nat := 1
  scope : Scope
  candidate : Candidate
  product : String
  tools : Array FileBinding
  controller : String
  deriving ToJson

structure Result where
  verdict : Verdict
  evidence : String

private def checkCore (repo : FilePath) (scope : Scope) (candidate : Candidate)
    (work : FilePath) : IO Result := do
  let snapshot := work / "snapshot"
  Git.materialize repo scope.policy snapshot
  Git.materialize repo candidate.tree snapshot
  let toolJson ← Git.decode (Json.parse (← IO.FS.readFile (snapshot / "controller-toolchain.json")))
  let toolchain : Toolchain ← Git.decode (fromJson? toolJson)
  let toolRoot : FilePath := toolchain.root
  let controller ← digestFile repo (← IO.appPath)
  let mut evidence : Array Git.Blob := #[]
  let retain (blobs : Array Git.Blob) (verdict : Verdict) : IO Result := do
    return ⟨verdict, ← Git.tree repo none blobs⟩
  let binding ← Git.hashText repo (Json.mkObj [
    ("scope", toJson scope), ("candidate", toJson candidate), ("controller", toJson controller)]).compress
  evidence := evidence.push ⟨"input.json", binding⟩
  unless (← toolBindings repo toolRoot) == toolchain.files do
    return ← retain evidence (.unknown "pinned verifier tools changed")
  let steps := #[
    ("01-build", #["--no-cache", "build", "Gate", "fifo_demo"]),
    ("02-audit", #["env", "lean", "Audit.lean"]),
    ("03-replay", #["env", "leanchecker", "Axiward", "Gate"])]
  for (name, arguments) in steps do
    let start ← IO.monoMsNow
    let output ← Sandbox.runVerifier repo snapshot toolRoot arguments buildEnvironment
    let result : ToolResult := ⟨name, arguments, output.exitCode.toNat,
      (← IO.monoMsNow) - start, output.stdout, output.stderr⟩
    IO.FS.writeFile (work / s!"{name}.json") (toJson result).compress
    let log ← Git.hashText repo (toJson result).compress
    evidence := evidence.push ⟨s!"{name}.json", log⟩
    if output.exitCode != 0 then
      return ← retain evidence (.rejected s!"{name} did not pass")
  for name in policyFiles ++ #["claims.json", "controller-toolchain.json", "overflow.json"] do
    unless (← digestFile repo (snapshot / name)) ==
        (← Git.resolve repo s!"{scope.policy}:{name}") do
      return ← retain evidence (.rejected "policy changed during verification")
  let candidatePaths := (← Git.checked repo #["ls-tree", "-r", "--name-only", candidate.tree]).splitOn "\n"
  for path in candidatePaths do
    unless (← digestFile repo (snapshot / path)) ==
        (← Git.resolve repo s!"{candidate.tree}:{path}") do
      return ← retain evidence (.rejected "candidate changed during verification")
  unless (← toolBindings repo toolRoot) == toolchain.files &&
      (← digestFile repo (← IO.appPath)) == controller do
    return ← retain evidence (.unknown "controller or verifier tools changed")
  let partSources := candidatePaths.filter (fun path => path.startsWith "Axiward/Parts/" && path.endsWith ".lean")
  let partObjects := partSources.map (fun path => ".lake/build/lib/lean/" ++ (path.dropEnd 5).toString ++ ".olean")
  let productFiles := policyFiles ++ #["claims.json", "overflow.json"] ++ #[
    "Axiward/Queue.lean", "Axiward/Proofs.lean", "audit.json",
    ".lake/build/lib/lean/Axiward/Queue.olean",
    ".lake/build/lib/lean/Axiward/Proofs.olean", ".lake/build/lib/lean/Gate.olean",
    ".lake/build/ir/Axiward/Queue.c", ".lake/build/ir/Main.c",
    ".lake/build/bin/fifo_demo.exe"] ++ partSources.toArray ++ partObjects.toArray
  let productBlobs ← productFiles.mapM fun (path : String) =>
    return (⟨path, ← Git.hashFile repo (snapshot / path)⟩ : Git.Blob)
  let product ← Git.tree repo none productBlobs
  let receipt : Receipt := ⟨1, scope, candidate, product, toolchain.files, controller⟩
  let receiptBlob ← Git.hashText repo (toJson receipt).compress
  evidence := evidence.push ⟨"receipt.json", receiptBlob⟩
  return ← retain evidence (.passed ⟨scope, candidate, product, receiptBlob⟩)

def check (repo : FilePath) (scope : Scope) (candidate : Candidate) : IO Result := do
  let work ← Sandbox.scratch repo
  IO.FS.writeFile (work / "input.json") (Json.mkObj [
    ("scope", toJson scope), ("candidate", toJson candidate)]).compress
  try
    checkCore repo scope candidate work
  catch error =>
    let errorBlob ← Git.hashText repo (Json.mkObj [("error", toJson error.toString)]).compress
    let mut logs : Array Git.Blob := #[⟨"error.json", errorBlob⟩]
    for name in #["input.json", "01-build.json", "02-audit.json", "03-replay.json"] do
      if ← (work / name).pathExists then
        logs := logs.push ⟨name, ← Git.hashFile repo (work / name)⟩
    return ⟨.unknown "verifier could not complete; see retained evidence",
      ← Git.tree repo none logs⟩

end Axiward.Verifier
