# Demo / fixture backend (DEBUG only)

Lets you exercise approval.v1, `create_task` and every catpaw.ui.v1 block without a model, a server or a production database.
It is compiled only in DEBUG (`#if DEBUG`) and never ships in Release.

## Turning it on

Pick one:

- **Launch argument:** Xcode → Scheme → Run → Arguments → add `-CatpawDemoBackend`.
- **UserDefaults:** `defaults write <bundle id> CatpawDemoBackend -bool YES` (Simulator: `xcrun simctl spawn booted defaults write <bundle id> CatpawDemoBackend -bool YES`).
  Turn it off with `defaults delete <bundle id> CatpawDemoBackend`.

When it is on, `NativeAuthApplicationModel` hands `CatpawDemoConversationBackend.shared` to `ConversationSessionService` in place of the HTTP backend.
Sign-in and local storage still work as usual. Only chat turns are scripted.

## Domain script (`CatpawDemoConversationBackend`)

Every message you send runs the same script:

| step | events |
|---|---|
| send | `turn_started` → `text_delta` → `tool_call create_task` → `approval_requested` (risk `local_write`, `rememberAllowed` true) → `turn_suspended` |
| approve / approve_always | `approval_resolved approved` → `tool_result create_task {status:"ok", task}` → `text_delta` → `turn_completed` |
| deny | `approval_resolved denied` → `tool_result {status:"denied"}` → `text_delta` → `turn_completed` |

The decision goes through `submitApproval`, so the approval card exercises the real flow:

- `args_hash` must match; otherwise the call fails with `.stale`.
- Repeating the same `operationID` and decision replays the result.
- Any other decision fails with `.consumed`.
- Stop/cancel works.

## catpaw.ui.v1 script (`CatpawDemoConversationBackend.shared.ui`)

The domain event enum has no `ui.*` cases yet.
Until the UI layer adds them, it reads the script directly:

```swift
let ui = CatpawDemoConversationBackend.shared.ui
var events = await ui.start()        // round 1: ui.block card, list, progress, choices (+interruptId/argsHash/expiresAt) → turn_suspended
events += try await ui.respond(blockID: "demo-choices", decision: .submit,
    responseJSON: #"{"type":"ui.response","blockId":"demo-choices","actionId":null,"values":{},"selected":["a"],"respondedAt":"2026-10-16T00:10:00Z"}"#,
    operationID: UUID())             // approval_resolved + ui.block.resolve, then round 2: ui.block.update(progress), form, confirm, sheet → turn_suspended
// answer demo-form / demo-confirm / demo-sheet in any order (partial answers are accepted). After the last one: turn_completed
```

Each `CatpawDemoUIEvent` has `type`, `sequence` and `json`.
`json` is the event's `data` object, byte-for-byte in the server's shape.

- **Decisions:**
  - `.submit` takes a `ui.response`.
  - `.reportError` takes a `ui.error`.
  - `.dismiss` takes nil.
- **Errors:**
  - Same `operationID` and body: replays the result.
  - Same `operationID`, different body: `.conflict`.
  - Another `operationID` for a block already answered: `.consumed`.
  - Malformed body, or a `confirm` without `actionId`: `.invalidResponse`.

## Recorded SSE (wire level)

`services/edge/docs/fixtures/catpaw-ui-demo.jsonl` is the same session recorded from the real Edge chat service.
It contains the full SSE envelopes plus the client decision requests in between, with ids and timestamps normalised.
Use it for parser and decoder tests.

`services/edge/test/generative-ui-demo-recording.test.mjs` fails if the server output drifts from the recording.
To re-record:

```sh
cd services/edge
CATPAW_RECORD_UI_DEMO=1 deno test --no-check --allow-read --allow-write=docs/fixtures --allow-env \
  --config supabase/functions/deno.json test/generative-ui-demo-recording.test.mjs
```

## Tests

`Scripts/test-demo-fixture.sh` (macOS, swiftc with `-D DEBUG`) checks:

- the switch;
- approval/create_task resume and idempotency;
- every ui kind, the update, the four resolves and decision replay.
