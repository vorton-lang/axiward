# 问题描述

**标题：Windows elevated 沙箱首次并发注册可写目录时，权限 SID 缓存失去一致性，导致已授权写入被拒绝。**

**归属：Codex 原生 Windows 沙箱。** 使用独立 Python 探针直接调用 `codex sandbox` 即可复现，不需要 Axiward、Lean、Git 仓库操作或模型推理。

## 已复现环境

| 项目 | 值 |
| --- | --- |
| 操作系统 | Windows 11 专业工作站版，64 位，10.0.26200 / build 26200 |
| Codex CLI | `0.155.0-alpha.9` |
| 沙箱模式 | `windows.sandbox = "elevated"` |
| 调用方式 | 两个独立 `codex sandbox` 进程，同一 Windows 用户及同一 `CODEX_HOME` |
| 工作目录 | 各自独立且新建的目录，使用不同的权限 profile |
| 探针运行时 | Python 3.11.9，仅标准库 |

不对其他 Codex 版本、其他 Windows 版本或 unelevated 模式作结论。

## 触发条件与复现步骤

附带脚本：[windows-sandbox-concurrency.py](windows-sandbox-concurrency.py)。它创建全新的探针目录，不删除已有目录、不手工修改 ACL，也不读取 sandbox 用户密码。

1. 为两个独立项目分别创建只读工作目录、私有目录、可写 `.lake` / `.tmp` 子目录，以及两个可写文件。
2. 两个权限 profile 均配置 `:root = "read"`、私有目录 `deny`、工作目录 `read`、指定输出目录及文件 `write`，并关闭网络。
3. 同时启动两个命令，命令形状为：

   ```text
   codex sandbox -P <独立profile> -C <独立工作目录>
     -c permissions.<profile>=<本项目权限配置>
     -c windows.sandbox="elevated"
     -- python -I -S windows-sandbox-concurrency.py --child
   ```

4. 每个子进程尝试创建 `.lake/build-<pid>`，写入 `.lake` 与 `.tmp` 下的新文件，并记录自己的限制令牌 SID。
5. 父进程记录目录 ACL 与 `cap_sid` 缓存前后摘要，对照实际权限 SID。

在本项目根目录运行整个实验：

```powershell
python experiments/windows-sandbox-concurrency.py --output .work/codex-sandbox-repro-new
```

`--output` 必须是不存在的新路径。脚本先做新目录串行对照，再做新目录并发，随后对失败目录串行预热，再次并发。请检查 `results.json` 中各案例的 `probe.operations`；探针会捕获错误用于记录，进程退出码 0 本身不代表获准写入成功。

## 预期结果

两种执行顺序都应允许写入各自明确授权的目录，同时保持源码目录不可写、私有目录不可读。新增一个沙箱的权限映射不应丢失已有映射或改变已分配的权限身份。

## 实际结果

新目录首次并发时，部分或全部获准写入失败，例如：

```text
PermissionError: [WinError 5] 拒绝访问: '.lake\\build-<pid>'
[Errno 13] Permission denied: '.tmp\\probe-<pid>.txt'
```

两个独立的新目录实验均复现了失败，受影响目录随调度不同而变化。第二组包含以下完整对照：

| 条件 | `.lake` / `.tmp` 写入 | 源码写入 / 私有目录读取 |
| --- | --- | --- |
| 新目录串行启动两个进程 | 均成功 | 均被拒绝 |
| 新目录并发启动两个进程 | 两个进程均失败 | 均被拒绝 |
| 对上述目录串行预热 | 均成功 | 均被拒绝 |
| 已预热目录再次并发 | 均成功 | 均被拒绝 |

影响是可用性与正确性：原 Axiward 回归中两个正确候选都因无法创建构建目录被拒绝。实验未观察到私有目录读取或源码写入越权；这不是对其他并发安全性质的证明。

# 原因

## 已确认的直接原因

**目录 ACL 中获准写入的 SID，与实际进程限制令牌中的 SID 不匹配。** 串行及预热后并发时二者匹配，相关写入成功。

同一 Codex 用户目录下的 `cap_sid` 文件包含 `workspace`、`readonly`、`workspace_by_cwd` 和 `writable_root_by_path` 等权限标识。第二组实验记录到：

| 阶段 | 可写路径映射数 | 基础 SID | ACL 与令牌 |
| --- | ---: | --- | --- |
| 第一次串行 | 1 → 5 | 保持 | 匹配 |
| 第二次串行 | 5 → 9 | 保持 | 匹配 |
| 首次并发 | 9 → 1 | `workspace`、`readonly` 均改变 | `.lake`、`.tmp` 均无匹配项 |
| 串行预热两个目录 | 恢复至 8 | 保持 | 匹配 |
| 再次并发 | 8 → 8 | 保持 | 匹配 |

这将故障定位到 **Codex 共享 SID 缓存在首次并发注册时的一致性问题**。Axiward 的状态转换、Lean 构建与项目内锁都不是独立探针复现所必需的。

## 尚未确认的源码细节

尚未审阅对应 Codex 源码中的具体竞态语句。现有证据支持共享缓存读改写或初始化存在并发缺陷，但不能据此断言究竟是读取到部分文件后重新初始化，还是其他丢失更新路径。原生日志中读取 ACL 助手的跳过消息，也不能单独作为根因。

本机证据：

- [完整对照结果](../.work/sandbox-concurrency-cause-20260918-02/results.json)：实际命令、进程令牌、ACL、缓存前后摘要与读写结果。
- [第二组调查摘要](../.work/sandbox-concurrency-cause-20260918-02/summary.md)。
- [第一组独立复现](../.work/sandbox-concurrency-cause-20260918-01/results.json)。
- [最初的实际构建失败](../.work/concurrent-isolation-1789737982520545100/result.json)。

这些链接中的运行证据保存在本机 `.work/`，不随源码 Git 历史自动配布。

# 拟定解决方案

**用户已明确无法修改 Codex 源码，因此实施方案必须限定在 Axiward 侧。** 下述 Codex 内部修复仅解释依赖层需要满足的正确性条件，不再作为我们可直接执行的方案。

1. 对同一 SID 存储的“读取当前映射、分配缺失 SID、保存结果”实施完整的跨进程协调，避免不同进程丢失彼此更新。
2. 使用原子保存，防止读取到部分内容；遇到已有文件读取或解析异常时，不能无声地重新生成一套权限身份。
3. 目录 ACL 与进程令牌必须使用同一稳定的路径 SID；核对调用方、设置助手和运行助手之间的对应关系。
4. 同步只覆盖权限注册与更新，继续允许不同项目的命令并行执行。
5. 增加全新目录的首次并发回归，同时核对授权目录可写、限制目录仍拒绝、原有映射不丢失。已预热目录通过不能替代该检查。

Codex 内部修复不在本任务可执行范围内。

**Axiward 侧候选方案：协调原生沙箱的启动阶段。** 对同一 Codex 权限环境，由所有 Axiward 项目共用启动协调，直到实际受限子进程已经开始、权限身份已确定，再放行下一次启动；核验主体仍可并行运行。

该路线已经在 Axiward 的 `Sandbox.runVerifier` 实现：同一 Codex 环境的核验启动共用文件锁，受限 PowerShell 子进程发出就绪信号后释放启动锁，再执行固定的 Lake 命令。原有项目内核验锁保留。没有修改 Codex 源码、权限配置或目录授权范围。

实际生产入口验证：三个全新沙箱的执行区间重叠 1.719 秒，30 轮检查中获准写入全部成功、私有读取与源码写入全部被拒绝。原先失败的跨项目完整核验、同项目并发核验，以及正确/恶意候选隔离检查也已通过。

可复验生产入口（先构建 `axiward`，工具链路径替换为本机实际路径）：

```powershell
python experiments/windows-sandbox-concurrency.py --production-toolchain C:\Tools\lean-4.34.0-windows --output .work/startup-check-new
```

此模式通过同目录下的 `sandbox-startup.lean` 调用实际生产代码，测试父进程不加启动锁；它同时断言成功退出、执行时间重叠和权限结果。普通模式仍可独立复现未经过 Axiward 的 Codex 问题，复现时应与同一 Codex 环境中的其他沙箱任务错开。

边界保持明确：该协调只覆盖 Axiward 核验调用，其他独立 Codex 进程不自动遵守，Codex 用户级共享缓存缺陷本身仍未修复。原始生产入口观测位于本机 `.work/sandbox-startup-production-20260918-final/`；这些可再生运行文件不入 Git，复验使用上面的独立入口。
