# 权限边界接入

状态：权限实现、原生绕过检查、完整流程及 17 组回归均通过。

已修复的缺口：旧 `session` 生成 `danger-full-access`，普通命令可以绕过 MCP。现在每个视图生成独立的原生权限方案，MCP 位于受信侧；核验候选也通过受限进程执行。

验收目标：

1. 普通 worker 命令不能直接读写正式仓库，也不能运行或修改受保护的控制端来取得权限。
2. worker 可以读写自己的视图，通过薄适配器调用已建模操作；用户入口不向 worker 开放。
3. 视图中的路径、候选和原生执行不能重新打开被禁止的项目访问；配置失败时拒绝启动，不静默恢复完全访问。
4. 限制仅作用于对应任务，正常外部调研与其他任务可继续。

代码、输入和实际结果保存在本仓库；可再生的原生运行目录使用 `.work/`。官方接口依据：[权限配置](https://developers.openai.com/codex/permissions)、[Windows sandbox](https://developers.openai.com/codex/windows)。权限配置与 MCP 是不同的控制面，需要一起验证。

初始调查记录：本机 `codex sandbox --help` 的实际语法为 `codex sandbox -P <profile> -C <cwd> <command>...`，没有 `windows` 子命令。`command/exec` 用 `permissionProfile` 选择方案，`thread/start` 用 `permissions`；二者不能同时传旧版 sandbox 参数。

## 已取得的结果

| 检查 | 实际结果 |
| --- | --- |
| 普通 worker 读写正式仓库、读取控制端/适配器/核验目录 | 拒绝。 |
| worker 改写自己的权限配置 | 拒绝；可编辑文件位于 `work/`、`tmp/`，配置位于只读父目录。 |
| 复制 CLI 到可写目录，再调用用户决定命令 | 仍拒绝访问正式仓库，待决事项没有被修改。 |
| 将私有文件硬链接为待提交候选 | 适配器按打开后的文件句柄检查并拒绝。 |
| 正确 Lean 候选 | 在受限核验进程中通过。 |
| 候选尝试读正式仓库或写核验规格 | 被原生权限拒绝。 |
| 外部文件读取与另一个任务写自己的目录 | 正常。 |
| 四类流程、暂停恢复、自动组合、实际交付 | 在新增边界下通过。 |
| 同项目并发核验 | 修正原生权限设置竞争后通过；仅核验工具排队，工作包和状态转换仍独立。 |
| 两个不同项目同时核验 | 通过；没有全机或全 harness 的互斥锁。 |

记录：[原生接入与绕过检查](native-isolation-05.json)、[核验进程](verifier-results.json)、[完整流程](workflow-results.json)。原始运行目录在仓内 `.work/`，公开记录含相应摘要；路径做了脱敏。

其他记录：[历史打包产物的原生检查](release-native.json)、[配置拒绝](configuration-guard.json)、[完整回归](regression-results.json)。历史记录对应各自注明的输入与版本。

## 实现位置

- `Axiward/Interface.lean`：生成唯一的项目权限方案，保护正式仓库与控制端，关闭其他独立特权工具入口。
- `adapter/server.py`：拒绝旧的完全访问配置；核验输入句柄和链接，复制到保护区后再交给 Lean。
- `Axiward/Sandbox.lean`：候选的核验在原生受限进程内执行，输入只读、构建输出可写。
- `Tests/native.py`：测试原生默认配置的实际执行，包含普通命令、复制 CLI、硬链接、独立用户问答和其他任务。

## 保留的失败尝试

这些失败推动了具体修正，不能从进度记录里丢掉：

- [过窄的原生读权限](profile-elevated-minimal.json)：当前 Windows elevated 后端要求保留 `:root` 读取，采用对项目私有目录的明确拒绝。
- [核验目录嵌在拒读仓库内](initial-checker-layout.json)：原生进程无法进入工作目录；改为单独保护的 `<repo>.checks/`。
- 核验初始化曾把含连字符的包名写成无效 Lean `Name`，导致正确候选被拒绝；修正后正反候选通过，失败记录保留在提交 `36a221d`。
- [首次原生联测](native-isolation-01.json)、[第二次](native-isolation-02.json)：仅禁用隐式 MCP 服务会丢失其传输定义；改为完整的停用配置，不复制服务凭据。
- [第三次原生联测](native-isolation-03.json)：Windows 受限执行不接受自定义输出上限参数；小型访问检查改用原生默认上限。
- [并发回归失败](concurrent-regression-failure.json)：同项目的原生权限设置竞争，误挡正确构建；仅给该项目的核验工具增加 OS 文件锁。[同项目验证](concurrent-isolation-1789723190814302800.json)和[跨项目验证](concurrent-isolation-1789723338962569000.json)均通过。更换权限方案名字没有解决问题，失败对照仍保留。

隔离依赖已验证的原生权限配置、受保护的控制端和操作系统。新增具有独立权限的工具、变更运行环境或主动切换到完全访问模式，不属于这份验收结论。
