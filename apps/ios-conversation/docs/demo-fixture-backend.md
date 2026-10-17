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

## Script (same domain path as the HTTP backend)

Every message runs:

| step | events |
|---|---|
| send | `turn_started` → `text_delta` → `tool_call create_task` → `approval_requested` → `turn_suspended` |
| `submitApproval` approve / deny | `approval_resolved` → `tool_result create_task {ok｜denied}` → `.uiBlock` card, list, progress, choices (waits) → `turn_suspended` |
| `submitUIDecision` choices | `approval_resolved(kind ui)` → `.uiBlockResolve` → `.uiBlockUpdate` progress → `.uiBlock` form, confirm, sheet → `turn_suspended` |
| `submitUIDecision` form / confirm / sheet (any order) | resolve each; after the last: `text_delta` → `turn_completed` |

The app answers through the real service API:

```swift
let blocks = try await service.pendingUIBlocks(scope: scope, conversationID: cid)   // [ConversationUIEvent]
try await service.submitUIDecision(scope: scope, conversationID: cid, turnID: turnID,
    interruptID: blocks[0].interruptID!, decision: .submit, argsHash: blocks[0].argsHash!,
    response: Data(#"{"type":"ui.response","blockId":"demo-choices","actionId":null,"values":{},"selected":["a"],"respondedAt":"2026-10-16T00:10:00Z"}"#.utf8))
```

Errors are `ConversationApprovalFailure`; show `friendlyMessage`.
Same `operationID` replays; another operation on an answered block is `.consumed`; bad body is `.rejected(422, "ui_response_invalid")`; wrong `argsHash` is `.stale`.

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

`Scripts/test-demo-fixture.sh` (macOS, swiftc with `-D DEBUG`; run from anywhere) decodes the recorded jsonl with `ConversationUIEvent.decode` and drives `ConversationSessionService` with the demo backend. It checks:

- the switch;
- every recorded ui kind, update and resolve decodes; malformed events are rejected;
- approval → ui round 1 → choices → round 2 → partial answers in any order → completed;
- stale / invalid / consumed errors and their friendly messages;
- the journal (`ConversationTurnRecord.uiEvents`) survives reopening from disk, ordered and unique by sequence.
