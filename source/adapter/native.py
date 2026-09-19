"""One native command/exec, with exact streams; no model or project scheduler."""
import base64
import json
import queue
import subprocess
import threading
import uuid
from pathlib import Path

HIDDEN = getattr(subprocess, "CREATE_NO_WINDOW", 0)


def execute(command, cwd: Path, evidence: Path):
    evidence.mkdir(parents=True, exist_ok=False)
    messages = queue.Queue()
    streams = {"stdout": bytearray(), "stderr": bytearray()}
    record = {"source": "codex-command-exec", "command": list(map(str, command)),
              "completed": False, "capped": False, "exitCode": 1,
              "processId": "axiward-" + uuid.uuid4().hex}
    with (evidence / "native-stderr.txt").open("w", encoding="utf-8") as errors:
        process = subprocess.Popen(
            ["codex", "app-server", "--stdio"], cwd=cwd, stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=errors, text=True, encoding="utf-8",
            creationflags=HIDDEN,
        )

        def reader():
            try:
                for line in process.stdout:
                    messages.put(json.loads(line))
            finally:
                messages.put(None)

        threading.Thread(target=reader, daemon=True).start()

        def send(item):
            process.stdin.write(json.dumps(item) + "\n")
            process.stdin.flush()

        def receive():
            item = messages.get(timeout=240)
            if item is None:
                raise RuntimeError("native transport closed; operation remains pending")
            return item

        try:
            send({"id": 1, "method": "initialize", "params": {
                "clientInfo": {"name": "axiward", "version": "0.2.0"},
                "capabilities": {"experimentalApi": True}}})
            while True:
                item = receive()
                if item.get("id") == 1:
                    if "error" in item:
                        raise RuntimeError(str(item["error"]))
                    break
            send({"method": "initialized"})
            send({"id": 2, "method": "command/exec", "params": {
                "command": record["command"], "cwd": str(cwd),
                "processId": record["processId"], "streamStdoutStderr": True,
                "timeoutMs": 180000, "disableOutputCap": True,
                "sandboxPolicy": {"type": "dangerFullAccess"}}})
            with (evidence / "events.jsonl").open("w", encoding="utf-8") as events:
                while True:
                    item = receive()
                    events.write(json.dumps(item, ensure_ascii=False) + "\n")
                    events.flush()
                    if item.get("method") == "command/exec/outputDelta":
                        delta = item["params"]
                        if delta["processId"] != record["processId"]:
                            raise RuntimeError("native process identity mismatch")
                        streams[delta["stream"]].extend(base64.b64decode(delta["deltaBase64"], validate=True))
                        record["capped"] |= delta.get("capReached", False)
                    elif item.get("id") == 2:
                        if "error" in item:
                            raise RuntimeError(str(item["error"]))
                        record.update(completed=True, exitCode=item["result"]["exitCode"])
                        break
        finally:
            for key, data in streams.items():
                (evidence / (key + ".bin")).write_bytes(data)
                try:
                    record[key] = data.decode("utf-8", errors="strict")
                except UnicodeDecodeError:
                    record[key] = data.decode("utf-8", errors="replace")
                    record["capped"] = True  # unusable as a complete structured observation
            (evidence / "capture.json").write_text(json.dumps(record, ensure_ascii=False), encoding="utf-8")
            process.stdin.close()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.terminate()
                process.wait(timeout=5)
    return evidence / "capture.json"
