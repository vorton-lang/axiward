# 历史推进记录

2026-09-18 将原先散落在本机任务目录的原型源码、设计记录、失败尝试及实验结果归入本仓库。这是本次导入，不伪造此前的 Git 提交时间。

入口：

- [最初设计与讨论稿](bootstrap/outputs/axiward-design-discussion.md)
- [已确认的原始交付路线](bootstrap/outputs/axiward-delivery-plan-draft.md)
- [M0 原型汇总](bootstrap/outputs/axiward-m0-results.md)：链接各探针的源码与报告。
- [M1 执行](bootstrap/outputs/axiward-m1-execute-results.md)、[精化图](bootstrap/outputs/axiward-m1-graph-results.md)、[变更与复用](bootstrap/outputs/axiward-m1-revision-results.md)
- [早期验收记录](https://github.com/vorton-lang/axiward/tree/c8dfe2887ba26d56fb33732ad34afc67c606d061/docs/releases)：包含当时的构建标识与证据摘要，按该提交查阅。
- [导入清单与摘要](bootstrap/manifest.json)

`bootstrap/outputs` 保留整理过的材料，`bootstrap/work` 保留实验中的输入版本、驱动和运行记录。路径与主机名做了脱敏，清单同时记录原文件与归档文件摘要；不能把脱敏副本冒充原始字节证据。

导入已完成；当时使用的[导入脚本](https://github.com/vorton-lang/axiward/blob/c8dfe2887ba26d56fb33732ad34afc67c606d061/scripts/import-history.py)保存在 Git 历史中。构建和使用方式以当前文档为准。

第三方工具链、缓存、构建产物、受管实验 Git 对象库和自动生成的上游协议全集没有复制进源码历史；相关项目代码、输入和结果记录已保留。后续实验在仓内运行，并把影响判断的记录直接提交到仓库。

**历史文档中的临时文本规则方案已被当前要求取代：权限隔离必须通过薄适配器与原生权限实际实现。** 当前状态以[项目状态](../docs/status.md)为入口。
