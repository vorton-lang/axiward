"""One real, bounded acceptance boundary per invocation; no cached verdicts.

The FIFO and successor cases record the same controller executable's SHA-256.
Fixtures simulate user confirmation; they never confirm the Axiward product root.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import time


def stop_tree(process):
    if process.poll() is not None:
        return
    deadline = time.monotonic() + .5
    try:
        subprocess.run(["taskkill", "/PID", str(process.pid), "/T", "/F"],
                       capture_output=True, timeout=.4, creationflags=subprocess.CREATE_NO_WINDOW)
        process.wait(timeout=max(.001, deadline - time.monotonic()))
    except subprocess.TimeoutExpired as error:
        raise TimeoutError(f"could not confirm termination of child {process.pid} within 0.5 seconds") from error


def main():
    started = time.monotonic()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--case", required=True, choices=[
        "fifo", "successor", "wrong-proposition", "missing-proof", "wrong-version",
        "handoff", "refinement", "wrong-relation"])
    parser.add_argument("--toolchain", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--executable", type=Path)
    parser.add_argument("--child", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()
    if not args.child:
        process = subprocess.Popen([sys.executable, str(Path(__file__).resolve()),
                                    *sys.argv[1:], "--child"], stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, text=True, encoding="utf-8",
                                   creationflags=subprocess.CREATE_NO_WINDOW)
        try:
            output, _ = process.communicate(timeout=max(.1, 59 - (time.monotonic() - started)))
        except subprocess.TimeoutExpired:
            stop_tree(process)
            raise TimeoutError("acceptance boundary exceeded its 59-second budget")
        if process.returncode == 0:
            result_path = args.output.resolve() / "results.json"
            result = json.loads(result_path.read_text(encoding="utf-8"))
            result["parentSeconds"] = round(time.monotonic() - started, 3)
            result_path.write_text(json.dumps(result, indent=2), encoding="utf-8")
            print(json.dumps(result), flush=True)
        else:
            print(output, end="")
        assert time.monotonic() - started < 60
        raise SystemExit(process.returncode)

    source = Path(__file__).resolve().parent.parent
    exe = (args.executable or source / ".lake/build/bin/axiward.exe").resolve()
    executable_digest = hashlib.sha256(exe.read_bytes()).hexdigest()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    repo, policy, candidate = output / "project", output / "policy", output / "candidate"
    example = "fifo" if args.case == "fifo" else "successor"
    original_policy = source / "examples" / example / "policy"
    manifest = json.loads((original_policy / "acceptance.json").read_text(encoding="utf-8"))
    for relative in ["acceptance.json", *manifest["files"]]:
        destination = policy / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(original_policy / relative, destination)
    commands = []

    def run(command, success=True):
        remaining = 58 - (time.monotonic() - started)
        if remaining <= 0:
            raise TimeoutError("acceptance command exceeded its case budget")
        command_started = time.monotonic()
        process = subprocess.Popen(list(map(str, command)), stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, text=True, encoding="utf-8",
                                   creationflags=subprocess.CREATE_NO_WINDOW)
        try:
            stdout, stderr = process.communicate(timeout=remaining)
        except subprocess.TimeoutExpired as error:
            stdout, stderr = error.output or "", error.stderr or ""
            if isinstance(stdout, bytes):
                stdout = stdout.decode("utf-8", errors="replace")
            if isinstance(stderr, bytes):
                stderr = stderr.decode("utf-8", errors="replace")
            commands.append({"command": list(map(str, command)), "timeout": remaining,
                             "stdout": stdout, "stderr": stderr})
            (output / "commands.json").write_text(json.dumps(commands, indent=2), encoding="utf-8")
            stop_tree(process)
            raise TimeoutError("acceptance command exceeded its case budget")
        commands.append({"command": list(map(str, command)), "exitCode": process.returncode,
                         "seconds": round(time.monotonic() - command_started, 3),
                         "stdout": stdout, "stderr": stderr})
        (output / "commands.json").write_text(json.dumps(commands, indent=2), encoding="utf-8")
        if success is not None:
            assert (process.returncode == 0) == success, stdout + stderr
        return stdout

    def cli(*arguments, success=True):
        return json.loads(run([exe, *arguments], success))

    initialized = cli("init", repo, policy, args.toolchain.resolve())
    scope = initialized["scope"]
    if args.case == "handoff":
        def acquire(name, request):
            view = repo / ".view" / name
            owner = cli("session", repo, view, sys.executable, source / "adapter/server.py")["worker"]
            package = cli("next", repo, request, owner, view, 0, "execute")
            return view, owner, package

        view, owner, first = acquire("first", "first-package")
        assert first["input"] == scope and first["acceptance"] == manifest
        original = (policy / manifest["specificationPath"]).read_bytes()
        (policy / manifest["specificationPath"]).write_text("unconfirmed draft\n", encoding="utf-8")
        restarted = cli("worker-status", repo, owner, view)
        assert restarted["input"] == scope and restarted["acceptance"] == manifest
        assert Path(restarted["specification"]).read_bytes() == original
        cli("cancel", repo, "end-first", owner, first["serial"], "fixture handoff")
        _, _, following = acquire("following", "following-package")
        assert following["serial"] != first["serial"]
        assert following["input"] == scope and following["acceptance"] == manifest
        assert Path(following["specification"]).read_bytes() == original
        assert following["handoff"]["attempts"], "new worker lost the prior package history"
    elif args.case in {"refinement", "wrong-relation"}:
        candidate.mkdir()
        for name in ("plan.json", "Refinement.lean"):
            shutil.copyfile(source / "examples/successor/refinement" / name, candidate / name)
        if args.case == "wrong-relation":
            plan = json.loads((candidate / "plan.json").read_text())
            plan["children"] = [[1]]
            (candidate / "plan.json").write_text(json.dumps(plan), encoding="utf-8")
        cli("begin", repo, "allocate", "worker", 0, "refine")
        cli("submit", repo, "seal", "worker", 0, candidate)
        verdict = cli("check", repo, "verify", 0)
        state = cli("status", repo)
        assert not state["complete"] and not state["rootClosed"]
        if args.case == "refinement":
            assert len(state["nodes"]) == 2, verdict
            assert state["nodes"][0]["route"] is not None, verdict
        else:
            assert "rejected" in verdict, verdict
            assert len(state["nodes"]) == 1
    else:
        candidate.mkdir()
        for mapping in manifest["candidateFiles"]:
            if args.case == "missing-proof" and mapping["source"] == "Proof.lean":
                continue
            destination = candidate / mapping["source"]
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source / "examples" / example / "candidate" / mapping["source"], destination)
        if args.case == "wrong-proposition":
            proof = candidate / "Proof.lean"
            proof.write_text(proof.read_text().replace(
                "theorem implementation_correct : Successor.Required Implementation.next := by\n  intro n\n  rfl",
                "theorem implementation_correct : True := True.intro"), encoding="utf-8")
        if args.case == "successor":
            (candidate / "Specification.lean").write_text("-- candidate-owned specification draft\n", encoding="utf-8")
        cli("begin", repo, "allocate", "worker")
        sealed = cli("submit", repo, "seal", "worker", 0, candidate,
                     success=None if args.case == "missing-proof" else True)
        if args.case == "successor":
            sealed_paths = run(["git", "-C", repo, "ls-tree", "-r", "--name-only",
                                "HEAD:.axiward/candidate"]).splitlines()
            assert set(sealed_paths) == {"submission.json", *(item["target"] for item in manifest["candidateFiles"])}, sealed_paths
        if args.case == "missing-proof" and "error" in sealed:
            assert "Proof.lean" in sealed["error"], sealed
        else:
            if args.case == "wrong-version":
                draft = dict(manifest, version="2")
                (policy / "acceptance.json").write_text(json.dumps(draft), encoding="utf-8")
                specification = policy / manifest["specificationPath"]
                specification.write_text(specification.read_text().replace("n + 1", "n + 2"), encoding="utf-8")
                preview = cli("revise-preview", repo, "revision", policy)
                cli("revise", repo, "revision", policy, preview["reviewToken"])
            elif args.case == "successor":
                # Neither a policy draft nor a candidate draft can alter sealed inputs.
                (policy / manifest["specificationPath"]).write_text("unconfirmed draft\n", encoding="utf-8")
                (candidate / "Implementation.lean").write_text("unsubmitted draft\n", encoding="utf-8")
            verdict = cli("check", repo, "verify", 0, success=None if args.case == "wrong-version" else True)
            if args.case in {"fifo", "successor"}:
                assert "accepted" in verdict, verdict
                delivered = cli("deliver", repo)
                application = Path(delivered["directory"]) / manifest["artifacts"][0]
                if example == "fifo":
                    text = run([application, "2", "a", "b", "c"])
                    assert "enqueue c: accepted=false" in text and "dequeue: value=a" in text
                else:
                    assert run([application, "42"]).strip() == "43"
            else:
                assert "accepted" not in verdict, verdict
                if args.case == "wrong-proposition":
                    assert "rejected" in verdict, verdict
                if args.case == "missing-proof":
                    assert "Proof.lean" in json.dumps(verdict), verdict
        if args.case in {"fifo", "successor"}:
            # Delivery performs the production load and completion check itself.
            assert delivered["complete"] and delivered["scope"] == scope
            assert json.loads((Path(delivered["directory"]) / "acceptance.json").read_text(encoding="utf-8")) == manifest
        else:
            state = cli("status", repo)
            assert not state["complete"] and not state["rootClosed"]
            if args.case == "wrong-version":
                assert state["state"]["scope"] != scope and state["acceptance"]["version"] == "2"

    assert hashlib.sha256(exe.read_bytes()).hexdigest() == executable_digest, "controller was rebuilt during case"
    result = {"case": args.case, "status": "passed", "seconds": round(time.monotonic() - started, 3),
              "controllerSha256": executable_digest, "executable": str(exe),
              "realLeanVerification": args.case in {"fifo", "successor", "wrong-proposition", "refinement", "wrong-relation"},
              "scope": scope, "axiwardProductRootVerified": False, "limitSeconds": 60}
    assert result["seconds"] < 60
    (output / "results.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
    print(json.dumps(result), flush=True)


if __name__ == "__main__":
    main()
