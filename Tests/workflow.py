"""Independent short workflow IO boundaries; no repeated FIFO compilation.

The Lean helper uses explicitly synthetic verdicts and real Git/process IO.
The intent case also checks that the production adapter never re-dispatches it.
"""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import time


def main():
    started = time.monotonic()
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--case", required=True, choices=["late", "intent"])
    args = parser.parse_args()
    source = Path(__file__).resolve().parent.parent
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    repo = output / "project"

    def remaining():
        seconds = 27 - (time.monotonic() - started)
        if seconds <= 0:
            raise TimeoutError("workflow boundary exceeded its 27-second budget")
        return seconds

    with (output / "stdout.txt").open("w", encoding="utf-8") as stdout, (output / "stderr.txt").open("w", encoding="utf-8") as stderr:
        process = subprocess.Popen([str(source / ".lake/build/bin/workflow_boundary.exe"), args.case, str(repo)],
                                   stdout=stdout, stderr=stderr, creationflags=subprocess.CREATE_NO_WINDOW)
        try:
            code = process.wait(timeout=remaining())
        except subprocess.TimeoutExpired:
            subprocess.run(["taskkill", "/PID", str(process.pid), "/T", "/F"],
                           capture_output=True, timeout=2, creationflags=subprocess.CREATE_NO_WINDOW)
            raise TimeoutError("workflow boundary exceeded its 27-second budget")
    if code:
        raise RuntimeError((output / "stderr.txt").read_text(encoding="utf-8"))
    if args.case == "intent":
        sys.path.insert(0, str(source / "adapter"))
        import server

        def forbidden_dispatch(*_args):
            raise AssertionError("adapter dispatched an already recorded experiment")

        server.execute = forbidden_dispatch
        adapter = server.Adapter(source / ".lake/build/bin/axiward.exe", repo, repo / ".view/worker", "worker")

        def cli(*arguments):
            run = subprocess.run([str(adapter.exe), *map(str, arguments)], capture_output=True,
                                 text=True, encoding="utf-8", timeout=remaining(),
                                 creationflags=subprocess.CREATE_NO_WINDOW)
            assert run.returncode == 0, run.stdout + run.stderr
            return json.loads(run.stdout)

        adapter.cli = cli
        # Handoff rendering has its own real-Git check. The synthetic policy in
        # this IO fixture intentionally has no FIFO gate or viewing resources.
        adapter.package_view = lambda _node, _serial: {}
        response = adapter.call("experiment", {"request_id": "trial", "node": 0, "serial": 0, "trial": "trial"}, "fixture")
        assert response["replayed"] and response["operation"]["result"] is not None, response
    result = {"case": args.case, "status": "passed", "seconds": round(time.monotonic() - started, 3),
              "verdictSource": "controlled protocol fixture; actual Git and process IO"}
    assert result["seconds"] < 30
    (output / "results.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
    print(json.dumps(result), flush=True)


if __name__ == "__main__":
    main()
