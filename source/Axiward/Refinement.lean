import Axiward.Verifier
import Axiward.AcceptanceCheck

namespace Axiward.Refinement

open Lean System

inductive ChildPlan where
  | fresh (claims : List Nat)
  | reuse (node : Nat)

instance : ToJson ChildPlan where
  toJson
    | .fresh claims => toJson claims
    | .reuse node => Json.mkObj [("reuse", toJson node)]

instance : FromJson ChildPlan where
  fromJson? json := match json with
    | .arr _ => ChildPlan.fresh <$> fromJson? json
    | _ => do return .reuse (← fromJson? (← json.getObjVal? "reuse"))

structure ReuseSource where
  node : Nat
  receipt : String
  deriving ToJson, FromJson

structure Plan where
  children : List ChildPlan := []
  direct : Bool := false
  implementation : Option Nat := none
  result : Option ReuseSource := none
  deriving ToJson, FromJson

structure Result where
  verdict : RefinementVerdict
  evidence : String

def importCandidate (repo directory : FilePath) : IO Candidate := do
  let marker ← Git.hashText repo "{\"format\":\"axiward-refinement-v1\"}\n"
  let mut blobs : Array Git.Blob := #[⟨"submission.json", marker⟩]
  for name in #["plan.json", "Refinement.lean"] do
    if ← (directory / name).pathExists then
      blobs := blobs.push ⟨name, ← Git.hashFile repo (directory / name)⟩
  return ⟨← Git.tree repo none blobs⟩

def reuseResult (repo : FilePath) (scope : Scope) (proposal : Candidate)
    (source : ReuseSource) (state : State) : IO Result := do
  let publication := state.journal.entries.findSome? fun entry => do
    let result ← (admissions entry).find? (fun r => r.node == source.node && r.publication.receipt == source.receipt)
    return result.publication
  let reject (reason : String) : IO Result := do
    let log ← Git.hashText repo (Json.mkObj [("scope", toJson scope),
      ("proposal", toJson proposal), ("source", toJson source), ("reason", toJson reason)]).compress
    return ⟨.rejected reason, ← Git.tree repo none #[⟨"reuse.json", log⟩]⟩
  let some publication := publication | return ← reject "source was never admitted"
  unless sameGoal publication.scope scope do
    return ← reject "historical result has a different checked goal"
  let original ← Git.decode (Json.parse (← Git.readBlob repo publication.receipt))
  let oldScope : Scope ← Git.decode (fromJson? (← Git.decode (original.getObjVal? "scope")))
  let oldCandidate : Candidate ← Git.decode (fromJson? (← Git.decode (original.getObjVal? "candidate")))
  let oldProduct : String ← Git.decode (fromJson? (← Git.decode (original.getObjVal? "product")))
  unless oldScope == publication.scope && oldCandidate == publication.candidate && oldProduct == publication.product do
    return ← reject "historical receipt binding mismatch"
  let _ ← Git.checked repo #["cat-file", "-e", publication.product ++ "^{tree}"]
  let receipt ← Git.hashText repo (Json.mkObj [("kind", toJson "reuse"), ("scope", toJson scope),
    ("candidate", toJson publication.candidate), ("product", toJson publication.product),
    ("proposal", toJson proposal), ("source", toJson source),
    ("controller", toJson (← Verifier.digestFile repo (← IO.appPath)))]).compress
  let evidence ← Git.tree repo none #[⟨"receipt.json", receipt⟩]
  return ⟨.reused ⟨scope, proposal, source.node, publication, receipt⟩, evidence⟩

private def checkCore (repo : FilePath) (scope : Scope) (candidate : Candidate)
    (work : FilePath) (state : State) : IO Result := do
  let snapshot ← Sandbox.createSnapshot repo work
  Git.materialize repo candidate.tree snapshot
  let json ← Git.decode (Json.parse (← IO.FS.readFile (snapshot / "plan.json")))
  let plan : Plan ← Git.decode (fromJson? json)
  let parent ← Policy.readClaims repo scope.policy
  let controller ← Verifier.digestFile repo (← IO.appPath)
  let mut evidence : Array Git.Blob := #[]
  let retain (blobs : Array Git.Blob) (verdict : RefinementVerdict) : IO Result :=
    return ⟨verdict, ← Git.tree repo none blobs⟩
  let input ← Git.hashText repo (Json.mkObj [("scope", toJson scope),
    ("candidate", toJson candidate), ("plan", toJson plan), ("controller", toJson controller)]).compress
  evidence := evidence.push ⟨"input.json", input⟩
  if plan.implementation.isSome then
    return ← retain evidence (.rejected "shared source merging does not select a child implementation")
  if let some source := plan.result then
    unless plan.children.isEmpty && !plan.direct && plan.implementation.isNone do
      return ← retain evidence (.rejected "result reuse cannot also replace child routes")
    return ← reuseResult repo scope candidate source state
  if plan.direct then
    unless plan.children.isEmpty && plan.implementation.isNone do return ← retain evidence (.rejected "direct route has no children")
    let certificate ← Git.tree repo none evidence
    return ⟨.passed ⟨scope, candidate, [], certificate, none⟩, certificate⟩
  let mut childClaims : List (List Nat) := []
  for child in plan.children do
    match child with
    | .fresh claims => childClaims := childClaims ++ [claims]
    | .reuse node =>
      let some existing := state.nodes[node]? | return ← retain evidence (.rejected "unknown reused node")
      unless compatible existing.domain.scope scope do
        return ← retain evidence (.rejected "reused goal depends on changed requirements")
      childClaims := childClaims ++ [← Policy.readClaims repo existing.domain.scope.policy]
  unless !childClaims.isEmpty && childClaims.all (fun child =>
      !child.isEmpty && child.all parent.contains && child.eraseDups == child) do
    return ← retain evidence (.rejected "invalid child claim selection")
  let manifest ← Policy.readManifest repo scope.policy
  unless !manifest.files.any (fun path => ["Plan.lean", "Refinement.lean", "plan.json", "submission.json"].contains path) &&
      !manifest.specificationModules.any (["Plan", "Refinement"].contains) do
    return ← retain evidence (.rejected "specification uses a reserved refinement module or input path")
  let config ← Git.resolve repo s!"{scope.policy}:controller-toolchain.json"
  let toolJson ← Git.decode (Json.parse (← Git.readBlob repo config))
  let tools : Verifier.Toolchain ← Git.decode (fromJson? toolJson)
  unless (← Verifier.toolBindings repo tools.root) == tools.files do
    return ← retain evidence (.unknown "pinned verifier tools changed")
  Verifier.checkDependencies repo scope.policy tools.root
  Git.materialize repo scope.policy snapshot
  let planSource := String.join (manifest.specificationModules.toList.map (fun name => s!"import {name}\n")) ++
    "\nnamespace Plan\ndef Relation : Prop :=\n  " ++
    Policy.refinementTypeText manifest parent childClaims ++ "\nend Plan\n"
  let lake := "name = \"axiward-refinement\"\nversion = \"0.1.0\"\n" ++
    String.join ((manifest.specificationModules.toList ++ ["Plan", "Refinement"]).map
      (fun name => s!"[[lean_lib]]\nname = \"{name}\"\n"))
  for (name, text) in #[("Plan.lean", planSource), ("lakefile.toml", lake)] do
    IO.FS.writeFile (snapshot / name) text
    evidence := evidence.push ⟨name, ← Git.hashText repo text⟩
  let proofBefore ← Verifier.digestFile repo (snapshot / "Refinement.lean")
  evidence := evidence.push ⟨"Refinement.lean", ← Git.hashFile repo (snapshot / "Refinement.lean")⟩
  let arguments := #["--no-cache", "build", "Refinement"]
  let start ← IO.monoMsNow
  let result ← Sandbox.runVerifier repo snapshot tools.root arguments Verifier.buildEnvironment
  let record : Verifier.ToolResult := ⟨"01-build", arguments, result.exitCode.toNat,
    (← IO.monoMsNow) - start, result.stdout, result.stderr⟩
  let log := (toJson record).compress
  IO.FS.writeFile (work / "01-build.json") log
  evidence := evidence.push ⟨"01-build.json", ← Git.hashText repo log⟩
  if result.exitCode != 0 then return ← retain evidence (.rejected "refinement build did not pass")
  let mut proofObjects : Array Git.Blob := #[]
  for moduleName in #["Plan", "Refinement"] do
    for suffix in #[".olean", ".olean.private", ".olean.server"] do
      let path := s!".lake/build/lib/lean/{moduleName}{suffix}"
      let file := snapshot / path
      if ← file.pathExists then
        unless (← file.symlinkMetadata).type == .file && (← IO.FS.realPath file).normalize == file.normalize do
          throw (IO.userError "refinement proof object is redirected")
        proofObjects := proofObjects.push ⟨path, ← Git.hashFile repo file⟩
      else if suffix == ".olean" then
        return ← retain evidence (.rejected "refinement proof object is missing")
  let checked : Except String AcceptanceCheck.Result ← try
    pure (.ok (← AcceptanceCheck.checkRelation tools.root (snapshot / ".acceptance/lib")
      (snapshot / ".lake/build/lib/lean") manifest parent childClaims))
    catch error => pure (.error error.toString)
  let .ok checked := checked | do
    let reason := match checked with | .error message => message | .ok _ => "missing kernel result"
    let error ← Git.hashText repo (Json.mkObj [("error", toJson reason)]).compress
    return ← retain ((evidence ++ proofObjects).push ⟨"error.json", error⟩)
      (.rejected "refinement proof does not establish the frozen parent-child relation")
  let dependencies ← Verifier.recordDependencies repo tools.root checked.dependencies
  let checkedBlob ← Git.hashText repo (Json.mkObj [("parent", toJson parent),
    ("children", toJson childClaims), ("relation", toJson (Policy.refinementTypeText manifest parent childClaims)),
    ("modules", toJson checked.modules), ("declarations", toJson checked.declarations),
    ("dependencies", toJson dependencies)]).compress
  evidence := evidence.push ⟨"kernel-check.json", checkedBlob⟩
  unless (← Verifier.digestFile repo (snapshot / "Refinement.lean")) == proofBefore &&
      (← Verifier.toolBindings repo tools.root) == tools.files &&
      (← Verifier.digestFile repo (← IO.appPath)) == controller do
    return ← retain evidence (.unknown "refinement or tools changed during verification")
  Verifier.checkDependencies repo scope.policy tools.root checked.dependencies
  unless (← Verifier.recordDependencies repo tools.root checked.dependencies) == dependencies do
    return ← retain evidence (.unknown "loaded refinement dependencies changed during verification")
  for binding in evidence ++ proofObjects do
    if ["Plan.lean", "Refinement.lean", "lakefile.toml"].contains binding.path || binding.path.startsWith ".lake/" then
      unless (← Verifier.digestFile repo (snapshot / binding.path)) == binding.oid do
        return ← retain evidence (.rejected "refinement inputs or proof objects changed during checking")
  -- Compare the entire frozen package, including the specification objects.
  -- Only this relation's generated build file intentionally replaces an input.
  for entry in (← Git.checked repo #["ls-tree", "-r", "-z", scope.policy]).splitOn "\x00" do
    if entry.isEmpty then continue
    let [metadata, path] := entry.splitOn "\t" | throw (IO.userError "invalid frozen refinement input")
    let [_, "blob", oid] := metadata.splitOn " " | throw (IO.userError "invalid frozen refinement input")
    if path == "lakefile.toml" then continue
    unless (← Verifier.digestFile repo (snapshot / path)) == oid do
      return ← retain evidence (.rejected "frozen specification or acceptance input changed during checking")
  evidence := evidence ++ proofObjects
  let children : List ChildTarget ← plan.children.mapM fun child => match child with
    | .fresh claims => return .fresh (← Policy.restrictScope repo scope claims)
    | .reuse node => do
      let some existing := state.nodes[node]? | throw (IO.userError "missing reuse snapshot")
      pure (.reuse ⟨node, existing.domain.scope⟩)
  let receipt ← Git.hashText repo (Json.mkObj [("scope", toJson scope),
    ("candidate", toJson candidate), ("children", toJson children), ("tools", toJson tools),
    ("controller", toJson controller)]).compress
  evidence := evidence.push ⟨"receipt.json", receipt⟩
  let certificate ← Git.tree repo none evidence
  return ⟨.passed ⟨scope, candidate, children, certificate, plan.implementation⟩, certificate⟩

def check (repo : FilePath) (scope : Scope) (candidate : Candidate) (state : State) : IO Result := do
  let work ← Sandbox.scratch repo
  IO.FS.writeFile (work / "input.json") (Json.mkObj [
    ("scope", toJson scope), ("candidate", toJson candidate)]).compress
  try checkCore repo scope candidate work state
  catch error =>
    let errorBlob ← Git.hashText repo (Json.mkObj [("error", toJson error.toString)]).compress
    let mut logs : Array Git.Blob := #[⟨"error.json", errorBlob⟩]
    for name in #["input.json", "01-build.json"] do
      if ← (work / name).pathExists then logs := logs.push ⟨name, ← Git.hashFile repo (work / name)⟩
    return ⟨.unknown s!"refinement checker could not complete: {error}; see evidence", ← Git.tree repo none logs⟩

end Axiward.Refinement
