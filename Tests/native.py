"""Unmodified Codex router + MCP elicitation. No model turns or inference.

The ephemeral native context is a protocol fixture. User replies are simulated
by this client and are not user approval of a real product.
"""
import argparse
import json
import os
import queue
import shutil
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
    repo, view = root / "project.git", root / "view"

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

    def native_command(number, argv, cwd, profile):
        params = {"command": list(map(str, argv)), "cwd": str(cwd), "timeoutMs": 30000}
        if profile is not None:
            params["permissionProfile"] = profile
        send({"id": number, "method": "command/exec", "params": params})
        return response(number)

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
        private_file = repo / "private-question.json"
        private_file.write_text(json.dumps(question), encoding="utf-8")
        os.link(private_file, candidate_file)
        refusal = tool(40, "submit", success=False, request_id="linked-submit", node=0, serial=0)
        assert "one link" in refusal["error"], refusal
        candidate_file.unlink()  # One synthetic input file, not a directory cleanup.
        candidate_file.write_text(json.dumps(question), encoding="utf-8")
        tool(5, "submit", request_id="question-submit", node=0, serial=0)

        checker = Path(str(repo) + ".checks")
        checker.mkdir(exist_ok=True)
        (checker / "private.txt").write_text("private-checker-input", encoding="utf-8")
        external = root / "external.txt"
        external.write_text("external research remains readable", encoding="utf-8")
        probe = """import json,sys
from pathlib import Path
view,repo,exe,adapter,checker,external=map(Path,sys.argv[1:]); result={}
for name,path,write in [('work-write',view/'work'/'ok.txt',True),('config-write',view/'.codex'/'config.toml',True),('repo-read',repo/'HEAD',False),('repo-write',repo/'forged.txt',True),('controller-read',exe,False),('adapter-read',adapter,False),('checker-read',checker/'private.txt',False),('external-read',external,False)]:
 try:
  if write: path.write_text('untrusted write',encoding='utf-8')
  else: path.read_bytes()
  result[name]='allowed'
 except OSError: result[name]='denied'
print(json.dumps(result))
"""
        access = native_command(41, [sys.executable, "-c", probe, view, repo, exe, source / "adapter/server.py", checker, external],
                                view / "work", None)
        assert access["exitCode"] == 0, access
        access_result = json.loads(access["stdout"])
        assert access_result == {"work-write":"allowed", "config-write":"denied", "repo-read":"denied",
                                 "repo-write":"denied", "controller-read":"denied", "adapter-read":"denied",
                                 "checker-read":"denied", "external-read":"allowed"}, access_result
        copied = view / "work/copied-controller.exe"
        shutil.copyfile(exe, copied)
        attack = native_command(42, [copied, "decide", repo, "forged-user-answer", "0", "0", "list", "not a user"],
                                view / "work", None)
        assert attack["exitCode"] != 0, attack
        state = cli("status", repo)
        assert state["state"]["workflow"]["decisions"][0]["answer"] is None
        unrelated = root / "unrelated-task"
        unrelated.mkdir()
        other = native_command(43, [sys.executable, "-c", "from pathlib import Path; Path('ok.txt').write_text('other task works')"],
                               unrelated, ":workspace")
        assert other["exitCode"] == 0 and (unrelated / "ok.txt").exists(), other
        (root / "isolation.json").write_text(json.dumps({"access":access_result, "copiedController":attack,
                                                        "unrelatedTask":other}, ensure_ascii=False, indent=2), encoding="utf-8")
        answer = tool(6, "ask_user", node=0, serial=0)
        assert len(questions) == 1 and questions[0]["threadId"] == thread, questions
        assert question["prompt"] in questions[0]["message"]
        assert answer["decision"] == {"answered": {"serial": 0, "applicable": True}}, answer
        status = tool(7, "status")
        assert len(status["inbox"]) == 1
        assert status["inbox"][0]["decision"]["answer"]["comment"] == "本次中文答复仅用于协议验收"
        tool(8, "acknowledge", request_id="ack", node=0, serial=0)
        assert tool(9, "status")["inbox"] == []
        result = {"status": "passed", "nativeThread": thread, "modelTurns": 0,
                  "userReplies": "simulated test client", "checks": ["native MCP routing", "same-task user elicitation", "durable answer", "notification acknowledgement",
                    "worker cannot read or write canonical storage", "worker cannot alter configuration or read controller/checker files",
                    "copied controller cannot forge user answer", "hard-linked input rejected by opened-handle check", "external reads and unrelated task remain available"]}
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
