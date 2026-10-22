-- catpaw.family.v1 core (v0.2 text loop). WRITTEN ONLY — NOT APPLIED to production (needs the user's approval).
-- Household / child / plan / item / proposal / observation / reminder rows, durable receipts and outbox, single-adult
-- RLS, and one SECURITY DEFINER entry point family.apply_command() that commits domain write + revision + receipt +
-- outbox in ONE transaction (api-v1 §4, §8). Service-role callers pass the verified actor; every statement re-filters
-- by owner (api-v1 §10). Commands are dispatched to family.cmd_<type> functions listed in family.command_types, so
-- later migrations add commands without rewriting this file.
create schema if not exists family;
revoke all on schema family from public, anon;
grant usage on schema family to authenticated, service_role;

create table family.households (
  id uuid primary key,
  owner_user_id uuid not null unique references auth.users(id) on delete cascade, -- single adult, one household
  name text not null check (char_length(name) between 1 and 80),
  timezone text not null default 'Asia/Shanghai',
  status text not null default 'active' check (status in ('active','archived')),
  revision integer not null default 1,
  seq bigint not null default 1,           -- projection_revision: bumped by every applied command
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create table family.members (
  id uuid primary key,
  household_id uuid not null references family.households(id) on delete cascade,
  display_name text not null check (char_length(display_name) between 1 and 40),
  member_kind text not null default 'child' check (member_kind = 'child'),
  birth_year integer check (birth_year is null or birth_year between 2000 and 2100),
  school_label text check (char_length(school_label) <= 60),
  class_label text check (char_length(class_label) <= 60),
  teacher_label text check (char_length(teacher_label) <= 60),
  place_label text check (char_length(place_label) <= 60),
  notes text check (char_length(notes) <= 500),
  status text not null default 'active' check (status in ('active','deleted')),
  revision integer not null default 1,
  deleted_at timestamptz, delete_command_id uuid,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create index on family.members(household_id) where status = 'active';
create table family.plans (
  id uuid primary key,
  household_id uuid not null references family.households(id) on delete cascade,
  member_id uuid references family.members(id),
  title text not null check (char_length(title) between 1 and 120),
  domain text not null default 'general' check (char_length(domain) <= 40),
  status text not null default 'active' check (status in ('draft','active','paused','completed','archived','deleted')),
  revision integer not null default 1,
  deleted_at timestamptz,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table family.items (
  id uuid primary key,
  household_id uuid not null references family.households(id) on delete cascade,
  member_id uuid references family.members(id),
  plan_id uuid references family.plans(id),
  title text not null check (char_length(title) between 1 and 120),
  status text not null check (status in ('needs_confirmation','scheduled','cancelled','deleted')),
  local_date date, local_time time, timezone text not null default 'Asia/Shanghai',
  place text check (char_length(place) <= 80),
  bring text[] not null default '{}' check (cardinality(bring) <= 12),
  notes text check (char_length(notes) <= 500),
  source jsonb not null,
  confirmed_command_id uuid,
  revision integer not null default 1,
  deleted_at timestamptz,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create index on family.items(household_id, local_date) where status = 'scheduled';
create table family.proposals (
  id uuid primary key,
  household_id uuid not null references family.households(id) on delete cascade,
  target_type text not null check (target_type in ('item')),
  target_id uuid not null,
  base_revision integer not null,
  patch jsonb not null,
  status text not null default 'open' check (status in ('open','confirmed','rejected','expired')),
  revision integer not null default 1,
  capture_id uuid,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create index on family.proposals(household_id) where status = 'open';
create table family.observations (
  id uuid primary key,
  household_id uuid not null references family.households(id) on delete cascade,
  member_id uuid not null references family.members(id),
  text text not null check (char_length(text) between 1 and 500),
  observed_on date not null,
  source jsonb not null,
  status text not null default 'recorded' check (status in ('recorded','deleted')),
  revision integer not null default 1,
  deleted_at timestamptz,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table family.reminders (
  id uuid primary key,
  household_id uuid not null references family.households(id) on delete cascade,
  item_id uuid not null references family.items(id),
  kind text not null check (kind in ('deadline_approaching','bring_item','conflict')),
  why_now text not null check (char_length(why_now) between 1 and 80),
  fire_at timestamptz not null,
  fire_local_date date not null,
  status text not null default 'scheduled' check (status in ('scheduled','cancelled','fired')),
  claimed_at timestamptz,
  revision integer not null default 1,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create index on family.reminders(fire_at) where status = 'scheduled';
create table family.receipts (
  actor_user_id uuid not null,
  household_id uuid not null,
  command_id uuid not null,
  type text not null,
  request_hash text not null check (request_hash ~ '^[0-9a-f]{64}$'),
  status text not null check (status in ('processing','applied','rejected')),
  objects jsonb not null default '[]',
  error jsonb,
  created_at timestamptz not null default now(),
  primary key (actor_user_id, household_id, command_id)
);
create unique index receipts_command_idx on family.receipts(actor_user_id, command_id);
create table family.outbox (
  seq bigserial primary key,
  event_id uuid not null unique default gen_random_uuid(),
  household_id uuid not null references family.households(id) on delete cascade,
  type text not null,
  aggregate_type text not null, aggregate_id uuid not null, aggregate_revision integer not null,
  actor_ref text not null, causation_id uuid not null,
  occurred_at timestamptz not null default now(),
  status text not null default 'pending' check (status in ('pending','dispatched'))
);
create index on family.outbox(household_id, seq);
create table family.command_types (type text primary key, fn text not null);

-- Single-adult RLS: default deny; authenticated sees only its own household tree. Writes only via apply_command.
do $$ declare t text; begin
  foreach t in array array['households','members','plans','items','proposals','observations','reminders','receipts','outbox','command_types'] loop
    execute format('alter table family.%I enable row level security', t);
    execute format('revoke all on family.%I from public, anon, authenticated', t);
    execute format('grant all on family.%I to service_role', t);
  end loop;
  foreach t in array array['members','plans','items','proposals','observations','reminders','outbox'] loop
    execute format('grant select on family.%I to authenticated', t);
    execute format('create policy %I on family.%I for select to authenticated using (exists (select 1 from family.households h where h.id = household_id and h.owner_user_id = auth.uid()))', t || '_owner_read', t);
  end loop;
end $$;
grant select on family.households to authenticated;
create policy households_owner_read on family.households for select to authenticated using (owner_user_id = auth.uid());
grant select on family.receipts to authenticated;
create policy receipts_owner_read on family.receipts for select to authenticated
  using (actor_user_id = auth.uid() and exists (select 1 from family.households h where h.id = household_id and h.owner_user_id = auth.uid()));
grant usage on all sequences in schema family to service_role;

-- ---------- helpers ----------
-- Deterministic rejection: rolls back the command's domain writes (sub-transaction) and becomes a rejected receipt.
create function family.reject(p_code text) returns void language plpgsql as $$
begin raise exception using errcode = 'FA001', message = p_code; end $$;
-- Non-receipt HTTP failures (not_found, idempotency_conflict, json/command shape): no receipt is written.
create function family.fail(p_code text) returns void language plpgsql as $$
begin raise exception using errcode = 'FA002', message = p_code; end $$;

create function family.emit(p_hh uuid, p_type text, p_agg_type text, p_agg uuid, p_rev integer, p_actor uuid, p_cause uuid)
returns void language sql as $$
  insert into family.outbox(household_id, type, aggregate_type, aggregate_id, aggregate_revision, actor_ref, causation_id)
  values (p_hh, p_type, p_agg_type, p_agg, p_rev, 'user:' || p_actor, p_cause) $$;

create function family.obj(p_type text, p_id uuid, p_rev integer) returns jsonb language sql immutable as $$
  select jsonb_build_object('type', p_type, 'id', p_id, 'revision', p_rev) $$;

create function family.valid_tz(p text) returns boolean language sql stable as $$
  select p is not null and exists (select 1 from pg_timezone_names where name = p) $$;

create function family.need_rev(p_cmd jsonb, p_current integer) returns void language plpgsql as $$
begin
  if p_cmd->'expected_revision' is null or jsonb_typeof(p_cmd->'expected_revision') <> 'number' then perform family.fail('command_invalid'); end if;
  if (p_cmd->>'expected_revision')::integer <> p_current then perform family.reject('revision_conflict'); end if;
end $$;

create function family.txt(p jsonb, k text, maxlen integer, required boolean default false) returns text language plpgsql immutable as $$
declare v text;
begin
  if p ? k and jsonb_typeof(p->k) not in ('string','null') then perform family.fail('command_invalid'); end if;
  v := nullif(btrim(p->>k), '');
  if required and v is null then perform family.fail('command_invalid'); end if;
  if v is not null and char_length(v) > maxlen then perform family.fail('command_invalid'); end if;
  return v;
end $$;

create function family.source_ok(p jsonb) returns jsonb language plpgsql immutable as $$
begin
  if p is null or jsonb_typeof(p) <> 'object' or coalesce(p->>'source_kind','') not in ('user_text','user_voice_transcript','user_confirm','notification_extract')
     or char_length(coalesce(p->>'source_ref','')) not between 1 and 120 then perform family.fail('command_invalid'); end if;
  return jsonb_build_object('source_kind', p->>'source_kind', 'source_ref', p->>'source_ref', 'captured_at', p->>'captured_at');
end $$;

create function family.bring(p jsonb) returns text[] language plpgsql immutable as $$
declare r text[] := '{}'; e jsonb;
begin
  if p is null or jsonb_typeof(p) = 'null' then return r; end if;
  if jsonb_typeof(p) <> 'array' or jsonb_array_length(p) > 12 then perform family.fail('command_invalid'); end if;
  for e in select * from jsonb_array_elements(p) loop
    if jsonb_typeof(e) <> 'string' or char_length(e #>> '{}') not between 1 and 40 then perform family.fail('command_invalid'); end if;
    r := r || (e #>> '{}');
  end loop; return r;
end $$;

create function family.active_member(p_hh uuid, p_id uuid) returns void language plpgsql stable as $$
begin
  if p_id is not null and not exists (select 1 from family.members where id = p_id and household_id = p_hh and status = 'active')
  then perform family.reject('member_not_found'); end if;
end $$;

create function family.uuid_or_null(p jsonb, k text) returns uuid language plpgsql immutable as $$
begin
  if p->k is null or jsonb_typeof(p->k) = 'null' then return null; end if;
  if jsonb_typeof(p->k) <> 'string' or (p->>k) !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then perform family.fail('command_invalid'); end if;
  return (p->>k)::uuid;
end $$;

create function family.local_date(p jsonb, k text) returns date language plpgsql immutable as $$
begin
  if p->k is null or jsonb_typeof(p->k) = 'null' then return null; end if;
  if (p->>k) !~ '^\d{4}-\d{2}-\d{2}$' then perform family.fail('command_invalid'); end if;
  return (p->>k)::date;
exception when datetime_field_overflow or invalid_datetime_format then perform family.fail('command_invalid'); return null;
end $$;

create function family.local_time(p jsonb, k text) returns time language plpgsql immutable as $$
begin
  if p->k is null or jsonb_typeof(p->k) = 'null' then return null; end if;
  if (p->>k) !~ '^([01]\d|2[0-3]):[0-5]\d$' then perform family.fail('command_invalid'); end if;
  return (p->>k)::time;
end $$;

-- ---------- commands (v0.2) ----------
-- Each returns jsonb array of touched objects; p_hh is already owner-checked by apply_command.
create function family.cmd_household_update(p_actor uuid, p_hh uuid, c jsonb) returns jsonb language plpgsql as $$
declare h family.households; p jsonb := coalesce(c->'payload','{}'); tz text;
begin
  select * into h from family.households where id = p_hh and owner_user_id = p_actor for update;
  perform family.need_rev(c, h.revision);
  tz := coalesce(family.txt(p,'timezone',64), h.timezone);
  if not family.valid_tz(tz) then perform family.fail('timezone_invalid'); end if;
  update family.households set name = coalesce(family.txt(p,'name',80), name), timezone = tz, revision = revision + 1, updated_at = now()
    where id = p_hh returning * into h;
  perform family.emit(p_hh, 'household.changed', 'household', p_hh, h.revision, p_actor, (c->>'command_id')::uuid);
  return jsonb_build_array(family.obj('household', p_hh, h.revision));
end $$;

create function family.cmd_child_upsert(p_actor uuid, p_hh uuid, c jsonb) returns jsonb language plpgsql as $$
declare m family.members; p jsonb := coalesce(c->'payload','{}'); v_id uuid := family.uuid_or_null(c,'target_id');
begin
  if v_id is not null then select * into m from family.members where members.id = v_id for update; end if;
  if m.id is not null and m.household_id <> p_hh then perform family.fail('not_found'); end if;
  if m.id is null then
    insert into family.members(id, household_id, display_name, birth_year, school_label, class_label, teacher_label, place_label, notes)
    values (coalesce(v_id, gen_random_uuid()), p_hh, family.txt(p,'display_name',40,true), (p->>'birth_year')::integer,
            family.txt(p,'school_label',60), family.txt(p,'class_label',60), family.txt(p,'teacher_label',60), family.txt(p,'place_label',60), family.txt(p,'notes',500))
    returning * into m;
  else
    if m.status = 'deleted' then perform family.reject('deleted'); end if;   -- tombstone never revived
    perform family.need_rev(c, m.revision);
    update family.members set
      display_name = coalesce(family.txt(p,'display_name',40), display_name),
      birth_year = case when p ? 'birth_year' then (p->>'birth_year')::integer else birth_year end,
      school_label = case when p ? 'school_label' then family.txt(p,'school_label',60) else school_label end,
      class_label = case when p ? 'class_label' then family.txt(p,'class_label',60) else class_label end,
      teacher_label = case when p ? 'teacher_label' then family.txt(p,'teacher_label',60) else teacher_label end,
      place_label = case when p ? 'place_label' then family.txt(p,'place_label',60) else place_label end,
      notes = case when p ? 'notes' then family.txt(p,'notes',500) else notes end,
      revision = revision + 1, updated_at = now()
    where members.id = m.id returning * into m;
  end if;
  perform family.emit(p_hh, 'child.changed', 'child', m.id, m.revision, p_actor, (c->>'command_id')::uuid);
  return jsonb_build_array(family.obj('child', m.id, m.revision));
end $$;

create function family.cmd_child_delete(p_actor uuid, p_hh uuid, c jsonb) returns jsonb language plpgsql as $$
declare m family.members;
begin
  select * into m from family.members where id = family.uuid_or_null(c,'target_id') and household_id = p_hh for update;
  if m.id is null then perform family.fail('not_found'); end if;
  if m.status = 'deleted' then perform family.reject('deleted'); end if;
  perform family.need_rev(c, m.revision);
  update family.members set status = 'deleted', deleted_at = now(), delete_command_id = (c->>'command_id')::uuid,
    display_name = '已删除', school_label = null, class_label = null, teacher_label = null, place_label = null, notes = null, birth_year = null,
    revision = revision + 1, updated_at = now() where id = m.id returning * into m;
  perform family.emit(p_hh, 'child.deleted', 'child', m.id, m.revision, p_actor, (c->>'command_id')::uuid);
  return jsonb_build_array(family.obj('child', m.id, m.revision));
end $$;

create function family.cmd_plan_upsert(p_actor uuid, p_hh uuid, c jsonb) returns jsonb language plpgsql as $$
declare r family.plans; p jsonb := coalesce(c->'payload','{}'); v_id uuid := family.uuid_or_null(c,'target_id'); mid uuid := family.uuid_or_null(p,'member_id');
begin
  perform family.active_member(p_hh, mid);
  if v_id is not null then select * into r from family.plans where plans.id = v_id for update; end if;
  if r.id is not null and r.household_id <> p_hh then perform family.fail('not_found'); end if;
  if r.id is null then
    insert into family.plans(id, household_id, member_id, title, domain) values (coalesce(v_id, gen_random_uuid()), p_hh, mid, family.txt(p,'title',120,true), coalesce(family.txt(p,'domain',40),'general')) returning * into r;
  else
    if r.status = 'deleted' then perform family.reject('deleted'); end if;
    perform family.need_rev(c, r.revision);
    update family.plans set title = coalesce(family.txt(p,'title',120), title), member_id = case when p ? 'member_id' then mid else member_id end,
      status = case when r.status = 'paused' and p->>'status' = 'active' then 'active' else status end,
      revision = revision + 1, updated_at = now() where plans.id = r.id returning * into r;
  end if;
  perform family.emit(p_hh, 'plan.changed', 'plan', r.id, r.revision, p_actor, (c->>'command_id')::uuid);
  return jsonb_build_array(family.obj('plan', r.id, r.revision));
end $$;

create function family.cmd_plan_pause(p_actor uuid, p_hh uuid, c jsonb) returns jsonb language plpgsql as $$
declare r family.plans;
begin
  select * into r from family.plans where id = family.uuid_or_null(c,'target_id') and household_id = p_hh for update;
  if r.id is null then perform family.fail('not_found'); end if;
  if r.status not in ('active','draft') then perform family.reject('invalid_state'); end if;
  perform family.need_rev(c, r.revision);
  update family.plans set status = 'paused', revision = revision + 1, updated_at = now() where id = r.id returning * into r; -- confirmed items untouched
  perform family.emit(p_hh, 'plan.changed', 'plan', r.id, r.revision, p_actor, (c->>'command_id')::uuid);
  return jsonb_build_array(family.obj('plan', r.id, r.revision));
end $$;

create function family.cmd_item_propose(p_actor uuid, p_hh uuid, c jsonb) returns jsonb language plpgsql as $$
declare i family.items; p jsonb := coalesce(c->'payload','{}'); pid uuid := coalesce(family.uuid_or_null(c,'proposal_id'), gen_random_uuid());
  mid uuid := family.uuid_or_null(p,'member_id'); tz text; hh_tz text;
begin
  select timezone into hh_tz from family.households where id = p_hh;
  tz := coalesce(family.txt(p,'timezone',64), hh_tz);
  if not family.valid_tz(tz) then perform family.fail('timezone_invalid'); end if;
  perform family.active_member(p_hh, mid);
  if exists (select 1 from family.items where id = family.uuid_or_null(c,'target_id')) then perform family.reject('already_exists'); end if;
  insert into family.items(id, household_id, member_id, title, status, local_date, local_time, timezone, place, bring, notes, source)
  values (coalesce(family.uuid_or_null(c,'target_id'), gen_random_uuid()), p_hh, mid, family.txt(p,'title',120,true), 'needs_confirmation',
          family.local_date(p,'local_date'), family.local_time(p,'local_time'), tz, family.txt(p,'place',80), family.bring(p->'bring'),
          family.txt(p,'notes',500), family.source_ok(p->'source'))
  returning * into i;
  insert into family.proposals(id, household_id, target_type, target_id, base_revision, patch, capture_id)
  values (pid, p_hh, 'item', i.id, i.revision, p - 'source', family.uuid_or_null(p,'capture_id'));
  perform family.emit(p_hh, 'item.proposed', 'item', i.id, i.revision, p_actor, (c->>'command_id')::uuid);
  return jsonb_build_array(family.obj('item', i.id, i.revision), family.obj('proposal', pid, 1));
end $$;

create function family.cmd_item_confirm(p_actor uuid, p_hh uuid, c jsonb) returns jsonb language plpgsql as $$
declare i family.items; pr family.proposals;
begin
  select * into i from family.items where id = family.uuid_or_null(c,'target_id') and household_id = p_hh for update;
  if i.id is null then perform family.fail('not_found'); end if;
  select * into pr from family.proposals where id = family.uuid_or_null(c,'proposal_id') and household_id = p_hh for update;
  if pr.id is null or pr.target_id <> i.id then perform family.reject('confirmation_required'); end if;
  if i.status in ('cancelled','deleted') then perform family.reject('invalid_state'); end if;
  if pr.status <> 'open' then perform family.reject('proposal_closed'); end if;
  perform family.need_rev(c, i.revision);
  if pr.base_revision <> i.revision then perform family.reject('revision_conflict'); end if;
  if i.status <> 'needs_confirmation' then perform family.reject('invalid_state'); end if;
  update family.items set status = 'scheduled', confirmed_command_id = (c->>'command_id')::uuid, revision = revision + 1, updated_at = now()
    where id = i.id returning * into i;
  update family.proposals set status = 'confirmed', revision = revision + 1, updated_at = now() where id = pr.id;
  perform family.emit(p_hh, 'item.changed', 'item', i.id, i.revision, p_actor, (c->>'command_id')::uuid);
  return jsonb_build_array(family.obj('item', i.id, i.revision), family.obj('proposal', pr.id, pr.revision + 1));
end $$;

create function family.cmd_item_correct(p_actor uuid, p_hh uuid, c jsonb) returns jsonb language plpgsql as $$
declare i family.items; p jsonb := coalesce(c->'payload','{}'); mid uuid := family.uuid_or_null(p,'member_id');
begin
  select * into i from family.items where id = family.uuid_or_null(c,'target_id') and household_id = p_hh for update;
  if i.id is null then perform family.fail('not_found'); end if;
  if i.status in ('cancelled','deleted') then perform family.reject('invalid_state'); end if;
  if p ?| array['local_date','local_time','timezone'] then perform family.reject('confirmation_required'); end if; -- behaviour fields need reschedule
  perform family.need_rev(c, i.revision);
  perform family.active_member(p_hh, mid);
  update family.items set title = coalesce(family.txt(p,'title',120), title),
    member_id = case when p ? 'member_id' then mid else member_id end,
    place = case when p ? 'place' then family.txt(p,'place',80) else place end,
    bring = case when p ? 'bring' then family.bring(p->'bring') else bring end,
    notes = case when p ? 'notes' then family.txt(p,'notes',500) else notes end,
    revision = revision + 1, updated_at = now() where id = i.id returning * into i;
  -- an open proposal for this item now points at an old revision: expire it (confirm needs a new proposal)
  update family.proposals set status = 'expired', revision = revision + 1, updated_at = now() where target_id = i.id and status = 'open';
  if i.status = 'needs_confirmation' then
    insert into family.proposals(id, household_id, target_type, target_id, base_revision, patch)
    values (gen_random_uuid(), p_hh, 'item', i.id, i.revision, jsonb_build_object('title', i.title));
  end if;
  perform family.emit(p_hh, 'item.changed', 'item', i.id, i.revision, p_actor, (c->>'command_id')::uuid);
  return jsonb_build_array(family.obj('item', i.id, i.revision));
end $$;

create function family.cmd_item_cancel(p_actor uuid, p_hh uuid, c jsonb) returns jsonb language plpgsql as $$
declare i family.items; r record; objs jsonb;
begin
  select * into i from family.items where id = family.uuid_or_null(c,'target_id') and household_id = p_hh for update;
  if i.id is null then perform family.fail('not_found'); end if;
  if i.status in ('cancelled','deleted') then perform family.reject('invalid_state'); end if;
  perform family.need_rev(c, i.revision);
  update family.items set status = 'cancelled', revision = revision + 1, updated_at = now() where id = i.id returning * into i;
  update family.proposals set status = 'rejected', revision = revision + 1, updated_at = now() where target_id = i.id and status = 'open';
  objs := jsonb_build_array(family.obj('item', i.id, i.revision));
  for r in update family.reminders set status = 'cancelled', revision = revision + 1, updated_at = now()
           where item_id = i.id and status = 'scheduled' returning id, revision loop
    perform family.emit(p_hh, 'reminder.changed', 'reminder', r.id, r.revision, p_actor, (c->>'command_id')::uuid);
    objs := objs || family.obj('reminder', r.id, r.revision);
  end loop;
  perform family.emit(p_hh, 'item.changed', 'item', i.id, i.revision, p_actor, (c->>'command_id')::uuid);
  return objs;
end $$;

create function family.cmd_item_reschedule(p_actor uuid, p_hh uuid, c jsonb) returns jsonb language plpgsql as $$
declare i family.items; p jsonb := coalesce(c->'payload','{}'); acts jsonb := coalesce(c#>'{consent,actions}','[]'); tz text; objs jsonb; r record; pr family.proposals;
begin
  select * into i from family.items where id = family.uuid_or_null(c,'target_id') and household_id = p_hh for update;
  if i.id is null then perform family.fail('not_found'); end if;
  if coalesce(p->>'scope','') not in ('one_occurrence','series') then perform family.fail('command_invalid'); end if;
  if jsonb_typeof(acts) <> 'array' or not acts ? 'update_item' then perform family.reject('confirmation_required'); end if;
  if i.status <> 'scheduled' then perform family.reject('confirmation_required'); end if;
  perform family.need_rev(c, i.revision);
  if family.uuid_or_null(c,'proposal_id') is not null then
    select * into pr from family.proposals where id = family.uuid_or_null(c,'proposal_id') and household_id = p_hh for update;
    if pr.id is null or pr.target_id <> i.id or pr.status <> 'open' or pr.base_revision <> i.revision then perform family.reject('confirmation_required'); end if;
    update family.proposals set status = 'confirmed', revision = revision + 1, updated_at = now() where id = pr.id;
  end if;
  tz := coalesce(family.txt(p,'timezone',64), i.timezone);
  if not family.valid_tz(tz) then perform family.fail('timezone_invalid'); end if;
  if exists (select 1 from family.reminders where item_id = i.id and status = 'scheduled') and not acts ? 'replace_reminder' then
    perform family.reject('confirmation_required'); -- would leave reminders on the old time; not in consent set
  end if;
  update family.items set local_date = coalesce(family.local_date(p,'local_date'), local_date),
    local_time = case when p ? 'local_time' then family.local_time(p,'local_time') else local_time end,
    timezone = tz, confirmed_command_id = (c->>'command_id')::uuid, revision = revision + 1, updated_at = now()
  where id = i.id returning * into i;
  objs := jsonb_build_array(family.obj('item', i.id, i.revision));
  for r in update family.reminders set status = 'cancelled', revision = revision + 1, updated_at = now()
           where item_id = i.id and status = 'scheduled' returning id, revision loop  -- replace_reminder: old ones void
    perform family.emit(p_hh, 'reminder.changed', 'reminder', r.id, r.revision, p_actor, (c->>'command_id')::uuid);
    objs := objs || family.obj('reminder', r.id, r.revision);
  end loop;
  perform family.emit(p_hh, 'item.changed', 'item', i.id, i.revision, p_actor, (c->>'command_id')::uuid);
  return objs;
end $$;

create function family.cmd_observation_record(p_actor uuid, p_hh uuid, c jsonb) returns jsonb language plpgsql as $$
declare o family.observations; p jsonb := coalesce(c->'payload','{}'); mid uuid := family.uuid_or_null(p,'member_id');
begin
  if mid is null then perform family.fail('command_invalid'); end if;
  perform family.active_member(p_hh, mid);
  insert into family.observations(id, household_id, member_id, text, observed_on, source)
  values (coalesce(family.uuid_or_null(c,'target_id'), gen_random_uuid()), p_hh, mid, family.txt(p,'text',500,true),
          coalesce(family.local_date(p,'observed_on'), (now() at time zone 'Asia/Shanghai')::date), family.source_ok(p->'source'))
  on conflict (id) do nothing returning * into o;
  if o.id is null then perform family.reject('already_exists'); end if;
  perform family.emit(p_hh, 'observation.recorded', 'observation', o.id, o.revision, p_actor, (c->>'command_id')::uuid);
  return jsonb_build_array(family.obj('observation', o.id, o.revision));
end $$;

create function family.cmd_observation_correct(p_actor uuid, p_hh uuid, c jsonb) returns jsonb language plpgsql as $$
declare o family.observations; p jsonb := coalesce(c->'payload','{}');
begin
  select * into o from family.observations where id = family.uuid_or_null(c,'target_id') and household_id = p_hh for update;
  if o.id is null then perform family.fail('not_found'); end if;
  if o.status = 'deleted' then perform family.reject('deleted'); end if;
  perform family.need_rev(c, o.revision);
  update family.observations set text = coalesce(family.txt(p,'text',500), text), observed_on = coalesce(family.local_date(p,'observed_on'), observed_on),
    revision = revision + 1, updated_at = now() where id = o.id returning * into o;
  perform family.emit(p_hh, 'observation.recorded', 'observation', o.id, o.revision, p_actor, (c->>'command_id')::uuid);
  return jsonb_build_array(family.obj('observation', o.id, o.revision));
end $$;

create function family.cmd_observation_delete(p_actor uuid, p_hh uuid, c jsonb) returns jsonb language plpgsql as $$
declare o family.observations;
begin
  select * into o from family.observations where id = family.uuid_or_null(c,'target_id') and household_id = p_hh for update;
  if o.id is null then perform family.fail('not_found'); end if;
  if o.status = 'deleted' then perform family.reject('deleted'); end if;
  perform family.need_rev(c, o.revision);
  update family.observations set status = 'deleted', text = '已删除', deleted_at = now(), revision = revision + 1, updated_at = now() where id = o.id returning * into o;
  perform family.emit(p_hh, 'observation.deleted', 'observation', o.id, o.revision, p_actor, (c->>'command_id')::uuid);
  return jsonb_build_array(family.obj('observation', o.id, o.revision));
end $$;

insert into family.command_types(type, fn) values
  ('household.update','cmd_household_update'), ('child.upsert','cmd_child_upsert'), ('child.delete','cmd_child_delete'),
  ('plan.upsert','cmd_plan_upsert'), ('plan.pause','cmd_plan_pause'),
  ('item.propose','cmd_item_propose'), ('item.confirm','cmd_item_confirm'), ('item.correct','cmd_item_correct'),
  ('item.cancel','cmd_item_cancel'), ('item.reschedule','cmd_item_reschedule'),
  ('observation.record','cmd_observation_record'), ('observation.correct','cmd_observation_correct'), ('observation.delete','cmd_observation_delete');

-- ---------- entry point ----------
-- Returns the receipt. Raises FA002 (no receipt) for not_found / idempotency_conflict / shape errors.
create function family.apply_command(p_actor uuid, p_cmd jsonb, p_hash text) returns jsonb
language plpgsql security definer set search_path = family, pg_temp as $$
declare
  cid uuid := family.uuid_or_null(p_cmd,'command_id'); hh uuid := family.uuid_or_null(p_cmd,'household_id');
  typ text := p_cmd->>'type'; rc family.receipts; fn text; objs jsonb; h family.households; err text;
begin
  if p_actor is null or cid is null or hh is null or typ is null then perform family.fail('command_invalid'); end if;
  -- idempotency: (actor, household, command_id); the same id under another household is also a conflict
  insert into family.receipts(actor_user_id, household_id, command_id, type, request_hash, status)
  values (p_actor, hh, cid, typ, p_hash, 'processing') on conflict do nothing;
  if not found then
    select * into rc from family.receipts where actor_user_id = p_actor and command_id = cid;
    if rc.household_id <> hh or rc.request_hash <> p_hash then perform family.fail('idempotency_conflict'); end if;
    if not exists (select 1 from family.households where id = rc.household_id and owner_user_id = p_actor) and typ <> 'household.ensure' then perform family.fail('not_found'); end if;
    return family.receipt_json(rc);
  end if;
  begin
    if typ = 'household.ensure' then
      select * into h from family.households where owner_user_id = p_actor for update;
      if h.id is null then
        if not family.valid_tz(coalesce(p_cmd#>>'{payload,timezone}','Asia/Shanghai')) then perform family.fail('timezone_invalid'); end if;
        insert into family.households(id, owner_user_id, name, timezone)
        values (hh, p_actor, coalesce(family.txt(coalesce(p_cmd->'payload','{}'),'name',80), '我们家'), coalesce(p_cmd#>>'{payload,timezone}','Asia/Shanghai'))
        on conflict (id) do nothing returning * into h;
        if h.id is null then perform family.fail('not_found'); end if; -- id taken by another owner: invisible
        perform family.emit(h.id, 'household.changed', 'household', h.id, h.revision, p_actor, cid);
      end if;
      objs := jsonb_build_array(family.obj('household', h.id, h.revision));
    else
      select * into h from family.households where id = hh and owner_user_id = p_actor and status = 'active' for update; -- serialises per household
      if h.id is null then perform family.fail('not_found'); end if;
      select ct.fn into fn from family.command_types ct where ct.type = typ;
      if fn is null then perform family.fail('command_invalid'); end if;
      execute format('select family.%I($1, $2, $3)', fn) into objs using p_actor, hh, p_cmd;
      update family.households set seq = seq + 1 where id = hh;
    end if;
    perform family.emit(coalesce(h.id, hh), 'command.applied', 'household', coalesce(h.id, hh), h.revision, p_actor, cid);
    update family.receipts set status = 'applied', objects = objs where actor_user_id = p_actor and household_id = hh and command_id = cid returning * into rc;
  exception when sqlstate 'FA001' then
    get stacked diagnostics err = message_text;
    update family.receipts set status = 'rejected', error = jsonb_build_object('code', err,
      'recoverable', case when err in ('revision_conflict','proposal_closed') then 'reread' else 'stop' end)
    where actor_user_id = p_actor and household_id = hh and command_id = cid returning * into rc;
  end;
  return family.receipt_json(rc);
end $$;

create function family.receipt_json(r family.receipts) returns jsonb language sql stable as $$
  select jsonb_build_object('protocol','catpaw.family.v1','schema_version',1,'command_id',r.command_id,'household_id',r.household_id,
    'type', r.type, 'request_hash',r.request_hash,'status',r.status,'objects',r.objects,'error',r.error) $$;

create function family.get_receipt(p_actor uuid, p_command uuid) returns jsonb
language sql stable security definer set search_path = family, pg_temp as $$
  select coalesce(
    (select family.receipt_json(r) || jsonb_build_object('outcome', r.status) from family.receipts r
       where r.actor_user_id = p_actor and r.command_id = p_command
         and exists (select 1 from family.households h where h.owner_user_id = p_actor and (h.id = r.household_id or r.type = 'household.ensure'))),
    jsonb_build_object('protocol','catpaw.family.v1','schema_version',1,'outcome','not_found','command_id',p_command)) $$;

create function family.my_households(p_actor uuid) returns jsonb language sql stable security definer set search_path = family, pg_temp as $$
  select coalesce(jsonb_agg(id), '[]') from family.households where owner_user_id = p_actor and status = 'active' $$;

-- One statement = one snapshot: today / conversation / home are consistent (api-v1 §9).
create function family.projection(p_actor uuid, p_hh uuid, p_date date) returns jsonb
language sql stable security definer set search_path = family, pg_temp as $$
  with h as (select * from family.households where id = p_hh and owner_user_id = p_actor),
  kids as (select * from family.members m where m.household_id = (select id from h) and m.status = 'active')
  select case when not exists (select 1 from h) then null else jsonb_build_object(
    'protocol','catpaw.family.v1','schema_version',1,'household_id',p_hh,
    'projection_revision', (select seq from h), 'local_date', p_date, 'timezone', (select timezone from h),
    'today', jsonb_build_object(
      'schedule', coalesce((select jsonb_agg(jsonb_build_object('item_id',i.id,'revision',i.revision,'title',i.title,'status',i.status,
          'member_id',i.member_id,'child_display_name',k.display_name,'local_date',i.local_date,'local_time',to_char(i.local_time,'HH24:MI'),
          'timezone',i.timezone,'place',i.place,'bring',to_jsonb(i.bring)) order by i.local_time nulls first, i.title)
        from family.items i left join kids k on k.id = i.member_id
        where i.household_id = p_hh and i.status = 'scheduled' and i.confirmed_command_id is not null and i.local_date = p_date), '[]'),
      'pending_confirmations', coalesce((select jsonb_agg(jsonb_build_object('item_id',i.id,'revision',i.revision,'proposal_id',pr.id,
          'title',i.title,'status',i.status,'member_id',i.member_id,'child_display_name',k.display_name,'local_date',i.local_date,
          'local_time',to_char(i.local_time,'HH24:MI'),'place',i.place,'bring',to_jsonb(i.bring),'source_kind',i.source->>'source_kind') order by i.created_at)
        from family.items i join family.proposals pr on pr.target_id = i.id and pr.status = 'open' left join kids k on k.id = i.member_id
        where i.household_id = p_hh and i.status = 'needs_confirmation'), '[]'),
      'reminders', coalesce((select jsonb_agg(jsonb_build_object('reminder_id',r.id,'item_id',r.item_id,'kind',r.kind,'why_now',r.why_now,
          'fire_at',r.fire_at,'revision',r.revision) order by r.fire_at)
        from family.reminders r where r.household_id = p_hh and r.status = 'scheduled' and r.fire_local_date = p_date), '[]')),
    'conversation', jsonb_build_object(
      'open_proposals', coalesce((select jsonb_agg(jsonb_build_object('proposal_id',pr.id,'target_type',pr.target_type,'target_id',pr.target_id,
          'base_revision',pr.base_revision,'revision',pr.revision) order by pr.created_at) from family.proposals pr where pr.household_id = p_hh and pr.status = 'open'), '[]'),
      'recent_receipts', coalesce((select jsonb_agg(x order by x->>'at' desc) from (select jsonb_build_object('command_id',r.command_id,'type',r.type,
          'status',r.status,'objects',r.objects,'at',r.created_at) x from family.receipts r where r.household_id = p_hh and r.actor_user_id = p_actor
          order by r.created_at desc limit 20) q), '[]')),
    'home', jsonb_build_object(
      'household', (select jsonb_build_object('household_id',id,'name',name,'timezone',timezone,'revision',revision) from h),
      'children', coalesce((select jsonb_agg(jsonb_build_object('member_id',k.id,'display_name',k.display_name,'birth_year',k.birth_year,
          'school_label',k.school_label,'class_label',k.class_label,'teacher_label',k.teacher_label,'place_label',k.place_label,'notes',k.notes,
          'revision',k.revision) order by k.created_at) from kids k), '[]'),
      'plans', coalesce((select jsonb_agg(jsonb_build_object('plan_id',p.id,'title',p.title,'member_id',p.member_id,'domain',p.domain,
          'status',p.status,'revision',p.revision) order by p.created_at) from family.plans p where p.household_id = p_hh and p.status <> 'deleted'), '[]'),
      'memories', '[]'::jsonb,
      'observations', coalesce((select jsonb_agg(jsonb_build_object('observation_id',o.id,'member_id',o.member_id,'text',o.text,
          'observed_on',o.observed_on,'source',o.source,'revision',o.revision) order by o.observed_on desc) from family.observations o
          where o.household_id = p_hh and o.status = 'recorded'), '[]'))
  ) end $$;

create function family.changes(p_actor uuid, p_hh uuid, p_after bigint, p_limit integer default 200) returns jsonb
language sql stable security definer set search_path = family, pg_temp as $$
  select case when not exists (select 1 from family.households where id = p_hh and owner_user_id = p_actor) then null else
    coalesce((select jsonb_agg(jsonb_build_object('cursor',e.seq,'event_id',e.event_id,'type',e.type,'schema_version',1,'protocol','catpaw.family.v1',
      'household_id',e.household_id,'aggregate_type',e.aggregate_type,'aggregate_id',e.aggregate_id,'aggregate_revision',e.aggregate_revision,
      'occurred_at',e.occurred_at,'actor_ref',e.actor_ref,'causation_id',e.causation_id,
      'payload_refs',jsonb_build_array(jsonb_build_object('type',e.aggregate_type,'id',e.aggregate_id))) order by e.seq)
     from (select * from family.outbox where household_id = p_hh and seq > coalesce(p_after,0) order by seq limit greatest(1, least(p_limit, 500))) e), '[]') end $$;

revoke execute on all functions in schema family from public, anon, authenticated;
do $$ declare f text; begin
  foreach f in array array['apply_command(uuid,jsonb,text)','get_receipt(uuid,uuid)','my_households(uuid)','projection(uuid,uuid,date)','changes(uuid,uuid,bigint,integer)'] loop
    execute format('revoke all on function family.%s from public, anon, authenticated', f);
    execute format('grant execute on function family.%s to service_role', f);
  end loop;
end $$;
