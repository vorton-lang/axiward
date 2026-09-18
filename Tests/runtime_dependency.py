"""Missing Codex PATH: fail before work starts and retain precise late failures.

All projects are new fixtures below --output. Only child-process environments
change; no user PATH, Codex configuration or existing project is modified.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time


def main():
    started = time.monotonic()
    parser = argparse.ArgumentParser()
    parser.add_argument("--toolchain", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--case", choices=["preflight", "late"], required=True)
    args = parser.parse_args()
    source = Path(__file__).resolve().parent.parent
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    repo = output / "project"
    view = repo / ".view" / "worker"
    executable = source / ".lake/build/bin/axiward.exe"
    git = Path(shutil.which("git"))
    codex = Path(shutil.which("codex"))
    missing = os.environ.copy()
    missing["PATH"] = os.pathsep.join([str(git.parent), os.environ["SystemRoot"],
                                      str(Path(os.environ["SystemRoot"]) / "System32")])
    assert shutil.which("codex", path=missing["PATH"]) is None
    available = missing.copy()
    available["PATH"] = str(codex.parent) + os.pathsep + missing["PATH"]
    events = []

    def run(command, env=available, success=True):
        remaining = 27 - (time.monotonic() - started)
        assert remaining > 0, "runtime dependency check exceeded its 27-second budget"
        result = subprocess.run(list(map(str, command)), env=env, capture_output=True,
                                timeout=remaining, creationflags=subprocess.CREATE_NO_WINDOW)
        stdout, stderr = result.stdout.decode("utf-8"), result.stderr.decode("utf-8")
        events.append({"command": list(map(str, command)), "exitCode": result.returncode,
                       "codexAvailable": env is available, "stdout": stdout, "stderr": stderr})
        (output / "commands.json").write_text(json.dumps(events, indent=2), encoding="utf-8")
        assert (result.returncode == 0) == success, stdout + stderr
        return stdout

    def cli(*arguments, env=available, success=True):
        return json.loads(run([executable, *arguments], env, success))

    def denied(*arguments):
        result = cli(*arguments, env=missing, success=False)
        assert "Codex CLI" in result["error"] and "PATH" in result["error"], result

    def head():
        return run([git, "-C", repo, "rev-parse", "HEAD"]).strip()

    init = ["init", repo, source / "examples/fifo/policy", args.toolchain.resolve()]
    if args.case == "preflight":
        denied(*init)
        assert not repo.exists(), "failed dependency preflight created a project"
    cli(*init)
    before = head()
    worker = "worker"
    if args.case == "preflight":
        denied("session", repo, view, sys.executable, source / "adapter/server.py")
        assert not view.exists(), "failed dependency preflight created a session"
        denied("begin", repo, "begin", "worker")
        assert head() == before, "missing runtime allocated a package"
        owner = cli("session", repo, view, sys.executable, source / "adapter/server.py")["worker"]
        worker = owner
        denied("next", repo, "next", owner, view, 0, "execute")
        assert head() == before, "missing runtime acquired a worker package"
    acquired = cli("begin", repo, "begin", worker)
    before = head()
    assert cli("begin", repo, "begin", worker, env=missing) == acquired
    conflict = cli("begin", repo, "begin", "different-owner", env=missing, success=False)
    assert "requestconflict" in conflict["error"].lower() and "Codex CLI" not in conflict["error"]
    if args.case == "preflight":
        recovered = cli("next", repo, "begin", worker, view, 0, "execute", env=missing)
        assert recovered["serial"] == 0 and recovered["phase"] == "drafting"
        bound = cli("next", repo, "recover", worker, view, env=missing)
        assert bound["serial"] == 0 and head() == before
    submit = ["submit", repo, "submit", worker, 0, source / "examples/fifo/candidate"]
    if args.case == "preflight":
        denied(*submit)
        assert head() == before, "missing runtime sealed a submission"
        assert cli("status", repo, env=missing)["state"]["active"]["phase"] == "drafting"
    sealed = cli(*submit)
    before = head()
    assert cli(*submit, env=missing) == sealed and head() == before
    if args.case == "late":
        reply = cli("check", repo, "check", 0, env=missing)
        assert "unresolved" in reply and "Codex CLI" in json.dumps(reply) and "PATH" in json.dumps(reply)
        status = cli("status", repo, env=missing)
        assert status["state"]["active"] is None and not status["complete"]
        evidence = repo / ".axiward/checks/0/verification"
        error = json.loads((evidence / "error.json").read_text(encoding="utf-8"))["error"]
        assert "Codex CLI" in error and "PATH" in error
        assert not (evidence / "01-build.json").exists(), "a verifier stage ran without Codex"
    result = {"case": args.case, "status": "passed", "seconds": round(time.monotonic() - started, 3),
              "realLeanVerification": False, "boundary": "real CLI and process lookup; no sandbox launched"}
    assert result["seconds"] < 30
    (output / "results.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
    print(json.dumps(result))


if __name__ == "__main__":
    main()
