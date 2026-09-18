"""Check whether two native verifier invocations interfere."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import subprocess
import time
from pathlib import Path
from records import PROJECT, save

parser = argparse.ArgumentParser()
parser.add_argument("--toolchain", type=Path, required=True)
parser.add_argument("--separate-projects", action="store_true")
args = parser.parse_args()
root = PROJECT / ".work" / ("concurrent-isolation-" + str(time.time_ns()))
root.mkdir(parents=True)
exe = PROJECT / ".lake/build/bin/axiward.exe"
repo = root / "project.git"


def cli(*items):
    run = subprocess.run([str(exe), *map(str, items)], capture_output=True, text=True,
                         encoding="utf-8", timeout=180, creationflags=subprocess.CREATE_NO_WINDOW)
    assert run.returncode == 0, run.stdout + run.stderr
    return json.loads(run.stdout)


repos = [repo, root / "other.git"] if args.separate_projects else [repo]
for target in repos:
    cli("init", target, PROJECT / "examples/fifo/policy", args.toolchain.resolve())
    cli("begin", target, "begin", "worker")
    cli("submit", target, "submit", "worker", 0, PROJECT / "examples/fifo/candidate")
with ThreadPoolExecutor(max_workers=2) as executor:
    futures = [executor.submit(cli, "check", repos[i % len(repos)], "check", 0) for i in range(2)]
    replies = [future.result() for future in futures]
logs = [json.loads(p.read_text(encoding="utf-8")) for target in repos for p in Path(str(target) + ".checks").glob("run-*/01-build.json")]
result = {"status": "passed" if all(r == {"accepted": {"serial": 0}} for r in replies) else "failed",
          "separateProjects": args.separate_projects, "replies": replies, "buildRecords": logs}
save(root.name + ".json", result, root / "result.json")
print(json.dumps(result, ensure_ascii=True), flush=True)
assert result["status"] == "passed"
