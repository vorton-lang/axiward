# Axiward

**从已确认的规格，推进到有证明、可追溯的产品。**

**[先看当前项目状态](docs/status.md)**：已有什么、缺什么、正在做什么、下一次交付什么。

Axiward 是本地项目控制系统。Agent 在独立视图中工作；Lean 控制端核验操作、维护精化图，Git 保存完整状态和证据。

R0 支持 Windows + Codex，覆盖执行、精化、探索、用户决定四条流程，以及并行工作包、暂停恢复、规格变更、成果复用和交付导出。Worker 根据状态与交接选择节点和动作，控制器检查准入条件。

**当前产品验证器支持 Lean 有界 FIFO 队列的两个登记规格。** Worker 使用用户批准的完全访问模式，按说明文档通过薄适配器推进项目；核验进程另行受限。任意软件与多语言验证器尚未接入。

R0 的固定范围工程检查已有通过记录；最近清理后的完整回归复验未完成。真实 agent 持续推进和用户最终验收仍待完成。

- [从源码开始使用](docs/product-guide.md) · [路线图](docs/roadmap.md)
- [架构与信任边界](docs/architecture.md) · [状态转换规则](docs/kernel-contract.md)
- [证明范围](docs/execution-slice.md) · [权限边界与检查](docs/permissions.md)
- [已审核设计与交付要求](docs/design.md)

## 构建与检查

需要 `lean-toolchain` 指定的 Lean 4.34.0 完整发行版、Git、Python 3.11+；原生接入检查还需要 Codex。以下命令在源码目录执行，`lake` 来自该发行版：

```powershell
lake build axiward store_scenarios workflow_scenarios
lake env lean Tests/Audit.lean
lake env leanchecker Axiward
.\.lake\build\bin\workflow_scenarios.exe
.\.lake\build\bin\store_scenarios.exe "$PWD\.work\new-storage-check"
python Tests/handoff.py --toolchain C:\Tools\lean-4.34.0-windows --output .work\new-handoff
python Tests/status_snapshot.py --toolchain C:\Tools\lean-4.34.0-windows --output .work\new-status-snapshot
python Tests/native.py --toolchain C:\Tools\lean-4.34.0-windows --output .work\new-native
```

检查保留证据目录，不自动清理。工作流、交接、快照和原生接入检查的用户答复均由测试客户端模拟，不是用户对真实产品的批准；不调用模型 API 或进行模型推理。

每项检查应在 30 秒内完成。已批准按“已有定理去重、纯逻辑补证明、外部边界保留短检查”重整检查；当前由 subagent 实施。上列短检查已有通过记录，新边界入口的最终覆盖与耗时见[验证与边界](docs/execution-slice.md#验证与边界)。权限隔离检查按用户要求跳过。

MIT License.
