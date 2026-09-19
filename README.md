# Axiward

**从已确认的规格，推进到有证明、可追溯的产品。**

**[先看当前项目状态](docs/status.md)**：已有什么、缺什么、正在做什么、下一次交付什么。

Axiward 是本地项目控制系统。Agent 在独立视图中工作；Lean 控制端核验操作、维护精化图，Git 保存完整状态和证据。

R0 支持 Windows + Codex，覆盖执行、精化、探索、用户决定四条流程，以及并行工作包、暂停恢复、规格变更、成果复用和交付导出。Worker 根据状态与交接选择节点和动作，控制器检查准入条件。

**当前产品验证器支持 Lean 有界 FIFO 队列的两个登记规格。** Worker 使用用户批准的完全访问模式，按说明文档通过薄适配器推进项目；核验进程另行受限。任意软件与多语言验证器尚未接入。

共享源码三方合入、旧保证重验、路线失效回收及原始失败交接已有独立检查；旧检查重整 checkpoint 的完整回归复验未完成。真实 agent 持续推进和用户最终验收仍待完成。

- [从源码开始使用](docs/product-guide.md) · [路线图](docs/roadmap.md)
- [架构与信任边界](docs/architecture.md) · [状态转换规则](docs/kernel-contract.md)
- [证明范围](docs/execution-slice.md) · [权限边界与检查](docs/permissions.md)
- [已审核设计与交付要求](docs/design.md)

## 构建与检查

需要 `lean-toolchain` 指定的 Lean 4.34.0 完整发行版、Git、Python 3.11+；原生接入检查还需要 Codex。以下命令在源码目录执行，`lake` 来自该发行版：

```powershell
lake build axiward store_scenarios workflow_scenarios verifier_boundary workflow_boundary
lake env lean Tests/Audit.lean
lake env leanchecker Axiward
.\.lake\build\bin\workflow_scenarios.exe
.\.lake\build\bin\store_scenarios.exe "$PWD\.work\new-storage-check"
python Tests/integration.py --case merged --toolchain C:\Tools\lean-4.34.0-windows --output .work\new-merged
python Tests/workflow.py --case route --output .work\new-route
python Tests/status_snapshot.py --toolchain C:\Tools\lean-4.34.0-windows --output .work\new-status-snapshot
python Tests/native.py --toolchain C:\Tools\lean-4.34.0-windows --output .work\new-native
```

检查保留证据目录，不自动清理。工作流、交接、快照和原生接入检查的用户答复均由测试客户端模拟，不是用户对真实产品的批准；不调用模型 API 或进行模型推理。

每项检查应在 30 秒内完成；旧 handoff 的超时和原生接入最终树未复验仍明确保留，不能把上列命令统一当作当前通过记录。实际覆盖、通过耗时和检查分层边界见[验证与边界](docs/execution-slice.md#验证与边界)。权限隔离检查按用户要求跳过。

## 本机发行目录

在干净的源码签出中执行 `python package_cli.py --toolchain C:\Tools\lean-4.34.0-windows --output .work\axiward-cli-new`，生成独立 exe、薄适配器、两套登记策略和来源/文件摘要清单。发行目录的使用不依赖源码签出；Git、Python、Codex 和完整 Lean 工具链仍使用本机既有安装；启动 CLI 的同一终端必须能运行 `codex --version`，桌面应用存在不等于 CLI 已进入 PATH。

每个 `.view/<包>/` 根目录保留候选、`Spec.lean`、`Goal.lean` 和唯一说明 `AGENTS.md`；`.codex/` 放连接配置，`.axiward/` 放视图、按需材料及临时文件，完整证据仅在显式请求时导出。核验副本和默认交付分别位于项目根 `.checks/`、`delivery/`。详细启动命令见发行目录 README 和[使用说明](docs/product-guide.md)。本版面向新建受管项目；先前缺少 `source/` 的试验仓库不能直接加载，不会自动迁移或清理。

MIT License.
