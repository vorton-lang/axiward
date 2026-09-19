# Axiward

从用户确认的规格，推进到有证明、可追溯的产品。

Axiward 是本地项目控制器。项目的规格、验收命题、候选文件、构建目标与产物由运行时加载的 `acceptance.json` 及固定材料定义；在已支持的 Lean 接入约定内，更换项目不需要修改或重新编译控制器。

加载会将整个规格包固定到 Git 内容版本。工作包、核验和交接绑定这一版本；外部规格草稿不改变已生效输入。规格文字及形式含义必须由用户确认，编译不能代替确认。

[完整产品根](source/spec/Root.md) 与普通示例分别验收。`source/examples/` 中 FIFO 和后继函数均通过统一入口接入；它们通过不表示完整 Axiward 已满足产品根。产品根的 Lean 草稿尚待用户审核，不自动注册。Worker 使用完全访问模式并遵守说明，候选核验沿用原生 harness。

- [接入与使用](source/docs/product-guide.md)
- [实现与信任边界](source/docs/architecture.md)
- [证明及检查范围](source/docs/execution-slice.md)
- [当前限制](source/docs/roadmap.md) · [执行权限](source/docs/permissions.md)

## 构建与检查

使用 `source/lean-toolchain` 指定的完整 Lean 4.34.0、Git、Python 3.11+ 与本机 Codex CLI。以下命令在原仓 `source/` 执行：

```powershell
lake build axiward
python Tests/acceptance.py --case fifo --toolchain C:\Tools\lean-4.34.0-windows --output ..\.work\fifo-new
python Tests/acceptance.py --case successor --toolchain C:\Tools\lean-4.34.0-windows --output ..\.work\successor-new
```

用户已将单次功能检查上限放宽至 60 秒，包含准备与清理；统一验收入口保留整体超时，其他已有短检查继续采用更严格的限制。其他独立场景见测试 `--help`；不同场景的记录包含控制器摘要，用于确认使用同一二进制。检查只创建新 `.work/` 目录，不自动删除旧产物。测试模拟的确认只适用于夹具。

## 本机发行物

在干净原仓根目录运行 `python source/package_cli.py --toolchain <完整工具链> --output .work\axiward-cli-new`。输出含 exe、适配器、普通示例材料、使用说明及源码/文件摘要；完整工具链、Git、Python 和 Codex 使用本机已有安装。本轮不自动打包或纳管原仓。

MIT License.
