# M0-L2 原型验证结果

2026-09-18 · **在 D6 的原型前提下，本轮接纳与拒绝对照通过。**

已用 Lean 写出可运行的接纳探针：控制端固定 Q0 与构建配置，候选只提交实现和证明。只有固定目标、审查与内核复查通过，才产生绑定源码与产物的接纳记录。

| 输入或变化 | 结果 |
| --- | --- |
| 正确 FIFO 实现及证明 | 接纳；保存的记录再次核对通过 |
| 入队改为插到队头 | 原证明检查失败 |
| 候选把要证明的目标改成 `True` | 候选自身可编译，固定 Q0 目标检查失败 |
| 新增自定义公理作为证明依据 | 构建通过；公理审查拒绝 |
| 使用 `sorry` | 构建允许其警告；公理审查明确发现 `sorryAx` 并拒绝 |
| 给候选入队函数添加 `implemented_by` 替换 | 逻辑证明与构建通过；运行结果成为 LIFO；运行替换审查拒绝 |
| 错误源码附带旧 `.olean` | 旧缓存不被采用；重新检查源码时失败 |
| 候选试图提交自己的规格文件 | 输入边界直接拒绝 |
| 接纳后修改源码或二进制 | 旧记录核对失败 |
| 记录声称属于另一规格版本 | 版本核对失败 |

这里的“未接纳”不一概等于命题为假；具体阶段与原因保存在记录中。

## 实际速度

正确候选：目标检查与编译 **2.79 秒**，公理及运行属性审查 **6.24 秒**，局部内核复查 **3.83 秒**。这些不含全部哈希与文件复制耗时，仅是本次观测。

本轮复用固定 Lean 4.34.0 的受信库，重新核验全部本地候选模块及目标模块。因此没有重复 L1 的 116 秒全库复查。

## 文件与证据

- [Lean CLI](Main.lean)：建立独立输入快照、执行检查、产生与复核接纳记录。
- [固定目标](trusted/Gate.lean)、[环境审查](trusted/Audit.lean)：检查实际定理和编译环境中的属性，不凭候选的自然语言说明判断。
- [拒绝结果](evidence/negative-results.json)、[篡改结果](evidence/receipt-negative-results.json)、[运行替换的实际输出](evidence/runtime-swap-observed.json)。
- [正确候选记录](evidence/receipt.json)、[内核复查](evidence/03-kernel-replay.json)。
- [最终构建复核](evidence/final-results.json)、[最终篡改对照](evidence/final-receipt-results.json)、[最长候选标识的检查 / 复核](evidence/final-long-id-result.json)。运行记录使用独立短 ID，避免候选名称使后续记录标识过长。

同一工作区中可运行：

```powershell
.\.lake\build\bin\axiward_l2.exe check correct
.\.lake\build\bin\axiward_l2.exe verify run-13161496969600
```

每次 `check` 返回新的 run ID，后续 `verify` 使用该 ID。重建或修改检查器、规格、工具版本后，需要新的检查记录。完整快照与原始日志保留在 `work/m0-l2/runs`。

初次构建的检查器和源码保留在 `evidence/initial-verifier`，可复核初次记录；[最终记录](evidence/final-receipt.json)对应当前可执行文件。最终构建已重新运行全部候选对照及篡改检查。

## 当前边界

本轮依赖执行者遵守 [访问规则](../axiward-prototype-access-rules.md)，不篡改控制端、受信库、工具链和接纳记录。记录哈希用于检查一致性，不代替受保护的记录来源。

探针审查了候选自身声明的公理依赖、`unsafe`、`extern` 与 `implemented_by`。本轮覆盖上表中的错误，不宣称已经防住任意 Lean 元程序、环境篡改或恶意进程。编译器、运行时、固定标准库、哈希工具与宿主仍属于信任前提。

这个接纳探针本身尚未完成形式验证；正式状态内核的机器核验仍按 M1 推进。
