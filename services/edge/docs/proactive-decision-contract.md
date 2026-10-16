# catpaw.proactive.decision.v1: proactive meeting and travel assistant

This lives in the `catpaw-proactive` edge function. All paths below are under `/functions/v1/catpaw-proactive`. The canonical prefix is `/catpaw/proactive/v1`, and the legacy `/proactive/...` prefix is also accepted. Every route requires the user's Supabase JWT (`Authorization: Bearer`).

The client models are 方块's `ProactiveSuggestion`, `ProactiveFeedback` and `ProactiveSuggestionBackend` (PR #54 / #56).

## Suggestion object
This object is the body of the `proactive_suggestion` SSE event and of the `catpaw-card` card. A suggestion's `id` is the `event_id` that `/evaluate` returns.
```json
{ "id": "uuid", "title": "该出发了", "reason": "why, one sentence",
  "memories": [{"id":"mem-taxi","content":"用户去静安一般打车"}],
  "actions": ["create_reminder","notify_attendees","snooze","dismiss"],
  "signals": [{"kind":"calendar|travel|location|weather|message|custom","text":"客户方案评审 · 35 分钟后 · 静安嘉里中心"}],
  "status": "pending|done|snoozed|dismissed", "createdAt": "ISO-8601",
  "taken": [{"action":"notify_attendees","at":"ISO-8601","detail":"optional"}],
  "decision": "card|notify|interrupt", "confidence": 0.85 }
```
`decision` and `confidence` are extra fields. The client can ignore them, because Codable skips unknown keys.

## Endpoints
| Method and path | Body | Result |
|---|---|---|
| `POST /catpaw/proactive/v1/evaluate` | `{signals[], context}` | `{event_id, suggestion, decision, reason, confidence, used_memories[], suggested_actions[], source, trace[]}` |
| `GET /catpaw/proactive/v1/suggestions[?status=pending&limit=50]` | none | `{suggestions:[Suggestion]}`, newest first, silent decisions excluded |
| `GET /catpaw/proactive/v1/suggestions/{id}` | none | `{suggestion}` |
| `POST …/suggestions/{id}/action` | `{action, operation_id?, detail?, minutes?}` | `{suggestion}` |
| `POST …/suggestions/{id}/undo` | `{operation_id?}` | `{suggestion}`, restored to the previous status |
| `POST …/suggestions/{id}/feedback` | `{value: helpful\|not_helpful\|intrusive}` | `{event_id, kind, applied, weights, memory_id}` |
| `POST /catpaw/proactive/v1/feedback` | `{event_id, kind}` | same as above (legacy form) |
| `GET /catpaw/proactive/v1/events[/{id}]` | none | the full explanation payload |
| `GET /catpaw/proactive/v1/weights` | none | `{weights: {trigger: {weight, threshold_bump}}}` |

### Signals
`{id?, type, source?, at?, dedupe_key?, data}`. `type` is one of `meeting_upcoming`, `meeting_conflict`, `flight_status`, `traffic`, `location`, `calendar_change`, `weather`, `message` or `custom`. There are 1–20 signals per call. The fields the rules read in `data`:
- `meeting_upcoming`: `{title, location, minutes_until, travel_minutes}`
- `flight_status`: `{flight, status, delay_minutes, affects_meeting?, gate_changed?, gate?}`
- `meeting_conflict`: `{a, b, minutes_until}`
- `traffic`: `{extra_minutes}`

You can also pass `data.text` to override the displayed signal text.

### Context
`{time_zone?, focus_mode?, conversation_id?, location?, ...}`, at most 8 KB.

## Pipeline (evaluate)
1. Validate the request.
2. `signal_hash` = sha256(type, source, dedupe_key or the canonical data). If every signal was already seen within `CATPAW_PROACTIVE_DEDUPE_WINDOW_SEC` (default 1800), the result is `silent` with `source=dedupe`.
3. Load the learned trigger weights.
4. Recall memories through the memory port (see "Memory" below).
5. Ask the LLM. The route order comes from catpaw-api's catalog: Gemini first (w6 default), then OpenRouter `:free`, Groq and OpenCode if their keys exist, then Agnes, with `CATPAW_MODEL_ROUTE_ORDER` able to reorder it. Keys are read only from env and are never logged or returned.
   - The model must return a JSON object `{decision, title, reason, confidence, trigger, suggested_actions[], used_memory_ids[]}`.
   - That output is validated. Unknown actions are dropped, `used_memory_ids` are filtered against the recalled ids, and `snooze` and `dismiss` are always appended.
   - If the model is unavailable or its output is invalid, deterministic rules decide instead (`source=rules`).
6. Apply the confidence threshold. `conf = raw × weight` and `threshold = CATPAW_PROACTIVE_CONFIDENCE_THRESHOLD (0.6) + threshold_bump`.
   - Below the threshold, the decision drops one level: interrupt → notify, notify → card.
   - More than 0.15 below, it drops two levels. It never goes below card.
7. Quiet hours (`CATPAW_PROACTIVE_QUIET_HOURS`, the B2 `throttle.mjs`): notify or interrupt becomes card, unless it's an interrupt with conf ≥ 0.9.
8. Daily cap (`CATPAW_PROACTIVE_DAILY_PUSH_CAP`, counting notify and interrupt since local midnight): becomes card once the cap is reached.
9. Write one `proactive.events` row per call (`kind='proactive_decision'`). notify and interrupt rows get `push_state='pending'`, so they go out through the existing push pipeline, which applies the B2 throttle again.

Every step that changed the decision is listed in `trace[]`.

## Explanation payload (stored in events.payload)
`{contract, title, why, proposed, decision, source, trigger, confidence, raw_confidence, threshold, weight, trace[], signals[] (each with signal_hash and duplicate), memories[], actions[], undo{kind, method, path, body_template}, suggestion{status, taken[], history[], ops{}}}`

## Actions
- `create_reminder` and `notify_attendees` are executed **on the phone** (EventKit / MFMessageCompose). The server only records them: status becomes `done` and a `taken` entry is appended.
- `snooze` sets status `snoozed` and `snooze_until` (`minutes`, default 10). `dismiss` sets status `dismissed`.
- Idempotency: the same `operation_id` returns the current state unchanged. Without one, repeating the last action while the status already matches is a no-op.
- `undo` pops one history entry, restoring the previous status and `taken`. It is idempotent per `operation_id`.

## Feedback
Feedback is stored once per event (`proactive.feedback`, PK `event_id`); repeats return `applied:false`. The legacy value `disturbing` is accepted as an alias for `intrusive`. It changes every trigger involved (the main trigger and each signal type):

| value | weight | threshold_bump |
|---|---|---|
| helpful | ×1.05 | −0.02 |
| not_helpful | ×0.85 | +0.05 |
| intrusive | ×0.7 | +0.1 |

Weights are clamped to [0.3, 1.5] and threshold_bump to [−0.1, 0.3]. When a memory port with `save` is present, `not_helpful` and `intrusive` also write a preference memory unless the request sends `save_preference:false`.

## Memory
The port is `{recall(uid, query, k) → [{id, content, kind}], save?(uid, content) → id}`.

B1 (`catpaw.agent-memory.v1`, PR #41) is not on this base branch, and its recall runs inside catpaw-api's process against its own store. So production `catpaw-proactive` currently runs with **no memory port** (`memory: null`, so `used_memories=[]`). Tests and the demo use `memory-recall.mjs`, an in-memory lexical stand-in. Once #41 merges, an adapter that calls its `rank()` (or a pg read of its table) plugs into the same port.

## Storage
The migration file is `supabase/migrations/20261016030000_proactive_decisions.sql`. It is **not applied**. It adds:
- `proactive_decision` to the events kind check
- the `signal_seen`, `trigger_weights` and `feedback` tables, with RLS (owner read; writes only by the service)

## Not done
- catpaw-api does not yet emit the `proactive_suggestion` SSE event into chat. Use `toSuggestion(event)` from `decision.mjs` to build its payload.
- Snoozed suggestions do not yet re-surface automatically.

## Demo
`deno run -A services/edge/scripts/demo-proactive.mjs`. Signals come from `test/fixtures/proactive/meeting-travel-signals.json`. With a model key in env the real LLM decides; without one the rules decide. Contract tests: `deno test -A services/edge/test/proactive-decision.test.mjs`.
