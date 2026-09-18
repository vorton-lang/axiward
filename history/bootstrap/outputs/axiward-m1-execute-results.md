# M1 首个执行闭环：结果

2026-09-18。已完成用户批准的第一个实现交付点：领取执行包 → 封存终稿 → 核验 → 接纳或拒绝 → 重启恢复。当前为单个目标，完整 M1 与四类工作流程尚未完成。

## 交付物

- [本地实现说明](<USER_HOME/Desktop/axiward/docs/execution-slice.md>)：模块、规则到定理的对应关系、运行方法与范围。
- [Lean CLI](<USER_HOME/Desktop/axiward/.lake/build/bin/axiward.exe>)。
- [集成检查结果](<LEGACY_WORKSPACE/work/m1-execute/run-1789697150778/final/results.json>)与[逐次命令记录](<LEGACY_WORKSPACE/work/m1-execute/run-1789697150778/final/commands.json>)。
- [真实交付的 FIFO 程序](<LEGACY_WORKSPACE/work/m1-execute/run-1789697150778/final/delivered/product/.lake/build/bin/fifo_demo.exe>)。

CLI、状态转换、证明、Git 存储与固定验证器均为 Lean 实现；Python 只用于跨进程集成检查。代码留在本地 Axiward 仓库，本轮未创建源码提交或推送。

## 证明结果

构建、`Tests/Audit.lean` 和 `leanchecker Axiward` 均通过。

- 审查了 842 个内核声明，没有 `sorry`、额外公理或未核验的运行实现替换。
- `run_preserves` 依赖 `propext`、`Quot.sound`。
- `accepted_binding` 依赖 `propext`，要求核验通过结果绑定当前版本和准确的封存候选。
- CLI 与历史恢复直接使用这些证明覆盖的转换函数。

## 外部边界检查

9 组集成检查全部通过：初始化保护与请求去重；封存恢复、候选隔离和并发核验；实际二进制运行；错误 FIFO；`sorry`；缺少证明；并发占用；存储故障注入；产物篡改。

存储检查包含旧版本 CAS 冲突、无关源码保留、重复请求、同 ID 不同内容、越权取消、封存恢复、版本失效和损坏历史。所有实验目录保留，没有执行批量删除。

正常 FIFO 的本次三个核验阶段耗时分别为：构建 2.935 秒、公理审查 4.094 秒、本地模块复查 3.993 秒；这是单次实验记录，不是性能承诺。标准库使用固定发行版，不在每次局部复查中重新检查。

验证项目的正常交付提交为 `fd1a90d1c864893e187fb3e8bb0e0b6d017ff8ee684564e8cd6945fe414a5359`。之后的篡改试验故意破坏测试裸仓库的当前交付，系统拒绝加载；`delivered/` 保留的是篡改前的正常导出。

CLI 可执行文件 SHA-256：`7028fa97bd6f72b0c851ec2f5d34a612f30d25ad4b223afbd7f2a62931f974cb`。

## 下一交付点

在现有执行闭环上增加多节点精化图、实际依赖的失效传播与成果复用，再接探索、用户决定和原生 harness。完整图上的项目完成判定尚未实现；不能把当前单目标接纳等同于 R0 完成。

目前未发现阻塞 Lean CLI 路线的语言问题。访问隔离继续采用用户已批准的 D6 前提，外部 Git、验证器、工具链与编译运行时仍按明确契约接入。

