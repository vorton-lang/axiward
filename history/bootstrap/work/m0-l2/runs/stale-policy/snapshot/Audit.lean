import Gate
import Lean

open Lean Elab Command

-- Inspect the compiled environment, rather than searching the candidate's text.
run_cmd do
  let env ← getEnv
  let allowed := #[`propext, `Quot.sound, `Classical.choice]
  let rootAxioms ← collectAxioms `Gate.accepted
  for axiomName in rootAxioms do
    unless allowed.contains axiomName do
      throwError "UNAPPROVED_AXIOM: {axiomName}"
  let mut checked := 0
  for (name, info) in env.constants do
    let some index := env.getModuleIdxFor? name | continue
    let moduleName := env.header.moduleNames[index.toNat]!
    unless moduleName == `Axiward.Queue || moduleName == `Axiward.Proofs do continue
    checked := checked + 1
    if info.isUnsafe then
      throwError "UNSAFE_CANDIDATE: {name}"
    if let some replacement := Compiler.getImplementedBy? env name then
      throwError "UNCHECKED_RUNTIME_REPLACEMENT: {name} -> {replacement}"
    if (getExternAttrData? env name).isSome then
      throwError "CANDIDATE_EXTERN: {name}"
    for axiomName in (← collectAxioms name) do
      unless allowed.contains axiomName do
        throwError "UNAPPROVED_AXIOM: {name} depends on {axiomName}"
  if checked == 0 then throwError "No candidate declarations were inspected"
  let report := Json.mkObj [
    ("goal", toJson "Gate.accepted"),
    ("candidateDeclarations", toJson checked),
    ("axioms", toJson (rootAxioms.map toString))]
  liftIO <| IO.FS.writeFile "audit.json" report.compress
