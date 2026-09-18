# Axiward 0.2 架构

**正式状态只有一个来源：受管项目 Git 仓库中的可重放历史。** 项目使用普通签出布局；工作视图和适配器都不是状态 authority。

```mermaid
flowchart TD
    User[用户：确认规格 / 回答问题 / 验收]
    Agent[Codex 原生任务]
    View[独立工作视图：规格与目标 / 可编辑候选 / 材料目录]
    MCP[薄 MCP 适配器：固定 worker 身份与路径 / 工具白名单]
    CLI[Lean CLI：工作包准入 / 视图 / 四条工作流程 / 交付]
    Kernel[Lean 状态内核：权限 / 精化图 / 当前证据 / 过程义务]
    Git[(受管 Git 仓库：规格 / 源码 / 图 / 证据 / 历史)]
    Verify[登记验证器：构建 / 公理审计 / leanchecker]
    Native[原生 command/exec：准确输入 / 完整输出 / 终止记录]
    Product[实际产品 / 证明 / 交付清单]
    User -->|用户入口| CLI
    User -->|elicitation 用户响应| MCP
    Agent <-->|读材料，写候选| View
    Agent <-->|工作工具| MCP
    MCP --> CLI
    CLI --> Kernel
    Kernel <-->|重放、CAS 提交| Git
    CLI --> Verify
    MCP -->|已持久化实验意图| Native
    Native -->|调用固定验证器| Verify
    Native -->|原始记录| CLI
    CLI --> View
    CLI -->|complete 后导出| Product
```

| 部分 | 职责与边界 |
| --- | --- |
| `Model` / `Transition` / `Workflow` / `Engine` | 纯状态转换；图完整性、证据接纳、角色和流程规则。 |
| `Git` | 同一条历史保存全部正式状态；比较旧版本提交，冲突重读；持锁同步普通签出，拒绝覆盖本地草稿；恢复时重放并检查内容绑定。 |
| `Verifier` / `Refinement` / `FifoPolicy` | 固定 FIFO 验证契约；依赖引用、封存源码、证明、构建产物和工具摘要。 |
| `Controller` / `FlowIO` | 真实 IO 与核验流程；登记、执行、记录、向上组合。 |
| `Interface` / `Main` | Worker 指定节点与动作后的领包入口、固定快照材料、worker 视图、用户管理命令、交付导出。 |
| `adapter/server.py` / `native.py` | 原生 MCP 和进程协议；不自主调度、不持有权威状态、不开放管理员工具。 |

用户通道与 worker 工具分离。`.view/<唯一目录>/` 的启动配置绑定 worker 身份；空空间首次领取后绑定一个包，每个新包使用另一个空间与 session。原包可在原空间恢复，绑定从 Git 分配历史读取，不靠可写文件标记。MCP 用户提问的回包进入原调用；决定存于 Git。`status` 和包视图从同一个当前版本计算完整交接，按目标、版本和访问权限提供决定，不按提问者或已读状态过滤。包输入仍绑定领取快照；`current/` 记录与固定的 `node/` 材料明确区分；活动包写权限仍绑定原 owner。

项目根正常签出正式内容，`.axiward/` 受版本管理，`.gitignore` 排除 `.view/`。私有索引、收件副本、传输日志和锁放在 `.git/`。正式写入先确认 checkout 不覆盖本地修改，再推进 `main` 并同步签出；若两步之间中断，`.git/` 内的临时记录只用于在下一次写请求时补齐签出。项目真值始终来自提交，读取不触发修复。

探索中的原始执行记录来自 [Codex `command/exec`](https://developers.openai.com/codex/app-server)，模型解释另存。实验意图先提交，只有成功创建意图的调用方发起执行；缺少结果时不盲重跑。

Worker 当前使用用户批准的完全访问模式。`.view/<目录>/` 保存包工作材料，生成说明要求 worker 只编辑本包候选、通过 Axiward 取得材料和提交，不直接操作正式仓库、其他包、控制端或适配器。这些是操作约定，不是操作系统强制隔离。MCP 入口继续检查参数、包归属和候选路径，并在封存前读取实际输入内容。

核验副本位于正式仓库旁的 `<repo>.checks/`，说明约定要求 worker 不直接操作。Lean 编译与核验仍通过既有原生受限进程运行；这限制核验进程本身，不提供对完全访问 worker 的隔离。Git 索引与正式状态由控制端维护。

原生核验调用使用项目内的 OS 文件锁，避免 Windows 为同一项目并发配置权限时发生竞争。锁随句柄释放，不成为第二份项目状态；不同项目不共享此锁。

外部信任前提包括用户根规格、登记规范、CLI 和适配器未被绕过或改写、Git、完整 Lean 工具链、Codex 原生进程服务和操作系统。当前 worker 的行为遵守依赖说明约定；本轮跳过权限隔离检查。
