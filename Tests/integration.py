"""Real process/Git/verifier boundary tests. All test directories are retained."""

import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import shutil
import subprocess
from threading import Lock


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--toolchain", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--executable", type=Path)
    args = parser.parse_args()
    source = Path(__file__).resolve().parent.parent
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    executable = args.executable.resolve() if args.executable else source / ".lake/build/bin/axiward.exe"
    policy = source / "examples/fifo/policy"
    original = source / "examples/fifo/candidate"
    events = []
    completed = []
    event_lock = Lock()

    def command(argv, *, success=True, env=None, data=None):
        result = subprocess.run(
            list(map(str, argv)), input=data, capture_output=True,
            text=True, encoding="utf-8", env=env, timeout=150,
        )
        event = {"argv": list(map(str, argv)), "exit": result.returncode,
                 "stdout": result.stdout, "stderr": result.stderr}
        with event_lock:
            events.append(event)
            (output / "commands.json").write_text(
                json.dumps(events, ensure_ascii=False, indent=2), encoding="utf-8")
        assert (result.returncode == 0) == success, event
        return result.stdout

    def cli(*argv, success=True, env=None):
        return json.loads(command([executable, *argv], success=success, env=env))

    def git(repo, *argv, data=None, env=None):
        return command(["git", f"--git-dir={repo}", "-c", "user.name=Axiward tests",
                        "-c", "user.email=tests@localhost", *argv], data=data, env=env).strip()

    def init(name):
        repo = output / f"{name}.git"
        cli("init", repo, policy, args.toolchain.resolve())
        return repo

    def passed(name):
        completed.append(name)
        print(f"PASS: {name}", flush=True)

    altered_policy = output / "altered-policy"
    shutil.copytree(policy, altered_policy)
    altered_gate = altered_policy / "Gate.lean"
    gate_text = altered_gate.read_text(encoding="utf-8")
    assert "Axiward.Q0.Created n" in gate_text
    altered_gate.write_text(gate_text.replace("Axiward.Q0.Created n",
                            "False ∧ Axiward.Q0.Created n", 1), encoding="utf-8")
    unsupported = output / "unsupported.git"
    refusal = cli("init", unsupported, altered_policy, args.toolchain.resolve(), success=False)
    assert "unsupported root policy" in refusal["error"]
    assert not unsupported.exists()
    passed("unsupported root policy is refused without silently substituting the FIFO goal")

    repo = init("accepted")
    start = cli("status", repo)["head"]
    cli("init", repo, policy, args.toolchain.resolve(), success=False)
    assert cli("status", repo)["head"] == start
    cli("begin", repo, "begin", "worker")
    leased = cli("status", repo)["head"]
    cli("begin", repo, "begin", "worker")
    assert cli("status", repo)["head"] == leased
    cli("begin", repo, "begin", "other", success=False)
    passed("initialization protection and request replay")

    candidate = output / "editable-candidate"
    shutil.copytree(original, candidate)
    cli("submit", repo, "submit", "worker", "0", candidate)
    sealed = cli("status", repo)
    assert "checking" in sealed["state"]["active"]["phase"]
    queue = candidate / "Queue.lean"
    queue.write_text(queue.read_text(encoding="utf-8").replace(
        "q.items ++ [item]", "item :: q.items"), encoding="utf-8")

    # Both controller invocations have the same logical request and immutable input.
    foreign_env = dict(os.environ, LEAN_SYSROOT=str(output / "foreign-toolchain"),
                       LEAN_CC=str(output / "foreign-compiler.exe"))
    with ThreadPoolExecutor(max_workers=2) as pool:
        futures = [pool.submit(cli, "check", repo, "check", "0", env=foreign_env) for _ in range(2)]
        replies = [future.result() for future in futures]
    assert all(reply == {"accepted": {"serial": 0}} for reply in replies), replies
    accepted = cli("status", repo)
    assert accepted["state"]["active"] is None
    assert accepted["state"]["published"] is not None
    assert accepted["transitions"] == 3
    cli("check", repo, "check", "0")
    assert cli("status", repo)["head"] == accepted["head"]
    assert "sealed" in cli("submit", repo, "submit", "worker", "0", original)
    cli("submit", repo, "submit", "worker", "0", candidate, success=False)
    assert cli("status", repo)["head"] == accepted["head"]
    passed("sealed input survives process restart and local edits; concurrent check commits once")

    exported = output / "delivered"
    command(["git", "clone", "--quiet", "--no-hardlinks", repo, exported])
    program = exported / "product/.lake/build/bin/fifo_demo.exe"
    execution = command([program, "2", "a", "b", "c"])
    assert "enqueue c: accepted=false" in execution
    assert execution.index("dequeue: value=a") < execution.index("dequeue: value=b")
    passed("published binary runs from the committed delivery")

    for name in ("wrong-fifo", "sorry", "missing-proof"):
        bad = init(name)
        directory = output / f"candidate-{name}"
        directory.mkdir()
        queue_source = queue if name == "wrong-fifo" else original / "Queue.lean"
        shutil.copyfile(queue_source, directory / "Queue.lean")
        if name != "missing-proof":
            proofs = (original / "Proofs.lean").read_text(encoding="utf-8")
            if name == "sorry":
                old = "  intro room\n  simp [Queue.enqueue, room]"
                assert old in proofs
                proofs = proofs.replace(old, "  sorry", 1)
            (directory / "Proofs.lean").write_text(proofs, encoding="utf-8")
        cli("begin", bad, "begin", "worker")
        cli("submit", bad, "submit", "worker", "0", directory)
        reply = cli("check", bad, "check", "0")
        assert "rejected" in reply, reply
        if name == "sorry":
            assert "02-audit" in reply["rejected"]["reason"], reply
        status = cli("status", bad)
        assert status["state"]["published"] is None
        assert status["state"]["active"] is None
        logs = git(bad, "ls-tree", "-r", "--name-only", "HEAD", ".axiward/checks/0")
        assert "01-build.json" in logs, logs
        passed(f"{name}: rejected, package released, raw evidence retained in Git")

    race = init("race")
    processes = [subprocess.Popen([str(executable), "begin", str(race), f"begin-{i}", f"worker-{i}"],
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                 encoding="utf-8") for i in range(2)]
    results = []
    for proc in processes:
        stdout, stderr = proc.communicate(timeout=60)
        results.append({"exit": proc.returncode, "stdout": stdout, "stderr": stderr})
    assert sorted(result["exit"] for result in results) == [0, 1], results
    assert cli("status", race)["transitions"] == 1
    (output / "race.json").write_text(json.dumps(results, indent=2), encoding="utf-8")
    passed("concurrent acquisition has exactly one owner")

    command([source / ".lake/build/bin/store_scenarios.exe", output / "storage.git"])
    passed("storage fault injection and journal validation")

    refinement_proof = (source / "examples/fifo/refinement/Refinement.lean").read_text(encoding="utf-8")
    proof_text = (original / "Proofs.lean").read_text(encoding="utf-8")
    claim_names = ["created", "enqueue_room", "enqueue_full", "dequeue_some", "dequeue_empty", "measured"]
    header = proof_text[:proof_text.index("theorem created")]

    def part(name, claims, wrong_queue=False, overwrite=False):
        folder = output / name
        folder.mkdir()
        source_candidate = source / "examples/fifo/candidate-overwrite" if overwrite else original
        code = (source_candidate / "Queue.lean").read_text(encoding="utf-8")
        if wrong_queue:
            code = code.replace("q.items ++ [item]", "item :: q.items")
        (folder / "Queue.lean").write_text(code, encoding="utf-8")
        selected_proofs = (source_candidate / "Proofs.lean").read_text(encoding="utf-8")
        fragments = []
        for claim in claims:
            start = selected_proofs.index(f"theorem {claim_names[claim]}")
            stop = (selected_proofs.index(f"theorem {claim_names[claim + 1]}") if claim < 5
                    else selected_proofs.index("-- The root binds"))
            fragments.append(selected_proofs[start:stop])
        (folder / "Proofs.lean").write_text(header + "".join(fragments) + "end Axiward\n", encoding="utf-8")
        return folder

    def refine(target, node, serial, name, children, direct=False, implementation=None, result=None):
        folder = output / name
        folder.mkdir()
        (folder / "plan.json").write_text(json.dumps({"children": children, "direct": direct,
            "implementation": implementation, "result": result}), encoding="utf-8")
        (folder / "Refinement.lean").write_text(refinement_proof, encoding="utf-8")
        cli("begin", target, name + "-begin", "planner", str(node), "refine")
        cli("submit", target, name + "-submit", "planner", str(serial), folder, str(node))
        return cli("check", target, name + "-check", str(serial), str(node))

    multi = init("multi")
    assert refine(multi, 0, 0, "split", [[0, 1, 2], [3, 4, 5]])["refined"]["children"] == [1, 2]
    assert not cli("status", multi)["rootClosed"]
    cli("compose", multi, "0", success=False)
    cli("begin", multi, "wrong-action", "worker", "0", "execute", success=False)
    assert refine(multi, 1, 0, "nested", [[0], [1, 2]])["refined"]["children"] == [3, 4]
    with ThreadPoolExecutor(max_workers=3) as pool:
        acquisitions = [pool.submit(cli, "begin", multi, f"begin-node-{node}", f"worker-{node}",
                                    str(node), "execute") for node in (2, 3, 4)]
        assert all("acquired" in future.result() for future in acquisitions)
    leaves = [(2, [3, 4, 5]), (3, [0]), (4, [1, 2])]
    for node, claims in leaves:
        folder = part(f"part-{node}", claims)
        cli("submit", multi, f"submit-node-{node}", f"worker-{node}", "0", folder, str(node))
    for node, _ in leaves[:-1]:
        assert "accepted" in cli("check", multi, f"check-node-{node}", "0", str(node))
        assert not cli("status", multi)["rootClosed"]
    assert "accepted" in cli("check", multi, "check-node-4", "0", "4")
    combined = cli("status", multi)
    assert combined["rootClosed"]
    assert all(node["domain"]["published"] is not None for node in combined["nodes"])
    assert combined["nodes"][0]["support"]["children"][0]["node"] == 1
    multi_export = output / "combined-delivery"
    command(["git", "clone", "--quiet", "--no-hardlinks", multi, multi_export])
    assert (multi_export / "product/Axiward/Parts/N3.lean").exists()
    combined_run = command([multi_export / "product/.lake/build/bin/fifo_demo.exe", "2", "first", "second"])
    assert combined_run.index("value=first") < combined_run.index("value=second")
    passed("nested refinement, independent concurrent tasks, automatic upward proofs, runnable combined delivery")

    replacement_policy = source / "examples/fifo/policy-overwrite"
    preview = cli("revise-preview", multi, "overwrite-revision", replacement_policy)
    assert preview["impact"]["changedRequirements"] == ["fifo/2"], preview
    assert preview["impact"]["invalidatedResults"] == [0, 1, 4], preview
    assert preview["impact"]["retainedResults"] == [2, 3], preview
    assert cli("status", multi)["head"] == combined["head"]
    altered_confirmation = cli("revise", multi, "overwrite-revision", policy, preview["reviewToken"], success=False)
    assert "reviewed change no longer matches" in altered_confirmation["error"]
    assert cli("status", multi)["head"] == combined["head"]
    changed = cli("revise", multi, "overwrite-revision", replacement_policy, preview["reviewToken"])
    assert changed["impact"] == preview["impact"]
    after_revision = cli("status", multi)
    assert not after_revision["rootClosed"] and after_revision["obsoleteGoals"] == [1, 4]
    for node in (2, 3):
        assert after_revision["nodes"][node] == combined["nodes"][node]
    assert cli("revise", multi, "overwrite-revision", replacement_policy, preview["reviewToken"])["alreadyApplied"]
    assert cli("status", multi)["head"] == after_revision["head"]
    cli("revise", multi, "overwrite-revision", policy, preview["reviewToken"], success=False)
    stale = cli("revise", multi, "stale-preview", policy, preview["reviewToken"], success=False)
    assert "reviewed change no longer matches" in stale["error"]
    cli("begin", multi, "obsolete-goal", "worker", "4", "execute", success=False)
    assert "rejected" in refine(multi, 0, 1, "obsolete-node-reuse", [{"reuse": 4}, [0], [3, 4, 5]])
    assert "rejected" in refine(multi, 0, 2, "obsolete-result-reuse", [], result={
        "node": 0, "receipt": combined["state"]["published"]["receipt"]})
    passed("requirement revision previews exact impact, preserves unaffected nodes, and rejects obsolete evidence")

    assert refine(multi, 0, 3, "revision-route", [[0, 1, 2], {"reuse": 2}],
                  implementation=0)["refined"]["children"] == [5, 2]
    assert refine(multi, 5, 0, "revision-branch", [{"reuse": 3}, [1, 2]],
                  implementation=0)["refined"]["children"] == [3, 6]
    replacement = part("replacement-enqueue", [1, 2], overwrite=True)
    cli("begin", multi, "replacement-begin", "replacement-worker", "6", "execute")
    cli("submit", multi, "replacement-submit", "replacement-worker", "0", replacement, "6")
    assert "accepted" in cli("check", multi, "replacement-check", "0", "6")
    wrong_source = cli("status", multi)
    assert not wrong_source["rootClosed"]
    assert wrong_source["nodes"][5]["domain"]["published"] is None
    assert wrong_source["nodes"][6]["domain"]["published"] is not None
    assert "refined" in refine(multi, 5, 1, "correct-source", [{"reuse": 3}, {"reuse": 6}], implementation=1)
    upgraded = cli("status", multi)
    assert upgraded["rootClosed"]
    assert len(upgraded["nodes"]) == 7
    for node in (2, 3):
        assert upgraded["nodes"][node] == combined["nodes"][node]
    assert upgraded["nodes"][6]["domain"]["nextSerial"] == 1
    changed_export = output / "changed-delivery"
    command(["git", "clone", "--quiet", "--no-hardlinks", multi, changed_export])
    new_program = changed_export / "product/.lake/build/bin/fifo_demo.exe"
    replaced_run = command([new_program, "2", "a", "b", "c"])
    assert "enqueue c: accepted=true" in replaced_run
    assert "dequeue: value=a" not in replaced_run
    assert replaced_run.index("dequeue: value=b") < replaced_run.index("dequeue: value=c")
    empty_run = command([new_program, "0", "x"])
    assert "accepted=false" in empty_run and "dequeue: empty" in empty_run
    passed("one execution task repairs the changed behavior; retained proof sources are checked against the new implementation")

    restore_preview = cli("revise-preview", multi, "restore-original-spec", policy)
    cli("revise", multi, "restore-original-spec", policy, restore_preview["reviewToken"])
    historical = refine(multi, 0, 4, "historical-result", [], result={
        "node": 0, "receipt": combined["state"]["published"]["receipt"]})
    assert "reused" in historical, historical
    recovered = cli("status", multi)
    assert recovered["rootClosed"] and recovered["state"]["scope"]["revision"] == 2
    assert recovered["state"]["published"]["product"] == combined["state"]["published"]["product"]
    historical_logs = git(multi, "ls-tree", "-r", "--name-only", "HEAD", ".axiward/checks/4")
    assert "receipt.json" in historical_logs and "01-build" not in historical_logs
    passed("historically admitted delivery is reused under an identical restored goal without rebuilding it")

    cycle = init("cycle")
    cycle_result = refine(cycle, 0, 0, "self-cycle", [{"reuse": 0}])
    assert "rejected" in cycle_result and "cyclic" in cycle_result["rejected"]["reason"]
    assert len(cli("status", cycle)["nodes"]) == 1
    assert "rejected" in refine(cycle, 0, 1, "unadmitted-result", [], result={"node": 0, "receipt": "f" * 64})
    passed("cyclic node reuse and unadmitted historical receipts are rejected")

    omitted = init("omit")
    assert "rejected" in refine(omitted, 0, 0, "omitted-clause", [[0, 1, 2], [3, 4]])
    omission = cli("status", omitted)
    assert len(omission["nodes"]) == 1 and not omission["rootClosed"]
    assert omission["state"]["active"] is None
    passed("refinement missing a root requirement is rejected before creating children")

    mixed = init("mix")
    assert "refined" in refine(mixed, 0, 0, "mixed-route", [[0, 1, 2], [3, 4, 5]])
    for node, claims in ((1, [0, 1, 2]), (2, [3, 4, 5])):
        folder = part(f"mixed-part-{node}", claims, wrong_queue=(node == 2))
        cli("begin", mixed, f"mix-begin-{node}", f"worker-{node}", str(node), "execute")
        cli("submit", mixed, f"mix-submit-{node}", f"worker-{node}", "0", folder, str(node))
        assert "accepted" in cli("check", mixed, f"mix-check-{node}", "0", str(node))
    mixing = cli("status", mixed)
    assert not mixing["rootClosed"]
    assert all(node["domain"]["published"] is not None for node in mixing["nodes"][1:])
    assert "compositionFailed" in cli("compose", mixed, "0")
    assert cli("status", mixed)["head"] == mixing["head"]
    conflict = cli("compose", mixed, "0", "mix-begin-1", success=False)
    assert "request ID conflict" in conflict["error"]
    assert "compositionFailed" in cli("compose", mixed, "0", "mix-retry")
    old_products = [node["domain"]["published"] for node in mixing["nodes"][1:]]
    assert refine(mixed, 0, 1, "restore-direct", [], direct=True)["refined"]["children"] == []
    direct = cli("status", mixed)
    assert direct["nodes"][0]["route"] is None and not direct["rootClosed"]
    assert old_products == [node["domain"]["published"] for node in direct["nodes"][1:]]
    passed("different implementations cannot be combined; replacing a route preserves existing child results")

    # Corrupt only the actual delivery, retaining its former state and receipt.
    index_env = dict(os.environ, GIT_INDEX_FILE=str(output / "tamper-index"))
    git(repo, "read-tree", "HEAD", env=index_env)
    replacement = git(repo, "hash-object", "-w", "--stdin", data="tampered binary")
    git(repo, "update-index", "--add", "--cacheinfo", "100644", replacement,
        "product/.lake/build/bin/fifo_demo.exe", env=index_env)
    bad_tree = git(repo, "write-tree", env=index_env)
    bad_commit = git(repo, "commit-tree", bad_tree, "-p", accepted["head"], data="fault injection\n")
    git(repo, "update-ref", "refs/heads/main", bad_commit, accepted["head"])
    rejected = cli("status", repo, success=False)
    assert "product or receipt" in rejected["error"]
    passed("delivery tampering prevents state recovery")

    (output / "results.json").write_text(json.dumps({
        "passed": completed, "deliveryCommit": accepted["head"],
        "exportedDelivery": str(exported), "retainedArtifacts": str(output),
        "combinedCommit": combined["head"], "combinedDelivery": str(multi_export),
        "changedCommit": upgraded["head"], "changedDelivery": str(changed_export),
        "revisionImpact": preview["impact"], "restoredCommit": recovered["head"],
    }, ensure_ascii=False, indent=2), encoding="utf-8")


if __name__ == "__main__":
    main()
