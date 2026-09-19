# Axiward · 使用说明

**Axiward 是一个本地项目控制系统。** Agent 在工作视图里提出实现、分解任务、探索或询问用户；Lean 控制端决定哪些操作可以进入正式项目。正式状态、源码和证据共用一条 Git 历史。

当前支持 **Lean 有界 FIFO 队列**的两种登记规格：满时拒绝、满时覆盖最旧元素。控制流程已通过工程检查；真实 agent 自主推进仍待实战验证。

按当前问题阅读：[从发行目录启动](#从发行目录启动) / [从源码启动](#从源码启动) → [四类工作流程](#agent-的四条工作流程) → [暂停与变更](#暂停变更恢复) → [交付](#完成与交付)。规格见下节，具体操作按对应小节查阅。

## 队列规格

示例根规格的六项承诺如下；容量是任意自然数，允许为零。

| 条款 | 用户可读含义 |
| --- | --- |
| 0 | 创建后队列为空，容量等于给定值。 |
| 1 | 未满时从尾部入队。 |
| 2 | 满时拒绝且保持不变；另一登记版本在正容量时替换最旧项，零容量仍拒绝。 |
| 3 | 非空时从头部出队。 |
| 4 | 空队列出队返回空，队列不变。 |
| 5 | 长度等于实际元素数，不超过容量；容量保持不变。 |

## 你需要做什么

1. 确认根规格，初始化项目。
2. 给 Codex 打开专用工作视图，让 agent 通过 Axiward 推进。
3. 回答具体问题；需要时暂停、恢复或修改根规格。
4. 查看 `complete` 和交付清单，验收实际产品。

你不用替 agent 写实现、证明或维护状态图。

## 从发行目录启动

在干净源码签出中运行 `python package_cli.py --toolchain <Lean完整目录> --output .work\axiward-cli-new`。输出包含独立 `axiward.exe`、两个适配器文件、两套登记策略、使用说明和文件 SHA-256/源码提交清单，使用时不需要源码签出。

在发行目录打开 PowerShell：

```powershell
$app = (Get-Location).Path
$cli = Join-Path $app 'axiward.exe'
$lean = 'C:\Tools\lean-4.34.0-windows'
$python = (Get-Command python).Source
$repo = Join-Path $env:USERPROFILE 'AxiwardProjects\queue'
$view = Join-Path $repo '.view\package-1'
codex --version
& $cli init $repo "$app\examples\fifo\policy" $lean
& $cli session $repo $view $python "$app\adapter\server.py"
```

`$repo` 必须是新目录。本版不迁移此前没有 `source/` 的试验仓库，旧数据不会自动删除。Session 固定 exe、Python 和适配器的绝对路径，使用期间保留发行目录位置。后续 Codex 工作视图操作与下节相同。

## 从源码启动

需要 Windows x64、Git、Python 3.11+、Lean **4.34.0 的完整发行版**、已安装的 Codex 及其已初始化的 Windows 原生沙箱（本机公开组 `CodexSandboxUsers`）。Axiward 不创建该账户组；缺失会给出明确依赖错误。使用现有 Codex 账户；Axiward 不调用模型 API，也不要求另配 API key。Python 适配器只使用标准库。实际候选核验需要从当前进程启动 `codex`，因此同一个 PowerShell 中 `codex --version` 必须成功；桌面应用已安装不等于普通终端 PATH 已包含其 CLI。缺失时确认现有 codex.exe 位置，仅给当前终端补路径：

```powershell
$codexDir = 'C:\path\to\directory-containing-codex.exe'
$env:PATH = "$codexDir;$env:PATH"
codex --version
```

初始化、建 session、领取新包及封存执行/精化候选会先检查入口，缺失时明确提示且不实施该步。已登记请求的幂等返回和原包恢复仍可用，参数冲突仍会被拒绝。预检不启动模型或沙箱，不代表候选核验通过，也不改全局配置。若依赖在已封存后的核验阶段消失，失败回复与证据指出具体原因；已结束的旧包保持结束，修正环境后领取新包。

下面在 Axiward 源码仓库根目录运行；把 Lean 路径换成本机位置。示例在开发仓库的 `.work/` 下创建一个独立受管项目，其内部使用普通签出布局：

```powershell
$app = (Get-Location).Path
$cli = Join-Path $app '.lake\build\bin\axiward.exe'
$repo = Join-Path $app '.work\queue'
$view = Join-Path $repo '.view\package-1'
$lean = 'C:\Tools\lean-4.34.0-windows'
$python = (Get-Command python).Source

& "$lean\bin\lake.exe" build axiward
codex --version
& $cli init $repo "$app\examples\fifo\policy" $lean
& $cli session $repo $view $python "$app\adapter\server.py"
```

把 `$view` 加入 Codex，设为受信项目，重新打开任务，确认出现 Axiward MCP 工具。生成的配置只作用于这个工作视图；没有修改全局配置。

工作工具已预授权，保留独立的用户问答通道。不要改成 `approval_policy = "never"`：当前 Codex 会连用户问答一起屏蔽。

给 agent 的起始指令：

> 使用 Axiward 完成本包。先读取 status 和 handoff，自行选择节点与动作，再向 next 提供 node 和 action。按已核准的流程工作，需要我决定时通过 ask_user 询问。包结束后保存交接；后续新包使用新的工作空间。

`$repo` 是人可以直接打开的项目根：`.git/` 保存 Git 数据，`.axiward/` 管理状态及正式成果随 Git 提交，`source/` 保存正式共享源码，`product/` 保留当前格式的根产物。`.gitignore` 排除 `/.view/`、`/.checks/` 和 `/delivery/`；每个包的工作空间是其中一个独立目录。控制端提交后同步普通签出文件，碰到会被覆盖的本地修改或未跟踪文件则拒绝继续，不丢弃草稿。若提交已记录而签出中断，后续写请求会先恢复签出；只读状态始终来自 Git 提交。

`.view/<包空间>/` 本身就是候选工作区：`Queue.lean`、`Proofs.lean` 或当前动作所需文件直接放在包根；领取后的根目录还提供 `Spec.lean`、`Goal.lean` 和唯一说明文件 `AGENTS.md`。`AGENTS.md` 同时包含工作边界与当前动作格式，不另生成 `ACTION.md`、`WORK.md`、`START.md` 或 `claims.json`。

`.codex/` 保留连接配置；包内 `.axiward/` 保存生成的 `view.json`，按需创建的 `materials/` 和启动前备好的 `tmp/`。临时研究文件放在 `.axiward/tmp/`。完整原始证据只在显式调用 `evidence` 时写入 `.axiward/evidence.json`；正常领取、恢复、查询和提交不会自动导出它。

核验临时副本在项目根 `.checks/<run>/snapshot/`，交付默认在 `delivery/`。旧目录和已有工作空间不会自动移动、迁移或删除。未提交草稿不由 Axiward 保证保存或恢复。受管项目的正式 Git 写入通过 Axiward，普通浏览无需控制入口。

每个视图同时只给一个原生任务使用。`session` 先创建空工作空间与身份，首次领取后永久绑定一个包；编号不需要预先写在目录名里。包结束后 `next` 返回原包及 `requiresNewSession`，新包须用另一个 `.view/<名称>/` 空间和新 session。恢复原包仍使用其所属视图，另一身份不能自动接管。可以在新空间继承原 worker 的对话上下文，但不沿用旧空间权限。包不会自动过期，系统不自动启动或调度 worker。

同一项目的原生核验工具会排队使用，避免 Windows 权限设置相互干扰。不同工作包仍可同时编写、提交和等待；不同项目可以同时核验。没有全机锁或独立守护进程。

项目配置与 MCP 启动方式依据 [Codex MCP 文档](https://developers.openai.com/codex/mcp)。当前 Windows 原生沙箱无法在拒绝项目根后正常启动内部 worker，用户已批准使用完全访问模式。`session` 生成 `sandbox_mode = "danger-full-access"`，保留独立用户问答；候选核验仍使用已有受限入口。

`AGENTS.md` 约定 worker 只在本包空间编辑候选，通过 Axiward 获取材料、提交及询问用户，不直接修改正式仓库、其他包、控制端或适配器。完全访问模式不会在操作系统层阻止这些操作，工作边界依靠 worker 遵守说明。

此前生成的受限视图需停止对应任务后，用 `session` 创建新的完全访问空间；正式项目历史保留。仍然活动的旧包按其归属恢复或显式结束，不因换配置而自动转交。

## Agent 的四条工作流程

封存只读取动作白名单中的候选文件：生成的 `Spec.lean`、`Goal.lean`、说明和 `.codex/` 不进入候选。正式 Git 中 `.axiward/candidate/` 仍是不可变封存证据，与用户工作区的扁平布局无关。

`status` 只读，未领包时返回项目地图与项目层 `handoff`。空间已绑定包时，保留项目地图并返回完整包级交接、失败诊断、`actionInstructions`、条款编号和实际路径；不依赖本地 `view.json`，也不改写包内文件。Worker 根据这些材料明确选择节点与 `execute`、`refine`、`explore`、`requestDecision` 中的一种动作，向 `next` 同时提供 `node` 和 `action`。控制器核准后返回固定动作、工作包编号、候选目录、规格和完整包级交接；领取后不能换类。省略节点和动作只用于恢复当前空间已经绑定的包，不会自动选择或领取新包。每次领取、恢复核验或接收答复都重新提供完整交接、动作说明及路径，不能依赖 Codex 曾经读过 `AGENTS.md`。

交接直接列出相关目标与成果、适用决定、正式尝试的结局与原因、阶段和在途操作。它每次从 Git 正式状态计算，不维护已读状态；新身份或失去上下文的同一身份都会再次得到必要内容。`status.head` 与 `handoff.currentHead` 来自同一快照。`snapshot` / `handoff.inputSnapshot.head` 则固定为领包时的输入，后来的变化不会替换包内源码或规格。

| 动作 | Agent 写什么 | 系统做什么 |
| --- | --- | --- |
| `execute` | `Queue.lean`、`Proofs.lean` | 封存一次终稿；核验当前命题与实际产物，通过后闭合节点。 |
| `refine` | `plan.json`、`Refinement.lean` | 核验分解蕴含关系、依赖与复用；子目标完成后自动核验父目标。 |
| `explore` | `exploration.json`，最后写 `report.md` | 先 `prepare`，再按预算运行实验，最后 `conclude`；探索本身不关闭产品目标。 |
| `requestDecision` | `question.json` | `submit` 保存问题，`ask_user` 走独立用户通道；答复持久化后返回原任务。 |

`Spec.lean` 是定义，`Goal.lean` 列出实际要求的定理名字与类型；工具响应和 `.axiward/view.json` 的 `claims` 字段标出本包固定输入中的条款编号，无权访问时为 `null`。`AGENTS.md` 和每次返回的 `actionInstructions` 提供当前动作的文件格式与模板。`search` 可找到尚未导出的资料，`view_add` 将所选资源导出到 `.axiward/materials/`；`node/` 材料来自固定输入快照，`current/` 提供交接所引用的当前正式历史、证据和报告，继续受相同访问规则约束。必要上下文不可见时，交接明确报告 `blockedByMissingContext`，不能当作完整输入继续依赖它。

资料导出针对控制器已登记的资源目录，当前不是按任意仓库路径签出文件的接口。Worker 无需读取完整仓库。

失败后领取的新包会在 `handoff.diagnostics` 直接收到原始 Lean 诊断、可解析位置，以及消息中已有的未证明目标和局部前提；没有这些信息的输出不会补造。`checkedSnapshotResource` 指向实际被检源码及 gate，可能不同于封存原稿，`evidenceResource` 保留完整原始证据。交接读取不重跑核验；访问被撤销时明确报告缺失。领取新包再修改，同一个终稿不能反复覆盖。网络或进程中断后的 `resume` 保持原终稿，按最新正式源码重新合并核验。重试同一请求要保持 `request_id` 和内容相同。

### 探索模板

```json
{
  "question": "当前队列表示是否满足 FIFO？",
  "maxRuns": 2,
  "stopWhen": "比较候选后形成下一步建议，最多运行两次核验"
}
```

R0 的已建模项目实验是：在隔离的构建目录，用登记的 Lean 验证器检查一个不可变候选。候选写到 `trials/<名称>/Queue.lean`、`Proofs.lean`，由 `experiment` 发起。预算是 **0–8 次**；0 次适合纯分析。准入只允许生成观测与建议，不允许实验改写正式源码、根规格或成果。

实验先登记准确输入，再由 Codex 原生 `command/exec` 执行，完整记录交给控制端。原始记录按需通过 `evidence` 导出到 `.axiward/evidence.json`；`report.md` 保存 agent 的解释。两者不会混成证明。

外部调研仍可使用原生工具；引用和架构建议可以写进报告，供后续 worker 参考。它们不会自动成为受信事实。首版没有任意 shell 实验、通用网站观测或多语言验证器的接入。

### 决定模板

```json
{
  "prompt": "先使用哪种队列表示？",
  "subject": "当前 FIFO 规格下的实现偏好；不改变规格",
  "options": [
    {"key": "list", "label": "先用不可变列表"},
    {"key": "explore", "label": "先比较其他表示"}
  ]
}
```

首版问题有 1–4 个明确选项，效果是**记录与当前规格绑定的用户偏好**。它不证明程序性质，不授权修改根规格。交接中的 `applicableNow` 会按当前目标、版本和依赖重新判断；`recordedApplicable` 只记录答复当时的准入结果。过期或选项外答复仅作历史输入。祖先或依赖目标的决定保留原作用范围，展示给新 worker 不扩大授权。工作侧没有 `inbox` 或 `acknowledge` 操作。

支持 MCP elicitation 的客户端会直接显示问题；不支持时，用户从独立终端运行：

```powershell
& $cli decide $repo 'answer-001' 0 1 'list' '先验证简单实现'
```

这里 `0 1` 是节点与包编号，以实际问题为准。此命令不开放给 worker。离线时不会启动后台任务；随后任何相关新包或原包的 `status` / `next` 都会带回必要的决定上下文。

## 暂停、变更、恢复

```powershell
& $cli overview $repo
& $cli pause $repo 'pause-001' '我暂时离开'
& $cli resume $repo 'resume-001'
```

暂停阻止新工作包、新实验和新核验。已开始的工作可以回传结果；仍可保存终稿、取消和接收用户答复。暂停不会把在途操作变成“未执行”。

根规格变更先预览，再由用户使用预览令牌确认：

```powershell
& $cli revise-preview $repo 'change-001' "$app\examples\fifo\policy-overwrite"
& $cli revise $repo 'change-001' "$app\examples\fifo\policy-overwrite" '<reviewToken>'
```

只使依赖变化要求的成果失效；保留其他成果和历史。进行中的旧包不自动取消，过期证据不能发布。令牌同时绑定旧根与新提案，根改变后须重新预览。

| 现象 | 下一步 |
| --- | --- |
| 已封存，核验回包丢失 | 原包调用 `resume`；不会换成后来编辑的文件。 |
| 实验在途，缺少终止记录 | **不重跑**。先确认原生执行进程已停止，查询保留记录，再由用户 `reconcile` 记为未知。 |
| 正式尝试被拒绝 | 看 `evidence`；下一轮决定实现、精化、探索或询问。 |
| 用户已答，原任务没有收到 | 读取 `status` 或领取相关新包；交接会再次提供决定，不依赖原 worker 的记忆。 |
| 已结束包的结果迟到 | 保存到原操作，不能复活工作包。 |
| 同一请求 ID 携带不同内容 | 拒绝。新尝试使用新 ID，重试保留原 ID。 |
| 数据损坏或绑定不符 | 停止转换并报错；不会把旧仓库当新项目初始化。 |

对账命令仅供用户在确认执行进程已停止后使用：

```powershell
& $cli reconcile $repo 'reconcile-001' 0 '<operationId>' '已确认原执行进程退出，结果丢失'
```

需要撤回某项材料的后续导出权限：`access <repo> <请求ID> <资源ID或前缀> deny`；用 `allow` 恢复该条规则。已经导出的文件或进入上下文的内容不会被抹除。

## 路线变更与共享源码

路线变更后，Discussion agent 读取 `invalidatedPackages`，立即通过 Codex 停止其中各 owner 对应的 worker，再执行 `axiward reclaim <repo> <request-id> <node> <serial> <reason>` 回收包。控制端命令不在 worker 白名单内；回收不代替在途操作对账。仍被当前路线依赖的共享节点不会列为失效。

源码和证明以包领取时的 `source/` 为固定基准。后交付包与最新源码三方合并，并核验新成果和当前全部已接纳保证。内容冲突或核验失败结束本包、保留原稿与原因，新包从最新源码继续；正式源码及已有成果保持不变。核验期间发生提交竞争则保留封存包，重试时重新合并核验。

候选只在首次领取时从固定基线填充，也遵守材料访问拒绝；恢复和查询不覆盖草稿，也不会补回用户已删除的候选。每次响应的 `blockedSourceFiles` 列出当前无权导出的基线文件。访问恢复后通过 `sourceResource` 取得该包的固定源码，不直接访问正式仓库；删除本地 `.axiward/view.json` 不会改变正式状态或触发重新填充。

## 完成与交付

`rootClosed` 表示根目标有当前有效证明；`complete` 还要求当前路线没有活动包、没有未解决的在途实验。条件满足就宣布完成，不等待旧路线 worker 停止或包回收。只有 `complete=true` 才能导出交付：

```powershell
& $cli deliver $repo
& "$repo\delivery\.lake\build\bin\fifo_demo.exe" 2 a b c
```

输出目录包含实现、证明、可执行文件，以及 `axiward-delivery.json`（规格、Git 快照、产物摘要）和 `axiward-receipt.json`。默认导出到项目根的 `delivery/`，返回实际目录；要求新目录，不覆盖已有交付物。后续版本可用 `deliver <repo> delivery/<新名称>`；显式路径也必须位于项目根内，不能进入 `.git/`、`.axiward/`、`source/`、`product/`、`.view/`、`.checks/` 等保留子树，也不能通过重定向父目录导出到其他位置。自定义目录在 `delivery/` 之外时，需自行决定其 Git 忽略规则。

## 保证与边界

Lean 检查的是实际控制转换及产品命题；不使用 `sorry`、额外公理、`unsafe` 或运行时替换绕过核验。内核保证范围见[工程说明](execution-slice.md)。故障和集成检查用于验证 Git、进程、MCP、编译和导出的接合处，不替代数学证明。

用户确认的根规格、操作规范，以及 Lean 发行版、编译器、Git、原生 harness、适配器和操作系统仍属于信任前提。规格表达了什么与用户真正想要什么之间的差距，不由控制系统证明。当前完全访问 worker 必须按说明使用工具，控制系统不承诺强制阻止其绕过工作边界。

Worker 负责决定后续工作，控制器核验操作和成果，不保证开放问题必然解决。首版完整性指上述 R0 控制闭环；新的产品领域需要另行实现并审核验证器契约。
