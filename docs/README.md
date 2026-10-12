# 文档索引

当前进展、owner、产品门槛与未验项只维护在 [主交付计划](status/master-plan.md)。固定目录的来源提交映射在 [local-integration-source.json](status/local-integration-source.json)，本地验证快照在 [固定目录验收](acceptance/local-fixed-directory.md)。

| 内容 | 入口 |
|---|---|
| 产品方向与页面/状态/API | [conversation-first spec](product/conversation-first-delivery-spec.md)、[产品资产索引](product/README.md) |
| 设计、tokens、A1图标与历史截图 | [设计索引](design/README.md)、[design-tokens.json](design/design-tokens.json) |
| 验收记录 | [验收索引](acceptance/README.md)、[连续多模态问题单](acceptance/r1-continuous-multimodal-issues.md) |
| 主 iOS 来源与 P0 bridge 证据 | [来源清单](status/ios-p0-import-provenance.json)、[原生结果快照](acceptance/evidence/ios-p0-native-bridge/RESULT.json) |
| 后端失败收尾 | [验收与边界](acceptance/backend-p0-finalization.md)、[原生契约交接](../services/edge/docs/NATIVE-HANDOFF.md) |
| 图片本地输入独立组件 | [接入契约](../packages/ios-image-composer/README.md)、[合成验收](acceptance/ios-image-composer.md)；未宿主接线/未开放生产路线 |
| 侧栏独立组件 | [接入契约](../packages/ios-navigation/README.md)、[合成验收](acceptance/ios-sidebar-navigation.md) |
| 独立 QA | [iOS 冻结补丁](../qa/ios-dialogue-p0/REPORT.md)、[后端撤权收尾](../qa/backend-finalization-p0/REPORT.md) |
| 运行时研究与待评审决策 | [研究索引](research/README.md)、[ADR-005](architecture/adr-005-runtime-reuse-and-hosting.md)、[2026-10-12现状快照](architecture/runtime-state-2026-10-12.md) |
| 下一版主动目标领域 | [中文规格与源码gap矩阵](spec/proactive-goal-kernel-v1.md)、[首批合成验收](acceptance/proactive-goal-kernel.md)；实时进度见主计划 |
| 历史架构、合同与来源 | [架构索引](architecture/README.md)、[冻结合同](../services/facade/contract/native-contract-v1.json)、[导入来源](status/import-provenance.json) |

v1/r2/r3 与各分支报告描述其当时输入和实测层；保留原文，不把历史计数改成当前通过。固定目录不包含 canonical 未跟踪候选资产，也未替代仍在装机/云端验证的 owner 工作目录。
