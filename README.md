# Axiward

**从已确认的规格，推进到有证明、可追溯的产品。**

Axiward 0.1 是本地项目控制系统。Agent 在独立视图中工作；Lean 控制端核验操作、维护精化图，Git 保存完整状态和证据。模型不能通过自报成功、提交日志或伪造用户答复来关闭目标。

R0 支持 Windows + Codex，覆盖执行、精化、探索、用户决定四条流程，以及导航、并行工作包、暂停恢复、规格变更、成果复用和交付导出。

**当前产品验证器支持 Lean 有界 FIFO 队列的两个登记规格。** 控制闭环可以使用；任意软件、多语言验证器和强制沙箱隔离不在本版支持范围。完全访问权限下沿用已批准的访问规则。

R0 已通过固定范围的工程验收；真实 agent 持续推进、导航效果和用户最终验收仍待完成。

- [完整路线图与当前进度](docs/roadmap.md)
- [R0 交付状态与验收依据](docs/releases/0.1.0.md)
- [开始使用、四类流程与恢复方法](docs/product-guide.md)
- [架构与信任边界](docs/architecture.md)
- [实际实现和证明范围](docs/execution-slice.md)
- [已审核的状态转换规则](docs/kernel-contract.md)
- [原始系统设计](https://github.com/vorton-lang/axiward/discussions/1)

## 构建与检查

需要 `lean-toolchain` 指定的 Lean 4.34.0 完整发行版、Git、Python 3.11+；原生接入检查还需要 Codex。以下命令在源码目录执行，`lake` 来自该发行版：

```powershell
lake build axiward store_scenarios workflow_scenarios
lake env lean Tests/Audit.lean
lake env leanchecker Axiward
.\.lake\build\bin\workflow_scenarios.exe
python Tests/integration.py --toolchain C:\Tools\lean-4.34.0-windows --output C:\Checks\new-regression
python Tests/workflow.py --toolchain C:\Tools\lean-4.34.0-windows --output C:\Checks\new-workflow
python Tests/native.py --toolchain C:\Tools\lean-4.34.0-windows --output C:\Checks\new-native
```

检查保留证据目录，不自动清理。`workflow.py` 和 `native.py` 的用户答复由测试客户端模拟，不是用户对真实产品的批准；不调用模型 API 或进行模型推理。

## 生成发行包

```powershell
pwsh -File scripts/package.ps1 -Toolchain C:\Tools\lean-4.34.0-windows -Destination C:\Releases\axiward-0.1.0
```

输出独立 CLI、标准库 Python 适配器、示例、说明和 SHA-256 清单，并生成 ZIP。首次启动和配置专用 worker 视图见[使用说明](docs/product-guide.md)。没有项目守护进程，也不修改全局 Codex 配置。

MIT License.
