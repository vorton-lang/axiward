"""Project a retained real merge failure through a fresh CLI package.

Run after integration.py --case merge-breaks-prior, passing its project as --repo.
Each case consumes one disposable .work fixture in place and checks one
independent read/access boundary. It never copies a repository or reruns the verifier.
"""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import time


def main():
    started = time.monotonic()
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--node", type=int, default=3)
    parser.add_argument("--serial", type=int, default=0)
    parser.add_argument("--case", required=True,
                        choices=["acquisition", "evidence", "history", "candidate", "previous-file", "initial-source"])
    args = parser.parse_args()
    assert args.node >= 0 and args.serial >= 0
    source = Path(__file__).resolve().parent.parent
    original = args.repo.resolve()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    repo = original
    assert repo.is_relative_to(source.parent / ".work"), "requires a disposable .work fixture"
    checks_before = set((repo / ".checks").iterdir()) if (repo / ".checks").exists() else set()
    exe = source / ".lake/build/bin/axiward.exe"
    commands = []

    def run(arguments, success=True):
        remaining = 28 - (time.monotonic() - started)
        if remaining <= 0:
            raise TimeoutError("diagnostic handoff check exceeded its 28-second budget")
        command_started = time.monotonic()
        result = subprocess.run(list(map(str, arguments)), capture_output=True, timeout=remaining,
                                creationflags=subprocess.CREATE_NO_WINDOW)
        stdout = result.stdout.decode("utf-8")
        stderr = result.stderr.decode("utf-8")
        commands.append({"args": list(map(str, arguments)), "exitCode": result.returncode,
                         "seconds": round(time.monotonic() - command_started, 3),
                         "stdout": stdout, "stderr": stderr})
        (output / "commands.json").write_text(
            json.dumps(commands, ensure_ascii=False, indent=2), encoding="utf-8")
        assert (result.returncode == 0) == success, stdout + stderr
        return stdout

    def git(project, *arguments):
        return run(["git", "--no-optional-locks", "-C", project, *arguments]).strip()

    def cli(*arguments, success=True):
        return json.loads(run([exe, *arguments], success))

    original_head = git(original, "rev-parse", "HEAD")
    node_path = ".axiward" if args.node == 0 else f".axiward/nodes/{args.node}"
    check_path = f"{node_path}/checks/{args.serial}"
    original_input = json.loads(git(original, "show", f"{original_head}:{check_path}/verification/input.json"))
    merge = json.loads(git(original, "show", f"{original_head}:{check_path}/merge.json"))
    original_stage = json.loads(git(original, "show", f"{original_head}:{check_path}/verification/01-build.json"))
    assert original_input["candidate"] == merge["merged"] != merge["submitted"], \
        "source must contain a real failed merged snapshot distinct from the submission"
    assert original_stage["exitCode"] != 0
    assert git(repo, "rev-parse", "HEAD") == original_head
    initial_denial = f"node/{args.node}/previous-Queue.lean"
    if args.case == "initial-source":
        cli("access", repo, "deny-initial-source", initial_denial, "deny")
    view = repo / ".view" / "fresh-reader"
    owner = cli("session", repo, view, sys.executable, source / "adapter/server.py")["worker"]
    following = cli("next", repo, "diagnostic-next", owner, view, args.node, "execute")
    serial = following["serial"]
    evidence = f"node/{args.node}/package-{args.serial}-evidence"
    current_evidence = f"current/{evidence}"
    snapshot = evidence + "-checked-snapshot"
    current_snapshot = f"current/{snapshot}"

    def failure(handoff):
        return next(item for item in handoff["diagnostics"] if item["evidenceResource"] == current_evidence)

    def strings(value):
        if isinstance(value, str):
            yield value
        elif isinstance(value, dict):
            for child in value.values():
                yield from strings(child)
        elif isinstance(value, list):
            for child in value:
                yield from strings(child)

    row = failure(following["handoff"])
    actual = row["diagnostic"]["checks"][0]
    assert row["checkedSnapshotResource"] == current_snapshot
    assert actual["input"]["record"] == original_input
    assert actual["stages"][0]["record"] == original_stage
    assert any(message["stream"] == "stdout" and message["severity"] == "error"
               for message in actual["stages"][0]["messages"])
    assert following["snapshot"] != original_head
    assert following["handoff"]["currentHead"] == following["status"]["head"]

    def read(resource, success=True):
        return cli("read", repo, owner, args.node, serial, resource, success=success)

    if args.case == "acquisition":
        snapshots = json.loads(read(current_snapshot)["content"])
        assert json.loads(read(snapshot)["content"]) == snapshots, "frozen/current aliases changed the failed input"
        checked = next(value for value in snapshots if value["input"] == original_input)
        for record in checked["candidateFiles"]:
            expected = run(["git", "-C", repo, "show", f'{merge["merged"]["tree"]}:{record["file"]}'])
            assert record["content"]["raw"] == expected
        assert checked["candidateFiles"], "actual checked source is missing"
        evidence_records = json.loads(read(current_evidence)["content"])
        assert any(original_stage == json.loads(item["raw"])
                   for record in evidence_records for item in json.loads(record["raw"])
                   if item["file"] == "verification/01-build.json")
    elif args.case == "initial-source":
        candidate_directory = Path(following["candidateDirectory"])
        assert not (candidate_directory / "Queue.lean").exists()
        assert (candidate_directory / "Proofs.lean").is_file(), "an allowed source file was not initialized"
        assert following["blockedSourceFiles"] == [initial_denial]
        status = cli("worker-status", repo, owner, view)
        assert status["blockedSourceFiles"] == [initial_denial]
        assert status["status"]["map"] == following["status"]["map"]
        assert status["handoff"]["currentHead"] == status["status"]["head"]
        assert failure(status["handoff"])["diagnostic"] == row["diagnostic"]
        source_resource = f"node/{args.node}/source"
        assert following["sourceResource"] == source_resource
        source_files = json.loads(read(source_resource)["content"])
        queue = next(record for record in source_files if record["file"] == "Axiward/Queue.lean")
        proof = next(record for record in source_files if record["file"] == "Axiward/Proofs.lean")
        assert queue["content"] == {"unavailable": "access revoked"}
        assert (candidate_directory / "Proofs.lean").read_bytes().decode("utf-8") == proof["content"]["raw"]
        cli("access", repo, "restore-initial-source", initial_denial, "allow")
        restored = json.loads(read(source_resource)["content"])
        for record in restored:
            expected = run(["git", "-C", repo, "show", f'{following["sourceBase"]["tree"]}:{record["file"]}'])
            assert record["content"]["raw"] == expected
        assert following["sourceBase"] != merge["merged"], "baseline must remain distinct from the rejected merge"
        draft = "-- unsubmitted worker draft\n"
        (view / "Queue.lean").write_text(draft, encoding="utf-8")
        (view / "Proofs.lean").unlink()
        view_file = view / ".axiward/view.json"
        view_file.write_text("invalid stale view", encoding="utf-8")
        status = cli("worker-status", repo, owner, view)
        assert status["snapshot"] == following["snapshot"] and status["blockedSourceFiles"] == []
        assert status["claims"] == following["claims"] and status["actionInstructions"]
        assert view_file.read_text(encoding="utf-8") == "invalid stale view", "status rewrote the local view"
        view_file.unlink()
        recovered = cli("next", repo, "recover-existing", owner, view)
        assert recovered["serial"] == serial and recovered["snapshot"] == following["snapshot"]
        assert recovered["claims"] == following["claims"] and recovered["actionInstructions"]
        assert recovered["blockedSourceFiles"] == []
        assert (view / "Queue.lean").read_text(encoding="utf-8") == draft, "recovery overwrote a draft"
        assert not (view / "Proofs.lean").exists(), "recovery revived a deleted candidate"
        assert not (view / ".axiward/evidence.json").exists(), "status or recovery exported full evidence"
    else:
        denied = {"evidence": evidence,
                  "history": f"node/{args.node}/history",
                  "candidate": f"node/{args.node}/package-{args.serial}-candidate",
                  "previous-file": f"node/{args.node}/previous-Proofs.lean"}[args.case]
        cli("access", repo, "diagnostic-deny", denied, "deny")
        if args.case in {"evidence", "history", "candidate"}:
            for resource in (snapshot, current_snapshot):
                assert "access revoked" in read(resource, success=False)["error"]
            assert "access revoked" in read(denied, success=False)["error"]
        if args.case in {"evidence", "history"}:
            assert "access revoked" in read(f"current/{denied}", success=False)["error"]
            status = cli("worker-status", repo, owner, view)
            hidden = failure(status["handoff"])
            assert hidden["unavailable"] == "access revoked" and "diagnostic" not in hidden
            assert status["handoff"]["blockedByMissingContext"]
            diagnostic_text = [message["raw"].strip() for message in actual["stages"][0]["messages"]
                               if message["stream"] == "stdout"]
            assert not any(marker in value for value in strings(status) for marker in diagnostic_text)
        elif args.case == "previous-file":
            for resource in (snapshot, current_snapshot):
                snapshots = json.loads(read(resource)["content"])
                checked = next(value for value in snapshots if value["input"] == original_input)
                proof = next(record for record in checked["candidateFiles"]
                             if record["file"] == "Axiward/Proofs.lean")
                assert proof["content"] == {"unavailable": "access revoked"}
    checks_after = set((repo / ".checks").iterdir()) if (repo / ".checks").exists() else set()
    assert checks_after == checks_before, "handoff unexpectedly reran the verifier"
    result = {"status": "passed", "case": args.case,
              "seconds": round(time.monotonic() - started, 3),
              "realCLI": True, "verifierRerun": False,
              "source": "retained real failure; disposable fixture used in place",
              "checkedCandidate": merge["merged"]["tree"]}
    assert result["seconds"] < 30
    (output / "results.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
    print(json.dumps(result), flush=True)


if __name__ == "__main__":
    main()
