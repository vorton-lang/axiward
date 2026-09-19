# 证明及检查范围

形式证明、版本绑定和运行观测分别报告。普通项目例子通过统一入口，不代表完整 Axiward 产品根通过。

## 现有纯控制内核

Model/Transition/Proofs/Workflow/Engine 的定理针对实际纯状态转换。`Tests/Audit.lean` 检查这一部分的声明与公理；主要对应如下。

| 保证 | 形式依据 |
| --- | --- |
| 发布结果绑定当前目标与候选 | `accepted_binding`、`current_result` |
| 精化图无循环 | `graph_acyclic` |
| 组合绑定当前子结果且必须经核验 | `composed_result_has_current_children`、`composition_requires_checked_output` |
| 工作流不修改目标或发布产品 | `workflow_preserves`、`workflow_never_publishes` |
| worker 身份不能作为用户答复或观测身份 | `worker_cannot_answer`、`worker_cannot_forge_observation` |
| 相同请求重放不更改状态 | `replay_preserves_state` |
| 旧版本不能凭旧结果发布 | `changed_scope_rejects`、`published_requirements_current` |
| 合并复核覆盖旧保证并绑定同份候选 | `rechecks_cover_required`、`rechecks_bind_merged_candidate` |
| 完成还要求过程义务结清 | `complete_requires_proof_and_settlement` |

这些定理不证明 Git、外部进程、编译器或完整应用 IO 的实现正确。旧 Completion 专用验收包和索引 6 接管分支不再是运行入口，也不作为产品根。

## 统一入口的运行检查

用户已明确将单次检查上限放宽至 60 秒。`Tests/acceptance.py` 每次只运行一个独立场景，命令预算 58 秒、外层 59 秒硬超时，子进程树终止最多 0.5 秒，并记录父进程总耗时；含准备和清理超过 60 秒不能记为通过。所有夹具创建在新的 `.work/` 输出中，不修改既有项目。每个结果记录实际控制器 SHA-256；FIFO 与后继场景必须使用同一摘要。

验收覆盖两个真实项目的接纳与交付、错误命题、缺证明、错版本、草稿与交接，以及真正的父子蕴含。具体场景以测试入口为准，不维护另一份并行检查清单。

统一入口的八项验收已有七项在 60 秒内通过，并使用同一生产二进制。FIFO 与后继项目的实际证明、交付、错误命题和缺证明拒绝、固定版本交接及真实精化关系均已核验；错版本的完整预览、确认与核验流程触发限时后，用户决定本轮跳过并允许合入；该项不计为通过，测试及失败记录保留。此前无总时限的性能诊断只属运行观测，不替代限时验收；旧版本检查记录也不自动继承。

保留的其他测试分别针对存储、协议工作流、状态快照、CLI/适配器、原生用户问答和依赖错误。协议夹具中的 `passed` 仅建立可控状态，不证明外部数学核验；模拟用户确认也不批准真实产品。

## 明确的验证缺口

完整产品根的 Lean 语义仍待用户确认。统一核验绑定实际命题、候选源码、必要依赖和产物，但这种绑定不能自行证明每个项目的入口与用户文字含义完全一致。

此前宏改写/运行替换反例被自动审查阻断，未执行。本次不重新生成或换工具运行，也不把 `loadExts=false` 的属性查询说成已经验证全部运行替换风险。权限隔离检查按用户要求跳过。真实模型持续开发、完整成品符合性及用户最终验收均需另行完成。
