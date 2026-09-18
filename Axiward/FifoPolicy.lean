import Axiward.Git

namespace Axiward.FifoPolicy

open Lean System

inductive Overflow where
  | reject
  | overwrite
  deriving Repr, BEq, DecidableEq, ToJson, FromJson

/-- Both roots are explicit, registered specifications. Other roots are refused. -/
def rootFiles (overflow : Overflow) : Array (String × String) := #[
  ("Axiward/Spec.lean", match overflow with
    | .reject => include_str "../examples/fifo/policy/Axiward/Spec.lean"
    | .overwrite => include_str "../examples/fifo/policy-overwrite/Axiward/Spec.lean"),
  ("Gate.lean", match overflow with
    | .reject => include_str "../examples/fifo/policy/Gate.lean"
    | .overwrite => include_str "../examples/fifo/policy-overwrite/Gate.lean"),
  ("Audit.lean", include_str "../examples/fifo/policy/Audit.lean"),
  ("Main.lean", include_str "../examples/fifo/policy/Main.lean"),
  ("lakefile.toml", include_str "../examples/fifo/policy/lakefile.toml"),
  ("lean-toolchain", include_str "../examples/fifo/policy/lean-toolchain")]

def normalizeText (text : String) : String := (text.replace "\r\n" "\n").trimAscii.toString

def validateRootText (overflow : Overflow) (path text : String) : IO Unit := do
  let some (_, expected) := (rootFiles overflow).find? (fun item => item.1 == path)
    | throw (IO.userError "unknown root policy file")
  unless normalizeText text == normalizeText expected do
    throw (IO.userError s!"unsupported root policy: {path}")

def validateRoot (directory : FilePath) : IO Overflow := do
  for overflow in [Overflow.reject, .overwrite] do
    let mut allMatch := true
    for (path, expected) in rootFiles overflow do
      if normalizeText (← IO.FS.readFile (directory / path)) != normalizeText expected then
        allMatch := false
    if allMatch then return overflow
  throw (IO.userError "unsupported root policy: use a registered FIFO specification")

def statements (overflow : Overflow) : Array String := #[
  "Axiward.Q0.Created n (Axiward.Queue.empty α n).capacity (Axiward.Queue.empty α n).items",
  "(∀ (q : Axiward.Queue α n) (x : α), Axiward.Q0.EnqueueRoom n q.items x (q.enqueue x).1 (q.enqueue x).2.items)",
  (match overflow with
   | .reject => "(∀ (q : Axiward.Queue α n) (x : α), Axiward.Q0.EnqueueFull n q.items (q.enqueue x).1 (q.enqueue x).2.items)"
   | .overwrite => "(∀ (q : Axiward.Queue α n) (x : α), Axiward.Q0.EnqueueFull n q.items x (q.enqueue x).1 (q.enqueue x).2.items)"),
  "(∀ q : Axiward.Queue α n, Axiward.Q0.DequeueSome q.items q.dequeue.1 q.dequeue.2.items)",
  "(∀ q : Axiward.Queue α n, Axiward.Q0.DequeueEmpty q.items q.dequeue.1 q.dequeue.2.items)",
  "(∀ q : Axiward.Queue α n, Axiward.Q0.Measured n q.capacity q.length q.items)"]

def terms : Array String := #["Axiward.created α n", "Axiward.enqueue_room", "Axiward.enqueue_full",
  "Axiward.dequeue_some", "Axiward.dequeue_empty", "Axiward.measured"]

def allClaims : List Nat := [0, 1, 2, 3, 4, 5]

def gate (overflow : Overflow) (claims : List Nat) : String :=
  let goal := claims.foldr (fun i rest => s!"{(statements overflow)[i]?.getD "False"} ∧\n  {rest}") "True"
  let proof := claims.foldr (fun i rest => s!"⟨{terms[i]?.getD "missing"}, {rest}⟩") "True.intro"
  "import Axiward.Spec\nimport Axiward.Queue\nimport Axiward.Proofs\n\nnamespace Gate\nuniverse u\n" ++
    s!"theorem accepted (α : Type u) (n : Nat) :\n  {goal} :=\n  {proof}\nend Gate\n"

def audit : String :=
  "import Gate\nimport Lean\nopen Lean Elab Command\nrun_cmd do\n" ++
  "  let env ← getEnv\n  let allowed := #[`propext, `Quot.sound, `Classical.choice]\n" ++
  "  for axiomName in (← collectAxioms `Gate.accepted) do\n" ++
  "    unless allowed.contains axiomName do throwError \"UNAPPROVED_AXIOM: {axiomName}\"\n" ++
  "  for (name, info) in env.constants do\n" ++
  "    let some index := env.getModuleIdxFor? name | continue\n" ++
  "    let moduleName := env.header.moduleNames[index.toNat]!\n" ++
  "    let isProof := moduleName == `Axiward.Proofs || moduleName.toString.startsWith \"Axiward.Parts.\"\n" ++
  "    unless moduleName == `Axiward.Queue || isProof do continue\n" ++
  "    if info.isUnsafe || (Compiler.getImplementedBy? env name).isSome || (getExternAttrData? env name).isSome then\n" ++
  "      throwError \"UNCHECKED_RUNTIME_REPLACEMENT: {name}\"\n" ++
  "    for axiomName in (← collectAxioms name) do\n" ++
  "      unless allowed.contains axiomName do throwError \"UNAPPROVED_AXIOM: {name}: {axiomName}\"\n" ++
  "  liftIO <| IO.FS.writeFile \"audit.json\" (Json.mkObj [(\"goal\", toJson \"Gate.accepted\")]).compress\n"

def readClaims (repo : FilePath) (policy : String) : IO (List Nat) := do
  let oid ← Git.resolve repo s!"{policy}:claims.json"
  let json ← Git.decode (Json.parse (← Git.readBlob repo oid))
  Git.decode (fromJson? json)

def readOverflow (repo : FilePath) (policy : String) : IO Overflow := do
  let oid ← Git.resolve repo s!"{policy}:overflow.json"
  let json ← Git.decode (Json.parse (← Git.readBlob repo oid))
  Git.decode (fromJson? json)

/-- Goal identity is based on the declarations actually used by that goal,
    not every unrelated declaration in the aggregate Spec.lean file. -/
def requirementRefs (repo : FilePath) (policy : String) (overflow : Overflow)
    (claims : List Nat) : IO (List Requirement) := do
  let source ← Git.readBlob repo (← Git.resolve repo s!"{policy}:Axiward/Spec.lean")
  let source := normalizeText source
  let names := #["Created", "EnqueueRoom", "EnqueueFull", "DequeueSome", "DequeueEmpty", "Measured"]
  let context := (source.splitOn "def Created").head!
  let contextHash ← Git.hashText repo context
  let dependencies ← #["controller-toolchain.json", "Audit.lean", "Main.lean", "lakefile.toml", "lean-toolchain"].mapM
    (fun path => Git.resolve repo s!"{policy}:{path}")
  let checkerHash ← Git.hashText repo (toJson dependencies).compress
  let mut refs : List Requirement := [⟨"fifo/context", contextHash⟩, ⟨"fifo/checker", checkerHash⟩]
  for claim in claims do
    let name := names[claim]?.getD "missing"
    let some suffix := (source.splitOn s!"def {name} ")[1]?
      | throw (IO.userError "missing requirement declaration")
    let body := ((suffix.splitOn "\n-- ").head!.splitOn "\nend Axiward.Q0").head!
    let definition := s!"def {name} {normalizeText body}\n{(statements overflow)[claim]?.getD "False"}"
    refs := refs ++ [⟨s!"fifo/{claim}", ← Git.hashText repo definition⟩]
  return refs

def selectClaims (repo : FilePath) (base : String) (claims : List Nat) : IO Scope := do
  unless !claims.isEmpty && claims.all (· < 6) && claims.eraseDups == claims do
    throw (IO.userError "invalid FIFO clause selection")
  let overflow ← readOverflow repo base
  let policy ← Git.tree repo (some base) #[
    ⟨"claims.json", ← Git.hashText repo (toJson claims).compress⟩,
    ⟨"Gate.lean", ← Git.hashText repo (gate overflow claims)⟩,
    ⟨"Audit.lean", ← Git.hashText repo audit⟩]
  return ⟨0, ← Git.resolve repo s!"{policy}:Axiward/Spec.lean", policy,
    ← requirementRefs repo policy overflow claims⟩

end Axiward.FifoPolicy
