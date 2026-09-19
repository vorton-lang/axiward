# 接入与使用

同一个 Axiward 二进制通过规格包接入不同项目。当前支持 Lean 4.34.0、无自由 universe 参数的规格常量，以及 Lake 构建的候选；未提供任意语言的验证器插件框架。

## 先确认什么

| 对象 | 谁提供或确认 | 控制器检查 |
| --- | --- | --- |
| 规格文字及 Lean 含义 | 用户审核二者是否表达想要的产品 | 格式/编译不能代替语义确认 |
| 命题与实际候选、成品的对应 | 固定验收材料及用户审核 | 按声明的实际常量应用命题，核验相应证明，绑定实际源码、依赖和产物 |
| 当前有效版本 | 用户通过 init/adopt 或确认后的 revise 加载 | 整个规格包的 Git 对象与明确版本，工作包及凭据保留该绑定 |
| 运行观测 | 实际命令输出和退出码 | 保存原始证据，不把输出字符串当作数学证明 |

## 规格包

`acceptance.json` 为 schema 1，字段如下。实际例子见 `examples/successor/policy/acceptance.json`。

| 字段 | 含义 |
| --- | --- |
| `name`、`version` | 项目名和明确的规格版本；内容摘要另由 Git 绑定 |
| `specificationPath` | 用户阅读的固定规格材料，必须在 files 内 |
| `files` | 不可变输入，包括正文、独立 Lean 规格、Lake 配置、工具链版本和必要依赖 |
| `specificationModules` | 不依赖候选的 Lean 规格模块 |
| `candidateFiles` | `{source,target}` 映射：工作包中的候选路径及构建目录中的路径 |
| `buildTargets` | 本规格需要的 Lake 构建目标 |
| `proofModules` | 保存实际候选证明的 Lean 模块 |
| `artifacts` | 构建后必须存在的相对产物路径 |
| `claims` | `{id,proposition,arguments,proof}`：稳定标识、固定命题、实际候选常量参数及候选证明 |

命题可以为闭合 Prop，或以实际实现对象为参数的命题。数组索引只供工作流选择，不是产品含义。候选只能提供声明的源码；规格、放行条件与构建材料属于固定输入，不能在提交时自行替换。

FIFO 示例对全部 Type 0 元素类型、任意容量、状态与元素量化六项行为：创建、未满入队、满时处理、非空出队、空出队和测量。两种版本分别满时拒绝和正容量时覆盖最旧项，零容量均拒绝。固定 `Main.lean` 直接运行命题所绑定的 `Axiward.subject`。后继例子对任意 Nat 输入证明结果为输入加一及结果为正数；固定入口运行被证明的 `Implementation.next`。这些是接入材料，不是 Axiward 产品根。

## 加载、工作和交付

```powershell
$cli = 'C:\path\to\axiward.exe'
$repo = 'C:\path\to\new-project'
$policy = 'C:\path\to\user-confirmed-policy'
$lean = 'C:\path\to\lean-4.34.0-windows'
codex --version
& $cli validate-policy $policy
& $cli init $repo $policy $lean
& $cli session $repo "$repo\.view\worker-1" (Get-Command python).Source 'C:\path\to\adapter\server.py'
& $cli overview $repo
```

`validate-policy` 只做格式检查。`init` 是用户入口，调用前须确认语义。已有原仓使用 `adopt <repo> <reviewed-HEAD> <policy> <lean>` 接入已提交 `source/`，保留原历史并只登记未验证基线，不制造已接纳成果。

Worker 先读 status/handoff，明确选择节点和 execute/refine/explore/requestDecision 动作，再调用 next。执行候选写在包根，路径以 manifest 为准；固定材料和 `Goal.md` 在 `.axiward/policy/`。`AGENTS.md` 包含动作说明，`.codex/` 保存连接配置，`.axiward/` 保存视图、按需 evidence/materials 和 tmp。一个视图永久绑定一个包，新包用新的 `.view/` 目录；恢复不覆盖草稿。

只读状态与交接从正式 Git 历史恢复，不以 `view.json` 或外部草稿为 authority。根完成后 `deliver <repo>` 导出新的根内 `delivery/`；显式输出也必须是根内新目录，不能覆盖管理区。实际启动命令由项目固定材料定义。

## 精化和规格变更

精化候选包含 `plan.json` 与 `Refinement.lean`。`children` 可以选条目数组或 `{"reuse":节点}`；证明 `Refinement.valid : Plan.Relation` 必须建立真实子命题到父命题的蕴含。后继例子仅以“结果等于输入加一”为子目标，就能推出父目标中的后继与正数性质；没有要求索引完整分区。子目标创建不代表产品完成，组合仍核验实际共享候选。

规格草稿编辑不切换当前版本。用户先运行 `revise-preview <repo> <id> <policy>` 查看影响，再以返回的 `reviewToken` 调用 `revise`。凭据同时绑定原根与拟议规格，输入改变后必须重新预览。旧工作包保留其输入，不可凭旧证明发布为新版本。

用户决定、实验观测与形式证明分开记录；worker 不能通过适配器自行确认规格或填写“通过”。完全访问 worker 仍依赖操作约定，详见[执行模式](permissions.md)。
