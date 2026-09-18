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

private def powershellLiteral (value : String) : String :=
  "'" ++ value.replace "'" "''" ++ "'"

/-- Codex shares SID registration across projects in one user environment.
    Hold this gate until its restricted child has started, not until work ends. -/
private def nativeOutput (args : IO.Process.SpawnArgs) : IO IO.Process.Output := do
  let codexHome ← match ← IO.getEnv "CODEX_HOME" with
    | some value => pure (FilePath.mk value)
    | none => do
      let some profile ← IO.getEnv "USERPROFILE"
        | throw (IO.userError "cannot locate the Codex sandbox environment")
      pure (FilePath.mk profile / ".codex")
  unless codexHome.isAbsolute do throw (IO.userError "Codex home must be absolute")
  IO.FS.createDirAll codexHome
  let gate ← IO.FS.Handle.mk (codexHome / "axiward-sandbox-start.lock") .append
  gate.lock
  let (child, stderr) ← try
      let child ← IO.Process.spawn { args with stdin := .null, stdout := .piped, stderr := .piped }
      let stderr ← IO.asTask child.stderr.readToEnd Task.Priority.dedicated
      let first ← child.stdout.getLine
      unless first.trimAscii.toString == "AXIWARD_SANDBOX_STARTED" do
        let rest ← child.stdout.readToEnd
        let code ← child.wait
        let error ← IO.ofExcept stderr.get
        throw (IO.userError s!"native sandbox did not signal readiness (exit {code}): {first}{rest}{error}")
      pure (child, stderr)
    finally gate.unlock
  let stdout ← child.stdout.readToEnd
  let exitCode ← child.wait
  let stderr ← IO.ofExcept stderr.get
  return { exitCode, stdout, stderr }

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
  let profileName := "axiward_" ++ ((snapshot.parent.getD snapshot).fileName.getD "check").replace "-" "_"
  let some systemRoot ← IO.getEnv "SystemRoot"
    | throw (IO.userError "cannot locate Windows PowerShell")
  let powershell := FilePath.mk systemRoot / "System32" / "WindowsPowerShell" / "v1.0" / "powershell.exe"
  let command := "[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)\n" ++
    "[Console]::Out.WriteLine('AXIWARD_SANDBOX_STARTED')\n[Console]::Out.Flush()\n" ++
    "try {\n& " ++ powershellLiteral (toolRoot / "bin" / "lake.exe").toString ++ " " ++
    String.intercalate " " (arguments.toList.map powershellLiteral) ++
    "\nexit $LASTEXITCODE\n} catch {\n[Console]::Error.WriteLine($_.Exception.Message)\nexit 1\n}\n"
  -- Preserve per-project verifier coordination; the shared gate above only
  -- serializes startup, so distinct projects can execute their checks together.
  let gate ← IO.FS.Handle.mk (repo / "axiward-verifier.lock") .append
  gate.lock
  try
    nativeOutput {
      cmd := "codex"
      args := #["sandbox", "-P", profileName, "-C", snapshot.toString,
        "-c", "permissions." ++ profileName ++ " = " ++ profile,
        "-c", "windows.sandbox = \"elevated\"", "--",
        powershell.toString, "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", command]
      cwd := some snapshot
      env := environment ++ #[("TMP", some (snapshot / ".tmp").toString),
        ("TEMP", some (snapshot / ".tmp").toString)] }
  finally gate.unlock

end Axiward.Sandbox
