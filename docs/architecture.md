# Axiward 0.1 架构

**正式状态只有一个来源：受保护裸 Git 仓库中的可重放历史。** 工作视图和适配器都不是状态 authority。

```mermaid
flowchart TD
    User[用户：确认规格 / 回答问题 / 验收]
    Agent[Codex 原生任务]
    View[独立工作视图：规格与目标 / 可编辑候选 / 材料目录]
    MCP[薄 MCP 适配器：固定 worker 身份与路径 / 工具白名单]
    CLI[Lean CLI：导航 / 视图 / 四条工作流程 / 交付]
    Kernel[Lean 状态内核：权限 / 精化图 / 当前证据 / 过程义务]
    Git[(保护的 Git 裸仓库：规格 / 源码 / 图 / 证据 / 历史)]
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
| `Git` | 同一条历史保存全部正式状态；比较旧版本提交，冲突重读；恢复时重放并检查内容绑定。 |
| `Verifier` / `Refinement` / `FifoPolicy` | 固定 FIFO 验证契约；依赖引用、封存源码、证明、构建产物和工具摘要。 |
| `Controller` / `FlowIO` | 真实 IO 与核验流程；登记、执行、记录、向上组合。 |
| `Interface` / `Main` | 四动作评分、固定快照材料、worker 视图、用户管理命令、交付导出。 |
| `adapter/server.py` / `native.py` | 原生 MCP 和进程协议；不自主调度、不持有权威状态、不开放管理员工具。 |

用户通道与 worker 工具分离。启动配置绑定 worker 身份；同一视图用于一个原生任务，多任务使用不同视图。MCP 用户提问的回包进入原调用；未读答复存于 Git，断线后可恢复。

探索中的原始执行记录来自 [Codex `command/exec`](https://developers.openai.com/codex/app-server)，模型解释另存。实验意图先提交，只有成功创建意图的调用方发起执行；缺少结果时不盲重跑。

R0 的外部信任前提：用户根规格、登记规范、受保护的 CLI 和适配器、Git、完整 Lean 工具链、Codex 原生进程服务和操作系统。工作视图采用完全访问权限加规则文本；图中的分离表达职责与接口，不表示当前具有硬隔离。
