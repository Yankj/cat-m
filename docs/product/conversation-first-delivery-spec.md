# 对话式产品交付规格 v1.1

这是可执行的产品基线；[主计划](../status/master-plan.md)维护当前结果，本文定义要交付什么。冻结v1/r3规格不改。复用[现有产品资产](README.md)、[原生交互约束](../design/README.md)、[design tokens](../design/design-tokens.json)、[图标语义](../design/icon-semantics.json)、[历史成果/恢复样式](../design/openmuse-r3.md)，不重造导航、状态机或设计系统。

## 产品闭环

**对话是唯一主入口 → 自然明确目标/任务 → 持久绑定与可追踪执行 → 成果回到原对话和收件箱 → 记忆可查看来源、更正、删除。**

R1必交**连续文字＋图片对话**和短任务的不可变文字成果；图片不是R3系统扩展。输入须即时本地反馈，回答须真实云流式，前后台自动续接原turn，实时问题须真实查询或诚实说明能力不可用。不自动外发邮件、改日历或操作其他App；目标/执行真相仍用现有task/run/binding，不先要求手填委托表单或新建另一Goal API。

## R1 P0连续性门槛

[MM01–MM05问题与验收门槛](../acceptance/r1-continuous-multimodal-issues.md)是R1必交：本地响应、真实流式、自动同turn续接、真图片送视觉模型、实时能力/诚实不可用。用同真机同会话连续自然输入、长文、图后追问和前后台场景验，不以短CATPAW_OK或技术性恢复提示替代。当前结果只维护在主计划。

## 页面结构

| 页面 | 入口与内容 | 完成标准 |
|---|---|---|
| 主对话 | 恢复最后选中会话；顶部历史/新建/收件箱；文字＋图片输入、预览/取消。即时本地回显与真实云流式；前台自动读原turn并续观察；任务更新在任务卡 | 不阻塞输入、滚动/草稿/中文IME；图片真正关联turn并送视觉模型；正常问题直接回应，实时不可用明确说明。未知不显示完成，不反复要求用户执行技术恢复 |
| 对话历史 | 顶部入口打开列表，显示标题、最近状态/草稿；切换后恢复选中ID | 账号隔离，重启回到最后选中的会话；切换不是重发/重建任务 |
| 成果阅读器 | 从原对话任务卡或收件箱打开同一不可变成果版本 | 展示标题、正文、版本、来源/不确定信息；hash折叠，确认body/hash/归属一致；无成果时按钮不得打开伪造内容 |
| 收件箱 | 顶部辅助入口，聚合真实完成/失败/需我回答的任务更新，回到原对话/成果 | R1可先从已读取的权威投影聚合，已读仅是UI状态；R2接服务端事件/outbox。收件箱记录不是新的执行者或完成权威 |
| 记忆管理 | 设置内查看记忆及来源，明确记住/更正/删除；可关闭使用 | R2认证接口接通后开放。候选与已确认记忆分开，操作成功后context过滤生效；不把源内容purge预览称删除完成 |

保留既有黑灰原生、NavigationStack、顶部轻量入口、原生返回和键盘上方输入区；不新增底部多业务导航。R1尚未接通的记忆/长程功能不能用假数据显示可用。

## 4条用户故事与验收

| ID / 阶段 | 用户故事 | 可观察验收 |
|---|---|---|
| US1 / R1 | 我能连续输入文字和图片，即时看到发送状态与真实流式回复；离开回来仍接着原对话，时效问题知道回答是否来自实时查询 | MM01–05同真机同会话通过；完整terminal/正文、图片真正送视觉模型、前台自动原turn恢复不重发；有查询给来源/时间，无查询诚实说明。短标记只算技术冒烟 |
| US2 / R1 | 我自然说出要做什么，助理澄清必要条件并形成可追踪的短任务，最后把成果交回 | delegate_task只产生一个持久binding；原task/run确有step/成果version/hash并succeeded；对话和收件箱打开同一成果。受理、running或模型“已完成”不能代替产物 |
| US3 / R2 | 我离开App，已授权目标仍持续跟进；回来能看到进展、需我回答和结果 | 独立云唤醒、可撤销任务授权、当前scope/consent/generation复核；重复tick、进程恢复、撤权及unknown不重复效果。App内收件箱先于APNs |
| US4 / R2 | 我能查看助理记住了什么、依据哪里，并更正或删除 | 确认/更正/forget有明确回执与来源；新context不再用旧值，迟到抽取/旧摘要/通知不能复活删除内容；源内容删除和备份purge另给证据 |

## 核心状态与交互

| 对象 | 状态转换 | 用户看到什么 / 不允许什么 |
|---|---|---|
| 消息 | draft → 本地回显/sending → 真实streaming → completed；not_sent回草稿；已发不确定→outcome_unknown；前台自动snapshot/cursor只读核验/继续观察 | 保存原ID、正文/草稿/附件并去重；unknown不是新POST或新身份许可。恢复是产品自动动作，技术信息不反复作为助理答复 |
| 任务 | accepted/queued/scheduled → running → succeeded；分支waiting_input/approval、paused、failed、cancelled或outcome_unknown | 卡片只来自权威projection。step0/lease异常/成果0不能显示“成果已就绪”；ask_user回到对话。暂停本机队列与服务端pause/revoke必须标明范围 |
| 成果 | 无成果 → 服务端发布不可变v1 → 后续新版本 | 同artifact引用、version/body/hash读取；不能只改UI状态或给不合格v1补文字制造成功 |
| 记忆 | candidate → 用户确认/可用；更正生成新版本使旧值退出；forget推进删除屏障 | 记忆是不可信上下文，不授权动作、不修改task真相；删除成功与源数据/备份物理purge区分 |

权限或需要回答必须使用服务端具版本实体；未接通的控制灰显并说明，不假装已暂停/已取消。成果中不受给定材料支持的内容标为不确定；格式validator不认证事实可靠性。

## 产品动作与API对应

路径相对现有Edge API；以下“已有”仅表示代码/接口，不代表整项产品已验。

| 产品动作 | API/权威来源 | 实施边界 |
|---|---|---|
| 开始/恢复体验 | Supabase Auth匿名signup；GET /catpaw/account/v1/session | 已有；保持现有Keychain身份与server scope，客户端不自造owner/membership |
| 自然聊天/历史 | /catpaw/chat/v1/scopes/:scope/conversations；POST .../:conversation/turns；GET原turn/会话snapshot | 已有文本合同；原turn/cursor自动续接需原生/API一致，不能声称已有接口等于连续真机体验通过 |
| 图片对话 | 当前text-only DTO/传输有缺口；图片parts/引用、同turn冻结与视觉provider能力须受控扩展会签 | 未实现/未验不称支持；实际传图片，不用占位或文字转述代替。保留scope/对话同意/预算，不篡改冻结旧合同或默换付费模型 |
| 实时查询 | 由API明确支持的查询工具/来源与时效，或明确不可用回答 | 尚无已验实时能力证据；必须回应当前问题，不以任务观测/技术恢复提示替代，不伪造“已联网” |
| 形成任务 | chat的delegate_task → 持久tool_result/task_binding | 已有；唯一binding，主入口不另调手建delegation/run冒充自然任务 |
| 读进度/成果 | GET /catpaw/v1/scopes/:scope/runs/:run；GET .../artifacts/:artifact/versions/:version | 已有；使用服务器binding的projection_url及成果引用，验证归属/版本/hash |
| 服务端控制 | POST .../delegations/:delegation/control，pause/resume/revoke，expected revision/epoch | 已有服务端接口；客户端接线/负向仍需验，不与本机followup队列混称 |
| 查看/更正/删除记忆 | 现有Foundation端口；候选GET /catpaw/memory/v1/scopes/:scope/claims、POST .../commands、GET .../events | cloud-foundation-next候选，未接入；命令需认证resolver/来源/OCC/删除屏障，不接受body权限字段 |
| 删除源/预览purge | 现有 .../sources/:source/delete、.../purge-plan | 不等于上述记忆列表/命令已上线；purge计划不等于物理删除 |
| 收件箱/通知 | R1权威成果投影聚合；R2候选GET /catpaw/notifications/v1/scopes/:scope，原子outbox | 候选未接入。APNs设备注册/发送链路另验，provider_accepted不等于用户收到 |
| 后台推进 | 现有catpaw-tick POST＋HMAC/nonce，及短时有界kick | POST可能调用模型，是执行动作；更新/原task恢复须获准。长期还缺独立云调用方与可撤销任务授权，不可跳过认证 |

## 阶段放行与开发切片

- **R1连续多模态＋短任务成果**：MM01–05/US1真机连续场景和US2真实成果都通过；图片/自动续接必交，实时工具不可用须诚实说明但不称查询能力已完成。唯一binding/实际step/成果hash/对话收件箱同引用、异常不假成功；短标记、安装、离线计数不能放行。原任务恢复保留IDs，不新建任务替代失败。
- **R2可靠持续跟进＋记忆**：US3/US4、独立云调度、认证记忆接口/有限重试抽取/context、原子outbox/删除屏障、真实PG并发/恢复通过。创建session过期与任务授权撤销语义分开设计；tick批准前不部署。先App内收件箱，APNs等Apple能力/发送链路。
- **R3系统入口＋语音扩展**：R1/R2后再交桌面/锁屏、语音/朗读、通知快捷入口，验证权限/中断/无障碍；系统入口恢复同对话和task，不新建另一执行真相。

每个切片由[主计划](../status/master-plan.md)指定负责人和当前阻塞；验收要求见[短清单](../acceptance/README.md)。这里的未来页面/接口/阶段要求不得写成已完成。
