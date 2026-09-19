import Implementation

def main (args : List String) : IO UInt32 := do
  let [input] := args | IO.eprintln "Usage: successor_demo NUMBER"; return 2
  let some value := input.toNat? | IO.eprintln "NUMBER must be a natural number"; return 2
  IO.println (Implementation.next value)
  return 0
