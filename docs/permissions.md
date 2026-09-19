# 执行模式与检查范围

当前 worker 使用用户批准的完全访问模式。本机 Codex Windows elevated 沙箱在拒绝项目根后，启动内部工作空间时报 `CreateProcessWithLogonW failed: 267`；因此保留普通仓库与 `.view/<包>/` 布局，以说明文档约束 worker，不再要求原生隔离。这是已观察到的本机限制，不对所有 Codex 版本作结论。

## Worker 操作约定

- 根据 `status` 与交接明确选择节点和动作，通过 Axiward 领取、提交、恢复或取消工作包。
- 只编辑本包候选和临时资料；正式仓库、其他包、控制端与适配器通过规定入口操作。
- 用户决定走独立问答通道，worker 不自行填写答复或调用管理 CLI。
- 完全访问模式不会在操作系统层阻止绕行。MCP 入口继续检查参数、归属、候选路径和封存规则，这些检查不等于机器级隔离。

`session` 生成 `sandbox_mode = "danger-full-access"`，保留独立的 MCP 用户问答。包根唯一的 `AGENTS.md` 说明上述约定与当前动作；不修改全局 Codex 配置。

## 候选核验进程

`Sandbox.runVerifier` 保留已有的原生限制：候选输入只读、构建输出可写、核验进程不能访问正式仓库。该限制只约束核验进程，不隔离完全访问的 worker。

核验目录位于项目内 `.checks/`。Windows 会把项目根的拒绝 ACL 继承到它的后代，因此控制器只对刚创建、尚未放入输入的 `snapshot/` 建立受保护的 ACL 继承边界。操作前核对真实路径处于本项目 `.checks/<run>/`，拒绝已有、非空或重定向目录；不修改父目录或旧数据的 ACL。

新目录保留控制器用户、SYSTEM、Administrators 的管理权限，从本机公开账户信息解析现有 `CodexSandboxUsers`，只授予其 ReadAndExecute；不增加通用用户组授权，不给该主体源码写权限，不读取凭据或持久化 SID。账户组不存在则明确失败，不自行创建。控制器的精确 RX 授权落实原 profile 声明的 snapshot read；本机 harness 不会补回被继承边界隔断的读 allow。原生 harness 继续执行项目根 deny，且仅向 `.lake/`、`.tmp/`、manifest、audit 输出授予原有写权限。

PowerShell 的路径提供器在父目录拒绝下可能把初始目录退到盘根。启动器通过 .NET `ProcessStartInfo.WorkingDirectory` 直接绑定 Lake 的 snapshot cwd；三阶段使用同一实际目录，stdout/stderr 明确按 UTF-8 完整转发，退出码保持。没有为适配错误 cwd 修改 Audit 或其他规范文件。以上 ACL 和进程调用属于实现依赖与外部信任边界，正常核验通过不等于权限隔离性质的完整证明。

本机 Codex CLI `0.155.0-alpha.9` 的 Windows elevated 沙箱曾在同一用户环境首次并发注册路径时出现共享 SID 缓存与目录 ACL 不一致，使已授权构建写入被拒绝。Axiward 按同一 `CODEX_HOME` 共用启动锁，直到受限子进程发出就绪信号才释放；同项目核验仍用项目锁排队，不同项目的核验主体可以并行。该协调只约束 Axiward 发起的核验，其他独立 Codex 进程不自动遵守，也不表示已修复 Codex 的共享缓存缺陷；不能把本机观测推广到所有 Codex 或 Windows 版本。

## 当前检查范围

`Tests/native.py` 检查真实 Codex MCP 路由、独立用户问答、答复持久化和完整交接；测试客户端模拟用户答复，不使用模型轮次。工作包、Git 状态及实际产物由相应功能检查覆盖。

按用户最新决定，跳过权限隔离检查。旧模式的“worker 不能读取仓库”“复制 CLI 必须被拒绝”“完全访问配置必须拒绝”等断言不适用于当前模式，不能拿旧通过记录声称当前存在强制隔离。
