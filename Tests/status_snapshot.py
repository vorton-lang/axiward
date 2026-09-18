"""Deterministic status/read-write interleaving through the real controller.

User answers are simulated fixture input. Only the test intercepts the adapter's
process boundary; every read and write still uses the production CLI and Git.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import subprocess
import sys
import threading
import time

from workflow import Client


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--toolchain", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    source = Path(__file__).resolve().parent.parent
    sys.path.insert(0, str(source / "adapter"))
    from server import Adapter

    started = time.monotonic()
    exe = source / ".lake/build/bin/axiward.exe"
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    repo, view = output / "project.git", output / "worker"
    commands = []

    def write(name, value):
        (output / name).write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding="utf-8")

    def cli(*arguments):
        run = subprocess.run([str(exe), *map(str, arguments)], capture_output=True,
                             text=True, encoding="utf-8", timeout=60,
                             creationflags=subprocess.CREATE_NO_WINDOW)
        commands.append({"args": list(map(str, arguments)), "exitCode": run.returncode,
                         "stdout": run.stdout, "stderr": run.stderr})
        write("commands.json", commands)
        assert run.returncode == 0, run.stdout + run.stderr
        return json.loads(run.stdout)

    def components(worker):
        # No writer runs while these independent reference reads are collected.
        value = cli("worker-status", repo, worker)
        assert value["status"] == cli("overview", repo)
        assert value["navigation"] == cli("navigate", repo)
        assert value["handoff"]["currentHead"] == value["status"]["head"]
        assert cli("overview", repo)["head"] == value["status"]["head"]
        return value

    cli("init", repo, source / "examples/fifo/policy", args.toolchain.resolve())
    worker = cli("session", repo, view, Path(sys.executable), source / "adapter/server.py")["worker"]
    other = cli("session", repo, output / "other-worker", Path(sys.executable),
                source / "adapter/server.py")["worker"]
    question = output / "question"
    question.mkdir()
    (question / "question.json").write_text(json.dumps({
        "prompt": "Fixture: use a list?", "subject": "Simulated FIFO preference only.",
        "options": [{"key": "list", "label": "Use a list"}]}), encoding="utf-8")
    for serial, owner in enumerate((worker, other)):
        assert cli("begin", repo, f"begin-{serial}", owner, 0, "requestDecision") == {"acquired": {"serial": serial}}
        cli("submit", repo, f"submit-{serial}", owner, serial, question)
        cli("check", repo, f"check-{serial}", serial)
        assert cli("decide", repo, f"answer-{serial}", 0, serial, "list", "simulated") == {
            "answered": {"serial": serial, "applicable": True}}

    before = components(worker)
    assert [item["sourceOwner"] for item in before["handoff"]["decisions"]] == [worker, other]
    assert all(item["applicableNow"] for item in before["handoff"]["decisions"])
    assert any(r["allowed"] for item in before["navigation"] for r in item["recommendations"])
    with (output / "mcp-events.jsonl").open("w", encoding="utf-8") as events:
        client = Client(source, exe, repo, view, worker, events)
        try:
            # Read repeatedly without consuming context or allowing forged identities.
            assert client.call("status") == before
            assert client.call("status") == before
            client.call("status", success=False, worker=other)
            client.call("status", success=False, repo=str(repo))
        finally:
            client.close()
    assert cli("overview", repo)["head"] == before["status"]["head"]

    adapter = Adapter(exe, repo, view, worker)
    controller_call = adapter.cli
    read_finished, write_finished = threading.Event(), threading.Event()

    def read_then_wait(*arguments):
        value = controller_call(*arguments)
        if not read_finished.is_set():
            read_finished.set()
            assert write_finished.wait(timeout=60), "writer did not complete"
        return value

    # Hold the first real controller result before Adapter.call can finish.
    # A split implementation would read navigation/handoff after the
    # commits below, despite reporting the earlier overview head.
    adapter.cli = read_then_wait
    with ThreadPoolExecutor(max_workers=1) as pool:
        pending = pool.submit(adapter.call, "status", {}, "race")
        try:
            assert read_finished.wait(timeout=60), "status did not finish its first read"
            cli("begin", repo, "race-question", other, 0, "requestDecision")
            cli("submit", repo, "race-submit", other, 2, question)
            cli("check", repo, "race-check", 2)
            cli("decide", repo, "race-answer", 0, 2, "list", "new simulated decision")
            cli("pause", repo, "race-pause", "status snapshot fixture")
        finally:
            write_finished.set()
        actual = pending.result(timeout=60)

    after = components(worker)
    write("race.json", {"before": before, "returned": actual, "after": after})
    assert before["status"]["head"] != after["status"]["head"], "writer made no commit"
    assert after["status"]["paused"] and len(after["handoff"]["decisions"]) == 3
    assert not any(r["allowed"] for item in after["navigation"] for r in item["recommendations"])
    assert components(other)["handoff"] == after["handoff"], "handoff depends on worker identity"
    assert actual["status"]["head"] == before["status"]["head"]
    for section in ("status", "navigation", "handoff"):
        assert actual[section] == before[section], f"{section} differs from the returned head's snapshot"
    assert adapter.call("status", {}, "after") == after
    result = {"status": "passed", "seconds": round(time.monotonic() - started, 3),
              "snapshotHead": before["status"]["head"], "currentHead": after["status"]["head"],
              "checks": ["MCP response shape and protected worker binding",
                         "status repeats all relevant decisions across worker identities without writes",
                         "concurrent commits complete before status returns",
                         "all three response sections match the returned head",
                         "later status observes pause and newly recorded user decision"]}
    write("results.json", result)
    print(json.dumps(result), flush=True)


if __name__ == "__main__":
    main()
