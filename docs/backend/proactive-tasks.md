# Proactive tasks & reminders backend (`catpaw-proactive`)

Status: draft, offline + real-Postgres tested; **not deployed**. Additive: new `proactive` schema and a new Edge function. It does not touch `public.records`, `catpaw.*`, or `catpaw-api` (owned by the conversation workstream).

## Pieces
| Piece | Path |
|---|---|
| Schema + RLS + claim function | `services/edge/supabase/migrations/20261015120000_proactive_tasks.sql` |
| pg_cron every minute → scheduler | `services/edge/supabase/migrations/20261015120100_proactive_cron.sql` |
| Edge entry | `services/edge/supabase/functions/catpaw-proactive/index.ts` |
| Service / routes / scheduler | `_shared/proactive/service.mjs` |
| Validation + **agent tool contract** | `_shared/proactive/contract.mjs` (`catpaw.task-tools.v1`) |
| Recurrence (wall-clock, DST-safe) | `_shared/proactive/recurrence.mjs` |
| Reminder text via OpenRouter free route | `_shared/proactive/model.mjs` (same `route` + `CATPAW_PRIVATE_MODEL_KEY` as catpaw-api) |
| APNs sender (alert + Live Activity) | `_shared/proactive/apns.mjs` — inactive until APNS secrets exist |
| Stores | `pg-store.mjs` (prod), `memory-store.mjs` (tests) |
| Tests | `services/edge/test/proactive-tasks.test.mjs`, `proactive-tasks-pg.test.mjs` |

## Tables (`proactive` schema)
- `tasks`: user_id, conversation_id, source_turn_id, operation_id (idempotency, unique per user), title, notes, due_at, time_zone, recurrence jsonb, status `open|done|cancelled|snoozed`, remind_lead_seconds, snooze_until, next_fire_at (scheduler cursor), fire_count, created_by `user|agent`, revision (auto +1 on update).
- `reminder_occurrences`: (task_id, scheduled_at) PK → each occurrence fires exactly once even with concurrent ticks.
- `events`: proactive outbox / in-app feed. kind `reminder_due|task_created|task_updated|agent_message`, title, body, payload, dedupe_key, push_state `pending|sent|skipped|failed|no_device`, read_at.
- `device_push_tokens`: kind `apns|live_activity_update|live_activity_start`, token(hex), environment `sandbox|production`, bundle_id, activity_id.
- RLS: every table `user_id = auth.uid()` for role `authenticated` (anonymous-auth users are `authenticated` with `is_anonymous=true`, so they work unchanged). Events are read-only to clients except `read_at`. `claim_due_reminders()` is service-role only.

Recurrence: `{"freq":"daily|weekly|monthly","interval":1}` keeps local wall time in `time_zone` (DST-safe, month-end clamped), or `{"freq":"interval","interval_seconds":>=300}`; optional `until`, `count`.

## HTTP API — `https://<project>.supabase.co/functions/v1/catpaw-proactive`
All user routes: `Authorization: Bearer <Supabase access token>` (anonymous OK). JSON errors `{error:"code"}`.
| Method/path | Notes |
|---|---|
| `GET /health` | no auth; shows whether model/APNs configured |
| `GET /tools` | tool definitions for the chat model |
| `GET /tasks?status=open\|done\|cancelled\|snoozed\|all&limit=` | |
| `POST /tasks` | `{operation_id(uuid), title, notes?, due_at?(ISO w/ offset), time_zone?, recurrence?, remind_lead_seconds?, conversation_id?, source_turn_id?}` → 201 new / 200 replay |
| `GET/PATCH/DELETE /tasks/:id` | PATCH `{expected_revision?, title?, notes?, due_at?, status?, recurrence?, snooze_until?}`; 409 `revision_conflict`; DELETE = cancel |
| `POST /tools/execute` | `{call:{name, arguments}, context:{conversation_id, turn_id, operation_id}}` → tool result JSON |
| `GET /events?after=<iso>&limit=` | proactive feed (ascending) |
| `POST /events/:id/read` | |
| `PUT /devices/tokens` | `{device_id, kind, token, environment, bundle_id, activity_id?}` upsert |
| `DELETE /devices/tokens` | `{device_id, kind?}` |
| `POST /scheduler/tick` | header `x-catpaw-scheduler-secret`; called by pg_cron |

Tick: claim due tasks (`FOR UPDATE SKIP LOCKED` + occurrence PK) → generate 1–2 sentence Chinese reminder with the free model (template fallback on any model error) → insert `reminder_due` event (dedupe `due:<task>:<scheduled_at>`) → advance `next_fire_at` per recurrence → fan out pending events to APNs (no token → `no_device`; no key → `skipped`; 410/BadDeviceToken disables token).

## Agent tool contract (for the `catpaw-api` dispatcher)
1. Add `TASK_TOOLS` (import from `_shared/proactive/contract.mjs`, or `GET /tools`) to the model request `tools`. Add to system prompt: user time zone + current local time, "use create_task when the user asks to be reminded".
2. When the model emits a tool call, run in-process (preferred, same deploy bundle):
   ```js
   import { createProactiveService } from '../_shared/proactive/service.mjs';
   import { createPgStore } from '../_shared/proactive/pg-store.mjs';
   const proactive = createProactiveService({ store: createPgStore(sql), verifyUser: async () => ({}) /* unused in-process */ });
   const result = await proactive.executeTool(subjectId /* Supabase auth user id */, { name, arguments }, { conversation_id, turn_id, operation_id: deterministicUUID(turn_id + tool_call_id) });
   ```
   or over HTTP: `POST /tools/execute` forwarding the user's bearer token.
3. `operation_id` must be deterministic per (turn, tool_call) so retry-busy / resume never duplicates a task.
4. Emit existing `toolStarted` / `toolResult` SSE events with `result` = the returned JSON (`{ok, created, task:{id,title,due_at,status,next_fire_at,revision}}` or `{ok:false,error}`); feed it back to the model for the final answer.
5. Proactive messages: the scheduler writes `events` with `conversation_id`. The conversation timeline should merge `reminder_due` events for that conversation (or the iOS app shows them as assistant "proactive" bubbles from `GET /events`). Writing directly into `native-chat-turns` records is intentionally **not** done here.

## iOS integration
- On launch / foreground: `GET /events?after=<last seen>` → proactive cards (actions in `payload.actions`: `done`, `snooze_10m`, `snooze_1h`, `open_conversation` → map to `PATCH /tasks/:id`).
- Tasks screen: `GET /tasks`, swipe to done/cancel (`PATCH`), always send `expected_revision`.
- Push: after `registerForRemoteNotifications`, `PUT /devices/tokens {kind:"apns", token:<hex>, environment:"sandbox"(debug)/"production", bundle_id}`. Live Activity: `pushTokenUpdates` → `kind:"live_activity_update", activity_id`. Notification category `CATPAW_REMINDER`; `userInfo.catpaw = {event_id, task_id, conversation_id, kind}`. Live Activity `content-state` = `{title, body, kind, taskID}` — make the ActivityAttributes.ContentState match.

## Deploy (user runs; needs Supabase CLI login + project ref `dbyklgxdvjbutxzsjeth`)
```bash
cd services/edge
supabase link --project-ref dbyklgxdvjbutxzsjeth
supabase db push                       # applies both migrations (pg_cron/pg_net must be enabled: Dashboard > Database > Extensions)
SECRET=$(openssl rand -hex 32)
supabase secrets set CATPAW_SCHEDULER_SECRET=$SECRET
# CATPAW_PRIVATE_MODEL_KEY (OpenRouter) is already used by catpaw-api; reuse it. Optional fallback: OPENROUTER_API_KEY
supabase functions deploy catpaw-proactive --no-verify-jwt
# Vault secrets read by pg_cron (SQL editor):
#   select vault.create_secret('https://dbyklgxdvjbutxzsjeth.supabase.co','catpaw_project_url');
#   select vault.create_secret('<same $SECRET>','catpaw_scheduler_secret');
curl https://dbyklgxdvjbutxzsjeth.supabase.co/functions/v1/catpaw-proactive/health
```
Later, when the APNs key exists:
```bash
supabase secrets set APNS_KEY_ID=XXXXXXXXXX APNS_TEAM_ID=XXXXXXXXXX APNS_BUNDLE_ID=<app bundle id> \
  APNS_PRIVATE_KEY="$(cat AuthKey_XXXXXXXXXX.p8)"
```
Secrets: `CATPAW_SCHEDULER_SECRET` (required), `CATPAW_PRIVATE_MODEL_KEY` (existing; without it reminders use template text), `SUPABASE_URL`/`SUPABASE_DB_URL` (auto-provided), optional `CATPAW_PROACTIVE_DATABASE_URL` override, `APNS_KEY_ID/APNS_TEAM_ID/APNS_BUNDLE_ID/APNS_PRIVATE_KEY` (push).

## Tests
```bash
cd services/edge
deno test -A --config supabase/functions/deno.json test/proactive-tasks.test.mjs
# real Postgres (local scratch DB; stub of auth schema/roles in test/fixtures/supabase-stub.sql):
psql "$URL" -f test/fixtures/supabase-stub.sql -f supabase/migrations/20261015120000_proactive_tasks.sql
CATPAW_PG_TEST_URL="$URL" deno test -A --config supabase/functions/deno.json test/proactive-tasks-pg.test.mjs
```
Not yet verified: hosted deploy, pg_cron on hosted DB, live OpenRouter reminder call, real APNs delivery.

## Interruption guard (B2, migration 20261016013000_proactive_push_throttle.sql)
- Quiet hours (`CATPAW_PROACTIVE_QUIET_HOURS`, default `22-8`, `off` disables), evaluated in the event's task time zone (default Asia/Shanghai). Agent/proactive pushes inside the window get `push_after` = window end and are coalesced into one push ("小猫有 N 条消息") when released.
- Daily cap (`CATPAW_PROACTIVE_DAILY_PUSH_CAP`, default 5) counts `push_state='sent'` since local midnight; over-cap events stay in the in-app feed with `push_error='daily_cap'`.
- Exempt: `reminder_due` for user-created tasks (the user chose that time).

## Push (B4, stub until APNs key arrives; migration 20261016020000_proactive_push_actions.sql)
- Sender activates only when `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_PRIVATE_KEY` (.p8 PEM), `APNS_BUNDLE_ID` are all set (env/Supabase secrets; never logged). Otherwise events get `push_state='skipped'`, `push_error='apns_not_configured'` and stay in the in-app feed; `/health` reports `apns:false`.
- Token env chooses sandbox/production host; 410 / BadDeviceToken / Unregistered disables the token.
- `POST /push/test` (auth): queue + send a test push to the caller; returns `state` = sent | no_device | apns_not_configured | failed.
- `POST /push/action` (auth) `{event_id, action: open|done|snooze_10m|snooze_1h|dismiss}`: records the tap once (`action`, `opened_at`), `done` closes the task, `snooze_*` reschedules it. Approval write-back from notification buttons is not wired yet (approvals live in catpaw-api).
- Token registration stays `PUT/DELETE /devices/tokens` only.
