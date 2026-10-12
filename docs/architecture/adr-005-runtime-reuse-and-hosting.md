# ADR-005：运行时复用与 worker 运行方式

状态：**Proposed**，2026-10-12。框架迁移和worker运行方式尚未Accepted；本ADR只记录现状、既有约束和待评审选项，不实施架构变更。固定目录来源HEAD为 `52ee35267fddfcb4ca4108a7a37893e860598d97`。

## 已有事实与约束

当前是 **vendored OpenMuse TaskWorker＋自研chat/auth/store/model适配**。`core/src/runtime.mjs` 引用受控 `vendor/openmuse/runtime/engine/worker.mjs`；Edge适配位于 `integration/edge-adapter/`。不是纯自研，也不等于已接入CopilotKit完整SDK或Intelligence服务。[ADR-002](adr-002-upstream-pinning.md)的固定上游、MIT归属和受控patch约束继续有效。

保留SwiftUI客户端和Supabase Auth/Postgres数据层。任务lease/checkpoint、审批和结果未知语义仍需明确权威；expired lease或网络中断不构成安全重放外部写操作的证据。研究建议不自动改变现有HTTP合同、数据权威或模型配置。

## 待评审选项

| 选项 | 评审内容 | 当前决议 |
|---|---|---|
| 常驻worker | 原状态机/heartbeat的适配程度、部署运维、授权续期、故障恢复及成本 | Proposed，未选定或部署 |
| Edge有界分步 | 每次调用预算、checkpoint栅栏、独立调度调用方、恢复/撤权、事务与effects核验 | Proposed，现有适配和离线测试不足以放行长期执行 |
| 其他durable框架迁移 | 与现有worker/state/store的收益和风险、迁移边界及许可 | Proposed，未Accepted；本批不迁移 |

[OpenMuse研究](../research/openmuse-runtime-source-review.md)提出长任务常驻worker等工程建议；它不是Catpaw-m已接受的部署决定。[OpenDot评估](../research/opendot-runtime-assessment.md)的仓库身份尚未用户确认，composio候选许可未核验，未采纳代码；不能以其他同名仓库的MIT/Apache声明替它授权。

评审应比较同一任务在中断/接管/等待审批/撤权/unknown等路径的正确性与成本，形成明确方案和验收门槛后再改变ADR状态。版本来源、部署、用户可用性分别签收，不能用测试数量或安装成功替代产品验收。[现状快照](runtime-state-2026-10-12.md)不宣称性能、图片、侧栏或后端P0已放行。
