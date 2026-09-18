import Gate
import Lean
open Lean Elab Command
run_cmd do
  let env ← getEnv
  let allowed := #[`propext, `Quot.sound, `Classical.choice]
  for axiomName in (← collectAxioms `Gate.accepted) do
    unless allowed.contains axiomName do throwError "UNAPPROVED_AXIOM: {axiomName}"
  for (name, info) in env.constants do
    let some index := env.getModuleIdxFor? name | continue
    unless env.header.moduleNames[index.toNat]! == `Refinement do continue
    if info.isUnsafe || (Compiler.getImplementedBy? env name).isSome || (getExternAttrData? env name).isSome then
      throwError "UNCHECKED_RUNTIME_REPLACEMENT: {name}"
    for axiomName in (← collectAxioms name) do
      unless allowed.contains axiomName do throwError "UNAPPROVED_AXIOM: {name}: {axiomName}"
