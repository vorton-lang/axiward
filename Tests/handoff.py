"""Fresh-worker recovery through real CLI/MCP and Git, without model inference.

User answers and the never-executed operation are explicit protocol fixtures.
The legacy acknowledgement is installed in its old journal encoding, not via a
current worker command. No native checker needs to run for these guarantees.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import time

from workflow import Client


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--toolchain", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    source = Path(__file__).resolve().parent.parent
    exe = source / ".lake/build/bin/axiward.exe"
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    repo = output / "project.git"
    started, commands, checks = time.monotonic(), [], []

    def write(name, value):
        (output / name).write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding="utf-8")

    def run(argv, *, success=True, data=None, env=None):
        result = subprocess.run(list(map(str, argv)), input=data, env=env, capture_output=True,
                                text=True, encoding="utf-8", timeout=90,
                                creationflags=subprocess.CREATE_NO_WINDOW)
        commands.append({"args": list(map(str, argv)), "exitCode": result.returncode,
                         "stdout": result.stdout, "stderr": result.stderr})
        write("commands.json", commands)
        assert (result.returncode == 0) == success, result.stdout + result.stderr
        return result.stdout.strip()

    def cli(*argv, success=True):
        return json.loads(run([exe, *argv], success=success))

    def git(*argv, **kwargs):
        return run(["git", f"--git-dir={repo / '.git'}", f"--work-tree={repo}", "-c", "user.name=Axiward tests",
                    "-c", "user.email=tests@localhost", *argv], **kwargs)

    cli("init", repo, source / "examples/fifo/policy", args.toolchain.resolve())
    views = [repo / ".view" / "worker-a", repo / ".view" / "worker-b"]
    owners = [cli("session", repo, view, sys.executable, source / "adapter/server.py")["worker"] for view in views]
    question = output / "question"
    question.mkdir()
    (question / "question.json").write_text(json.dumps({"prompt": "Use a list?",
        "subject": "FIFO implementation preference", "options": [{"key": "list", "label": "Use a list"}]}), encoding="utf-8")
    cli("begin", repo, "a-question", owners[0], 0, "requestDecision")
    cli("submit", repo, "a-submit", owners[0], 0, question)
    cli("check", repo, "a-check", 0)
    cli("decide", repo, "a-answer", 0, 0, "list", "durable preference marker")

    # Exact pre-removal event shape, retaining every original entry and reply.
    prior = git("rev-parse", "refs/heads/main")
    journal = json.loads(git("show", f"{prior}:.axiward/state.json"))
    journal["entries"].append({"request": {"id": "legacy-ack", "node": 0,
        "actor": {"worker": {"identity": owners[0]}},
        "command": {"workflow": {"command": {"acknowledge": {"serial": 0}}}}},
        "reply": {"acknowledged": {"serial": 0}}})
    blob = git("hash-object", "-w", "--stdin", data=json.dumps(journal))
    index_env = {**os.environ, "GIT_INDEX_FILE": str(output / "legacy-index")}
    git("read-tree", prior, env=index_env)
    git("update-index", "--add", "--cacheinfo", "100644", blob, ".axiward/state.json", env=index_env)
    tree = git("write-tree", env=index_env)
    commit = git("commit-tree", tree, "-p", prior, data=f"Axiward transition {len(journal['entries'])}\n")
    git("update-ref", "refs/heads/main", commit, prior)
    git("read-tree", "-m", "-u", prior, commit)
    restored = cli("status", repo)
    assert "acknowledged" not in restored["state"]["workflow"]["decisions"][0]
    assert json.loads(git("show", "main:.axiward/state.json")) == journal
    cli("acknowledge", repo, "removed", owners[0], 0, 0, success=False)
    cli("inbox", repo, owners[0], success=False)
    checks.append("legacy acknowledge journal replays unchanged without an acknowledged field or worker entry point")

    with (output / "mcp-events.jsonl").open("w", encoding="utf-8") as events:
        def fresh(name):
            view = repo / ".view" / name
            owner = cli("session", repo, view, sys.executable, source / "adapter/server.py")["worker"]
            return Client(source, exe, repo, view, owner, events)

        a = Client(source, exe, repo, views[0], owners[0], events)
        b = Client(source, exe, repo, views[1], owners[1], events)
        try:
            state = b.call("status")
            assert state == b.call("status") == a.call("status")
            assert cli("overview", repo)["head"] == commit
            b.call("acknowledge", success=False, request_id="removed", node=0, serial=0)
            package = b.call("next", request_id="fresh-b", node=0, action="explore")
            decision = package["handoff"]["decisions"][0]
            assert decision["sourceOwner"] == owners[0] and decision["applicableNow"]
            assert decision["answer"]["comment"] == "durable preference marker"
            assert package["handoff"]["inputSnapshot"]["head"] == package["snapshot"]
            assert package["handoff"]["currentHead"] == package["status"]["head"]
            checks.append("fresh B automatically receives A's previously acknowledged decision and fixed input version")

            directory = Path(package["candidateDirectory"])
            (directory / "exploration.json").write_text(json.dumps({"question": "Fixture recovery",
                "maxRuns": 1, "stopWhen": "Observe once"}), encoding="utf-8")
            b.call("prepare", request_id="prepare", node=0, serial=1)
            operation = owners[1] + "/fixture-operation"
            intent = cli("start-experiment", repo, operation, owners[1], 0, 1, source / "examples/fifo/candidate")
            assert not intent["replayed"]
            pending_head = cli("overview", repo)["head"]
            b.close()
            b = Client(source, exe, repo, views[1], owners[1], events)
            recovered = b.call("next", request_id="lost-context")
            assert recovered["snapshot"] == package["snapshot"]
            assert recovered["handoff"]["operations"][0]["operation"]["result"] is None
            assert a.call("status")["handoff"]["operations"] == recovered["handoff"]["operations"]
            assert cli("start-experiment", repo, operation, owners[1], 0, 1,
                       source / "examples/fifo/candidate")["replayed"]
            a.call("cancel", success=False, request_id="steal", node=0, serial=1, reason="foreign owner")
            a.call("submit", success=False, request_id="steal", node=0, serial=1)
            assert cli("overview", repo)["head"] == pending_head
            assert len(cli("status", repo)["state"]["workflow"]["operations"]) == 1
            b.call("cancel", request_id="end", node=0, serial=1, reason="leave the operation for reconciliation")
            ended = a.call("next", request_id="old-workspace")
            assert ended["serial"] == 0 and ended["requiresNewSession"]
            a.call("next", success=False, request_id="cannot-rebind", node=0, action="execute")
            a.close()
            a = fresh("followup")
            assigned = a.call("next", request_id="followup", node=0, action="execute")
            frozen_spec = (Path(assigned["candidateDirectory"]).parent / "Spec.lean").read_bytes()
            assert assigned["handoff"]["operations"][0]["operation"]["result"] is None
            checks.append("context-loss recovery preserves pending operation and owner restrictions without execution or commits")

            cli("reconcile", repo, "never-ran", 0, operation, "Fixture runner never started; no process remains")
            live = a.call("view_add", node=0, serial=2, resource="current/node/0/package-1-evidence")
            frozen = a.call("view_add", node=0, serial=2, resource="node/0/package-1-evidence")
            assert "Fixture runner never started" in Path(live["path"]).read_text(encoding="utf-8")
            assert "pending: reconcile before retry" in Path(frozen["path"]).read_text(encoding="utf-8")
            token = cli("revise-preview", repo, "new-root", source / "examples/fifo/policy-overwrite")["reviewToken"]
            cli("revise", repo, "new-root", source / "examples/fifo/policy-overwrite", token)
            changed_head = cli("overview", repo)["head"]
            changed = a.call("next", request_id="still-same-package")
            assert changed["snapshot"] == assigned["snapshot"]
            assert changed["handoff"]["currentHead"] == changed_head != assigned["snapshot"]
            assert not changed["handoff"]["inputSnapshot"]["stillCurrent"]
            old = changed["handoff"]["decisions"][0]
            assert old["recordedApplicable"] and not old["applicableNow"]
            assert (Path(changed["candidateDirectory"]).parent / "Spec.lean").read_bytes() == frozen_spec
            assert a.call("next", request_id="again") == changed
            assert cli("overview", repo)["head"] == changed_head
            checks.append("current decisions and operation records update while allocation input and source files stay fixed")

            cli("access", repo, "deny-history", "node/0/history", "deny")
            hidden = a.call("next", request_id="denied-context")
            assert hidden["handoff"]["blockedByMissingContext"] and not hidden["handoff"]["contextComplete"]
            assert hidden["handoff"]["decisions"] == [] and hidden["handoff"]["attempts"] == []
            assert "durable preference marker" not in json.dumps(hidden)
            a.call("view_add", success=False, node=0, serial=2, resource="current/node/0/history")
            assert a.call("search", node=0, serial=2, query="durable preference marker") == []
            cli("access", repo, "allow-history", "node/0/history", "allow")
            a.call("cancel", request_id="end-stale", node=0, serial=2, reason="stale input")
            b.close()
            b = fresh("off-branch")
            q = b.call("next", request_id="off-branch", node=0, action="requestDecision")
            (Path(q["candidateDirectory"]) / "question.json").write_bytes((question / "question.json").read_bytes())
            b.call("submit", request_id="off-submit", node=0, serial=3)
            cli("decide", repo, "off-answer", 0, 3, "unlisted answer", "simulated off-branch text")
            final = b.call("ask_user", node=0, serial=3)
            assert not any(d["applicableNow"] for d in final["handoff"]["decisions"])
            assert final["status"]["head"] == final["handoff"]["currentHead"]
            assert final["phase"] == "ended"
            checks.append("permissions block missing context explicitly, current aliases obey denials, and off-branch answers stay historical")
            b.close()
            b = fresh("invalid-question")
            invalid = b.call("next", request_id="invalid-question", node=0, action="requestDecision")
            (Path(invalid["candidateDirectory"]) / "question.json").write_text('{"prompt":"missing branches"}', encoding="utf-8")
            rejected = b.call("submit", request_id="invalid-submit", node=0, serial=4)["result"]
            assert "rejected" in rejected and rejected["rejected"]["reason"]
            a.close()
            a = fresh("after-failure")
            followup = a.call("next", request_id="after-failure", node=0, action="execute")
            attempt = next(x for x in followup["handoff"]["attempts"] if x.get("serial") == 4)
            assert attempt["action"] == "requestDecision"
            assert any(e["recordedOutcome"] == rejected for e in attempt["events"])
            sealed = next(e for e in attempt["events"] if "candidateResource" in e)
            assert sealed["availableInInputSnapshot"]
            exported = a.call("view_add", node=0, serial=5, resource=sealed["candidateResource"])
            assert "missing branches" in Path(exported["path"]).read_text(encoding="utf-8")
            checks.append("fresh worker receives the actual formal rejection reason and sealed candidate reference")
            write("final-handoff.json", final)
        finally:
            a.close()
            b.close()
    result = {"status": "passed", "seconds": round(time.monotonic() - started, 3), "checks": checks}
    write("results.json", result)
    print(json.dumps(result), flush=True)


if __name__ == "__main__":
    main()
