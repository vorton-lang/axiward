import Axiward.Git

namespace Axiward.Diagnostics

open Lean System

private def severity (line : String) : Option String :=
  ["error", "warning", "info"].find? (fun level => line.startsWith (level ++ ": "))

private def location (line level : String) : Option Json := do
  let header := (line.drop (level.length + 2)).toString
  let [path, rest] := header.splitOn ".lean:" | none
  let parts := rest.splitOn ":"
  let row ← parts[0]?.bind String.toNat?
  let column ← parts[1]?.bind String.toNat?
  if row == 0 || column == 0 then none else
    some (Json.mkObj [("file", toJson (path ++ ".lean")),
      ("line", toJson row), ("column", toJson column)])

private def buildBoundary (line : String) : Bool :=
  ["✔ [", "✖ [", "⚠ [", "ℹ [", "trace: ", "Some required targets logged failures:",
    "Build completed"].any (fun marker => line.startsWith marker)

/-- These are verbatim message blocks from the retained tool output, not inferred
    goals, counterexamples or root causes. The enclosing stage keeps all output. -/
def messages (stream text : String) : Array Json := Id.run do
  let mut result := #[]
  let mut current : Option (String × List String) := none
  let finish (value : Option (String × List String)) : Array Json :=
    match value with
    | none => #[]
    | some (level, lines) => #[Json.mkObj [
        ("stream", toJson stream), ("severity", toJson level),
        ("location", toJson (location (lines.headD "") level)),
        ("raw", toJson (String.intercalate "\n" lines))]]
  for line in text.splitOn "\n" do
    if let some level := severity line then
      result := result ++ finish current
      current := some (level, [line])
    else if buildBoundary line then
      result := result ++ finish current
      current := none
    else if let some (level, lines) := current then
      current := some (level, lines ++ [line])
  return result ++ finish current

private structure Item where
  name : String
  kind : String
  oid : String

private def items (repo : FilePath) (tree : String) : IO (List Item) := do
  let listing ← Git.checked repo #["ls-tree", "-z", tree]
  return (listing.splitOn "\x00").filterMap fun entry => do
    let [metadata, name] := entry.splitOn "\t" | none
    let [_, kind, oid] := metadata.splitOn " " | none
    return ⟨name, kind, oid⟩

private def record (repo : FilePath) (pathPrefix : String) (item : Item) : IO Json := do
  let raw ← Git.readBlob repo item.oid
  let body := match Json.parse raw with
    | .ok value => [("record", value)]
    | .error reason => [("raw", toJson raw), ("parseError", toJson reason)]
  return Json.mkObj ([("file", toJson (pathPrefix ++ item.name)), ("blob", toJson item.oid)] ++ body)

private partial def collect (repo : FilePath) (tree pathPrefix : String) :
    IO (Array Json × Array Json) := do
  let contents ← items repo tree
  let get (name : String) : IO (Option Json) := do
    match contents.find? (fun item => item.name == name && item.kind == "blob") with
    | none => return none
    | some item => return some (← record repo pathPrefix item)
  let input ← get "input.json"
  let error ← get "error.json"
  let mut stages := #[]
  for name in ["01-build.json", "02-audit.json", "03-replay.json"] do
    let some retained ← get name | continue
    let body := (retained.getObjVal? "record").toOption
    if body.any (fun value => (value.getObjValAs? Nat "exitCode").toOption == some 0) then continue
    let output (key : String) : String :=
      body.bind (fun value => (value.getObjValAs? String key).toOption) |>.getD ""
    let diagnostics := messages "stdout" (output "stdout") ++ messages "stderr" (output "stderr")
    stages := stages.push (retained.setObjVal! "messages" (toJson diagnostics))
  let mut checks := if input.isSome || error.isSome || !stages.isEmpty then #[Json.mkObj [
    ("prefix", toJson pathPrefix), ("input", toJson input),
    ("stages", toJson stages), ("error", toJson error)]] else #[]
  let mut merges := (← get "merge.json").toArray
  -- These are the existing controller wrappers. Product and candidate trees are
  -- deliberately not searched; input.json identifies the actual checked source.
  for item in contents do
    if item.kind == "tree" && ["verification", "merge", "check", "verifier"].contains item.name then
      let (nestedChecks, nestedMerges) ← collect repo item.oid (pathPrefix ++ item.name ++ "/")
      checks := checks ++ nestedChecks
      merges := merges ++ nestedMerges
  return (checks, merges)

/-- Derive diagnostics only from immutable retained evidence. The caller must
    authorize sourceResource before calling; this is not an arbitrary-object
    worker API. No current HEAD, mutable check directory or new check is used. -/
def read (repo : FilePath) (evidenceTree sourceResource : String) : IO Json := do
  unless Git.objectId evidenceTree do throw (IO.userError "invalid evidence tree")
  let (checks, merges) ← collect repo evidenceTree ""
  return Json.mkObj [("evidenceTree", toJson evidenceTree), ("sourceResource", toJson sourceResource),
    ("checks", toJson checks), ("merges", toJson merges)]

end Axiward.Diagnostics
