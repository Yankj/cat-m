# catpaw.family.v1

状态：冻结。日期：2026-10-23。协议名 `catpaw.family.v1`。前缀 `/catpaw/family/v1`。

本文是家庭线的类型化 API / 事件合同，供 iOS 与后端同时实现。它落实 [M0 契约](m0-contract.md) 里尚未写死的 JSON、请求哈希、错误和读模型，并服从用户已确认的 [定位 v1](positioning-v1.md)。既有 `/catpaw/...`、SSE、存储和安装身份保持不变。本文不表示接口已部署，也不授权迁移、生产写入或发布。

未冻结、因此本协议不授权的事项：年龄推断、普通观察自动长期保存、原图/音频保留期、第二位成人的共享、实时语音、自动报名缴费。未知能力保持关闭。

## 1. 传输

- 只接受 `https` JSON，`content-type: application/json`。响应 `cache-control: no-store`。
- 字符集 UTF-8。请求体上限 32 KiB。更大返回 `413 request_too_large`，不写回执。
- 重复 JSON 键拒绝，`422 json_invalid`。
- `actor_user_id` 只从已验证会话解析。请求体里的 actor、user、owner 字段一律忽略，不参与哈希。
- 家庭时区是 IANA 名，默认 `Asia/Shanghai`。时刻用带偏移的 ISO-8601；本地日期是 `YYYY-MM-DD`，不把全天事项编成 UTC 零点。
- 标识符是 UUID（小写字符串）。`command_id` 由客户端生成并在重试时保持不变。

能力探测：`GET /catpaw/family/v1/bootstrap` 在会话有效时返回 `{protocol, schema_version:1, enabled:true}` 以及该用户可见的家庭 id 列表。未部署或旧客户端看不到此路由时，不得把本地 fixture 当成能力已开放。

## 2. 对象

所有家庭对象带 `household_id` 与从 1 起的 `revision`。删除不物理抹掉身份：写 `deleted_at`，revision + 1，并留下墓碑。迟到的创建/更新不得把墓碑行救回。

| 对象 | 标识 | 必填字段 | 状态 |
|---|---|---|---|
| family `household` | `household_id` | `name`, `timezone`, `owner_user_id`, `revision` | `active` / `archived` |
| child `member` | `member_id` | `display_name`, `member_kind=child`, `revision` | `active` / `deleted` |
| plan | `plan_id` | `title`, `member_id` 可空, `domain`, `revision` | `draft` / `active` / `paused` / `completed` / `archived` / `deleted` |
| item / schedule entry | `item_id` | `title`, `status`, `revision`, `local_date` 可空, `local_time` 可空, `timezone` | 见下 |
| observation | `observation_id` | `member_id`, `text`, `observed_on`, `source`, `revision` | `recorded` / `deleted` |
| memory fact | `memory_id` | `text`, `kind=fact`, `source`, `revision` | `active` / `deleted` |
| reminder | `reminder_id` | `item_id`, `kind`, `why_now`, `fire_at`, `revision` | `scheduled` / `cancelled` |
| proposal | `proposal_id` | `target_type`, `target_id`, `base_revision`, `patch`, `revision` | `open` / `confirmed` / `rejected` / `expired` |
| receipt | `command_id` | 见第 4 节 | `processing` / `applied` / `rejected` |
| outbox event | `event_id` | 见第 8 节 | `pending` / `dispatched` |

事项 `item.status` 只有：

- `needs_confirmation`：已抽出、未确认。读模型不得把它放进日程。
- `scheduled`：存在一条 `applied` 的 `item.confirm` 或 `item.reschedule` 回执，且 `confirmed_command_id` 指向该回执。只有这种事项是日程。
- `cancelled` / `deleted`：不出现在日程。

记忆 `source` 必填，且只含类型与引用，不把原图或音频放进事实：

```json
{"source_kind":"user_text","source_ref":"turn:example","captured_at":"2026-10-23T12:00:00+08:00"}
```

`source_kind`：`user_text` / `user_voice_transcript` / `user_confirm` / `notification_extract`。推断不是事实，本版本没有 `inference` 写入命令。

孩子档案可含可选 `school_label`、`class_label`、`teacher_label`、`place_label`。这些是家长写入的短文本，不是账号。

## 3. 命令

`POST /catpaw/family/v1/households/{household_id}/commands`

`household.ensure` 使用 `POST /catpaw/family/v1/commands`，因为家庭可能尚不存在。路径上的 `household_id` 必须等于体里的 `household_id`。

```json
{
  "command_id": "6f1c2c2e-7b1a-4c0a-9d2e-1a2b3c4d5e6f",
  "type": "item.reschedule",
  "household_id": "3c1a9b2e-4d5f-4a6b-8c7d-9e0f1a2b3c4d",
  "target_id": "8a7b6c5d-4e3f-4a2b-9c8d-7e6f5a4b3c2d",
  "expected_revision": 7,
  "proposal_id": "1d2c3b4a-5e6f-4a7b-8c9d-0e1f2a3b4c5d",
  "payload": {
    "local_date": "2026-11-05",
    "local_time": "17:00",
    "timezone": "Asia/Shanghai",
    "scope": "one_occurrence"
  },
  "consent": {"confirm_revision": 2, "actions": ["update_item", "replace_reminder"]}
}
```

| type | expected_revision | 作用 |
|---|---|---|
| `household.ensure` | 不需要 | 创建该用户的唯一家庭；已存在则返回原家庭且不覆盖名称，除非另发 `household.update` |
| `household.update` | 需要 | 改名称或时区 |
| `child.upsert` | 新建不需要；已存在需要 | 新建或更正孩子档案 |
| `child.delete` | 需要 | 墓碑 |
| `plan.upsert` | 新建不需要；已存在需要 | 计划不等于事项 |
| `plan.pause` | 需要 | 暂停计划，不自动取消已确认事项 |
| `item.propose` | 不需要 | 写入 `needs_confirmation`。不是日程 |
| `item.confirm` | 需要，且等于提案的 `base_revision` | 唯一把事项变成 `scheduled` 的命令 |
| `item.correct` | 需要 | 更正标题、孩子、地点、要带的东西；不改变确认状态 |
| `item.cancel` | 需要 | 取消事项及其未发出提醒 |
| `item.reschedule` | 需要 | `scope=one_occurrence` 或 `series`。必须带 `consent.actions`，其中含 `update_item`；若同时改提醒，还含 `replace_reminder` |
| `observation.record` | 不需要 | 观察，不是事实，不改计划 |
| `observation.correct` | 需要 | CAS 更正 |
| `observation.delete` | 需要 | 墓碑 |
| `memory.upsert` | 新建不需要；已存在需要 | 事实，必须带 `source` |
| `memory.correct` | 需要 | CAS；旧文本不得再被读模型返回 |
| `memory.delete` | 需要 | 墓碑。同 `command_id` 重放不得重建 |
| `reminder.schedule` | 需要（事项 revision） | 仅当事项已是 `scheduled`。见第 7 节 |
| `reminder.cancel` | 需要 | 取消提醒，不反向取消事项 |

`consent.actions` 是本次允许的副作用集合。服务端不得执行集合之外的写入。影响行为的字段（日期、时间、时区、范围、孩子、提醒）任一变化，旧确认失效，必须新的 `proposal_id` 与新的 `command_id`。

## 4. 回执

受理后的每一个命令都有一行持久回执，与领域写入、revision、outbox 同一事务提交。没有回执不得报告完成。HTTP 状态不是完成证明。

```json
{
  "protocol": "catpaw.family.v1",
  "schema_version": 1,
  "command_id": "6f1c2c2e-7b1a-4c0a-9d2e-1a2b3c4d5e6f",
  "household_id": "3c1a9b2e-4d5f-4a6b-8c7d-9e0f1a2b3c4d",
  "request_hash": "64 位小写十六进制",
  "status": "applied",
  "objects": [{"type": "item", "id": "8a7b6c5d-4e3f-4a2b-9c8d-7e6f5a4b3c2d", "revision": 8}],
  "error": null
}
```

`status`：

- `processing`：事务尚未对调用方可见。客户端继续用原 `command_id` 查询，不新造 id。
- `applied`：领域写入、revision 与 outbox 已提交。
- `rejected`：确定性拒绝已提交（冲突、校验、确认不匹配）。同一哈希的重试返回这条回执，不会重新执行。

`error` 在 `rejected` 时为 `{code, recoverable}`。`recoverable`：

- `reread`：先读当前投影，用新 `command_id` 重试。
- `stop`：同一命令不应自动重试（权限、确认集合不合法）。
- `retry_same_id`：仅当回执仍是 `processing` 或查询结果为 `not_found` 且合同允许重放该 id。

HTTP：

- `200`：响应体里的回执已经是 `applied` 或 `rejected`。
- `202`：只表示受理，回执仍是 `processing`。不得把 202 显示成已安排。
- 同步实现可以在同一事务提交后直接 `200`。不得在提交前返回 `applied`。

## 5. 幂等、版本、未知

幂等键是 `(actor_user_id, household_id, command_id)`。

- 相同 `request_hash`：返回原回执，不第二次写领域。
- 不同 `request_hash`：`409 idempotency_conflict`。不返回另一份载荷、标题或差异。
- 每次读回执都重新检查当前会话。撤权后不得借旧回执读出内容。

`request_hash` 是请求体的 SHA-256，UTF-8，小写十六进制。规范化 JSON：

1. 只取 `command_id`、`type`、`household_id`、`target_id`、`expected_revision`、`proposal_id`、`payload`、`consent`。缺省键写成 `null`。
2. 对象键按 UTF-16 码元升序。数组保持原序。
3. 无空白。字符串按 RFC 8259 转义。`true` / `false` / `null` 为字面量。
4. 数字只接受安全整数，序列化不带指数和小数点。其他数字 `422 json_invalid`。
5. 不把会话、HTTP 头或收到时间算进哈希。

`revision` 由服务端单调增加。更正、删除、确认、改期必须带 `expected_revision`。不匹配则 `409 revision_conflict`，领域不变，客户端保留草稿。旧响应不得覆盖客户端已知的更高 revision。

未知结果是客户端状态，不是服务端状态。响应丢失、超时或连接中断时：

1. 记 `outcome_unknown`。
2. `GET /catpaw/family/v1/commands/{command_id}`。
3. 可见回执按其 `status` 解释。
4. `not_found` 只说明当前身份看不见这条回执。只有合同写明可以重放、且调用方仍持有原 `command_id` 时，才用同一 id 再 POST 一次。不得新造 id 来掩盖未知。

`GET` 回执体：

```json
{"protocol":"catpaw.family.v1","schema_version":1,"outcome":"not_found","command_id":"..."}
```

`outcome`：`not_found` / `processing` / `applied` / `rejected`。后三者同时带第 4 节的回执字段。

## 6. 错误

机器码稳定。响应不包含堆栈、SQL、URL、密钥或用户正文。

| HTTP | code | 何时 |
|---|---|---|
| 401 | `session_required` | 无有效会话 |
| 403 | `forbidden` | 曾经可见但成员资格已撤。不含标题 |
| 404 | `not_found` | 当前身份看不见对象或回执 |
| 409 | `revision_conflict` | `expected_revision` 落后 |
| 409 | `idempotency_conflict` | 同命令 id、不同哈希 |
| 409 | `confirmation_required` | 想把未确认事项当成日程，或改期缺少 consent |
| 422 | `json_invalid` / `command_invalid` / `timezone_invalid` | 形状不合法。不写领域 |
| 413 | `request_too_large` | 体超过 32 KiB |
| 503 | `unavailable` | 依赖不可用。`retryable` 恒为 false；不因此自动重发写命令 |

无权时不返回对象标题、冲突差异或记忆来源。

## 7. 提醒

只允许三类 `kind`：`deadline_approaching`、`bring_item`、`conflict`。每户每个本地日最多 2 条 `scheduled` 提醒。`why_now` 必填，最长 80 字，说明为何现在提醒。家庭时区 21:00–08:00 不新建会在该窗口触发的提醒；调用返回 `rejected` / `quiet_hours`。

未确认事项调用 `reminder.schedule` 得到 `confirmation_required`，不写提醒行。

## 8. 事件

领域对象、revision、回执、outbox 同一事务。模型、APNs、设备动作在事务外，且执行前再次核对权限、revision 与提醒状态。

```json
{
  "event_id": "0f1e2d3c-4b5a-4968-8776-655443322110",
  "type": "item.changed",
  "schema_version": 1,
  "protocol": "catpaw.family.v1",
  "household_id": "3c1a9b2e-4d5f-4a6b-8c7d-9e0f1a2b3c4d",
  "aggregate_type": "item",
  "aggregate_id": "8a7b6c5d-4e3f-4a2b-9c8d-7e6f5a4b3c2d",
  "aggregate_revision": 8,
  "occurred_at": "2026-10-23T04:00:00Z",
  "actor_ref": "user:9b8a7c6d-5e4f-4a3b-8c7d-6e5f4a3b2c1d",
  "causation_id": "6f1c2c2e-7b1a-4c0a-9d2e-1a2b3c4d5e6f",
  "payload_refs": [{"type": "item", "id": "8a7b6c5d-4e3f-4a2b-9c8d-7e6f5a4b3c2d"}]
}
```

首批 `type`：`household.changed`、`child.changed`、`child.deleted`、`plan.changed`、`item.proposed`、`item.changed`、`item.deleted`、`observation.recorded`、`observation.deleted`、`memory.changed`、`memory.deleted`、`reminder.changed`、`command.applied`。

事件载荷只有引用，不复制孩子全文。消费者按 `event_id` 去重，按 `aggregate_revision` 丢掉更旧事件，缺号则回读第 9 节快照。事件不是权威，领域行才是。

`GET /catpaw/family/v1/households/{household_id}/changes?after=<event_id 或 revision 游标>` 按 `occurred_at, event_id` 升序返回仍可见的事件。游标失效时 `409 cursor_expired`，客户端改读完整投影。

## 9. 读模型

今天、对话、我们家读同一次快照。SSE 结束、模型说完成、卡片点击都不能把事项显示为已安排。

`GET /catpaw/family/v1/households/{household_id}/projection?local_date=YYYY-MM-DD`

```json
{
  "protocol": "catpaw.family.v1",
  "schema_version": 1,
  "household_id": "...",
  "projection_revision": 12,
  "local_date": "2026-10-23",
  "timezone": "Asia/Shanghai",
  "today": {
    "schedule": [],
    "pending_confirmations": [],
    "reminders": []
  },
  "conversation": {"open_proposals": [], "recent_receipts": []},
  "home": {"household": {}, "children": [], "plans": [], "memories": [], "observations": []}
}
```

- `today.schedule`：仅 `scheduled` 且 `local_date` 匹配的事项。每条带 `revision`、孩子显示名、时间、要带的东西。
- `today.pending_confirmations`：`needs_confirmation` 的事项与开放提案。文案层不得叫「已安排」。
- `today.reminders`：当日仍 `scheduled` 的提醒，含 `why_now`。
- `conversation`：开放提案与最近回执的状态、对象 id、revision。不含模型原文。
- `home`：家庭、孩子、计划、带 `source` 的事实、观察。已删除对象不在列表里；变更流里用墓碑。

`projection_revision` 是该家庭当前最大领域 revision。客户端若本地已有更高值，丢弃这份更旧响应。

## 10. 隔离

首版只有一位成人。`households.owner_user_id` 等于会话用户。RLS 默认拒绝；`authenticated` 只能读写自己拥有的家庭及其子行。不提供第二位照护者的邀请命令。服务角色连接必须在语句里再次按 owner 过滤，不能只依赖 RLS。

个人聊天仍属原账号。本协议不把对话记录改成家庭共享。

## 11. 与既有记忆、提醒的边界

`catpaw.agent-memory.v1` 与 `catpaw` 主动提醒继续服务既有客户端。家庭事实的权威是本协议的 `memory` 对象。既有记忆写入若被家庭删除命令覆盖，重放原 operation 不得复活该事实。迟到的更正若 `expected_revision` 或写入开始时读到的 revision 已过期，返回 `409`，保留较新正文。

既有提醒的 claim 在租约到期后可被下一个调度周期重新领取；取消若先于事件提交成功，则不得再产生 `reminder_due` 或发送。写失败不得清掉仍到期的 `next_fire_at`。日志只记稳定错误码，不记标题、正文、堆栈或异常 message。
