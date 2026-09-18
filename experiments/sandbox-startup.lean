import Axiward.Sandbox
import Axiward.Verifier

open Lean System

def main (args : List String) : IO UInt32 := do
  let [repo, snapshot, toolchain, python, probe] := args
    | throw (IO.userError "sandbox-startup <repo> <snapshot> <toolchain> <python> <probe>")
  let output ← Axiward.Sandbox.runVerifier repo snapshot toolchain
    #["env", python, "-I", "-S", probe, "--child"] Axiward.Verifier.buildEnvironment
  (← IO.getStdout).putStr output.stdout
  (← IO.getStderr).putStr output.stderr
  return output.exitCode
