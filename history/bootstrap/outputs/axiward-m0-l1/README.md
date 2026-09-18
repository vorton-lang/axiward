# M0-L1 验证结果

2026-09-18（日本时间） · **通过本工作包的验收。**

Lean 4.34.0 在本机 Windows 上接通了：**Q0 → 实际队列函数 → 证明 → 可运行程序**。

| 检查 | 实际结果 |
| --- | --- |
| 六条 Q0 规格 | 均有通用命题，覆盖任意元素类型和自然数容量，包括 0 |
| 实际实现的证明 | `satisfies_Q0` 通过；随后用 `leanchecker --fresh` 重新核验保存的证明及导入依赖 |
| 公理清单 | 根定理仅依赖标准公理 `propext`、`Quot.sound`；未使用未完成证明或自定义公理 |
| 编译与运行 | 生成 Windows EXE；FIFO、满队列、空队列和零容量的运行观测符合预期；本机不把 Lean 加入 PATH 也能运行此 EXE |
| 错误对照 | 仅将“加入队尾”改成“加入队头”：错误版本能编译运行，原规格与证明保持逐字不变时，证明检查失败 |
| 产物对应 | 保存工具版本、固定源码快照、命令与退出码，以及源码、证明文件、生成 C 和 EXE 的 SHA-256 |

**本轮结论：Lean 可以承载这一最小实现与证明链。** 这份实验没有完成 Axiward 的权限隔离或可信自动接纳；下一工作包是 M0-H1。

先读 [六条规格与源码对应表](PACKAGE.md)。实际文件是 [规格](Axiward/Spec.lean)、[队列](Axiward/Queue.lean)、[证明](Axiward/Proofs.lean)。列表实现优先简单，没有增加性能要求。

## 这个“通过”保证什么

机器证明覆盖库函数对所有合法输入的行为，不以几个运行样例代替证明。运行样例用于检查编译与调用链。

仍需信任：人类规格与形式命题的对应、Lean 逻辑与内核、标准库的运行实现、编译器与链接器、运行时及宿主环境。源码和产物哈希记录关联，不证明编译器自身正确。`Main.lean` 是运行展示用的 IO 包装，未进行完整形式验证。

这次使用同一个 Lean 内核重新检查证明，不是独立实现的第二验证器。普通构建、公理打印和本地记录，也不构成对恶意候选的完整接纳机制；L2 将在已核实的隔离条件下验证该边界。[Lean 官方验证说明](https://lean-lang.org/doc/reference/latest/ValidatingProofs/)

## 证据

- [通过运行的完整记录](evidence/20260917T152318Z-24a3ab/result.json)：普通构建约 2.38 秒，包含导入库的内核复查约 116.48 秒；仅为本次观测。
- [公理输出](evidence/20260917T152318Z-24a3ab/04-axioms.log)、[正确运行](evidence/20260917T152318Z-24a3ab/06-runtime-fifo.log)、[零容量](evidence/20260917T152318Z-24a3ab/07-runtime-zero.log)。
- [错误版本的运行](evidence/20260917T152318Z-24a3ab/09-mutant-runtime.log)、[原证明被拒绝](evidence/20260917T152318Z-24a3ab/10-mutant-proof-rejected.log)：失败目标是 `item :: q.items = q.items ++ [item]`，并非语法错误。
- [独立启动记录](evidence/standalone-run.json)、[工具链与输入基线](evidence/toolchain.json)。
- [首轮失败记录](evidence/20260917T152255Z-b604f8/result.json)：列表长度化简未完成，容量界限证明被拒绝；修正证明步骤后通过。失败快照保留，没有改变 Q0。

## 复现

工具链固定为官方 [Lean 4.34.0 Windows 发行包](https://github.com/leanprover/lean4/releases/tag/v4.34.0)，下载文件已对照 GitHub 提供的 SHA-256 校验。没有项目级第三方依赖。

在本目录打开 PowerShell，使用本机已下载的便携工具链：

```powershell
.\verify.ps1 -LeanBin '..\..\work\m0-l1\lean-4.34.0-windows\bin'
```

在其他目录或机器上，把参数替换成相同版本工具链的 `bin` 路径。脚本在新的 `evidence` 子目录复制输入并构建，保留失败记录；不会清理旧尝试。复现脚本是本实验的自动记录工具，不是 Axiward 的可信接纳内核。重跑时保持输入目录不变。

直接运行本次产物：

```powershell
& '.\evidence\20260917T152318Z-24a3ab\project\.lake\build\bin\fifo_demo.exe' 2 alpha beta gamma
```

此例接受 `alpha`、`beta`，拒绝超出容量的 `gamma`，再依次返回 `alpha`、`beta` 和“空”。
