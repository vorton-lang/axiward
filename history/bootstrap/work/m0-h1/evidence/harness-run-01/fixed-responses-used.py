"""Deterministic local Responses fixture for the unmodified Codex tool router.

No model inference, delegation, or external API is used. Only predefined calls
against the H1 synthetic laboratory are emitted. Request prompts are not logged.
"""
import argparse
import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


parser = argparse.ArgumentParser()
parser.add_argument("--cases", type=Path, required=True)
parser.add_argument("--evidence", type=Path, required=True)
args = parser.parse_args()
cases = json.loads(args.cases.read_text(encoding="utf-8-sig"))
args.evidence.mkdir(parents=True, exist_ok=True)
request_number = 0


def tool_names(tools, namespace=None):
    result = []
    for tool in tools:
        if tool.get("type") == "namespace":
            result.extend(tool_names(tool.get("tools", []), tool.get("name")))
        else:
            result.append({"name": tool.get("name"), "type": tool.get("type"), "namespace": namespace})
    return result


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        global request_number
        if self.path == "/stop":
            self.send_response(200)
            self.end_headers()
            threading.Thread(target=self.server.shutdown, daemon=True).start()
            return
        if self.path not in ("/responses", "/v1/responses"):
            self.send_error(404)
            return
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        number = request_number
        request_number += 1
        available = tool_names(body.get("tools", []))
        observations = [item for item in body.get("input", []) if isinstance(item, dict)
                        and item.get("type") in ("function_call_output", "custom_tool_call_output")]
        (args.evidence / f"request-{number:02d}.json").write_text(
            json.dumps({"model": body.get("model"), "tools": available,
                        "toolOutputs": observations}, ensure_ascii=False, indent=2), encoding="utf-8")
        executor = next((tool for tool in available if tool["name"] == "exec_command"), None)
        if number < len(cases) and executor:
            case = cases[number]
            item = {"type": "function_call", "id": f"fc_h1_{number}",
                    "call_id": f"call_h1_{number}", "name": "exec_command",
                    "arguments": json.dumps({"cmd": case["command"], "workdir": case["cwd"],
                                              "max_output_tokens": 1600, "yield_time_ms": 1000})}
            if executor["namespace"]:
                item["namespace"] = executor["namespace"]
        else:
            item = {"type": "message", "id": f"msg_h1_{number}", "role": "assistant",
                    "content": [{"type": "output_text", "text": "Fixed H1 tool sequence complete."}]}
        response = {"id": f"resp_h1_{number}", "object": "response", "status": "completed",
                    "model": "axiward-h1-fixture", "output": [item],
                    "usage": {"input_tokens": 0, "output_tokens": 0, "total_tokens": 0}}
        events = [
            {"type": "response.created", "response": {**response, "status": "in_progress", "output": []}},
            {"type": "response.output_item.done", "output_index": 0, "item": item},
            {"type": "response.completed", "response": response},
        ]
        payload = "".join("data: " + json.dumps(event) + "\n\n" for event in events).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)
        self.wfile.flush()


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
(args.evidence / "endpoint.json").write_text(json.dumps({"port": server.server_port}), encoding="utf-8")
print(json.dumps({"port": server.server_port}), flush=True)
server.serve_forever()
server.server_close()
