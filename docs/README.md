# 文档索引（Diátaxis）

[← 返回项目 README](../README.md) · 当前进展只维护在 [主交付计划](status/master-plan.md)

本索引按 [Diátaxis](https://diataxis.fr/) 四象限组织。旧文档是其日期 / 源码范围的证据，保留原文，不把历史计数改成当前通过。

| 象限 | 读者目标 | 入口 |
|---|---|---|
| **Tutorials 教程** | 第一次跑起来 | [README · Quick Start](../README.md#quick-start)、[接手说明](../handoff.md)、[iOS 工程说明](../apps/ios-conversation/README.md) |
| **How-to 操作指南** | 完成具体任务 | [下载与安装](../README.md#下载与安装)、[使用场景](../README.md#使用)、[录屏分镜](demo-script.md)、[开发与测试](../README.md#开发与测试)、[Edge 离线验证](../services/edge/README.md)、[分支规范](development/branch-management.md)、[贡献指南](../CONTRIBUTING.md)、[长任务开发启动合同](planning/AF-1/development-start-contract.md) |
| **Reference 参考** | 查准确信息 | [配置参考](../README.md#配置参考)、[CHANGELOG](../CHANGELOG.md)、[iOS 版本规范](development/ios-versioning.md)、[目录角色](development/repository-layout.json)、[AF-1 底座 spec](product/agent-foundation-spec.md)、[CGUI-1](design/conversation-generative-ui-spec.md)、[设计 tokens](design/design-tokens.json)、[验收索引](acceptance/README.md)、[执行切片](status/delivery-slices.json)、[冻结合同](../services/facade/contract/native-contract-v1.json) |
| **Explanation 原理** | 理解为什么 | [架构总览](architecture.md)、[架构索引](architecture/README.md)、[最新代码与分支复核](architecture/repository-review-2026-10-15.md)、[ADR-005](architecture/adr-005-runtime-reuse-and-hosting.md)、[研究索引](research/README.md)、[云电脑提案](architecture/cloud-computer-proposal.md) |

## 完整入口表

固定目录的来源提交映射在 [local-integration-source.json](status/local-integration-source.json)，本地验证快照在 [固定目录验收](acceptance/local-fixed-directory.md)。

| 内容 | 入口 |
|---|---|
| 长任务开发与对话交互 | [启动合同](planning/AF-1/development-start-contract.md)、[可复制prompt](planning/AF-1/long-task-development-prompt.md)、[CGUI-1](design/conversation-generative-ui-spec.md)、[10项验收](acceptance/conversation-generative-ui-acceptance.md) |
| 家庭成长助理执行准备 | [M0契约](design/family-companion/m0-contract.md)、[初始验收矩阵](acceptance/family-companion/acceptance-matrix-v1.json)、[2026-10-23准备证据](acceptance/family-companion/preparation-2026-10-23.md)；实时进展见主计划 |
| 终版产品、视觉与技术设计 | [FINAL-1综合规格](product/catpaw-final-product-spec.md)、[日用质量／竞争优势验收](acceptance/catpaw-final-product-acceptance.md)、[可点按状态提案](design/prototypes/catpaw-final/index.html) |
| 项目架构与开发规则 | [最新代码与分支复核](architecture/repository-review-2026-10-15.md)、[目录角色](development/repository-layout.json)、[分支规范](development/branch-management.md)、[2026-10-13基础审查](architecture/repository-review-2026-10-13.md) |
| 当前产品与页面/状态/API | [AF-1底座](product/agent-foundation-spec.md)、[UX-1](design/ios-codex-experience-spec.md)、[产品索引](product/README.md) |
| 设计、tokens、A1图标与历史截图 | [设计索引](design/README.md)、[design-tokens.json](design/design-tokens.json) |
| 验收记录 | [验收索引](acceptance/README.md)、[连续多模态问题单](acceptance/r1-continuous-multimodal-issues.md) |
| 主 iOS 来源与 P0 bridge 证据 | [来源清单](status/ios-p0-import-provenance.json)、[原生结果快照](acceptance/evidence/ios-p0-native-bridge/RESULT.json) |
| 后端失败收尾 | [验收与边界](acceptance/backend-p0-finalization.md)、[原生契约交接](../services/edge/docs/NATIVE-HANDOFF.md) |
| 图片本地输入独立组件 | [接入契约](../packages/ios-image-composer/README.md)、[合成验收](acceptance/ios-image-composer.md)；宿主验收与未开放生产路线见主计划 |
| 侧栏独立组件 | [接入契约](../packages/ios-navigation/README.md)、[合成验收](acceptance/ios-sidebar-navigation.md) |
| 独立 QA | [iOS 冻结补丁](../qa/ios-dialogue-p0/REPORT.md)、[后端撤权收尾](../qa/backend-finalization-p0/REPORT.md) |
| 运行时研究与待评审决策 | [四仓源码决策增量](research/copilotkit-four-repo-decision-update-2026-10-13.md)、[研究索引](research/README.md)、[ADR-005](architecture/adr-005-runtime-reuse-and-hosting.md)、[2026-10-12现状快照](architecture/runtime-state-2026-10-12.md) |
| 历史架构、合同与来源 | [架构索引](architecture/README.md)、[冻结合同](../services/facade/contract/native-contract-v1.json)、[导入来源](status/import-provenance.json) |
| 已过时的过程入口 | [历史资料归档索引](archive/README.md)、[本次清理记录](status/repository-cleanup-2026-10-13.md) |

v1/r2/r3 与各分支报告描述其当时输入和实测层；固定目录不包含 canonical 未跟踪候选资产，也未替代仍在装机 / 云端验证的 owner 工作目录。
