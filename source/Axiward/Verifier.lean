import Axiward.AcceptanceCheck
import Axiward.Sandbox

namespace Axiward.Verifier

open Lean System

structure FileBinding where
  path : String
  oid : String
  deriving BEq, ToJson, FromJson

structure Toolchain where
  root : String
  files : Array FileBinding
  deriving ToJson, FromJson

structure ToolResult where
  name : String
  arguments : Array String
  exitCode : Nat
  elapsedMs : Nat
  stdout : String
  stderr : String
  deriving ToJson

structure Receipt where
  schema : Nat := 2
  scope : Scope
  candidate : Candidate
  product : String
  tools : Array FileBinding
  dependencies : Array FileBinding
  controller : String
  deriving ToJson

structure Result where
  verdict : Verdict
  evidence : String

def buildEnvironment : Array (String × Option String) :=
  #["LEAN_PATH", "LEAN_SRC_PATH", "LEAN_SYSROOT", "LEAN", "LEAN_GITHASH",
    "LEAN_CC", "LEAN_AR", "LAKE", "LAKE_HOME", "LAKE_CONFIG", "LAKE_OVERRIDE_LEAN",
    "ELAN_TOOLCHAIN"].map (fun key => (key, none))

def digestFile (repo file : FilePath) : IO String :=
  Git.checked repo #["hash-object", "--no-filters", "--", file.toString]

private def fileIds (repo : FilePath) (files : Array FilePath) (store : Bool := false) : IO (Array String) := do
  if files.isEmpty then return #[]
  let args := #["hash-object", "--no-filters", "--stdin-paths"] ++ (if store then #["-w"] else #[])
  let input := String.intercalate "\n" (files.toList.map fun p => p.toString.replace "\\" "/") ++ "\n"
  let ids := (← Git.checked repo args (some input)).splitOn "\n" |>.toArray
  unless ids.size == files.size && ids.all Git.objectId do
    throw (IO.userError "Git returned an incomplete file digest response")
  return ids

def recordDependencies (repo root : FilePath) (paths : Array String) : IO (Array FileBinding) := do
  let ids ← fileIds repo (paths.map (fun (path : String) => root / path))
  return (paths.zip ids).map fun (path, oid) => ⟨path, oid⟩

private partial def headerPaths (root : FilePath) (prefixPath : String) : IO (Array String) := do
  let mut result := #[]
  for entry in ← (root / prefixPath).readDir do
    let path := prefixPath ++ "/" ++ entry.fileName
    let metadata ← entry.path.symlinkMetadata
    match metadata.type with
    | .dir => result := result ++ (← headerPaths root path)
    | .file => result := result.push path
    | _ => throw (IO.userError "toolchain headers must be ordinary files")
  return result

/-- Pin executables and the native Lean runtime/build libraries, as well as the
    actual standard-library proof imports recorded separately with each policy. -/
def toolBindings (repo root : FilePath) : IO (Array FileBinding) := do
  let mut paths := #["bin/lean.exe", "bin/lake.exe", "bin/clang.exe", "bin/ld.lld.exe", "bin/llvm-ar.exe"]
  for entry in ← (root / "bin").readDir do
    if entry.fileName.endsWith ".dll" then paths := paths.push ("bin/" ++ entry.fileName)
  for entry in ← (root / "lib/lean").readDir do
    if entry.fileName.endsWith ".a" || entry.fileName.endsWith ".lib" then
      paths := paths.push ("lib/lean/" ++ entry.fileName)
  paths := paths ++ (← headerPaths root "include/lean")
  recordDependencies repo root (paths.qsort (· < ·))

def verifiedDependencies (repo : FilePath) (policy : String) (toolRoot : FilePath)
    (observed : Array String := #[]) : IO (Array FileBinding) := do
  let texts ← Git.readBlobs repo #[s!"{policy}:dependencies.json"]
  let expected : Array FileBinding ← Git.decode (fromJson? (← Git.decode (Json.parse texts[0]!)))
  unless observed.all (fun path => expected.any (·.path == path)) do
    throw (IO.userError "candidate imports a standard-library proof dependency outside the registered package")
  let paths := if observed.isEmpty then expected.map (·.path) else observed
  let actual ← recordDependencies repo toolRoot paths
  unless actual.all expected.contains do
    throw (IO.userError "pinned specification proof dependencies changed")
  return actual

def checkDependencies (repo : FilePath) (policy : String) (toolRoot : FilePath)
    (observed : Array String := #[]) : IO Unit := do
  let _ ← verifiedDependencies repo policy toolRoot observed

private def listFiles (repo : FilePath) (tree : String) : IO (Array String) := do
  return ((← Git.checked repo #["ls-tree", "-r", "-z", "--name-only", tree]).splitOn "\x00"
    |>.filter (!·.isEmpty)).toArray

private def unchanged (repo : FilePath) (tree : String) (directory : FilePath) : IO Bool := do
  let paths ← listFiles repo tree
  let actual ← fileIds repo (paths.map (fun (path : String) => directory / path))
  let requested := String.intercalate "\n" (paths.toList.map (fun path => s!"{tree}:{path}")) ++ "\n"
  let expected := (← Git.checked repo #["cat-file", "--batch-check=%(objectname)"] (some requested)).splitOn "\n" |>.toArray
  return expected.size == actual.size && expected.all Git.objectId && expected == actual

private def objectPaths (directory : FilePath) (modules : Array String) : IO (Array String) := do
  let mut paths := #[]
  for moduleName in modules do
    let stem := moduleName.replace "." "/"
    for suffix in #[".olean", ".olean.server", ".olean.private"] do
      let path := stem ++ suffix
      if ← (directory / path).pathExists then
        let file := directory / path
        unless (← file.symlinkMetadata).type == .file && (← IO.FS.realPath file).normalize == file.normalize do
          throw (IO.userError "proof object redirects outside its frozen build data")
        paths := paths.push path
      else if suffix == ".olean" then throw (IO.userError s!"required proof object is missing: {path}")
  return paths

private partial def proofFiles (root : FilePath) (relative : String := "") : IO (Array String) := do
  let mut result := #[]
  let directory := if relative.isEmpty then root else root / relative
  for entry in ← directory.readDir do
    let path := if relative.isEmpty then entry.fileName else relative ++ "/" ++ entry.fileName
    unless (← IO.FS.realPath entry.path).normalize == entry.path.normalize do
      throw (IO.userError "proof data redirects outside the build directory")
    match (← entry.path.symlinkMetadata).type with
    | .dir => result := result ++ (← proofFiles root path)
    | .file =>
      if [".olean", ".olean.private", ".olean.server"].any (fun suffix => path.endsWith suffix) then
        result := result.push path
    | _ => throw (IO.userError "proof data must be ordinary files")
  return result.qsort (· < ·)

private def importPolicyChecked (repo directory : FilePath) (config : String)
    (manifest : Policy.Manifest) (tools : Toolchain) : IO Scope := do
  let mut blobs : Array Git.Blob := #[
    ⟨Policy.manifestPath, ← Git.hashText repo (toJson manifest).compress⟩,
    ⟨"controller-toolchain.json", config⟩]
  let sourceIds ← fileIds repo (manifest.files.map (fun (path : String) => directory / path)) true
  blobs := blobs ++ (manifest.files.zip sourceIds).map (fun (path, oid) => ⟨path, oid⟩)
  let inputs ← Git.tree repo none blobs
  let work ← Sandbox.scratch repo
  let snapshot ← Sandbox.createSnapshot repo work
  Git.materialize repo inputs snapshot
  let output ← Sandbox.runVerifier repo snapshot tools.root
    (#["--no-cache", "build"] ++ manifest.specificationModules) buildEnvironment
  unless output.exitCode == 0 do
    throw (IO.userError s!"standalone acceptance specification did not compile: {output.stdout}{output.stderr}")
  let objects := snapshot / ".lake/build/lib/lean"
  let checked ← AcceptanceCheck.validateSpecification tools.root objects manifest
  let dependencies ← recordDependencies repo tools.root checked.dependencies
  unless (← unchanged repo inputs snapshot) && (← toolBindings repo tools.root) == tools.files do
    throw (IO.userError "acceptance inputs or compiler tools changed during registration")
  let paths ← objectPaths objects checked.modules
  let ids ← fileIds repo (paths.map (fun (path : String) => objects / path)) true
  blobs := blobs ++ (paths.zip ids).map (fun (path, oid) => ⟨".acceptance/lib/" ++ path, oid⟩)
  blobs := blobs.push ⟨"dependencies.json", ← Git.hashText repo (toJson dependencies).compress⟩
  let policy ← Git.tree repo none blobs
  Policy.selectClaims repo policy (List.range manifest.claims.size)

/-- Import is a controller entry for an explicitly selected acceptance package.
    The package is compiled independently before any candidate can be imported. -/
def importPolicyWithConfig (repo directory : FilePath) (config : String) : IO Scope := do
  let manifest ← Policy.validateRoot directory
  let tools : Toolchain ← Git.decode (fromJson? (← Git.decode (Json.parse (← Git.readBlob repo config))))
  unless (← toolBindings repo tools.root) == tools.files do
    throw (IO.userError "pinned acceptance compiler tools changed")
  importPolicyChecked repo directory config manifest tools

def importPolicy (repo directory toolchain : FilePath) : IO Scope := do
  let manifest ← Policy.validateRoot directory
  let tools : Toolchain := ⟨toolchain.toString, ← toolBindings repo toolchain⟩
  let config ← Git.hashText repo (toJson tools).compress
  importPolicyChecked repo directory config manifest tools

/-- Candidate source is admitted only through the fixed source-to-build mapping.
    Other workspace files, including edited specification drafts, are not inputs. -/
def candidatePaths (manifest : Policy.Manifest) (directory : FilePath) : IO (Array String) := do
  let root ← IO.FS.realPath directory
  let mut paths := #[]
  for item in manifest.candidateFiles do
    let file := root / item.source
    if ← file.pathExists then
      unless (← file.symlinkMetadata).type == .file && (← IO.FS.realPath file).normalize == file.normalize do
        throw (IO.userError s!"candidate input must be an ordinary non-redirected file: {item.source}")
      paths := paths.push item.source
  return paths

def importCandidateForPolicy (repo : FilePath) (policy : String) (directory : FilePath) : IO Candidate := do
  let manifest ← Policy.readManifest repo policy
  let paths ← candidatePaths manifest directory
  let ids ← fileIds repo (paths.map (fun (path : String) => directory / path)) true
  let marker ← Git.hashText repo "{\"format\":\"axiward-candidate-v1\"}\n"
  let mut blobs : Array Git.Blob := #[⟨"submission.json", marker⟩]
  for (path, oid) in paths.zip ids do
    let some mapping := manifest.candidateFiles.find? (·.source == path)
      | throw (IO.userError "unregistered candidate source")
    blobs := blobs.push ⟨mapping.target, oid⟩
  return ⟨← Git.tree repo none blobs⟩

private def sourceBlobs (repo : FilePath) (manifest : Policy.Manifest) (tree : String) : IO (Array Git.Blob) := do
  let mut blobs : Array Git.Blob := #[]
  for entry in (← Git.checked repo #["ls-tree", "-r", "-z", tree]).splitOn "\x00" do
    if entry.isEmpty then continue
    let [metadata, path] := entry.splitOn "\t" | throw (IO.userError "invalid source tree entry")
    let [mode, "blob", oid] := metadata.splitOn " " | throw (IO.userError "source tree must contain files only")
    unless Git.objectId oid && ["100644", "100755"].contains mode &&
        (path == "submission.json" || manifest.candidateFiles.any (·.target == path)) do
      throw (IO.userError s!"source tree contains an unmapped path: {path}")
    blobs := blobs.push ⟨path, oid⟩
  for file in manifest.candidateFiles do
    unless blobs.any (·.path == file.target) do throw (IO.userError s!"candidate is missing {file.target}")
  return blobs

/-- Adoption seals the mapped committed source. It does not verify or publish it. -/
def validateSourceTree (repo : FilePath) (policy tree : String) : IO Unit := do
  let manifest ← Policy.readManifest repo policy
  let _ ← sourceBlobs repo manifest tree

private def checkCore (repo : FilePath) (scope : Scope) (candidate : Candidate) (work : FilePath) : IO Result := do
  let (manifest, claims) ← Policy.validateScope repo scope
  let candidateBlobs ← sourceBlobs repo manifest candidate.tree
  let snapshot ← Sandbox.createSnapshot repo work
  Git.materialize repo scope.policy snapshot
  Git.materialize repo candidate.tree snapshot
  let toolText ← IO.FS.readFile (snapshot / "controller-toolchain.json")
  let tools : Toolchain ← Git.decode (fromJson? (← Git.decode (Json.parse toolText)))
  let controller ← digestFile repo (← IO.appPath)
  let binding := Json.mkObj [("scope", toJson scope), ("candidate", toJson candidate),
    ("controller", toJson controller), ("version", toJson manifest.version),
    ("artifactBinding", toJson "pinned acceptance build and declared outputs; kernel proof is of the named source subjects")]
  IO.FS.writeFile (work / "input.json") binding.compress
  let mut evidence : Array Git.Blob := #[⟨"input.json", ← Git.hashText repo binding.compress⟩]
  unless (← toolBindings repo tools.root) == tools.files do
    return ⟨.unknown "pinned verifier tools changed", ← Git.tree repo none evidence⟩
  checkDependencies repo scope.policy tools.root
  let arguments := #["--no-cache", "build"] ++ manifest.buildTargets
  let started ← IO.monoMsNow
  let output ← Sandbox.runVerifier repo snapshot tools.root arguments buildEnvironment
  let record : ToolResult := ⟨"01-build", arguments, output.exitCode.toNat,
    (← IO.monoMsNow) - started, output.stdout, output.stderr⟩
  IO.FS.writeFile (work / "01-build.json") (toJson record).compress
  evidence := evidence.push ⟨"01-build.json", ← Git.hashText repo (toJson record).compress⟩
  if output.exitCode != 0 then
    return ⟨.rejected "candidate build did not pass", ← Git.tree repo none evidence⟩
  let proofRoot := snapshot / ".lake/build/lib/lean"
  let proofInputs ← proofFiles proofRoot
  let proofBefore ← recordDependencies repo proofRoot proofInputs
  let checked ← try
      AcceptanceCheck.check tools.root (snapshot / ".acceptance/lib")
        (snapshot / ".lake/build/lib/lean") manifest claims
    catch error =>
      let diagnostic ← Git.hashText repo (Json.mkObj [("error", toJson error.toString)]).compress
      return ⟨.rejected s!"kernel acceptance failed: {error}",
        ← Git.tree repo none (evidence.push ⟨"error.json", diagnostic⟩)⟩
  unless (← proofFiles proofRoot) == proofInputs &&
      (← recordDependencies repo proofRoot proofInputs) == proofBefore do
    return ⟨.rejected "proof objects changed during kernel checking", ← Git.tree repo none evidence⟩
  evidence := evidence.push ⟨"kernel.json", ← Git.hashText repo (toJson checked).compress⟩
  unless (← unchanged repo scope.policy snapshot) && (← unchanged repo candidate.tree snapshot) do
    return ⟨.rejected "sealed specification or candidate inputs changed", ← Git.tree repo none evidence⟩
  unless (← toolBindings repo tools.root) == tools.files && (← digestFile repo (← IO.appPath)) == controller do
    return ⟨.unknown "controller or verifier tools changed", ← Git.tree repo none evidence⟩
  let proofPaths ← objectPaths (snapshot / ".lake/build/lib/lean") checked.modules
  let productPaths := (manifest.artifacts ++ proofPaths.map (".lake/build/lib/lean/" ++ ·)).toList.eraseDups.toArray
  for path in productPaths do
    let file := snapshot / path
    unless (← file.symlinkMetadata).type == .file && (← IO.FS.realPath file).normalize == file.normalize do
      throw (IO.userError s!"declared artifact is missing or redirected: {path}")
  let productIds ← fileIds repo (productPaths.map (fun (path : String) => snapshot / path)) true
  for (path, oid) in productPaths.zip productIds do
    if path.startsWith ".lake/build/lib/lean/" then
      let relative := (path.drop ".lake/build/lib/lean/".length).toString
      if let some checkedFile := proofBefore.find? (·.path == relative) then
        unless checkedFile.oid == oid do
          return ⟨.rejected "retained proof object differs from the checked bytes", ← Git.tree repo none evidence⟩
  let product ← Git.tree repo (some scope.policy) (candidateBlobs ++
    (productPaths.zip productIds).map (fun (path, oid) => ⟨path, oid⟩))
  let dependencies ← verifiedDependencies repo scope.policy tools.root checked.dependencies
  let receipt : Receipt := ⟨2, scope, candidate, product, tools.files, dependencies, controller⟩
  let receiptBlob ← Git.hashText repo (toJson receipt).compress
  evidence := evidence.push ⟨"receipt.json", receiptBlob⟩
  return ⟨.passed ⟨scope, candidate, product, receiptBlob⟩, ← Git.tree repo none evidence⟩

def check (repo : FilePath) (scope : Scope) (candidate : Candidate) : IO Result := do
  let work ← Sandbox.scratch repo
  IO.FS.writeFile (work / "input.json") (Json.mkObj [("scope", toJson scope), ("candidate", toJson candidate)]).compress
  try checkCore repo scope candidate work
  catch error =>
    let errorBlob ← Git.hashText repo (Json.mkObj [("error", toJson error.toString)]).compress
    let mut logs : Array Git.Blob := #[⟨"error.json", errorBlob⟩]
    for name in #["input.json", "01-build.json"] do
      if ← (work / name).pathExists then logs := logs.push ⟨name, ← Git.hashFile repo (work / name)⟩
    return ⟨.unknown s!"verifier could not complete: {error}; see retained evidence", ← Git.tree repo none logs⟩

end Axiward.Verifier
