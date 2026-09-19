import Lean.Data.Json

namespace Axiward.Sandbox

open Lean System

def quote (value : String) : String := (toJson value).compress

private def codexStartError (error : IO.Error) : IO.Error :=
  IO.userError s!"Cannot start Codex CLI (codex) from this process. Run codex --version in the same terminal and add the directory containing codex.exe to this session's PATH. Original error: {error}"

/-- Availability only: this does not start a sandbox, model turn or verifier. -/
def requireCodex : IO Unit := do
  let result ← try IO.Process.output { cmd := "codex", args := #["--version"] }
    catch error => throw (codexStartError error)
  unless result.exitCode == 0 do
    throw (IO.userError s!"Codex CLI preflight failed (exit {result.exitCode}): {result.stdout}{result.stderr}")

def pathRule (path : FilePath) (access : String) : String :=
  quote (path.normalize.toString.replace "\\" "/") ++ " = " ++ quote access

def workRoot (repo : FilePath) : FilePath :=
  repo / ".checks"

def scratch (repo : FilePath) : IO FilePath := do
  let repo ← IO.FS.realPath repo
  let root := workRoot repo
  IO.FS.createDirAll root
  unless (← IO.FS.realPath root).normalize == root.normalize do
    throw (IO.userError "checks directory must not redirect outside its project path")
  let path := root / s!"run-{← IO.monoNanosNow}-{← IO.rand 0 1000000000}"
  IO.FS.createDir path
  return path

private def powershellLiteral (value : String) : String :=
  "'" ++ value.replace "'" "''" ++ "'"

/-- Windows argv quoting for ProcessStartInfo.Arguments (not shell quoting). -/
private def windowsArgument (value : String) : String := Id.run do
  let mut result := "\""
  let mut slashes := 0
  for c in value.toList do
    if c == '\\' then slashes := slashes + 1 else
      let count := if c == '"' then 2 * slashes + 1 else slashes
      result := result ++ String.ofList (List.replicate count '\\') ++ String.singleton c
      slashes := 0
  return result ++ String.ofList (List.replicate (2 * slashes) '\\') ++ "\""

/-- Only a newly created empty snapshot receives an inheritance boundary. The
    controller grants the existing Codex sandbox identity read/execute access
    there. The native harness retains the canonical repository deny ACL and
    grants write access only to the declared build outputs. -/
def createSnapshot (repo work : FilePath) : IO FilePath := do
  let repo ← IO.FS.realPath repo
  unless work.parent == some (workRoot repo) && (← IO.FS.realPath work).normalize == work.normalize do
    throw (IO.userError "snapshot workspace must be a direct project checks directory")
  let snapshot := work / "snapshot"
  if ← snapshot.pathExists then throw (IO.userError "snapshot requires a new empty directory")
  IO.FS.createDir snapshot
  unless (← IO.FS.realPath snapshot).normalize == snapshot.normalize do
    throw (IO.userError "snapshot must not be a redirected directory")
  let some systemRoot ← IO.getEnv "SystemRoot"
    | throw (IO.userError "cannot locate Windows PowerShell")
  let powershell := FilePath.mk systemRoot / "System32/WindowsPowerShell/v1.0/powershell.exe"
  let command := "$ErrorActionPreference = 'Stop'\n$directory = Get-Item -LiteralPath " ++
    powershellLiteral snapshot.toString ++ " -Force\n" ++
    "if (($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $directory.GetFileSystemInfos().Length -ne 0) { throw 'snapshot must be empty and not redirected' }\n" ++
    "try { $reader = [Security.Principal.NTAccount]::new($env:COMPUTERNAME, 'CodexSandboxUsers').Translate([Security.Principal.SecurityIdentifier]) } catch { throw 'Codex native sandbox group CodexSandboxUsers is not initialized; no account was created' }\n" ++
    "$owner = [Security.Principal.WindowsIdentity]::GetCurrent().User\n" ++
    "$acl = [Security.AccessControl.DirectorySecurity]::new()\n$acl.SetOwner($owner)\n$acl.SetAccessRuleProtection($true, $false)\n" ++
    "foreach ($identity in @($owner, [Security.Principal.SecurityIdentifier]::new('S-1-5-18'), [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))) {\n" ++
    "  $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($identity, 'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow'))\n}\n" ++
    "$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($reader, 'ReadAndExecute', 'ContainerInherit, ObjectInherit', 'None', 'Allow'))\n" ++
    "$directory.SetAccessControl($acl)\n"
  let result ← IO.Process.output {
    cmd := powershell.toString
    args := #["-NoLogo", "-NoProfile", "-NonInteractive", "-Command", command] }
  unless result.exitCode == 0 do
    throw (IO.userError s!"cannot prepare empty snapshot ACL: {result.stderr}")
  return snapshot

/-- Codex shares SID registration across projects in one user environment.
    Hold this gate until its restricted child has started, not until work ends. -/
private def nativeOutput (args : IO.Process.SpawnArgs) : IO IO.Process.Output := do
  requireCodex
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
      let child ← try IO.Process.spawn { args with stdin := .null, stdout := .piped, stderr := .piped }
        catch error => throw (codexStartError error)
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
    "try {\n$start = [Diagnostics.ProcessStartInfo]::new()\n$start.FileName = " ++
    powershellLiteral (toolRoot / "bin" / "lake.exe").toString ++ "\n$start.WorkingDirectory = " ++
    powershellLiteral snapshot.toString ++ "\n$start.Arguments = " ++
    powershellLiteral (String.intercalate " " (arguments.toList.map windowsArgument)) ++
    "\n$start.UseShellExecute = $false\n$start.CreateNoWindow = $true\n" ++
    "$start.RedirectStandardOutput = $true\n$start.RedirectStandardError = $true\n" ++
    "$start.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)\n$start.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)\n" ++
    "$process = [Diagnostics.Process]::Start($start)\n" ++
    "$stdout = $process.StandardOutput.ReadToEndAsync()\n$stderr = $process.StandardError.ReadToEndAsync()\n" ++
    "$process.WaitForExit()\n[Console]::Out.Write($stdout.GetAwaiter().GetResult())\n" ++
    "[Console]::Error.Write($stderr.GetAwaiter().GetResult())\nexit $process.ExitCode\n" ++
    "} catch {\n[Console]::Error.WriteLine($_.Exception.Message)\nexit 1\n}\n"
  -- Preserve per-project verifier coordination; the shared gate above only
  -- serializes startup, so distinct projects can execute their checks together.
  let gate ← IO.FS.Handle.mk (repo / ".git" / "axiward-verifier.lock") .append
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
