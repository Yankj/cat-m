# 产品基线与实现范围

当前可执行交付要求见 [对话式产品交付spec](conversation-first-delivery-spec.md)：页面、4条故事、状态/API与R1–R3门槛；R1新增[连续多模态P0](../acceptance/r1-continuous-multimodal-issues.md)。[此前一页说明](Catpaw-m_Product_Delivery_Baseline_2026-10-12.md)是用户真机失败反馈前的历史快照，不能作为最新通过声明；当前结果与owner仅见 [主计划](../status/master-plan.md)。冻结规格与下列历史资产不改。

当前产品方向、owner与验收只维护在 [主交付计划](../status/master-plan.md)。用户不接受散装Demo/手建委托；新主线是自然对话中的真实回复、服务端任务卡、审批与产物。下面保留v1规格/能力历史，不能充当当前产品接受。新记忆需求以 [brief v1](../architecture/memory-brief-v1.md) 为建议输入，待Store/合同适配与验收。

产品目标是移动端个人工作空间：会话、项目与文件阅读，持续委托和一次运行分开，成果保留版本，外部操作先确认具体版本/目的地，语音采用主动授权与可中止的 session。来源许可、记忆、授权 epoch 和核验状态必须可见。

冻结输入保存在 [iOS spec](../../apps/ios/docs/spec/README.txt)：产品 v0.5、技术正文 v1.3、iOS 实施 v0.1。原冻结 README 仍标技术 v1.2，与正文版本不同；本轮保留原字节，定位以文件正文和 SHA256 为准。原 10 项文件 SHA256 不改；两份 Swift 契约是当时的参考文件，不代表直接可编译。当前源码包含后续契约校准，不能用规格目标或旧开工状态替代验收。

| 功能域 | 已交付 v1 范围 | 待实现/未验 |
|---|---|---|
| 会话/项目/文件 | 本地持久消息/草稿、项目隔离、固定请求、CSV/版本阅读器、改稿 | 完整 Markdown/Mermaid、真实远程来源与大存储性能 |
| 模型/专家/技能/环境 | 本地配置冻结、有限种子目录、隔离分区、显式 fixture | 真实 provider、安全沙箱、子代理、安装执行、在线设备 |
| 持续助理 | 委托编辑、一次 Run、成果版本、来源配置、显式记忆/遗忘 | 真实研究/来源读取、跨生命周期云 worker/通知 |
| 操作确认 | 版本/hash/目的地绑定；本地受理、unknown、核验模型 | 真实外部效果、生产身份与服务权限 |
| 定时/语音/设置 | 前台本地 tick、双语资源、主动语音入口和 epoch 守卫 | 真机 ASR/TTS、拒绝/再授权、后台/中断、VoiceOver 与多设备完整验收 |

v1 的本地 Gateway SSE 演示与新增 façade HTTP 合同是两条独立适配。r2 接通 Task/Run/Artifact/ActionProposal 的合成服务投影；Goal/Monitor、真正来源和记忆工具尚未接通。冻结r3客户端在独立 `apps/ios-openmuse-demo`，恢复/审批/来源页面已在合成r2链路通过，见 [整合记录](../status/openmuse-integration.md)。真实能力门槛保持未验。

历史目标规格：[产品规格](../../apps/ios/docs/spec/catpaw-product-spec.md)、[技术规格](../../apps/ios/docs/spec/catpaw-technical-spec.md)、[实施计划](../../apps/ios/docs/spec/catpaw-ios-implementation-plan.md)。当前主线与里程碑只见 [主计划](../status/master-plan.md)；[验收索引](../acceptance/README.md) 保留实际历史结果。
