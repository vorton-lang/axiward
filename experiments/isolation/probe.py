"""Bounded native permission-profile probe. All generated artifacts stay in .work."""
import argparse
import json
import subprocess
import sys
import time
from pathlib import Path
from records import save


def toml(value):
    if isinstance(value, dict):
        return "{ " + ", ".join(json.dumps(k) + " = " + toml(v) for k, v in value.items()) + " }"
    return json.dumps(value)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=["elevated", "unelevated"], default="elevated")
    parser.add_argument("--minimal", action="store_true")
    args = parser.parse_args()
    project = Path(__file__).resolve().parents[2]
    root = project / ".work" / ("isolation-" + str(time.time_ns()))
    view, vault, other = root / "view", root / "vault", root / "other"
    for path in (view, vault, other):
        path.mkdir(parents=True)
    (vault / "data.txt").write_text("synthetic-private-project", encoding="utf-8")
    (other / "data.txt").write_text("unrelated-project", encoding="utf-8")
    script = view / "access.py"
    script.write_text('''import json, sys
from pathlib import Path
root=Path(sys.argv[1]); report={}
for name,path,write in [('view',root/'view'/'ok.txt',True),('private-read',root/'vault'/'data.txt',False),('private-write',root/'vault'/'new.txt',True),('outside-read',root/'other'/'data.txt',False)]:
 try:
  if write: path.write_text('probe',encoding='utf-8')
  else: path.read_text(encoding='utf-8')
  report[name]='allowed'
 except OSError as e: report[name]={'denied':e.winerror,'message':str(e)}
print(json.dumps(report))
''', encoding="utf-8")
    policy = {"filesystem": {":root": "read", ":workspace_roots": {".": "write", ".codex": "read", ".git": "read"},
                             vault.as_posix(): "deny"}, "network": {"enabled": True}}
    if args.minimal:
        policy["filesystem"] = {":minimal": "read", str(Path(sys.executable).parent): "read", str(view): "write"}
        policy["network"]["enabled"] = False
    command = ["codex", "sandbox", "-P", "axiward_probe", "-C", str(view),
               "-c", "permissions.axiward_probe = " + toml(policy),
               "-c", "windows.sandbox = " + json.dumps(args.mode),
               sys.executable, str(script), str(root)]
    run = subprocess.run(command, capture_output=True, text=True, encoding="utf-8", timeout=60,
                         creationflags=subprocess.CREATE_NO_WINDOW)
    record = {"mode": args.mode, "policy": policy, "command": command, "exitCode": run.returncode,
              "stdout": run.stdout, "stderr": run.stderr}
    name = "profile-" + args.mode + ("-minimal" if args.minimal else "") + ".json"
    save(name, record, root / "result.json")
    print(json.dumps({"exitCode": run.returncode, "stdout": run.stdout, "stderr": run.stderr}, ensure_ascii=True))


if __name__ == "__main__":
    main()
