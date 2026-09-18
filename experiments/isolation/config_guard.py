"""A privileged adapter must refuse legacy or broadened native profiles."""
import argparse
import json
import subprocess
import sys
import time
import tomllib
from pathlib import Path
from records import PROJECT, save

parser = argparse.ArgumentParser()
parser.add_argument("--repo", type=Path, required=True)
args = parser.parse_args()
root = PROJECT / ".work" / ("configuration-guard-" + str(time.time_ns()))
exe = PROJECT / ".lake/build/bin/axiward.exe"
adapter = PROJECT / "adapter/server.py"
run = subprocess.run([str(exe), "session", str(args.repo.resolve()), str(root), sys.executable, str(adapter)],
                     capture_output=True, text=True, encoding="utf-8", timeout=60)
assert run.returncode == 0, run.stdout + run.stderr
session = json.loads(run.stdout)
config = root / ".codex/config.toml"
original = config.read_text(encoding="utf-8")
cases = []
try:
    for name, altered in [
        ("legacy-full-access", 'sandbox_mode = "danger-full-access"\n' + original),
        ("extra-workspace-write", original.replace('filesystem = { ', 'filesystem = { ":workspace_roots" = { "." = "write" }, ', 1)),
    ]:
        tomllib.loads(altered)
        config.write_text(altered, encoding="utf-8")
        child = subprocess.run([sys.executable, "-E", "-s", str(adapter), "--exe", str(exe),
                                "--repo", str(args.repo.resolve()), "--view", str(root), "--worker", session["worker"]],
                               input='{"id":1,"method":"initialize","params":{}}\n', capture_output=True,
                               text=True, encoding="utf-8", timeout=15)
        cases.append({"name": name, "exitCode": child.returncode, "stdout": child.stdout, "stderr": child.stderr})
        assert child.returncode != 0 and not child.stdout, cases[-1]
        assert "native" in child.stderr and ("refused" in child.stderr or "does not protect" in child.stderr)
    save("configuration-guard.json", {"status": "passed", "cases": cases}, root / "result.json")
    print("PASS: legacy full access and broadened profiles cannot start the adapter")
finally:
    config.write_text(original, encoding="utf-8")
