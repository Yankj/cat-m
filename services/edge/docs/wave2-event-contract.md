# Wave 2 event contract (B5): memory_saved, memory_recalled, device_call

Machine-checked by `test/wave2-event-contract.test.mjs` against `test/fixtures/wave2-events.jsonl`.
Implementations: B1 PR #41 (`catpaw.agent-memory.v1`), B3 PR #49 (`catpaw.device.v1`).
`task_proposed`, `task_updated` and `proactive_message` belong to B2 and are not covered here.

## Envelope (all native-chat SSE events)

`data: {schema_version:1, contract:"catpaw.native-chat.v1", scope_id, conversation_id, turn_id, sequence, cursor, grant_epoch, model_reality, type, data}`

Plan §6 draws the fields flat (`{"type":"memory_saved","memory":…}`); on the wire they sit under `data`, and
`conversation_id` / `turn_id` come from the envelope. Unknown extra fields must be ignored by clients.

## memory_saved (B1)

```json
{"type":"memory_saved","data":{"memory":{"id":"uuid","kind":"profile|preference|person|fact","content":"≤500 chars"},"undo_token":"base64url, 32 chars","call_id":"…"}}
```
- Right after the `tool_result` of the `memory_save` call with the same `call_id`. Only for a new save (a retried operation emits nothing).
- Undo: `POST /catpaw/agent-memory/v1/undo {undo_token}` within 24 h → hard delete. `kind` is never `journal` here.

## memory_recalled (B1)

```json
{"type":"memory_recalled","data":{"ids":["uuid", "…"]}}
```
- Right after `turn_started` (sequence 2), only when at least one memory was injected; 1–26 ids (≤20 profile/pinned within 1.5k tokens + top 6), no duplicates.
- Never sent for temporary turns (`X-Catpaw-Memory-Mode: ephemeral`).

## device_call (B3)

```json
{"type":"device_call","data":{"call_id":"…","tool":"calendar_create","args":{},"confirm":"card|none","ttl_sec":600,"interrupt_id":"uuid","args_hash":"64 hex","expires_at":"ISO 8601"}}
```
- Order: `tool_call` (same call_id) → `device_call` → `turn_suspended` (`interrupt_ids` contains `interrupt_id`).
- `confirm:"none"` only for `calendar_list` and `contacts_search`.
- Answered by `POST …/turns/{t}/device-result {call_id, operation_id, args_hash, status:"ok|cancelled|denied|error", data?}`;
  resolution shows as `approval_resolved{kind:"device", decision:"reported"|"expired"|"cancelled", device_status?}`.
