"""R0 acceptance through the actual stdio adapter and native command/exec.

User replies here are explicitly simulated by the test client, not approvals of
any real product. No LLM inference or external API service is used.
"""
import argparse
import json
import queue
import shutil
import subprocess
import sys
import threading
import time
from pathlib import Path


class Client:
    def __init__(self, source, exe, repo, view, worker, events):
        self.events = events
        self.messages = queue.Queue()
        self.number = 0
        self.errors = (view / "transport-stderr.txt").open("w", encoding="utf-8")
        self.process = subprocess.Popen(
            [sys.executable, str(source / "adapter/server.py"), "--exe", str(exe),
             "--repo", str(repo), "--view", str(view), "--worker", worker],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.errors,
            text=True, encoding="utf-8", creationflags=subprocess.CREATE_NO_WINDOW)

        def reader():
            for line in self.process.stdout:
                self.messages.put(json.loads(line))
            self.messages.put(None)

        threading.Thread(target=reader, daemon=True).start()
        self.send({"id": 0, "method": "initialize", "params": {
            "protocolVersion": "2025-03-26", "capabilities": {"elicitation": {}},
            "clientInfo": {"name": "axiward-acceptance", "version": "0.1"}}})
        assert self.receive()["result"]["serverInfo"]["name"] == "axiward"

    def send(self, item):
        self.events.write(json.dumps({"sent": item}, ensure_ascii=False) + "\n")
        self.events.flush()
        self.process.stdin.write(json.dumps(item) + "\n")
        self.process.stdin.flush()

    def receive(self):
        item = self.messages.get(timeout=240)
        assert item is not None, "MCP server exited"
        self.events.write(json.dumps({"received": item}, ensure_ascii=False) + "\n")
        self.events.flush()
        return item

    def start(self, name, args):
        self.number += 1
        self.send({"id": self.number, "method": "tools/call", "params": {"name": name, "arguments": args}})
        return self.number

    def call(self, name, success=True, **args):
        call_id = self.start(name, args)
        item = self.receive()
        assert item["id"] == call_id, item
        result = item["result"]
        value = json.loads(result["content"][0]["text"])
        assert not result["isError"] == success, value
        return value

    def close(self):
        self.process.stdin.close()
        self.process.wait(timeout=10)
        self.errors.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--toolchain", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    source = Path(__file__).resolve().parent.parent
    exe = source / ".lake/build/bin/axiward.exe"
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    repo = output / "project.git"
    view = output / "worker-a"
    view2 = output / "worker-b"
    commands = []
    passed = []

    def cli(*args, success=True):
        run = subprocess.run([str(exe), *map(str, args)], capture_output=True, text=True,
                             encoding="utf-8", timeout=240, creationflags=subprocess.CREATE_NO_WINDOW)
        value = json.loads(run.stdout)
        commands.append({"args": list(map(str, args)), "exitCode": run.returncode, "result": value})
        (output / "commands.json").write_text(json.dumps(commands, ensure_ascii=False, indent=2), encoding="utf-8")
        assert (run.returncode == 0) == success, value
        return value

    def ok(name):
        passed.append(name)
        (output / "results.json").write_text(json.dumps({"status": "running", "passed": passed}, indent=2), encoding="utf-8")
        print("PASS:", name, flush=True)

    def write(path, value):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value, ensure_ascii=False) if not isinstance(value, str) else value, encoding="utf-8")

    def candidate(destination, bad=False):
        destination.mkdir(parents=True, exist_ok=True)
        for name in ("Queue.lean", "Proofs.lean"):
            text = (source / "examples/fifo/candidate" / name).read_text(encoding="utf-8")
            if bad and name == "Queue.lean":
                text = text.replace("q.items ++ [item]", "item :: q.items")
            (destination / name).write_text(text, encoding="utf-8")

    cli("init", repo, source / "examples/fifo/policy", args.toolchain.resolve())
    session = cli("session", repo, view, Path(sys.executable), source / "adapter/server.py")
    session2 = cli("session", repo, view2, Path(sys.executable), source / "adapter/server.py")
    assert session["worker"] != session2["worker"]
    events = (output / "mcp-events.jsonl").open("w", encoding="utf-8")
    client = Client(source, exe, repo, view, session["worker"], events)
    second = Client(source, exe, repo, view2, session2["worker"], events)
    try:
        client.send({"id": "list", "method": "tools/list"})
        tools = client.receive()["result"]["tools"]
        assert not {"decide", "revise", "observe", "run-experiment", "inbox", "acknowledge"} & {x["name"] for x in tools}
        start = cli("status", repo)["head"]
        client.call("decide", success=False, choice="yes", source="user")
        client.call("next", success=False, request_id="evil", owner="other")
        assert cli("status", repo)["head"] == start
        ok("strict worker boundary; admin actions and forged identities are unavailable")

        pkg = client.call("next", request_id="explore", node=0, action="explore")
        assert pkg["serial"] == 0
        directory = Path(pkg["candidateDirectory"]).parent
        plan = {"question": "Does the implementation preserve FIFO?", "maxRuns": 2,
                "stopWhen": "Compare a failing candidate with a proved candidate, then stop."}
        write(directory / "candidate/exploration.json", plan)
        client.call("prepare", request_id="prepare", node=0, serial=0)
        prepared = cli("status", repo)
        assert prepared["state"]["published"] is None
        client.call("view_add", success=False, node=0, serial=0, resource="../../controller-toolchain.json")
        cli("access", repo, "deny-spec", "node/0/spec", "deny")
        client.call("view_add", success=False, node=0, serial=0, resource="node/0/spec")
        cli("access", repo, "allow-spec", "node/0/spec", "allow")
        material = Path(client.call("view_add", node=0, serial=0, resource="node/0/spec")["path"])
        assert material.read_text(encoding="utf-8") == (source / "examples/fifo/policy/Axiward/Spec.lean").read_text(encoding="utf-8")
        candidate(directory / "trials/bad", bad=True)
        candidate(directory / "trials/good")
        client.call("experiment", request_id="trial-bad", node=0, serial=0, trial="bad")
        result = cli("status", repo)["state"]["workflow"]["operations"][0]
        assert "rejected" in result["result"], result
        diagnostics = client.call("evidence", node=0, serial=0)
        raw = Path(diagnostics["path"]).read_text(encoding="utf-8")
        assert "codex-command-exec" in raw and "01-build" in raw and "error" in raw.lower()
        assert cli("status", repo)["rootClosed"] is False
        client.call("experiment", request_id="trial-good", node=0, serial=0, trial="good")
        after = cli("status", repo)
        assert "passed" in after["state"]["workflow"]["operations"][1]["result"]
        assert after["rootClosed"] is False
        assert client.call("experiment", request_id="trial-good", node=0, serial=0, trial="good")["replayed"]
        assert cli("status", repo)["head"] == after["head"]
        client.call("experiment", success=False, request_id="trial-extra", node=0, serial=0, trial="good")
        write(directory / "candidate/report.md", "The bad candidate prepends. The registered checker rejected its proof. Use the FIFO version next.")
        client.call("conclude", request_id="report", node=0, serial=0)
        ok("native experiments: raw results, two-run budget, replay prevention, observations never publish")

        pkg = client.call("next", request_id="question", node=0, action="requestDecision")
        directory = Path(pkg["candidateDirectory"])
        write(directory / "question.json", {"prompt": "Which implementation should the next package use?",
              "subject": "Current FIFO specification; this records a preference only.",
              "options": [{"key": "list", "label": "Simple immutable list"}, {"key": "other", "label": "Explore another representation"}]})
        client.call("submit", request_id="question-submit", node=0, serial=1)
        cli("pause", repo, "pause-for-user", "User away; preserve waiting package")
        assert cli("overview", repo)["map"][0]["phase"] == "waiting-user"
        call_id = client.start("ask_user", {"node": 0, "serial": 1})
        question = client.receive()
        assert question["method"] == "elicitation/create"
        client.send({"id": question["id"], "result": {"action": "accept", "content": {"choice": "list"}}})
        response = client.receive()
        assert response["id"] == call_id
        # Discard the result and restart: complete context is delivered again.
        client.close()
        client = Client(source, exe, repo, view, session["worker"], events)
        state = client.call("status")
        assert state["handoff"]["decisions"][0]["applicableNow"] is True
        assert state["status"]["paused"] and not state["status"]["rootClosed"]
        client.call("next", request_id="blocked")
        assert cli("status", repo)["state"]["active"] is None
        assert client.call("status") == state
        assert second.call("status")["handoff"] == state["handoff"]
        cli("resume", repo, "resume-user")
        ok("user-only elicitation survives pause and lost context; another identity receives the complete decision")

        pkg = client.call("next", request_id="route", node=0, action="refine")
        directory = Path(pkg["candidateDirectory"])
        for path in (source / "examples/fifo/refinement").iterdir():
            shutil.copyfile(path, directory / path.name)
        client.call("submit", request_id="route-submit", node=0, serial=2)
        left = client.call("next", request_id="left", node=1, action="execute")
        right = second.call("next", request_id="right", node=2, action="execute")
        assert right["handoff"]["decisions"][0]["applicableNow"]
        assert right["handoff"]["decisions"][0]["node"] == 0
        assert right["handoff"]["decisions"][0]["sourceOwner"] == session["worker"]
        assert any(c["node"] == 0 and c["relation"] == "current-ancestor" for c in right["handoff"]["contexts"])
        second.call("submit", success=False, request_id="steal", node=1, serial=0)
        candidate(Path(left["candidateDirectory"]))
        candidate(Path(right["candidateDirectory"]))
        cli("pause", repo, "pause-during-draft", "exercise save and recovery")
        client.call("submit", success=False, request_id="left-submit", node=1, serial=0)
        sealed = cli("status", repo)
        assert "checking" in sealed["nodes"][1]["domain"]["active"]["phase"]
        cli("resume", repo, "resume-draft")
        recovered = client.call("resume", node=1, serial=0)
        assert recovered["status"]["head"] == recovered["handoff"]["currentHead"]
        assert recovered["snapshot"] == left["snapshot"]
        assert not cli("overview", repo)["complete"]
        second.call("submit", request_id="right-submit", node=2, serial=0)
        final = cli("overview", repo)
        assert final["complete"] and final["rootClosed"]
        delivery = output / "delivery"
        receipt = cli("deliver", repo, delivery)
        program = subprocess.run([str(delivery / ".lake/build/bin/fifo_demo.exe"), "2", "a", "b", "c"],
                                 capture_output=True, text=True, encoding="utf-8", timeout=10)
        assert program.returncode == 0
        assert "enqueue c: accepted=false" in program.stdout
        assert program.stdout.index("value=a") < program.stdout.index("value=b")
        (output / "delivered-program.txt").write_text(program.stdout, encoding="utf-8")
        ok("four-action lifecycle, two worker views, sealed recovery, automatic composition and runnable delivery")

        # Race the real verifier with cancellation. A passing but late result must
        # be archived as history, not admitted or discarded as an IO exception.
        faults = output / "faults.git"
        cli("init", faults, source / "examples/fifo/policy", args.toolchain.resolve())
        cli("begin", faults, "late-begin", "worker")
        cli("submit", faults, "late-submit", "worker", 0, source / "examples/fifo/candidate")
        checking = subprocess.Popen([str(exe), "check", str(faults), "late-check", "0"],
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                    encoding="utf-8", creationflags=subprocess.CREATE_NO_WINDOW)
        deadline = time.monotonic() + 60
        while not list(Path(str(faults) + ".checks").glob("run-*/input.json")):
            assert checking.poll() is None and time.monotonic() < deadline, "verifier did not start"
            time.sleep(0.05)
        cli("cancel", faults, "late-cancel", "worker", 0, "cancel while proof runs")
        stdout, stderr = checking.communicate(timeout=180)
        assert checking.returncode == 0, (stdout, stderr)
        assert json.loads(stdout) == {"archived": {"serial": 0}}, stdout
        late = cli("status", faults)
        assert not late["rootClosed"] and late["state"]["active"] is None

        cli("begin", faults, "lost-begin", "worker", 0, "explore")
        proposal = output / "lost-plan"
        write(proposal / "exploration.json", plan)
        cli("submit", faults, "lost-submit", "worker", 1, proposal)
        cli("check", faults, "lost-prepare", 1)
        intent = cli("start-experiment", faults, "lost-intent", "worker", 0, 1, source / "examples/fifo/candidate")
        assert not intent["replayed"]
        cli("cancel", faults, "lost-cancel", "worker", 1, "disconnect after intent")
        replay = cli("start-experiment", faults, "lost-intent", "worker", 0, 1, source / "examples/fifo/candidate")
        assert replay["replayed"] and replay["operation"]["result"] is None
        assert cli("overview", faults)["pendingOperations"] == 1
        cli("reconcile", faults, "lost-reconcile", 0, "lost-intent", "Fixture never dispatched a native process; no process is running")
        assert cli("overview", faults)["pendingOperations"] == 0
        assert not cli("overview", faults)["complete"]
        ok("real verification cancellation archives late evidence; lost intent is never replayed and requires reconciliation")
        (output / "results.json").write_text(json.dumps({"status": "passed", "passed": passed,
            "delivery": receipt, "native": "actual Codex command/exec", "userReplies": "simulated protocol client"}, indent=2), encoding="utf-8")
    finally:
        client.close()
        second.close()
        events.close()


if __name__ == "__main__":
    main()
