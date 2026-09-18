# R0 实现与验证范围

当前实现覆盖四类流程、工作视图、导航、暂停恢复、规格变更、成果复用与交付导出。这里说明实际证明和外部契约；日常使用见[产品说明](product-guide.md)。[已审核规则](kernel-contract.md)是设计依据，不等同于对所有基础设施已经完成端到端形式证明。

已跑通的项目形状如下。完成三个叶子后，系统依次核验并关闭中间目标和根目标。

```mermaid
flowchart TD
  R[0：完整 FIFO 要求] --> A[1：创建与入队]
  R --> B[2：出队与状态查询]
  A --> C[3：创建]
  A --> D[4：入队]
```

## 模块与实际调用

| 模块 | 当前职责 |
| --- | --- |
| `Model.lean` | 版本、工作包、证据、路线与历史记录的类型。 |
| `Transition.lean`、`Proofs.lean` | 单节点转换及其证明。 |
| `Workflow.lean` | 探索、在途操作、用户决定、暂停和访问规则的纯转换与证明。 |
| `Engine.lean` | 多节点转换、图不变量、请求去重和历史回放。 |
| `Git.lean` | 完整快照、对象绑定检查、私有索引和分支比较交换。 |
| `FifoPolicy.lean`、`Verifier.lean` | 从 Q0 六项要求构造核验目标，核验实际程序。 |
| `Refinement.lean` | 核验拆分关系，组装已核验源码。 |
| `Controller.lean` | 调用核验器、自动向父目标传播、处理重试。 |
| `FlowIO.lean` | 流程候选、实验登记、原生记录接纳与对账。 |
| `Interface.lean` | 四动作评分、固定快照视图、材料检索、原始诊断与交付。 |
| `Main.lean` | 受信控制端 CLI。 |

上述模块均在 `Axiward/` 下，`Main.lean` 位于仓库根目录。

每个节点至多一个活动包，不同节点独立占用。动作固定为四种之一；阶段由封存状态及已准入的探索、待决定记录共同导出。没有过期回收。探索原语限定为登记的 FIFO 候选核验；纯分析可以用零次实验预算。用户问题目前只产生版本绑定的偏好，根变更仍走单独的用户确认命令。

普通执行仍调用已证明的 `run`。项目转换通过 `runGraph` 计算候选，再检查节点、边和成果依赖；只有满足 `GraphIntegrity` 才能构造正式状态。Git 保存初始规格与逐次转换记录，恢复时重新执行转换并核对结果，没有另一份可单独改写的当前状态缓存。

## 规则与证明对应

| 已覆盖的性质 | 规则 | 依据 |
| --- | --- | --- |
| 占用与闭合不重叠，结果绑定当前目标版本 | S1、S3、G3 | `run_preserves`、`current_result`、`graph_node_integrity` |
| 封存后不能替换终稿 | T4 | `sealed_cannot_be_replaced` |
| 被拒绝的核验释放占用，结束后迟到结果不能发布 | T5、T15 | `rejection_releases`、`ended_cannot_publish` |
| 执行发布必须有匹配版本和候选的通过结果 | G3、T5 | `accepted_binding` |
| 流程动作不修改命题、不发布产品、也不重分配编号 | G5、T10–T13 | `workflow_preserves`、`workflow_never_publishes` |
| 模型不能冒充用户答复或 harness 观测 | G1、T10、T13 | `worker_cannot_answer`、`worker_cannot_forge_observation`；身份对应由保护的适配器契约承担 |
| 取消保留过程义务，迟到观测不改变活动包 | T10、T15 | `cancel_preserves_obligations`、`late_observation_never_revives` |
| 暂停禁止新的工作包 | T16 | `pause_blocks_new_package` |
| 实验发起前必须有登记的准入方案 | T8、T9 | `launch_requires_admitted_plan` |
| 完成声明需要根证明及已结清的在途操作 | T18 | `complete_requires_proof_and_settlement` |
| 旧包不能凭旧核验发布到新版本 | T17 | `changed_scope_rejects` |
| 新建或复用节点均不能引入循环 | T6 | `route_rank_decreases`、`reachable_decreases`、`graph_acyclic` |
| 父结果绑定当前子成果和选定路线 | T14 | `composed_result_has_current_children` |
| 组合发布必须有匹配的核验通过结果 | T14 | `composition_requires_checked_output` |
| 模型不能直接批准精化或发布组合结果 | G1 | `worker_cannot_install_refinement`、`worker_cannot_compose` |
| 转换保留已有历史 | S5 | `Change.historyPrefix`、`step_preserves_history` |
| 当前成果的规格依赖符合最新根 | G3、T17 | `published_requirements_current` |
| 失效传播不改写包编号和活动包快照 | S3、T17 | `normalize_preserves_packages` |
| 历史复用只引用正式接纳过的结果 | T7 | `priorAdmission`、`priorAdmission_iff`，由 `step` 强制检查 |

这些证明与构造约束覆盖上述实际实现；并非对任意依赖分析、任意外部副作用或操作系统权限的证明。预算、具体实验准入、用户答复适用性和完整交付条件由对应的纯转换守卫实施，跨流程检查验证它们的组合；上表仅列出已实际陈述并核验的定理。`Tests/Audit.lean` 检查内核声明的公理和运行实现替换；另用 `leanchecker Axiward` 复查本地模块。定理使用 Lean 的标准公理 `propext`、`Quot.sound`、`Classical.choice`，没有 `sorry`。

## 拆分与组合如何工作

精化提交包含 `plan.json` 和 `Refinement.lean`。前者选择子任务的要求组；后者证明：对于任意一组事实，满足这些子要求足以满足父要求。控制端生成固定目标，让 Lean 核验这个蕴含关系，并检查公理与证明模块。通过后才创建子节点。

每次子节点完成后，控制端寻找可组合的父节点，核对当前子结果与路线，组装证明源码，再核验父目标和实际程序。成功才发布父结果，并继续向上。它不会把“所有子任务通过”直接翻译为“整个项目通过”。

相同输入只自动尝试组合一次。条件恢复后可以提供新的组合请求 ID 再核验；未知或失败不等于命题已被证伪。相同 ID、相同请求返回原结果；复用 ID 提交不同请求会被拒绝。

当前 FIFO 接入将六项要求分成非空、不重叠的组。子项可以是新目标，也可以用 `{"reuse": 节点编号}` 引用已有目标。系统核对被引用目标的版本与要求；允许引用较早的节点，但计算图的层次并检查每条边下降，以拒绝循环。

默认组合仍要求相同实现。需要把保留的证明材料用于新实现时，精化方案必须用 `implementation` 指定一个子项的位置作为实现来源；系统会把所有证明源码放到该实现下重新核验父目标。选错实现会导致组合失败，不能把旧证书直接当成新程序的证明。

初始化和变更严格匹配两个已登记根策略（忽略换行格式和首尾空白）：Q0 满时拒绝，以及验收用的“满时替换最旧元素”版本。容量为零仍拒绝。不支持的规格不会被悄悄替换；导入 Git 后再次核对实际内容。

恢复直接实现路线会保留原目标与已有子成果，不把撤下子目标当作完成。

## 规格变更与历史复用

目标记录对具体要求和检查器规范的版本依赖。FIFO 适配器从实际使用的命题定义和受信检查配置生成这些引用；未使用的另一项命题变化不会单独使本目标失效。引用完整性仍是适配器的明确契约。

`revise-preview` 执行同一份纯状态转换，列出变化的要求、失效结果、保留结果与过期工作包，不更新正式分支。用户入口用预览返回的 `reviewToken` 确认变更；该凭据同时绑定旧根和拟议新规格；其他节点提交不影响确认，但根被更新或新规格被替换时必须重新预览。

真正写入时再次检查当前状态，并从成功提交的那次转换生成影响报告。失效沿依赖传播，历史记录、产物和工作包原输入保留。过期结果不能发布；无关的进行中工作包仍可以完成。变更本身不会取消包或重新分配包编号。

历史产物复用同样属于精化。结果包可提供 `{"result":{"node": 原节点,"receipt":"原凭据ID"}}`，不同时提供子项或直接路线。控制端和内核都要求它来自历史上真正接纳的结果；仅检查通过但最终被拒绝的尝试不算接纳。

历史结果必须具有完全相同的已核验规格、策略和依赖，允许操作版本号不同。条件满足时接纳原产物并生成新绑定凭据，原源码、证明和二进制不重建。规格不同必须重新核验，不能用历史复用绕过新要求。

## Git 中保存什么

| 路径 | 内容 |
| --- | --- |
| `.axiward/state.json` | 初始规格、请求及转换结果，恢复时重放。 |
| `.axiward/policy/`、`.axiward/candidate/` | 根节点的策略与封存候选。 |
| `.axiward/route/` | 根节点当前精化关系的核验凭据。 |
| `.axiward/checks/<包编号>/` | 原始核验记录，失败也保存。 |
| `.axiward/compositions/<记录编号>/` | 父目标组合核验记录，失败也保存。 |
| `.axiward/receipt.json`、`product/` | 根的已发布凭据与实际产物。 |
| `.axiward/nodes/<节点编号>/` | 子节点对应的策略、候选、路线、记录与产物。 |

这些内容共用 `main` 的 Git 历史，旧路线和旧产物由历史提交保留。每次写入使用私有索引构造完整树，再比较旧提交更新引用；冲突后按最新状态重新检查。只改变状态时保留无关源码。

恢复同时检查规格、候选、精化凭据和交付物的实际对象摘要。裸仓库中的 `axiward-work/` 保留构建目录和诊断材料，不参与正式状态判断。

当前持久化协议为 schema 3；程序明确拒绝加载 schema 1、2，不自动改写旧记录。

## CLI

```text
axiward init <裸仓库绝对路径> <受信策略目录> <Lean工具链目录>
axiward begin <仓库> <请求ID> <执行者ID> [节点编号=0 动作=execute]
axiward submit <仓库> <请求ID> <执行者ID> <包编号> <候选目录> [节点编号=0]
axiward check <仓库> <请求ID> <包编号> [节点编号=0]
axiward compose <仓库> <节点编号> [重新核验所用的新请求ID]
axiward revise-preview <仓库> <请求ID> <已登记策略目录>
axiward revise <仓库> <请求ID> <已登记策略目录> <预览的reviewToken>  # 仅用户入口
axiward status <仓库>
axiward cancel <仓库> <请求ID> <执行者ID> <包编号> <原因> [节点编号=0]
```

动作参数支持 `execute`、`refine`、`explore`、`requestDecision`。根编号为 `0`，各节点的工作包独立从 `0` 开始。完整用户命令见 `--help`，worker 工具与文件格式见产品说明。

基线策略和候选在 `examples/fifo/policy`、`candidate`；变更验收版本在 `policy-overwrite`、`candidate-overwrite`。精化候选在 `examples/fifo/refinement`；集成检查从完整候选中提取所需的分组证明。

身份由受信调用方填写；CLI 是控制端接口，身份字符串本身不提供认证。薄 MCP 适配器在启动时绑定 worker 身份、仓库和视图；工具白名单不提供 `revise`、`decide` 或原始观测登记。用户答复来自原生 MCP elicitation 响应或独立用户终端。模型没有自填“通过”来发布成果的命令。

## 验证与边界

`Tests/integration.py` 调用真实 CLI、Git 和 Lean，覆盖单目标交付、终稿隔离、并发重试、错误证明、存储故障和篡改，以及嵌套精化、自动组合、遗漏要求、循环复用和实现不匹配。本轮还验证变更预览、保留无关节点、只执行一次新的入队任务、错误实现选择被拒绝、历史交付复用，以及过期确认不能覆盖新根。

检查会从单目标与组合项目的 Git 交付中运行二进制。正式行为保证来自 Q0 证明；运行示例只检查编译和导出接入。实验目录均保留，不自动清理。

Git、原生执行通道、受保护的控制端与完整 Lean 发行版仍是明确的外部信任前提。标准库、编译器及运行时正确性不由本内核证明。当前使用薄适配器与原生权限：普通 worker 不能直接访问正式仓库；核验候选的子进程不能读取正式仓库或改写规格输入。实现边界和检查入口见[权限接入](permissions.md)。

`Tests/workflow.py` 验证真实 MCP 适配器、Codex 原生实验、预算、回包重试、暂停与封存恢复、用户答复断线恢复、双 worker 视图、四类动作和实际导出的程序。`Tests/native.py` 使用原生 `mcpServer/tool/call` 和用户 elicitation 路由，零模型轮次；用户答复为测试客户端明确模拟。`Tests/WorkflowScenarios.lean` 检查跨流程的异常组合和历史重放，不把这些检查称为定理证明。

`rootClosed` 表示当前精化图的根有有效结果。`complete` 还要求当前路线没有活动工作包，所有已登记的在途实验均已完成或明确对账；无关的历史支线不要求全部闭合。交付绑定具体 Git 快照与产物摘要。导航是机械启发式，没有最优性或必然收敛保证。

存储、进程身份、完整原生记录、资源访问、编译及产品导出对应关系仍由外部契约和集成检查支撑。当前是有限 FIFO 规格族，不能据此宣称支持任意软件需求的影响分析。根规格和 checker 不能由 worker 自定义来绕过已登记目标。
