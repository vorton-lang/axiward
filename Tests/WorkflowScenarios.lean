import Axiward

open Axiward

def ensure (condition : Bool) (message : String) : IO Unit :=
  unless condition do throw (IO.userError message)

def advance (s : State) (actor : Actor) (command : Command) (node : Nat := 0) : IO State := do
  let request : Request := ⟨s!"event-{s.journal.entries.length}", actor, command, node⟩
  return (← Git.decode ((step s request).mapError (fun e => s!"{repr e}"))).after

def handoffCases : IO Unit := do
  -- Checked refinement is a protocol fixture for handoff projection, not
  -- evidence that an external Lean verifier accepted these synthetic results.
  let a : Requirement := ⟨"a", "one"⟩
  let b : Requirement := ⟨"b", "one"⟩
  let root : Scope := ⟨0, "spec", "policy", [a, b]⟩
  let childA : Scope := ⟨0, "spec-a", "policy-a", [a]⟩
  let childB : Scope := ⟨0, "spec-b", "policy-b", [b]⟩
  let question : Question := ⟨"Which approach?", "this exact goal", [⟨"list", "list"⟩]⟩
  let ask (s : State) (node serial : Nat) : IO State := do
    let s ← advance s .controller (.begin "original" .requestDecision) node
    let s ← advance s (.worker "original") (.submit serial ⟨"question"⟩) node
    let s ← advance s .controller (.workflow (.ask serial question)) node
    advance s .user (.workflow (.answer serial "list" "scoped preference")) node
  let mut s ← Git.decode (restore { initial := root })
  s ← ask s 0 0
  s ← advance s .controller (.begin "planner" .refine)
  s ← advance s (.worker "planner") (.submit 1 ⟨"plan"⟩)
  s ← advance s .controller (.finishRefinement 1
    (.passed ⟨root, ⟨"plan"⟩, [.fresh childA, .fresh childB], "certificate", none⟩) "fixture")
  s ← ask s 1 0
  s ← ask s 2 0
  s ← advance s .controller (.begin "fresh" .execute) 1
  let snapshot := s
  let before := Interface.handoff ⟨"before", s⟩ (some (1, snapshot, "input"))
  let decisions : List Lean.Json ← Git.decode (before.getObjValAs? _ "decisions")
  ensure (decisions.map (fun q => (q.getObjValAs? Nat "node").toOption) == [some 1, some 0])
    "handoff omitted the ancestor or included an unrelated sibling decision"
  ensure (decisions.all (fun q => (q.getObjValAs? Bool "applicableNow").toOption == some true))
    "current scoped preferences were not supplied to the fresh worker"
  s ← advance s .user (.revise root ⟨0, "spec-new", "policy-new", [⟨"a", "two"⟩, b]⟩)
  let after := Interface.handoff ⟨"after", s⟩ (some (1, snapshot, "input"))
  let decisions : List Lean.Json ← Git.decode (after.getObjValAs? _ "decisions")
  ensure (decisions.length == 1 && decisions.all (fun q =>
    (q.getObjValAs? Bool "recordedApplicable").toOption == some true &&
    (q.getObjValAs? Bool "applicableNow").toOption == some false))
    "unchanged child scope bypassed a changed root requirement dependency"
  let unaffected := Interface.handoff ⟨"after", s⟩ (some (2, snapshot, "input"))
  let decisions : List Lean.Json ← Git.decode (unaffected.getObjValAs? _ "decisions")
  ensure (decisions.length == 1 && decisions.all (fun q =>
    (q.getObjValAs? Bool "applicableNow").toOption == some true))
    "unaffected requirement dependency lost its applicable preference"

def unaffectedPackageCase : IO Unit := do
  -- Safety theorems prevent stale publication but do not establish this progress
  -- property: an independent package can still finish after a root revision.
  let a : Requirement := ⟨"a", "one"⟩
  let b : Requirement := ⟨"b", "one"⟩
  let root : Scope := ⟨0, "root", "root-policy", [a, b]⟩
  let child : Scope := ⟨0, "b", "b-policy", [b]⟩
  let mut s ← Git.decode (restore { initial := root })
  s ← advance s .controller (.begin "planner" .refine)
  s ← advance s (.worker "planner") (.submit 0 ⟨"plan"⟩)
  s ← advance s .controller (.finishRefinement 0
    (.passed ⟨root, ⟨"plan"⟩, [.fresh child], "fixture", none⟩) "fixture")
  s ← advance s .controller (.begin "worker" .execute) 1
  s ← advance s (.worker "worker") (.submit 0 ⟨"candidate"⟩) 1
  s ← advance s .user (.revise root ⟨0, "root-two", "policy-two", [⟨"a", "two"⟩, b]⟩)
  s ← advance s .controller (.finish 0 (.passed ⟨child, ⟨"candidate"⟩, "product", "receipt"⟩) "fixture") 1
  ensure (s.nodes[1]?.any (fun node => node.domain.published.isSome))
    "an unrelated root requirement change blocked the unchanged package"

/-- This checks serialization/recovery of a mixed journal, not the already
    proved transition safety properties. -/
def main : IO Unit := do
  handoffCases
  unaffectedPackageCase
  let scope : Scope := ⟨0, "spec", "policy", [⟨"root", "v1"⟩]⟩
  let mut s ← Git.decode (restore { initial := scope })
  s ← advance s .controller (.begin "worker" .explore)
  s ← advance s (.worker "worker") (.submit 0 ⟨"plan"⟩)
  s ← advance s .controller (.workflow (.prepare 0 ⟨"compare algorithms", 1, "one trial"⟩))
  s ← advance s .controller (.workflow (.launch 0 "op" ⟨"candidate"⟩))
  s ← advance s (.worker "worker") (.cancel 0 "runner stopped")
  s ← advance s .controller (.workflow (.observe "op" (.unknown "late result") "evidence"))
  s ← advance s .controller (.begin "worker" .requestDecision)
  s ← advance s (.worker "worker") (.submit 1 ⟨"question"⟩)
  let question : Question := ⟨"Which representation?", "current root", [⟨"list", "immutable list"⟩]⟩
  s ← advance s .controller (.workflow (.ask 1 question))
  s ← advance s .user (.workflow (.answer 1 "list" "preference"))
  s ← advance s (.worker "worker") (.workflow (.acknowledge 1))
  let journal : Journal ← Git.decode (Lean.fromJson? (Lean.toJson s.journal))
  let recovered ← Git.decode (restore journal)
  ensure (recovered.domain == s.domain && recovered.journal == s.journal)
    "mixed workflow and legacy acknowledgement journal did not decode and replay exactly"
  IO.println "PASS: scoped handoff, unaffected-package progress and mixed journal serialization/recovery"
