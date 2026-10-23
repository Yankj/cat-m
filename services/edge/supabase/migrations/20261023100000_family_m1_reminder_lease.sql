-- M1 REM-01/02: reminder occurrence claims become leases. A 'claimed' occurrence older than 15 minutes
-- (worker lost after claim) is claimable again; 'generated' occurrences are final. Expired leases are
-- considered before the limit, so an abandoned batch cannot starve later due rows.
-- Deploy review (live callers run this function unchanged: catpaw-proactive v10 and catpaw-api POST /scheduler/tick,
-- both through proactive/service.mjs tick() -> pg-store claimDue):
--  * lease = 15 min, far above the longest possible in-flight fire: the tick runs inside one Edge Function
--    invocation (wall clock <= 400 s, paid plan; 150 s free), so a live worker can never lose its lease mid-fire.
--  * even after a re-claim, a reminder is delivered at most once: fire() inserts reminder_due with
--    dedupe_key 'due:<task>:<scheduled_at>' (unique (user_id, dedupe_key), on conflict do nothing) in both the live
--    and the new code, finishOccurrence is fenced on next_fire_at = scheduled_at, and APNs sends are driven by the
--    event row's own push claim/lease, never by the occurrence. A re-claim can only repeat the (free) text generation.
--  * the claim time is p_now, so the new worker fences releaseOccurrence on claimed_at (a late failure of an old
--    worker cannot release a newer claim).
create or replace function proactive.claim_due_reminders(p_now timestamptz, p_limit integer default 50)
returns table(task_id uuid, user_id uuid, conversation_id uuid, title text, notes text, due_at timestamptz,
              time_zone text, recurrence jsonb, scheduled_at timestamptz, fire_count integer)
language plpgsql security definer set search_path = proactive, pg_temp as $$
#variable_conflict use_column
begin
  return query
  with due as (
    select t.* from proactive.tasks t
    where t.status in ('open','snoozed') and t.next_fire_at is not null and t.next_fire_at <= p_now
      and not exists (select 1 from proactive.reminder_occurrences o
                      where o.task_id = t.id and o.scheduled_at = t.next_fire_at
                        and (o.state <> 'claimed' or o.claimed_at > p_now - interval '15 minutes'))
    order by t.next_fire_at limit greatest(1, least(p_limit, 200))
    for update skip locked
  ), ins as (
    insert into proactive.reminder_occurrences as o (task_id, scheduled_at, user_id, state, claimed_at)
    select d.id, d.next_fire_at, d.user_id, 'claimed', p_now from due d
    on conflict (task_id, scheduled_at) do update set claimed_at = excluded.claimed_at
      where o.state = 'claimed' and o.claimed_at <= p_now - interval '15 minutes'
    returning o.task_id, o.scheduled_at
  )
  select d.id, d.user_id, d.conversation_id, d.title, d.notes, d.due_at, d.time_zone, d.recurrence, i.scheduled_at, d.fire_count
  from due d join ins i on i.task_id = d.id;
end $$;
revoke all on function proactive.claim_due_reminders(timestamptz, integer) from public, anon, authenticated;
grant execute on function proactive.claim_due_reminders(timestamptz, integer) to service_role;
