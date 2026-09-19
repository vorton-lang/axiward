import Axiward.Proofs

-- The executable calls the exact subject named by acceptance.json.
def main (args : List String) : IO UInt32 := do
  let capacityText :: values := args
    | IO.eprintln "Usage: fifo_demo CAPACITY [VALUE ...]"; return 2
  let some capacity := capacityText.toNat?
    | IO.eprintln "CAPACITY must be a natural number"; return 2
  let model := Axiward.subject
  let mut queue := model.empty String capacity
  IO.println s!"created capacity={model.capacity queue} length={model.length queue}"
  for value in values do
    let (accepted, next) := model.enqueue queue value
    queue := next
    IO.println s!"enqueue {value}: accepted={accepted} length={model.length queue} capacity={model.capacity queue}"
  let attempts := model.length queue + 1
  for _ in [:attempts] do
    let (returned, next) := model.dequeue queue
    queue := next
    match returned with
    | some value => IO.println s!"dequeue: value={value} length={model.length queue} capacity={model.capacity queue}"
    | none => IO.println s!"dequeue: empty length={model.length queue} capacity={model.capacity queue}"
  return 0
