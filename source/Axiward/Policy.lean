import Axiward.Git

namespace Axiward.Policy

open Lean System

structure CandidateFile where
  source : String
  target : String
  deriving Inhabited, BEq, ToJson, FromJson

structure Claim where
  id : String
  proposition : String
  arguments : Array String
  proof : String
  deriving Inhabited, BEq, ToJson, FromJson

/-- The supported local Lean acceptance convention. Its readable specification,
    compiled propositions and version are all fixed by Scope.policy. -/
structure Manifest where
  schema : Nat
  name : String
  version : String
  specificationPath : String
  files : Array String
  specificationModules : Array String
  candidateFiles : Array CandidateFile
  buildTargets : Array String
  proofModules : Array String
  artifacts : Array String
  claims : Array Claim
  deriving ToJson, FromJson

def manifestPath : String := "acceptance.json"
def goalPath : String := "Goal.md"

def declarationName (text : String) : Bool :=
  !text.isEmpty && (text.splitOn ".").all fun part =>
    !part.isEmpty && part.toList.all (fun c => c.isAlphanum || c == '_' || c == '\'') &&
      !(part.toList.head!).isDigit

def candidatePathIgnored (path : String) : Bool :=
  (path.toLower.splitOn "/").any
    ([".git", ".axiward", ".view", ".checks", ".work", ".lake", ".codex", "__pycache__"].contains)

def candidatePathAllowed (manifest : Manifest) (path : String) : Bool :=
  manifest.candidateFiles.any (·.source == path)

private def unique (values : Array String) : Bool :=
  let normalized := values.toList.map String.toLower
  normalized.eraseDups == normalized

private def inputPath (path : String) : Bool :=
  Git.safePath path && !candidatePathIgnored path &&
    ![manifestPath.toLower, goalPath.toLower, "claims.json", "controller-toolchain.json",
      "dependencies.json", "submission.json", "agents.md", ".acceptance"].contains path.toLower &&
    !(path.toLower.startsWith ".acceptance/")

private def separatePaths (paths : Array String) : Bool :=
  paths.all fun path => paths.all fun other =>
    !(path.toLower.startsWith (other.toLower ++ "/"))

def validate (manifest : Manifest) : IO Unit := do
  unless manifest.schema == 1 && !manifest.name.trimAscii.toString.isEmpty &&
      !manifest.version.trimAscii.toString.isEmpty do
    throw (IO.userError "acceptance package requires schema 1, a name and an explicit version")
  unless !manifest.claims.isEmpty && !manifest.specificationModules.isEmpty &&
      !manifest.proofModules.isEmpty && !manifest.candidateFiles.isEmpty &&
      !manifest.buildTargets.isEmpty && !manifest.artifacts.isEmpty do
    throw (IO.userError "acceptance package is missing claims, sources, modules, build targets or artifacts")
  unless manifest.files.all inputPath && unique manifest.files &&
      manifest.files.contains manifest.specificationPath &&
      manifest.files.contains "lakefile.toml" && manifest.files.contains "lean-toolchain" do
    throw (IO.userError "acceptance files must include the specification and the fixed local Lean build configuration")
  unless manifest.candidateFiles.all (fun file => inputPath file.source && inputPath file.target) &&
      unique (manifest.candidateFiles.map (·.source)) && unique (manifest.candidateFiles.map (·.target)) &&
      (manifest.candidateFiles.map (·.target)).all (fun path =>
        !manifest.files.any (fun fixed => fixed.toLower == path.toLower)) &&
      separatePaths (manifest.files ++ manifest.candidateFiles.map (·.target)) &&
      separatePaths (manifest.candidateFiles.map (·.source)) do
    throw (IO.userError "candidate source mappings overlap fixed inputs or one another")
  unless (manifest.specificationModules ++ manifest.proofModules).all declarationName &&
      unique (manifest.specificationModules ++ manifest.proofModules) &&
      manifest.buildTargets.all (fun target => !target.isEmpty &&
        !(target.startsWith "-") && target.toList.all (fun c => c.isAlphanum || "_./:+-".contains c)) do
    throw (IO.userError "invalid Lean modules or build targets")
  unless manifest.artifacts.all (fun path => Git.safePath path &&
      path.startsWith ".lake/build/") && unique manifest.artifacts do
    throw (IO.userError "artifacts must be explicit files under .lake/build")
  unless unique (manifest.claims.map (·.id)) && manifest.claims.all (fun claim =>
      !claim.id.trimAscii.toString.isEmpty && declarationName claim.proposition &&
      declarationName claim.proof && claim.arguments.all declarationName) do
    throw (IO.userError "acceptance claims require distinct IDs and actual Lean declaration names")
  let arguments := manifest.claims[0]!.arguments
  unless manifest.claims.all (·.arguments == arguments) do
    throw (IO.userError "supported claims must share the same ordered candidate subject arguments")

def validateRoot (directory : FilePath) : IO Manifest := do
  let manifest : Manifest ← Git.decode (fromJson? (← Git.decode (Json.parse
    (← IO.FS.readFile (directory / manifestPath)))))
  validate manifest
  let root ← IO.FS.realPath directory
  for path in manifest.files do
    let file := root / path
    unless (← file.symlinkMetadata).type == .file &&
        (← IO.FS.realPath file).normalize == file.normalize do
      throw (IO.userError s!"acceptance input must be an ordinary non-redirected file: {path}")
  return manifest

private def decodeManifest (text : String) : IO Manifest := do
  let json ← Git.decode (Json.parse text)
  let manifest : Manifest ← Git.decode (fromJson? json)
  validate manifest
  return manifest

def readManifest (repo : FilePath) (policy : String) : IO Manifest := do
  let texts ← Git.readBlobs repo #[s!"{policy}:{manifestPath}"]
  decodeManifest texts[0]!

def readClaims (repo : FilePath) (policy : String) : IO (List Nat) := do
  let texts ← Git.readBlobs repo #[s!"{policy}:claims.json"]
  Git.decode (fromJson? (← Git.decode (Json.parse texts[0]!)))

def validateClaims (manifest : Manifest) (claims : List Nat) : IO Unit := do
  unless !claims.isEmpty && claims.all (· < manifest.claims.size) && claims.eraseDups == claims do
    throw (IO.userError "invalid acceptance claim selection")

def goalText (manifest : Manifest) (claims : List Nat) : String :=
  s!"# {manifest.name}\n\nConfirmed acceptance version: {manifest.version}.\n\n" ++
  s!"Read {manifest.specificationPath} and the fixed acceptance.json. The selected actual Lean obligations are:\n\n" ++
  String.join (claims.map fun index =>
    let claim := manifest.claims[index]!
    s!"- {claim.id}: `{claim.proposition} {String.intercalate " " claim.arguments.toList}`; proof `{claim.proof}`.\n") ++
  "\nOnly the pinned package is authoritative for this work item. Editing a draft does not change it. Compilation and build outputs alone are not proofs of these obligations. The manifest declares which source subjects, proofs and artifacts this acceptance covers.\n"

def refinementTypeText (manifest : Manifest) (parent : List Nat) (children : List (List Nat)) : String :=
  let args := (List.range manifest.claims[0]!.arguments.size).map (fun i => s!"subject{i}")
  let conjunction (indices : List Nat) := indices.foldr (fun i rest =>
    s!"({manifest.claims[i]!.proposition} {String.intercalate " " args}) ∧ ({rest})") "True"
  (if args.isEmpty then "" else s!"∀ {String.intercalate " " args}, ") ++
    String.join (children.map (fun claims => s!"({conjunction claims}) → ")) ++ conjunction parent

private def scopeBindings (repo : FilePath) (policy : String) (manifest : Manifest)
    (claims : List Nat) : IO (String × List Requirement) := do
  let paths := #[manifestPath, "controller-toolchain.json", "dependencies.json"] ++ manifest.files
  let inputs ← Git.resolveMany repo ((paths.push ".acceptance").map (fun path => s!"{policy}:{path}"))
  let some (_, specification) := (paths.zip inputs).find? (fun (path, _) => path == manifest.specificationPath)
    | throw (IO.userError "registered specification is missing from the acceptance inputs")
  let contract ← Git.hashText repo (toJson inputs).compress
  let refs ← claims.mapM fun index => do
    let claim := manifest.claims[index]!
    let version ← Git.hashText repo (Json.mkObj [("contract", toJson contract),
      ("version", toJson manifest.version), ("claim", toJson claim)]).compress
    return (⟨s!"{manifest.name}/{claim.id}", version⟩ : Requirement)
  return (specification, ⟨"acceptance/contract", contract⟩ :: refs)

def selectClaims (repo : FilePath) (base : String) (claims : List Nat) : IO Scope := do
  let manifest ← readManifest repo base
  validateClaims manifest claims
  let policy ← Git.tree repo (some base) #[
    ⟨"claims.json", ← Git.hashText repo (toJson claims).compress⟩,
    ⟨goalPath, ← Git.hashText repo (goalText manifest claims)⟩]
  let (specification, requirements) ← scopeBindings repo policy manifest claims
  return ⟨0, specification, policy, requirements⟩

/-- Recompute the registered binding directly from its immutable tree. Checking
    a scope does not need to construct another copy of its selected goal. -/
def validateScope (repo : FilePath) (scope : Scope) : IO (Manifest × List Nat) := do
  let texts ← Git.readBlobs repo #[s!"{scope.policy}:{manifestPath}", s!"{scope.policy}:claims.json"]
  let manifest ← decodeManifest texts[0]!
  let claims : List Nat ← Git.decode (fromJson? (← Git.decode (Json.parse texts[1]!)))
  validateClaims manifest claims
  let (specification, requirements) ← scopeBindings repo scope.policy manifest claims
  unless scope.specification == specification && scope.requirements == requirements do
    throw (IO.userError "scope does not bind the registered specification version and obligations")
  return (manifest, claims)

def restrictScope (repo : FilePath) (base : Scope) (claims : List Nat) : IO Scope := do
  let selected ← selectClaims repo base.policy claims
  unless selected.requirements.all (fun requirement => base.requirements.contains requirement) do
    throw (IO.userError "claim is outside the registered acceptance scope")
  return { selected with specification := base.specification }

end Axiward.Policy
