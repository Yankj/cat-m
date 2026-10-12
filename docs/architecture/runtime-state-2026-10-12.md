# Catpaw-m 运行时与版本现状：2026-10-12快照

本文件是带日期的事实快照，唯一实时进展仍是 [主交付计划](../status/master-plan.md)。固定本地目录的来源HEAD为 **`52ee35267fddfcb4ca4108a7a37893e860598d97`**，分支为 `integration/local-fixed-directory`；详细提交映射见 [local-integration-source.json](../status/local-integration-source.json)。本文之后的文档commit不表示应用或云端版本变化。

## 当前实现

| 层 | 实际来源与实现 | 不能据此推定的能力 |
|---|---|---|
| iOS | SwiftUI主客户端 `apps/ios-conversation`，来源d9a897cc；本地对话副本、队列、现有auth/chat适配 | 真实连续多模态、性能、VoiceOver/IME或云恢复全部通过 |
| 任务执行 | vendored受控OpenMuse TaskWorker，连接自研适配及有界Edge入口 | 纯自研agent框架、CopilotKit完整SDK、无限循环或可靠常驻后台 |
| chat/auth/store/model | 自研ChatService、身份/授权、Postgres/store及模型provider适配；保留Supabase数据层 | 复用上游默认单用户身份即可满足多租户，或所有上游第三方服务均已接入 |
| 运行方式 | 当前源码包含Edge适配；常驻worker vs Edge分步的后续方案待评审 | 已接受框架迁移或已完成长期调度部署 |

本地源码证据：[runtime.mjs](../../services/edge/supabase/functions/_shared/core/src/runtime.mjs)、[vendored worker](../../services/edge/supabase/functions/_shared/core/integration/edge-adapter/vendor/openmuse/runtime/engine/worker.mjs)、[bounded tick](../../services/edge/supabase/functions/_shared/core/integration/edge-adapter/src/bounded-tick.mjs)。来源归属继续受 [ADR-002](adr-002-upstream-pinning.md)约束；待评审方案见 [ADR-005](adr-005-runtime-reuse-and-hosting.md)。

## 固定目录、手机与云端分别记账

| 版本维度 | 本次已知状态 | 未包含/未放行 |
|---|---|---|
| 固定目录52ee352 | 指定iOS、后端P0、侧栏和QA提交已本地整合；开发入口和验证快照已提交 | 本地整合不是手机安装或云部署；canonical未跟踪资产与后续owner改动未自动导入 |
| 手机build14 | 协调转交原生owner状态：已安装并启动，同bundle保数据；**原生源码仅d9a897cc**。本次文档任务未独立验机 | **未接独立侧栏、未交付图片能力**；性能与真实产品路径未放行，保留此前build13真实失败证据 |
| 后端 | 固定目录含dialogue P0和撤权失败收尾候选；原v14部署历史由SOURCE-MANIFEST保留 | **后端P0未部署**；不能因build14安装或本地62项合成通过推断其已上线 |
| 侧栏 | 独立package及测试已整合 | 未宿主接线、未装到手机；实际手势/VoiceOver/最大字号/延迟仍待验 |

[固定目录验收](../acceptance/local-fixed-directory.md)、[原生P0证据](../acceptance/evidence/ios-p0-native-bridge/RESULT.json)和[后端P0验收](../acceptance/backend-p0-finalization.md)各自只证明注明的输入与运行层。手机安装、代码存在、测试数量、局部PASS都不能替代用户可用性；性能、图片、侧栏、后端P0部署及真实持续任务门槛仍未放行。

## 研究与采纳状态

[OpenMuse](../research/openmuse-runtime-source-review.md)已有固定commit源码核验；当前代码本就复用了其TaskWorker。本次没有再引入运行时代码或接入Intelligence。

[OpenDot](../research/opendot-runtime-assessment.md)仍未确认用户所指仓库，composio候选许可未核验，**未采纳代码**。其他同名项目的文档声称、许可证标识及durable模式不等同于该候选的已验证保证。

保留SwiftUI＋Supabase。worker运行方式和框架迁移状态为 **Proposed**，非Accepted；本批只归档研究与决策记录，无应用修改、部署、安装或push。
