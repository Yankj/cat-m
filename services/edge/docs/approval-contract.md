# catpaw.approval.v1 — human-in-the-loop tool approval

Status: A1 (backend core + iOS network layer). The UI is not part of A1. `facade.gatedChatTools` is empty until A2 registers real gated tools, so production behaviour is unchanged until then.

## 1. Negotiation

- The client sends `X-Catpaw-Approval-Contract: catpaw.approval.v1` on `POST …/conversations/{c}/turns`. iOS sends it only for plain turns: no image, continuation, accepted work or revision work.
- Any other value gets 422 `approval_contract_invalid`. The contract is part of the turn admission hash and is stored as `turn.approval_contract`.
- **Old clients** (no header) are never offered a tool whose policy is not `never`. Read-only gated tools are still offered.

## 2. Confirmation policy (tool registry, `tools.mjs` `TOOL_APPROVAL`)

| approval | tools | class |
|---|---|---|
| `never` | agent_status, list_tasks, delegate_*, revise_*, propose_memory_v1 | — |
| `first_use` | create_task, update_task | `proactive_task_write` (`approve_always` allowed) |
| `always` | create/update_calendar_event, create/update_reminder, external_write | calendar_write / reminder_write / external_write |
| undeclared tool | — | `always`, risk `external_write` |

- `approve_always` stores `{state:'always_allow'}` in the existing `public.records` table under kind `native-chat-approval-preferences`, keyed per subject and class. No new table and no DDL.
- After that, calls of that class run without asking. `always` tools keep asking.

## 3. State machine

```
running ──gated call──▶ awaiting_approval ──all interrupts resolved──▶ running ──▶ completed | failed
                              │  └─ cancel ─▶ failed{cancelled}
                              └─ 10 min ─▶ expired (= denied to the model) ─▶ running
```

- `awaiting_approval` is **not terminal**. The observation SSE stream ends after `turn_suspended`, and the turn stays `conversation_busy` for new messages. To start over, the client cancels.
- **Expiry** is 10 minutes after `approval_requested`. It is applied lazily on any turn read (`GET` turn/events) and on a decision. `catpaw-tick` is unchanged.
- **Denied, expired and cancelled calls are never executed.** The model receives `tool_result{status:'denied', result:{status:'denied', reason:'user_denied'|'approval_expired'|'approval_cancelled'}}`.
- **Cancel** (`POST …/turns/{t}/cancel`) of a suspended turn does two things:
  - It resolves each pending interrupt as `cancelled` by emitting `approval_resolved`.
  - It then emits `turn_failed{code:'cancelled'}`.

## 4. Events (same envelope, `sequence` stays continuous)

| type | data |
|---|---|
| `tool_call` | unchanged; always precedes its interrupt |
| `approval_requested` | `{interrupt_id, call_id, tool, summary(≤240), arguments, args_hash(sha256 hex), expires_at(ISO UTC), risk, remember_allowed}` |
| `turn_suspended` | `{interrupt_ids:[…], expires_at}` (earliest expiry) |
| `approval_resolved` | `{interrupt_id, call_id, decision:'approved'|'denied'|'expired'|'cancelled', remember, decided_at, decision_operation_id?}` |
| `tool_result` | adds `status:'ok'|'denied'|'error'` |

- **Interrupt ids** are deterministic: `stableUUID(turn_id:call_id:approval)`.
- **Gated tool execution** uses `operation_id = stableUUID(turn_id:call_id:operation)`.

## 5. Decision endpoint

`POST /catpaw/chat/v1/scopes/{s}/conversations/{c}/turns/{t}/interrupts/{i}/decision[?after_sequence=N]`

Body (exact keys): `{"operation_id":"<uuid>","decision":"approve"|"deny"|"approve_always","args_hash":"<64 hex>"}`

- **Success:** `200 text/event-stream` carrying the SAME turn's events after N.
  - The default N is the sequence just before this `approval_resolved`.
  - The model round continues in place, the same way busy-retry restarts a turn. There is no re-POST and the user message is not repeated.
- **Idempotency:** the same `operation_id` with the same body replays as 200 with the stream. The same `operation_id` with a different body gets 409 `approval_operation_conflict`.
- **Errors** use the actions/v1 envelope `{schema_version:1, error:{code,…}}`:

| status | code | meaning |
|---|---|---|
| 422 | `approval_schema_invalid` | bad body |
| 422 | `approval_remember_not_allowed` | `approve_always` on an `always` tool |
| 404 | `not_found` | unknown turn or interrupt |
| 409 | `approval_expired` | expired; the expiry is committed and the turn has resumed with a denied result |
| 409 | `approval_consumed` | already decided, or the turn is not awaiting |
| 409 | `approval_stale` | args_hash mismatch |
| 409 | `approval_grant_conflict` | the conversation revision or grant changed |
| 409 | `approval_operation_conflict` | operation_id reused with a different body |

## 6. Snapshot

`GET …/turns/{t}` returns `turn.state` (which may be `awaiting_approval`) and `turn.pending_approvals`: `[{interrupt_id, call_id, tool, summary, arguments, args_hash, expires_at, risk, remember_allowed}]`. Internal `interrupts` and `approval_checkpoint` are never projected.

## 7. Storage

Everything lives on the existing `native-chat-turns` record: `interrupts[]`, `approval_checkpoint` (the paused model round), `approval_contract` and `suspended_at`. Class grants are stored as records of kind `native-chat-approval-preferences`. No table or column was added.

## 8. iOS (network layer)

- **`ConversationTurnEvent.Payload`** gains these cases:
  - `.approvalRequested(ConversationApprovalRequest)`
  - `.suspended(interruptIDs:expiresAt:)`
  - `.approvalResolved(interruptID:callID:decision:remember:)`
  - `ConversationToolResult.status` is also new.
- **`ConversationSessionService`:**
  - `send` returns normally when the turn suspends. The record stays `.running` with `pendingApprovals`, and `awaitingApproval == true`.
  - `pendingApprovals(scope:conversationID:)` returns the pending approvals.
  - `submitApproval(scope:conversationID:interruptID:decision:operationID:)`:
    - It posts the decision and pumps the continuation through the usual journal → `turnEvents()` path.
    - After `.transport`, resend with the SAME `operationID`.
    - On `.expired`, `.consumed`, `.stale` or `.notFound`, it reconciles from the snapshot first and then rethrows.
  - **Cold start:** `openLatest` marks the turn `unknown`, and `observe` then restores `pendingApprovals` from the snapshot.
  - `cancelCurrentTurn` also cancels a suspended turn.
- **`ConversationBackend.submitApproval(...)`** has a default that throws `ConversationApprovalFailure.unsupported`.

## 9. A2 — proactive task tools (catpaw.task-tools.v1)

- **Registration:** `_shared/proactive/chat-tools.mjs` registers `create_task`, `update_task` and `list_tasks` in `facade.gatedChatTools`. It is enabled in catpaw-api by `CATPAW_PROACTIVE_TOOLS_ENABLED=true`, through `createPgStore(sql)` on the API's dedicated pool.
- **Contract-only:** the entries are `contractOnly`, so they are offered only to turns that negotiated `catpaw.approval.v1`. Older iOS builds reject unknown tool names.
- **Policy:**
  - `list_tasks` is `never` and runs directly.
  - `create_task` and `update_task` are `first_use`, class `proactive_task_write`, and allow `approve_always`.
- **Execution:** tools run in-process with `createProactiveService({store}).executeTool(subject_id, call, {conversation_id, turn_id, operation_id})`.
  - `operation_id = stableUUID(turn_id:call_id:operation)`, so retry-busy, approval resume and recovery replay the same task (`created:false`).
  - If the service returns `{ok:false,error}`, the result is `tool_result{status:'error', result:{status:'error', code}}`.
- **Time zone:** clients send `X-Catpaw-Time-Zone: <IANA>`, which is stored as `turn.client_time_zone`. On negotiated turns the prompt includes the user's time zone and current local time with its offset. If the zone is missing or invalid, it uses `UTC`, labelled as a fallback. There is no server-side user setting for time zone yet.
- **Atomicity:** proactive writes go through the `postgres` client, not the records transaction. Idempotency comes from `(user_id, operation_id)`, not from a shared transaction.
