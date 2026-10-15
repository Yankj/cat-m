# catpaw.device.v1 — Wave 2 B3 (device_call / device_result)

Gate `CATPAW_DEVICE_TOOLS_ENABLED` (`true` · `allowlist` · unset/off, default **off**). The client opts in per turn with
`X-Catpaw-Device-Contract: catpaw.device.v1` (only honoured together with `X-Catpaw-Approval-Contract`).
No schema change, no migration: device calls are approval.v1 interrupts of `kind:"device"` on the turn row.

## Flow

1. The model calls a device tool → the turn suspends (`awaiting_approval`) and streams
   `tool_call` → `device_call` → `turn_suspended`.
2. The app shows the card (`confirm:"card"`) or runs directly (`confirm:"none"`, read-only tools), executes, and posts the result.
3. The server resolves the interrupt and resumes the SAME turn in place: `approval_resolved{kind:"device",decision:"reported",device_status}`
   → `tool_result` → … → `turn_completed`.
4. No result before `expires_at` (`ttl_sec`, default 600): the interrupt expires (lazily, on the next read/post), the model gets
   `{status:"pending_timeout"}`. The SSE stream ends at `turn_suspended`; "pending" is just that state. When the user comes
   back, the app reads the turn (`pending_approvals[]` has `kind:"device"` + `device_call`) or replays the events, and posts.

## Event

```jsonc
{"type":"device_call","data":{"call_id":"call-…","tool":"calendar_create","args":{…},"confirm":"card","ttl_sec":600,
  "interrupt_id":"uuid","args_hash":"sha256 hex","expires_at":"ISO"}}   // envelope carries conversation_id, turn_id, sequence
```

## Result

`POST /functions/v1/catpaw-api/catpaw/chat/v1/scopes/{s}/conversations/{c}/turns/{t}/device-result` (SSE response, like the decision route)

```json
{"call_id":"call-…","operation_id":"uuid","args_hash":"<from device_call>","status":"ok|cancelled|denied|error","data":{}}
```

| case | answer |
|---|---|
| same `operation_id` + same body | 200, replay |
| same `operation_id`, different body | 409 `approval_operation_conflict` |
| new `operation_id` after it was reported | 409 `approval_consumed` |
| `args_hash` mismatch | 409 `approval_stale` |
| past `expires_at` | 409 `approval_expired` (the turn resumes with `pending_timeout`) |
| unknown call_id | 404 `device_call_not_found` |

`data` ≤ 32 KB. The model receives `{status, data?}`.

## Tools (plan §3.2)

| tool | confirm |
|---|---|
| `calendar_list{from,to}` · `contacts_search{query}` | none |
| `calendar_create{title,start,end,location?,notes?,alarms?}` · `reminder_create{title,due?,list?,priority?}` · `mail_compose{to[],cc?,subject,body}` · `sms_compose{to[],body}` · `phone_call{number,name?}` · `maps_open{query｜lat+lng,mode?}` · `shop_open{platform,query｜url}` · `alarm_set{time,label?}` · `shortcut_run{name,input?}` | card |

Not cloud tools: `pay_apple` (merchant entitlement, phase 2), `timer_start`/`focus` (App Intents, reverse direction).

## iOS (this PR)

- `ConversationTurnEvent.Payload.deviceCall(ConversationDeviceCall)`, `ConversationTurnRecord.pendingDeviceCalls`.
- `ConversationSessionService.submitDeviceResult(scope:callID:status:data:)`; `ConversationDeviceResultSubmitter` adapts it to #44's
  `DeviceResultSubmitting` (snippet in the source). `ConversationDeviceCall.wireJSON` decodes into #44's `DeviceCall`.
- `ConversationDeviceCall.clientEnabled` (default false) gates the header until #44's card + M1's executor are installed.

## Differences from #44 / plan

- #44 `DeviceCallResult` has no `operation_id`/`args_hash`/turn: the submitter derives them (stable operation id per call, args_hash
  from the event, turn from the call index). `openURL` stays on the device and is not sent.
- #44 `DeviceCallValue` has no numeric arrays: `calendar_create.alarms` (minutes) decodes as `.null` there.
- Plan `POST /device-result` is turn-scoped here (`…/turns/{t}/device-result`), like the decision route.
