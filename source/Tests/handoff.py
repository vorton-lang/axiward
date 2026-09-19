"""Persisted rejection and sealed inputs must reach a fresh package.

Pure workflow/scoped-decision cases live in WorkflowScenarios.lean; native.py
checks the real MCP/user channel. This check exercises the production adapter
and CLI against real Git without repeating those complete workflows.
"""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import time


def main():
    started = time.monotonic()
    deadline = started + 27
    parser = argparse.ArgumentParser()
    parser.add_argument("--toolchain", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    source = Path(__file__).resolve().parent.parent
    sys.path.insert(0, str(source / "adapter"))
    from server import Adapter

    exe = source / ".lake/build/bin/axiward.exe"
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    repo = output / "project"
    commands = []

    def cli(*arguments):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("handoff check exceeded its 27-second budget")
        run = subprocess.run([str(exe), *map(str, arguments)], capture_output=True,
                             text=True, encoding="utf-8", timeout=remaining,
                             creationflags=subprocess.CREATE_NO_WINDOW)
        commands.append({"args": list(map(str, arguments)), "exitCode": run.returncode,
                         "stdout": run.stdout, "stderr": run.stderr})
        (output / "commands.json").write_text(json.dumps(commands, ensure_ascii=False, indent=2), encoding="utf-8")
        value = json.loads(run.stdout)
        if run.returncode:
            raise RuntimeError(value.get("error", str(value)))
        return value

    def worker(name):
        view = repo / ".view" / name
        owner = cli("session", repo, view, sys.executable, source / "adapter/server.py")["worker"]
        result = Adapter(exe, repo, view, owner)
        result.cli = cli  # Same real controller boundary, with this check's total budget.
        return result

    def call(adapter, name, **data):
        return adapter.call(name, data, "fixture")

    cli("init", repo, source / "examples/fifo/policy", args.toolchain.resolve())
    a = worker("a")
    try:
        call(a, "next", request_id="missing-choice")
    except RuntimeError as error:
        assert "choose a node and action" in str(error), str(error)
    else:
        raise AssertionError("new work was allocated without an explicit choice")
    first = call(a, "next", request_id="question", node=0, action="requestDecision")
    assert first["serial"] == 0
    candidate = Path(first["candidateDirectory"]) / "question.json"
    candidate.write_text('{"prompt":"sealed rejection marker"}', encoding="utf-8")
    rejected = call(a, "submit", request_id="invalid-question", node=0, serial=0)["result"]
    assert "rejected" in rejected and rejected["rejected"]["reason"]
    candidate.write_text('{"prompt":"unsubmitted replacement"}', encoding="utf-8")
    ended = call(a, "next", request_id="recover-ended")
    assert ended["phase"] == "ended" and ended["requiresNewSession"]

    b = worker("b")
    following = call(b, "next", request_id="retry", node=0, action="execute")
    assert following["serial"] == 1 and following["snapshot"] != first["snapshot"]
    assert following["handoff"]["inputSnapshot"]["head"] == following["snapshot"]
    attempt = next(item for item in following["handoff"]["attempts"] if item.get("serial") == 0)
    assert any(event["recordedOutcome"] == rejected for event in attempt["events"])
    sealed = next(event for event in attempt["events"] if "candidateResource" in event)
    assert sealed["availableInInputSnapshot"]
    exported = call(b, "view_add", node=0, serial=1, resource=sealed["candidateResource"])
    text = Path(exported["path"]).read_text(encoding="utf-8")
    assert "sealed rejection marker" in text and "unsubmitted replacement" not in text
    (output / "handoff.json").write_text(json.dumps(following, ensure_ascii=False, indent=2), encoding="utf-8")
    result = {"status": "passed", "seconds": round(time.monotonic() - started, 3),
              "checks": ["new allocation requires explicit selection",
                         "ended packages stay ended and require a new workspace",
                         "fresh worker receives the durable rejection and a new input snapshot",
                         "old sealed candidate is reusable despite later unsubmitted edits"]}
    (output / "results.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
    print(json.dumps(result), flush=True)


if __name__ == "__main__":
    main()
