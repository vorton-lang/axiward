# 权限边界与检查

普通 worker 通过薄适配器操作正式项目，原生命令只能修改自己的 `work/` 和 `tmp/`。正式仓库、控制端、适配器和核验目录受到路径权限保护；候选构建与证明核验也在受限进程中执行。当前验证状态见[项目状态](status.md)。

## 必须保持的边界

- 普通命令不能读写正式仓库，复制 CLI 不能取得用户决定权限。
- worker 不能修改权限配置，也不能通过硬链接或越出视图的链接提交私有输入。
- 适配器拒绝旧的完全访问配置和扩大写权限的配置；配置错误必须阻止启动。
- 正确候选能够核验；候选代码不能读取正式仓库或修改核验规格。
- 外部调研读取与其他任务仍可工作。限制针对生成的任务配置，不是整个 harness 的全局限制。
- 同项目的核验工具使用 OS 文件锁排队。共享同一 Codex 环境的 Axiward 核验调用只在沙箱启动阶段排队，收到受限子进程的就绪信号后，不同项目继续并行核验。

实现分别在 `Axiward/Interface.lean`、`adapter/server.py` 和 `Axiward/Sandbox.lean`。Windows elevated 配置保留 `:root` 只读基线，再显式拒绝项目私有路径；核验目录位于正式仓库旁的 `<repo>.checks/`，避免工作目录自身落入拒读范围。

隔离依赖受保护的控制端、完整 Lean 工具链、原生权限配置和操作系统。新增独立特权工具、切换完全访问模式或更换平台，需要重新验证对应边界。

Codex `0.155.0-alpha.9` 的 Windows elevated 沙箱在首次并发注册可写路径时可产生 SID 缓存不一致。Axiward 在 `CODEX_HOME`（默认 `%USERPROFILE%/.codex`）使用 `axiward-sandbox-start.lock` 协调自身的核验启动；Windows 自带 PowerShell 在受限子进程内发出就绪信号，随后执行固定的 Lake 命令。控制端移除协议行，保留工具输出与退出码；缺少就绪信号按启动故障报告。

启动协调不改写 Codex 权限配置、不扩大核验进程的读写范围，也不使锁成为项目状态。它只协调 Axiward 核验调用，无法约束其他独立 Codex 进程；相关依赖缺陷与独立复现见[故障说明](../experiments/windows-sandbox-concurrency.md)。

## 可复现检查

| 入口 | 独立检查什么 |
| --- | --- |
| [`Tests/native.py`](../Tests/native.py) | 原生 worker 的路径拒绝、配置保护、复制 CLI、硬链接、其他任务与用户问答。 |
| [`Tests/isolation/config_guard.py`](../Tests/isolation/config_guard.py) | 完全访问配置或额外 workspace 写权限不能启动适配器。 |
| [`Tests/isolation/verifier.py`](../Tests/isolation/verifier.py) | 正确候选通过；尝试读正式仓库或写核验规格的候选被拒绝。 |
| [`Tests/isolation/parallel_check.py`](../Tests/isolation/parallel_check.py) | 同项目及跨项目并发核验不会互相破坏原生权限配置。 |
| [`Tests/workflow.py`](../Tests/workflow.py)、[`Tests/integration.py`](../Tests/integration.py) | 边界下的完整流程，以及正式状态和实际交付物。 |
| [`experiments/windows-sandbox-concurrency.py`](../experiments/windows-sandbox-concurrency.py) 配合 `--production-toolchain` | 从实际 `Sandbox.runVerifier` 启动三个全新沙箱，检查执行区间重叠，以及后续启动期间的读写隔离。 |

先按 [README](../README.md#构建与检查) 构建。以下命令从仓库根目录执行，工具链路径替换为本机位置；按本次改动涉及的边界选择检查。原生检查会启动进程并多次核验 Lean 候选，不是快速静态检查。

```powershell
python Tests/native.py --toolchain C:\Tools\lean-4.34.0-windows --output .work\native-permissions
python Tests/isolation/config_guard.py --repo .work\native-permissions\project.git
python Tests/isolation/verifier.py --toolchain C:\Tools\lean-4.34.0-windows
python Tests/isolation/parallel_check.py --toolchain C:\Tools\lean-4.34.0-windows
python Tests/isolation/parallel_check.py --toolchain C:\Tools\lean-4.34.0-windows --separate-projects
```

`config_guard.py` 使用原生检查创建的测试仓库；它修改新建视图中的配置并检查拒绝结果。其余隔离脚本创建新的 `.work/` 运行目录，原始记录与可分享摘要一起写入该目录，不改写检查源码目录。检查不自动清理运行目录。需要支撑当前结论的证据按项目约定另行保留，旧结果不能充当新版本通过的证明。
