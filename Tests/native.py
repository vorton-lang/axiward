"""Full-access Codex router + MCP elicitation. No model turns or inference.

The ephemeral native context is a protocol fixture. User replies are simulated
by this client and are not user approval of a real product.
"""
import argparse
import json
import queue
import subprocess
import sys
import threading
import tomllib
from pathlib import Path


def toml(value):
    if isinstance(value, dict):
        return "{ " + ", ".join(json.dumps(k) + " = " + toml(v) for k, v in value.items()) + " }"
    return json.dumps(value)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--toolchain", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    source = Path(__file__).resolve().parent.parent
    exe = source / ".lake/build/bin/axiward.exe"
    root = args.output.resolve()
    root.mkdir(parents=True, exist_ok=False)
    repo = root / "project.git"
    view = repo / ".view" / "question"

    def cli(*args):
        run = subprocess.run([str(exe), *map(str, args)], capture_output=True, text=True,
                             encoding="utf-8", timeout=60, creationflags=subprocess.CREATE_NO_WINDOW)
        assert run.returncode == 0, run.stdout + run.stderr
        return json.loads(run.stdout)

    cli("init", repo, source / "examples/fifo/policy", args.toolchain.resolve())
    cli("session", repo, view, Path(sys.executable), source / "adapter/server.py")
    generated = tomllib.loads((view / ".codex/config.toml").read_text(encoding="utf-8"))
    mcp = generated["mcp_servers"]["axiward"]
    assert mcp["args"][:2] == ["-E", "-s"]
    command = ["codex", "app-server", "--stdio"]
    for key, value in generated.items():
        if key == "mcp_servers":
            for name, settings in value.items():
                command += ["-c", "mcp_servers." + name + " = " + toml(settings)]
        else:
            command += ["-c", key + " = " + toml(value)]
    command += ["--disable", "multi_agent"]
    events = (root / "events.jsonl").open("w", encoding="utf-8")
    errors = (root / "stderr.txt").open("w", encoding="utf-8")
    native = subprocess.Popen(command, cwd=view, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                              stderr=errors, text=True, encoding="utf-8", creationflags=subprocess.CREATE_NO_WINDOW)
    messages = queue.Queue()

    def read():
        for line in native.stdout:
            messages.put(json.loads(line))
        messages.put(None)

    threading.Thread(target=read, daemon=True).start()
    questions = []

    def send(item):
        native.stdin.write(json.dumps(item) + "\n")
        native.stdin.flush()

    def response(number):
        while True:
            item = messages.get(timeout=90)
            assert item is not None, "native server exited"
            events.write(json.dumps(item, ensure_ascii=False) + "\n")
            events.flush()
            if item.get("method") == "mcpServer/elicitation/request":
                params = item["params"]
                assert params["serverName"] == "axiward", params
                if (params.get("_meta") or {}).get("codex_approval_kind") == "mcp_tool_call":
                    send({"id": item["id"], "result": {"action": "accept", "content": {}}})
                else:
                    questions.append({"threadId": params["threadId"], "message": params["message"]})
                    send({"id": item["id"], "result": {"action": "accept", "content": {
                        "choice": "list", "comment": "本次中文答复仅用于协议验收"}}})
            elif "method" in item and "id" in item:
                send({"id": item["id"], "error": {"code": -32601, "message": "not part of this protocol fixture"}})
            elif item.get("id") == number:
                assert "error" not in item, item
                return item["result"]

    def tool(number, name, success=True, **data):
        send({"id": number, "method": "mcpServer/tool/call", "params": {
            "threadId": thread, "server": "axiward", "tool": name, "arguments": data}})
        result = response(number)
        assert (not result.get("isError")) == success, result
        return json.loads(result["content"][0]["text"])

    try:
        send({"id": 1, "method": "initialize", "params": {"clientInfo": {"name": "axiward-acceptance", "version": "0.1"},
              "capabilities": {"experimentalApi": True}}})
        response(1)
        send({"method": "initialized"})
        send({"id": 2, "method": "thread/start", "params": {"cwd": str(view),
              "approvalPolicy": generated["approval_policy"], "ephemeral": True}})
        thread = response(2)["thread"]["id"]
        tool(3, "status")
        package = tool(4, "next", request_id="question", node=0, action="requestDecision")
        question = {"prompt": "协议验收：先使用列表吗？", "subject": "仅模拟当前 FIFO 目标的偏好，不是真实用户批准。",
                    "options": [{"key": "list", "label": "使用不可变列表"}]}
        candidate_file = Path(package["candidateDirectory"]) / "question.json"
        candidate_file.write_text(json.dumps(question), encoding="utf-8")
        tool(5, "submit", request_id="question-submit", node=0, serial=0)
        answer = tool(6, "ask_user", node=0, serial=0)
        assert len(questions) == 1 and questions[0]["threadId"] == thread, questions
        assert question["prompt"] in questions[0]["message"]
        assert answer["decision"] == {"answered": {"serial": 0, "applicable": True}}, answer
        status = tool(7, "status")
        assert len(status["handoff"]["decisions"]) == 1
        assert status["handoff"]["decisions"][0]["answer"]["comment"] == "本次中文答复仅用于协议验收"
        assert status["handoff"]["decisions"][0]["applicableNow"]
        assert answer["handoff"]["decisions"] == status["handoff"]["decisions"]
        assert answer["status"]["head"] == answer["handoff"]["currentHead"]
        assert tool(9, "status") == status
        result = {"status": "passed", "nativeThread": thread, "modelTurns": 0,
                  "workerMode": "user-approved full access; workspace rules are instructions",
                  "userReplies": "simulated test client", "checks": ["native MCP routing", "same-task user elicitation", "durable answer", "repeatable complete handoff"]}
        (root / "results.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
        print(json.dumps(result), flush=True)
    finally:
        native.stdin.close()
        try:
            native.wait(timeout=5)
        except subprocess.TimeoutExpired:
            native.terminate()
            native.wait(timeout=5)
        events.close()
        errors.close()


if __name__ == "__main__":
    main()
