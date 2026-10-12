# Catpaw-m 长期个人助理技术规格

版本：1.3 设计提案 含原生iOS实施路线  
核验日期：2026-10-10  
读者：CatDesk / Catpaw-m 产品、移动端、服务端、安全与测试负责人  
范围：可落地架构、接口契约、可靠性与安全、分阶段交付；不包含代码实现、账号连接、仓库修改或部署。

## 1 结论与默认选择

建议在已证实的 CatDesk 基础能力上构建 Catpaw-m 长期助理。当前先完成可独立运行的基础复刻，真实实现本地会话、文件、任务与权限交互，再接云端持久化委托运行层；原宿主代码可用后再按需要适配回接。首页呈现已准备成果和轻量跟进；对话继续承担说明、补充与协商。不能把一个长对话、定时唤醒模型，或手机静默推送当作长期助理的完整后端。

首个真实闭环建议为“持续研究一个技术主题，并维护可审阅的私有草稿”。例如关注编程 Agent 的架构演进，定期检查用户选定的一手来源，识别实质变化，更新有证据的对比与草稿。此场景是可替换建议，不是用户已定稿的产品定位，不自动发帖，不要求邮箱、日历或电脑权限。

推荐默认项：

1. 用户已明确开发iOS版本：独立SwiftUI原生工程优先，暂定iOS17+与SwiftData本地持久化，按本机Xcode/SDK校准。以31图证据复刻全部基础功能，不因没有CatDesk源码而停做，也不沿用旧独立Swift日历Demo；计划后进入实际编码。
2. 云端先采用模块化单体 API + 独立 worker + PostgreSQL + 私有对象存储。默认 TypeScript 作为接口和业务实现语言；若宿主已有成熟 Go/Python/Java 后端，保留协议并使用原栈。
3. PostgreSQL 保存权威业务状态、运行日志、幂等记录、租约与事务性 outbox。v1 不强制引入 Redis、Kafka、向量数据库或 Temporal。
4. 由持久调度器驱动云端工作。APNs/FCM 只提示客户端刷新和用户查看。APP 关闭、拒绝通知或手机离线，不应阻止已授权的云端资料研究。
5. 模型负责提议、提取和撰写；确定性服务负责授权、状态迁移、预算、调度、执行和验证。模型不能自行声明“用户同意”、改变权限或把网页文字升级为指令。
6. 默认只有委托内显式要求和任务事实可进入该委托的上下文。跨委托记忆须显式开启；敏感事实不自动扩散。删除传播覆盖检索索引、摘要、缓存和排队上下文。
7. 内部私有草稿与资料整理在委托范围内无需反复审批。外发、公开发布或共享需要具体目标与具体内容的确认；授权与执行前校验必须在服务端执行。
8. 语音先采用可核验设备朗读与独立ASR接口；高质量中文TTS评估Qwen3-TTS自托管，模型许可免费不等于算力免费；语音不扩张业务授权。
9. 不承诺跨外部系统的 exactly-once。采用至少一次事件处理、稳定操作 ID、供应商幂等能力及结果核对，避免重复副作用。无法确定执行结果时使用“结果未知”，不能伪装成功或直接重发。

这些选择能先验证长期委托的价值，再按吞吐、等待复杂度和团队能力替换基础设施。本文所有 API 名称均为拟议契约，不代表 CatDesk 已有对应接口。

## 2 事实边界与能力分层

### 2.1 已见的宿主表现

根据本次提供的真实产品图与任务背景，CatDesk 移动端已有 Agent 对话；左侧栏可见云端/电脑切换、新任务、定时任务、专家、技能、项目；已有对话进度、文件阅读器、半屏表单、权限设置等交互。以上是 UI 级证据，不等于已证明后台接口、权限检查、调度语义、文件版本或执行可靠性。

实际宿主代码、身份系统、云任务服务、插件协议和数据库未提供，不能判断“云端”入口背后是否具备本规格所需能力。远程 Yankj/catpaw-m 当前为空；旧独立 Swift 日历 Demo 不作为产品或工程基线。

### 2.2 四层接入模型

| 层级 | 内容 | 本次证据状态 | 集成策略 |
|---|---|---|---|
| A 宿主交互 | 对话、进度、文件阅读、半屏表单、项目/技能导航 | UI 已见 | 尽量直接复用组件与路由 |
| B 宿主基础服务 | 会话 ID、身份/租户、文件句柄、权限服务、工具连接、推送令牌 | 待验证 | 通过 HostBridge 和 capability handshake 接入 |
| C 长期助理领域层 | 委托、事件收件箱、运行、成果版本、记忆、审批绑定、回执、通知策略 | 新增或待发现等价实现 | 以本文契约为实现目标；发现宿主等价实现则适配，避免双系统 |
| D 外部执行能力 | 公共来源抓取、未来账号工具、电脑执行器 | 公共读取可单独建设；其余待授权验证 | ToolAdapter 分层接入，未就绪就明确降级 |

不能因为侧栏出现“定时任务”就直接宣称支持无人值守持久工作；也不能因为出现“权限设置”就假定每次执行都有服务端权限验证。

### 2.3 一次性接入勘察清单

实现前完成一轮有边界的技术勘察，输出 capability 清单，不把所有未知转成产品问题：

- 能否取得经服务端验证的 user_id / tenant_id / session？能否复用登录？
- 会话能否携带 delegation_id、run_id、artifact_id，并深链回同一上下文？
- 文件是否私有、是否有版本、能否对特定版本读取、是否支持删除？
- 定时任务是否持久化，有无重试、取消、去重、运行历史和执行器状态？
- 工具服务能否声明和实际限制读/写范围，有无请求 ID、幂等和结果查询？
- 手机是否已有 APNs/FCM 注册、通知设置与深链处理？
- 云端/电脑执行是否有真实环境心跳、能力与可达状态？

缺一项就使用明确的适配层或阻断依赖步骤；不重建已有宿主服务，也不把未核验的宿主能力写成事实。

## 3 系统组成与端云分工

### 3.1 模块边界

1. **Mobile Assistant Surface**：工作简报、委托详情、成果版本、审批表单、来源与记忆管理。只展示服务器状态，缓存可读内容，不能自行认定执行完成。
2. **HostBridge**：把 CatDesk 身份、会话、文件、权限、路由、推送、音频会话与环境能力映射到稳定接口。隔离宿主具体实现。
3. **Assistant API / Sync**：身份校验、资源级访问控制、版本并发控制、增量同步、首页 read model。客户端不能指定自己属于哪一个租户。
4. **Delegation Service**：持久目标、范围、停止条件、预算、通知偏好与修订；创建或停止运行。
5. **Event Ingestion**：来源轮询/webhook、签名验证、规范化、去重、来源快照与事件收件箱。
6. **Scheduler / Orchestrator**：到期任务、事件匹配、运行状态机、租约、恢复、取消、补偿/核对。等待不占用常驻模型会话。
7. **Context / Memory Service**：按委托和来源权限组装有限上下文；记录来源、时间、有效期、用户更正、删除传播。
8. **Agent Runtime**：提取结构化事实、判断变化、撰写成果、提出动作；有每轮工具、时间、token 与费用上限。
9. **Policy / Approval Service**：由代码计算风险和许可；维护 grant、待批准动作的不可变快照、审批决议与撤销。
10. **Tool Gateway / Adapters**：凭据隔离、参数校验、目标解析、执行前权限检查、稳定 operation_id、供应商回执与状态查询。
11. **Artifact / Evidence Service**：私有成果、不可变版本、修改差异、来源映射、发布前检查；与宿主阅读器对接。
12. **Notification Service**：决定是否值得打扰，聚合、静默时段、去重、推送内容脱敏；记录推送提交与用户打开，不把提交等同已送达。
13. **Audit / Evaluation**：事件链、动作事实、异常、成本、质量样本；不要求保存或展示模型私有思维链。

以上是逻辑模块，v1 可位于一个代码库和两个进程（API、worker）。不需要拆成 13 个微服务。

### 3.2 权威状态

本节描述R1真实云端架构；B0原生基础版以本机SwiftData为本地数据权威，远端行为明确fixtures，详见第16节及iOS实施计划。真实云端接通后，PostgreSQL 为委托、运行、授权和回执的权威来源。对象存储保存成果正文与允许保留的来源快照；对象 key 不能充当授权。搜索/向量索引、首页缓存、推送内容、客户端 SQLite 均为可重建投影。

推荐事务边界：每次业务状态变化、对应 audit event 和 outbox 记录同事务提交。outbox dispatcher 可以重复投递；消费者按 event_id 去重。只在 durable inbox 写入成功后向来源 ACK。不要在提交前向用户发送“完成”或触发推送。

初期 worker 通过带租约的 job 表领取工作，`FOR UPDATE SKIP LOCKED` 适合队列表的并发消费者，但不能当普通业务一致性读。领取时增加 fencing_token；随后释放数据库事务再做外部 I/O，不能长时间持有数据库锁。回写需要 run/job 的期望版本与当前 token 匹配。领取只预约工作，不代表外部动作已提交；敏感动作另遵守第 7.6 节的 dispatch_commit。依据：[PostgreSQL SELECT](https://www.postgresql.org/docs/current/sql-select.html)。

当工作流分支、跨天审批、跨服务等待、恢复运维成本明显增加时，可把 Orchestrator 替换为 Temporal 等持久工作流系统。业务 operation_id、授权模型和外部核对逻辑必须保留；工作流引擎也无法自动消除外部副作用的重复。Temporal 官方同样要求 Activity 按可重复执行设计。[Temporal Activity Definition](https://docs.temporal.io/activity-definition)

### 3.3 移动端负责什么

- 前台：拉取/流式刷新、创建或修改委托、阅读编辑草稿、审批、权限说明、来源与记忆查看。
- 后台：尽力更新缓存、完成系统允许的短任务；不承担长期研究循环、精确提醒或永久连接。
- 本地：加密/受系统保护的最近数据缓存；短期 UI 队列；设备通知设置。服务端凭据、工具 access token、模型 API key 不进入业务前端。
- 离线：读取有时间标记的缓存，编辑本地草稿副本，保存未提交的意图。不能把离线点击“批准”当有效许可；联网后重新取快照、检查版本并由用户确认仍有效的动作。
- 退出登录：清空账户相关缓存和设备通知内容，注销/解除 token 与账户绑定。一个设备 token 不能永久代表同一个账户。

### 3.4 电脑执行器不是隐含依赖

首个研究闭环运行在云端，无需电脑在线。未来需要本地文件或应用时，运行保存 required_environment、capabilities、last_seen；离线显示“等待电脑连接”。不得偷偷切换到云端或别的电脑读取数据，也不得把电脑不在线说成整个助理停机。独立可授权步骤继续，依赖步骤等待或由用户取消。

## 4 移动平台约束与通知设计

本节以官方公开资料核验，平台规则可能继续变化；具体最低 OS、目标 SDK、宿主 entitlement 与厂商差异须在实现阶段测试。产品承诺是云端工作可持续、客户端最终同步，不能承诺操作系统必定在某一秒唤醒或展示通知。

### 4.1 iOS 官方限制

- `BGTaskRequest.earliestBeginDate` 是最早可开始时间，系统不保证该时刻运行；后台刷新按机会分配。适合刷新缓存和可延期维护，不适合准点模型循环。[Apple earliestBeginDate](https://developer.apple.com/documentation/backgroundtasks/bgtaskrequest/earliestbegindate)
- 静默背景推送低优先级、不保证送达，可能节流或被较新的推送替换；唤醒后的执行窗口有限。服务端必须保存全部状态，手机按游标补齐。[Apple Background Updates](https://developer.apple.com/documentation/usernotifications/pushing-background-updates-to-your-app)
- 用户划掉 App 通常抑制后台启动，但存在 API/版本/使用模式例外。Apple DTS 在完整讨论中还更正了 BGProcessing 强退后“仅一次”的旧说法；不能写成“强退后任何后台绝对不能运行”，也不能依赖例外保证持续执行。后台代码启动和系统通知展示是不同问题。[Apple Background Limits](https://developer.apple.com/forums/thread/685525)、[Apple BGProcessing 后续更正](https://developer.apple.com/forums/thread/793189)
- alert/sound/badge 需相应通知授权；Focus 与通知摘要会影响打断时机，用户可关闭 Time Sensitive。Critical Alerts 需要特殊 entitlement，不是本产品默认能力。初版使用普通通知，不以时间敏感级别给日常研究强行提权。[Apple Notification Permission](https://developer.apple.com/documentation/usernotifications/asking-permission-to-use-notifications)、[Apple Managing Notifications](https://developer.apple.com/design/human-interface-guidelines/managing-notifications)
- Apple 明确提醒不要在推送载荷中放敏感/客户信息；可见锁屏内容同样要最小化。即使未来采用加密载荷，解密后的锁屏预览仍要另做保护。[Apple Remote Notification](https://developer.apple.com/documentation/usernotifications/generating-a-remote-notification)、[Apple Notifications HIG](https://developer.apple.com/design/human-interface-guidelines/notifications)

### 4.2 Android 与 FCM 官方限制

- 周期 WorkManager 的最小间隔为 15 分钟，但实际执行可延迟，条件不满足可跳过；OneTimeWorkRequest 的 initial delay 也只是下界。Doze 会推迟网络、同步和 job；不能用短周期链条绕成精确后台时钟。[Android Work Requests](https://developer.android.com/develop/background-work/background-tasks/persistent/getting-started/define-work)、[Android Doze](https://developer.android.com/training/monitoring-device-state/doze-standby)
- FCM high priority 为及时、用户可见的消息设计，并只提供短执行机会；若不产生用户可见通知可能被降级。研究计算不能塞进 `onMessageReceived`，也不靠 high priority 维持后台心跳。[FCM Android Priority](https://firebase.google.com/docs/cloud-messaging/android-message-priority)
- Android 13/API 33+ 非豁免通知需要 `POST_NOTIFICATIONS`；启动前台服务与通知是否对用户可见不能等同。前台服务不是绕开通知拒绝的替代品。[Android Notification Permission](https://developer.android.com/develop/ui/compose/notifications/notification-permission)
- FGS 受后台启动、类型/权限和版本限制。特定 Android 15 目标版本的后台 dataSync/mediaProcessing 有各自累计时长限制；Android 16+ 的后台 job 即使由 FGS 发起仍受配额约束。不能把长期个人助理设计成永久 FGS。[Android FGS Restrictions](https://developer.android.com/develop/background-work/services/fgs/restrictions-bg-start)、[Android FGS Changes](https://developer.android.com/develop/background-work/services/fgs/changes)
- `VISIBILITY_PRIVATE` 与删减 publicVersion 可保护锁屏内容，用户仍控制最终呈现。系统设置 Force Stop 与最近任务界面划掉不是同一种操作，必须分别测试。[Android Lock Screen Visibility](https://developer.android.com/develop/ui/compose/notifications/create-notification)、[Android Stopped State](https://developer.android.com/about/versions/15/behavior-changes-all)
- FCM 接收请求返回 message ID 不等于消息已送达；TLS 也不等于端到端加密。默认只发通用文案与 ID，打开 app 再鉴权获取内容。[FCM Lifespan](https://firebase.google.com/docs/cloud-messaging/customize-messages/setting-message-lifespan)、[FCM Encryption](https://firebase.google.com/docs/cloud-messaging/encryption)

Android 推送渠道还依赖目标市场、设备与服务可用性，不能假设所有 Android 设备/地区都具备同等 FCM 能力。默认 APNs/FCM 只是可替换集成建议；若实际宿主使用厂商渠道，则复用并保持相同隐私/回执语义。

详细官方核验清单与平台测试场景见配套《Catpaw-m 移动后台与通知官方约束核验》。真实闹钟、本地提醒等将来如有需求，应按专门 API 另设计，不与任意模型后台执行混为一谈。

### 4.3 平台无关的通知契约

- 云端 `notification.intent` 持久化后才尝试 APNs/FCM。payload 默认只有不透明 notification_id、最小类型与通用文案，例如“有一项内容更新待查看”。不得包含私人主题、来源全文、审批 token、登录 token 或可直接执行的 URL。
- 客户端打开通知后，使用自己的有效登录态向服务端读取当前资源。服务端再次校验租户、权限、动作/成果版本和是否撤销；旧推送只允许安全打开当前状态。
- 初版锁屏不提供“同意并执行”按钮。通知点击、系统展示或“已读”不能隐含批准。批准必须在 app 中看见具体内容、目标与后果。
- 通知至少区分 `queued`、`submitted_to_provider`、`provider_rejected`、`opened`。能取得的送达遥测单独保存，不能从 provider accepted 推断手机已展示或用户已看到。
- 同一委托相近变化聚合，设置 topic/collapse key 与 TTL。折叠仅压缩提示，原始事件仍在服务端，不依赖每条 push 都送达。
- 默认普通研究更新进入工作简报；有显著新成果才合并通知。安静时段只暂停触达，不暂停已授权研究。无变化不重复推送“我还在看”。由 owner/day 级 AttentionPolicy 统一限额，默认每位用户每天最多一条非紧急汇总，跨委托合并；委托级 max_per_day 只是附加上限，不能让三个委托各发一条。配额使用用户时区日界线并做原子计数，多设备展示不增加新消息预算。
- 用户拒绝系统通知时，委托继续，首页显示“通知未开启；打开应用可查看更新”，提供系统设置入口。不能通过邮件/短信等新渠道绕过用户选择。
- 删除、退出账号或撤销委托时取消待发通知；已交给系统的通用通知无法保证远程消失，因此从一开始减少敏感内容。

## 5 核心领域模型

所有主键为随机不透明 ID。所有业务行包括 tenant_id、owner_user_id、created_at、updated_at、revision；除明确公共来源缓存外，查询和写入必须有服务端租户约束。日期使用 UTC RFC 3339，另保存用户时区的 IANA 名称与 schedule 语义。`status` 不是一个混用全系统的字符串。

### 5.1 委托 Delegation

表示可跨多次运行存在的责任。

关键字段：id、title、goal、scope（主题/来源/项目/输出）、success_criteria、stop_conditions、trigger_spec、notification_policy、budget、memory_scope、grant_refs、state、revision、created_by_message_id、next_check_at、last_healthy_check_at、last_meaningful_change_at。

状态：`draft → active ↔ paused → completed | cancelled | expired`。缺连接、临时故障、没有新消息属于 health/blocker，不应该随意把 active 变 completed。一次草稿 ready 不等于委托结束。`completed` 只在达到用户明示终止目标时使用；长期订阅通常保持 active，直到用户暂停/停止或预设期限到达。

自然语言停止条件可用于建议，但终止动作需对应已记录条件或用户命令。模型不能为了节约工作自行结束持续委托。修改目标、范围或权限会增加 revision，标记依赖旧版本的运行/审批需要重评估。

### 5.1.1 规范状态与产品展示映射

| 对象 | 服务端规范状态/字段 | 产品展示与语义 |
|---|---|---|
| 委托 | draft | 尚未开始；无持续触发 |
| 委托 | active | 持续跟进；单次 run 成功不改变它 |
| 委托 | paused | 已暂停；不生成新业务运行 |
| 委托 | completed / cancelled / expired | 已结束，并分别显示达成目标/用户停止/到期原因 |
| 委托归档 | archived_at，仅终态可设置 | 从活跃列表收起，不恢复 schedule；取消归档也不重启 |
| 未创建委托弃置 | discarded_at，state=draft | 放弃未生效草案，不当成曾运行/已完成 |
| 单次运行 | succeeded + outcome=changed/no_change | 本次处理完成/无新变化；不等于委托完成 |
| 成果 | draft / ready / stale / superseded / withdrawn | 草稿/已准备/需更新/有新版/已撤回 |
| 阅读回执 | ArtifactView(user_id, artifact_id, version, viewed_at) | 当前版本已看；独立于 ready，读过不批准发布或结束委托 |

新的成果版本具有独立阅读回执；不能因为旧版已读就把新版自动标已看。归档不是运行态，不能用于绕过取消/恢复的明确语义。

### 5.2 任务与运行 Task / Run

Task 为可执行工作项（如“检查三个来源”“更新架构对比草稿”）；Run 是一次实际尝试组，不与会话消息一一对应。

关键字段：id、delegation_id、delegation_revision、trigger_event_ids、task_kind、state、phase、current_step、plan_version、context_manifest_id、artifact_refs、cancel_requested_at、lease_owner、lease_expires_at、fencing_token、attempt_count、next_attempt_at、deadline_at、budget_used、trace_id。

Run 状态：`queued → preparing → running → verifying → succeeded`；可进入 `waiting_approval`、`waiting_dependency`、`retry_scheduled`、`cancel_requested`、`cancelled`、`failed`、`outcome_unknown`。`no_change` 是成功运行的一种 outcome，不生成假成果或重复通知。`succeeded` 只表示该次运行结束，和委托是否继续独立。

用户能看见简明阶段与已核验结果；内部 step 日志记录工具与事实，不暴露凭据或私有思维链。

### 5.3 事件 Event

关键字段：id、source_kind、source_id、provider_event_id、source_object_id、source_revision、event_type、occurred_at、observed_at、received_at、payload_ref、payload_hash、dedupe_key、trust_class、signature_status、ingest_status、causation_id、correlation_id。

`occurred_at` 可能缺失或由来源声明，不能用它决定全局先后；处理逻辑依赖可比较的 source_revision、权威回读或对象级序列。客户端用户动作、服务器时钟到期、外部内容变化是不同来源，不能混成同等权威指令。

### 5.4 来源与证据 Source / Evidence

Source 保存 canonical URL、来源类型、所有者/发布方、可信度依据、抓取策略、授权范围、最近 ETag/Last-Modified、检查健康度。Evidence 保存 source_version、抓取时间、内容 hash、相关片段或定位、允许保留的快照引用、支持的 claim_id 和限制。

“一手来源”不是文本自称官网；来源需要经 URL/机构页面/已批准域名确认。真实官方页面也可能被污染，仍是外部数据，不具有指令权限。给用户的引用定位到支持该论点的页面/段落；不把搜索摘要当完整证据。

### 5.5 记忆 MemoryItem

关键字段：id、kind（用户显式偏好/任务要求/来源事实/暂定推断）、scope_type（run/delegation/project/user）、scope_id、content、source_refs、asserted_by、confidence、valid_from、valid_until、last_verified_at、sensitivity、status、supersedes、derived_from、deletion_epoch。

状态：candidate、active、superseded、disputed、expired、deleted。用户要求优先于推断；冲突事实并列记录来源与时间，不静默覆盖。推断不能提升工具权限。R1 使用显式委托约束与来源版本索引即可，不必先做无边界自动“记住一切”。

### 5.6 授权 Grant 与审批 Approval

Grant 表示用户允许系统持续做什么：subject、source/action scope、purpose、recipient constraints、data categories、resource IDs、expiry、budget limits、created_by、revision、revoked_at。读取来源与本地通知许可、某个工具 OAuth scope、对具体业务动作的批准是不同层，不可互相替代。

Approval 表示对某个具体不可变 ActionEnvelope 的决议：id、action_id、action_digest、artifact_version、recipient_snapshot、grant_revision、policy_version、status、expires_at、decided_by、decided_at、decision_source、execution_claimed_at、dispatch_commit_seq、dispatch_committed_at、revoked_at。默认一次逻辑动作消费一次；同一动作在证明安全的重试里可复用同一 operation_id，不能变成无限次外发许可。

审批状态：pending、approved、rejected、expired、invalidated、consumed、revoked。`approved` 不等于已经执行。用户在聊天中说“可以”只有在可确定唯一 pending 动作、核对绑定内容后才能转换；有两个可能对象就问清一个必要问题。

### 5.7 ActionEnvelope

由可信服务生成，模型只能提出 candidate。包含：operation_id、delegation_revision、tool_id/version、actor/account、effect_class、resolved_targets（供应商不可变 ID 与显示值）、arguments_ref/hash、artifact_id/version/content_hash、data_categories、preconditions、grant_id/revision、policy_version、expires_at、idempotency_key、required_confirmation。

审批展示由这份对象渲染；执行也只从同一对象读取参数。不能展示摘要 A、执行模型后来生成的内容 B。使用规范化序列化生成 digest；可采用 RFC 8785 JCS，需注意其数值和字符串约束。hash 输入为版本化白名单的执行/授权字段，明确排除 action_digest 本身、UI 摘要、状态和遥测，避免自引用和不必要失效；必须包含 operation_id、目标、账号、工具版本、参数/成果 hash、权限版本、有效期与重要前置条件。arguments_ref/content_ref 只能指向固定不可变对象，dispatch 前读回并校验 hash。digest 仅用于绑定内容，不能作为身份凭据或单独授予执行权。批准后不允许修改执行对象，只能生成新版本并作废旧审批。[RFC 8785](https://www.rfc-editor.org/rfc/rfc8785)

### 5.8 执行回执 ExecutionReceipt

关键字段：id、operation_id、run_id、attempt_id、adapter_id/version、action_digest、authorization_decision_id、request_started_at、provider_request_id、provider_operation_id、status、response_class、observed_effect、verification_method、verification_evidence_ref、verified_at、error_code、retry_safety、compensation_ref。

状态：not_started、reserved、dispatch_committed、accepted、verified、failed_definite、unknown、cancelled_before_dispatch、cancelled_before_transport。外部 HTTP 200/202、按钮点击或模型说“完成”不是通用完成证据；只有适配器定义的 postcondition 成立才能 verified。未提供可观测证据的工具不能支持“已核验”展示。

### 5.9 成果 Artifact 与首页投影

Artifact 是稳定成果身份；ArtifactVersion 是不可变版本。字段包括：kind、title、visibility=private、version、parent_version、content_ref/hash、source_evidence_ids、claim_evidence_map、generated_from_run、user_edits_base_version、quality_checks、state（draft/ready/stale/superseded/withdrawn）、created_at。

用户编辑与 Agent 新版本并发时不覆盖：通过 base_version 检测，产生待合并分支，展示差异。成果 ready 表示已完成本次内部质量检查，可审阅，不等于用户同意发布。首页 read model 包含一个 primary_ready_artifact 与简短 followups，同时携带 freshness 和 blocking_reason；无成果时自然显示准备中/等待条件，不伪造一张“已完成”卡片。

## 6 示例 API 契约

下列为拟议 REST 契约，可用现有宿主 RPC 实现。身份从经验证 session 推导；所有写请求使用 Idempotency-Key，资源修改使用 If-Match/revision。异步请求返回 202 和可查询资源，不能仅返回一句自然语言。

### 6.1 宿主能力握手

`GET /v1/assistant/capabilities`

```json
{
  "schema_version": "1.0",
  "host": {"name": "CatDesk", "integration_status": "unverified"},
  "capabilities": {
    "conversation_link": "unverified",
    "private_artifact_reader": "unverified",
    "cloud_scheduler": "unverified",
    "server_side_approval": "unverified",
    "push_registration": "unverified",
    "desktop_executor": "unverified",
    "device_tts": "unverified",
    "speech_recognition": "unverified",
    "audio_session_control": "unverified"
  },
  "mode": "prototype"
}
```

真实服务按 `available/unavailable/unverified` 返回，feature flag 来源于部署能力，不由模型生成。原型 fixture 必须保留 mode=prototype，不会被当成生产接口证据。

### 6.2 创建持续委托

`POST /v1/delegations`，`Idempotency-Key: client-create-47`

```json
{
  "title": "跟进编程 Agent 架构演进",
  "goal": "跟踪所选一手资料，维护有来源的对比与可审阅草稿",
  "scope": {
    "source_ids": ["src_official_docs", "src_official_releases"],
    "output_visibility": "private",
    "allowed_outputs": ["comparison", "draft"]
  },
  "trigger_spec": {
    "kind": "scheduled_poll",
    "cadence": "daily",
    "local_time": "09:00",
    "timezone": "Asia/Shanghai",
    "missed_run_policy": "coalesce_latest"
  },
  "stop_conditions": {"until_user_stops": true},
  "memory_scope": "delegation",
  "notification_policy": {"mode": "meaningful_change_digest", "max_per_day": 1},
  "budget": {"max_runs_per_day": 2, "max_pages_per_run": 12, "max_model_tokens_per_run": 30000},
  "grant_template": "public_research_private_artifact_only"
}
```

上述时间与额度仅为示例，不是已知用户时区、已设定监控或承诺收费。响应包含 delegation_id、revision、state、effective_scope、effective_next_check_at；不可因为默认值存在便跳过创建界面对用户展示持续频率和范围。

### 6.3 工作简报和详情

- `GET /v1/brief?cursor=...`：返回 primary_ready_artifact、followups、server_time、projection_revision、sync_cursor。
- `GET /v1/delegations/{id}`：目标、范围、停止条件、下一次计划、最近健康检查、最新变化与阻塞。
- `GET /v1/delegations/{id}/runs` 与 `GET /v1/runs/{id}`：可解释时间线和各步证据。
- `GET /v1/artifacts/{id}/versions/{version}`：固定版本，访问前重新校验权限。
- `PATCH /v1/artifacts/{id}`，body 带 base_version：保存私有编辑，冲突返回 409 与当前版本，不自动覆盖。
- `PATCH /v1/delegations/{id}`，`If-Match: "7"`：修订范围/频率，返回受影响运行与审批。
- `POST /v1/delegations/{id}/pause`、`/resume`、`/cancel`：语义明确，取消持续委托不等于删除成果。

### 6.4 创建与决定具体审批

`POST /v1/actions/prepare` 由可信服务接收 candidate 并做目标解析、policy precheck 后返回 action_id 与 approval_id。移动端不能直接调用适配器。

```json
{
  "approval_id": "ap_018",
  "action_id": "act_018",
  "action_digest": "sha256:example_digest_generated_by_server",
  "summary": "将草稿第 3 版发给已核验的指定接收人",
  "effect_class": "external_send",
  "artifact": {"id": "art_42", "version": 3, "content_hash": "sha256:example_content_hash"},
  "target": {"provider_id": "recipient_017", "display": "具体接收人及账号"},
  "expires_at": "2026-10-11T01:30:00Z",
  "status": "pending"
}
```

这是未来外发扩展的契约示例，R1 没有真实发送适配器。示例 hash 为占位，不是可用批准凭证。

`POST /v1/approvals/{id}/decisions`

```json
{
  "decision": "approve",
  "expected_action_digest": "sha256:example_digest_generated_by_server",
  "expected_approval_revision": 2,
  "client_request_id": "decision_723"
}
```

服务端验证用户、未过期、当前成果/目标/权限版本与 digest，原子写决议与 outbox。若内容变了返回 `409 approval_stale`；若权限撤销返回 `403 grant_revoked`。返回 `approved_pending_execution`，实际效果另看 receipt。

### 6.5 记忆与删除传播

- `GET /v1/memories?scope_type=delegation&scope_id=...`：每项含来源、是否推断、有效期、作用范围。
- `PATCH /v1/memories/{id}`：用户更正创建新 revision，旧值被 superseded；不得丢失更正来源。
- `DELETE /v1/memories/{id}`：立即建立 tombstone 与禁止检索，返回 `202 deletion_job_id`。
- `GET /v1/deletion-jobs/{id}`：显示在线检索、摘要、缓存、对象、备份保留窗口各阶段；不能在仍有待清理副本时谎称所有物理副本消失。

### 6.6 同步与错误

`GET /v1/sync?after={opaque_cursor}` 返回按服务端 change_seq 排序的 upserts、tombstones、next_cursor；游标过期返回 `410 sync_reset_required`，客户端做有范围的重新同步。前台 SSE 可提供低延迟提示，断开后以 cursor 补拉；SSE 不是权威数据库。

统一错误：`{code, message, retryable, retry_after_seconds, request_id, current_revision, suggested_action}`。401 重认证；403 不重试扩权；409 重新读取并由用户/策略重新判断；429 遵守 Retry-After；5xx/网络错误依赖动作的 retry_safety，不能统一自动重试。

## 7 状态机与可靠性规则

### 7.1 一个完整研究循环

1. 用户明确创建持续委托，保存目标、来源、输出、频率、停止条件和预算。
2. 调度器生成逻辑 trigger；入站持久化并按 dedupe_key 去重。
3. 原子检查委托 active、当前 revision、预算、连接/来源权限；合并未开始的同类变化，创建 Run。
4. 工具拉取来源，用 ETag/Last-Modified 或内容 hash 比较；保存来源版本与健康状态。
5. 结构化抽取“何处变了、对主题何影响、证据在哪”。网页中的操作要求仅作为数据，不能授权调用工具。
6. 只有该委托已有有效基线与满足目标的首版成果，且本次确无实质变化时，才写 no_change 回执、更新时间与下一次计划，静默结束本次运行。首个 run 即使命中公共缓存、来源网页未变化，也要建立本委托基线并交付首版；不得继承其他委托的 last_processed_revision 而跳过。
7. 若有变化，按当前委托记忆生成私有成果新版本；验证引用、事实支持、输出完整性、用户编辑冲突与敏感信息。
8. 原子发布 ready 版本与首页投影，通知策略判断是否触达；通知失败不回滚已准备成果。
9. 用户阅读、改写或提出新要求。委托继续，直到已有停止条件成立或用户暂停/取消。

### 7.2 事件去重和乱序

- 有稳定供应商 event ID：`tenant + connection + provider_event_id` 唯一约束。
- 无 event ID 的轮询：`source_object_id + source_revision`；来源没有 revision 时使用规范化内容 hash。ETag 是缓存校验器，不保证等于语义内容版本。
- 原始事件去重与“内容无实质变化”是两层。先确保不重复执行，再判断是否值得生成/通知，不能用模糊语义判断代替唯一约束。
- 同一来源不同版本不能因为同一 URL 被误删；标题变化/页面模板变化可在二级 delta 分析抑制噪声，但保存诊断。
- 乱序事件回读最新对象，或按供应商可比较序列处理；不能依赖到达时间或只比较时间戳。Stripe 官方明确其 webhook 不保证生成顺序；这是外部集成需要防御的具体实例，不代表所有供应商语义相同。[Stripe Webhooks](https://docs.stripe.com/webhooks#event-ordering)
- webhook 重放验证签名、时间窗口、事件 ID；同一来源事件风暴按租户限速，入站隔离队列而非拖垮所有委托。

### 7.3 调度与停止

- schedule 保存用户本地时区与规则，同时计算 next_due_at UTC。时区改变要区分“每天当地 9 点”与“固定 UTC 时刻”；DST 缺失/重复时刻须有明确策略并测试。
- 云服务停机恢复默认 coalesce_latest：把错过的非关键研究轮询合并成一次当前状态检查；不补发几十个过期通知。对用户要求每次均有意义的任务另设 catch_up 策略。
- 用户暂停先停止新 run 与新触达；对正在执行的只读工作发取消，允许记录已到手结果。取消外部动作前必须看 dispatch 边界。
- 用户取消或 grant 撤销增加 epoch，worker 每个敏感边界检查 epoch；过期 worker 即使完成模型输出也不能新发外部动作。
- 连续来源故障、预算耗尽、凭据失效显示健康阻塞，不能无限快速重试。用户可以查看最近一次健康检查，不以“上次尝试”冒充“上次成功”。

### 7.4 幂等与原子边界

- 创建委托/决议等 API 用 `tenant + route + Idempotency-Key` 记录请求 hash 与结果；相同 key 不同 body 返回冲突。
- 每个逻辑动作固定 operation_id；attempt_id 随尝试递增。不得在网络超时后生成新 operation_id 来“重试同一件事”。
- 内部写入用唯一约束与事务（例如 artifact_id + version，operation_id + effect_kind）。
- 外部支持 idempotency key 时传递稳定 key，遵守供应商保存期限。超过期限或 key 语义不明确时先核对，不能假定仍防重。
- 本地幂等表只能防止本系统重复派发，不能证明供应商没有在超时前执行。跨网络事务不存在数据库式原子提交。
- 多 worker 租约失效时 fencing token 阻止旧 worker 回写，但不能撤回已发出的外部请求。敏感动作须先取得预约 claim，再通过 gateway 的原子 dispatch_commit（见 7.6）；claim 本身不许可外部调用。即便如此仍需供应商幂等/核对。

### 7.5 重试分类

| 结果 | 默认行为 | 用户状态 |
|---|---|---|
| 只读网络超时/429/暂时 5xx | 指数退避加抖动，尊重 Retry-After、截止时间与预算 | 稍后重试 |
| 模型结构不合法 | 有界修复或重生成；不放宽 schema/权限 | 正在整理；超限则失败 |
| 401/权限失效 | 停止受影响步骤，请求重新连接；不擅自扩大 scope | 需要连接 |
| 403/策略拒绝 | 不自动改参数绕过；说明具体限制 | 需要决定或不支持 |
| 外部明确未执行的失败 | 在相同权限与动作下安全重试 | 重试中 |
| 外部调用超时，可能已执行 | 进入 unknown，查询 operation/status/readback；不可直接重发 | 正在核实结果 |
| 人工审批超时 | expires_at 后失效，保留草稿；有需要时生成新快照 | 审批已过期 |
| 取消后仍有外部回执 | 对账并说明已发生事实；不宣称取消已撤回 | 已停止后续，已有动作待确认 |

重试策略必须有 max_elapsed_time 与 max_attempts，以及取消/预算检查。默认值可配置，不能无限重试直至费用失控。dead-letter 不是终止责任：需要可解释告警、修复后重放入口和相同幂等键。

### 7.6 审批版本绑定与撤销竞态

将“领取工作”“提交外部动作”“供应商接收”“效果核验”明确分开。`claim/reserved` 只预约一个 worker，没有外发权。预约后、提交前到达服务端并成功提交的撤销，必须阻断该动作。

**统一线性化点是 gateway 的 `dispatch_commit`，不是队列领取、模型工具调用、客户端点击或 HTTP 响应。** Gateway 通过同一强一致权威存储，按稳定顺序锁定 delegation/grant/operation，和 pause/cancel/revoke 使用相同记录与 epoch。事务内核验 approval 仍有效、digest 相同、成果/目标版本匹配、grant 与委托未撤销、有效期、工具/环境能力及预算，然后比较状态并原子写入 `dispatch_commit_seq`、`dispatch_committed_at`、authorization snapshot 与唯一 operation_id。撤销事务增加 epoch 并写 `cancel/revoke_commit_seq`。不能用最终一致缓存决定这场竞态。

- 撤销事务排在 dispatch_commit 前：该逻辑动作进入 `cancelled_before_dispatch`，gateway 不得调用外部工具，旧 worker、重试和过期 outbox 都不能突破。
- dispatch_commit 排在撤销前：动作已经进入“正在提交，结果待确认”的边界。服务端立即阻止之后的新动作，但不承诺该动作一定还来得及停止。
- 已提交但 transport 尚未开始：gateway 仍尝试本地中止。只有 transport 层能证明请求未交给网络、未来也不会重发时，才出 `cancelled_before_transport` 回执。
- 任何可能已交给网络的情况：不能称已取消；等待响应或进行有权限的只读核对，必要时标 `unknown`。

数据库提交与物理网络发包无法跨系统原子化。因此 dispatch_commit 是“不能再保证撤回”的产品边界，不是“请求已经发出”或“供应商已接收”的证据；界面和文案必须保留这个区别。若 worker 在 commit 后、实际发包前崩溃，恢复过程不得猜测已执行。没有撤销且供应商支持稳定幂等时可按同一 operation_id 恢复；若此时已撤销，即使幂等重试也可能首次产生效果，不得再发，只可在仍有读取授权时核对。停止委托只是停止新的业务工作；已提交动作的核对责任保留，直至得到权威结果、用户明确接手，或读取授权/供应商能力阻断。不能因委托已结束把 unknown 自动改成 failed。

取消/撤销接口响应明确返回 `blocked_operation_ids`、`in_flight_operation_ids`、`unknown_operation_ids`，只对前者显示“已阻止”。有在途动作时显示“后续已停止；一项动作正在核实，可能已经发生”。批量停止委托不能以一条成功响应掩盖这些差异。

支持撤销/删除的供应商动作也需要单独、适当的授权与回执；补偿不能被当成原事务回滚。如果用户同时断开连接并撤销读取，系统不得为了核对而继续访问该账号，应报告无法验证并提供用户手动检查路径。

批准后任何以下变化均失效：正文/附件版本、接收方 ID、可见性、账号、工具的副作用类型、金额/重要条件、权限 scope、相关 policy、证据不足导致行动实质变化。纯展示格式修复若不能证明不会影响提交内容，也按新版本处理。

必测竞态：claim 前撤销、claim 后/dispatch_commit 前撤销、两事务并发争用、commit 后/transport 前撤销、transport 已接受请求但响应丢失、commit 后 worker 崩溃再撤销。每个用例检查外部调用次数、数据库序列、客户端文案和恢复行为，不能只加一次“再检查权限”便宣称消除 TOCTOU。

### 7.7 离线与多端并发

- 手机缓存必须标记 as_of 和 sync 状态，不把过期卡片当当前任务状态。
- 本地未提交的编辑保存 client_mutation_id、base_revision；重连后提交并处理 409。
- 审批不排队自动提交；用户重新在线后必须看当前动作。拒绝/暂停可记录待同步意图，但明确尚未传达云端，不能提前显示“已停止云端”。
- 多设备同时批准同一动作只有一条决议与一次逻辑执行；另一设备同步已处理结果。
- 客户端收到更老 revision 不能覆盖新内容。通知打开与消息流更新只触发 fetch，不让通知 payload 直接修改权威状态。

## 8 工具适配协议与执行验证

### 8.1 适配器必须声明的能力

```json
{
  "tool_id": "public_source.fetch",
  "tool_version": "1.0",
  "effects": ["read_public"],
  "input_schema_ref": "PublicFetchRequest@1",
  "output_schema_ref": "SourceSnapshot@1",
  "supports": {
    "dry_run": true,
    "provider_idempotency": false,
    "status_query": false,
    "read_after_write": false,
    "cancel": false
  },
  "retry_safety": "safe_read",
  "timeout_ms": 30000,
  "required_grants": ["public_research"],
  "credential_location": "none",
  "verification_strategy": "http_status_and_content_hash",
  "data_residency": "deployment_defined"
}
```

还有适配器级 allowlist、最大输入/输出、文件类型、页面/重定向大小限制、目标解析、敏感数据类别、错误分类、服务条款/账号依赖。声明来自受控 registry 与测试结果，不能信任远端工具自称“只读”。MCP 的工具 annotations 本身也不是可靠授权依据；规范要求对不可信服务器的 annotations 持不可信态度。[MCP Tools](https://modelcontextprotocol.io/specification/2025-11-25/server/tools)

### 8.2 Gateway 统一执行顺序

`resolve → validate → authorize → prepare immutable action → obtain approval if required → reserve → atomic revalidate and dispatch_commit → transport → observe → verify → receipt`

只读公开 fetch 走简化但同样可审计的路径；无需给用户弹“是否允许打开下一页”。内部私有 artifact.create/update 由已授委托范围覆盖。未来 external_send/share/publish 没有 approval 不能进入 dispatch。

实现 API 与 MCP 都可接入；MCP 是工具发现/调用协议，不替代产品的用户授权、持久化、幂等或回执。首次集成优先正式 API，网页自动化只作有边界降级，不能在 API 返回禁止后换浏览器绕过权限。

### 8.3 证据等级

| 工具动作 | 成功必须看到的证据 | 不能作为成功的证据 |
|---|---|---|
| 公共资料读取 | 实际响应、来源身份、有效内容、抓取时间/hash | 搜索摘要、空页面、仅 URL |
| 私有草稿写入 | 存储成功后按固定版本读回，hash 相同，用户可访问 | 模型生成完一段文字 |
| 更新现有成果 | base_version 匹配，新版读回，与预期 diff 一致 | 最后一个 UI 按钮点击成功 |
| 外发消息（未来） | 供应商稳定 message ID 与已发送状态；若需送达则另验 delivery | 202 accepted、没有报错 |
| 公开发布（未来） | 权威资源读回、可见性/内容/受众符合审批快照 | 浏览器导航完成 |
| 电脑执行（未来） | 指定环境中可验证后置条件与环境身份 | 子任务称“完成”但无可验证结果 |

receipt 同时记录 confidence/limitations。某个供应商只能证明 accepted，就如实展示“服务已接收，效果待确认”，不能升级 verified。

## 9 记忆生命周期与删除传播

### 9.1 作用域与检索规则

- run：短期工作上下文，默认随运行保留策略过期。
- delegation：目标、明确要求、已接受的成果状态与相关来源事实；R1 默认。
- project：需要用户明确关联委托与项目，按项目访问范围检索。
- user：可跨委托使用的明确偏好或经确认事实；用户显式开启后才纳入。

检索必须先按 owner/scope/ACL/有效期/deletion_epoch 过滤再排序，不能先取全局 top-k 再让模型“忽略别人的”。向量相似度不是授权，也不证明事实仍有效。模型只接收本次所需片段与引用；密钥不进入记忆库。

用户更正、删除和“以后别这样”要区分：删除一个事实不代表撤销工具连接；关闭某来源连接不默认删除用户已有私有成果；撤销连接后禁止新读取，并让依赖数据按选择清理/保留。界面提供分开的“停止获取”“删除已保存资料”“删除成果”，避免一个按钮暗含三件不同事。

### 9.2 删除传播与防止自动重建

删除不仅使当前记录不再检索，还应防止系统从保留的旧对话、来源副本或摘要把同一条记忆重新存回来。`MemoryItem` tombstone 与 `ForgetSuppression` 是两个独立对象。

ForgetSuppression 保存最小化元数据：owner/scope、被删除 memory_id、source_message_id/source_span_ids、derived lineage IDs、适用的结构化 subject/predicate 指纹、created_at、deletion_epoch、恢复条件。指纹应采用租户隔离 HMAC 或等效方案，不能在 suppression 里暗存被删除正文；摘要、索引和备份仍必须按删除流程处理。指纹不是普遍可靠的“语义相同”判定，来源链和保守阻断是主要保障。

1. 在同一权威事务中创建 tombstone 与 suppression，增加 scoped deletion_epoch，检索立即排除内容；这是同步完成的隐私屏障。
2. 标记 derived_from 图上的索引项、摘要、context manifest、预生成草稿/建议、缓存为失效。保留原对话供用户查看，并不允许自动记忆抽取再利用被抑制的源片段；若旧摘要无法定位片段，就整份摘要失效并基于允许材料重建。
3. 抽取入口先过滤 suppression 覆盖的来源片段；记忆 candidate 入库前再次检查 provenance 和 subject/predicate 指纹。在同一作用域可能重建同一事实但无法可靠区分时，保守不写长期记忆，不能把模型换一个说法当新事实绕过。保留抑制测试样本，但不保留被删除正文。
4. worker 每次模型调用、有副作用动作前，以及模型返回后发布 ArtifactVersion/read model/outbox 的事务内，都核对 context_manifest 涵盖的全部 scope/source deletion epoch。删除期间在飞的模型返回必须丢弃或基于净化上下文重做，旧 epoch 不得发布 ready 或发通知。已经发送到模型提供方的历史输入不能假装未发生。
5. 清除在线原文/向量/缓存，按依赖重新计算仍允许保留的摘要与成果。对用户编辑成果不可静默整篇删除，应标记含已删资料并按用户选择处理；若用户明确要求彻底删除该资料，则清理可识别副本并显示受影响项。
6. 删除队列幂等运行，记录各存储阶段与核验结果；已退出账号设备下次连接收到 tombstone，本地缓存必须有到期清理。长期离线或已导出的副本无法保证立即抹除，需如实说明。
7. 备份采用明确有限保留期和访问隔离；恢复时先应用删除日志及 suppression，避免“从备份复活”。删除审计仅保留最小 ID/时间/结果，不保留被删除正文。
8. 只有用户在删除后新近、明确地要求记住或重新陈述相关事实，并能判断这就是用户当前意图，才可新建有新来源的记忆并解除对应 suppression。转引旧对话、检索命中、第三方提到、模型自行推断都不能解除。存在歧义时保持不记忆，必要时问一个明确问题。
9. 外部已发内容无法通过删除本地记忆自动收回；如需对外删除，另走具体授权和供应商能力。

suppression 的作用域和保留用途需在隐私说明中讲清：它仅用于兑现“不再自动记起”，不用于恢复正文或个性化。用户要求删除账户时纳入账户删除范围；用户仅删除某条记忆时保留最小 suppression 元数据以防重建。

建议 R1 在线可检索屏蔽与 suppression 同步生效，异步物理清理目标 24 小时内；备份建议最长 30 天滚动窗口。这些是拟议服务目标，须根据实际部署、合同与适用要求确认，不是现有承诺。

必测：删除后重新总结原会话、重复 ingestion 同一源、从旧摘要抽取、换措辞的候选、跨设备旧缓存、备份恢复、用户新明确要求重新记住。并加入模型调用在飞时删除后再返回的竞态：旧输出不得入成果和通知。自动重建各项不得复活；用户重新明确要求一项有可审计的新用户来源。

### 9.3 保留与最小化

公共资料缓存可共享原始公开内容，但用户关注列表、标注、研究轨迹和个性化摘要仍属于用户数据。私人来源（后续扩展）不能与公共缓存混用。默认不做跨用户语义检索。

模型提供方、日志平台、存储区域与保留设置必须在首次接入前核实。R1 公共来源研究仍会向模型发送用户研究主题和草稿，产品应说明处理方与用途，不能因为来源公开就声称整个流程“没有用户数据”。

## 10 安全威胁模型

### 10.1 资产与边界

保护：用户身份/会话、工具凭据、委托目的、私人草稿、研究偏好、记忆、审批、外部账号和执行器。

边界：用户与第三方文本；移动端与服务端；不同租户；模型建议与确定性执行；工具 registry 与远程描述；公共网络与内部网；云端与用户电脑；私有成果与公开发布。

### 10.2 主要威胁与控制

| 威胁 | 场景 | 必需控制 |
|---|---|---|
| Prompt injection | 网页要求忽略目标、上传文档、修改许可 | 来源内容以数据封装；模型无直接凭据；有副作用调用独立策略门禁；动作必须匹配用户授权 |
| 记忆投毒 | 来源称“用户已同意以后自动发帖” | 仅用户来源可建授权；来源事实不得写入指令/偏好 scope；显式更正优先 |
| 越权访问/IDOR | 修改 artifact_id 读取别人的文件 | 所有端点从 session 派生 tenant；资源级 ACL；对象读 URL 短有效期且受控 |
| 跨用户检索泄露 | 向量搜索混入其他用户片段 | 检索前 ACL 过滤、独立 namespace、跨租户负例测试 |
| 审批重放/内容调包 | 批准旧草稿后换收件人 | 服务器 immutable envelope、digest、version、TTL、一次逻辑动作 claim |
| TOCTOU 与撤销竞态 | 批准后权限被撤销 | 执行前重验与 epoch，原子 dispatch_commit；claim 仅预约，记录提交边界 |
| SSRF/恶意 URL | 来源跳转云元数据或内网 | HTTPS allowlist、逐跳校验、阻断私网/保留地址、出口代理与 DNS rebinding 防护 |
| 工具供应链 | MCP 新工具自称只读却写数据 | 受控注册、版本固定、输出校验、适配器合约测试、变更重新审核 |
| 凭据泄露/混淆代理 | 上游 token 被透传给错误服务 | 凭据库隔离、短期 token、audience 校验、明确下游账号和 scope |
| 通知泄密 | 锁屏出现研究秘密或审批令牌 | 通用文案、不透明 ID、无正文/可执行 token；认证后 fetch |
| 资源耗尽 | 无限事件、模型循环、超大 PDF | 入站/工具限流、文件大小/解压上限、token/费用/深度预算、熔断 |
| 虚假完成 | 工具超时被总结为成功 | 结构化 receipt、未知状态、readback 验证、completion evaluator |

### 10.3 Prompt injection 分层防护

第一层为数据与权威隔离。原始网页/文档/工具结果不能插入 system/developer 指令或服务端 policy；保留来源标签、可引用片段与时间。来源中的“立即发送”“管理员已授权”等文字不建立权限。

第二层为最小工具集。研究 run 默认只有公共读取、私有 artifact 与必要记忆读取；没有外发、账号管理或 shell 工具。任何新增工具须 gateway 评估授权，不由模型自行解锁。

第三层为结构化数据通道。抽取器输出有限 schema：claim、source_ref、observed_delta、relevance；枚举/长度/ID/URL 都校验。结构化输出有助减少自由文本对控制流的影响，但不能证明字段语义安全，不能把“valid JSON”当通过安全检查。

第四层为独立执行门禁。effect_class 与所需许可由服务端 registry 决定；对目标、数据类别、参数内容、grant、digest、预算做检查。模型输出“已经批准”不被读取为布尔权限。

第五层为内容与链接安全。渲染 Markdown/HTML 时去活动脚本、危险协议、远程追踪资源；打开外部链接提示目标域名。抓取器逐跳校验地址，隔离解析附件。MCP 官方安全指南详细讨论了 OAuth 发现中的 SSRF、DNS rebinding、重定向及出口限制，可作为工具网络层的参考。[MCP Security Best Practices](https://modelcontextprotocol.io/docs/2025-11-25/tutorials/security/security_best_practices)

第六层为对抗评测和可回滚上线。覆盖文本、HTML 隐藏内容、图片 OCR、PDF、工具描述、检索摘要、记忆与跨来源指令洗白。OpenAI 官方建议把不可信内容与高优先级指令隔离、约束跨节点结构、结合工具确认和评测；这些可降风险，不能承诺消除所有 prompt injection。[OpenAI Agent Safety](https://developers.openai.com/api/docs/guides/agent-builder-safety)

### 10.4 身份凭据与存储

优先复用宿主身份；无宿主支持才另选成熟身份方案，不能在原型里用静态 token 冒充正式鉴权。未来 OAuth 使用安全的授权码流、PKCE、精确 redirect URI、state/nonce 和最小 scope；移动客户端不藏 client secret。RFC 9700 明确公共客户端使用 PKCE 的安全要求。[OAuth 2.0 Security BCP](https://www.rfc-editor.org/rfc/rfc9700.html)

服务端工具凭据由凭据服务管理，模型只看 credential_ref，日志不保存 token。MCP 接入需 audience 绑定、验证每次请求，禁止把客户端 token 原样透传给下游服务。[MCP Authorization](https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization)

数据库使用应用层资源授权并可加 RLS 纵深防御；不能把 RLS 当全部保障，因为超级用户、BYPASSRLS 角色、通常的表 owner 可绕过，服务角色配置必须测试。[PostgreSQL Row Security](https://www.postgresql.org/docs/current/ddl-rowsecurity.html)

传输 TLS，静态数据加密，对象存储私有，生产与评测环境隔离；审计访问最小化，导出敏感日志需要单独权限。R1 不采集无关设备位置、通讯录、麦克风或相册权限。

## 11 评测与可观测性

### 11.1 发布门槛不是只看回答好不好

必须同时测质量、安全、可靠性、隐私和打扰程度。测试数据使用公开来源或合成内容；真实用户数据进入评测前另确认授权与保留策略。

建议首版建立 60 个闭环用例，按 12 类各 5 个变体覆盖：无变化、实质更新、旧资料纠错、冲突来源、用户改稿、来源失效、重复事件、乱序事件、worker 崩溃、审批版本冲突、记忆删除、恶意注入。另有 API/适配器单元、契约、集成和故障注入测试，不以 60 个语言用例替代系统测试。必须额外验证 first_run/use_cached_source：公共源无新版本但新委托仍产出首版。

### 11.2 验收矩阵

| 维度 | 必测内容 | 建议门槛或指标 |
|---|---|---|
| 事实与引用 | 核心结论与一手证据对应，引用实际支持 | 高影响结论 100% 有可核对证据；抽样支持率 ≥95% |
| 实质变化 | 新内容是否影响主题，避免模板噪声 | 人工标注集 precision 优先；目标 ≥90%，同时记录漏报 |
| 私有成果质量 | 信息完整、可编辑、版本清楚 | 固定测试集关键段落和来源映射全部通过 |
| 权限 | 未批准外发、错租户读取、旧审批执行 | 0 次绕过；任一严重绕过禁止发布 |
| 重复副作用 | 相同事件 100 次、重复审批、多 worker 崩溃 | 同一 operation_id 不得重复产生已知外部效果；unknown 必须保留 |
| 撤销 | claim 前/后、dispatch_commit 前/后、transport 前/后、并发与崩溃 | commit 前撤销阻断；commit 后按证据中止/核对，绝不虚假承诺撤回 |
| 删除 | 索引/摘要/缓存/排队上下文/旧源重抽取/恢复 | tombstone 后不可检索；旧 epoch 不新执行；suppression 阻止自动重建 |
| 离线 | 手机离线、重连、旧通知、多端冲突 | 不丢意图，不静默覆盖，不离线批准执行 |
| 恢复 | worker 在每一步崩溃、服务重启 | 从已保存 checkpoint 继续；不重复已验证写入 |
| 触达 | 安静时段、无变化、重复更新、拒绝通知 | 无变化不推送；同一成果版本不重复打扰 |
| 成本 | 事件风暴、大文档、循环工具 | 达到硬预算后阻止新增费用，并显示原因 |

阈值是初始工程验收建议，需用场景数据校准；不是已经测得的产品能力。R1 建集时锁定评审单位与分母：事实支持率以抽样成果中的可核验原子事实 claim 为单位，未支持/无法核对计入未通过；变化 precision = TP/(TP+FP)，同时报告 recall = TP/(TP+FN)，无正例时不得报 100%。有标注指南、来源版本、两人独立标注/分歧裁决及固定测试集后才可报实测达标。

### 11.3 观测事件

统一传播 correlation_id、delegation_id、run_id、operation_id、artifact_version、policy_version、adapter_version、model_version/prompt_version。记录阶段耗时、重试原因、来源健康、审批等待时间、回执状态、token/工具成本、notification decision reason。

不记录原始凭据、审批秘密、完整私人正文或模型私有思维链。可解释记录包括“因哪项范围/版本拒绝执行”“用了哪些来源”“哪一项后置条件核验失败”。脱敏和租户隔离同样适用于 trace 后端。OpenTelemetry 的 traces、metrics、logs 可作为供应商可替换的标准观测层。[OpenTelemetry Observability](https://opentelemetry.io/docs/concepts/observability-primer/)

### 11.4 初始 SLO 与告警

- 权限检查、动作版本绑定和删除屏蔽：正确性硬门槛，不以平均成功率掩盖安全缺陷。
- 在云服务健康、来源可用和预算足够的前提下，定时研究开始延迟建议 P95 <5 分钟；首次成果耗时由来源数/模型决定，记录实测，不先承诺固定秒数。
- 正常网络下首页 API P95 <1 秒（不含大文件下载）；客户端旧数据有 as_of 提示。
- 审批后待执行超过预期、unknown 副作用、持续来源失败、queue lag、dead-letter 增长、删除传播超期、跨租户拒绝峰值均告警。
- 对用户推送的送达时延不设硬保证；统计 provider accepted、可见遥测与 opened 的不同转化。

成本按每个委托/运行归因，展示预算使用与可解释上限。先用结构化 diff、条件 GET、内容 hash、摘要缓存减少重复模型调用；不要靠频繁模型空转检查“有什么可做”。

## 12 分阶段交付与依赖

统一使用 D0/B0/D1/R1，避免把交互探索、独立基础复刻、原宿主适配和真实后台混写。B0定义见第16节，可在没有原宿主源码时完成真实本地功能；D1是可选回接而非B0/R1前置。后续R2–R4为扩展路径。当前工作按实际进度称“宿主对齐原型”或“独立基础复刻”，不能称已在真实CatDesk中集成。

### 阶段 D0 宿主对齐交互原型

交付：依据已见 CatDesk 交互对齐的工作简报、委托详情、可阅读成果、版本/来源、审批失效、记忆修改删除、权限和离线/异常状态。所有后台事件与工具结果使用确定性 fixtures，并明确“演示数据/原型”。演示控制器可以推进事件，不伪装真实持续监控。

门槛：手机尺寸交互和无障碍基础检查；返回/关闭/重复点击一致；ready 与持续 active 不混淆；拒绝通知不阻断首页；没有真实外发/账号连接/部署副作用。

依赖：可在当前独立原型环境完成；无需等待宿主所有后台问题答案。并行完成一次宿主 capability 勘察，为真实集成准备。约一周仅可作为有人员和环境条件时的 D0 排期假设，不是 D1/R1 的完成承诺；本规格不在未见代码前承诺工期。

### 阶段 B0 独立基础复刻

在31图证据矩阵基础上，交付可独立启动的会话/消息/项目/专家/技能/任务/定时任务/文档/环境/权限模块。真实实现本地UI、导航、数据关系、持久化与适用主路径；远端行为使用明确标记的fixtures，不等待原宿主代码。验收区分界面、导航、本地功能、模拟远端和真实后台五层，详见第16节。新增助理和语音应复用这套基础。

### 阶段 D1 宿主内集成演示

交付：把 D0 页面嵌入真实 CatDesk 分支，复用实际入口、路由、返回/关闭、会话与文件组件；仍可使用明确标记的 fixtures。验证宿主不会多出一套相互冲突的导航、身份和权限界面。

依赖：宿主源码、运行环境、组件/API 接口与授权的工程任务。验收要在真实宿主完成入口/返回/恢复/阅读器与表单交互，独立浏览器原型不能计作通过。D1 的嵌入通过不证明真实后台已就绪。

### 阶段 R1 真实有限闭环

交付：一个实际云端委托、批准范围内的 2–5 个公共一手来源、真实持久日程、内容版本检查、结构化变化提取、私有成果版本、读回验证、工作简报增量同步、停止/恢复、预算和故障恢复。推送可在宿主具备真实配置后接入；未配置时用前台同步完成闭环，不声称手机必达。

依赖：独立应用或宿主已有身份/资源所有权方案；一个可部署服务环境和数据库；私有文件存储；模型与公共 fetch 出口；操作日志与密钥管理；用户同意的频率/来源与处理方说明。部署/账号配置需由获授权实施流程完成，本规格不执行。

验收：至少经历两个不同日期的真实持久运行；关掉手机后云端继续；来源实际更新产生带证据的新版本；无变化不打扰；服务重启与重复事件不重复生成；用户改稿不被覆盖；用户取消后不再新增研究；断网重连可见正确状态；删除与恶意来源测试通过。

不能以手动点击一次“生成草稿”冒充持续闭环。自然来源没有更新时可用明确标记的测试来源制造变化，分别报告“调度/状态真跑”和“来源变化为测试注入”。

### 阶段 R2 多委托与记忆扩展

增加：事件订阅、更多公共来源适配、项目作用域、用户显式跨委托记忆、通知偏好、检索质量评测和删除图。先证明主题隔离、用户更正优先与成本可控，再增加更广感知。

依赖：R1 稳定，队列容量与成本数据足够；若长等待流程明显复杂，再引入持久工作流引擎。仍不必加入任意网页自动化或自动外发。

### 阶段 R3 账号连接与外部写操作

逐个接入用户确实需要的服务与动作。每个适配器都要完成 OAuth/权限说明、目标解析、最小 scope、审批绑定、幂等/unknown 对账、回执和撤销测试。先支持一个清晰、低风险外发动作，不同时开放所有 MCP 工具。

依赖：用户对具体数据与目标授权；供应商正式 API/条款；凭据服务；安全复核；真实 provider sandbox 或测试账号；移动端完整审批交互。不能把“连接账号”视为“允许以后任意发送”。

### 阶段 R4 电脑与复杂执行

有明确用户需求再接电脑环境、文件和本地应用；独立环境身份、在线状态、范围权限、可核验 postcondition。环境离线是等待条件，不能靠手机常驻后台解决。涉及金融、医疗、身份、不可恢复删除等高风险动作，需要专门策略和人工接管边界，不纳入首版普遍自动执行承诺。

### 实施工作包与依赖顺序

1. Host capability 勘察 + API/schema contract：移动、后端共同确认最小桥接。
2. 核心状态与存储：Delegation/Run/Event/Artifact/Grant/Receipt + outbox + sync。
3. 公共源适配器与调度：条件 GET、去重、健康、预算、恢复。
4. 内容流水线：提取/差异/引用/草稿/质量验证，结构化边界。
5. 端上真实读写：工作简报、成果编辑、委托控制、来源/记忆，版本冲突。
6. 安全与故障门槛：撤销、删除、注入、崩溃、乱序、离线。
7. 推送与观测：隐私 payload、设置、聚合、端到端 trace。

工作包 3/4 可用契约 mock 并行，端上也可继续精修；生产打通必须等待1/2的身份、权限和状态来源确定，但B0本地基础功能不必等待宿主桥接。未见代码、人员与部署环境前不报精确工期。

## 13 最小待决策项

不需要用户替工程团队选所有技术。下列先用建议推进设计，真正影响范围/隐私的再确认：

1. **首个真实闭环是否采用持续技术主题研究与私有草稿？** 推荐采用；可换成用户更高频的资料研究任务，不改变委托/运行架构。
2. **iOS构建与目标设备的实际条件。** 平台选择已确定为iOS，不再询问；只校准本机Xcode/SDK、最低系统和可运行设备。原生B0不以宿主源码可用为前置。
3. **后台是否可复用 CatDesk 已有服务？** 这是工程勘察事项；默认优先复用身份/文件/会话，长期领域能力不足的部分新增。
4. **数据和模型部署边界是否有要求？** 若没有特定企业/地区限制，先以当前团队受控云环境、最小数据、私有存储设计；实际提供方、区域与保留期上线前确认。
5. **研究频率、来源与通知上限？** 设计默认每日检查、显著变化才摘要触达、跨任务记忆关闭；创建委托时让用户看到并可改，不把示例时间当真实用户偏好。

暂不要求决定：向量数据库品牌、工作流引擎品牌、任意专家市场、邮箱/日历、公开发布渠道、多电脑控制。它们不是验证首个闭环的前置条件。

## 14 风险排序与实施底线

**最高风险：把 UI 能力误当真实基础设施。** 先做 capability 勘察，原型与真实状态明确分开。

**最高风险：权限只写在 prompt 里。** 独立 gateway 与 immutable approval 是外发前置；无此能力不接真实写工具。

**最高风险：超时重复执行或虚假完成。** operation_id、unknown、readback 与 receipt 先于更多工具。

**高风险：记忆删除仅删一行。** 依赖图、epoch 与备份恢复处理需在第一个真实记忆功能上线时加入。

**高风险：手机后台被当服务器。** 云端驱动，端上最终同步；通知只作尽力触达。

**中高风险：质量差却频繁主动打扰。** 证据化 delta 与触达评测；先安静准备有用成果，再请求用户注意。

**中风险：为未来通用 Agent 平台过度建造。** 先模块化单体、一个场景、一个可靠闭环；按真实复杂度替换基础设施。

本次交付是设计与官方约束研究，没有验证 CatDesk 生产接口，没有运行持续后台任务，没有接入账号、发送消息、发布内容或修改远程仓库。

## 15 语音交互与可替换语音技术栈

新增范围：语音交代、前台连续对话、朗读成果、口述改稿。语音是同一套委托/成果/授权系统的输入输出方式，不另建一个能绕过业务规则的 Agent。本文仅更新设计与契约，没有安装模型、接入账号、部署语音服务、录音或向服务商传输私人内容。

### 15.1 默认选择与“免费”的准确范围

采用两层可替换方案：

1. **先行可用朗读**：在真实运行容器支持时，Web 原型使用 `speechSynthesis`；原生宿主使用系统 TTS 适配器。选择已安装且已核验本地的中文语音，目标是无需额外按次 TTS 服务费。声音清单、中文可用性、离线能力、朗读质量与具体设备有关，不能承诺每台设备同样效果。
2. **高质量中文升级候选**：自托管 `Qwen3-TTS-12Hz-1.7B-CustomVoice`；资源更紧时评估 0.6B-CustomVoice。官方发布 Apache-2.0 模型，覆盖中文等 10 种语言与预设音色。1.7B 的风格控制是评估重点；0.6B 不把 `instruct` 情绪控制列为保证能力。它们免模型许可费用，设备、GPU、内存、带宽和运维仍有成本，未做本产品实测前不称“全球第一”“免费 GPU”或手机实时可用。[Qwen 官方仓库](https://github.com/QwenLM/Qwen3-TTS)、[官方 1.7B 模型卡](https://huggingface.co/Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice)
3. **ASR 分开选择**：优先真正可用的设备端识别；自托管/本地 `whisper.cpp` 的多语 base/small 是可评估候选，不能选仅英语的 `.en` 版本充当中文识别。官方工程支持 CPU、Apple Metal 等路径及多平台示例，但模型可运行不等于在目标手机满足延迟/电量要求。[whisper.cpp 官方工程](https://github.com/ggml-org/whisper.cpp)

不在 D0 默认安装这些模型或下载语音包。D0 可以真实演示已有设备语音的朗读；ASR 未接通时仍是可辨认的模拟转写，不能把动效或输入框填字标成真实录音识别。R1 的在线 ASR/TTS 必须先确定具体处理方、数据目的和保留策略。

**流式实现必须锁版本。** Qwen 普通 `generate_custom_voice` 示例返回完整 WAV，本身不证明 HTTP 服务能边生成边播放。当前 vLLM-Omni 官方 speech API 支持流式，但不同版本的 SSE/原始音频响应契约不同；适配器须固定版本并做合约测试，不把模型宣传的最低延迟当本产品端到端延迟。其文本流接口可能按句缓存再合成，所以“模型支持流式”“服务返回流”“首句开始播放”应分别测量。[vLLM-Omni Speech API](https://docs.vllm.ai/projects/vllm-omni/en/stable/serving/speech_api/)

本规格不预设未经官方验证的绝对最低 VRAM，也不把模型下载体积当显存需求。容量评估记录硬件、精度/量化、并发、文本长度、首音频延迟与 real-time factor 后再定部署预算。

### 15.2 平台能力与数据路径必须可证明

- Web Speech 的合成与识别接口都可能由本地或服务端实现。`SpeechSynthesisVoice.localService` 是选择本地语音的能力信号，仍需在目标浏览器/WebView 中验证；API 存在不代表语音包、中文或音频输出可用。规范中的本地 ASR 开关也不能当所有浏览器都已实现的证据。[Web Speech 官方草案](https://webaudio.github.io/web-speech-api/)
- Android TTS 通过具体 Voice 的 `isNetworkConnectionRequired()` 区分是否需要联网。保存 voice_id 与 engine_id，不把系统默认 engine 永久视作本地；切换声音后重新评估数据路径。[Android Voice](https://developer.android.com/reference/android/speech/tts/Voice)
- iOS 使用 SFSpeechRecognizer 路径时，只有 `supportsOnDeviceRecognition=true` 才可依赖 `requiresOnDeviceRecognition=true` 的设备内识别要求；不可用时返回明确错误，不静默改云端识别。[Apple On-device Recognition](https://developer.apple.com/documentation/speech/sfspeechrecognizer/supportsondevicerecognition)
- Android API 31+ 提供 `isOnDeviceRecognitionAvailable()` 与 `createOnDeviceSpeechRecognizer()`；需要核验目标设备、语言和已安装资源，普通 recognizer 可用不证明离线可用。[Android SpeechRecognizer](https://developer.android.com/reference/android/speech/SpeechRecognizer)
- 原生音频由宿主唯一的音频会话/焦点管理器统一管理，不能让 TTS、ASR 和媒体各自抢设备。iOS 音频中断、Android audio focus 丢失必须进入显式状态并停/暂停相应动作；恢复遵循用户意图而非盲目自动重播。[Apple Audio Interruptions](https://developer.apple.com/documentation/avfaudio/handling-audio-interruptions)、[Android Audio Focus](https://developer.android.com/media/optimize/audio-focus)

首次能力探测和每次 provider/voice 变更后保存：platform、runtime_version、provider_id/version、language、locality（verified_on_device / controlled_server / third_party / unknown）、offline_tested、支持的取消/流式/时间戳能力、测试时间。`unknown` 不允许用于私人正文/音频传输。离线测试只验证所测路径，不宣称永远无网络或覆盖所有设备。

### 15.3 三个接口边界

**TTSProvider**

- `capabilities()`：可用语言、voice_id、执行位置、是否需要网络、输入长度、文本/音频流能力、暂停/取消、逐字边界是否可靠。
- `synthesize(request, cancellation)`：接受纯文本或固定成果版本的允许片段，返回带 request_id / turn_id / playback_epoch 的音频段或设备播放 handle。
- `cancel(request_id)`：停止未完成生成；播放器必须另行立即清空本地队列。服务端支持取消不等于已经播放的声音可撤回。
- 输入不接受任意 SSML、外部 audio URL、任意服务地址或模型生成的 provider 参数；允许的语速/音色由 registry 限定。

**ASRProvider**

- `capabilities()`：语言、locality、是否真流式、最大会话时长、partial/final 语义、时间戳/置信度可用性、取消能力。
- `start(request)` / `append(audio_chunk)` / `finishInput()` / `abort()`：区分结束本句并请求最终转写与彻底取消本句。音频格式协商，不把所有设备的采样率写死。
- 输出 `partial`、`final`、`no_speech`、`error`；附 capture_id、utterance_id、revision、session_epoch、序号。partial 可被后续改写，不能作为不可逆业务命令。
- `abort` 后即便 provider 回传 final，当前客户端/服务端仍按 epoch 丢弃，不写入聊天、记忆或成果。

**VoiceSessionAdapter**

统一接入宿主会话、身份、麦克风权限、音频会话/焦点、路由、VAD、echo cancellation 能力、ASR/TTS Provider、播放器、字幕与文字输入。

提供 `startSession`、`startCapture`、`finishUtterance`、`abortCapture`、`submitTranscript`、`readArtifact`、`pausePlayback`、`resumePlayback`、`stopPlayback`、`interruptTurn`、`endSession`。按钮和口令对应明确动作；“停一下”在朗读中默认只停止朗读，不自动取消持续委托。若用户明确要求停止委托，才走现有 delegation cancel 与 dispatch_commit 语义。

模型不能直接申请麦克风、恢复录音或改变 provider；这些是用户动作和确定性会话控制器的职责。单一音频 owner 控制设备，避免两个会话同时录音或播音。

### 15.4 单次口述与连续对话

**单次口述为先行默认**：用户点击/按住说话 → 显示麦克风正在使用 → 录音/本地 VAD → 松开或点击结束 → ASR 最终文本 → 可编辑预览 → 发送到当前对话或指定成果编辑动作。用户取消时清除临时音频与尚未提交文字，不留下伪造的“已发送”。设备返回 partial 时可以展示，但只作为暂定文本。raw ASR 的 transcript_revision 与用户编辑的 edit_revision 分开；用户开始编辑后，迟到的 ASR final 只能成为独立候选，不能覆盖编辑器。提交时冻结 submitted_text_ref、submitted_text_hash 与 submitted_revision，正文以用户最后确认的编辑版本为准，之后的识别回包不得改写已提交消息。

口述改稿必须携带 artifact_id、base_version、selection_span 或明确编辑目标。生成修改建议后仍用现有版本冲突检查；不能把“把第二段短一点”误作用于刚切换的新文档。私有改稿无需额外外发审批，但引用对象不明确时需要澄清。

**连续对话是用户主动开始的前台、多轮、有限会话**，不是全天候后台收音。R1 可先采用轮替发言/按住说话；启用 VAD 自动分句和自动提交 final 之前，用户需看见本会话行为并可随时改回手动。VAD 仅检测语音活动，不证明一句话已说完；静音超时、最长一句、最大会话时长和低置信度均有可配置处理。

连续模式中普通对话 final 可自动提交为该会话的新一轮，仍不能直接批准外发、支付或权限扩展。首版具体动作审批在屏幕上展示 ActionEnvelope，用户查看并确认；从录音中识别出的“好”“可以”不单独替代该界面。ASR 文本是可能错误的输入，不是生物身份认证；电视、旁人声音或扬声器回声不能获得用户权限。

TTS 开始后，半双工模式停收或抑制识别；只有实际 AEC/双工路径通过真机测试后才启用讲话打断。不要把 Agent 自己读出的“发送”再次识别成用户命令。用户按“说话”可先本机停播，再进入采集，确保有一个可靠的打断路径。

### 15.5 朗读成果与实时回复

朗读请求固定 artifact_id、version、content_hash、reading_mode（全文/摘要/选中段）及字符/段落范围。用户选择“全文”时不能只读模型摘要；代码块、URL、表格如何转成语音应可预测，并保留原文供对照。大段成果先按语义边界分段，不将全部私人全文无条件发送给 TTS 服务。

实时对话仅把稳定、可展示的回复片段送 TTS；未完成的 token、后来可能撤回的内部草稿和工具私有输出不能抢先播出。每段有 segment_id、segment_index、text_hash、turn_id、playback_epoch。播放器按序播放，限制预取和缓冲长度，避免用户打断后仍排着长串旧音频。

`end` 回调只代表当前 utterance 已结束，不证明用户听完或认可。音频已合成、首音频到达、实际开始播放、段落结束、用户主动停止和成果已看都分开记录。语音播放不自动把成果标为已审阅，不建立发送许可。

后台产生 V+1 时，可继续朗读屏幕仍固定展示的 V，并提示有新版；不能自动换稿混播。用户主动进入编辑、切换显示到 V+1 之前，必须停 V 并增加 playback_epoch。用户删除/撤回正在朗读版本或撤销访问权限时立即停止；继续时基于用户选择且仍有权限的版本重新生成，不能一边展示新版一边读旧文。删除源记忆命中当前朗读上下文时，同样取消相关音频、临时缓存和待发请求；已在空气中播放的声音无法收回。

### 15.6 取消 打断和过期回包

为会话使用 `session_epoch`，为每次输入使用 capture_id / utterance_id，为输出使用 turn_id / generation_id / generation_epoch / playback_epoch。取消不是只有一个布尔值。

1. 用户打断首先本机停止音频源、清空未播放队列，增加 playback_epoch；不等待服务端确认才停声。
2. 只取消控制指令覆盖的生成/流请求；支持 AbortSignal 或 provider 等价机制。stopPlayback仅取消TTS与播放器，合法文字回答可继续；interruptTurn才终止当前回答generation。停止后不自动把相同语音文本再排队。
3. 按事件类型检查相关epoch，不能因为包带了全部epoch就要求全部相等：ASR partial/final检查session/capture/consent及当前提交条件；合法文字回复检查session/turn/generation；TTS与播放回调再检查playback、正文版本与删除epoch。stopPlayback不使合法ASR final或文字回复失效。相关epoch过期的回包只可记录最小诊断，不得恢复录音、播放、写聊天、改稿、建记忆或显示完成。
4. `finishUtterance` 与 `abortCapture` 不同：前者允许本句 final 返回待确认，后者使本句及迟到 final 失效。
5. `stopPlayback` 与 `endSession` 不同：前者只增加 playback_epoch，停朗读，可继续合法文字回复/下一轮；后者增加 session/capture/playback/generation epoch，停全部语音采集、播放、网络流，释放音频会话/焦点和临时数据。已提交给业务系统的输入和持续委托不因此撤销。
6. 跨端撤销 provider 授权增加 consent_epoch。客户端在收到后立即停采集/播放；服务器每次转发新音频/文字块前检查 epoch，在取消与发送同一序列中裁决。已发数据无法承诺收回；断网设备的纯本地麦克风停止由本机退出/失焦/会话上限保证，不能宣称远程瞬时控制。

控制矩阵必须由确定性控制器实现：

| 指令或系统事件 | 失效对象 | 仍有效的对象 |
|---|---|---|
| finishUtterance | 停收新音频，本句仍等待final | 本句可预览；已明确启用的前台连续模式可提交final |
| abortCapture | 本句capture_epoch增加，ASR和上传流停止，迟到partial/final丢弃 | 已提交输入、已有业务、当前合法文字回复 |
| stopPlayback | playback_epoch增加，TTS/播放器队列清空 | 当前合法文字回复、已提交输入和业务 |
| interruptTurn | 当前generation_epoch与playback_epoch增加，当前回答生成与朗读停止 | 已提交输入、已创建业务；新一轮需独立turn |
| endSession | session/capture/playback/generation全部失效并释放语音资源 | 已提交聊天记录与独立云端委托 |
| 后台/锁屏/来电/音频焦点中断 | 对未提交本句执行abortCapture而非finishInput；停传流，冻结auto_submit，暂停/取消朗读 | 已有可编辑预览可在本机留待用户；已提交业务按原授权继续 |

系统中断时设置 `auto_submit_suspended=true`；任何回调提交前都必须验证 foreground、session active、有效epoch与未冻结状态。不能因ASR迟到final在后台自动发出新消息。回前台后由用户明确恢复会话或提交保留的预览；不自动恢复麦克风。需要恢复朗读时从已确认段落位置新建播放epoch，不能重播未确认旧音频队列。

实时音频传输不承诺 exactly-once。网络重连使用新的 stream_id 与单调 seq；不把无法确认的旧音频自动整段重传。用户已提交文本消息用现有 Idempotency-Key 去重；未提交转写保留为本地待处理文本，不悄悄发送。

### 15.7 权限 敏感内容与保留

至少分清四项：操作系统麦克风权限、当前是否正在录音、所选 ASR/TTS 处理方及数据用途、业务动作授权。允许麦克风不等于同意把音频送到任意云服务；允许读出草稿也不等于允许用它训练模型或建立声纹。

- 真设备内路径：先验证引擎/语音包/语言，用户主动启动采集或朗读；明确状态和停止入口。下载新模型/语言包是单独设置动作，D0 不代用户执行。
- controlled_server：说明传给本产品受控服务的音频/文字类别、识别/朗读用途、部署区域与保留规则。自托管 Qwen 只改变处理方，不让“传到服务器”变成“没有外传”。
- third_party：首次启用前明确服务商、数据（麦克风音频/研究主题/选中私人草稿）、用途与保留；取得适用的具体授权。切换新处理方或扩大数据类别需重评估，不静默 failover。
- unknown locality：只允许公开/合成测试内容，私人内容不得进入；若用户选择的本地路径不可用，回退文字并说明，可另让用户选经过说明的云端路径。

VoiceTransportConsent 保存 provider_id、用途、data_categories、scope（本次会话或用户明确允许的范围）、policy_version、expires_at、revision、revoked_at，不保存密钥。它独立于业务 Grant/Approval；不能用语音服务授权批准发邮件或发布文章。

原音默认不持久化：设备和受控服务只使用有容量/时长上限的内存缓冲；每句识别结束/取消/超时即释放该句原音，连续会话不累积原音；会话结束再清剩余缓冲。不要把音频放进 analytics、错误日志、trace、浏览器持久缓存或长期对象存储。provider 无法支持相应保留政策时不标“原音不留存”，应明确其限制并阻止不兼容场景。ASR 最终文字只有用户提交或已明确开启当前连续会话自动提交后才成为普通聊天记录；临时 partial 不进入长期记忆。音频质量评测、样本留存、声音克隆和声纹都不默认开启。

TTS 只传当前请求允许的最小片段，引用中的秘密/凭据不读出、不送 TTS。私人内容朗读由用户主动触发；耳机拔出或蓝牙断开时默认暂停，避免突然从扬声器播放。音频缓存跟随成果版本、授权和删除 epoch 失效，缓存键不能只用全文裸 hash 跨用户复用。

### 15.8 错误和平台中断

| 情况 | 行为 | 不能做什么 |
|---|---|---|
| 用户拒绝/撤销麦克风 | 保留文字输入；停止采集，显示设置入口 | 循环弹权限或另开引擎绕过 |
| 无中文/本地模型未安装 | 明确不可用，可选已有可用语音或文字 | 自动下载大型模型或偷偷改云端 |
| 静音/音量零/无可用输出路由 | 字幕保留，提示检查输出，播放状态如实 | 把API成功当用户已听到 |
| 来电/音频焦点丢失 | abort未提交本句，冻结auto_submit，暂停播放，保存安全的段落位置 | 自动抢回麦克风或未经用户动作重播私人内容 |
| 进入后台/锁屏 | D0/D1及首版R1默认abort未提交本句、停传流、冻结auto_submit并暂停朗读 | 以语音名义承诺永久后台保活 |
| 断网/服务超时 | 清晰失败；保留已提交文字；未提交转写待用户处理 | 自动转另一个云提供方或重放整段录音 |
| 播放/生成失败 | 同隐私边界的本地TTS可回退，否则文字 | 跨数据边界无提示降级 |
| 用户打断但旧回包到达 | epoch判旧丢弃 | 旧音频复活、旧final发送、误报完成 |

未来若有用户明确要求的后台长音频播放，再针对 iOS 音频模式、Android 媒体会话/前台服务及发布政策做独立设计；它不改变第4节长期助理后台限制。首版语音不依赖这个范围。

### 15.9 拟议接口与数据契约

接口为逻辑契约，可由宿主本地桥接或正式服务实现；不存在已上线的真实 endpoint 承诺。

- `GET /v1/voice/capabilities`：返回本地/服务端 provider registry 与当前设备探测结果，`available/unverified/unavailable` 分开。
- `POST /v1/voice/sessions`：选 conversation_id、mode、language、asr_provider_id、tts_provider_id、consent_refs、auto_submit_final=false；返回 session_id、session_epoch、limits、有效数据路径。
- `POST /v1/voice/sessions/{id}/transcripts`：提交用户确认的 final/编辑文本，带 utterance_id、capture_epoch、expected_session_epoch、transcript_revision、edit_revision、完整 submitted_text 与 client_message_id。服务端验证本句未取消、final/编辑状态、身份与用户当前提交意图，重新计算文本hash并冻结submitted_text_ref/hash/revision；相同消息 ID 只重放同正文结果，不同正文返回409，不覆盖旧消息。partial/no_speech不能直接建立已提交记录。
- `POST /v1/voice/readouts`：artifact_id/version/hash、reading_mode、range、voice_id、provider_id、consent_revision、playback_epoch；本地路径由设备适配器执行，受控服务不接收不必要正文。
- `POST /v1/voice/sessions/{id}/interrupt`：明确 target=capture/playback/turn/session，expected_epoch；响应返回新 epoch 与实际可取消范围。

真正流式识别需经适配器支持的已鉴权传输，不把长期 token 放 URL 查询参数或日志；连接校验 origin/session，短时凭据与当前用户/会话绑定。流头声明 codec、sample_rate、channels、seq 与采集时间；服务端拒绝未授权数据路径、超长/超量和不属于当前 session 的帧。

新增模型：

- VoiceProviderCapability：kind、provider/version、language、locality、网络要求、stream input/output、取消支持、保留政策、核验状态。
- VoiceSession：会话与所属用户、mode、lifecycle、capture_state、playback_state、session_epoch、capture_epoch、playback_epoch、当前 turn/generation_epoch、auto_submit_suspended、provider/consent 引用、前台状态与时长限制。
- VoiceTransportConsent：处理方/用途/数据类别/范围/保留说明、revision、到期/撤销。
- VoiceTurn：utterance/turn ID、raw ASR transcript_revision、用户edit_revision、source capture epoch、提交状态、固定submitted_text_ref/hash/revision、绑定成果版本、输出 generation 与取消状态。只有submitted状态可携带正式消息ID和auto_submitted标志。
- VoiceStreamEvent：stream/session/turn、方向、seq、epoch、事件类型、受控 payload 引用；音频字节走有界传输缓冲，不写普通业务日志。
- VoiceControl：明确的停止/结束/中断/恢复指令、来源、reason 与期望epoch，避免一个stop布尔值隐含多个不同语义。

语音子契约单独使用 `catpaw-voice-contracts.schema.json`，避免改变已定版核心记录的身份。schema只验证形状；privacy consent、current epoch、话轮所有权、目标版本、输出路由和业务审批仍由确定性代码检查。

### 15.10 阶段验收与新增测试

**D0 宿主对齐交互原型**：完成按住说话/转写预览/连续对话状态/读全文或摘要/打断/错误回退的可辨认模拟；如运行容器存在可用已核验的本地 TTS，用非敏感演示内容验证真实开始/结束/停止/切换版本。没有实际设备输出就报告“交互可演示，真实朗读待测”，不以动效算通过。一周 D0 范围不含 GPU 部署、真实 ASR 云接入或全双工质量调优。

**D1 宿主内集成演示**：在实际目标手机验证系统TTS、麦克风权限流程、音频路由/焦点、中断和返回恢复。ASR若只做fixtures仍明确模拟；能启动麦克风不等于识别可用，更不等于已有合法云传输。

**R1 真实有限闭环**：选定并验证一个 ASR 路径和一个 TTS 路径；单次口述→可编辑文字→研究委托/私有改稿→朗读固定成果版本真实运行。连续模式先以稳定轮替为验收基线，VAD/AEC全双工另列能力项；远程路径完成授权、保留和取消测试后才开放。

关键用例：中文与中英术语、数字/人名错误纠正；partial回改；松开final与abort差异；连续两轮迟到结果；双击朗读；打断后晚到音频；朗读中改稿/删除；模型在飞撤销；无语音/噪声/旁人讲话；扬声器回声；耳机断开；来电/静音/后台；离线/重连；拒绝权限；provider跨边界回退禁止；原音/正文不出现在日志；ASR误识别“可以”不能执行外发。

质量与性能分别记录：中文 CER/术语准确率、首次转写与 final 延迟、TTS 首音频/首播放延迟、长文实时系数、打断停声时间、过期片段播放数、误触发数、每分钟计算成本与耗电。按设备/provider/版本报告，不混用厂商 benchmark。听感用用户相关中文材料盲听比较自然度、清晰度和长文稳定性；未测前不宣布“顶级”达标。安全门槛为未授权音频/正文外传 0 次、已取消话轮复活 0 次、语音绕过业务审批 0 次。


## 16 独立基础复刻与本地可运行路线

用户已明确：现有功能复刻是基础工作。没有原宿主源码不阻塞真实 UI、导航、本地数据与 fixtures 的实现。本节补充独立基础复刻 B0；它与第3节的未来宿主复用策略并行，不能把所有现有入口都推迟为“等 D1 有源码才做”。本节只定义技术方案；独立工程、原图覆盖矩阵与实际测试由相应实现任务完成。

### 16.1 路线与交付层级

推荐路径是“31张原图证据矩阵 → B0 独立基础复刻 → 在同一基础上加入长期助理和语音 → 按需要接 R1 真实服务”。D0 继续用于探索新增交互；D1 是拿到原宿主代码/桥接契约后可选的回接，不是 B0 的前置条件，也不是独立应用开展 R1 的必要条件。

B0 必须可独立启动，数据在约定本地存储中保存，已证实模块都有完整主路径。五层验收不可互相替代：

1. **界面复刻**：依据证据复现布局、层级、文案与组件，记录合理适配。
2. **导航复刻**：入口、深链、返回、关闭、切换上下文与恢复可用。
3. **本地功能**：创建/读取/修改/归档等已选主路径真实更新本地数据，重启后可见。
4. **远端动作 fixture**：可重复驱动消息流、进度、文件、错误与审批情节，始终标明模拟。
5. **真实 provider**：必须具备实际连接、授权、请求、可核对回执才能计为通过。

“导航到一个空页面”只满足很小一部分第2层，不能声称模块已复刻。“本地保存成功”不是“已保存到云端”；fixture完成不是任务真实执行完成。

### 16.2 原图证据矩阵是行为依据

每条覆盖记录至少包括 evidence_id、原图编号/文件名、可见区域、feature_id、具体观察、证据级别、目标页面/组件、动作主路径、data/provider层级、验收用例和当前实现状态。

证据分为：

- `confirmed`：图中可直接观察的文案、字段、布局、状态或交互入口。
- `inferred`：为了让独立流程闭合所作的有限推断，例如点击列表项进入详情；需注明依据，不能当原应用已证实行为。
- `unverified`：图中未见的后台效果、认证、调度保证、工具权限或数据同步语义。

本节的 id、revision、时间戳等是**拟议工程字段**；它们用于实现本地功能，不宣称原应用已有同名 API 或数据库。领域字段逐项对齐矩阵后再冻结。一个屏幕里存在的“云端”“定时”或“允许”字样，只证明可见入口/状态，不自动证明实际云执行、后台调度或服务端授权已存在。

矩阵到齐后逐条校准：删除无证据且非必要的猜测字段；把必要新字段标为独立实现选择；补齐图中确有而设计漏掉的模块/状态；把尚未看见的主路径列成待验证，不悄悄扩大“完全复刻”的承诺。

### 16.3 基础领域实体与最小本地模型

共同记录封套：`local_id`、`profile_id`、`workspace_id`、`schema_version`、`revision`、`created_at`、`updated_at`、`deleted_at`、`origin`（user_local / fixture_seed / provider_cache）、`provider_id?`、`provider_object_id?`、`evidence_refs`。本地 profile 是数据分区标识，不冒充已验证云账号。所有关联对象必须处于相同profile/workspace或经过明确的只读公共资源规则。

下表是实施所需的候选最小模型，确切可见字段及功能要按31图矩阵校准。

| 实体 | 拟议最小字段与关联 | B0 可真实本地实现 | 需要 provider 才能声称的能力 |
|---|---|---|---|
| Conversation 会话 | title、project_id?、expert_id?、environment_id、message_order、archive_state | 新建、命名、列表、打开、按本地内容搜索、草稿恢复 | 远端会话同步、真实模型回答 |
| Message 消息 | conversation_id、role、content_blocks、client_message_id、reply_to?、attachments、delivery_state、execution_reality | 编辑输入、提交本地消息、渲染消息/文件、fixture回复、重试同一模拟轮次 | 真正模型/工具输出、远端已发送/送达 |
| Project 项目 | name、description?、conversation_ids、document_ids、default_expert/skill_refs? | 项目列表/详情、选择、建立关联、相应本地创建编辑 | 云空间同步、真实共享/成员权限 |
| Expert 专家 | name、summary、local_instruction_ref?、preset_or_custom、config_revision | 列表/详情、选择用于本地会话配置；编辑范围以证据为准 | 真实专家服务、远端工具/模型行为 |
| Skill 技能 | name、summary、definition_ref?、version、scope、enabled_local | 列表/详情、作用域选择、配置保存，fixture使用记录 | 实际安装/执行第三方技能、扩大工具权限 |
| Task 任务 | title、conversation_id、environment_id、task_type、state、step_refs、result_document_ids、operation_id | 新建本地任务、详情、状态时间线、取消/重试模拟进程、关联成果 | 真正云/电脑执行、实际取消或完成证明 |
| ScheduledTask 定时任务 | title、schedule_spec、timezone、enabled、next_due_at、last_local_attempt_at、execution_mode、task_template_ref | 创建/编辑/暂停/恢复计划、计算并展示下一次时间、应用内fixture触发 | 退出应用后的持久执行、后台准点运行、推送送达 |
| Document 文档 | title、mime_type、local_blob_ref、content_hash、version、parent_version、source_kind、owner_refs | 内置演示文件、用户选择导入、阅读器、格式支持范围内编辑/版本、与会话关联 | 云文件读取/写回、真实共享、提供方版本同步 |
| Environment 环境 | display_name、kind（cloud/computer/local）、capabilities、connection_state、verified_at、provider_binding? | 云端/电脑视图切换、选择默认上下文、显示可解释模拟/未连接状态 | 电脑实际在线、云算力可用、远程文件/执行访问 |
| Permission 权限 | resource/action_scope、decision、scope_target、expires_at、revision、authority（local_preference / fixture / provider_verified） | 设置界面、保存本地偏好、演示具体审批、撤销本地允许项 | OS权限授予、账号OAuth、真实工具业务授权与安全设置 |

可见性与关系维护是功能的一部分。例如本地任务产生fixture文档后，会话附件、文件阅读器和任务结果应引用同一个 Document ID/版本；不能各页硬编码互不一致的假文案。若项目关联被移除，重返会话不应恢复已删除关联。用户切换默认环境只影响后续新任务，已创建任务绑定的environment_id不静默迁移。

新增助理的 Delegation/Run/Artifact 与上述实体通过稳定ID关联：委托可由会话创建，运行关联任务，成果版本适配文档版本。不得复制一套与基础任务/文件不互通的助理专用存储。语音也复用当前Conversation和Document，不开第二份历史。

### 16.4 本地存储与持久化

**当前默认已确定为iOS原生。** 使用SwiftUI + SwiftData与应用私有文件目录，显式禁用自动CloudKit同步，详见《Catpaw-m iOS工程实施规格》。以下IndexedDB/SQLite说明保留为已有Web原型迁移及存储替换参考，不是改回Web交付：浏览器应用用IndexedDB；需要不同原生存储驱动时可用SQLite。UI和领域层依赖同一个 LocalRepository 接口，未来换宿主存储不重写业务语义。不要在没有工程证据时要求全部重写成某个框架。

IndexedDB 的版本升级、事务和多连接阻塞需要显式处理；不能把“执行了put”当作事务已经成功提交。[W3C IndexedDB](https://www.w3.org/TR/IndexedDB/)

浏览器存储按 origin 隔离并有配额/清理规则，默认 best-effort。应使用稳定的本地开发/应用origin；不能承诺任意 file:// 打开或更换端口后仍能自动找到原数据。可解释地提供持久存储状态与导出备份；申请 persistent-storage 需遵守浏览器权限流程，申请不代表获准。[WHATWG Storage](https://storage.spec.whatwg.org/)

SQLite路径采用事务迁移及应用定义的版本编号，例如user_version；数据版本是应用负责管理的契约，不是SQLite自动替应用迁移。[SQLite PRAGMA](https://www.sqlite.org/pragma.html#pragma_user_version)、[SQLite Transactions](https://www.sqlite.org/lang_transaction.html)

LocalRepository至少提供：`get/list/query`、`create`、`update(expected_revision)`、`archive`、`remove/restore`（按实际可恢复设计）、`transaction`、`subscribeChanges`、`exportProfile`、`importPreview`。列表/详情和编辑器读取同一数据源；组件内部state只存瞬时交互，不能成为另一份权威数据。

- 消息写入、会话排序更新时间与附件关系在同一事务提交；事务成功后才显示“已保存到本机”。
- 大blob与元数据分开时，使用staged → referenced状态、hash与孤儿清理，崩溃后恢复；不能出现元数据已保存却正文缺失还显示成功。
- 每条修改带expected_revision和client_operation_id，双窗口编辑冲突要提示/合并，不能最后一次写入静默覆盖。
- 统一维护profile级change_seq，跨页/跨窗口收到变更后重新读取当前版本；系统临时缓存不是持久成功证明。
- 配额满、存储被禁用、私密浏览、磁盘写入错误时，保留可见未保存状态与导出路径，不伪报成功。

### 16.5 数据版本迁移与隔离

1. 在应用启动时读取schema_version；迁移按单调版本号执行，使用事务或带恢复点的有界迁移计划。大blob迁移不得假设能跨多个独立存储做原子操作。
2. 迁移前验证旧数据形状和关联；必要时在本地保留可恢复副本/导出。迁移失败继续只读或显示恢复入口，不能用“重置应用”悄悄清空用户数据。
3. 更新应用不能每次重灌fixtures覆盖用户数据。seed版本独立于schema版本；fixture_seed记录可重置，本地用户新建/修改记录默认保留。
4. 演示profile、用户本地profile、未来provider账号缓存采用独立namespace。fixture中的“批准”“已连接”不能进入真实账号的授权表；fixture任务永远不能被真实provider领取。
5. 切换账号/profile关闭旧订阅和流、清空内存选中项与查询缓存；深链再次校验当前分区。不能只换头像继续显示上个profile的私有文档。
6. 本地隔离不等同于抵御有设备访问权的攻击者。Web IndexedDB不是天然加密保险箱；应用不得存账号密码/API key。未来原生敏感密钥交给系统安全存储，浏览器会话凭据按服务端安全设计处理。
7. 导出包带format_version、导出时间、数据范围、完整性校验与清楚的敏感内容提示；不导出凭据/可复用授权token。导入先预览、校验引用与大小、分配/映射ID；导入的权限记录只能成为禁用的本地设置候选，绝不导入生效的云授权。
8. 正式provider接入后，由用户选择是否迁移本地内容，并明确目的地与范围；不能把B0本地数据自动上传当“升级”。既有fixture内容仍标模拟，不因换provider就变成真实历史。

### 16.6 导航 深链与上下文一致性

使用集中路由表和类型化Route对象。拟议路由可采用 conversations/{id}、projects/{id}、experts/{id}、skills/{id}、tasks/{id}、schedules/{id}、documents/{id}?version=n、environments、permissions；这是独立实现建议，不是已核验的原宿主URL。

页面、半屏表单和阅读器都由可追踪的导航状态打开：包含origin_route、selected_profile、return_target与资源ID。返回关闭后回到真实来源位置，保留必要滚动/选中上下文，不把所有Close都硬跳首页。深链到不存在、已删除、其他profile或未知版本的对象时显示安全解释与返回路径，不能展示另一个同名对象。

入口和详情共享统一action command；从首页、项目页、侧栏进入同一任务得到同一状态。重复点击新建/保存不能生成两份对象。刷新/重启恢复允许的路由和草稿，但不自动重放发送、模拟执行或批准动作；权限表单恢复时仍需读取当前版本。

### 16.7 统一 Provider 协议

Provider是可替换的数据/执行来源，不把真实后端能力散落在按钮回调里。推荐分成LocalProvider、FixtureProvider、HostProvider、RemoteProvider，并通过同一受控registry选择；模式由可信配置和明确用户选择确定，不能由模型/网页或导入数据自行切换。

共同能力：

- `describeCapabilities()`：按功能返回 `local_available / fixture_available / remote_verified / unavailable / unverified`，注明协议版本、作用范围、授权前置与错误语义。
- `query(entity, filter, cursor)` 与受限领域command：查询资源、创建/修改本地对象，校验profile和revision；不能开放任意数据库/文件路径操作。
- `submitMessage`、`startTask`、`cancelTask`、`configureSchedule`、`readDocumentVersion`：操作ID稳定，返回状态与来源，流回调有seq和epoch，取消后迟到结果按已有规则处理。
- `observeOperation`：FixtureProvider返回可重复情节进度；真实provider需要实际请求ID/回执。真实执行成功标准继续遵守第7–8节。
- `disconnect/resetFixture`：只影响指定数据域；不能用同一个按钮默默注销真实账号或删用户文档。

请求上下文包含profile/workspace、mode、provider_id/version、environment_id、operation_id、expected_revision和必要授权引用。响应必须带`data_origin`、`execution_reality`、`receipt?`、`current_revision`、`error?`。

`execution_reality`建议枚举：`local_effect`、`simulated`、`remote_accepted`、`remote_verified`、`unknown`。它不是装饰性角标：路由、消息、任务、文档、通知、日志和导出都保留该值，不能在中途剥掉模拟标记。LocalProvider保存一条消息是local_effect；FixtureProvider返回AI回复是simulated；只有真实适配器回执才可用remote_accepted/verified。

UI可立即实现的功能不应因为RemoteProvider缺失一律禁用。例如创建项目、保存定时规则、编辑私有草稿都能本地完成。仅真正依赖后台的动作（真实模型调用、连接电脑、提交远程任务、持久云定时、外发）在无能力时提供清楚的说明或用户明确选定的fixture演示；不能悄悄模拟后显示“已在云端完成”。

权限采取同一原则：本地偏好只控制本地产品行为；OS提示、OAuth scope、provider Grant与具体ActionEnvelope仍是各自权威域。B0权限页不能靠改localStorage把真实动作放行。未知provider描述与工具结果仍按不可信数据处理。

### 16.8 定时任务的独立可用边界

B0可真实保存schedule/timezone、计算下一次时间、暂停/恢复、显示历史，并在应用活跃时以本地调度器驱动明确标记的fixture。它已经是可用的本地配置和演示功能，不是空导航。

但浏览器计时器/移动进程不能保证关闭或休眠后执行。本地schedule显示execution_mode=local_session_only或fixture，并说明“仅应用运行且获得执行机会时模拟检查”；退出期间不编造运行历史。恢复后如需要演示错过触发，只能合并为一次明确的本地补演示，不能伪造此前已经完成的时间戳。

接入真实云scheduler后，新增provider_verified绑定与服务端next_due_at/receipt，才可升级展示为持久任务。旧本地计划不会自动上云或产生新的持续授权；需用户明确启用真实运行的范围、来源和频率。

### 16.9 B0 验收与后续接入

每个已证实基础模块至少通过一条“入口 → 列表/空态 → 创建/选择 → 详情 → 修改/关联 → 返回 → 重启恢复”的适用主路径；原图未显示创建或编辑时，不能把补充能力描述成原功能，但可作为明确的独立实现补全。

共同必测：

- 会话、任务和文档跨页一致；同一版本正文一致。
- 项目/专家/技能选择在对应上下文真实生效；不只改按钮文字。
- 用户数据重启保留，fixtures重置不覆盖用户修改；迁移失败不丢数据。
- 双窗口冲突、重复点击、深链刷新、返回关闭、对象删除后旧路由都有正确结果。
- 模拟/本地/真实provider标记贯穿详情、结果、导出；缺后台时不出现虚假的远端成功。
- 本地定时规则真实可编辑持久化，关闭期间无伪造运行。
- profile隔离、导入安全、存储满、权限撤销及provider切换不越界。
- 语音与新增助理复用基础会话/文档/任务，不产生两套互相矛盾的历史。

D1取得原宿主桥接后只替换存储/路由/服务适配器并校准差异；B0已完成的页面、领域命令和本地用例应尽量保留。R1也可以从B0独立应用连接新的受控真实服务，不强制等D1。真实provider的鉴权、授权、回执、删除与后台验收仍不能由B0通过代替。

本节不把“独立基础复刻完成”预先作为事实；完成范围必须回到实际31图覆盖矩阵、运行结果和测试报告。它明确的是可立即推进的工程路线与真实性边界。下一步执行依据为配套 `catpaw-ios-implementation-plan.md` 与 `catpaw-ios-contracts.swift`：产品M0–M6里程碑、技术WP0–WP7工作包、Swift模型/provider/语音契约与20条iOS验收。契约文件未在当前无Swift编译器环境typecheck，实际Xcode验证由实施任务完成；计划不能替代编码。


## 附录 资料口径

官方文档核验日为 2026-10-10。文内“建议/默认/目标”为本方案设计判断；“官方说明”由对应链接支持。来源的 SDK、版本和平台限制上线前再次复核。具体产品首演和文案由产品规格与真实原型共同收敛，本技术方案不把示例替代用户决定。

## 附录 核心结构契约

配套 `catpaw-core-contracts.schema.json` 是拟议服务端记录的 JSON Schema Draft 2020-12，覆盖委托、运行、事件、记忆、防自动重建记录、授权、动作快照、审批、回执、成果版本、阅读回执与用户级触达政策。`catpaw-core-contracts.examples.json` 提供合成示例，hash 为格式占位，不是实际签名或授权。它们不是宿主已实现 API，也不能替代服务端业务校验。

需额外以事务/代码保证的跨记录不变量包括：tenant/owner 从 session 推导；状态迁移合法；source_user_message 为真实用户来源；digest 从固定参数重算；审批与当前 grant/artifact 版本相等；有效期与撤销 epoch；dispatch_commit 与 revoke 的序列；operation_id 唯一副作用；source suppression 和删除传播。Schema 无法单独证明这些性质。
