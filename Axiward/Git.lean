import Axiward.Engine

namespace Axiward.Git

open Lean System

def decode {α : Type} (value : Except String α) : IO α :=
  match value with
  | .ok a => pure a
  | .error e => throw (IO.userError e)

def objectId (value : String) : Bool :=
  value.length == 64 && value.toList.all (fun c => c.isDigit || ('a' ≤ c && c ≤ 'f'))

def cleanEnv : Array (String × Option String) :=
  #["GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE",
    "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_NAMESPACE",
    "GIT_CONFIG_PARAMETERS", "GIT_CONFIG_COUNT", "GIT_REPLACE_REF_BASE"].map
    (fun key => (key, none)) ++
  #[("GIT_CONFIG_GLOBAL", some "NUL"), ("GIT_CONFIG_SYSTEM", some "NUL")]

def call (repo : FilePath) (args : Array String) (input : Option String := none)
    (index : Option FilePath := none) : IO IO.Process.Output := do
  IO.Process.output {
    cmd := "git"
    args := #["--no-replace-objects", "--literal-pathspecs", s!"--git-dir={repo}",
      "-c", s!"core.hooksPath={repo / "axiward-no-hooks"}",
      "-c", "user.name=Axiward", "-c", "user.email=axiward@localhost",
      "-c", "commit.gpgsign=false", "-c", "core.autocrlf=false",
      "-c", "core.fsync=committed"] ++ args
    env := cleanEnv ++ index.toArray.map (fun p => ("GIT_INDEX_FILE", some p.toString))
  } input

def checked (repo : FilePath) (args : Array String) (input : Option String := none)
    (index : Option FilePath := none) : IO String := do
  let output ← call repo args input index
  unless output.exitCode == 0 do
    throw (IO.userError s!"git {args[0]?.getD ""}: {output.stderr}")
  return output.stdout.trimAscii.toString

def checkRepository (repo : FilePath) : IO Unit := do
  unless repo.isAbsolute do throw (IO.userError "repository path must be absolute")
  unless (← checked repo #["rev-parse", "--is-bare-repository"]) == "true" do
    throw (IO.userError "managed repository must be bare")
  unless (← checked repo #["rev-parse", "--show-object-format"]) == "sha256" do
    throw (IO.userError "managed repository must use SHA-256")

def initRepository (repo : FilePath) : IO Unit := do
  unless repo.isAbsolute do throw (IO.userError "repository path must be absolute")
  if ← repo.pathExists then throw (IO.userError "initialization requires a new directory")
  let result ← IO.Process.output {
    cmd := "git"
    args := #["init", "--bare", "--object-format=sha256", "--initial-branch=main", repo.toString]
    env := cleanEnv }
  unless result.exitCode == 0 do throw (IO.userError result.stderr)
  checkRepository repo

def hashText (repo : FilePath) (text : String) : IO String :=
  checked repo #["hash-object", "-w", "--stdin"] (some text)

def hashFile (repo file : FilePath) : IO String :=
  checked repo #["hash-object", "-w", "--no-filters", "--", file.toString]

def readBlob (repo : FilePath) (oid : String) : IO String := do
  unless objectId oid do throw (IO.userError "invalid object ID")
  let result ← call repo #["cat-file", "blob", oid]
  unless result.exitCode == 0 do throw (IO.userError result.stderr)
  return result.stdout

def scratch (repo : FilePath) : IO FilePath := do
  let parent := repo / "axiward-work"
  IO.FS.createDirAll parent
  let path := parent / s!"run-{← IO.monoNanosNow}-{← IO.rand 0 1000000000}"
  IO.FS.createDir path
  return path

structure Blob where
  path : String
  oid : String
  deriving Repr

def safePath (path : String) : Bool :=
  !path.isEmpty && !(path.startsWith "/") &&
  !(path.toList.any (fun c => c == '\\' || c == ':' || c == '\x00' || c == '\n' || c == '\r')) &&
  (path.splitOn "/").all (fun part => !part.isEmpty && part != "." &&
    part != ".." && part.toLower != ".git")

/-- A private index constructs the complete next tree; no checkout is modified. -/
def tree (repo : FilePath) (base : Option String) (blobs : Array Blob)
    (subtrees : Array (String × String) := #[]) : IO String := do
  let index := (← scratch repo) / "index"
  let _ ← checked repo (match base with
    | some oid => #["read-tree", oid]
    | none => #["read-tree", "--empty"]) none (some index)
  for (treePrefix, oid) in subtrees do
    unless safePath treePrefix && objectId oid do throw (IO.userError "invalid subtree binding")
    let listing ← checked repo #["ls-files", "-z", "--", treePrefix] none (some index)
    for path in listing.splitOn "\x00" do
      if !path.isEmpty then
        unless safePath path do throw (IO.userError "invalid existing managed path")
        let zero := String.ofList (List.replicate 64 '0')
        let _ ← checked repo #["update-index", "--index-info"]
          (some s!"0 {zero}\t{path}\n") (some index)
    let _ ← checked repo #["read-tree", "-i", s!"--prefix={treePrefix}/", oid] none (some index)
  for blob in blobs do
    unless safePath blob.path && objectId blob.oid do throw (IO.userError "invalid blob binding")
    let _ ← checked repo #["update-index", "--add", "--cacheinfo", "100644", blob.oid,
      blob.path] none (some index)
  checked repo #["write-tree"] none (some index)

def resolve (repo : FilePath) (revision : String) : IO String :=
  checked repo #["rev-parse", "--verify", "--end-of-options", revision]

def commitTree (repo : FilePath) (tree : String) (parent : Option String)
    (message : String) : IO String :=
  checked repo (#["commit-tree", tree] ++
    (parent.toArray.flatMap (fun oid => #["-p", oid]))) (some message)

def compareAndSwap (repo : FilePath) (expected : Option String) (commit : String) : IO Bool := do
  let output ← call repo #["update-ref", "--no-deref", "refs/heads/main", commit,
    expected.getD (String.ofList (List.replicate 64 '0'))]
  if output.exitCode == 0 then return true
  let actual ← call repo #["rev-parse", "--verify", "refs/heads/main"]
  if actual.exitCode == 0 && some actual.stdout.trimAscii.toString != expected then return false
  if (output.stderr.splitOn "File exists").length > 1 then return false
  throw (IO.userError s!"reference update failed: {output.stderr}")

structure Loaded where
  head : String
  state : State

def nodePath (id : Nat) : String := if id == 0 then ".axiward" else s!".axiward/nodes/{id}"

def productPath (id : Nat) : String := if id == 0 then "product" else s!"{nodePath id}/product"

def verifyBindings (repo : FilePath) (head : String) (nodes : Array Node) : IO Unit := do
  for (node, i) in nodes.toList.zipIdx do
    let s := node.domain
    let path := nodePath i
    unless (← resolve repo s!"{head}:{path}/policy") == s.scope.policy do
      throw (IO.userError s!"node {i}: policy tree differs from journal scope")
    unless (← resolve repo s!"{head}:{path}/policy/Axiward/Spec.lean") == s.scope.specification do
      throw (IO.userError s!"node {i}: specification differs from journal scope")
    if let some package := s.active then
      if let .checking candidate := package.phase then
        unless (← resolve repo s!"{head}:{path}/candidate") == candidate.tree do
          throw (IO.userError s!"node {i}: sealed candidate differs from journal")
    if let some publication := s.published then
      unless (← resolve repo s!"{head}:{productPath i}") == publication.product &&
          (← resolve repo s!"{head}:{path}/receipt.json") == publication.receipt do
        throw (IO.userError s!"node {i}: published product or receipt differs from journal")
    if let some route := node.route then
      unless (← resolve repo s!"{head}:{path}/route") == route.certificate do
        throw (IO.userError s!"node {i}: refinement certificate differs from journal")
    for (op, j) in s.workflow.operations.zipIdx do
      unless (← resolve repo s!"{head}:{path}/operations/{j}/input") == op.candidate.tree do
        throw (IO.userError "operation input differs from journal")
      if op.result.isSome then
        unless (← resolve repo s!"{head}:{path}/operations/{j}/evidence") == op.evidence do
          throw (IO.userError "observation differs from journal")
    for (serial, report) in s.workflow.reports do
      unless (← resolve repo s!"{head}:{path}/reports/{serial}.md") == report do
        throw (IO.userError "exploration report differs from journal")
def load (repo : FilePath) : IO Loaded := do
  checkRepository repo
  let head ← resolve repo "refs/heads/main"
  let oid ← resolve repo s!"{head}:.axiward/state.json"
  let json ← decode (Json.parse (← readBlob repo oid))
  let journal : Journal ← decode (fromJson? json)
  let state ← decode (restore journal)
  verifyBindings repo head state.nodes
  return ⟨head, state⟩

def create (repo : FilePath) (scope : Scope) : IO Unit := do
  unless validRequirements scope.requirements do throw (IO.userError "invalid requirements")
  let state ← decode (restore { initial := scope })
  let stateBlob ← hashText repo (toJson state.journal).compress
  let root ← tree repo none #[⟨".axiward/state.json", stateBlob⟩]
    #[(".axiward/policy", scope.policy)]
  let commit ← commitTree repo root none "Axiward initialization\n"
  unless ← compareAndSwap repo none commit do throw (IO.userError "project already initialized")

def commitChange (repo : FilePath) (loaded : Loaded) (change : Change loaded.state) : IO Bool := do
  if !change.changed then return true
  let stateBlob ← hashText repo (toJson change.after.journal).compress
  let mut blobs : Array Blob := #[⟨".axiward/state.json", stateBlob⟩]
  let mut subtrees : Array (String × String) := #[]
  if let some entry := change.after.journal.entries.getLast? then
    let path := nodePath entry.request.node
    match entry.request.command with
    | .finish serial _ evidence | .finishRefinement serial _ evidence =>
      subtrees := subtrees.push (s!"{path}/checks/{serial}", evidence)
    | .compose _ _ evidence =>
      subtrees := subtrees.push (s!"{path}/compositions/{change.after.journal.entries.length}", evidence)
    | .archive _ _ evidence =>
      subtrees := subtrees.push (s!"{path}/late-checks/{change.after.journal.entries.length}", evidence)
    | _ => pure ()
  for (node, i) in change.after.nodes.toList.zipIdx do
    let previous := loaded.state.nodes[i]?
    let path := nodePath i
    unless previous.any (fun old => old.domain.scope.policy == node.domain.scope.policy) do
      subtrees := subtrees.push (s!"{path}/policy", node.domain.scope.policy)
    if let some package := node.domain.active then
      if let .checking candidate := package.phase then
        unless previous.any (fun old => old.domain.active.any (fun p => p.phase == package.phase)) do
          subtrees := subtrees.push (s!"{path}/candidate", candidate.tree)
    if let some publication := node.domain.published then
      unless previous.any (fun old => old.domain.published == some publication) do
        subtrees := subtrees.push (productPath i, publication.product)
        blobs := blobs.push ⟨s!"{path}/receipt.json", publication.receipt⟩
    if let some route := node.route then
      unless previous.any (fun old => old.route == some route) do
        subtrees := subtrees.push (s!"{path}/route", route.certificate)
    for (op, j) in node.domain.workflow.operations.zipIdx do
      let old := previous.bind (fun n => n.domain.workflow.operations[j]?)
      if old.isNone then
        subtrees := subtrees.push (s!"{path}/operations/{j}/input", op.candidate.tree)
      if op.result.isSome && !old.any (fun x => x.result == op.result) then
        subtrees := subtrees.push (s!"{path}/operations/{j}/evidence", op.evidence)
        if let some (.passed output) := op.result then
          subtrees := subtrees.push (s!"{path}/operations/{j}/product", output.product)
          blobs := blobs.push ⟨s!"{path}/operations/{j}/receipt.json", output.receipt⟩
    for (serial, report) in node.domain.workflow.reports do
      unless previous.any (fun n => n.domain.workflow.reports.contains (serial, report)) do
        blobs := blobs.push ⟨s!"{path}/reports/{serial}.md", report⟩
  let root ← tree repo (some loaded.head) blobs subtrees
  let commit ← commitTree repo root (some loaded.head)
    s!"Axiward transition {change.after.journal.entries.length}\n"
  compareAndSwap repo (some loaded.head) commit
structure Transaction where
  before : Loaded
  change : Change before.state

/-- The detailed result binds reports to the transition that actually won CAS. -/
def transactDetailed (repo : FilePath) (request : Request) : IO Transaction := do
  for _ in [:8] do
    let loaded ← load repo
    let change ← decode ((step loaded.state request).mapError (fun e => s!"{repr e}"))
    if ← commitChange repo loaded change then return ⟨loaded, change⟩
  throw (IO.userError "repository remains busy; retry the same request ID")

def transact (repo : FilePath) (request : Request) : IO Reply := do
  return (← transactDetailed repo request).change.reply

def materialize (repo : FilePath) (oid : String) (destination : FilePath) : IO Unit := do
  unless objectId oid do throw (IO.userError "invalid tree ID")
  let index := (← scratch repo) / "index"
  let _ ← checked repo #["read-tree", oid] none (some index)
  IO.FS.createDirAll destination
  let treePrefix := destination.toString.replace "\\" "/" ++ "/"
  let _ ← checked repo #[s!"--work-tree={destination}", "checkout-index", "--all",
    s!"--prefix={treePrefix}"] none (some index)
  return ()

end Axiward.Git
