"""Run correct and hostile candidates through the actual restricted verifier."""
import argparse
import json
import shutil
import subprocess
import time
from pathlib import Path
from records import PROJECT, save

parser = argparse.ArgumentParser()
parser.add_argument("--toolchain", type=Path, required=True)
args = parser.parse_args()
root = PROJECT / ".work" / ("verifier-isolation-" + str(time.time_ns()))
root.mkdir(parents=True)
exe = PROJECT / ".lake/build/bin/axiward.exe"
events, cases = [], []


def cli(*arguments):
    run = subprocess.run([str(exe), *map(str, arguments)], capture_output=True, text=True,
                         encoding="utf-8", timeout=180, creationflags=subprocess.CREATE_NO_WINDOW)
    event = {"arguments": list(map(str, arguments)), "exitCode": run.returncode,
             "stdout": run.stdout, "stderr": run.stderr}
    events.append(event)
    (root / "commands.json").write_text(json.dumps(events, ensure_ascii=False, indent=2), encoding="utf-8")
    assert run.returncode == 0, event
    return json.loads(run.stdout)


result = {"status": "running", "cases": cases, "commands": events}
try:
    for name in ("valid", "private-read", "policy-write"):
        repo = root / (name + ".git")
        cli("init", repo, PROJECT / "examples/fifo/policy", args.toolchain.resolve())
        sentinel = "PROTECTED_STORE_BYTES_" + name
        (repo / "PRIVATE.txt").write_text(sentinel, encoding="utf-8")
        candidate = root / (name + "-candidate")
        shutil.copytree(PROJECT / "examples/fifo/candidate", candidate)
        if name != "valid":
            original = (candidate / "Proofs.lean").read_text(encoding="utf-8")
            if name == "private-read":
                operation = '  let secret ← IO.FS.readFile ' + json.dumps(str(repo / "PRIVATE.txt")) + '\n  IO.println secret'
            else:
                operation = '  IO.FS.writeFile "Axiward/Spec.lean" "-- attempted policy replacement"'
            (candidate / "Proofs.lean").write_text("import Lean\n" + original.replace(
                "namespace Axiward", "run_cmd do\n" + operation + "\n\nnamespace Axiward", 1), encoding="utf-8")
        cli("begin", repo, "begin", "worker")
        cli("submit", repo, "submit", "worker", 0, candidate)
        reply = cli("check", repo, "check", 0)
        logs = [json.loads(path.read_text(encoding="utf-8")) for path in root.glob(name + ".git.checks/run-*/01-build.json")]
        cases.append({"name": name, "reply": reply, "buildRecords": logs})
        save("verifier-results.json", result, root / "result.json")
        if name == "valid":
            assert "accepted" in reply, cases[-1]
        else:
            assert "rejected" in reply, cases[-1]
            observed = "\n".join(log["stdout"] + log["stderr"] for log in logs).lower()
            assert sentinel.lower() not in observed
            assert any(word in observed for word in ("permission", "denied", "not permitted", "拒绝访问")), cases[-1]
            assert (repo / "PRIVATE.txt").read_text(encoding="utf-8") == sentinel
        print("PASS:", name, flush=True)
    result["status"] = "passed"
except Exception as error:
    result["status"] = "failed"
    result["error"] = str(error)
    raise
finally:
    save("verifier-results.json", result, root / "result.json")
