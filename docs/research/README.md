# 运行时研究索引

两篇既有研究由协调交付，本批按提供内容归档；未重新运行上游测试、接入账户或联网重做研究。研究中的推荐是工程判断，不是已接受的迁移方案。当前产品进展只见 [主计划](../status/master-plan.md)。

| 研究 | 固定身份与限制 |
|---|---|
| [OpenMuse 源码核验](openmuse-runtime-source-review.md) | 固定公开 commit `1ac68f3909f2478ab6280883f1ab5ea65eb5719d`；静态源码核验，区分前台聊天、后台worker和Intelligence服务 |
| [OpenDot runtime assessment](opendot-runtime-assessment.md) | 用户所指仓库尚未确认；对composio-community/open-dot仅暂定评估，branch链接会变化，复用许可未核验；其他候选不能混为同一项目 |

现有 Catpaw-m 代码已经 vendored OpenMuse TaskWorker，并有自研 chat/auth/store/model 适配，不能称为纯自研运行时。保留 SwiftUI 与 Supabase 数据层；常驻worker或Edge分步的选型、框架迁移仍待评审，见 [ADR-005](../architecture/adr-005-runtime-reuse-and-hosting.md)。

固定目录、手机build14与云部署是不同版本维度，见 [2026-10-12现状快照](../architecture/runtime-state-2026-10-12.md)。测试数量不能代替用户可用性或真实部署签收。OpenDot代码未采纳；身份和许可确定前不复制或引入其实现。
