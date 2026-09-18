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
    let moduleName := env.header.moduleNames[index.toNat]!
    let isProof := moduleName == `Axiward.Proofs || moduleName.toString.startsWith "Axiward.Parts."
    unless moduleName == `Axiward.Queue || isProof do continue
    if info.isUnsafe || (Compiler.getImplementedBy? env name).isSome || (getExternAttrData? env name).isSome then
      throwError "UNCHECKED_RUNTIME_REPLACEMENT: {name}"
    for axiomName in (← collectAxioms name) do
      unless allowed.contains axiomName do throwError "UNAPPROVED_AXIOM: {name}: {axiomName}"
  liftIO <| IO.FS.writeFile "audit.json" (Json.mkObj [("goal", toJson "Gate.accepted")]).compress
