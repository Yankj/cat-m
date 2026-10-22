-- M1 REM-01/02: reminder occurrence claims become leases. A 'claimed' occurrence older than 30 seconds
-- (worker lost after claim) is claimable again; 'generated' occurrences are final. Expired leases are
-- considered before the limit, so an abandoned batch cannot starve later due rows.
create or replace function proactive.claim_due_reminders(p_now timestamptz, p_limit integer default 50)
returns table(task_id uuid, user_id uuid, conversation_id uuid, title text, notes text, due_at timestamptz,
              time_zone text, recurrence jsonb, scheduled_at timestamptz, fire_count integer)
language plpgsql security definer set search_path = proactive, pg_temp as $$
begin
  return query
  with due as (
    select t.* from proactive.tasks t
    where t.status in ('open','snoozed') and t.next_fire_at is not null and t.next_fire_at <= p_now
      and not exists (select 1 from proactive.reminder_occurrences o
                      where o.task_id = t.id and o.scheduled_at = t.next_fire_at
                        and (o.state <> 'claimed' or o.claimed_at > p_now - interval '30 seconds'))
    order by t.next_fire_at limit greatest(1, least(p_limit, 200))
    for update skip locked
  ), ins as (
    insert into proactive.reminder_occurrences as o (task_id, scheduled_at, user_id, state, claimed_at)
    select d.id, d.next_fire_at, d.user_id, 'claimed', p_now from due d
    on conflict (task_id, scheduled_at) do update set claimed_at = excluded.claimed_at
      where o.state = 'claimed' and o.claimed_at <= p_now - interval '30 seconds'
    returning o.task_id, o.scheduled_at
  )
  select d.id, d.user_id, d.conversation_id, d.title, d.notes, d.due_at, d.time_zone, d.recurrence, i.scheduled_at, d.fire_count
  from due d join ins i on i.task_id = d.id;
end $$;
revoke all on function proactive.claim_due_reminders(timestamptz, integer) from public, anon, authenticated;
grant execute on function proactive.claim_due_reminders(timestamptz, integer) to service_role;
