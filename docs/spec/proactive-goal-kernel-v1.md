# 主动目标领域内核 v1：规格与源码 gap 矩阵

本规格定义下一版本的小批领域内核，目标是减少用户发现问题、再次交代任务和记住跟进的负担。它不替代冻结修复版的对话流畅、后台恢复、侧栏、图片/API P0 验收，也不声明主动助理已可用。当前进度只维护在[主计划](../status/master-plan.md)；本批验证范围见[验收记录](../acceptance/proactive-goal-kernel.md)。

## 来源与审查方法

云端从已发布 `integration/local-fixed-directory` 的 `c1e23c287dd0e1da36067dfea2f1712555f56d0d`（622 文件）建立独立 `feat/proactive-goal-kernel`。初始化 checkout 原为无提交 `work`，没有沿用假定的 main。随后只读核实远端 main 已到 `78d9002fb57706f8663d3812f146d60e61b75897`：相对基线仅增加分支规范并修改 README/CONTRIBUTING。按后续明确指令保留原分支与 WIP；未重置、合并、推送。已读取该提交的 `docs/development/branch-management.md`。基线只有根 `AGENTS.md`，没有 `.agents/skills`；没有导入本机 `docs/proactive-assistant-review` 或未发布候选。

审查阅读了根 README、docs 索引、主计划、整合来源/验收，并追踪真实入口、授权、Store 和 worker。以下路径均相对 `services/edge/supabase/functions/_shared/`，行号用函数定位代替，避免本批增量造成错位：

| 需求 | 基线源码证据 | 已有能力/缺口 | 本批增量与剩余边界 |
|---|---|---|---|
| 目标及完成条件 | `core/integration/server-foundation/src/foundation.mjs:createGoal/linkExecution` | 已有 `goals`、revision 和执行 binding；目标只有 title/description，没有现实完成判据 | 原位增加 subject 归属及 `proactive` 契约；不建另一张 Goal 表。旧无 subject Goal 拒绝自动接管，所有权迁移未实现 |
| 自然形成/主动发现 | `core/src/tools.mjs` 的 delegate_task、save_artifact、finish_task | 由对话触发本地报告；无事件发现、语义影响分析 | 接收具类型合成事件、保存证据绑定 Proposal；自动发现/自然语言抽取/规划器未实现 |
| 完成权威 | `core/src/local-output-facade.mjs:assertTaskCompletion`、`report-completion.mjs` | 校验本地报告成果；不能证明现实目标达成 | Goal 完成另有独立证据；不改原报告成果完成契约 |
| 授权/撤销 | `authority.mjs:assertSourceAuthority`、`consent.mjs:assertConsent`、`api.mjs` 的 admittedTask 包装 | 当前 session/scope/model consent 和 delegation grant；模型 consent 不是购买/发信权限 | 注入现有 authorize/admitTask 端口；确切 Action 摘要的直接用户 Decision 才授权该动作。生产授权接线/长期目标授权未实现 |
| CAS 与 fencing | `facade-r2/src/fenced-worker-store.mjs`、`integration/edge-adapter/src/bounded-store.mjs` | 已有 task lease、grant/hash 检查、事务内 CAS | 扩展 scoped Repository CAS；消费原 task/lease/binding，不另建 lease、queue 或 worker |
| Proposal/Decision | `facade-r2/src/facade.mjs:proposePreview/decide` | 原 `actions` 和 `catpaw-approval-bindings` 已绑定成果版本；本地输出入口关闭 preview | 新 `catpaw.goal.synthetic` kind 原位扩展 Action，审批加 goal version；不添加平行 proposal/approval 表，不改变冻结 preview |
| 未知效果 | `core/src/model-handler.mjs`、bounded store 的 dispatched/unknown；facade preview reconcile | 模型派发不盲重放，preview 仅合成局部账本查询 | Action 在效果前持久 executing；unknown 只 lookup reconcile。同意、重启、新 goal version 均不能绕过未知效果 |
| 持续执行/预算 | `worker-kick.mjs:kickTurnTasks`、`bounded-tick.mjs` | 有界推进，非独立持续调度；原实现保留 finalization reserve | 本批只手动调用领域方法/Store CAS，不调用 tick/start；control 由既有 worker 注入，不新增运行时长数值 |
| 通知/outbox | `bounded-store.mjs:acknowledge` 的 onCommit hook；product spec R2 候选 | 存在事务 hook；此 checkout 无完整 notification outbox 实现 | 在原 `public.records` Store 增加 outbox/inbox kind，事务原子发布 refs，去重与静默期抑制；HTTP/App/APNs/远端通知未接入 |
| 删除/恢复 | `core/src/purge-plan.mjs` | 有 plan，无完整可执行 purge/backup 屏障 | 第二小批新增逻辑删除与原 Record Store tombstone；保留最新 tombstone 时拒绝旧 Goal/批准恢复。未实现物理清除或独立备份恢复屏障；整库回滚已复现重放风险，仍阻断生产接线 |

## 版本化领域契约

契约名称 `catpaw.proactive-goal`，版本 `schema_version: 1`。公开领域命令拒绝未知版本和未声明字段；持久内部 event/decision 版本放在既有 `events.refs`，Goal 放在 `proactive.schema_version`，Action 的 Proposal 放在 `data.schema_version`，Outcome 本身带版本。所有新事件、Action data、outbox 和 adapter receipt 明确 `synthetic: true`。

| 概念 | 保存位置与权威 | 必要语义 |
|---|---|---|
| Goal | 原 `catpaw.goals` 行，`revision` 是唯一 goal_version | 同一 scope/subject，`active/paused/revoked/completed`，completion、event_heads、quiet_until。首次确认不授予任何副作用权限 |
| Event | 原不可变 `catpaw.events` | scope 的提交 sequence 是游标；source key+trust+revision 是去重/修订键，类型/载荷摘要用 SHA256 绑定 |
| Decision | 原不可变 Event `goal_action_decided`，既有 approval binding 引用 | 来自已认证的直接用户命令，approve/deny，确切 actor、goal version、action digest；第三方文字不能进入权限链 |
| Proposal | 原 `public.records(kind=actions)` 的 data，初始 awaiting_review | 有当前证据 ID、摘要、候选操作/参数、goal version、subject/scope；不是新执行者，不自动执行 |
| Action | 同一原 Action 行＋`catpaw-approval-bindings` | 用户批准后进入新增 approved，随后 executing、succeeded/outcome_unknown/failed；另有 denied/expired。该 kind 不交给冻结 preview ActionService |
| Outcome | Action.outcome＋原不可变 outcome/reconciled Event | `confirmed/not_applied/unknown`，effect key 与 synthetic 版本；动作 succeeded 只表示该合成效果得到回执，不等于最终 Goal 完成 |

Goal completion v1 的两个类型：

```json
{"schema_version":1,"kind":"actual_arrival","location":"合成会场","deadline":"2026-10-12T16:00:00Z"}
{"schema_version":1,"kind":"delivery_confirmed","report_key":"synthetic-weekly-report"}
```

Event 命令形状为 `{schema_version, source_key, revision, type, payload}`。v1 支持 `arrival_estimate(location,at)`、`actual_arrival(location,at)`、`report_generated(report_key,artifact_hash)`、`delivery_confirmed(report_key,receipt_id)` 和仅直接用户可提交的 `user_completed(statement)`。trust 由受信入口指定，不从第三方 payload 读取。当前 external ingress 只开放 synthetic adapter 方法；真实 source provenance 验证未实现。

Proposal 命令显式给出 `{schema_version, proposal_id, goal_version, task_id, lease_id, evidence_ids, operation, arguments, summary, expires_at}`。只允许 synthetic `choose_travel_plan/purchase/send_report`；opaque arguments 和 summary 只作为数据，不解释为权限。Action digest 绑定完整 Proposal data、task ID 和有效期。Decision 命令为 `{schema_version, goal_version, action_digest, decision}`；审批与派发分开，批准不是调用 adapter。

## 原子性与停止规则

1. Foundation 负责 scope identity/事务，新增 Goal subject 归属防止同 scope 的另一用户接管。所有 kernel 事务开始与提交前都调用 fresh authorize；任务检查消费既有 admitTask（包括已接线 consent），不得用模型/body 声称的 principal 或 permission 替代。
2. 同一 source/trust/revision 的同摘要事件重放返回原事件，无新增 Goal revision、通知或效果。相同键的不同摘要返回 `event_revision_conflict`。来源修订可以有空洞；采用最大 revision，迟到低 revision 返回 out_of_order，不倒退 head。不用发生时间或入库时间猜修订顺序。
3. 新观察或用户修改均对 Goal revision 做 CAS。旧建议/审批进入 expired；既有 Decision 历史保留但不再授权。提案证据必须是该 Goal 当前 source head；被更正的旧证据拒绝使用。并发 CAS 只有一个胜者。
4. 派发前检查 Goal active、goal version、证据、摘要/有效期、用户批准 binding、当前 session/scope/consent、原 execution binding/run hash/subject、task running、捕获 lease ID/到期时间和 worker control。写 executing 后再检查；adapter 在同步合成效果前再次调用 beforeEffect。提交前的最后授权 await 后还要复查 worker fence，不能耗尽 reserve 后发布成功。
5. 持久 executing 是可能已派发的保守标记。异常、确认丢失、派发后失租/撤销均保留 unknown，不撤回已发生效果、不改成普通可重试失败。snapshot restore 后先 reconcile；即使换 proposal ID、更新 Goal version，相同 effect key 也不能绕过 executing/unknown。
6. effect key 绑定 scope、Goal、operation、arguments，故跨 Goal version 相同意图仍受保护。confirmed lookup 可结算效果；缺少效果记录仅得 unknown。只有受信的 not_applied 证据才能转 failed，随后须新 Proposal 和新批准；旧动作永不自动重放。此 key 不是完整真实语义幂等协议，改参数是否相同真实意图尚需 adapter 契约。
7. 暂停/撤销/完成使待批/已批动作失效，清掉绑定任务的活动 lease 并将其 paused/cancelled；原 succeeded/failed/cancelled/outcome_unknown 保留。暂停后恢复只恢复 Goal 状态，任务重新受理/claim 未接线，旧批准不会恢复。revoked/completed 不允许恢复；终态事实更正/重新开启需后续专门命令。
8. unknown 的只读效果核对允许在 Goal 停止或租约变化之后进行，但只保存审计 Outcome，不恢复权限，也不完成 Goal。已进入派发窗口的外部效果未来无法靠数据库撤销保证召回，真实 adapter 必须给出幂等/取消/对账契约。
9. `goal_proposal_ready` 和当前 `goal_action_outcome` 的 Event 与 outbox 同事务提交。outbox ID 绑定 scope/event/channel。合成 inbox insertIfAbsent 和 outbox published 在同事务完成；重启/重复发布只产生一条通知。静默期内保留 pending；过期 Goal version 或 stopped Goal 的 pending 在消费时 cancelled，无通知发送。仅 refs，不发信、不调用 APNs。静默期到期也没有定时自动唤醒。

第二小批强化：停止工作前也必须核对 binding 对应的权威 run subject/scope/operation/request hash 和 task tag，并沿既有 scope→delegation→task 顺序锁 task。审批 binding 必须指向不可变、同 Goal/version/action digest 的直接用户 Decision；binding 的 approved 投影不能独立授权。最后 binding/Decision await 后复查捕获 leaseUntil 与 control。unknown 的 effect key 必须与保存的原参数重算一致，防止损坏的 key 绕过意图保留或把 reconcile 指向其他效果。

逻辑删除命令 `{schema_version, expected_revision}` 通过 Goal CAS、停止旧工作和写 `catpaw-goal-tombstones` 同事务完成。它仅封住执行，不声称物理删除内容。删除后最新 tombstone 会阻止旧 Goal、旧批准和旧 pending outbox 复活；只读 unknown 审计可使用 subject/scope 绑定的 tombstone 投影，不恢复 Goal 内容或权限。原 Foundation Store 的 remove/put 是受信维护端口，绕开逻辑删除协议不受保护。

必须保留恢复边界：如果恢复整个派发前 snapshot，且同时丢失 tombstone、Action executing/unknown 和通知去重账本，内核无法知道之后发生了什么。本批有具名测试实际复现两个合成 adapter 对同一意图各执行一次；这是未解决风险复现，不能算恢复安全通过。生产恢复需独立于被恢复库的最新删除/撤权/效果清单及隔离恢复门槛，未达到前保持 production_kernel_disabled。通知一次性同样仅在最新 inbox 去重记录保留时成立；外部推送回执、跨系统 exactly-once 和整库回滚未证明。

第三小批新增[恢复派发屏障](../acceptance/proactive-restore-dispatch-barrier.md)：外部可信readMarker/操作员bind注入，库内只存期望指针。外部locked、缺失/失联/过期、scope错误、DB binding或旧Action指针不匹配均拒绝副作用；只读效果核对仍可用。规范恢复要先外部锁定并更新incarnation/epoch、隔离核对独立删除/撤权/效果账本、人工授权bind，再开放；库内复制表不算独立权威。指针检查已实现，真实外部权威/全恢复路径覆盖尚未实现；未锁定且外部标记未变化的回滚仍保留反例，生产继续关闭。

预算直接消费既有 `control.assertLive`，不创造新的平台时限。原 boundedTick 的 30,000ms 上限及 settleReserve、lease 校验保持不动；worker-kick 的总推进预算不被扩大。上线还需按实际部署计划重核 [Supabase Edge limits](https://supabase.com/docs/guides/functions/limits) 和 [changelog](https://supabase.com/changelog)。本批没有更改 Edge 配置或 Supabase SDK。

## 两个固定场景

旅行：用户确认「16:00 到合成会场」→ source revision 1 给出预计 17:00 → 准备引用该证据的替代方案，摘要说明候选预计 14:00，Action awaiting_review → 用户批准确切 Action 后才能调用合成效果 adapter。候选购买/计划成功、预计 14:00、到机场、带未来时间戳的“实际到达”均不完成 Goal。独立 actual_arrival 证据需地点匹配、到达时间不晚于当前时刻且不晚于 16:00；例如 15:45 到合成会场才完成。若用户已经自行完成，直接确认后停止待购方案和任务。16:00 后真实到达不能满足原时间目标；失败/超时决策策略尚未实现。

报告：用户确认交付特定 report_key → report_generated 只说明生成了带 hash 的成果 → 提案等待独立发信批准 → 合成 adapter 的 provider_accepted 只说明效果得到接受，不声称收件人收到。确认丢失时 unknown，不重复发送；reconcile confirmed 只结算效果。必须独立 delivery_confirmed 事件与 report_key 相符才完成最终 Goal。真实收件方 receipt、人工签收或其他可靠交付证明的 adapter 契约未实现。

## 本批边界和下一批

构造器仅接受 `synthetic_test_double` Repository，真实 Postgres kernel 显式返回 `production_kernel_disabled`；非 synthetic adapter 返回 `real_adapter_disabled`。没有注册 kernel 到 API/bootstrap/runtime，没有外部真实 adapter、邮箱/账号接入、Cron/tick、模型、UI、部署、生产 SQL 或凭据。scoped Postgres CAS 增量只做参数化序列化验证；不代表数据库已迁移或并发验收通过。

对抗复核与新验证层见[第二小批记录](../acceptance/proactive-goal-adversarial-review.md)。在用户随后授权补官方依赖后，Deno 2.9.6 从[官方发布](https://github.com/denoland/deno/releases/tag/v2.9.6)下载并按发布方 SHA256 校验；jose/postgres 只缓存 deno.lock 固定版本且启用 frozen lock，无 lifecycle scripts。仅测试阶段 deny-net/ignore-env。完整 Edge 合成回归覆盖实际 Store/serializer 分支，但 TestRepository 仍把整个 scope/owner 写入串行化，lock 是空操作；无法证明 PostgreSQL 行锁顺序/死锁、跨实例 CAS、SQL+records 原子提交、提交确认丢失、RLS/隔离级别、进程 crash、备份恢复。生产构造器拒绝 PostgreSQL，因此这些测试也没有执行真实 kernel SQL。

第三小批另外执行临时真实Postgres17.11：6项实际存储/CAS/lease撤销/通知唯一性及锁等待验证＋1项生产关闭检查，7/7；同连接Goal/Event/records异常回滚通过。该层不是mock，但仍为superuser/minimal fixture schema下的Repository/BoundedStore/Facade存储原语，不代表生产RLS、完整kernel、多实例崩溃或COMMIT确认丢失通过。测试容器network=none、tmpfs、无端口/host mount，已清理；生产DB未连接。

下一批按小批顺序：设计 task/run 的 Goal binding 更新与生产 fresh authority/长期撤销协议；用独立测试 PG 验证 scope锁、CAS、outbox、多实例重启、删除/恢复屏障；补真实 ingress 来源身份与 source revision 协议；设计 purchase/send 的 adapter 幂等/receipt/reconcile 与人工签收；最后才考虑自然语言目标抽取、事件影响与建议生成、原生回流和经过授权的唤醒/部署。

确定性测试只验证领域规则、幂等、停止、fencing 与效果计数。固定候选摘要或模型字符串相等不构成语义准确率。语义评测需另外准备 held-out 目标/事件对（包含不相关事件、地点与时区、估计/事实、权限注入、生成/交付区分、事实更正），独立标注影响判断、证据覆盖、误完成/误授权、用户打扰率；本批未建立/运行该评测，也未调用真实模型。
