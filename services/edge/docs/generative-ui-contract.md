# catpaw.ui.v1 — generative UI and HITL blocks

Status: backend implemented behind `CATPAW_GENERATIVE_UI_ENABLED` (default **off**). Sources of truth:
r10 spec §4 (`catpaw-design/r10/spec.md`) and the Codable draft in PR #35 (`GenerativeBlock`, `GenerativeBlockPatch`,
`GenerativeBlockResponse`, `GenerativeBlockError`). Transport reuses `catpaw.approval.v1` (approval-contract.md):
suspend, resume, decision endpoint, expiry and idempotency. No table, column or migration.

## 0. Review of the PR #35 draft (for 方块 / Grok Bot)

### Agreed
- Tool `render_ui({block})` with the r10 §4.1 schema, camelCase keys; server also accepts a bare block.
- Kinds `card · choices · confirm · form · sheet · list · progress`; the r10 limits (title ≤60, body ≤600 markdown,
  items/fields ≤8, actions ≤3, item label ≤40, action label ≤16, https images, payload ≤32 KB).
- Events `ui.block` (data = block), `ui.block.update` (`{id,title?,body?,items?,actions?,steps?,expiresAt?}`,
  shallow patch by id), `ui.block.resolve` (`{id,status}`).
- `schemaVersion` (int, default 1). The server always stamps `schemaVersion:1` and rejects other values from the model;
  the client rejecting a higher version and degrading to a card is right.
- `progress.steps[{id,label,state:pending|running|done|failed}]` ≤12, updated through `ui.block.update`.
- `sheet.content` (default form if fields, choices if items, else card). Agreed; the server also uses it to decide
  whether the sheet waits for an answer.
- `ui.response.other` for `allowOther`, mirrored into `values.other` (server checks they are equal).
- `ui.response.respondedAt` (ISO-8601) — kept as client-reported metadata only; the server's `decided_at` is authoritative.
- `ui.error` codes as listed in the PR; degrade to a card, never show raw JSON.

### Changes proposed (and implemented this way on the server)
1. **Return path: not "a tool result of the next turn", but the approval.v1 decision on the SAME turn.**
   The model's `render_ui` call must get its tool result in the same assistant round (provider tool-calling
   protocol); answering on the next turn leaves a dangling call, needs a synthetic user turn, re-sends history,
   and has no idempotency/expiry. approval.v1 already has exactly this machinery (paused round checkpoint,
   `interrupts/{i}/decision`, `operation_id` idempotency, 10 min lazy expiry, cancel, args_hash staleness).
   So an interactive block **is** an interrupt (`kind:'ui'`) and `ui.response` is the decision body's `response`.
   The model still "sees it as the tool result" — of the same call, in the same turn.
   Unified, not two systems: real tool approvals (create_task etc.) keep `approval_requested` + `approve|deny`,
   and the client renders them with the confirm look (#30 ConversationApprovalHost); a model-level `confirm` block
   is a ui interrupt with `actionId`.
2. **Server linkage on `ui.block`:** interactive blocks carry `interruptId`, `argsHash`, `expiresAt` (min of the
   model's `expiresAt` and server TTL). Codable should decode them as optional extra fields.
3. **`ui.error` travels as `decision:"report_error"`** with `response:{type:"ui.error",blockId?,code,path?}` on an
   interactive block; the model receives `{status:'error',error}` and can call render_ui again.
   Errors on display-only blocks have no channel back (nothing is waiting); report them only to client logs.
4. **Which blocks wait:** choices, confirm, form (and sheet with that content) always; card/list only when they have
   `actions`; progress never; `choices` with `selection:'none'` and no actions never.
5. **Confirm response:** `actionId` is required (`approve`/`deny` or one of `actions[].id`).
6. **Update scope:** `ui.block.update` is emitted when the model re-renders an existing display-only block id
   in the same turn (e.g. progress). Interactive blocks cannot be patched (their args_hash is the stale check).
7. **Security:** markdown body is untrusted (no HTML, links shown with host); `image` https only and should be
   fetched without cookies; block text is never treated as instructions; `respondedAt` is not trusted for ordering.
   The response is validated server-side against the frozen block (exact keys, types, option ids) before the model sees it.

## 1. Negotiation
- `POST …/turns` with `X-Catpaw-Approval-Contract: catpaw.approval.v1` **and** `X-Catpaw-UI-Contract: catpaw.ui.v1`.
- Other UI values → 422 `ui_contract_invalid`. Without either header or with the gate closed, `render_ui` is not offered.
- Gate: `CATPAW_GENERATIVE_UI_ENABLED=true|allowlist|off` (+ `CATPAW_FEATURE_ALLOWLIST_SUBJECTS`), see feature-gates.md.
- System prompt adds: "需要用户选择、确认、填写或查看结构化结果时调用 render_ui；不要输出 HTML/SwiftUI/JSON 代码来表示界面，除非用户明确要代码。"

## 2. Block (render_ui `{block}`; full schema `renderUISchema` in core/src/generative-ui.mjs)
`{schemaVersion?:1, id, kind, title?, body?, presentation?:inline|sheet, image?, items?[{id,label,detail?,icon?}],
selection?:single|multiple|none, allowOther?, fields?[{id,type,label,placeholder?,required?,options?[string],default?}],
actions?[{id,label,style?:primary|secondary|destructive}], steps?[{id,label,state}], content?, expiresAt?}`
Field types: text(≤200) multiline(≤2000) number date(YYYY-MM-DD) time(HH:mm) datetime(ISO) toggle select(option string) stepper(int).

## 3. Events (same envelope, continuous `sequence`)
| type | data |
|---|---|
| `ui.block` | the block (+ `interruptId`, `argsHash`, `expiresAt` when interactive) |
| `ui.block.update` | `{id, title?, body?, items?, actions?, steps?, expiresAt?}` |
| `ui.block.resolve` | `{id, status: submitted|dismissed|errored|expired|cancelled}` |
| `turn_suspended` | after an interactive `ui.block` (approval.v1) |
| `approval_resolved` | `{…, kind:'ui', decision:<status>}` precedes `ui.block.resolve` |

Order: `tool_call(render_ui)` → `ui.block` → (interactive) `turn_suspended` … decision … `approval_resolved` →
`ui.block.resolve` → `tool_result` → model text → `turn_completed`. Display-only: `ui.block|ui.block.update` →
`tool_result{result:{status:'shown'}}`. Snapshot `GET …/turns/{t}`: `pending_approvals[i].kind='ui'`, `.block`.

## 4. Decision (`POST …/turns/{t}/interrupts/{interruptId}/decision`)
```json
{"operation_id":"<uuid>","decision":"submit","args_hash":"<argsHash>",
 "response":{"type":"ui.response","blockId":"…","actionId":null,"values":{},"selected":["a"],"other":"…","respondedAt":"ISO"}}
{"operation_id":"<uuid>","decision":"dismiss","args_hash":"<argsHash>"}
{"operation_id":"<uuid>","decision":"report_error","args_hash":"<argsHash>","response":{"type":"ui.error","blockId":"…","code":"too_long","path":"items[0].label"}}
```
Response rules: `blockId` = block id; `values` only declared field ids (+`other` with allowOther), required form fields
present, types as declared; `selected` ⊆ item ids, single → exactly one (or `other`), multiple → ≥1; confirm needs `actionId`;
card/list need `actionId` or `selected`.
Success 200 SSE (same turn, after N). Errors: 422 `approval_schema_invalid` · 422 `ui_response_invalid` · 404 ·
409 `approval_expired|approval_consumed|approval_stale|approval_grant_conflict|approval_operation_conflict`.
Model tool result: `{status:'submitted',response}` · `{status:'dismissed'|'expired'|'cancelled'}` · `{status:'error',error}` · `{status:'shown'}`.

## 5. Idempotency, expiry, safety
- Same `operation_id` + same body (incl. response) replays; different body → 409. Interrupt id = stableUUID(turn:call:ui).
- TTL 10 min (or the model's earlier `expiresAt`); lazy expiry → `expired` → model is told the user did not answer.
- Cancel resolves pending ui interrupts as `cancelled`. Image, accepted-work and revision turns never get render_ui.

## Server limits and ordering (verified against `test/generative-ui-demo-recording.test.mjs`)

- A turn has at most **3 model rounds**, and a round has at most **4 tool calls**. Past either limit the turn fails with `model_step_limit` or `duplicate_tool_call`. The prompt should ask the model to merge blocks rather than emit one block per round.
- In a round that suspends, display-only blocks (card/list/progress, plus `ui.block.update`) are sent **before** `turn_suspended`, not after the user answers.
- A round with several interactive blocks emits one `turn_suspended` carrying every `interrupt_ids`. The client may answer them in any order. A partial answer returns `approval_resolved` + `ui.block.resolve` and leaves the turn suspended. The model resumes only once the last one is answered.
- Recorded wire session: `docs/fixtures/catpaw-ui-demo.jsonl`.
