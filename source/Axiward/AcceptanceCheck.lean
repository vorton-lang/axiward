import Axiward.Policy
import Lean.Replay

namespace Axiward.AcceptanceCheck

open Lean System

structure Result where
  modules : Array String
  dependencies : Array String
  declarations : Nat
  deriving ToJson

private def key (path : FilePath) : String :=
  path.normalize.toString.replace "\\" "/" |>.toLower

private def under (path root : FilePath) : Bool :=
  (key path).startsWith (key root ++ "/")

private def ordinary (path : FilePath) : IO Unit := do
  unless (← path.symlinkMetadata).type == .file && key (← IO.FS.realPath path) == key path do
    throw (IO.userError s!"kernel input must be an ordinary non-redirected file: {path}")

private def withPath (toolRoot localRoot : FilePath) (action : IO α) : IO α := do
  let previous ← searchPathRef.get
  searchPathRef.set [toolRoot / "lib/lean", localRoot]
  try action finally searchPathRef.set previous

private def modulePath (moduleName : Name) : String :=
  moduleName.toString.replace "." "/"

private def moduleParts (path : FilePath) : IO (Array FilePath) := do
  ordinary path
  let mut result := #[path]
  for level in #[OLeanLevel.server, OLeanLevel.private] do
    let part := level.adjustFileName path
    if ← part.pathExists then
      ordinary part
      result := result.push part
  return result

private def modules (env : Environment) (toolRoot localRoot : FilePath)
    (sources : Array String) : IO (Array Name × Array Name × Array String) := do
  let mut localModules := #[]
  let mut standard := #[]
  let mut dependencies := #[]
  for moduleName in env.header.moduleNames do
    let path ← findOLean moduleName
    let parts ← moduleParts path
    if under path localRoot then
      unless sources.contains (modulePath moduleName ++ ".lean") do
        throw (IO.userError s!"proof dependency has no pinned source: {moduleName}")
      localModules := localModules.push moduleName
    else if under path (toolRoot / "lib/lean") then
      standard := standard.push moduleName
      for part in parts do
        dependencies := dependencies.push (part.normalize.toString.replace "\\" "/" |>.drop
          ((toolRoot.normalize.toString.replace "\\" "/").length + 1) |>.toString)
    else
      throw (IO.userError s!"proof dependency is outside the pinned package and toolchain: {moduleName}")
  return (localModules, standard, dependencies)

private def declarations (env : Environment) (owners : Array Name) : IO (Std.HashMap Name ConstantInfo) := do
  let mut result := {}
  let moduleNames := env.header.moduleNames
  for (name, info) in env.constants do
    let some index := env.getModuleIdxFor? name | continue
    unless owners.contains moduleNames[index.toNat]! do continue
    if info.isUnsafe || info.isPartial then
      throw (IO.userError s!"unsafe or partial declaration is outside the acceptance convention: {name}")
    if info matches .axiomInfo _ then
      throw (IO.userError s!"UNAPPROVED_AXIOM: {name}")
    result := result.insert name info
  return result

private def auditAxioms (env : Kernel.Environment) (initial : Array Name) : IO Unit := do
  let mut pending := initial
  let mut seen : NameSet := {}
  let mut cursor := 0
  while cursor < pending.size do
    let name := pending[cursor]!
    cursor := cursor + 1
    if seen.contains name then continue
    seen := seen.insert name
    let some info := env.find? name | throw (IO.userError s!"missing proof declaration: {name}")
    if info matches .axiomInfo _ then
      unless [`propext, `Quot.sound, `Classical.choice].contains name do
        throw (IO.userError s!"UNAPPROVED_AXIOM: {name}")
    pending := pending ++ info.type.getUsedConstants
    if let some value := info.value? (allowOpaque := true) then
      pending := pending ++ value.getUsedConstants
    if let .inductInfo value := info then pending := pending ++ value.ctors.toArray

private def named (text : String) : Name := text.toName

/-- All claim types have the same explicit subject binders and result Prop.
    Universe quantification belongs inside the supported closed declarations. -/
private def parameters (kernel : Kernel.Environment) (manifest : Policy.Manifest) :
    IO (Array (Name × Expr × BinderInfo)) := do
  let mut parameters := #[]
  let mut reference : Option Expr := none
  for claim in manifest.claims do
    let some info := kernel.find? (named claim.proposition)
      | throw (IO.userError s!"missing pinned proposition: {claim.proposition}")
    unless info.levelParams.isEmpty do
      throw (IO.userError "acceptance propositions must have no free universe parameters")
    if let some type := reference then
      unless info.type == type do
        throw (IO.userError "acceptance propositions must share the same subject parameter types")
    else reference := some info.type
    let mut type := info.type
    let mut binders := #[]
    for _ in claim.arguments do
      let .forallE name domain body binder := type.consumeMData
        | throw (IO.userError "proposition has fewer subject binders than the manifest")
      binders := binders.push (name, domain, binder)
      type := body
    unless type.consumeMData == .sort .zero do
      throw (IO.userError "after subject arguments an acceptance proposition must have type Prop")
    parameters := binders
  return parameters

private def imports (names : Array String) : Array Import :=
  names.map (fun name => { module := named name })

private def requireOwnModules (root : FilePath) (names : Array String) : IO Unit := do
  for name in names do
    let path ← findOLean (named name)
    unless under path root do
      throw (IO.userError s!"required local module resolves outside its pinned data: {name}")

/-- Validates the standalone formal specification without importing any candidate.
    Returns exactly the standard-library proof files used by the kernel. -/
def validateSpecification (toolRoot frozen : FilePath) (manifest : Policy.Manifest) : IO Result :=
  withPath toolRoot frozen do
    requireOwnModules frozen manifest.specificationModules
    let env ← importModules (imports manifest.specificationModules) {} (loadExts := false)
    let (localModules, standard, dependencies) ← modules env toolRoot frozen manifest.files
    let fixed ← declarations env localModules
    let base ← importModules (standard.map (fun module => { module })) {} (loadExts := false)
    let kernel ← base.toKernelEnv.replay fixed
    let _ ← parameters kernel manifest
    for claim in manifest.claims do
      unless fixed.contains (named claim.proposition) do
        throw (IO.userError "proposition must be defined in the pinned specification modules")
    auditAxioms kernel (fixed.toArray.map (·.1))
    return ⟨localModules.map Name.toString, dependencies, fixed.size⟩

private def checkCore (toolRoot frozen candidateObjects : FilePath) (manifest : Policy.Manifest)
    (relation : Option (List Nat × List (List Nat))) (selected : List Nat) : IO Result := do
  let (trusted, fixedModules, fixed, standard, fixedDependencies) ← withPath toolRoot frozen do
    requireOwnModules frozen manifest.specificationModules
    let trusted ← importModules (imports manifest.specificationModules) {} (loadExts := false)
    let (owners, standard, dependencies) ← modules trusted toolRoot frozen manifest.files
    return (trusted, owners, ← declarations trusted owners, standard, dependencies)
  let _ := trusted
  withPath toolRoot candidateObjects do
    let proofModules := if relation.isSome then #["Refinement"] else manifest.proofModules
    requireOwnModules candidateObjects proofModules
    let env ← importModules (imports proofModules) {} (loadExts := false)
    let sources := manifest.files ++ manifest.candidateFiles.map (·.target) ++
      (if relation.isSome then #["Plan.lean", "Refinement.lean"] else #[])
    let (owners, importedStandard, dependencies) ← modules env toolRoot candidateObjects sources
    let candidateModules := owners.filter (fun module => !fixedModules.contains module)
    let candidateDeclarations ← declarations env candidateModules
    let base ← importModules ((standard ++ importedStandard).toList.eraseDups.toArray.map
      (fun module => { module })) {} (loadExts := false)
    -- Candidate copies of specification declarations are never authority. Both
    -- the candidate terms and proof terms are replayed against the frozen ones.
    let kernel ← base.toKernelEnv.replay fixed
    let binders ← parameters kernel manifest
    let mut kernel ← kernel.replay candidateDeclarations
    let checkProof (kernel : Kernel.Environment) (proof : String) (expected : Expr) (index : Nat) :
        IO Kernel.Environment := do
      let some info := candidateDeclarations[named proof]?
        | throw (IO.userError s!"candidate proof is missing: {proof}")
      unless info.levelParams.isEmpty do
        throw (IO.userError "candidate proof must have no free universe parameters")
      let name := Name.num `AxiwardAcceptanceCertificate index
      if kernel.find? name |>.isSome then throw (IO.userError "certificate name collision")
      let certificate : ConstantInfo := .thmInfo {
        name, levelParams := [], type := expected, value := mkConst (named proof), all := [name] }
      kernel.replay (({} : Std.HashMap Name ConstantInfo).insert name certificate)
    if let some (parent, children) := relation then
      let args := (Array.range binders.size).map (fun i => Expr.bvar (binders.size - i - 1))
      let conjunction (indices : List Nat) := indices.foldr (fun index rest =>
        mkApp2 (mkConst ``And) (mkAppN (mkConst (named manifest.claims[index]!.proposition)) args) rest)
        (mkConst ``True)
      let mut expected := children.foldr (fun child rest =>
        Expr.forallE .anonymous (conjunction child) (rest.liftLooseBVars 0 1) .default) (conjunction parent)
      for (name, type, binder) in binders.reverse do
        expected := .forallE name type expected binder
      kernel ← checkProof kernel "Refinement.valid" expected 0
    else
      for index in selected do
        let claim := manifest.claims[index]!
        for argument in claim.arguments do
          let some info := candidateDeclarations[named argument]?
            | throw (IO.userError s!"candidate subject is missing: {argument}")
          unless info.levelParams.isEmpty do
            throw (IO.userError "candidate subject must have no free universe parameters")
        let expected := mkAppN (mkConst (named claim.proposition)) (claim.arguments.map (mkConst ∘ named))
        kernel ← checkProof kernel claim.proof expected index
    auditAxioms kernel (candidateDeclarations.toArray.map (·.1))
    return ⟨owners.map Name.toString, (fixedDependencies ++ dependencies).toList.eraseDups.toArray,
      fixed.size + candidateDeclarations.size⟩

def check (toolRoot frozen candidateObjects : FilePath) (manifest : Policy.Manifest)
    (selected : List Nat) : IO Result := do
  Policy.validateClaims manifest selected
  checkCore toolRoot frozen candidateObjects manifest none selected

def checkRelation (toolRoot frozen candidateObjects : FilePath) (manifest : Policy.Manifest)
    (parent : List Nat) (children : List (List Nat)) : IO Result := do
  Policy.validateClaims manifest parent
  for child in children do Policy.validateClaims manifest child
  unless !children.isEmpty do throw (IO.userError "refinement requires child propositions")
  checkCore toolRoot frozen candidateObjects manifest (some (parent, children)) []

end Axiward.AcceptanceCheck
