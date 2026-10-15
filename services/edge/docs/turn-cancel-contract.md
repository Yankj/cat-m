# Turn cancel — client contract (catpaw.native-chat.v1)

`POST /functions/v1/catpaw-api/catpaw/chat/v1/scopes/{scope_id}/conversations/{conversation_id}/turns/{turn_id}/cancel`

- Headers: `Authorization: Bearer <session JWT>`, `apikey: <publishable key>`.
- Body: empty or exactly `{}` (anything else → 422 `schema_invalid`).
- Idempotent: safe to resend any number of times (retry on network error / unknown outcome).

## Response 200

```json
{"schema_version":1,"contract":"catpaw.native-chat.v1",
 "cancel":{"turn_id":"…","state":"failed","cancelled":true,"already_terminal":false}}
```

| case | state | cancelled | already_terminal |
|---|---|---|---|
| running turn, this call cancelled it | `failed` | `true` | `false` |
| repeat of a successful cancel | `failed` | `true` | `true` |
| turn had already completed | `completed` | `false` | `true` |
| turn had already failed for another reason | `failed`/`outcome_unknown` | `false` | `true` |

Errors: 404 `not_found` (unknown turn, other user's turn, wrong conversation/scope), 401/403 as for other chat routes, 422 `schema_invalid`.

## Event stream

The open SSE stream of the turn (`POST …/turns` or `GET …/turns/{t}/events`) ends with

```json
{"type":"turn_failed","data":{"code":"cancelled","retryable":false,"reconciliation_required":false,
 "partial_text_hash":"<sha256 of committed text>","partial_text_length":123}}
```

and then closes. No further `text_delta`/`reasoning_summary` events follow it.

## Client rules

1. Treat `turn_failed` with `code=="cancelled"` as a user stop: keep the text already shown (all `text_delta`
   events before it are durable; `GET …/turns/{t}` returns them), show it as interrupted, no error banner,
   no automatic resend.
2. The SSE `turn_failed` event and the cancel response are equivalent; whichever arrives first wins.
   If the stream already dropped, `GET …/turns/{t}` shows `state:"failed"`, `error.code:"cancelled"`.
3. A cancel racing completion can return `cancelled:false, state:"completed"`: show the completed answer.
4. Text that the model produced but the server had not yet committed when cancel landed is discarded;
   the committed prefix is identified by `partial_text_length` / `partial_text_hash`.
5. The conversation stays `active`; the next message is a normal new turn (use the conversation's current
   `revision`/`grant_epoch` from `GET …/conversations/{c}`).

## Server behaviour (for reference)

- The cancel commits `state:"failed"` + `turn_failed{cancelled}` on the existing `native-chat-turns`
  record under the conversation lock (`cancel_requested_at` marker). No new table or column.
- Same instance: the turn's AbortController is aborted immediately (model HTTP request cancelled).
- Other instance: the executor polls its turn row every 1.5 s and aborts on any non-running state; any
  write it attempts after the marker is fenced (`live()` requires `state=="running"`).
