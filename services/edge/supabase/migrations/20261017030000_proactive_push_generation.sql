-- Codex PR90f #4: delivery generation + claim token + lease. NOT APPLIED automatically (needs approval).
-- Requires 20261017020000_proactive_push_sending.sql. Runs in the migration transaction; lock waits are bounded.
-- Rollback: drop the columns only after the old code is back (it ignores them); move 'sending' rows to 'pending' first.
set local lock_timeout = '5s';
alter table proactive.events
  add column if not exists push_generation int not null default 0,   -- bumped whenever a row is re-armed / recovered
  add column if not exists push_claim uuid,                          -- the send licence of the current generation
  add column if not exists push_claimed_at timestamptz,              -- lease start
  add column if not exists push_attempted_at timestamptz,            -- APNs was called under this claim (outcome unknown if it crashes)
  add column if not exists push_recovered text;                      -- 'unsent' | 'unknown' after a lease recovery
create index if not exists events_push_sending_idx on proactive.events(push_claimed_at) where push_state = 'sending';

-- Snooze expiry re-arms a remote push as a NEW generation: any claim of the previous round can no longer complete.
create or replace function proactive.resurface_snoozed_suggestions(p_now timestamptz default now())
returns setof uuid language sql security definer set search_path = proactive, pg_temp as $$
  update proactive.events e set
    payload = jsonb_set(e.payload, '{suggestion}', ((e.payload->'suggestion') - 'snooze_until' - 'chat_delivered_at')
      || jsonb_build_object('status', 'pending', 'resurfaced_at', p_now, 'rev', coalesce((e.payload->'suggestion'->>'rev')::int, 0) + 1)),
    push_state = case when e.payload->>'decision' in ('notify','interrupt') and e.payload->>'delivery' = 'remote' then 'pending' else e.push_state end,
    push_generation = case when e.payload->>'decision' in ('notify','interrupt') and e.payload->>'delivery' = 'remote' then e.push_generation + 1 else e.push_generation end,
    push_claim = case when e.payload->>'decision' in ('notify','interrupt') and e.payload->>'delivery' = 'remote' then null else e.push_claim end,
    push_after = null
  where e.kind = 'proactive_decision' and e.payload->'suggestion'->>'status' = 'snoozed'
    and (e.payload->'suggestion'->>'snooze_until')::timestamptz <= p_now
  returning e.id;
$$;
revoke all on function proactive.resurface_snoozed_suggestions(timestamptz) from public, anon, authenticated;
grant execute on function proactive.resurface_snoozed_suggestions(timestamptz) to service_role;
