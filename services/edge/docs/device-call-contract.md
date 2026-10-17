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
| past `expires_at`, up to 24 h after it (chat-context-1522 P1-2) | **200** SSE, header `X-Catpaw-Device-Late: ttl_exceeded`. The phone's result is recorded on the interrupt (`late_response`, `late_ttl_exceeded`) and in `conversation.interaction_outcomes` (`late:true, ttl_exceeded:true`), and the next turn gets a note. If this report is the one that expires the card, the resumed round gets the real result (`reported_after_ttl:true`) instead of `pending_timeout`. A turn that already ended is never reopened. Idempotent by `operation_id`; `args_hash` and grant-epoch checks still apply |
| past `expires_at` by more than 24 h | 409 `approval_expired`, nothing recorded (the turn resumes with `pending_timeout`) |
| card superseded by the user's next message (turn failed `superseded_by_new_message`) | **200** SSE, header `X-Catpaw-Device-Late: superseded` (or `ttl_exceeded` when also past `expires_at`). The result is recorded the same way, and the turn stays closed |
| unknown call_id | 404 `device_call_not_found` |

`data` ≤ 32 KB. The model receives `{status, data?}`.

## Tools (plan §3.2)

| tool | confirm |
|---|---|
| `calendar_list{from,to}` | none |
| `contacts_search{query,include_email?}` | card (chat-ux #7: contacts leave the phone only after a tap; result = name + phones, emails only with include_email) |
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

## Client execution gate (Codex P0-1 / PR #89 re-review)

- **Where grants come from.** Grants are created only at the authenticated SSE boundary: `ConversationSessionService` saves the journal, then fires `ConversationDeviceCall.lifecycle(.received)`, and `DeviceCallGate.receive` creates the grant. Views and Markdown can never create one.
- **What a grant is bound to.** call_id + tool + args hash + interrupt_id + conversation + turn + a non-nil account + the session generation.
  - The deadline is strict: if `expires_at` can't be parsed, the call is refused. When both values are present, the earlier of `expires_at` and `ttl` wins. A repeated event never extends the deadline. An uptime budget stops wall-clock rollback from extending it. At exactly the deadline the call already counts as expired.
- **Revocation.** Grants are revoked when the journal drops the call (resolved, cancelled, turn completed or failed). Sign-out bumps the generation, which revokes everything. A card that is still waiting for confirmation then shows as expired.
- **Writes need a tap.** Every write consumes a one-shot tap token from the card button, bound to the final edited args.
- **Check before every side effect.** `DeviceToolRouter` re-checks `commitCheck` synchronously right before each system effect (EventKit save, compose sheet, URL handoff), so a permission prompt or other await cannot outlive the grant.
- **Restart recovery never writes.**
  - Only the account that recorded the call can recover it.
  - Recovery only looks up the original effect by its call_id marker. If nothing is found, the result is `interrupted_outcome_unknown`.
  - Pending calls restored from the journal after a cold start are not executable until the server re-sends them.
- **Tradeoff: auto-run reads.** `calendar_list` and `places_search` run without a tap but still need a live, account-bound grant. They are read-only but **not privacy-free**:
  - calendar_list returns event titles, times and locations;
  - places_search uses the current location and preference memory.

  Their results go only to the turn that requested them.
