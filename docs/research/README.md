# 运行时研究索引

[对话UI／onboarding补充核读](copilotkit-conversation-ui-onboarding-review-2026-10-13.md)与[固定来源](copilotkit-conversation-ui-source-manifest-2026-10-13.json)：确认OpenIntelligentUI机制可用于原生交互回答；第二链接是CLI接入提示。来源核读不等于安装或运行成功，采用细分见[CGUI-1](../design/conversation-generative-ui-spec.md)。

[Grok Cat Companion整合核读](grok-companion-integration-review-2026-10-13.md)及[17文件固定来源](grok-companion-source-manifest-2026-10-13.json)区分设计骨架和真实执行，核实用户所指xAI实际Grok产品。与四仓、本地设计合成[FINAL-1](../product/catpaw-final-product-spec.md)；优势仍按真实配对验收，研究不作为产品PASS。

当前入口为 [2026-10-13四仓源码决策增量](copilotkit-four-repo-decision-update-2026-10-13.md)与[固定来源 manifest](copilotkit-four-repo-source-manifest-2026-10-13.json)：读取公开固定代码、schema、测试和许可后修订既有方案；没有运行模板、安装依赖、请求模型或部署。研究建议不是迁移通过，当前产品进展只见 [主计划](../status/master-plan.md)。

| 本轮核读 | 主要输入 |
|---|---|
| [OpenMuse](openmuse-code-gap-review-2026-10-13.md) | 保留已有worker；计划逐步证据、成果引用重取、monitor |
| [CopilotKit/OpenDots](opendots-code-review-2026-10-13.md) | 明确身份；成果版本与迟到响应保护；审批/调度保证边界 |
| [OpenBot](openbot-code-review-2026-10-13.md) | 消费/结果/续聊恢复、PG工作合同、后台卡；Intelligence强依赖 |
| [OpenIntelligentUI](openintelligentui-code-review-2026-10-13.md) | 受控registry/schema/生命周期；A2UI与任意HTML路线分别选择 |

以下两篇为协调交付的历史记录，保留原有日期、范围和限制；当时没有在本固定目录重跑上游。

| 研究 | 固定身份与限制 |
|---|---|
| [OpenMuse 源码核验](openmuse-runtime-source-review.md) | 固定公开 commit `1ac68f3909f2478ab6280883f1ab5ea65eb5719d`；静态源码核验，区分前台聊天、后台worker和Intelligence服务 |
| [OpenDot runtime assessment](opendot-runtime-assessment.md) | 当时未确认的composio同名候选；现已被用户指定的CopilotKit/OpenDots研究替代为决策依据。原文/许可未验边界保留 |

现有 cat 代码已经 vendored OpenMuse TaskWorker，并有自研 chat/auth/store/model 适配，不能称为纯自研运行时。保留 SwiftUI 与 Supabase 数据层；常驻worker或Edge分步的选型、框架迁移仍待评审，见 [ADR-005](../architecture/adr-005-runtime-reuse-and-hosting.md)。

固定目录、手机与云部署是不同版本维度；旧身份见 [2026-10-12现状快照](../architecture/runtime-state-2026-10-12.md)，当前只查主计划。测试数量不能代替用户可用性或真实部署签收。本轮未导入四仓生产代码，未来实质复用单独记录pin/hash/受控差异并保留对应许可。
