"""One independent storage boundary, including initialization, within 30 seconds."""
import argparse
import json
from pathlib import Path
import subprocess
import time


def main():
    started = time.monotonic()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--case", choices=["batch", "cas", "sealed", "checked-race", "corruption"], required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    source = Path(__file__).resolve().parent.parent
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    process = subprocess.Popen([str(source / ".lake/build/bin/store_scenarios.exe"),
                                args.case, str(output / "project")],
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               text=True, encoding="utf-8", creationflags=subprocess.CREATE_NO_WINDOW)
    try:
        text, _ = process.communicate(timeout=max(.1, 27 - (time.monotonic() - started)))
    except subprocess.TimeoutExpired:
        subprocess.run(["taskkill", "/PID", str(process.pid), "/T", "/F"],
                       capture_output=True, timeout=1, creationflags=subprocess.CREATE_NO_WINDOW)
        raise TimeoutError("storage boundary exceeded its 27-second budget")
    (output / "output.txt").write_text(text, encoding="utf-8")
    result = {"case": args.case, "exitCode": process.returncode,
              "seconds": round(time.monotonic() - started, 3), "realLeanVerification": False}
    assert result["seconds"] < 30
    (output / "results.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
    print(text, end="")
    print(json.dumps(result))
    raise SystemExit(process.returncode)


if __name__ == "__main__":
    main()
