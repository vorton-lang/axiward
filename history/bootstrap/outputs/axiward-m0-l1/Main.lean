import Axiward.Queue

-- This small IO wrapper exercises the compiled library; it is not a proof oracle.
def main (args : List String) : IO UInt32 := do
  let capacityText :: values := args
    | IO.eprintln "Usage: fifo_demo CAPACITY [VALUE ...]"; return 2
  let some capacity := capacityText.toNat?
    | IO.eprintln "CAPACITY must be a natural number"; return 2
  let mut queue := Axiward.Queue.empty String capacity
  IO.println s!"created capacity={queue.capacity} length={queue.length}"
  for value in values do
    let (accepted, next) := queue.enqueue value
    queue := next
    IO.println s!"enqueue {value}: accepted={accepted} length={queue.length} capacity={queue.capacity}"
  let attempts := queue.length + 1
  for _ in [:attempts] do
    let (returned, next) := queue.dequeue
    queue := next
    match returned with
    | some value => IO.println s!"dequeue: value={value} length={queue.length} capacity={queue.capacity}"
    | none => IO.println s!"dequeue: empty length={queue.length} capacity={queue.capacity}"
  return 0
