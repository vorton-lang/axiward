import Axiward.Engine

namespace Axiward.Git

open Lean System

def decode {α : Type} (value : Except String α) : IO α :=
  match value with
  | .ok a => pure a
  | .error e => throw (IO.userError e)

def objectId (value : String) : Bool :=
  (value.length == 40 || value.length == 64) &&
    value.toList.all (fun c => c.isDigit || ('a' ≤ c && c ≤ 'f'))

def gitDirectory (repo : FilePath) : FilePath := repo / ".git"

def cleanEnv : Array (String × Option String) :=
  #["GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE",
    "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_NAMESPACE",
    "GIT_CONFIG_PARAMETERS", "GIT_CONFIG_COUNT", "GIT_REPLACE_REF_BASE"].map
    (fun key => (key, none)) ++
  #[("GIT_CONFIG_GLOBAL", some "NUL"), ("GIT_CONFIG_SYSTEM", some "NUL")]

def call (repo : FilePath) (args : Array String) (input : Option String := none)
    (index : Option FilePath := none) : IO IO.Process.Output := do
  let process : IO.Process.SpawnArgs := {
    cmd := "git"
    args := #["--no-replace-objects", "--literal-pathspecs", s!"--git-dir={gitDirectory repo}",
      s!"--work-tree={repo}", "-c", s!"core.hooksPath={gitDirectory repo / "axiward-no-hooks"}",
      "-c", "user.name=Axiward", "-c", "user.email=axiward@localhost",
      "-c", "commit.gpgsign=false", "-c", "core.autocrlf=false",
      "-c", "core.fsync=committed"] ++ args
    env := cleanEnv ++ index.toArray.map (fun p => ("GIT_INDEX_FILE", some p.toString))
    cwd := some repo
  }
  let some input := input | IO.Process.output process
  -- Git can answer each input line immediately. Drain both output pipes before
  -- writing a large request, and release stdin before waiting for Git's EOF.
  let (child, stdout, stderr, written) ← do
    let (stdin, child) ← (← IO.Process.spawn
      { process with stdin := .piped, stdout := .piped, stderr := .piped }).takeStdin
    let stdout ← IO.asTask child.stdout.readToEnd Task.Priority.dedicated
    let stderr ← IO.asTask child.stderr.readToEnd Task.Priority.dedicated
    let written : Except IO.Error Unit ← try
      stdin.putStr input
      stdin.flush
      pure (.ok ())
      catch error => pure (.error error)
    pure (child, stdout, stderr, written)
  try
    IO.ofExcept written
    let output ← IO.ofExcept stdout.get
    let errors ← IO.ofExcept stderr.get
    let exitCode ← child.wait
    return { exitCode, stdout := output, stderr := errors }
  catch error =>
    try child.kill catch _ => pure ()
    try let _ ← child.wait; pure () catch _ => pure ()
    try let _ ← IO.ofExcept stdout.get; pure () catch _ => pure ()
    try let _ ← IO.ofExcept stderr.get; pure () catch _ => pure ()
    throw error

def checked (repo : FilePath) (args : Array String) (input : Option String := none)
    (index : Option FilePath := none) : IO String := do
  let output ← call repo args input index
  unless output.exitCode == 0 do
    throw (IO.userError s!"git {args[0]?.getD ""}: {output.stderr}")
  return output.stdout.trimAscii.toString

def checkRepository (repo : FilePath) : IO Unit := do
  unless repo.isAbsolute do throw (IO.userError "repository path must be absolute")
  let properties := (← checked repo #["rev-parse", "--is-bare-repository", "--show-object-format"]).splitOn "\n"
  let [bare, format] := properties | throw (IO.userError "incomplete repository properties")
  unless bare == "false" do
    throw (IO.userError "managed project must be a normal checkout with its own .git directory")
  unless (← checked repo #["symbolic-ref", "HEAD"]) == "refs/heads/main" do
    throw (IO.userError "managed checkout must remain on main")
  unless ["sha1", "sha256"].contains format do
    throw (IO.userError "managed repository must use SHA-1 or SHA-256")

def initRepository (repo : FilePath) : IO Unit := do
  unless repo.isAbsolute do throw (IO.userError "repository path must be absolute")
  if ← repo.pathExists then throw (IO.userError "initialization requires a new directory")
  let result ← IO.Process.output {
    cmd := "git"
    args := #["init", "--object-format=sha256", "--initial-branch=main", repo.toString]
    env := cleanEnv }
  unless result.exitCode == 0 do throw (IO.userError result.stderr)
  checkRepository repo

def hashText (repo : FilePath) (text : String) : IO String :=
  checked repo #["hash-object", "-w", "--stdin"] (some text)

def hashFile (repo file : FilePath) : IO String :=
  checked repo #["hash-object", "-w", "--no-filters", "--", file.toString]

private def batchInput (revisions : Array String) : IO String := do
  unless revisions.all (fun revision => !revision.isEmpty &&
      !revision.toList.any (fun c => c == '\n' || c == '\r' || c == '\x00')) do
    throw (IO.userError "invalid batch object reference")
  return String.intercalate "\n" revisions.toList ++ "\n"

/-- Git returns one object in request order, including repeated references.
    Missing objects and unexpected kinds fail the whole lookup. -/
def resolveMany (repo : FilePath) (revisions : Array String)
    (expectedKind : Option String := none) : IO (Array String) := do
  if revisions.isEmpty then return #[]
  let output ← checked repo #["cat-file", "--batch-check=%(objectname) %(objecttype)"]
    (some (← batchInput revisions))
  let records := output.splitOn "\n"
  unless records.length == revisions.size do throw (IO.userError "incomplete batch object lookup")
  let mut result := #[]
  for (record, revision) in records.zip revisions.toList do
    let [oid, kind] := record.splitOn " " | throw (IO.userError s!"object lookup failed: {revision}")
    unless objectId oid && ["blob", "tree", "commit", "tag"].contains kind &&
        expectedKind.all (· == kind) do
      throw (IO.userError s!"missing object or unexpected object kind: {revision}")
    result := result.push oid
  return result

/-- Text blobs are framed by Git's byte count, never by text lines or character
    indices. Valid UTF-8 and every trailing separator are checked explicitly. -/
def readBlobs (repo : FilePath) (revisions : Array String) : IO (Array String) := do
  if revisions.isEmpty then return #[]
  let output ← call repo #["cat-file", "--batch"] (some (← batchInput revisions))
  unless output.exitCode == 0 do throw (IO.userError output.stderr)
  let bytes := output.stdout.toUTF8
  let mut cursor := 0
  let mut result := #[]
  for revision in revisions do
    let start := cursor
    while cursor < bytes.size && bytes[cursor]! != 10 do cursor := cursor + 1
    unless cursor < bytes.size do throw (IO.userError "incomplete batch blob header")
    let some header := String.fromUTF8? (bytes.extract start cursor)
      | throw (IO.userError "invalid UTF-8 batch blob header")
    let [oid, "blob", amount] := header.splitOn " "
      | throw (IO.userError s!"missing object or expected a text blob: {revision}")
    let some size := amount.toNat? | throw (IO.userError "invalid batch blob size")
    unless objectId oid do throw (IO.userError "invalid batch blob object ID")
    let start := cursor + 1
    let stop := start + size
    unless stop < bytes.size && bytes[stop]! == 10 do
      throw (IO.userError "incomplete batch blob contents")
    let some content := String.fromUTF8? (bytes.extract start stop)
      | throw (IO.userError "batch blob is not valid UTF-8 text")
    result := result.push content
    cursor := stop + 1
  unless cursor == bytes.size do throw (IO.userError "unexpected trailing batch blob data")
  return result

def readBlob (repo : FilePath) (oid : String) : IO String := do
  unless objectId oid do throw (IO.userError "invalid object ID")
  let result ← call repo #["cat-file", "blob", oid]
  unless result.exitCode == 0 do throw (IO.userError result.stderr)
  return result.stdout

def scratch (repo : FilePath) : IO FilePath := do
  let parent := gitDirectory repo / "axiward-work"
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
        let zero := String.ofList (List.replicate oid.length '0')
        let _ ← checked repo #["update-index", "--index-info"]
          (some s!"0 {zero}\t{path}\n") (some index)
    let _ ← checked repo #["read-tree", "-i", s!"--prefix={treePrefix}/", oid] none (some index)
  for blob in blobs do
    unless safePath blob.path && objectId blob.oid do throw (IO.userError "invalid blob binding")
  unless blobs.isEmpty do
    let entries := String.join (blobs.toList.map fun blob => s!"100644 {blob.oid}\t{blob.path}\x00")
    let _ ← checked repo #["update-index", "-z", "--index-info"] (some entries) (some index)
  checked repo #["write-tree"] none (some index)

def resolve (repo : FilePath) (revision : String) : IO String :=
  checked repo #["rev-parse", "--verify", "--end-of-options", revision]

def commitTree (repo : FilePath) (tree : String) (parent : Option String)
    (message : String) : IO String :=
  checked repo (#["commit-tree", tree] ++
    (parent.toArray.flatMap (fun oid => #["-p", oid]))) (some message)

structure Merge where
  tree : String
  clean : Bool
  report : String

/-- Git performs content merging on source-only trees. Controller state is not
    an input. Temporary commits only describe the fixed base and the two sides. -/
def mergeSource (repo : FilePath) (base current : Option Candidate) (submitted : Candidate) : IO Merge := do
  if base == current || current == some submitted then return ⟨submitted.tree, true, ""⟩
  let empty ← tree repo none #[]
  let baseTree := base.map (·.tree) |>.getD empty
  let currentTree := current.map (·.tree) |>.getD empty
  if currentTree == baseTree || submitted.tree == currentTree then return ⟨submitted.tree, true, ""⟩
  if submitted.tree == baseTree then return ⟨currentTree, true, ""⟩
  let ancestor ← commitTree repo baseTree none "Axiward merge base\n"
  let ours ← commitTree repo currentTree (some ancestor) "Axiward current source\n"
  let theirs ← commitTree repo submitted.tree (some ancestor) "Axiward submitted source\n"
  let result ← call repo #["merge-tree", "--write-tree", s!"--merge-base={ancestor}", ours, theirs]
  unless result.exitCode == 0 || result.exitCode == 1 do
    throw (IO.userError s!"source merge failed: {result.stderr}")
  let merged := (result.stdout.splitOn "\n").head!.trimAscii.toString
  unless objectId merged do throw (IO.userError "source merge returned no tree")
  return ⟨merged, result.exitCode == 0, result.stdout⟩

/-- Recovery metadata for projecting an already authoritative commit. It never
    supplies project state and is removed after the ordinary checkout catches up. -/
private structure Checkout where
  before : Option String
  after : String
  deriving ToJson, FromJson

private def checkout (repo : FilePath) (pending : Checkout) (preview : Bool := false) : IO Unit := do
  let _ ← checked repo (#["read-tree"] ++ (if preview then #["--dry-run"] else #[]) ++
    #["-m", "-u"] ++ pending.before.toArray ++ #[pending.after])
  return ()

private def recoverCheckout (repo : FilePath) : IO Unit := do
  let path := gitDirectory repo / "axiward-checkout.json"
  unless ← path.pathExists do return ()
  let pending : Checkout ← decode (fromJson? (← decode (Json.parse (← IO.FS.readFile path))))
  unless objectId pending.after && pending.before.all objectId do
    throw (IO.userError "invalid pending checkout record")
  let actual ← call repo #["rev-parse", "--verify", "refs/heads/main"]
  let current := if actual.exitCode == 0 then some actual.stdout.trimAscii.toString else none
  if current == some pending.after then
    checkout repo pending
  else if current != pending.before then
    throw (IO.userError "main changed outside the controller while checkout was pending")
  IO.FS.removeFile path

private def withCheckoutLock (repo : FilePath) (operation : IO α) : IO α := do
  let gate ← IO.FS.Handle.mk (gitDirectory repo / "axiward-commit.lock") .append
  gate.lock
  try
    recoverCheckout repo
    operation
  finally gate.unlock

/-- Mutating entry points also call this before returning a recorded reply.
    Read-only load/status deliberately never repair or modify the checkout. -/
def synchronize (repo : FilePath) : IO Unit := withCheckoutLock repo (pure ())

def compareAndSwap (repo : FilePath) (expected : Option String) (commit : String) : IO Bool :=
  withCheckoutLock repo do
    let actual ← call repo #["rev-parse", "--verify", "refs/heads/main"]
    let current := if actual.exitCode == 0 then some actual.stdout.trimAscii.toString else none
    unless current == expected do return false
    let pending : Checkout := ⟨expected, commit⟩
    -- Two-tree checkout refuses colliding local edits and untracked files;
    -- never use reset --hard to synchronize a human-readable working tree.
    checkout repo pending true
    let path := gitDirectory repo / "axiward-checkout.json"
    let temporary := gitDirectory repo / "axiward-checkout.tmp"
    IO.FS.writeFile temporary (toJson pending).compress
    IO.FS.rename temporary path
    let output ← call repo #["update-ref", "--no-deref", "refs/heads/main", commit,
      expected.getD (String.ofList (List.replicate commit.length '0'))]
    if output.exitCode != 0 then
      IO.FS.removeFile path
      let actual ← call repo #["rev-parse", "--verify", "refs/heads/main"]
      if actual.exitCode == 0 && some actual.stdout.trimAscii.toString != expected then return false
      if (output.stderr.splitOn "File exists").length > 1 then return false
      throw (IO.userError s!"reference update failed: {output.stderr}")
    try
      checkout repo pending
      IO.FS.removeFile path
    catch error =>
      throw (IO.userError s!"commit recorded; checkout is pending, retry the same request after resolving local file conflicts: {error}")
    return true

structure Loaded where
  head : String
  state : State

def nodePath (id : Nat) : String := if id == 0 then ".axiward" else s!".axiward/nodes/{id}"

def productPath (id : Nat) : String := if id == 0 then "product" else s!"{nodePath id}/product"

private def specificationPath (text : String) : IO String := do
  let json ← decode (Json.parse text)
  let path : String ← decode (json.getObjValAs? String "specificationPath")
  unless safePath path do throw (IO.userError "invalid frozen specification path")
  return path

def policySpecificationPath (repo : FilePath) (policy : String) : IO String := do
  specificationPath (← readBlobs repo #[s!"{policy}:acceptance.json"])[0]!

def verifyBindings (repo : FilePath) (head : String) (nodes : Array Node)
    (source : Option Candidate := none) : IO Unit := do
  -- One Git process resolves every binding against this immutable head. The
  -- expected object kind is checked too; a missing path never counts as a match.
  let mut bindings : Array (String × String × String × String) := #[]
  let manifests ← readBlobs repo (nodes.map (fun node => s!"{node.domain.scope.policy}:acceptance.json"))
  for (node, i) in nodes.toList.zipIdx do
    let s := node.domain
    let path := nodePath i
    let specificationPath ← specificationPath manifests[i]!
    bindings := bindings.push (s!"{path}/policy", "tree", s.scope.policy,
      s!"node {i}: policy tree differs from journal scope")
    bindings := bindings.push (s!"{path}/policy/{specificationPath}", "blob", s.scope.specification,
      s!"node {i}: specification differs from journal scope")
    if let some package := s.active then
      if let .checking candidate := package.phase then
        bindings := bindings.push (s!"{path}/candidate", "tree", candidate.tree,
          s!"node {i}: sealed candidate differs from journal")
    if let some publication := s.published then
      bindings := bindings.push (productPath i, "tree", publication.product,
        s!"node {i}: published product or receipt differs from journal")
      bindings := bindings.push (s!"{path}/receipt.json", "blob", publication.receipt,
        s!"node {i}: published product or receipt differs from journal")
    if let some route := node.route then
      bindings := bindings.push (s!"{path}/route", "tree", route.certificate,
        s!"node {i}: refinement certificate differs from journal")
    for (op, j) in s.workflow.operations.zipIdx do
      bindings := bindings.push (s!"{path}/operations/{j}/input", "tree", op.candidate.tree,
        "operation input differs from journal")
      if op.result.isSome then
        bindings := bindings.push (s!"{path}/operations/{j}/evidence", "tree", op.evidence,
          "observation differs from journal")
    for (serial, report) in s.workflow.reports do
      bindings := bindings.push (s!"{path}/reports/{serial}.md", "blob", report,
        "exploration report differs from journal")
  if let some candidate := source then
    bindings := bindings.push ("source", "tree", candidate.tree, "formal source differs from admission history")
  let input := String.intercalate "\n" (bindings.toList.map (fun b => s!"{head}:{b.1}")) ++ "\n"
  let output ← checked repo #["cat-file", "--batch-check=%(objectname) %(objecttype)"] (some input)
  let actual := output.splitOn "\n"
  unless actual.length == bindings.size do
    throw (IO.userError "Git returned an incomplete object binding response")
  for (value, (_, kind, oid, message)) in actual.zip bindings.toList do
    unless value.trimAscii.toString == s!"{oid} {kind}" do throw (IO.userError message)

def load (repo : FilePath) : IO Loaded := do
  checkRepository repo
  let head ← resolve repo "refs/heads/main"
  let journalText := (← readBlobs repo #[s!"{head}:.axiward/state.json"])[0]!
  let json ← decode (Json.parse journalText)
  let journal : Journal ← decode (fromJson? json)
  let state ← decode (restore journal)
  verifyBindings repo head state.nodes (sourceAt state.journal.entries state.journal.initialSource)
  return ⟨head, state⟩

def create (repo : FilePath) (scope : Scope) : IO Unit := do
  unless validRequirements scope.requirements do throw (IO.userError "invalid requirements")
  let state ← decode (restore { initial := scope })
  let stateBlob ← hashText repo (toJson state.journal).compress
  let ignore ← hashText repo "/.view/\n/.checks/\n/delivery/\n"
  let root ← tree repo none #[⟨".axiward/state.json", stateBlob⟩, ⟨".gitignore", ignore⟩]
    #[(".axiward/policy", scope.policy)]
  let commit ← commitTree repo root none "Axiward initialization\n"
  unless ← compareAndSwap repo none commit do throw (IO.userError "project already initialized")

/-- Attach management to an existing committed source/ tree. The original
    history and unrelated files stay intact; this records no verified result. -/
def adopt (repo : FilePath) (expectedHead : String) (scope : Scope) : IO String := do
  checkRepository repo
  synchronize repo
  unless objectId expectedHead && (← resolve repo "refs/heads/main") == expectedHead do
    throw (IO.userError "repository changed; review the current HEAD before adoption")
  let metadata ← call repo #["rev-parse", "--verify", s!"{expectedHead}:.axiward"]
  if metadata.exitCode == 0 || (← (repo / ".axiward").pathExists) then
    throw (IO.userError "adoption requires a repository without existing .axiward metadata")
  let source ← call repo #["rev-parse", "--verify", s!"{expectedHead}:source"]
  unless source.exitCode == 0 do
    throw (IO.userError "adoption requires a committed source/ directory")
  let source := source.stdout.trimAscii.toString
  unless (← checked repo #["cat-file", "-t", source]) == "tree" do
    throw (IO.userError "adoption requires source/ to be a committed directory")
  let state ← decode (restore { schema := 4, initial := scope, initialSource := some ⟨source⟩ })
  let stateBlob ← hashText repo (toJson state.journal).compress
  let oldIgnore ← call repo #["rev-parse", "--verify", s!"{expectedHead}:.gitignore"]
  let mut ignore ← if oldIgnore.exitCode == 0 then
      readBlob repo oldIgnore.stdout.trimAscii.toString else pure ""
  for entry in ["/.view/", "/.checks/", "/delivery/"] do
    unless (ignore.replace "\r\n" "\n" |>.splitOn "\n").contains entry do
      if !ignore.isEmpty && !ignore.endsWith "\n" then ignore := ignore ++ "\n"
      ignore := ignore ++ entry ++ "\n"
  let root ← tree repo (some expectedHead)
    #[⟨".axiward/state.json", stateBlob⟩, ⟨".gitignore", ← hashText repo ignore⟩]
    #[(".axiward/policy", scope.policy)]
  verifyBindings repo root state.nodes
  let commit ← commitTree repo root (some expectedHead) "Axiward adoption\n"
  unless ← compareAndSwap repo (some expectedHead) commit do
    throw (IO.userError "repository changed during adoption; review the current HEAD before retrying")
  return commit

def commitChange (repo : FilePath) (loaded : Loaded) (change : Change loaded.state) : IO Bool := do
  if !change.changed then return ← withCheckoutLock repo (pure true)
  let stateBlob ← hashText repo (toJson change.after.journal).compress
  let mut blobs : Array Blob := #[⟨".axiward/state.json", stateBlob⟩]
  let mut subtrees : Array (String × String) := #[]
  let source := sourceAt change.after.journal.entries change.after.journal.initialSource
  if source != sourceAt loaded.state.journal.entries loaded.state.journal.initialSource then
    if let some candidate := source then subtrees := subtrees.push ("source", candidate.tree)
  if let some entry := change.after.journal.entries.getLast? then
    let path := nodePath entry.request.node
    match entry.request.command with
    | .finish serial _ evidence | .finishRefinement serial _ evidence | .integrate serial _ evidence =>
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
def transactDetailed (repo : FilePath) (request : Request) (initial : Option Loaded := none) : IO Transaction := do
  let mut snapshot := initial
  for _ in [:8] do
    let loaded ← match snapshot with | some loaded => pure loaded | none => load repo
    let change ← decode ((step loaded.state request).mapError (fun e => s!"{repr e}"))
    if ← commitChange repo loaded change then return ⟨loaded, change⟩
    -- A losing CAS discards the request-local snapshot. Every retry restores
    -- and validates the new HEAD before evaluating the transition again.
    snapshot := none
  throw (IO.userError "repository remains busy; retry the same request ID")

def transact (repo : FilePath) (request : Request) (initial : Option Loaded := none) : IO Reply := do
  return (← transactDetailed repo request initial).change.reply

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
