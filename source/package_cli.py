"""Build a local Windows release from one clean source commit; never overwrite output."""
import argparse
import hashlib
import json
import os
import shutil
import subprocess
import time
from pathlib import Path


README = r"""# Axiward 本机 CLI

使用本机 Git、Python 3.11+、Codex CLI 与完整 Lean 4.34.0 工具链。
在同一终端确认 `codex --version` 成功；版本和文件摘要见 `release.json`。
`examples/` 提供普通规格包和候选，控制器没有项目专用注册分支。

用户先审核规格正文、Lean 命题与实际实现/产物的对应，再通过用户入口加载：

```powershell
$app = (Get-Location).Path
$cli = Join-Path $app 'axiward.exe'
$lean = 'C:\path\to\lean-4.34.0-windows'
$policy = 'C:\path\to\confirmed-policy'
$repo = 'C:\path\to\new-managed-project'
& $cli validate-policy $policy
& $cli init $repo $policy $lean
& $cli session $repo "$repo\.view\worker-1" (Get-Command python).Source "$app\adapter\server.py"
& $cli overview $repo
```

`validate-policy` 只检查接入格式；编译或核验成功不能代替用户的语义确认。
`acceptance.json` 声明明确版本、固定材料、独立规格模块、候选文件映射、命题/实际参数/证明、构建目标与产物。
加载时整个规格包进入 Git；后续核验和工作交接使用其内容版本。
外部草稿编辑不切换生效版本。变更先 `revise-preview`，用户审核后把其 `reviewToken` 交给 `revise`。

已有原仓可由用户以 `adopt <repo> <reviewed-HEAD> <policy> <lean>` 接入已提交的 `source/` 基线；
它只登记未验证输入，不宣布产品完成。本发行物不自动纳管任何仓库。

Worker 候选写在包根，路径由规格包声明。固定规格与全部验收材料在 `.axiward/policy/`；
`AGENTS.md` 提供当前动作，`.codex/` 保存连接配置，`.axiward/` 保存视图、按需材料及临时文件。
一个视图绑定一个包，新包使用新的 `.view/` 目录。状态和交接来自正式 Git 历史，不读取草稿作为当前规格。
Worker 使用完全访问权限并遵守说明；候选核验沿用原生 harness，需已有 `CodexSandboxUsers` 身份。

精化候选通过 `Plan.Relation` 证明实际子命题蕴含父命题；条目索引只选择命题。
正确示例的接纳说明统一接入链可工作，不代表完整 Axiward 产品根已经形式化、获用户确认或通过验收。
完整产品根不会随发行物自动注册。

完成后 `deliver <repo>` 导出到新的根内 `delivery/`，不覆盖既有输出。
`.checks/`、`.view/` 与 `delivery/` 不参与正式状态。旧项目和目录不会自动迁移或清理。
"""


def runtime_files(source):
    examples = []
    for path in (source / "examples").rglob("*"):
        if not path.is_file() or any(part.startswith(".") for part in path.relative_to(source).parts):
            continue
        if path.name == "lean-toolchain" or path.suffix in {".lean", ".json", ".toml"}:
            examples.append(path.relative_to(source).as_posix())
    return ["adapter/server.py", "adapter/native.py", "LICENSE", *sorted(examples)]


def main():
    started = time.monotonic()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--toolchain", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    source = Path(__file__).resolve().parent
    repository = source.parent
    toolchain = args.toolchain.resolve()
    output = args.output.resolve()
    files_to_package = runtime_files(source)
    if os.name != "nt":
        raise RuntimeError("this release supports Windows only")
    if output.exists():
        raise RuntimeError("release output must be a new directory")
    if not output.is_relative_to(repository / ".work"):
        raise RuntimeError("release output must be under this repository's ignored .work directory")

    def run(*command):
        remaining = 27 - (time.monotonic() - started)
        if remaining <= 0:
            raise TimeoutError("packaging exceeded its 27-second budget")
        process = subprocess.Popen(list(map(str, command)), cwd=source,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   text=True, encoding="utf-8", creationflags=subprocess.CREATE_NO_WINDOW)
        try:
            stdout, stderr = process.communicate(timeout=remaining)
        except subprocess.TimeoutExpired:
            subprocess.run(["taskkill", "/PID", str(process.pid), "/T", "/F"],
                           capture_output=True, timeout=1, creationflags=subprocess.CREATE_NO_WINDOW)
            raise TimeoutError("packaging exceeded its 27-second budget")
        if process.returncode:
            raise RuntimeError(stdout + stderr)
        return stdout.strip()

    def clean_commit():
        if run("git", "status", "--porcelain"):
            raise RuntimeError("commit source changes before packaging")
        return run("git", "rev-parse", "HEAD")

    commit = clean_commit()
    lean_version = run(toolchain / "bin/lean.exe", "--version")
    if "version 4.34.0," not in lean_version:
        raise RuntimeError("the release requires the complete Lean 4.34.0 toolchain")
    run(toolchain / "bin/lake.exe", "build", "axiward")
    if clean_commit() != commit:
        raise RuntimeError("source changed while building")
    executable = source / ".lake/build/bin/axiward.exe"
    version = run(executable, "--version")
    for manifest in sorted((source / "examples").rglob("acceptance.json")):
        run(executable, "validate-policy", manifest.parent)
    output.mkdir(parents=True, exist_ok=False)
    shutil.copyfile(executable, output / "axiward.exe")
    for relative in files_to_package:
        target = output / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile((repository if relative == "LICENSE" else source) / relative, target)
    (output / "README.md").write_text(README, encoding="utf-8")
    paths = ["axiward.exe", *files_to_package, "README.md"]
    files = []
    for relative in paths:
        path = output / relative
        with path.open("rb") as stream:
            digest = hashlib.file_digest(stream, "sha256").hexdigest()
        files.append({"path": relative, "bytes": path.stat().st_size, "sha256": digest})
    if clean_commit() != commit:
        raise RuntimeError("source changed while packaging; output is incomplete")
    manifest = {"version": version, "sourceCommit": commit,
                "leanVersion": lean_version, "platform": "windows-x64", "files": files}
    (output / "release.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"release": str(output), "sourceCommit": commit,
                      "executableSha256": files[0]["sha256"],
                      "seconds": round(time.monotonic() - started, 3)}))


if __name__ == "__main__":
    main()
