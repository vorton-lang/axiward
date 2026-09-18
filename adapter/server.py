"""Harness-owned MCP transport. All authoritative state transitions live in Lean/Git.

One launch configuration binds one worker view. No worker tool accepts
an identity, canonical path, user answer, verifier result or arbitrary command.
The current full-access worker follows workspace rules by instruction; this
transport does not provide OS isolation against direct repository access.
"""
import argparse
import ctypes
import json
import msvcrt
import os
import re
import stat
import subprocess
import sys
import uuid
from pathlib import Path

from native import execute, HIDDEN


def schema(properties=None, required=None):
    return {"type": "object", "properties": properties or {},
            "required": required if required is not None else list(properties or {}),
            "additionalProperties": False}


STRING = {"type": "string", "maxLength": 2000}
NAT = {"type": "integer", "minimum": 0}
PACKAGE = {"node": NAT, "serial": NAT}
REQUEST = {"request_id": STRING, **PACKAGE}
TOOLS = {
    "status": ("Current graph and complete project handoff: scoped decisions, attempts and outstanding work.", schema()),
    "next": ("Choose node and action from status and handoff, then request that package. Both are required for new work; omit both only to recover this workspace's existing package. After it ends, create a new session for new work.",
             schema({"request_id": STRING, "node": NAT, "action": {
                 "type": "string", "enum": ["execute", "refine", "explore", "requestDecision"]}}, ["request_id"])),
    "search": ("Search fixed node/ input materials and explicitly current/ handoff records. Access rules apply.", schema({**PACKAGE, "query": STRING})),
    "view_add": ("Export a catalog resource into the package view. Current access rules apply.", schema({**PACKAGE, "resource": STRING})),
    "evidence": ("Export actual checker diagnostics and this package's new observations into evidence.json, separate from model notes.", schema(PACKAGE)),
    "submit": ("Seal candidate/ once, check it and propagate proofs. For exploration use prepare, then conclude.", schema(REQUEST)),
    "prepare": ("Admit candidate/exploration.json before experiments (0..8 checker trials).", schema(REQUEST)),
    "resume": ("Resume checking the same sealed submission after interruption.", schema(PACKAGE)),
    "experiment": ("Run trials/<trial>/Queue.lean + Proofs.lean through the native harness. Records intent first; never replays lost work.",
                   schema({**REQUEST, "trial": STRING})),
    "conclude": ("Seal candidate/report.md as exploration interpretation; does not close the goal.", schema(REQUEST)),
    "cancel": ("End your active package; preserve observations and outstanding operations.", schema({**REQUEST, "reason": STRING})),
    "ask_user": ("Present the already registered question through the separate user channel. No answer argument exists.", schema(PACKAGE)),
}


class Adapter:
    def __init__(self, exe, repo, view, worker):
        self.exe, self.repo, self.view = map(lambda p: Path(p).resolve(), (exe, repo, view))
        self.worker = worker
        if self.view.parent != self.repo / ".view":
            raise ValueError("worker workspace must be a direct child of the project's .view directory")
        self.git = self.repo / ".git"
        if not self.git.is_dir():
            raise ValueError("managed project must have its own .git directory")
        self.pending = {}
        self.elicitation = False
        self.audit = self.git / "axiward-transport" / (uuid.uuid4().hex + ".jsonl")
        self.audit.parent.mkdir(exist_ok=True)

    def cli(self, *args):
        run = subprocess.run([str(self.exe), *map(str, args)], capture_output=True,
                             text=True, encoding="utf-8", timeout=240, creationflags=HIDDEN)
        try:
            result = json.loads(run.stdout)
        except ValueError as exc:
            raise RuntimeError("controller did not return JSON; inspect its logs") from exc
        if run.returncode:
            raise RuntimeError(result.get("error", str(result)))
        return result

    def request_id(self, value):
        if not value or len(value) > 160:
            raise ValueError("request_id must contain 1..160 characters; reuse it on retry")
        return self.worker + "/" + value

    def package(self, node, serial):
        # Ownership is checked from canonical allocation history, not local files.
        package = self.cli("package-info", self.repo, self.worker, node, serial)
        directory = (self.view / "work").resolve()
        if not directory.is_relative_to(self.view):
            raise ValueError("package view escapes its root")
        return package["domain"], directory

    def package_view(self, node, serial):
        # Current status and handoff come from the same controller load. The
        # exported input files still use the allocation's immutable snapshot.
        return self.cli("package-view", self.repo, self.worker, self.view, node, serial)

    def local(self, directory, *parts):
        path = directory.joinpath(*parts).resolve()
        if not path.is_relative_to(directory) or not path.is_relative_to(self.view):
            raise ValueError("candidate path escapes its assigned view")
        # Reject directory/file links in the submitted source set as well.
        if path.is_dir():
            for name in ("Queue.lean", "Proofs.lean", "Refinement.lean", "plan.json", "question.json", "exploration.json"):
                child = path / name
                if child.exists() and not child.resolve().is_relative_to(path):
                    raise ValueError("candidate contains an out-of-view link")
        return path

    def read_input(self, file, allowed_root):
        """Validate the opened handle, not just a path checked before opening it.

        Checking the opened handle keeps junction/symlink swaps from changing
        which source the adapter seals. Hard links are refused because their
        display path alone cannot establish where the underlying file came from.
        """
        descriptor = os.open(file, os.O_RDONLY | os.O_BINARY | os.O_NOINHERIT)
        try:
            info = os.fstat(descriptor)
            if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
                raise ValueError("input must be a regular file with one link")
            final_name = ctypes.WinDLL("kernel32", use_last_error=True).GetFinalPathNameByHandleW
            final_name.argtypes = [ctypes.c_void_p, ctypes.c_wchar_p, ctypes.c_uint32, ctypes.c_uint32]
            final_name.restype = ctypes.c_uint32
            buffer = ctypes.create_unicode_buffer(32768)
            length = final_name(msvcrt.get_osfhandle(descriptor), buffer, len(buffer), 0)
            if not length or length >= len(buffer):
                raise OSError("cannot establish input handle location")
            name = buffer.value.removeprefix("\\\\?\\")
            if name.startswith("UNC\\"):
                name = "\\\\" + name[4:]
            actual = Path(name)
            if not actual.is_relative_to(allowed_root) or not actual.is_relative_to(self.view / "work"):
                raise ValueError("opened input escapes the assigned work area")
            with os.fdopen(descriptor, "rb", closefd=False) as stream:
                return stream.read()
        finally:
            os.close(descriptor)

    def stage(self, directory, names, *, missing_allowed=False):
        directory = self.local(directory)
        captured = {}
        for name in names:
            try:
                captured[name] = self.read_input(directory / name, directory)
            except FileNotFoundError:
                if not missing_allowed:
                    raise
        destination = self.git / "axiward-inbox" / uuid.uuid4().hex
        destination.mkdir(parents=True)
        for name, content in captured.items():
            (destination / name).write_bytes(content)
        return destination

    def validate(self, name, data):
        if name not in TOOLS or not isinstance(data, dict):
            raise ValueError("unknown worker tool")
        spec = TOOLS[name][1]
        if set(data) - set(spec["properties"]) or not set(spec["required"]) <= set(data):
            raise ValueError("unexpected or missing arguments; workers cannot set identity, answer or evidence")
        for key, value in data.items():
            field = spec["properties"][key]
            if field["type"] == "integer" and (type(value) is not int or value < 0):
                raise ValueError(key + " must be a nonnegative integer")
            if field["type"] == "string" and (not isinstance(value, str) or len(value) > 2000):
                raise ValueError(key + " must be a short string")
            if "enum" in field and value not in field["enum"]:
                raise ValueError("unknown " + key)

    def call(self, name, data, call_id):
        self.validate(name, data)
        if name == "status":
            return self.cli("worker-status", self.repo, self.worker)
        if name == "next":
            if ("node" in data) != ("action" in data):
                raise ValueError("node and action must be provided together")
            tail = [data["node"], data["action"]] if "node" in data else []
            return self.cli("next", self.repo, self.request_id(data["request_id"]), self.worker, self.view, *tail)
        node, serial = data["node"], data["serial"]
        domain, directory = self.package(node, serial)
        if name == "search":
            return self.cli("search", self.repo, self.worker, node, serial, data["query"])
        if name == "view_add":
            return self.cli("view-add", self.repo, self.worker, self.view, node, serial, data["resource"])
        if name == "evidence":
            return self.cli("evidence", self.repo, self.worker, self.view, node, serial)
        if name in ("submit", "prepare", "resume"):
            if name == "prepare" and (domain["active"] is None or domain["active"]["action"] != "explore"):
                raise ValueError("prepare requires an exploration package")
            if name != "resume":
                assignment = self.cli("package-info", self.repo, self.worker, node, serial)["action"]
                files = {"execute": ["Queue.lean", "Proofs.lean"], "refine": ["plan.json", "Refinement.lean"],
                         "explore": ["exploration.json"], "requestDecision": ["question.json"]}[assignment]
                sealed = self.stage(self.local(directory, "candidate"), files, missing_allowed=True)
                self.cli("submit", self.repo, self.request_id(data["request_id"]), self.worker, serial,
                         sealed, node)
            result = self.cli("check", self.repo, f"{self.worker}/check/{node}/{serial}", serial, node)
            return {"result": result, **self.package_view(node, serial)}
        if name == "experiment":
            if not re.fullmatch(r"[A-Za-z0-9_-]{1,64}", data["trial"]):
                raise ValueError("trial must be a simple directory name")
            request_id = self.request_id(data["request_id"])
            sealed = self.stage(self.local(directory, "trials", data["trial"]),
                                ["Queue.lean", "Proofs.lean"], missing_allowed=True)
            intent = self.cli("start-experiment", self.repo, request_id, self.worker, node, serial,
                              sealed)
            if intent["replayed"]:
                return {**intent, **self.package_view(node, serial)}
            capture = execute([str(self.exe), "run-experiment", str(self.repo), str(node), request_id],
                              directory, self.git / "axiward-transport" / uuid.uuid4().hex)
            result = self.cli("record-experiment", self.repo, node, request_id, capture)
            return {"result": result, "closesGoal": False, **self.package_view(node, serial)}
        if name == "conclude":
            sealed = self.stage(self.local(directory, "candidate"), ["report.md"])
            result = self.cli("conclude", self.repo, self.request_id(data["request_id"]), self.worker,
                              node, serial, sealed / "report.md")
            return {"result": result, **self.package_view(node, serial)}
        if name == "cancel":
            result = self.cli("cancel", self.repo, self.request_id(data["request_id"]), self.worker, serial, data["reason"], node)
            return {"result": result, **self.package_view(node, serial)}
        if name == "ask_user":
            view = self.package_view(node, serial)
            question = next((q for q in view["handoff"]["decisions"] if q["node"] == node and q["serial"] == serial), None)
            if question is None:
                raise ValueError("question context is inaccessible; restore access before asking")
            if question["sourceOwner"] != self.worker:
                raise ValueError("no registered question for this worker")
            if question["answer"] is not None:
                return view
            if not question["pending"]:
                raise ValueError("question package has ended")
            if not self.elicitation:
                return {"waitingUser": True, **view,
                        "message": "Client does not support elicitation. Use the separate user decide command, then read status or next."}
            key = "user-" + uuid.uuid4().hex
            self.pending[key] = (call_id, node, serial)
            choices = question["question"]["options"]
            emit({"jsonrpc": "2.0", "id": key, "method": "elicitation/create", "params": {
                "mode": "form", "message": question["question"]["prompt"] + "\n" +
                question["question"]["subject"] + "\n" + "\n".join(f'{x["key"]}: {x["label"]}' for x in choices) +
                "\nEffect: record a preference for this scope. This does not prove code or change the root specification.",
                "requestedSchema": {"type": "object", "properties": {
                    "choice": {"type": "string", "enum": [x["key"] for x in choices]},
                    "comment": {"type": "string"}}, "required": ["choice"]}}})
            return None
        raise ValueError("unsupported worker tool")

    def answer(self, message):
        call_id, node, serial = self.pending.pop(message["id"])
        result = message.get("result", {})
        if result.get("action") != "accept":
            tool_result(call_id, {"waitingUser": True, "message": "No answer recorded. Question remains pending.",
                                  **self.package_view(node, serial)})
            return
        content = result.get("content", {})
        choice, comment = content.get("choice"), content.get("comment", "")
        if not isinstance(choice, str) or not isinstance(comment, str):
            tool_result(call_id, "invalid user response; question remains pending", True)
            return
        reply = self.cli("decide", self.repo, f"{self.worker}/answer/{node}/{serial}", node, serial, choice, comment)
        tool_result(call_id, {"decision": reply, **self.package_view(node, serial)})


def emit(item):
    print(json.dumps(item, ensure_ascii=False), flush=True)


def tool_result(call_id, value, error=False):
    emit({"jsonrpc": "2.0", "id": call_id, "result": {"isError": error,
          "content": [{"type": "text", "text": json.dumps(value, ensure_ascii=False)}]}})


def main():
    # MCP is UTF-8 regardless of the Windows console or system code page.
    sys.stdin.reconfigure(encoding="utf-8")
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(description=__doc__)
    for key in ("exe", "repo", "view", "worker"):
        parser.add_argument("--" + key, required=True)
    args = parser.parse_args()
    adapter = Adapter(args.exe, args.repo, args.view, args.worker)
    for line in sys.stdin:
        request = None
        try:
            request = json.loads(line)
            if "method" not in request:
                if request.get("id") in adapter.pending:
                    adapter.answer(request)
                continue
            if "id" not in request:
                continue
            method = request["method"]
            if method == "initialize":
                adapter.elicitation = "elicitation" in request["params"].get("capabilities", {})
                emit({"jsonrpc": "2.0", "id": request["id"], "result": {
                    "protocolVersion": request["params"]["protocolVersion"], "capabilities": {"tools": {}},
                    "serverInfo": {"name": "axiward", "version": "0.2.0"}}})
            elif method == "tools/list":
                emit({"jsonrpc": "2.0", "id": request["id"], "result": {"tools": [
                    {"name": name, "description": description, "inputSchema": spec}
                    for name, (description, spec) in TOOLS.items()]}})
            elif method == "ping":
                emit({"jsonrpc": "2.0", "id": request["id"], "result": {}})
            elif method == "tools/call":
                params = request.get("params", {})
                result = adapter.call(params.get("name"), params.get("arguments", {}), request["id"])
                if result is not None:
                    tool_result(request["id"], result)
            else:
                emit({"jsonrpc": "2.0", "id": request["id"], "error": {"code": -32601, "message": "method unavailable"}})
        except Exception as error:
            with adapter.audit.open("a", encoding="utf-8") as log:
                log.write(json.dumps({"request": request, "error": str(error)}, ensure_ascii=False) + "\n")
            if isinstance(request, dict) and "id" in request:
                tool_result(request["id"], {"error": str(error)}, True)
            else:
                emit({"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "invalid JSON"}})


if __name__ == "__main__":
    main()
