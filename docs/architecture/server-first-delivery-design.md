# 小咪：服务端优先的整体架构与交付闸门

日期：2026-10-11。性质：拟实施架构与独立验收计划；不是代码完成、部署完成或真机端到端通过证明。

## 1. 架构裁决与最短关键路径

- 最小云形态：一个 API 进程、一个任务 worker、一个 Postgres。可部署在同一计算实例，进程职责分离。PG 同时存业务数据、持久工作队列、事件日志和通知 outbox；先不加 Redis、独立向量库、复杂编排器。
- iOS 是自然对话入口、命令发起方、事件投影和审批界面。任务执行、记忆检索、目标推进在服务器；手机锁屏、退出、断网不影响已被服务器持久接受的工作。
- conversation-first：一条用户消息可以产生回复、task 卡、approval 卡、artifact 链接，全部绑定原 conversation。独立任务列表是投影，不能形成第二套任务状态。
- 单权威：Postgres 提交后的领域状态是权威；API 内存、OpenMuse worker 对象、file-store、iOS 缓存、SSE 流、推送都不是并列真相来源。模型不能直接写 completed/approved 等权威状态。
- 最短关键路径：冻结消息/任务/事件合同 → M1 真实前台闭环 → M2 PG 持久化、租约恢复、回放、记忆 → 经授权部署并验证手机离线云执行 → M3 主动触发与通知。
- 后端与记忆可立即并行。OpenRouter key 未配只阻塞真实 provider 验收；不能因此停止合成合同、持久性、故障注入、安全边界和打包工作。

## 2. 当前基线：M0，只承认已知证据

来自项目协调上下文，尚未独立读取仓库或复跑：

- SwiftUI iOS 17 客户端已装至 iOS 26.5.2 测试机；用户反馈像散装 demo，正在改 conversation-first。
- 固定复用 OpenMuseTaskWorker、file-store facade r2 的 scope/epoch/version hash/unknown 不重发已有本地测试。
- 后端 owner 正在做 provider-ready chat transport、历史 context、受控 delegate_task/agent_status 和真实 model handler；前端 owner 正在做自然对话主屏与任务卡。
- 未证实完整 OpenMuse、Intelligence、真实模型请求、云部署、SQL 或多实例安全。
- facade r2 是现有版本称谓；不要把它误写为已经接入某厂商的 R2 对象存储。

M0→M1 不可偷换：编译成功 ≠ 真机交互通过；mock 回复 ≠ 真模型；adapter 存在 ≠ runtime 全部集成；本地重启 ≠ 云端独立运行；有租约字段 ≠ 双 worker 安全。

## 3. 组件与数据边界

### API

认证与 scope 解析、输入验证、命令幂等、conversation/message 读写、任务和审批命令、snapshot、SSE/增量 polling、artifact 授权下载。只在事务提交成功后回复 accepted。不得在 HTTP 连接生命周期内托管长期任务。

### Worker

从 PG 领取任务，构造上下文，调用模型和允许的工具，记录步骤与结果；按授权边界暂停；通过领域服务提交状态和事件。OpenMuse 是执行 adapter，不能自建一套用户/任务/审批数据库。第一版限制并发和工具集合，禁止任意 shell、任意网络目标和无限递归委派。

### Postgres 逻辑实体

- scopes、users、devices、sessions：单用户也保留真实 scope 和服务端验证的 principal。
- conversations、messages、turns：消息顺序、角色、内容版本、client_message_id、关联 task、生成状态。
- goals：用户明确目标、来源、状态；与任务一对多；普通闲聊不自动变长期目标。
- tasks、task_attempts、task_steps：生命周期、当前 attempt、checkpoint、lease/fencing、幂等 action key、取消请求。
- approvals：动作目标与参数摘要/hash、有效期、scope、请求来源、决定和 consumed_at。审批不能仅是一句模型生成的“用户同意”。
- artifacts：scope、task、存储定位、媒体类型、长度、hash、可见性和保留策略。小型文本产物可先入 PG；大文件经 ArtifactStore 接口，独立持久卷或对象存储另选。
- memory_records/memory_versions 或记忆 owner 定义的等价结构：来源、修订与删除边界必须保留。
- jobs、events、notification_outbox、idempotency_records、tool_receipts、audit_log。

所有资源查找按 scope 限定，包括 join、嵌套 artifact、事件 cursor、审批与工具回执。需要跨实体外键时约束同 scope，不能只靠 UI 隐藏。共享表数据库角色采用最小权限；初期可应用层强制 scope＋负向测试，后续 RLS 是防御层，不是替代验证。

## 4. 任务生命周期、租约与未知副作用

建议状态：queued → running → waiting_approval / waiting_input / retry_wait → queued；终态 succeeded / failed / cancelled。恢复不回写历史终态；重试创建新 attempt。取消请求先写 cancel_requested_at，worker 在安全点确认后才置 cancelled。

- 入队：message/turn/task/job/event 在一个事务中创建，幂等键重复且同 payload 返回原对象；同键不同 payload 返回 conflict。
- 领取：短事务使用行锁领取到期 job，写 lease_owner、lease_until、单调递增 fencing_token、attempt_id 后提交。模型请求期间不持有事务或数据库锁。
- 心跳：用数据库时间续租；所有 checkpoint、状态提交及 outbox 写入必须校验当前 fencing token。租约过期的旧 worker 即使回来了也不能提交结果。
- 恢复：扫描过期租约，检查最新 checkpoint 与 tool receipt；只自动重试明确幂等或已证实未发生的动作。不能用“超时”推导“对方未执行”。
- 外部动作：执行前持久化 intent/action key；完成后保存 provider receipt。若请求可能已到达但结果丢失，进入 outcome_unknown 阻塞原因，查询回执或请求决定，禁止盲目重发。fencing 只能阻止旧 worker 写库，不能撤销已经发往第三方的动作。
- 等审批/输入时释放租约，不占 worker；有效审批产生新 job。审批绑定 action version/hash 与 attempt 边界，参数变化、过期、已消费时不得复用。
- 重试分类：限流与临时连接失败允许有上限、带 jitter/backoff 的重试；缺 key、无权限、协议不兼容和预算耗尽进入明确阻塞；没有无限循环。
- task succeeded 的最低条件：所需步骤完成且结果/产物已持久化，状态及事件原子提交。流结束或模型说“完成”不足以满足。

单 worker 是部署规模选择，不是可以省略竞争防护的理由。测试必须启动两个竞争 worker，并证明同一 job 不会被并行有效提交。

## 5. 对话命令与 realtime 合同（v1建议，需 owner 对齐）

### 命令/读取

- POST /v1/conversations：创建会话；客户端传 client_request_id，scope 从认证取得。
- POST /v1/conversations/{id}/messages：client_message_id、content、attachment_refs、可选 expected_conversation_version；返回已提交的 message_id、turn_id、event_cursor、generation_status。
- GET /v1/conversations/{id}/snapshot：会话消息分页、活动任务/审批、conversation_version、snapshot_cursor。
- GET /v1/events?after={opaque_cursor}&amp;limit={n}：同 scope 增量事件、next_cursor、has_more；与 SSE 使用同一持久事件源。
- GET /v1/events/stream：SSE，支持 Last-Event-ID。iOS URLSession 发 Authorization header；token 不放 query string。
- GET /v1/tasks/{id}：完整权威任务投影；POST /v1/tasks/{id}/cancel：幂等取消命令。
- POST /v1/approvals/{id}/decision：decision、expected_action_hash、client_request_id；由服务端检查 scope、有效期和不可变动作版本。
- GET /v1/artifacts/{id}/content：鉴权下载或经授权生成的短期 URL；不可公开裸露文件路径。

所有名称是建议接口，不宣称仓库已经实现。返回错误应有 stable code、retryable、request_id，不能用 HTTP 200 + 模型文本掩盖失败。

### 事件信封

schema_version、event_id、scope_cursor、conversation_id、aggregate_type/id/version、type、occurred_at、causation_id、payload。scope 由服务端解析，客户端不能跨 scope 订阅。

持久事件示例：message.accepted、message.completed、message.failed、task.created、task.state_changed、task.progress、approval.requested、approval.decided、artifact.available、memory.changed、goal.changed。

- 领域更新＋event 插入同事务；NOTIFY（若采用）只作唤醒提示，丢失通知不丢数据。
- 每 scope 的 cursor 必须符合提交顺序。不能把普通全局 BIGSERIAL 的分配顺序误当提交顺序，导致客户端越过晚提交事件。首版可锁 scope stream head 并在领域事务分配顺序；snapshot 与 watermark 在一致读视图内产生。
- SSE 至少一次投递，客户端按 event_id 去重；aggregate_version 落后丢弃、跳跃时重取该资源或 snapshot。
- 断线从最后已应用 cursor 回放；cursor 超出保留窗口返回 reset_required，先获取原子 snapshot 再续流。事件保留不得短于约定离线窗口；删除/清理需要保留必要 tombstone。
- token delta 是临时展示，使用独立 turn_id＋chunk_seq，不能冒充持久业务 cursor；最终 message.completed 替换临时文本。断线允许丢 token 动画，不能丢最终消息或任务状态。
- 心跳不推进业务 cursor。网络连接断开不取消 server task。轮询和 SSE 不能各维护一份状态。

### 单权威 UI 规则

客户端可以显示 optimistic“发送中”，收到持久 acceptance 后才显示“已提交”；没收到结果时按 client_message_id 查询/重试，不能新造消息 ID。任务卡只能由服务端状态投影驱动。模型先说“正在处理”不等于已建 task。审批卡状态必须经服务器确认，不靠本地按钮立即进入 running。

## 6. 记忆接口与依赖（不替代记忆 owner 细案）

后端依赖最小接口：

- MemoryRead(scope, query, purpose, context_budget, as_of_version) → 有来源的条目/摘要、used_versions、被排除原因。
- MemoryPropose(scope, source_message_ids, candidate_changes, idempotency_key) → 待处理变更；模型输出仅候选，不能直接覆盖权威记忆。
- MemoryApply(scope, expected_version, authorized_change) → 新版本及 memory.changed 事件。
- MemoryForget(scope, record_ids, expected_version) → tombstone/version；后续上下文构造不得再次召回旧值。

关键依赖：先有稳定 scope/message/task ID 与来源引用，再接记忆写入；context builder 合并最近对话、相关任务、目标和有预算的记忆，记载来源版本。任务状态不能藏在自然语言记忆里。禁止将推断、工具外部文本直接提升为用户指令。首版只需结构化 PG 查询/简单全文检索；先用质量与删除测试证明可用，再考虑 embeddings。若添加第三方 embedding，会新增资料外发与成本边界。

并行约定：记忆 owner 负责抽取/冲突/遗忘/保留策略与质量样例；后端 owner 负责事务、scope、服务接口、context 注入和事件；iOS 负责可见更正入口与结果展示。版本冲突返回明确信号，不能静默 last-write-wins。

## 7. 鉴权、provider 和权限底线

- 单用户起步不等于无鉴权。首版可设计一次性配对＋可撤销设备 session；实现先用合成测试 token，真实长期凭据的创建/配置单独走授权与安全输入。手机 Keychain 保存 app session，不存 provider key。
- 所有公网 API 必须 TLS、鉴权、scope 校验、请求大小限制、速率限制和基本滥用防护。健康检查不泄露密钥或内部配置。数据库不暴露公网。
- 模型 key 只在服务器受控 secret/env 注入。不得写进 repo、iOS bundle、截图、日志、共享文件或计划。开发与生产凭据隔离，可撤销、可轮换。
- OpenRouter free 是用户选择的方向，不是稳定可用性或永久零成本保证。真实调用前核对模型 ID、当前额度、路由/隐私条款；禁用静默付费 fallback，设置硬请求/token/预算上限。无 key 返回 provider_not_configured，不能伪装真实成功。
- 合成测试不包含用户邮件、联系人或真实历史；获准后外发也最小化 context。provider tool-call 内容只进入校验器，工具名、参数、scope 和授权均须独立验证。
- 日志记录 request_id、task_id、attempt、provider/model、耗时、错误码和用量，不默认记录正文/key。审计日志不应成为无保留期限的私密数据副本。

## 8. 手机离线、通知与签名限制

- 真正保证：服务器已 accepted 的任务可以在手机离线时继续；最终事件持久保存，手机恢复联网/前台后通过 cursor 补齐。手机离线且未提交的消息只是本地待发送，不能宣称云端已经启动。
- M2 默认 SSE 前台更新＋有退避的前台 polling＋回前台强制 catch-up；不承诺 iOS 后台定时轮询持续运行。
- M3 APNs 只是“有新结果”的提示，notification outbox 从已提交事件派生，去重、重试和 token 失效清理；推送失败不得回滚任务成功。APNs 接受不等于设备展示/用户已读。
- 免费 Personal Team 不能作为可交付 APNs 的前提；先核对实际 team、signed provisioning profile 和 aps-environment entitlement，再决定能否测试。未具备条件时保留 poll/catch-up 路径，不为做推送擅自购买会员或创建密钥。
- Apple 当前官方页面明确 Personal Team 的 provisioning profile 7 天到期，须重新构建安装；这是持续真机测试的实际限制，并非后端故障。[Apple 账号说明](https://developer.apple.com/help/account/basics/about-your-developer-account)
- 推送 capability 随会员类型变化；上线前以当前签名能力实测。[Apple capability 列表](https://developer.apple.com/help/account/reference/supported-capabilities-ios)
- Apple 明确不保证 background notification 投递，因此 silent push 不可充当可靠任务调度器。[Apple background updates](https://developer.apple.com/documentation/usernotifications/pushing-background-updates-to-your-app)

## 9. 里程碑与最低验收证据

### M0：可重现基线（当前）

交付：锁定 commit、依赖和运行方式；列清真实/合成 adapter；现有单测清单及输出。证据：精确 commit、执行命令/环境/日期、通过与未跑项目。当前上下文只足以说明局部成果，不能签署整个 M0 完成。

### M1：真实前台闭环

交付：在同一自然对话中发消息 → 真模型使用历史 context → 明确需要执行时真实建立 task → progress/approval/result 在原对话呈现。任务必须来自服务端工具/状态结果，不能仅靠前端关键词或预置脚本。

最低证据：
1. 真机录屏＋同一次 interaction 的 request/turn/task ID；受控合成内容和明确标注的真实 provider/model。
2. 第二轮能引用第一轮已知信息；能区分聊天与 delegate_task；agent_status 返回同一权威 task。
3. 缺 key、provider 失败、重复发送、取消、拒绝审批都呈现正确可恢复状态，不假成功。
4. 真 key 未配置时可以交“provider-ready 合同测试通过”，M1真实部分仍为 BLOCKED，不能写完成。

### M2：单实例云持久执行＋记忆

M2a（可自主开发/本地验证）：PG migrations/repository/queue/event log、租约与fencing、memory接口、auth合同、容器化与runbook。
M2b（需部署授权）：运行在手机/开发电脑之外的服务器，用真实地址完成验证；不可把本地 M2a 写作 M2b。

最低证据：
1. 手机收到 acceptance 后断网/杀 app；worker完成；手机重连恢复原对话、任务和产物，无丢失/重复。
2. API/worker 在领取后、模型返回后、提交前后分别被杀并重启；有恢复证据；旧 lease 不能覆盖新结果。
3. 两个 worker 竞争同 job；同键重复命令；迟到事件；snapshot/stream交界；cursor过期均通过。
4. 模拟外部副作用成功但回执丢失，进入 outcome_unknown 且不自动重发。
5. A/B scope 越权负向测试覆盖消息、任务、审批、事件、artifact、memory。
6. 记忆可跨新会话召回合成事实，有来源；更正与遗忘生效；与任务状态不冲突。
7. PG备份恢复到空数据库，恢复后有效状态/事件/产物引用可校验；migration、rollback策略、健康检查和日志已验证。
8. 部署版本、真实主机独立运行、TLS/auth和用量限制证据齐全；没有部署授权则 M2b明确保持 BLOCKED。

### M3：主动 trigger＋通知

交付：持久 trigger（明确用户目标/授权、due_at、timezone、dedupe key、quiet hours、预算和停止条件）；scheduler只创建job，沿用同一执行/审批机制。通知消费已提交事件，不能自行推进任务。

最低证据：重启后到期触发、重复tick只建一个task、取消/暂停后不再执行、跨时区/夏令时测试、通知拒绝/失效token/重复投递、不含私密内容的push、点击后正确catch-up。具备资格后增加真实APNs真机证据；否则只完成通知adapter和降级验收，真实push标阻塞。

## 10. 执行顺序与可并行角色

1. 合同owner/后端owner冻结 ID、scope、message/turn/task/approval 状态机和事件v1。前端与记忆owner对字段快速确认，避免三方分别造类型。
2. 并行A：后端完成真实provider transport/context/tool校验与M1；并行B：iOS对话主屏/任务卡/审批/失败恢复；并行C：记忆owner落实接口、来源/版本/更正遗忘；并行D：持久化owner做PG migration、job租约、event replay与故障测试。
3. 合同固定后整合M1，不等云账号；合成全套跑完，key可用才跑真实合成内容 smoke。
4. 后端整合M2a；QA以failure matrix独立验证，不能由“owner说能跑”代替证据。
5. 打包镜像、迁移命令、配置schema、无密钥env示例、备份恢复runbook、部署/回滚runbook；向用户集中申请必要的最小部署权限。
6. 获批后才执行M2b；完成云端离线闭环后再扩大到M3，不能优先靠通知给未完成后端做产品效果。

若同一owner容量有限，优先顺序：合同 → M1 → 持久事务与队列 → 恢复/回放 → 记忆集成 → 部署验证 → 主动触发/推送。没有依据不承诺具体日期。

## 11. 部署路线及授权闸门

供应商解耦：一份API/worker镜像（不同entrypoint）、PG migration、容器编排示例、health/readiness、持久卷说明、备份/恢复和回滚说明。云厂商、区域、域名和公网策略未选定，本文不编地址、账号或免费额度。

现有授权可继续：设计、现有授权环境内开发、合成调试、单元/集成/故障注入测试、依赖现有免费能力的本地工件构建、密钥扫描、runbook；不得把实现登录代码等同于创建真实授权grant。

需要用户明确决策/授权：
- 选定云账号/平台/区域/数据保存地，创建新账号或资源，公开服务入口或改变网络/安全权限。
- 任何付费、信用卡绑定、订阅、超出明确上限的资源，或“免费”试用可能转付费的承诺。
- 新协议接受：展示相关协议和具体动作；不擅自同意。
- 创建/配置 provider、APNs、部署等长期密钥或OAuth权限，采用安全输入，不在聊天收集密钥。
- 从合成数据改为用户真实对话/记忆/文件送往明确 provider；必须解释数据类别、接收方和目的。
- Apple付费会员、分发发布、真实推送权限、用户数据库迁移/不可恢复删除。

部署申请一次打包说明：平台/区域/用途/入口受众、实例与数据库资源、总预算币种/周期、数据类别及接收方、协议链接、secret配置方式、回滚与删除策略。未批准前只交可部署工件，不进行“先上线再说”。

## 12. 主要风险与独立审查清单

- 产品错觉：UI串起来但服务端依旧mock。要求同一trace串联真机→API→provider→task→持久结果。
- 状态分叉：OpenMuse内部状态、facade和iOS各自完成任务。所有持久转移必须汇入领域服务与PG事务。
- 重复外部动作：超时后重跑。必须tool receipt/幂等键/unknown人工处理，不承诺通用exactly-once。
- 记忆污染：模型幻觉或第三方指令写入长期偏好。来源、版本、候选/确认区分、遗忘测试优先。
- “免费”不稳定：模型可用性、限流、账户权益变化。provider能力探测、硬限额和诚实阻塞；不静默付费回退。
- 基础设施休眠/临时磁盘：选型时必须核对常驻worker、持久盘、PG备份；未核实不称24小时云执行。
- 运维盲点：只有活性检查没有队列积压、租约超时、未知结果和预算报警。M2最少记录这些指标，先不引入复杂监控平台。
- 通知误导：silent push不可靠，免费签名可能不具备APNs能力；poll/恢复前台不是后台通知。

验收报告每项必须标 PASS / FAIL / BLOCKED / NOT RUN，附 commit、命令、环境、证据与未覆盖边界。计划、schema和测试数都不是端到端体验的替代物。
