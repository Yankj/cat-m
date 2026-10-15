-- Proactive suggestions runtime: snooze re-surface (pg_cron), chat SSE delivery, Idempotency-Key store. Additive.
-- Requires 20261015120000, 20261015120100 (pg_cron/pg_net), 20261015150000, 20261016030000. NOT APPLIED automatically.

-- 1) Snoozed suggestions come back when snooze_until passes. The SQL function runs every minute from its own cron job
--    (no edge hop needed); catpaw-proactive /scheduler/tick also calls it (idempotent).
create or replace function proactive.resurface_snoozed_suggestions(p_now timestamptz default now())
returns setof uuid language sql security definer set search_path = proactive, pg_temp as $$
  update proactive.events e set
    payload = jsonb_set(e.payload, '{suggestion}', ((e.payload->'suggestion') - 'snooze_until' - 'chat_delivered_at') || jsonb_build_object('status', 'pending', 'resurfaced_at', p_now)),
    push_state = case when e.payload->>'decision' in ('notify','interrupt') then 'pending' else e.push_state end,
    push_after = null
  where e.kind = 'proactive_decision' and e.payload->'suggestion'->>'status' = 'snoozed'
    and (e.payload->'suggestion'->>'snooze_until')::timestamptz <= p_now
  returning e.id;
$$;
revoke all on function proactive.resurface_snoozed_suggestions(timestamptz) from public, anon, authenticated;
grant execute on function proactive.resurface_snoozed_suggestions(timestamptz) to service_role;
create index if not exists events_snoozed_idx on proactive.events(((payload->'suggestion'->>'snooze_until')))
  where kind = 'proactive_decision' and payload->'suggestion'->>'status' = 'snoozed';
select cron.unschedule(jobid) from cron.job where jobname = 'catpaw-proactive-resurface';
select cron.schedule('catpaw-proactive-resurface', '* * * * *', $cron$ select count(*) from proactive.resurface_snoozed_suggestions(now()); $cron$);

-- 2) catpaw-api claims pending suggestions into the next chat turn (proactive_suggestion SSE).
grant update (payload) on proactive.events to catpaw_records;
drop policy if exists events_catpaw_api_claim on proactive.events;
create policy events_catpaw_api_claim on proactive.events for update to catpaw_records
  using (kind = 'proactive_decision') with check (kind = 'proactive_decision');
create index if not exists events_chat_pending_idx on proactive.events(user_id, created_at)
  where kind = 'proactive_decision' and payload->'suggestion'->>'status' = 'pending';

-- 3) Idempotency-Key replay store for /catpaw/proactive/v1 POST routes (S1).
create table if not exists proactive.idempotency_keys (
  user_id uuid not null references auth.users(id) on delete cascade,
  key text not null check (char_length(key) between 8 and 200),
  route text not null, request_hash text not null, status integer not null, response jsonb not null,
  created_at timestamptz not null default now(),
  primary key (user_id, key)
);
alter table proactive.idempotency_keys enable row level security;   -- service role only, no client policy
grant all on proactive.idempotency_keys to service_role;
-- optional cleanup: delete from proactive.idempotency_keys where created_at < now() - interval '7 days';
