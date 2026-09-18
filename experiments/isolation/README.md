# 权限边界接入

状态：进行中。此次直接完成已批准的薄适配器隔离，不回退到完全访问权限加文本约定。

当前缺口：`session` 生成 `danger-full-access`。MCP 工具本身有参数和身份限制，但普通原生命令仍能访问正式仓库。验证器的候选执行也需要检查是否会形成绕过路径。

验收目标：

1. 普通 worker 命令不能直接读写正式仓库，也不能运行或修改受保护的控制端来取得权限。
2. worker 可以读写自己的视图，通过薄适配器调用已建模操作；用户入口不向 worker 开放。
3. 视图中的路径、候选和原生执行不能重新打开被禁止的项目访问；配置失败时拒绝启动，不静默恢复完全访问。
4. 限制仅作用于对应任务，正常外部调研与其他任务可继续。

代码、输入和实际结果保存在本仓库；可再生的原生运行目录使用 `.work/`。官方接口依据：[权限配置](https://developers.openai.com/codex/permissions)、[Windows sandbox](https://developers.openai.com/codex/windows)。权限配置与 MCP 是不同的控制面，需要一起验证。

初始调查记录：本机 `codex sandbox --help` 的实际语法为 `codex sandbox -P <profile> -C <cwd> <command>...`，没有 `windows` 子命令。`command/exec` 用 `permissionProfile` 选择方案，`thread/start` 用 `permissions`；二者不能同时传旧版 sandbox 参数。
