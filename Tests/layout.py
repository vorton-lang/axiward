"""Root-contained delivery and flat worker inputs through real CLI/adapter IO.

Package cases intercept only the check dispatch after real sealing, with an
explicit not-verified result. Mathematical verification has its own boundary.
Delivery clones an already accepted test fixture without rerunning its verifier.
"""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import sys
import time
import tomllib


def main():
    started = time.monotonic()
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--toolchain", type=Path)
    parser.add_argument("--repo", type=Path)
    parser.add_argument("--case", required=True,
                        choices=["execute", "refine", "explore", "requestDecision", "delivery"])
    args = parser.parse_args()
    source = Path(__file__).resolve().parent.parent
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    repo = output / "project"
    exe = source / ".lake/build/bin/axiward.exe"
    events = []

    def run(command, success=True):
        remaining = 27 - (time.monotonic() - started)
        assert remaining > 0, "layout check exceeded its 27-second budget"
        result = subprocess.run(list(map(str, command)), capture_output=True, timeout=remaining,
                                creationflags=subprocess.CREATE_NO_WINDOW)
        stdout, stderr = result.stdout.decode("utf-8"), result.stderr.decode("utf-8")
        events.append({"command": list(map(str, command)), "exitCode": result.returncode,
                       "stdout": stdout, "stderr": stderr})
        (output / "commands.json").write_text(json.dumps(events, indent=2), encoding="utf-8")
        assert (result.returncode == 0) == success, stdout + stderr
        return stdout

    def cli(*arguments, success=True):
        return json.loads(run([exe, *arguments], success))

    def git(*arguments):
        return run(["git", "-C", repo, *arguments]).strip()

    if args.case == "delivery":
        assert args.repo is not None
        run(["git", "clone", "--quiet", "--no-hardlinks", "--", args.repo.resolve(), repo])
        before = git("rev-parse", "HEAD")
        delivered = cli("deliver", repo)
        destination = Path(delivered["directory"])
        assert destination == repo / "delivery" and destination.is_dir()
        manifest = (destination / "axiward-delivery.json").read_bytes()
        refused = cli("deliver", repo, success=False)
        assert "new directory" in refused["error"]
        assert (destination / "axiward-delivery.json").read_bytes() == manifest
        for reserved in (".git", ".axiward", "source", "product", ".view", ".checks"):
            refused = cli("deliver", repo, f"{reserved}/wrong-output", success=False)
            assert "reserved" in refused["error"]
            assert not (repo / reserved / "wrong-output").exists()
        for outside in (output / "outside", Path("delivery/../../outside")):
            refused = cli("deliver", repo, outside, success=False)
            assert "inside the project root" in refused["error"]
        assert not (output / "outside").exists()
        named = cli("deliver", repo, "delivery/next")
        assert Path(named["directory"]) == destination / "next"
        assert git("rev-parse", "HEAD") == before
        assert not (output / "project.checks").exists()
    else:
        assert args.toolchain is not None
        cli("init", repo, source / "examples/fifo/policy", args.toolchain.resolve())
        assert (repo / ".gitignore").read_text() == "/.view/\n/.checks/\n/delivery/\n"
        view = repo / ".view" / "package"
        session = cli("session", repo, view, sys.executable, source / "adapter/server.py")
        owner = session["worker"]
        metadata = view / ".axiward"
        assert (metadata / "tmp").is_dir(), "temporary directory must exist before the worker starts"
        config = tomllib.loads(Path(session["configuration"]).read_text(encoding="utf-8"))
        for key in ("TMP", "TEMP"):
            assert Path(config["shell_environment_policy"]["set"][key]) == metadata / "tmp"
        package = cli("next", repo, "next", owner, view, 0, args.case)
        assert Path(package["candidateDirectory"]) == view
        assert {path.name for path in view.iterdir()} == {"AGENTS.md", "Spec.lean", "Goal.lean", ".codex", ".axiward"}
        assert Path(package["guide"]) == view / "AGENTS.md"
        assert Path(package["viewPath"]) == metadata / "view.json"
        assert Path(package["evidencePath"]) == metadata / "evidence.json"
        assert Path(package["materialsDirectory"]) == metadata / "materials"
        assert Path(package["tempDirectory"]) == metadata / "tmp"
        assert package["claims"] == [0, 1, 2, 3, 4, 5]
        assert json.loads((metadata / "view.json").read_text(encoding="utf-8")) == package
        assert package["actionInstructions"].strip() in (view / "AGENTS.md").read_text(encoding="utf-8")
        assert package["handoff"]["inputSnapshot"]["head"] == package["snapshot"]
        assert package["handoff"]["currentHead"] == package["status"]["head"]
        assert package["status"]["map"] and isinstance(package["handoff"]["diagnostics"], list)
        assert not (metadata / "evidence.json").exists()
        assert not (metadata / "materials").exists()
        files = {"execute": ["Queue.lean", "Proofs.lean"],
                 "refine": ["plan.json", "Refinement.lean"],
                 "explore": ["exploration.json"], "requestDecision": ["question.json"]}[args.case]
        for name in files:
            original = source / "examples/fifo" / ("candidate" if args.case == "execute" else "refinement") / name
            if original.exists():
                shutil.copyfile(original, view / name)
            else:
                (view / name).write_text('{"fixture":"sealed only; not verified"}\n', encoding="utf-8")
        (view / "unselected.lean").write_text("must not be sealed\n", encoding="utf-8")
        sys.path.insert(0, str(source / "adapter"))
        import server
        adapter = server.Adapter(exe, repo, view, owner)
        dispatched = []

        def adapter_cli(*arguments):
            if arguments[0] == "check":
                dispatched.append(arguments)
                return {"verificationNotRun": True}
            return cli(*arguments)

        adapter.cli = adapter_cli
        response = adapter.call("prepare" if args.case == "explore" else "submit",
                                {"request_id": "seal", "node": 0, "serial": 0}, "layout-fixture")
        assert response["result"] == {"verificationNotRun": True} and len(dispatched) == 1
        assert not (metadata / "evidence.json").exists(), "ordinary package refresh must not export full evidence"
        expected = {"submission.json" if args.case in {"execute", "refine"} else "submission.txt"}
        expected.update(("Axiward/" + name if args.case == "execute" else name) for name in files)
        actual = set(git("ls-tree", "-r", "--name-only", "HEAD:.axiward/candidate").splitlines())
        assert actual == expected, "metadata or unrelated files entered the sealed candidate"
        for name in files:
            sealed = f'HEAD:.axiward/candidate/{"Axiward/" if args.case == "execute" else ""}{name}'
            assert run(["git", "-C", repo, "show", sealed]) == (view / name).read_bytes().decode("utf-8")
        artifact = adapter.call("evidence", {"node": 0, "serial": 0}, "evidence")
        assert Path(artifact["path"]) == metadata / "evidence.json"
        assert (metadata / "evidence.json").is_file() and not (view / "evidence.json").exists()
        if args.case == "execute":
            resource = "node/0/spec"
            material = adapter.call("view_add", {"node": 0, "serial": 0, "resource": resource}, "material")
            assert Path(material["path"]) == metadata / "materials/node_0_spec.txt"
            assert Path(material["path"]).read_bytes() == (view / "Spec.lean").read_bytes()
        assert not (repo / ".checks").exists(), "sealing unexpectedly invoked a verifier"
        assert not (output / "project.checks").exists()
    result = {"case": args.case, "status": "passed", "seconds": round(time.monotonic() - started, 3),
              "realLeanVerification": False, "boundary": "real CLI/adapter/Git layout IO"}
    assert result["seconds"] < 30
    (output / "results.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
    print(json.dumps(result))


if __name__ == "__main__":
    main()
