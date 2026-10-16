-- Codex PR90c #2/#3: delivery ownership + shared payload revision protocol. NOT APPLIED automatically (needs approval).
-- Requires 20261016040000_proactive_suggestions_runtime.sql.

-- 1) Snooze expiry: re-arm an APNs push only for decisions the client handed off (delivery = 'remote');
--    device-owned decisions resurface in the inbox and the device re-notifies. Every write bumps suggestion.rev so a
--    concurrent action compare-and-set (catpaw-proactive) reloads instead of overwriting this change.
create or replace function proactive.resurface_snoozed_suggestions(p_now timestamptz default now())
returns setof uuid language sql security definer set search_path = proactive, pg_temp as $$
  update proactive.events e set
    payload = jsonb_set(e.payload, '{suggestion}', ((e.payload->'suggestion') - 'snooze_until' - 'chat_delivered_at')
      || jsonb_build_object('status', 'pending', 'resurfaced_at', p_now, 'rev', coalesce((e.payload->'suggestion'->>'rev')::int, 0) + 1)),
    push_state = case when e.payload->>'decision' in ('notify','interrupt') and e.payload->>'delivery' = 'remote' then 'pending' else e.push_state end,
    push_after = null
  where e.kind = 'proactive_decision' and e.payload->'suggestion'->>'status' = 'snoozed'
    and (e.payload->'suggestion'->>'snooze_until')::timestamptz <= p_now
  returning e.id;
$$;
revoke all on function proactive.resurface_snoozed_suggestions(timestamptz) from public, anon, authenticated;
grant execute on function proactive.resurface_snoozed_suggestions(timestamptz) to service_role;

-- 2) Historical rows: pending pushes for proactive decisions written before ownership existed (no 'delivery') or
--    owned by the device are never sent by APNs. Explicit, auditable disposition.
update proactive.events
   set push_state = 'skipped', push_error = 'device_owned'
 where kind = 'proactive_decision' and push_state = 'pending'
   and coalesce(payload->>'delivery', 'device') <> 'remote';
