# Edge deploy checklist (catpaw-api + catpaw-proactive)

Project ref `dbyklgxdvjbutxzsjeth`. The user runs every step that writes to production. Agents only read: `list_tables` and `list_migrations`.

## 0. Production state (read-only check, 2026-10-15 22:0x UTC+8)

- **Tables:** only `public.records` exists. There is **no `proactive` schema**.
- **Migrations applied:** catpaw_foundation_server_only, catpaw_trigger_search_path, catpaw_runtime_role, catpaw_application_auth_reader, chat_attachments_bucket.

## 1. Database (pending; in this order)

1. **Enable extensions:** turn on `pg_cron` and `pg_net` in Dashboard > Database > Extensions. They are needed by step 3.
2. **`20261015120000_proactive_tasks.sql`:**
   - Creates the `proactive` schema and the `tasks`, `reminder_occurrences`, `events` and `device_push_tokens` tables.
   - Adds RLS policies and the `claim_due_reminders()` function.
3. **`20261015120100_proactive_cron.sql`:** schedules `catpaw-proactive-tick` every minute through pg_cron and pg_net. Its Vault secrets (step 4) must exist first.
4. **Vault secrets** (SQL editor):
   - `select vault.create_secret('https://dbyklgxdvjbutxzsjeth.supabase.co','catpaw_project_url');`
   - `select vault.create_secret('<SECRET>','catpaw_scheduler_secret');`
5. **`20261015150000_proactive_task_tools_runtime.sql`** (A2):
   - Grants `catpaw_records` (the catpaw-api dedicated login role) USAGE on the schema, select/insert/update on `proactive.tasks`, and select/insert on `proactive.events`.
   - Adds RLS policies for that role.
   - Without this migration, in-process task tools fail with `tool_failed`, which reaches the model as a `tool_result{status:'error'}`.

Apply with `supabase link --project-ref dbyklgxdvjbutxzsjeth && supabase db push` from `services/edge`. Then confirm with `list_migrations`.

## 2. Secrets

- `supabase secrets set CATPAW_SCHEDULER_SECRET=<SECRET>`. Use the same value as the Vault secret. It is required by catpaw-proactive.
- `CATPAW_PRIVATE_MODEL_KEY` already exists and is reused for reminder text. Optional fallback: `OPENROUTER_API_KEY`.
- **APNs**, only once the key exists: `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_BUNDLE_ID`, `APNS_PRIVATE_KEY`.
- **A2 switch for catpaw-api:** `CATPAW_PROACTIVE_TOOLS_ENABLED=true`. Set it only after step 1.5. Until it is set, catpaw-api offers no task tools.

## 3. Functions

- **catpaw-proactive:** `supabase functions deploy catpaw-proactive --no-verify-jwt`. Then check `curl …/functions/v1/catpaw-proactive/health`.
  - Push tokens are owned **only** by catpaw-proactive: `PUT` and `DELETE /devices/tokens`. iOS `CatpawPushTokenUploader` already targets this endpoint.
- **catpaw-api:** deploy as usual. It contains the A1 approval contract and the A2 task tools (inactive until the switch in section 2 is set).

## 4. Verify

- **Approval contract**, on a new iOS build or with curl:
  - `create_task` produces `approval_requested` and then `turn_suspended`.
  - A `decision` of `approve` produces `tool_result{status:'ok'}` and a row in `proactive.tasks` with `created_by='agent'`.
- **Scheduler:** `proactive.events` gets a `reminder_due` row when a task falls due.
- **Rollback:**
  - Unset `CATPAW_PROACTIVE_TOOLS_ENABLED`. Task tools disappear and A1 is unaffected.
  - To stop the scheduler, run `select cron.unschedule('catpaw-proactive-tick')`.
