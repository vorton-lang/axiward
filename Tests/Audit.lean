import Axiward
import Lean

open Lean Elab Command

run_cmd do
  let env ← getEnv
  let allowed := #[`propext, `Quot.sound, `Classical.choice]
  let modules := #[`Axiward.Model, `Axiward.Transition, `Axiward.Proofs, `Axiward.Workflow, `Axiward.Engine]
  let mut count : Nat := 0
  for (name, info) in env.constants do
    let some index := env.getModuleIdxFor? name | continue
    unless modules.contains env.header.moduleNames[index.toNat]! do continue
    count := count + 1
    if info.isUnsafe || (Compiler.getImplementedBy? env name).isSome ||
        (getExternAttrData? env name).isSome then
      throwError "Unverified kernel runtime replacement: {name}"
    for axiomName in (← collectAxioms name) do
      unless allowed.contains axiomName do
        throwError "Unapproved kernel axiom: {name}: {axiomName}"
  logInfo m!"Audited {count} kernel declarations; no sorry or extra axioms."

#print axioms Axiward.run_preserves
#print axioms Axiward.accepted_binding
#print axioms Axiward.graph_acyclic
#print axioms Axiward.composed_result_has_current_children
#print axioms Axiward.composition_requires_checked_output
#print axioms Axiward.published_requirements_current
#print axioms Axiward.normalize_preserves_packages
#print axioms Axiward.priorAdmission_iff
#print axioms Axiward.workflow_preserves
#print axioms Axiward.workflow_never_publishes
#print axioms Axiward.worker_cannot_answer
#print axioms Axiward.worker_cannot_forge_observation
#print axioms Axiward.observation_preserves_occupancy
#print axioms Axiward.late_observation_never_revives
#print axioms Axiward.cancel_preserves_obligations
#print axioms Axiward.pause_blocks_new_package
#print axioms Axiward.launch_requires_admitted_plan
#print axioms Axiward.complete_requires_proof_and_settlement
#print axioms Axiward.launch_within_budget
#print axioms Axiward.applicable_answer_binding
#print axioms Axiward.replay_preserves_state
#print axioms Axiward.stale_revision_rejected
#print axioms Axiward.revision_preserves_package
