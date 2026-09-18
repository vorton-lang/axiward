import Lean.Data.Json

namespace Axiward.Sandbox

open Lean System

def quote (value : String) : String := (toJson value).compress

def pathRule (path : FilePath) (access : String) : String :=
  quote (path.normalize.toString.replace "\\" "/") ++ " = " ++ quote access

def workRoot (repo : FilePath) : FilePath :=
  (repo.parent.getD repo) / (repo.fileName.getD "project" ++ ".checks")

def scratch (repo : FilePath) : IO FilePath := do
  let root := workRoot repo
  IO.FS.createDirAll root
  let path := root / s!"run-{← IO.monoNanosNow}-{← IO.rand 0 1000000000}"
  IO.FS.createDir path
  return path

/-- Candidate code runs with read-only inputs, writable build outputs, and no
    access to the canonical store outside this one materialized snapshot. -/
def runVerifier (repo snapshot toolRoot : FilePath) (arguments : Array String)
    (environment : Array (String × Option String)) : IO IO.Process.Output := do
  IO.FS.createDirAll (snapshot / ".lake")
  IO.FS.createDirAll (snapshot / ".tmp")
  unless ← (snapshot / "lake-manifest.json").pathExists do
    IO.FS.writeFile (snapshot / "lake-manifest.json")
      "{\"version\":\"1.2.0\",\"packagesDir\":\".lake/packages\",\"packages\":[],\"name\":\"axiward\",\"lakeDir\":\".lake\"}"
  unless ← (snapshot / "audit.json").pathExists do IO.FS.writeFile (snapshot / "audit.json") ""
  let rules := ["\":root\" = \"read\"", pathRule repo "deny", pathRule snapshot "read",
    pathRule (snapshot / ".lake") "write", pathRule (snapshot / ".tmp") "write",
    pathRule (snapshot / "lake-manifest.json") "write", pathRule (snapshot / "audit.json") "write"]
  let profile := "{ filesystem = { " ++ String.intercalate ", " rules ++ " }, network = { enabled = false } }"
  IO.Process.output {
    cmd := "codex"
    args := #["sandbox", "-P", "axiward_verifier", "-C", snapshot.toString,
      "-c", "permissions.axiward_verifier = " ++ profile,
      "-c", "windows.sandbox = \"elevated\"", "--",
      (toolRoot / "bin" / "lake.exe").toString] ++ arguments
    cwd := some snapshot
    env := environment ++ #[("TMP", some (snapshot / ".tmp").toString),
      ("TEMP", some (snapshot / ".tmp").toString)] }

end Axiward.Sandbox
