import Axiward.Verifier

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

def leanList (xs : List Nat) : String := "[" ++ String.intercalate ", " (xs.map toString) ++ "]"

def logic : String := "def Holds (claims : List Nat) (facts : Nat → Prop) : Prop :=\n  ∀ c ∈ claims, facts c\n"

def audit : String :=
  "import Gate\nimport Lean\nopen Lean Elab Command\nrun_cmd do\n" ++
  "  let env ← getEnv\n  let allowed := #[`propext, `Quot.sound, `Classical.choice]\n" ++
  "  for axiomName in (← collectAxioms `Gate.accepted) do\n" ++
  "    unless allowed.contains axiomName do throwError \"UNAPPROVED_AXIOM: {axiomName}\"\n" ++
  "  for (name, info) in env.constants do\n" ++
  "    let some index := env.getModuleIdxFor? name | continue\n" ++
  "    unless env.header.moduleNames[index.toNat]! == `Refinement do continue\n" ++
  "    if info.isUnsafe || (Compiler.getImplementedBy? env name).isSome || (getExternAttrData? env name).isSome then\n" ++
  "      throwError \"UNCHECKED_RUNTIME_REPLACEMENT: {name}\"\n" ++
  "    for axiomName in (← collectAxioms name) do\n" ++
  "      unless allowed.contains axiomName do throwError \"UNAPPROVED_AXIOM: {name}: {axiomName}\"\n"

def reuseResult (repo : FilePath) (scope : Scope) (proposal : Candidate)
    (source : ReuseSource) (state : State) : IO Result := do
  let publication := state.journal.entries.findSome? fun entry => do
    if entry.request.node != source.node then none else do
      let p ← admittedPublication entry
      if p.receipt == source.receipt then some p else none
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
  let snapshot := work / "snapshot"
  Git.materialize repo candidate.tree snapshot
  let json ← Git.decode (Json.parse (← IO.FS.readFile (snapshot / "plan.json")))
  let plan : Plan ← Git.decode (fromJson? json)
  let parent ← FifoPolicy.readClaims repo scope.policy
  let controller ← Verifier.digestFile repo (← IO.appPath)
  let mut evidence : Array Git.Blob := #[]
  let retain (blobs : Array Git.Blob) (verdict : RefinementVerdict) : IO Result :=
    return ⟨verdict, ← Git.tree repo none blobs⟩
  let input ← Git.hashText repo (Json.mkObj [("scope", toJson scope),
    ("candidate", toJson candidate), ("plan", toJson plan), ("controller", toJson controller)]).compress
  evidence := evidence.push ⟨"input.json", input⟩
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
      childClaims := childClaims ++ [← FifoPolicy.readClaims repo existing.domain.scope.policy]
  let flattened := childClaims.flatten
  unless !childClaims.isEmpty && childClaims.all (fun child =>
      !child.isEmpty && child.all parent.contains) && flattened.eraseDups == flattened &&
      plan.implementation.all (· < childClaims.length) do
    return ← retain evidence (.rejected "invalid child partition or implementation choice")
  let config ← Git.resolve repo s!"{scope.policy}:controller-toolchain.json"
  let toolJson ← Git.decode (Json.parse (← Git.readBlob repo config))
  let tools : Verifier.Toolchain ← Git.decode (fromJson? toolJson)
  unless (← Verifier.toolBindings repo tools.root) == tools.files do
    return ← retain evidence (.unknown "pinned verifier tools changed")
  let planSource := "import Logic\nnamespace Plan\n" ++
    s!"def parent : List Nat := {leanList parent}\n" ++
    s!"def children : List (List Nat) := [{String.intercalate ", " (childClaims.map leanList)}]\nend Plan\n"
  let gate := "import Plan\nimport Refinement\nnamespace Gate\n" ++
    "theorem accepted (facts : Nat → Prop) :\n" ++
    "  (∀ child ∈ Plan.children, Holds child facts) → Holds Plan.parent facts :=\n" ++
    "  Refinement.valid facts\nend Gate\n"
  let lake := "name = \"axiward-refinement\"\nversion = \"0.1.0\"\n" ++
    "[[lean_lib]]\nname = \"Logic\"\n[[lean_lib]]\nname = \"Plan\"\n" ++
    "[[lean_lib]]\nname = \"Refinement\"\n[[lean_lib]]\nname = \"Gate\"\n"
  for (name, text) in #[("Logic.lean", logic), ("Plan.lean", planSource),
      ("Gate.lean", gate), ("Audit.lean", audit), ("lakefile.toml", lake)] do
    IO.FS.writeFile (snapshot / name) text
    evidence := evidence.push ⟨name, ← Git.hashText repo text⟩
  let proofBefore ← Verifier.digestFile repo (snapshot / "Refinement.lean")
  evidence := evidence.push ⟨"Refinement.lean", ← Git.hashFile repo (snapshot / "Refinement.lean")⟩
  let steps := #[
    ("01-build", #["--no-cache", "build", "Gate"]),
    ("02-audit", #["env", "lean", "Audit.lean"]),
    ("03-replay", #["env", "leanchecker", "Logic", "Plan", "Refinement", "Gate"])]
  for (name, arguments) in steps do
    let start ← IO.monoMsNow
    let result ← IO.Process.output {
      cmd := ((tools.root : FilePath) / "bin" / "lake.exe").toString
      args := arguments
      cwd := some snapshot
      env := Verifier.buildEnvironment }
    let record : Verifier.ToolResult := ⟨name, arguments, result.exitCode.toNat,
      (← IO.monoMsNow) - start, result.stdout, result.stderr⟩
    let log := (toJson record).compress
    IO.FS.writeFile (work / s!"{name}.json") log
    evidence := evidence.push ⟨s!"{name}.json", ← Git.hashText repo log⟩
    if result.exitCode != 0 then return ← retain evidence (.rejected s!"{name} did not pass")
  unless (← Verifier.digestFile repo (snapshot / "Refinement.lean")) == proofBefore &&
      (← Verifier.toolBindings repo tools.root) == tools.files &&
      (← Verifier.digestFile repo (← IO.appPath)) == controller do
    return ← retain evidence (.unknown "refinement or tools changed during verification")
  for name in #["Logic.lean", "Plan.lean", "Gate.lean", "Audit.lean", "lakefile.toml"] do
    let some binding := evidence.find? (fun b => b.path == name) | throw (IO.userError "missing input binding")
    unless (← Verifier.digestFile repo (snapshot / name)) == binding.oid do
      return ← retain evidence (.rejected "trusted refinement goal changed during checking")
  let children : List ChildTarget ← plan.children.mapM fun child => match child with
    | .fresh claims => return .fresh (← FifoPolicy.selectClaims repo scope.policy claims)
    | .reuse node => do
      let some existing := state.nodes[node]? | throw (IO.userError "missing reuse snapshot")
      pure (.reuse ⟨node, existing.domain.scope⟩)
  let receipt ← Git.hashText repo (Json.mkObj [("scope", toJson scope),
    ("candidate", toJson candidate), ("children", toJson children), ("tools", toJson tools),
    ("controller", toJson controller)]).compress
  evidence := evidence.push ⟨"receipt.json", receipt⟩
  evidence := evidence.push ⟨"Gate.olean", ← Git.hashFile repo (snapshot / ".lake/build/lib/lean/Gate.olean")⟩
  let certificate ← Git.tree repo none evidence
  return ⟨.passed ⟨scope, candidate, children, certificate, plan.implementation⟩, certificate⟩

def check (repo : FilePath) (scope : Scope) (candidate : Candidate) (state : State) : IO Result := do
  let work ← Git.scratch repo
  IO.FS.writeFile (work / "input.json") (Json.mkObj [
    ("scope", toJson scope), ("candidate", toJson candidate)]).compress
  try checkCore repo scope candidate work state
  catch error =>
    let errorBlob ← Git.hashText repo (Json.mkObj [("error", toJson error.toString)]).compress
    let mut logs : Array Git.Blob := #[⟨"error.json", errorBlob⟩]
    for name in #["input.json", "01-build.json", "02-audit.json", "03-replay.json"] do
      if ← (work / name).pathExists then logs := logs.push ⟨name, ← Git.hashFile repo (work / name)⟩
    return ⟨.unknown "refinement checker could not complete; see evidence", ← Git.tree repo none logs⟩

/-- An explicit source permits rebinding retained proofs to that implementation.
    The parent verifier must then prove the full current goal for the actual assembled code. -/
def assemble (repo : FilePath) (scope : Scope) (route : Route) (children : List ChildResult) : IO Candidate := do
  let mut queue : Option String := none
  let mut blobs : Array Git.Blob := #[]
  let mut imports := ""
  let mut importedProofs : List String := []
  if let some selected := route.implementation then
    let some child := children[selected]? | throw (IO.userError "invalid implementation source")
    let implementation ← Git.resolve repo s!"{child.publication.product}:Axiward/Queue.lean"
    queue := some implementation
    blobs := blobs.push ⟨"Axiward/Queue.lean", implementation⟩
  for child in children do
    unless compatible child.publication.scope scope do
      throw (IO.userError "child requirements are incompatible with the current parent")
    let product := child.publication.product
    let implementation ← Git.resolve repo s!"{product}:Axiward/Queue.lean"
    if let some expected := queue then
      if route.implementation.isNone && implementation != expected then
        throw (IO.userError "child proofs describe different queue implementations; an explicit source and recheck are required")
    else
      queue := some implementation
      blobs := blobs.push ⟨"Axiward/Queue.lean", implementation⟩
    let moduleName := s!"Axiward.Parts.N{child.node}"
    let proof ← Git.resolve repo s!"{product}:Axiward/Proofs.lean"
    -- Identical proof modules need one import, even when independently admitted
    -- children use the same complete file. The parent gate still checks all goals.
    unless importedProofs.contains proof do
      importedProofs := importedProofs ++ [proof]
      blobs := blobs.push ⟨s!"Axiward/Parts/N{child.node}.lean", proof⟩
      imports := imports ++ s!"import {moduleName}\n"
    let files := (← Git.checked repo #["ls-tree", "-r", "--name-only", product, "--", "Axiward/Parts"]).splitOn "\n"
    for path in files do
      if !path.isEmpty then blobs := blobs.push ⟨path, ← Git.resolve repo s!"{product}:{path}"⟩
  unless queue.isSome do throw (IO.userError "no child implementations")
  blobs := blobs.push ⟨"Axiward/Proofs.lean", ← Git.hashText repo imports⟩
  blobs := blobs.push ⟨"submission.json", ← Git.hashText repo "{\"format\":\"axiward-composition-v1\"}\n"⟩
  return ⟨← Git.tree repo none blobs⟩

end Axiward.Refinement
