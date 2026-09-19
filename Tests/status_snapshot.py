"""A real Git commit between controller reads must not mix status snapshots."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import time


def main():
    started = time.monotonic()
    deadline = started + 25
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
    view = repo / ".view" / "reader"
    commands = []

    def cli(*arguments):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("status snapshot check exceeded its 25-second budget")
        run = subprocess.run([str(exe), *map(str, arguments)], capture_output=True,
                             text=True, encoding="utf-8", timeout=remaining,
                             creationflags=subprocess.CREATE_NO_WINDOW)
        commands.append({"args": list(map(str, arguments)), "exitCode": run.returncode,
                         "stdout": run.stdout, "stderr": run.stderr})
        (output / "commands.json").write_text(json.dumps(commands, ensure_ascii=False, indent=2), encoding="utf-8")
        assert run.returncode == 0, run.stdout + run.stderr
        return json.loads(run.stdout)

    cli("init", repo, source / "examples/fifo/policy", args.toolchain.resolve())
    owner = cli("session", repo, view, sys.executable, source / "adapter/server.py")["worker"]
    cli("next", repo, "allocate", owner, view, 0, "execute")
    adapter = Adapter(exe, repo, view, owner)
    before = cli("worker-status", repo, owner, view)
    assert not before["status"]["paused"] and not before["handoff"]["paused"]
    assert before["status"]["map"] and before["actionInstructions"]

    def workspace():
        return {str(path.relative_to(view)): None if path.is_dir() else
                (path.read_bytes(), path.stat().st_mtime_ns) for path in view.rglob("*")}

    original_files = workspace()
    committed = False

    def read_then_commit(*arguments):
        nonlocal committed
        value = cli(*arguments)
        if not committed:
            committed = True
            # Commit after the first real read, before Adapter.call receives it.
            # Any subsequent component read would observe the new Git version.
            cli("pause", repo, "interleaved-pause", "snapshot check")
        return value

    adapter.cli = read_then_commit
    actual = adapter.call("status", {}, "race")
    after = cli("worker-status", repo, owner, view)
    (output / "race.json").write_text(json.dumps(
        {"before": before, "returned": actual, "after": after}, ensure_ascii=False, indent=2), encoding="utf-8")
    assert committed and before["status"]["head"] != after["status"]["head"]
    assert after["status"]["paused"] and after["handoff"]["paused"]
    assert actual == before, "response mixed state from different Git commits"
    assert actual["status"]["head"] == actual["handoff"]["currentHead"]
    adapter.cli = cli
    assert adapter.call("status", {}, "repeat") == after, "reading status changed or consumed state"
    cli("access", repo, "deny-claims", "node/0/claims", "deny")
    denied = adapter.call("status", {}, "denied-claims")
    assert denied["claims"] is None, "status leaked revoked claims from the old view"
    assert denied["handoff"]["blockedByMissingContext"]
    assert workspace() == original_files, "status wrote to the package workspace"
    result = {"status": "passed", "seconds": round(time.monotonic() - started, 3),
              "checks": ["real commit between component reads cannot mix response versions",
                         "later status observes the committed pause",
                         "bound status retains project map and action instructions",
                         "revoked claims are not recovered from a stale local view",
                         "repeated reads do not change state or write package files"]}
    assert result["seconds"] < 30
    (output / "results.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
    print(json.dumps(result), flush=True)


if __name__ == "__main__":
    main()
