"""One independent real verifier boundary per invocation, including setup.

Each required --case identifies a separate boundary. Successful results
are not cached between cases; the 28-second guard is failure containment only.
"""
import argparse
import json
from pathlib import Path
import subprocess
import time


def main():
    started = time.monotonic()
    parser = argparse.ArgumentParser()
    parser.add_argument("--toolchain", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--case", required=True,
                        choices=["accepted", "assembled", "mixed", "wrong-fifo", "sorry", "missing-proof",
                                 "refinement", "omitted-clause", "revision", "reuse"])
    args = parser.parse_args()
    source = Path(__file__).resolve().parent.parent
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    command = [str(source / ".lake/build/bin/verifier_boundary.exe"), args.case,
               str(output / "project"), str(source), str(args.toolchain.resolve())]
    with (output / "stdout.txt").open("w", encoding="utf-8") as stdout, (output / "stderr.txt").open("w", encoding="utf-8") as stderr:
        process = subprocess.Popen(command, stdout=stdout, stderr=stderr,
                                   creationflags=subprocess.CREATE_NO_WINDOW)
        try:
            code = process.wait(timeout=max(0.1, 28 - (time.monotonic() - started)))
        except subprocess.TimeoutExpired:
            subprocess.run(["taskkill", "/PID", str(process.pid), "/T", "/F"],
                           capture_output=True, timeout=1, creationflags=subprocess.CREATE_NO_WINDOW)
            raise TimeoutError("real verifier boundary exceeded its 28-second budget")
    result = {"case": args.case, "status": "passed" if code == 0 else "failed",
              "seconds": round(time.monotonic() - started, 3), "exitCode": code,
              "realLeanVerification": args.case not in {"mixed", "revision", "reuse"},
              "fixtureVerdicts": args.case in {"assembled", "mixed", "reuse"}}
    assert result["seconds"] < 30, "verifier boundary exceeded 30 seconds"
    (output / "results.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
    print(json.dumps(result), flush=True)
    if code:
        raise RuntimeError((output / "stderr.txt").read_text(encoding="utf-8"))


if __name__ == "__main__":
    main()
