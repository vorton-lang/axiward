"""Diagnose native sandbox concurrency without running a product verifier.

Creates fresh probe directories and retains records. Never changes ACLs itself.
"""
import argparse
import ctypes
from ctypes import wintypes
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time


def token_identity():
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    advapi = ctypes.WinDLL("advapi32", use_last_error=True)
    kernel.GetCurrentProcess.restype = wintypes.HANDLE
    advapi.OpenProcessToken.argtypes = [wintypes.HANDLE, wintypes.DWORD, ctypes.POINTER(wintypes.HANDLE)]
    advapi.GetTokenInformation.argtypes = [wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p,
                                         wintypes.DWORD, ctypes.POINTER(wintypes.DWORD)]
    advapi.ConvertSidToStringSidW.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_void_p)]
    kernel.LocalFree.argtypes = [ctypes.c_void_p]
    kernel.CloseHandle.argtypes = [wintypes.HANDLE]
    token = wintypes.HANDLE()
    if not advapi.OpenProcessToken(kernel.GetCurrentProcess(), 8, ctypes.byref(token)):
        raise ctypes.WinError(ctypes.get_last_error())

    class SidAttributes(ctypes.Structure):
        _fields_ = [("sid", ctypes.c_void_p), ("attributes", wintypes.DWORD)]

    class TokenGroups(ctypes.Structure):
        _fields_ = [("count", wintypes.DWORD), ("groups", SidAttributes * 1)]

    def sid_text(sid):
        pointer = ctypes.c_void_p()
        if not advapi.ConvertSidToStringSidW(sid, ctypes.byref(pointer)):
            raise ctypes.WinError(ctypes.get_last_error())
        try:
            return ctypes.wstring_at(pointer.value)
        finally:
            kernel.LocalFree(pointer)

    def info(kind):
        size = wintypes.DWORD()
        advapi.GetTokenInformation(token, kind, None, 0, ctypes.byref(size))
        buffer = ctypes.create_string_buffer(size.value)
        if not advapi.GetTokenInformation(token, kind, buffer, size, ctypes.byref(size)):
            raise ctypes.WinError(ctypes.get_last_error())
        return buffer

    try:
        user = SidAttributes.from_buffer(info(1))
        result = {"user": sid_text(user.sid)}
        for label, kind in (("groups", 2), ("restricted", 11)):
            buffer = info(kind)
            count = wintypes.DWORD.from_buffer(buffer).value
            entries = (SidAttributes * count).from_buffer(buffer, TokenGroups.groups.offset)
            result[label] = [{"sid": sid_text(item.sid), "attributes": hex(item.attributes)}
                             for item in entries]
        return result
    finally:
        kernel.CloseHandle(token)


def child():
    result = {"cwd": str(Path.cwd()), "pid": os.getpid(), "token": token_identity(), "operations": {}}
    coordinated = os.environ.get("AXIWARD_PROBE_ACTIVE") == "1"
    result["startedNs"] = time.monotonic_ns()
    result["iterations"] = []
    for iteration in range(10 if coordinated else 1):
        suffix = str(os.getpid()) + "-" + str(iteration)
        operations = {
            "build-mkdir": lambda: Path(".lake/build-" + suffix).mkdir(),
            "build-write": lambda: Path(".lake/direct-" + suffix + ".txt").write_text("probe", encoding="utf-8"),
            "tmp-write": lambda: Path(".tmp/probe-" + suffix + ".txt").write_text("probe", encoding="utf-8"),
            "source-write": lambda: Path("forbidden-" + suffix + ".txt").write_text("probe", encoding="utf-8"),
            "private-read": lambda: Path(os.environ["AXIWARD_PROBE_PRIVATE"]).read_text(encoding="utf-8"),
        }
        observed = {}
        for name, action in operations.items():
            try:
                action()
                observed[name] = {"allowed": True}
            except OSError as error:
                observed[name] = {"allowed": False, "errno": error.errno,
                                  "winerror": getattr(error, "winerror", None), "error": str(error)}
        result["iterations"].append(observed)
        if coordinated:
            time.sleep(0.3)
    result["operations"] = result["iterations"][-1]
    result["finishedNs"] = time.monotonic_ns()
    print(json.dumps(result, ensure_ascii=False), flush=True)


def dacl(path):
    advapi = ctypes.WinDLL("advapi32", use_last_error=True)
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    advapi.GetFileSecurityW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, ctypes.c_void_p,
                                      wintypes.DWORD, ctypes.POINTER(wintypes.DWORD)]
    advapi.ConvertSecurityDescriptorToStringSecurityDescriptorW.argtypes = [
        ctypes.c_void_p, wintypes.DWORD, wintypes.DWORD, ctypes.POINTER(ctypes.c_void_p),
        ctypes.POINTER(wintypes.DWORD)]
    kernel.LocalFree.argtypes = [ctypes.c_void_p]
    size = wintypes.DWORD()
    advapi.GetFileSecurityW(str(path), 4, None, 0, ctypes.byref(size))
    buffer = ctypes.create_string_buffer(size.value)
    if not advapi.GetFileSecurityW(str(path), 4, buffer, size, ctypes.byref(size)):
        raise ctypes.WinError(ctypes.get_last_error())
    pointer = ctypes.c_void_p()
    if not advapi.ConvertSecurityDescriptorToStringSecurityDescriptorW(buffer, 1, 4, ctypes.byref(pointer), None):
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        return ctypes.wstring_at(pointer.value)
    finally:
        kernel.LocalFree(pointer)


def main():
    started = time.monotonic()
    deadline = started + 27
    parser = argparse.ArgumentParser()
    parser.add_argument("--child", action="store_true")
    parser.add_argument("--production-toolchain", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if args.child:
        child()
        return
    if args.output is None:
        parser.error("--output is required")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    codex = shutil.which("codex")
    cases = {}

    def capability_state():
        path = Path(os.environ.get("CODEX_HOME", Path.home() / ".codex")) / "cap_sid"
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
            roots = data.get("writable_root_by_path", {})
            return {"workspace": data.get("workspace"), "readonly": data.get("readonly"),
                    "rootCount": len(roots), "probeRoots": {key: value for key, value in roots.items()
                    if output.as_posix().lower() in key.replace("\\", "/").lower()}}
        except (OSError, ValueError) as error:
            return {"error": str(error)}

    def setup(name):
        project = output / name
        repo = project / "project.git"
        snapshot = project / "project.git.checks" / "run-probe" / "snapshot"
        (repo / ".git").mkdir(parents=True)
        (repo / "PRIVATE.txt").write_text("probe sentinel", encoding="utf-8")
        for directory in (".lake", ".tmp"):
            (snapshot / directory).mkdir(parents=True)
        (snapshot / "audit.json").write_text("{}", encoding="utf-8")
        (snapshot / "lake-manifest.json").write_text(json.dumps({"version": "1.2.0", "packagesDir": ".lake/packages",
            "packages": [], "name": "sandbox_probe", "lakeDir": ".lake"}), encoding="utf-8")
        (snapshot / "lakefile.toml").write_text('name = "sandbox_probe"\nversion = "0.1.0"\n', encoding="utf-8")
        rules = {":root": "read", str(repo): "deny", str(snapshot): "read",
                 str(snapshot / ".lake"): "write", str(snapshot / ".tmp"): "write",
                 str(snapshot / "audit.json"): "write", str(snapshot / "lake-manifest.json"): "write"}
        profile = "{ filesystem = { " + ", ".join(json.dumps(k) + " = " + json.dumps(v)
                    for k, v in rules.items()) + " }, network = { enabled = false } }"
        profile_name = "axiward_probe_" + name.replace("-", "_")
        command = [codex, "sandbox", "-P", profile_name, "-C", str(snapshot),
                   "-c", f"permissions.{profile_name}={profile}", "-c", 'windows.sandbox="elevated"',
                   "--", sys.executable, "-I", "-S", str(Path(__file__).resolve()), "--child"]
        env = dict(os.environ, TMP=str(snapshot / ".tmp"), TEMP=str(snapshot / ".tmp"),
                   AXIWARD_PROBE_PRIVATE=str(repo / "PRIVATE.txt"), PYTHONIOENCODING="utf-8")
        if args.production_toolchain:
            env["AXIWARD_PROBE_ACTIVE"] = "1"
            project_source = Path(__file__).resolve().parent.parent
            command = [str(args.production_toolchain.resolve() / "bin/lake.exe"), "env", "lean", "--run",
                       str(project_source / "experiments/sandbox-startup.lean"), str(repo), str(snapshot),
                       str(args.production_toolchain.resolve()), sys.executable, str(Path(__file__).resolve())]
        return command, env, snapshot

    def run(name, prepared):
        command, env, snapshot = prepared
        before = capability_state()
        start = time.monotonic()
        working = Path(__file__).resolve().parent.parent if args.production_toolchain else snapshot
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("sandbox probe exceeded its 27-second budget")
        process = subprocess.run(command, cwd=working, env=env, capture_output=True, text=True,
                                 encoding="utf-8", timeout=remaining, creationflags=subprocess.CREATE_NO_WINDOW)
        stdout, stderr = process.stdout, process.stderr
        record = {"command": command, "exitCode": process.returncode,
                  "seconds": round(time.monotonic() - start, 3),
                  "stdout": stdout, "stderr": stderr,
                  "capabilityBefore": before, "capabilityAfter": capability_state()}
        try:
            record["probe"] = json.loads(stdout)
        except ValueError:
            pass
        if "probe" in record:
            restricted = {item["sid"] for item in record["probe"]["token"]["restricted"]}
            record["directoryAcls"] = {}
            for name_part in (".lake", ".tmp"):
                sddl = dacl(snapshot / name_part)
                record["directoryAcls"][name_part] = {"sddl": sddl,
                    "matchingRestrictedSids": sorted(restricted.intersection(re.findall(r"S-\d+(?:-\d+)+", sddl)))}
        (output / (name + ".json")).write_text(json.dumps(record, ensure_ascii=False, indent=2), encoding="utf-8")
        return record

    if args.production_toolchain:
        prepared = {name: setup(name) for name in ("coordinated-a", "coordinated-b", "coordinated-c")}
        print("START three cold sandboxes with serialized startup and overlapping bodies", flush=True)
        with ThreadPoolExecutor(max_workers=3) as executor:
            futures = {name: executor.submit(run, name, case) for name, case in prepared.items()}
            for name, future in futures.items():
                cases[name] = future.result()
        (output / "results.json").write_text(json.dumps(cases, ensure_ascii=False, indent=2), encoding="utf-8")
        assert all(case["exitCode"] == 0 for case in cases.values()), {name: case["stderr"] for name, case in cases.items()}
        assert all("probe" in case for case in cases.values()), {name: case["stderr"] for name, case in cases.items()}
        probes = [case["probe"] for case in cases.values()]
        overlap = min(p["finishedNs"] for p in probes) - max(p["startedNs"] for p in probes)
        expected = {"build-mkdir": True, "build-write": True, "tmp-write": True,
                    "source-write": False, "private-read": False}
        mismatches = [{"case": name, "iteration": index, "observed": observed}
                      for name, case in cases.items() for index, observed in enumerate(case["probe"]["iterations"])
                      if {key: value["allowed"] for key, value in observed.items()} != expected]
        summary = {"seconds": round(time.monotonic() - started, 3),
                   "overlapSeconds": round(overlap / 1e9, 3), "mismatches": mismatches,
                   "cases": len(cases), "iterationsPerCase": 10}
        (output / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")
        print(json.dumps(summary, ensure_ascii=False), flush=True)
        assert overlap > 0 and not mismatches, summary
        return

    for name in ("serial-a", "serial-b"):
        print("START", name, flush=True)
        cases[name] = run(name, setup(name))
        print(name, cases[name].get("probe", {}).get("operations", cases[name]["stderr"]), flush=True)
    prepared = {name: setup(name) for name in ("parallel-a", "parallel-b")}
    print("START parallel pair", flush=True)
    with ThreadPoolExecutor(max_workers=2) as executor:
        futures = {name: executor.submit(run, name, case) for name, case in prepared.items()}
        for name, future in futures.items():
            cases[name] = future.result()
            print(name, cases[name].get("probe", {}).get("operations", cases[name]["stderr"]), flush=True)
    for name, case in prepared.items():
        cases["warm-" + name] = run("warm-" + name, case)
        print("warm-" + name, cases["warm-" + name].get("probe", {}).get("operations", {}), flush=True)
    print("START warmed parallel pair", flush=True)
    with ThreadPoolExecutor(max_workers=2) as executor:
        futures = {name: executor.submit(run, "repeat-" + name, case) for name, case in prepared.items()}
        for name, future in futures.items():
            cases["repeat-" + name] = future.result()
            print("repeat-" + name, cases["repeat-" + name].get("probe", {}).get("operations", {}), flush=True)
    (output / "results.json").write_text(json.dumps(cases, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps({"seconds": round(time.monotonic() - started, 3), "cases": len(cases)}), flush=True)


if __name__ == "__main__":
    main()
