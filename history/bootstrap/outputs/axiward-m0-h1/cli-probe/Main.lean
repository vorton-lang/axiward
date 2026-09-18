import Init

-- A fixed-path access probe for synthetic files only, not the product CLI.
def laboratory : System.FilePath :=
  "LEGACY_WORKSPACE/work/m0-h1/lab"

def main (args : List String) : IO UInt32 := do
  try
    match args with
    | ["status"] =>
      let identity ← IO.Process.output { cmd := "C:/Windows/System32/whoami.exe" }
      IO.println s!"identity={identity.stdout.trimAscii.toString}"
      IO.println (← IO.FS.readFile (laboratory / "repository" / "state.txt"))
      return 0
    | ["submit"] =>
      let candidate ← IO.FS.readFile (laboratory / "view" / "candidate.txt")
      if candidate != "candidate=1" then
        IO.eprintln "unexpected synthetic candidate"
        return 2
      IO.FS.writeFile (laboratory / "repository" / "accepted.txt") candidate
      IO.println "synthetic candidate received"
      return 0
    | ["decide"] =>
      IO.FS.writeFile (laboratory / "repository" / "decision.txt") "synthetic decision"
      IO.println "synthetic decision recorded"
      return 0
    | _ =>
      IO.eprintln "only exact status, submit, or decide commands are accepted"
      return 2
  catch error =>
    IO.eprintln s!"probe IO failure: {error}"
    return 1
