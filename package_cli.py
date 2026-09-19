"""Build a local Windows release from one clean source commit; never overwrite output."""
import argparse
import hashlib
import json
import os
import shutil
import subprocess
import time
from pathlib import Path


POLICY_FILES = (
    "Axiward/Spec.lean", "Gate.lean", "Audit.lean", "Main.lean",
    "lakefile.toml", "lean-toolchain",
)
RUNTIME_FILES = ["adapter/server.py", "adapter/native.py", "LICENSE"] + [
    f"examples/fifo/{policy}/{name}"
    for policy in ("policy", "policy-overwrite") for name in POLICY_FILES
]

README = r"""# Axiward 本机 CLI

Windows x64；使用已有 Git、Python 3.11+、Codex 与完整 Lean 4.34.0 工具链。
Codex Windows 原生沙箱的公开本机组 `CodexSandboxUsers` 必须已初始化；
Axiward 只解析现有身份，不创建账户组，缺失时明确报错。
Git 需支持 SHA-256 仓库和 `merge-tree --write-tree --merge-base`。
无需复制源码仓库或 Lean 工具链到本目录。版本与文件 SHA-256 见 `release.json`。
实际核验通过 Codex CLI 启动：同一个 PowerShell 中 `codex --version` 必须成功。
安装了 Codex 桌面应用不代表普通终端已能找到 codex.exe；发行目录也不捆绑 Codex。
本版用于新建受管项目；此前缺少 `source/` 的试验仓库不能直接加载。
没有自动迁移，不会为升级删除旧项目数据。

在本目录打开 PowerShell，将 `$lean` 改为现有工具链位置；`$repo` 必须是新目录：

```powershell
$app = (Get-Location).Path
$cli = Join-Path $app 'axiward.exe'
$lean = 'C:\path\to\lean-4.34.0-windows'
$python = (Get-Command python).Source
$repo = Join-Path $env:USERPROFILE 'AxiwardProjects\queue'
$view = Join-Path $repo '.view\package-1'
codex --version
& $cli --version
& $cli init $repo "$app\examples\fifo\policy" $lean
& $cli session $repo $view $python "$app\adapter\server.py"
& $cli overview $repo
```

若 `codex --version` 报找不到命令，确认本机现有 codex.exe 的位置，
只在当前 PowerShell 临时添加它所在的目录，再重新检查：

```powershell
$codexDir = 'C:\path\to\directory-containing-codex.exe'
$env:PATH = "$codexDir;$env:PATH"
codex --version
```

这是当前终端的环境设置，不修改全局 PATH，也不安装 Codex。
CLI 会在初始化、建 session、领取新包和封存实现/精化候选前检查该入口。
已登记请求的重放和原包恢复仍可用，参数冲突仍会被拒绝。
此检查仅确认命令可启动，不代表候选已经通过数学核验。
若核验时入口消失，原包仍按 unresolved 结束；修正环境后使用新包，不复活旧包。

`policy` 是满时拒绝的 FIFO 规格；`policy-overwrite` 是满时覆盖最旧元素的登记规格。
将 `$view` 加入 Codex 并信任项目，重新打开任务，确认 Axiward MCP 工具已加载。
保留生成的审批配置，以便用户问答可用；配置只写入这个工作视图。
Worker 使用已批准的完全访问模式，工作边界由生成的 `AGENTS.md` 说明。

给 worker 的起始指令：先读取 Axiward status 和 handoff，自行选择 node 和 action，
调用 next 后按返回的 actionInstructions 完成本包；需要用户决定时用 ask_user。
实现包的 `Queue.lean`、`Proofs.lean` 直接写在 `$view` 下。
包根的唯一说明文件 `AGENTS.md` 同时说明工作边界与当前动作；
保留根目录的 `Spec.lean`、`Goal.lean` 和 `.codex/` 连接配置。
`.axiward/` 保存 `view.json`、按需导出的 `materials/` 和启动前备好的 `tmp/`；
临时研究文件放在 `.axiward/tmp/`。完整证据只在显式调用 evidence 时导出到 `.axiward/evidence.json`。
条款编号由工具响应和 `.axiward/view.json` 的 claims 字段提供，不另生成 claims.json。
每次领取、恢复和已绑定包的 status 都返回完整交接、失败诊断、动作说明及实际路径；
status 只读并保留项目地图，正式状态来自 Git，不能用本地 view.json 代替。
一个视图永久绑定一个包；新包通过 session 创建新的 `.view/<名称>/` 空间。
session 记录 exe、适配器和 Python 的绝对路径，开始使用后应保持发行目录位置稳定。

核验临时副本位于项目根的 `.checks/`；默认交付目录为项目根的 `delivery/`。
这两个目录和 `.view/` 均由受管项目的 `.gitignore` 排除。
已有项目和工作空间不会自动迁移或清理。

Discussion agent 在路线变更后读取 `invalidatedPackages`，先通过 Codex 停止对应 worker，
再用控制端 `reclaim` 回收其包。Axiward 不启动或停止 Codex worker。
用 `overview` 查看状态；`complete=true` 后导出并运行：

```powershell
& $cli deliver $repo
& "$repo\delivery\.lake\build\bin\fifo_demo.exe" 2 a b c
```

`deliver` 默认新建 `$repo\delivery`；显式输出路径也必须是项目根内的新目录，
不能位于 `.git/`、`.axiward/`、`source/`、`product/`、`.view/` 或 `.checks/` 中。
具体命令参数见 `axiward.exe --help`。本发行物的启动检查不代表真实 agent 自主推进已验收。
"""


def main():
    started = time.monotonic()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--toolchain", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    source = Path(__file__).resolve().parent
    toolchain = args.toolchain.resolve()
    output = args.output.resolve()
    if os.name != "nt":
        raise RuntimeError("this release supports Windows only")
    if output.exists():
        raise RuntimeError("release output must be a new directory")
    if not output.is_relative_to(source / ".work"):
        raise RuntimeError("release output must be under this repository's ignored .work directory")

    def run(*command):
        result = subprocess.run(list(map(str, command)), cwd=source,
                                capture_output=True, text=True, encoding="utf-8",
                                creationflags=subprocess.CREATE_NO_WINDOW)
        if result.returncode:
            raise RuntimeError(result.stdout + result.stderr)
        return result.stdout.strip()

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
    output.mkdir(parents=True, exist_ok=False)
    shutil.copyfile(executable, output / "axiward.exe")
    for relative in RUNTIME_FILES:
        target = output / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source / relative, target)
    (output / "README.md").write_text(README, encoding="utf-8")
    paths = ["axiward.exe", *RUNTIME_FILES, "README.md"]
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
