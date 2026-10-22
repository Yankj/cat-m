-- catpaw.family.v1 v0.4: household memory facts (correct / pause / delete) and restrained reminders.
-- WRITTEN ONLY — NOT APPLIED to production (needs the user's approval).
alter table family.members drop constraint if exists members_member_kind_check;
alter table family.members add constraint members_member_kind_check check (member_kind in ('child','adult','other'));
alter table family.households add column if not exists memory_paused boolean not null default false;
alter table family.households add column if not exists reminders_paused boolean not null default false;

create table family.memories (
  id uuid primary key,
  household_id uuid not null references family.households(id) on delete cascade,
  member_id uuid references family.members(id),
  text text not null check (char_length(text) between 1 and 500),
  kind text not null default 'fact' check (kind = 'fact'),
  visibility text not null default 'household' check (visibility in ('household','private')),
  valid_from timestamptz, valid_to timestamptz,
  source jsonb not null,
  status text not null default 'active' check (status in ('active','deleted')),
  revision integer not null default 1,
  deleted_at timestamptz, delete_command_id uuid,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create index on family.memories(household_id) where status = 'active';
alter table family.memories enable row level security;
revoke all on family.memories from public, anon, authenticated;
grant all on family.memories to service_role;
grant select on family.memories to authenticated;
create policy memories_owner_read on family.memories for select to authenticated
  using (exists (select 1 from family.households h where h.id = household_id and h.owner_user_id = auth.uid()));

create function family.ts(p jsonb, k text) returns timestamptz language plpgsql immutable as $$
begin
  if p->k is null or jsonb_typeof(p->k) = 'null' then return null; end if;
  if jsonb_typeof(p->k) <> 'string' or (p->>k) !~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2})?(\.\d+)?(Z|[+-]\d{2}:\d{2})$' then perform family.fail('command_invalid'); end if;
  return (p->>k)::timestamptz;
end $$;

create function family.cmd_member_kind(p_actor uuid, p_hh uuid, c jsonb) returns jsonb language plpgsql as $$
-- member.upsert: like child.upsert but for adult / other household members (used by memory subjects)
declare r jsonb; k text := coalesce(c#>>'{payload,member_kind}','child');
begin
  if k not in ('child','adult','other') then perform family.fail('command_invalid'); end if;
  r := family.cmd_child_upsert(p_actor, p_hh, jsonb_set(c, '{payload}', coalesce(c->'payload','{}') - 'member_kind'));
  update family.members set member_kind = k where id = (r->0->>'id')::uuid;
  return r;
end $$;

create function family.cmd_memory_upsert(p_actor uuid, p_hh uuid, c jsonb) returns jsonb language plpgsql as $$
declare m family.memories; p jsonb := coalesce(c->'payload','{}'); v_id uuid := family.uuid_or_null(c,'target_id'); mid uuid := family.uuid_or_null(p,'member_id');
begin
  if (select memory_paused from family.households where id = p_hh) then perform family.reject('memory_paused'); end if;
  perform family.active_member(p_hh, mid);
  if v_id is not null then select * into m from family.memories where id = v_id for update; end if;
  if m.id is not null and m.household_id <> p_hh then perform family.fail('not_found'); end if;
  if m.id is null then
    insert into family.memories(id, household_id, member_id, text, visibility, valid_from, valid_to, source)
    values (coalesce(v_id, gen_random_uuid()), p_hh, mid, family.txt(p,'text',500,true), coalesce(family.txt(p,'visibility',16),'household'),
            family.ts(p,'valid_from'), family.ts(p,'valid_to'), family.source_ok(p->'source'))
    returning * into m;
  else
    if m.status = 'deleted' then perform family.reject('previously_deleted'); end if;  -- never relearn a deleted fact by id
    perform family.need_rev(c, m.revision);
    update family.memories set text = coalesce(family.txt(p,'text',500), text), source = coalesce(family.source_ok(p->'source'), source),
      revision = revision + 1, updated_at = now() where id = m.id returning * into m;
  end if;
  perform family.emit(p_hh, 'memory.changed', 'memory', m.id, m.revision, p_actor, (c->>'command_id')::uuid);
  return jsonb_build_array(family.obj('memory', m.id, m.revision));
end $$;

create function family.cmd_memory_correct(p_actor uuid, p_hh uuid, c jsonb) returns jsonb language plpgsql as $$
declare m family.memories; p jsonb := coalesce(c->'payload','{}');
begin
  select * into m from family.memories where id = family.uuid_or_null(c,'target_id') and household_id = p_hh for update;
  if m.id is null then perform family.fail('not_found'); end if;
  if m.status = 'deleted' then perform family.reject('previously_deleted'); end if;
  perform family.need_rev(c, m.revision);   -- late correction against an old revision: 409-style rejection, newer text kept
  update family.memories set text = family.txt(p,'text',500,true),
    source = case when p ? 'source' then family.source_ok(p->'source') else jsonb_set(source, '{source_kind}', '"user_confirm"') end,
    revision = revision + 1, updated_at = now() where id = m.id returning * into m;
  perform family.emit(p_hh, 'memory.changed', 'memory', m.id, m.revision, p_actor, (c->>'command_id')::uuid);
  return jsonb_build_array(family.obj('memory', m.id, m.revision));
end $$;

create function family.cmd_memory_delete(p_actor uuid, p_hh uuid, c jsonb) returns jsonb language plpgsql as $$
declare m family.memories;
begin
  select * into m from family.memories where id = family.uuid_or_null(c,'target_id') and household_id = p_hh for update;
  if m.id is null then perform family.fail('not_found'); end if;
  if m.status = 'deleted' then perform family.reject('previously_deleted'); end if;
  perform family.need_rev(c, m.revision);
  update family.memories set status = 'deleted', text = '已删除', source = jsonb_build_object('source_kind', source->>'source_kind', 'source_ref', 'deleted'),
    deleted_at = now(), delete_command_id = (c->>'command_id')::uuid, revision = revision + 1, updated_at = now() where id = m.id returning * into m;
  perform family.emit(p_hh, 'memory.deleted', 'memory', m.id, m.revision, p_actor, (c->>'command_id')::uuid);
  return jsonb_build_array(family.obj('memory', m.id, m.revision));
end $$;

-- memory.pause / reminder.pause: payload {paused: bool}; expected_revision = household revision.
create function family.cmd_memory_pause(p_actor uuid, p_hh uuid, c jsonb) returns jsonb language plpgsql as $$
declare h family.households;
begin
  if jsonb_typeof(c#>'{payload,paused}') <> 'boolean' then perform family.fail('command_invalid'); end if;
  select * into h from family.households where id = p_hh for update;
  perform family.need_rev(c, h.revision);
  update family.households set memory_paused = (c#>>'{payload,paused}')::boolean, revision = revision + 1, updated_at = now() where id = p_hh returning * into h;
  perform family.emit(p_hh, 'household.changed', 'household', p_hh, h.revision, p_actor, (c->>'command_id')::uuid);
  return jsonb_build_array(family.obj('household', p_hh, h.revision));
end $$;

create function family.cmd_reminder_pause(p_actor uuid, p_hh uuid, c jsonb) returns jsonb language plpgsql as $$
declare h family.households;
begin
  if jsonb_typeof(c#>'{payload,paused}') <> 'boolean' then perform family.fail('command_invalid'); end if;
  select * into h from family.households where id = p_hh for update;
  perform family.need_rev(c, h.revision);
  update family.households set reminders_paused = (c#>>'{payload,paused}')::boolean, revision = revision + 1, updated_at = now() where id = p_hh returning * into h;
  perform family.emit(p_hh, 'household.changed', 'household', p_hh, h.revision, p_actor, (c->>'command_id')::uuid);
  return jsonb_build_array(family.obj('household', p_hh, h.revision));
end $$;

-- api-v1 §7: kinds deadline_approaching / bring_item / conflict; why_now ≤80; ≤2 scheduled per household local day;
-- no reminder firing 21:00–08:00 household time; only for scheduled (confirmed) items.
create function family.cmd_reminder_schedule(p_actor uuid, p_hh uuid, c jsonb) returns jsonb language plpgsql as $$
declare i family.items; h family.households; p jsonb := coalesce(c->'payload','{}'); at timestamptz := family.ts(p,'fire_at'); loc timestamp; r family.reminders;
begin
  select * into h from family.households where id = p_hh;
  select * into i from family.items where id = family.uuid_or_null(c,'target_id') and household_id = p_hh for update;
  if i.id is null then perform family.fail('not_found'); end if;
  if coalesce(p->>'kind','') not in ('deadline_approaching','bring_item','conflict') or at is null then perform family.fail('command_invalid'); end if;
  if family.txt(p,'why_now',80,true) is null then perform family.fail('command_invalid'); end if;
  if i.status <> 'scheduled' or i.confirmed_command_id is null then perform family.reject('confirmation_required'); end if;
  perform family.need_rev(c, i.revision);
  if h.reminders_paused then perform family.reject('reminders_paused'); end if;
  if at <= now() then perform family.reject('fire_at_past'); end if;
  loc := at at time zone h.timezone;
  if loc::time >= time '21:00' or loc::time < time '08:00' then perform family.reject('quiet_hours'); end if;
  perform 1 from family.households where id = p_hh for update; -- serialise the daily cap
  if (select count(*) from family.reminders where household_id = p_hh and status = 'scheduled' and fire_local_date = loc::date) >= 2 then
    perform family.reject('daily_limit');
  end if;
  insert into family.reminders(id, household_id, item_id, kind, why_now, fire_at, fire_local_date)
  values (coalesce(family.uuid_or_null(p,'reminder_id'), gen_random_uuid()), p_hh, i.id, p->>'kind', family.txt(p,'why_now',80,true), at, loc::date)
  returning * into r;
  perform family.emit(p_hh, 'reminder.changed', 'reminder', r.id, r.revision, p_actor, (c->>'command_id')::uuid);
  return jsonb_build_array(family.obj('reminder', r.id, r.revision));
end $$;

create function family.cmd_reminder_cancel(p_actor uuid, p_hh uuid, c jsonb) returns jsonb language plpgsql as $$
declare r family.reminders;
begin
  select * into r from family.reminders where id = family.uuid_or_null(c,'target_id') and household_id = p_hh for update;
  if r.id is null then perform family.fail('not_found'); end if;
  if r.status <> 'scheduled' then perform family.reject('invalid_state'); end if;
  perform family.need_rev(c, r.revision);
  update family.reminders set status = 'cancelled', revision = revision + 1, updated_at = now() where id = r.id returning * into r; -- item untouched
  perform family.emit(p_hh, 'reminder.changed', 'reminder', r.id, r.revision, p_actor, (c->>'command_id')::uuid);
  return jsonb_build_array(family.obj('reminder', r.id, r.revision));
end $$;

insert into family.command_types(type, fn) values
  ('member.upsert','cmd_member_kind'),
  ('memory.upsert','cmd_memory_upsert'), ('memory.correct','cmd_memory_correct'), ('memory.delete','cmd_memory_delete'),
  ('memory.pause','cmd_memory_pause'), ('reminder.pause','cmd_reminder_pause'),
  ('reminder.schedule','cmd_reminder_schedule'), ('reminder.cancel','cmd_reminder_cancel');

-- Read: household memories for 我们家 and recall candidates (filtered here; ranking in the service).
create function family.memories_for(p_actor uuid, p_hh uuid, p_at timestamptz, p_member uuid, p_visibility text default 'household') returns jsonb
language sql stable security definer set search_path = family, pg_temp as $$
  select case when not exists (select 1 from family.households where id = p_hh and owner_user_id = p_actor) then null
    when (select memory_paused from family.households where id = p_hh) and p_at is not null then '[]'::jsonb else
    coalesce((select jsonb_agg(jsonb_build_object('memory_id',m.id,'member_id',m.member_id,'text',m.text,'kind',m.kind,'visibility',m.visibility,
      'valid_from',m.valid_from,'valid_to',m.valid_to,'source',m.source,'revision',m.revision) order by m.updated_at desc)
     from family.memories m join family.households h on h.id = m.household_id and h.owner_user_id = p_actor
     where m.household_id = p_hh and m.status = 'active'
       and (p_at is null or ((m.valid_from is null or m.valid_from <= p_at) and (m.valid_to is null or m.valid_to > p_at)))
       and (p_member is null or m.member_id is null or m.member_id = p_member)
       and (p_visibility = 'all' or m.visibility = p_visibility)), '[]') end $$;

create function family.settings_for(p_actor uuid, p_hh uuid) returns jsonb language sql stable security definer set search_path = family, pg_temp as $$
  select jsonb_build_object('memory_paused', memory_paused, 'reminders_paused', reminders_paused, 'revision', revision)
  from family.households where id = p_hh and owner_user_id = p_actor $$;

-- Reminder dispatch: 30 s claim lease; fire re-checks reminder + item + household state atomically (api-v1 §8, §11).
create function family.claim_due_reminders(p_now timestamptz, p_limit integer default 50)
returns table(reminder_id uuid, household_id uuid, item_id uuid, claimed_at timestamptz)
language plpgsql security definer set search_path = family, pg_temp as $$
#variable_conflict use_column
begin
  return query
  update family.reminders r set claimed_at = p_now
  where r.id in (
    select r2.id from family.reminders r2
    join family.items i on i.id = r2.item_id and i.status = 'scheduled'
    join family.households h on h.id = r2.household_id and not h.reminders_paused
    where r2.status = 'scheduled' and r2.fire_at <= p_now and (r2.claimed_at is null or r2.claimed_at <= p_now - interval '30 seconds')
    order by r2.fire_at limit greatest(1, least(p_limit, 200)) for update of r2 skip locked)
  returning r.id, r.household_id, r.item_id, r.claimed_at;
end $$;

create function family.fire_reminder(p_id uuid, p_claimed_at timestamptz) returns boolean
language plpgsql security definer set search_path = family, pg_temp as $$
declare r family.reminders;
begin
  update family.reminders rr set status = 'fired', revision = revision + 1, updated_at = now()
  where rr.id = p_id and rr.status = 'scheduled' and rr.claimed_at = p_claimed_at
    and exists (select 1 from family.items i where i.id = rr.item_id and i.status = 'scheduled')
    and exists (select 1 from family.households h where h.id = rr.household_id and not h.reminders_paused)
  returning * into r;
  if r.id is null then return false; end if;
  insert into family.outbox(household_id, type, aggregate_type, aggregate_id, aggregate_revision, actor_ref, causation_id)
  values (r.household_id, 'reminder.due', 'reminder', r.id, r.revision, 'system:reminder', r.id);
  return true;
end $$;

create function family.release_reminder(p_id uuid, p_claimed_at timestamptz) returns void
language sql security definer set search_path = family, pg_temp as $$
  update family.reminders set claimed_at = null where id = p_id and status = 'scheduled' and claimed_at = p_claimed_at $$;

revoke execute on all functions in schema family from public, anon, authenticated;
do $$ declare f text; begin
  foreach f in array array['apply_command(uuid,jsonb,text)','get_receipt(uuid,uuid)','my_households(uuid)','projection(uuid,uuid,date)','changes(uuid,uuid,bigint,integer)',
    'memories_for(uuid,uuid,timestamptz,uuid,text)','settings_for(uuid,uuid)','claim_due_reminders(timestamptz,integer)','fire_reminder(uuid,timestamptz)','release_reminder(uuid,timestamptz)'] loop
    execute format('grant execute on function family.%s to service_role', f);
  end loop;
end $$;
