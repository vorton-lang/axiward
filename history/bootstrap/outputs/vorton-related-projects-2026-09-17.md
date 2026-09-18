# Vorton 相关项目调查

检索日期：2026-09-17。对照当前系统方案草稿。

## 先读结论

- **有整体方向接近的项目：qed、Overplane，以及邻近商业产品 Imandra CodeLogician。**
- **有直接值得借鉴的技术模块：EquiVM、WybeCoder、Aria、AET、Why3、HTPS。**
- 本轮尚未找到公开材料足以确认：某个现成系统同时提供根规格到实际产品的证明链、全过程操作约束、可变规格下的图与证据复用，以及可替换的四类动作导航。
- 这不构成“没有竞品”或“方案独有”的结论。各个核心思想已有大量先例，近似系统也正在形成。

调查以官方文档、作者论文和公开仓库为依据；对 qed 和 Overplane 额外抽查了部分源码。未安装运行项目，也未独立复现论文结果。下文的覆盖判断是本次比较结论，不能当作这些项目的完整审计。

## 1. 整体形态接近或构成邻近竞争的项目

### qed：最值得先看的一份小型流程内核

- **已有内容：** 类型化验收项、worker → verify → retry 状态机、重复失败检测、迭代上限、规格内容绑定；纯核心使用 Lean 4，并公开相关证明。
- **对应 Vorton：** 固定流程、模型与裁决分离、规范变更检测、核验器分派。
- **实际边界：** 证明主要涉及编排状态转换。验收项还可以是命令、性质测试、LLM 评审或人工判断，不能把整个任务的通过统一理解为产品的形式化正确性。文件和进程操作位于 IO 外层。
- **状态：** 作者明确标为正在开发 MVP。本轮读了架构、证明清单和 `NoSkip.lean`，没有运行 Lean 重验。

来源：[仓库](https://github.com/tskovlund/qed)、[架构](https://github.com/tskovlund/qed/blob/main/docs/architecture.md)、[证明清单](https://github.com/tskovlund/qed/blob/main/docs/proven-properties.md)、[NoSkip 源码](https://github.com/tskovlund/qed/blob/main/Qed/Proofs/NoSkip.lean)。

### Overplane：产品流程最接近的开源 CLI 之一

- **已有内容：** 编号 Markdown 规格，经模型转换为形式 IR，用 Z3 检查，再在容器内运行编码 agent；有内容缓存和成本记录。
- **对应 Vorton：** 规格驱动生成、现有 agent 的统一调用、隔离、版本缓存、执行成本。
- **实际边界：** 所检查的核心对象包括规格约束的一致性和场景；这不等于证明生成的程序实现了全部规格，也不等于认证全部研发操作。
- **源码观察：** 已查版本的 `buildverify.go` 对部分 C6 工具错误采用告警或零退出处理，不能直接拿来承担我们“未证明即不放行”的规则。
- **状态：** 公开 CLI、仓库和发布下载，仍需针对实际保证做独立验证。

来源：[仓库](https://github.com/overplane/overplane)、[官网](https://www.overplane.dev/)、[已查核验代码，固定版本](https://github.com/overplane/overplane/blob/eb07dd8601667bacecfbbfd41ab53d22a250f928/internal/cli/buildverify.go#L236)。

### Imandra CodeLogician：应关注的邻近商业产品

- **已有内容：** 通过 agent 把源码转换成 IML 数学模型，调用 ImandraX 分析性质、生成反例和测试；提供高层流程、低层命令及集成接口。
- **对应 Vorton：** 模型与逻辑引擎协作、形式化中间表示、明确的推理状态、卡住时请求用户。
- **实际边界：** 公开文档的中心是对生成模型进行分析。源码与模型的语义对应、外部函数假设需要单独核对，不能直接把模型上的定理当作原始产品的整体保证。
- **状态：** 商业服务，有 API 和开发工具文档；本轮未使用服务。

来源：[官方介绍](https://docs.imandra.ai/universe/code_logician/introduction/)、[建模与外部假设](https://docs.imandra.ai/universe/code_logician/thinking-formally/)。

## 2. 可参考的核心模块

| 项目 | 最值得借鉴的部分 | 范围与成熟度 |
|---|---|---|
| [EquiVM](https://github.com/argotorg/EquiVM) | 人可读形式规格到实际 EVM 字节码的精化证明；最终证书绑定具体产物 | 实验项目，有真实合约案例和明确可信基础。限于 EVM；其关系明确不比较 gas 消耗、日志等部分行为 |
| [WybeCoder](https://github.com/facebookresearch/wybecoder) | 生成命令式代码及证明、分解证明子目标、收集轨迹；结合 SMT 与 Lean | 公开研究代码，基于 Lean 中的 Velvet/Loom 语言，主要评价算法与验证任务；不代表已解决任意项目全生命周期 |
| [Aria](https://arxiv.org/html/2607.06341v1) | 整条引理作为粗粒度工作，外部 harness 核验；HHL 描述检查流程 | 研究论文公开；本轮未确认完整可用代码仓库。内部允许反馈重试，与我们的 one-shot 执行约定不同 |
| [AET](https://github.com/AdvancingTitans/agent-engineering-toolkit) | 证据与版本绑定、失效检测、证据图、局部视图、跨 agent 交接 | 已公开 CLI 和发布记录。它的 Proof 包括命令执行证据，不能等同于数学证明；项目明确不自动执行干预 |
| [AutoVerus / VeruSAGE](https://github.com/microsoft/verus-proof-synthesis) | Rust/Verus 证明生成、错误反馈、系统项目上下文及评估任务 | 公开研究工具与基准；适合作为证明工作包的候选能力，任务重点是证明生成和修复 |
| [Why3](https://why3.org/doc/manpages.html) | 多验证器调度、证明尝试树、过期标记、证明脚本重用和重放 | 成熟形式验证基础设施。原文件或转换变化会触发过期处理；不宜外推为任意工程修改下的最小影响分析 |
| [Event-B / Rodin](https://wiki.event-b.org/index.php/Main_Page) | 系统状态与事件建模、逐步精化、不同抽象层之间的证明义务 | 已有工业与研究使用的形式方法平台；提供精化方法参照，不自带我们的 agent 生命周期 |
| [HTPS / Evariste](https://github.com/facebookresearch/Evariste) | 在证明图中选择分支、扩展子目标并回传价值；policy 与 critic 配合 | 研究原型；仓库明确说明当前代码不能直接开箱运行。任务是定理证明，不是四类软件工程动作导航 |

补充来源：[Aria 的粗粒度证明与 harness 架构](https://arxiv.org/html/2607.06341v1)、[Why3 过期证明与重放](https://why3.org/doc/manpages.html#the-graphical-interface)、[HTPS 论文](https://arxiv.org/abs/2205.11491)。

## 3. 操作准入和基础设施建模的参考

### GapHarness

先把请求转换成观察、执行、状态、动作、控制、验证等义务，再从已声明的模块注册表里选择支持集，并给出覆盖证书或拒绝证书。

它接近我们的“操作执行前检查所需支持是否齐全”。但证书证明的是对声明义务和能力的覆盖，不能外推到工具真实效果或最终答案正确性。README 明确说明默认执行器是确定性 sandbox/mock；真实编辑仅在生成的测试夹具中进行，实时副作用记录执行器仍是后续工作。

来源：[GapHarness 仓库及边界声明](https://github.com/HaochengLu/GapHarness)。

### AgentSpec

用触发器、谓词和处置机制构成 DSL，在运行时约束 agent 行为。可以参考规则接口和工具调用边界。其公开定位是运行时约束执行，不能仅凭相关实验结果推出全部软件功能正确。

来源：[论文，ICSE 2026](https://arxiv.org/abs/2503.18666)、[代码](https://github.com/haoyuwang99/AgentSpec)。

### No Certificate, No Execution

这篇论文的思想与我们高度接近：提议与认证分离，执行轨迹需要可检查证书，证明相关历史通过 proof memory 保存，还讨论策略版本与重新认证。

它值得用于核对理论边界，特别是“单步允许不代表整个轨迹允许”。本轮核对到的是理论框架和示例，没有确认可直接替代我们整体系统的运行实现。

来源：[作者论文](https://arxiv.org/html/2605.24462v1)。

### Methods for Formal Verification of Agent Skills / enclawed

讨论 skill 的能力边界、工具调用的细化类型和有界模型检查，接近“把现有能力建模后纳入管控”。论文明确把运行时正确性作为假设；其参照实现尚不包含运行时自身的形式化证书。

来源：[论文](https://arxiv.org/html/2605.23951v1)、[参照仓库](https://github.com/metereconsulting/enclawed)。

## 4. 上游规格工具与常见邻近产品

| 项目 | 关系 | 不能混淆的保证 |
|---|---|---|
| [GitHub Spec Kit](https://github.github.com/spec-kit/) | 规格、计划、任务、实现及收敛流程；可作为规格生成和工作流参考 | Markdown 产物、检查清单和 agent 分析本身不是产品的形式证明 |
| [Kiro](https://kiro.dev/docs/specs/correctness/) | EARS 需求、设计与任务，并把性质测试关联回需求 | 官方明确说明性质测试提供正确性证据，不能作为形式证明；不是全输入保证 |
| [Clover](https://arxiv.org/abs/2310.17807) | 代码、文档与形式注解的一致性闭环；历史研究参照 | 包含对规格和文档一致性的分析，与我们把已确认规格作为起点的边界不同 |

## 5. 两处源码核对带来的具体发现

**qed：形式证明到底证明了什么，需要读命题。**

`no_skip_verification` 证明：非终止状态到达 `passed` 前，其状态必须是 `verifying`。这是有价值的编排保证，但该命题本身不证明检查器正确、规格完整或产物满足规格。架构文档还明确把 IO 放在外层。可以借其纯内核结构，同时继续检查状态机与实际工具的连接。

来源：[定理源码](https://github.com/tskovlund/qed/blob/main/Qed/Proofs/NoSkip.lean)、[纯核心与 IO 外层](https://github.com/tskovlund/qed/blob/main/docs/architecture.md)。

**Overplane：调用了求解器，不代表所有未证明情况都会阻止继续。**

已查提交 `eb07dd8601667bacecfbbfd41ab53d22a250f928` 的 `finishVerdict` 对 C6 返回零退出；合并检查解析器也有把工具错误记为告警的路径。这说明其该层行为和我们要求的严格准入不同。此处是静态源码观察，没有实际触发该路径，也不是完整安全审计。

来源：[核验代码](https://github.com/overplane/overplane/blob/eb07dd8601667bacecfbbfd41ab53d22a250f928/internal/cli/buildverify.go#L236)。

## 6. 建议的阅读顺序

1. **qed**：先看已有的形式化流程内核怎样写，保证在哪一层结束。
2. **EquiVM**：看规格怎样直接绑定实际交付产物，以及可信前提如何公开。
3. **AET + Why3**：看尝试历史、证据适用性、局部视图和过期重验。
4. **WybeCoder + Aria**：看粗粒度生成、证明反馈和子目标协作；Rust 路线再看 AutoVerus / VeruSAGE。
5. **Overplane + CodeLogician**：对照产品交互和集成形态。
6. **HTPS**：作为导航搜索与价值回传的算法参照；其结果不能直接代替四类动作导航的实验。

以上顺序是调查建议，不变更已确认的 Vorton 系统方案。
