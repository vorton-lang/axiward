import Axiward

open Axiward Lean System

private def require (condition : Bool) (message : String) : IO Unit :=
  unless condition do throw (IO.userError message)

private def expectRefusal (operation : IO α) (reason : String) : IO Unit := do
  let error ← try let _ ← operation; pure "" catch error => pure error.toString
  require ((error.splitOn reason).length > 1) s!"expected {reason}, received {error}"

private def rejectJournal (journal : Journal) : IO Unit :=
  match restore journal with
  | .error _ => pure ()
  | .ok _ => throw (IO.userError "invalid source/schema binding was restored")

private def schemaCase : IO Unit := do
  let scope : Scope := ⟨0, "specification", "policy", []⟩
  let legacy := Json.mkObj [("schema", toJson (3 : Nat)), ("initial", toJson scope),
    ("entries", toJson ([] : List Entry))]
  let old : Journal ← Git.decode (fromJson? legacy)
  let oldState ← Git.decode (restore old)
  require (old.initialSource.isNone && sourceAt oldState.journal.entries == none)
    "legacy schema 3 acquired an initial source"
  let source : Candidate := ⟨"unverified baseline"⟩
  let journal : Journal := { schema := 4, initial := scope, initialSource := some source }
  let decoded : Journal ← Git.decode (fromJson? (toJson journal))
  let state ← Git.decode (restore decoded)
  require (state.journal == journal && state.domain.published.isNone && !complete state &&
    state.journal.entries.isEmpty) "adoption manufactured an admission or closed the root"
  let acquired ← Git.decode ((step state ⟨"begin", .controller, .begin "worker" .execute, 0⟩).mapError reprStr)
  require (packageSource acquired.after.journal.entries 0 0 acquired.after.journal.initialSource == some source)
    "the first package lost its unverified merge base"
  let sealed ← Git.decode ((step acquired.after
    ⟨"submit", .worker "worker", .submit 0 ⟨"new unverified candidate"⟩, 0⟩).mapError reprStr)
  let ended ← Git.decode ((step sealed.after
    ⟨"unknown", .controller, .finish 0 (.unknown "fixture interruption") "evidence", 0⟩).mapError reprStr)
  require (sourceAt ended.after.journal.entries ended.after.journal.initialSource == some source &&
    ended.after.domain.published.isNone && (ended.after.journal.entries.flatMap admissions).isEmpty)
    "an unverified attempt changed the source or created historical reuse evidence"
  let recovered ← Git.decode (restore ended.after.journal)
  require (recovered.journal == ended.after.journal && toJson recovered.nodes == toJson ended.after.nodes)
    "schema 4 replay changed the baseline or package history"
  rejectJournal { journal with schema := 3 }
  rejectJournal { journal with initialSource := none }
  rejectJournal { journal with initialSource := some ⟨""⟩ }
  rejectJournal { journal with schema := 5 }

private def code : String := "def original : Nat := 1\n"
private def ignore : String := ".work/\ncustom-cache/\n"

/-- These files only exercise storage and protocol bindings. No test fixture
    verdict claims that an external product verifier accepted this source. -/
private def fixture (repo : FilePath) : IO (String × Scope × Candidate) := do
  unless repo.isAbsolute do throw (IO.userError "absolute fixture directory required")
  if ← repo.pathExists then throw (IO.userError "fixture requires a new directory")
  let result ← IO.Process.output {
    cmd := "git"
    args := #["init", "--object-format=sha1", "--initial-branch=main", repo.toString]
    env := Git.cleanEnv }
  require (result.exitCode == 0) result.stderr
  Git.checkRepository repo
  let spec ← Git.hashText repo "storage fixture only; not a product proof\n"
  let manifest : Policy.Manifest := {
    schema := 1, name := "storage-fixture", version := "1", specificationPath := "Specification.lean"
    files := #["Specification.lean", "lakefile.toml", "lean-toolchain"]
    specificationModules := #["Specification"], candidateFiles := #[⟨"Code.lean", "Code.lean"⟩]
    buildTargets := #["Code"], proofModules := #["Code"], artifacts := #[".lake/build/lib/lean/Code.olean"]
    claims := #[⟨"fixture", "Specification.Required", #[], "Code.proof"⟩] }
  let policy ← Git.tree repo none #[⟨"Specification.lean", spec⟩,
    ⟨"claims.json", ← Git.hashText repo "[0]"⟩, ⟨"Goal.md", spec⟩,
    ⟨"acceptance.json", ← Git.hashText repo (toJson manifest).compress⟩,
    ⟨"lakefile.toml", spec⟩, ⟨"lean-toolchain", spec⟩]
  let source ← Git.tree repo none #[⟨"Code.lean", ← Git.hashText repo code⟩]
  let root ← Git.tree repo none #[⟨"README.md", ← Git.hashText repo "ordinary project history\n"⟩,
    ⟨".gitignore", ← Git.hashText repo ignore⟩] #[("source", source)]
  let head ← Git.commitTree repo root none "ordinary project baseline\n"
  require (← Git.compareAndSwap repo none head) "initial SHA-1 commit failed"
  return (head, ⟨0, spec, policy, []⟩, ⟨source⟩)

private def storageCase (repo : FilePath) : IO Unit := do
  let (before, scope, source) ← fixture repo
  let draft := "uncommitted local draft\n"
  IO.FS.writeFile (repo / "source" / "Code.lean") draft
  let head ← Git.adopt repo before scope
  require (head.length == 40 && (← Git.resolve repo "HEAD^") == before &&
    (← Git.resolve repo "HEAD:source") == source.tree &&
    (← Git.resolve repo "HEAD:README.md") == (← Git.resolve repo s!"{before}:README.md"))
    "adoption changed the existing history or source"
  require ((← IO.FS.readFile (repo / "source" / "Code.lean")) == draft)
    "adoption overwrote or consumed an unrelated local draft"
  let savedIgnore ← IO.FS.readFile (repo / ".gitignore")
  require (savedIgnore.startsWith ignore && ["/.view/", "/.checks/", "/delivery/"].all
    (fun entry => (savedIgnore.splitOn "\n").contains entry)) "adoption replaced existing ignore rules"
  let adopted ← Git.load repo
  require (adopted.state.journal.schema == 4 && adopted.state.journal.initialSource == some source &&
    adopted.state.domain.published.isNone && !complete adopted.state && adopted.state.journal.entries.isEmpty)
    "initial source was not recorded as an unverified baseline"
  let _ ← Git.transact repo ⟨"acquire", .controller, .begin "worker" .execute, 0⟩
  let allocated ← Git.load repo
  let view ← Interface.exportViewLoaded repo (repo / ".view" / "reader") allocated "worker" 0 0 false
  require (view.getObjValD "sourceBase" == toJson (some source))
    "package status omitted the adopted source baseline"
  let material ← Interface.readResource repo "worker" 0 0 "node/0/source"
  let content : String ← Git.decode (material.getObjValAs? String "content")
  require ((content.splitOn "def original").length > 1 &&
    (content.splitOn "uncommitted local draft").length == 1)
    "fixed source resources read a local draft instead of the adopted snapshot"
  IO.FS.writeFile (repo / "source" / "Code.lean") code
  let _ ← Git.checked repo #["update-index", "--refresh"]
  let changedSource ← Git.tree repo none #[⟨"Code.lean", ← Git.hashText repo "changed without an admission\n"⟩]
  let changed ← Git.tree repo (some allocated.head) #[] #[("source", changedSource)]
  let corrupted ← Git.commitTree repo changed (some allocated.head) "source binding corruption fixture\n"
  require (← Git.compareAndSwap repo (some allocated.head) corrupted) "corruption fixture failed"
  expectRefusal (Git.load repo) "formal source differs from admission history"

private def refusalCase (repo : FilePath) : IO Unit := do
  let (before, scope, source) ← fixture repo
  let newerTree ← Git.tree repo (some before) #[⟨"extra.txt", ← Git.hashText repo "later user commit\n"⟩]
  let newer ← Git.commitTree repo newerTree (some before) "ordinary later commit\n"
  require (← Git.compareAndSwap repo (some before) newer) "later commit fixture failed"
  expectRefusal (Git.adopt repo before scope) "repository changed"
  require ((← Git.resolve repo "HEAD") == newer && !(← (repo / ".axiward").pathExists))
    "stale adoption changed the project"
  let dirty := "local ignore draft must survive\n"
  IO.FS.writeFile (repo / ".gitignore") dirty
  expectRefusal (Git.adopt repo newer scope) ".gitignore"
  require ((← Git.resolve repo "HEAD") == newer &&
    (← IO.FS.readFile (repo / ".gitignore")) == dirty &&
    !(← (repo / ".axiward").pathExists) &&
    !(← (repo / ".git" / "axiward-checkout.json").pathExists) &&
    (← Git.resolve repo "HEAD:source") == source.tree)
    "a colliding draft was overwritten or adoption partially committed"
  IO.FS.writeFile (repo / ".gitignore") ignore
  IO.FS.createDirAll (repo / ".axiward")
  IO.FS.writeFile (repo / ".axiward" / "local.txt") "untracked metadata draft\n"
  expectRefusal (Git.adopt repo newer scope) "existing .axiward metadata"
  require ((← Git.resolve repo "HEAD") == newer &&
    (← IO.FS.readFile (repo / ".axiward" / "local.txt")) == "untracked metadata draft\n")
    "adoption overwrote existing metadata"

def main (args : List String) : IO Unit := do
  match args with
  | ["schema"] => schemaCase
  | ["storage", directory] => storageCase directory
  | ["refusal", directory] => refusalCase directory
  | _ => throw (IO.userError "Adoption.lean schema | storage/refusal <new-absolute-fixture-directory>")
  IO.println "PASS: adoption boundary (storage/protocol only; no product verification)"
