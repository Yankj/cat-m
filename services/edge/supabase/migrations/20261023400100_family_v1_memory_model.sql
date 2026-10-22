-- catpaw.family.v1 memory model (M3 follow-up). WRITTEN ONLY — NOT APPLIED to production (needs the user's approval).
-- (a) kinds fact/preference/observation/inference/plan_reference; statuses active/proposed/disputed/retracted/rejected/deleted.
--     'disputed' is stored as disputed (was silently active) and recalled WITH that status; inference is always 'proposed'
--     until memory.confirm; proposed/rejected are never recalled.
-- (b) memory sources (no raw text stored): retract / revoke_access retract every dependent memory; expire_media keeps the
--     confirmed text. (c) memory.settings with a monotonic choice_sequence (late/stale choices ignored, rejected stale_sequence).
-- (d) memory.share needs visibility_confirmed; memory.restore of a forgotten fact is rejected undo_expired (no undo window).
-- (e) read-only household grants (viewer, optional member scope): grantees can recall household-visible memories in scope;
--     every command from a grantee is a rejected 'forbidden' receipt; a revoked grant is not_found.
alter table family.memories drop constraint if exists memories_kind_check;
alter table family.memories add constraint memories_kind_check check (kind in ('fact','preference','observation','inference','plan_reference'));
alter table family.memories drop constraint if exists memories_status_check;
alter table family.memories add constraint memories_status_check check (status in ('active','proposed','disputed','retracted','rejected','deleted'));
alter table family.memories add column if not exists assertion text not null default 'explicit' check (assertion in ('explicit','inference'));
alter table family.memories add column if not exists conditions jsonb check (conditions is null or jsonb_typeof(conditions) = 'object');
alter table family.memories add column if not exists sensitivity text not null default 'normal' check (sensitivity in ('normal','sensitive'));
alter table family.memories add column if not exists source_ids uuid[] not null default '{}';
alter table family.households add column if not exists setting_sequence bigint not null default 0;

create table family.memory_sources (
  id uuid primary key,
  household_id uuid not null references family.households(id) on delete cascade,
  kind text not null check (kind in ('user_text','user_voice_transcript','image_notice','assistant_inference','external_advice','unknown')),
  trust text not null check (trust in ('user_direct','external','assistant','unknown')),
  status text not null default 'active' check (status in ('active','retracted','access_revoked')),
  retention_mode text not null default 'confirmed_text_only' check (char_length(retention_mode) between 1 and 40),
  raw_media_available boolean not null default false,
  revision integer not null default 1,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table family.household_grants (
  household_id uuid not null references family.households(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null default 'viewer' check (role = 'viewer'),
  member_scope uuid[],
  status text not null default 'active' check (status in ('active','revoked')),
  revision integer not null default 1,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  primary key (household_id, user_id)
);
alter table family.memory_sources enable row level security;
alter table family.household_grants enable row level security;
revoke all on family.memory_sources, family.household_grants from public, anon, authenticated;
grant all on family.memory_sources, family.household_grants to service_role;

-- reader: owner (active household) or active viewer grant; null = invisible (404)
create function family.reader(p_actor uuid, p_hh uuid) returns jsonb language sql stable security definer set search_path = family, pg_temp as $$
  select coalesce(
    (select jsonb_build_object('role','owner','scope',null) from family.households where id = p_hh and owner_user_id = p_actor and status = 'active'),
    (select jsonb_build_object('role',g.role,'scope',to_jsonb(g.member_scope)) from family.household_grants g join family.households h on h.id = g.household_id
      where g.household_id = p_hh and g.user_id = p_actor and g.status = 'active' and h.status = 'active')) $$;

create function family.source_ids(p jsonb, p_hh uuid) returns uuid[] language plpgsql stable as $$
declare r uuid[] := '{}'; e jsonb;
begin
  if p->'source_ids' is null or jsonb_typeof(p->'source_ids') = 'null' then return r; end if;
  if jsonb_typeof(p->'source_ids') <> 'array' or jsonb_array_length(p->'source_ids') > 8 then perform family.fail('command_invalid'); end if;
  for e in select * from jsonb_array_elements(p->'source_ids') loop
    if jsonb_typeof(e) <> 'string' or (e#>>'{}') !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then perform family.fail('command_invalid'); end if;
    if not exists (select 1 from family.memory_sources s where s.id = (e#>>'{}')::uuid and s.household_id = p_hh) then perform family.reject('source_not_found'); end if;
    if exists (select 1 from family.memory_sources s where s.id = (e#>>'{}')::uuid and s.status <> 'active') then perform family.reject('source_inactive'); end if;
    r := r || (e#>>'{}')::uuid;
  end loop;
  return r;
end $$;

create or replace function family.cmd_memory_upsert(p_actor uuid, p_hh uuid, c jsonb) returns jsonb language plpgsql as $$
declare m family.memories; p jsonb := coalesce(c->'payload','{}'); v_id uuid := family.uuid_or_null(c,'target_id'); mid uuid := family.uuid_or_null(p,'member_id');
  k text := coalesce(family.txt(p,'kind',20),'fact'); a text := coalesce(family.txt(p,'assertion',20),'explicit');
  st text := coalesce(family.txt(p,'status',20),'active'); sens text := coalesce(family.txt(p,'sensitivity',20),'normal');
begin
  if (select memory_paused from family.households where id = p_hh) then perform family.reject('memory_paused'); end if;
  if k not in ('fact','preference','observation','inference','plan_reference') or a not in ('explicit','inference')
     or st not in ('active','proposed','disputed') or sens not in ('normal','sensitive') then perform family.fail('command_invalid'); end if;
  if p ? 'conditions' and jsonb_typeof(p->'conditions') not in ('object','null') then perform family.fail('command_invalid'); end if;
  if k = 'inference' or a = 'inference' then st := 'proposed'; end if;   -- a guess never becomes a fact without memory.confirm
  perform family.active_member(p_hh, mid);
  if v_id is not null then select * into m from family.memories where id = v_id for update; end if;
  if m.id is not null and m.household_id <> p_hh then perform family.fail('not_found'); end if;
  if m.id is null then
    insert into family.memories(id, household_id, member_id, text, kind, assertion, status, sensitivity, conditions, source_ids, visibility, valid_from, valid_to, source)
    values (coalesce(v_id, gen_random_uuid()), p_hh, mid, family.txt(p,'text',500,true), k, a, st, sens, nullif(p->'conditions','null'::jsonb), family.source_ids(p, p_hh),
            coalesce(family.txt(p,'visibility',16),'household'), family.ts(p,'valid_from'), family.ts(p,'valid_to'), family.source_ok(p->'source'))
    returning * into m;
  else
    if m.status in ('deleted','retracted','rejected') then perform family.reject('previously_deleted'); end if;  -- never relearn by id
    perform family.need_rev(c, m.revision);
    update family.memories set text = coalesce(family.txt(p,'text',500), text), source = coalesce(family.source_ok(p->'source'), source),
      revision = revision + 1, updated_at = now() where id = m.id returning * into m;
  end if;
  perform family.emit(p_hh, 'memory.changed', 'memory', m.id, m.revision, p_actor, (c->>'command_id')::uuid);
  return jsonb_build_array(family.obj('memory', m.id, m.revision));
end $$;

create function family.memory_target(p_hh uuid, c jsonb) returns family.memories language plpgsql as $$
declare m family.memories;
begin
  select * into m from family.memories where id = family.uuid_or_null(c,'target_id') and household_id = p_hh for update;
  if m.id is null then perform family.fail('not_found'); end if;
  return m;
end $$;

create function family.cmd_memory_confirm(p_actor uuid, p_hh uuid, c jsonb) returns jsonb language plpgsql as $$
declare m family.memories := family.memory_target(p_hh, c);
begin
  if m.status <> 'proposed' then perform family.reject('invalid_state'); end if;
  perform family.need_rev(c, m.revision);
  -- an inference confirmed by the user becomes an explicit statement of the same kind; observations stay observations
  update family.memories set status = 'active', assertion = 'explicit', kind = case when kind = 'inference' then 'fact' else kind end,
    revision = revision + 1, updated_at = now() where id = m.id returning * into m;
  perform family.emit(p_hh, 'memory.changed', 'memory', m.id, m.revision, p_actor, (c->>'command_id')::uuid);
  return jsonb_build_array(family.obj('memory', m.id, m.revision));
end $$;

create function family.cmd_memory_reject(p_actor uuid, p_hh uuid, c jsonb) returns jsonb language plpgsql as $$
declare m family.memories := family.memory_target(p_hh, c);
begin
  if m.status <> 'proposed' then perform family.reject('invalid_state'); end if;
  perform family.need_rev(c, m.revision);
  update family.memories set status = 'rejected', text = '已拒绝', revision = revision + 1, updated_at = now() where id = m.id returning * into m;
  perform family.emit(p_hh, 'memory.changed', 'memory', m.id, m.revision, p_actor, (c->>'command_id')::uuid);
  return jsonb_build_array(family.obj('memory', m.id, m.revision));
end $$;

create function family.cmd_memory_share(p_actor uuid, p_hh uuid, c jsonb) returns jsonb language plpgsql as $$
declare m family.memories := family.memory_target(p_hh, c);
begin
  if m.status not in ('active','disputed') then perform family.reject('invalid_state'); end if;
  if jsonb_typeof(c#>'{payload,visibility_confirmed}') is distinct from 'boolean' or not (c#>>'{payload,visibility_confirmed}')::boolean then
    perform family.reject('visibility_confirmation_required'); end if;
  perform family.need_rev(c, m.revision);
  update family.memories set visibility = 'household', revision = revision + 1, updated_at = now() where id = m.id returning * into m;
  perform family.emit(p_hh, 'memory.changed', 'memory', m.id, m.revision, p_actor, (c->>'command_id')::uuid);
  return jsonb_build_array(family.obj('memory', m.id, m.revision));
end $$;

create function family.cmd_memory_restore(p_actor uuid, p_hh uuid, c jsonb) returns jsonb language plpgsql as $$
declare m family.memories := family.memory_target(p_hh, c);
begin
  if m.status = 'deleted' then perform family.reject('undo_expired'); end if;  -- v1 has no undo window: forget is final
  perform family.reject('invalid_state');
  return '[]';
end $$;

create function family.cmd_memory_settings(p_actor uuid, p_hh uuid, c jsonb) returns jsonb language plpgsql as $$
declare h family.households; p jsonb := coalesce(c->'payload','{}');
begin
  if jsonb_typeof(p->'use_memory') is distinct from 'boolean' or jsonb_typeof(p->'choice_sequence') is distinct from 'number' or (p->>'choice_sequence')::bigint < 1 then
    perform family.fail('command_invalid'); end if;
  select * into h from family.households where id = p_hh for update;
  if (p->>'choice_sequence')::bigint <= h.setting_sequence then perform family.reject('stale_sequence'); end if;  -- a late older choice never wins
  update family.households set memory_paused = not (p->>'use_memory')::boolean, setting_sequence = (p->>'choice_sequence')::bigint,
    revision = revision + 1, updated_at = now() where id = p_hh returning * into h;
  perform family.emit(p_hh, 'household.changed', 'household', p_hh, h.revision, p_actor, (c->>'command_id')::uuid);
  return jsonb_build_array(family.obj('household', p_hh, h.revision));
end $$;

create function family.cmd_source_register(p_actor uuid, p_hh uuid, c jsonb) returns jsonb language plpgsql as $$
declare s family.memory_sources; p jsonb := coalesce(c->'payload','{}');
begin
  if coalesce(p->>'kind','') not in ('user_text','user_voice_transcript','image_notice','assistant_inference','external_advice','unknown')
     or coalesce(p->>'trust','') not in ('user_direct','external','assistant','unknown')
     or (p ? 'raw_media_available' and jsonb_typeof(p->'raw_media_available') <> 'boolean') then perform family.fail('command_invalid'); end if;
  insert into family.memory_sources(id, household_id, kind, trust, retention_mode, raw_media_available)
  values (coalesce(family.uuid_or_null(p,'source_id'), gen_random_uuid()), p_hh, p->>'kind', p->>'trust',
          coalesce(family.txt(p,'retention_mode',40),'confirmed_text_only'), coalesce((p->>'raw_media_available')::boolean, false))
  on conflict (id) do nothing returning * into s;
  if s.id is null then perform family.reject('source_exists'); end if;
  return jsonb_build_array(family.obj('source', s.id, s.revision));
end $$;

create function family.source_close(p_actor uuid, p_hh uuid, c jsonb, p_status text) returns jsonb language plpgsql as $$
declare s family.memory_sources; r jsonb; x record;
begin
  select * into s from family.memory_sources where id = family.uuid_or_null(c,'target_id') and household_id = p_hh for update;
  if s.id is null then perform family.fail('not_found'); end if;
  if s.status <> 'active' then perform family.reject('invalid_state'); end if;
  perform family.need_rev(c, s.revision);
  update family.memory_sources set status = p_status, raw_media_available = false, revision = revision + 1, updated_at = now() where id = s.id returning * into s;
  r := jsonb_build_array(family.obj('source', s.id, s.revision));
  for x in update family.memories set status = 'retracted', revision = revision + 1, updated_at = now()
           where household_id = p_hh and s.id = any(source_ids) and status in ('active','proposed','disputed') returning id, revision loop
    perform family.emit(p_hh, 'memory.changed', 'memory', x.id, x.revision, p_actor, (c->>'command_id')::uuid);
    r := r || family.obj('memory', x.id, x.revision);
  end loop;
  update family.households set memory_generation = memory_generation + 1 where id = p_hh;
  return r;
end $$;
create function family.cmd_source_retract(p_actor uuid, p_hh uuid, c jsonb) returns jsonb language sql as $$ select family.source_close(p_actor, p_hh, c, 'retracted') $$;
create function family.cmd_source_revoke_access(p_actor uuid, p_hh uuid, c jsonb) returns jsonb language sql as $$ select family.source_close(p_actor, p_hh, c, 'access_revoked') $$;
create function family.cmd_source_expire_media(p_actor uuid, p_hh uuid, c jsonb) returns jsonb language plpgsql as $$
declare s family.memory_sources;
begin
  select * into s from family.memory_sources where id = family.uuid_or_null(c,'target_id') and household_id = p_hh for update;
  if s.id is null then perform family.fail('not_found'); end if;
  update family.memory_sources set raw_media_available = false, revision = revision + 1, updated_at = now() where id = s.id returning * into s;
  return jsonb_build_array(family.obj('source', s.id, s.revision));   -- confirmed memory text is kept
end $$;

create function family.cmd_grant_upsert(p_actor uuid, p_hh uuid, c jsonb) returns jsonb language plpgsql as $$
declare g family.household_grants; p jsonb := coalesce(c->'payload','{}'); u uuid := family.uuid_or_null(p,'user_id'); sc uuid[];
begin
  if u is null or u = p_actor or coalesce(p->>'role','viewer') <> 'viewer' then perform family.fail('command_invalid'); end if;
  if not exists (select 1 from auth.users where id = u) then perform family.reject('user_not_found'); end if;
  if p->'member_scope' is not null and jsonb_typeof(p->'member_scope') = 'array' then
    select array_agg(x::uuid) into sc from jsonb_array_elements_text(p->'member_scope') x;
  end if;
  insert into family.household_grants(household_id, user_id, member_scope) values (p_hh, u, sc)
  on conflict (household_id, user_id) do update set member_scope = excluded.member_scope, status = 'active',
    revision = family.household_grants.revision + 1, updated_at = now()
  returning * into g;
  return jsonb_build_array(jsonb_build_object('type','grant','id',u,'revision',g.revision));
end $$;
create function family.cmd_grant_revoke(p_actor uuid, p_hh uuid, c jsonb) returns jsonb language plpgsql as $$
declare g family.household_grants; u uuid := family.uuid_or_null(coalesce(c->'payload','{}'),'user_id');
begin
  select * into g from family.household_grants where household_id = p_hh and user_id = u for update;
  if g.user_id is null then perform family.fail('not_found'); end if;
  if g.status = 'revoked' then perform family.reject('invalid_state'); end if;
  update family.household_grants set status = 'revoked', revision = revision + 1, updated_at = now() where household_id = p_hh and user_id = u returning * into g;
  return jsonb_build_array(jsonb_build_object('type','grant','id',u,'revision',g.revision));
end $$;

-- tombstones now cover every live status (proposed / disputed candidates included)
create or replace function family.cmd_household_delete(p_actor uuid, p_hh uuid, c jsonb) returns jsonb language plpgsql as $$
declare h family.households;
begin
  select * into h from family.households where id = p_hh and owner_user_id = p_actor for update;
  perform family.need_rev(c, h.revision);
  update family.memories set status = 'deleted', text = '已删除', deleted_at = now(), delete_command_id = (c->>'command_id')::uuid,
    revision = revision + 1, updated_at = now() where household_id = p_hh and status in ('active','proposed','disputed');
  update family.reminders set status = 'cancelled', revision = revision + 1, updated_at = now() where household_id = p_hh and status = 'scheduled';
  update family.household_grants set status = 'revoked', revision = revision + 1, updated_at = now() where household_id = p_hh and status = 'active';
  update family.households set status = 'archived', memory_generation = memory_generation + 1, revision = revision + 1, updated_at = now()
    where id = p_hh returning * into h;
  perform family.emit(p_hh, 'household.changed', 'household', p_hh, h.revision, p_actor, (c->>'command_id')::uuid);
  return jsonb_build_array(family.obj('household', p_hh, h.revision));
end $$;
create or replace function family.cmd_child_delete_cascade(p_actor uuid, p_hh uuid, c jsonb) returns jsonb language plpgsql as $$
declare r jsonb; mid uuid := family.uuid_or_null(c,'target_id'); x record;
begin
  r := family.cmd_child_delete(p_actor, p_hh, c);
  for x in update family.memories set status = 'deleted', text = '已删除', deleted_at = now(), delete_command_id = (c->>'command_id')::uuid,
             revision = revision + 1, updated_at = now() where household_id = p_hh and member_id = mid and status in ('active','proposed','disputed') returning id, revision loop
    perform family.emit(p_hh, 'memory.deleted', 'memory', x.id, x.revision, p_actor, (c->>'command_id')::uuid);
    r := r || family.obj('memory', x.id, x.revision);
  end loop;
  update family.households set memory_generation = memory_generation + 1 where id = p_hh;
  return r;
end $$;

insert into family.command_types(type, fn) values
  ('memory.confirm','cmd_memory_confirm'), ('memory.reject','cmd_memory_reject'), ('memory.share','cmd_memory_share'),
  ('memory.restore','cmd_memory_restore'), ('memory.settings','cmd_memory_settings'),
  ('source.register','cmd_source_register'), ('source.retract','cmd_source_retract'), ('source.revoke_access','cmd_source_revoke_access'),
  ('source.expire_media','cmd_source_expire_media'), ('grant.upsert','cmd_grant_upsert'), ('grant.revoke','cmd_grant_revoke');

-- Recall / listing candidates. p_at null = 我们家 listing (live statuses incl. proposed); p_at set = recall (active + disputed,
-- validity window at p_at). Grantees see household-visible rows in their member scope only.
drop function if exists family.memories_for(uuid,uuid,timestamptz,uuid,text);
create function family.memories_for(p_actor uuid, p_hh uuid, p_at timestamptz, p_member uuid, p_visibility text default 'household') returns jsonb
language sql stable security definer set search_path = family, pg_temp as $$
  with rd as (select family.reader(p_actor, p_hh) r),
  sc as (select case when jsonb_typeof(r->'scope') = 'array' then array(select jsonb_array_elements_text(r->'scope'))::uuid[] end s, r->>'role' role from rd)
  select case when (select r from rd) is null then null
    when (select memory_paused from family.households where id = p_hh) and p_at is not null then '[]'::jsonb else
    coalesce((select jsonb_agg(jsonb_build_object('memory_id',m.id,'member_id',m.member_id,'text',m.text,'kind',m.kind,'assertion',m.assertion,
      'status',m.status,'sensitivity',m.sensitivity,'conditions',m.conditions,'visibility',m.visibility,'source_ids',to_jsonb(m.source_ids),
      'valid_from',m.valid_from,'valid_to',m.valid_to,'source',m.source,'revision',m.revision) order by m.updated_at desc)
     from family.memories m, sc
     where m.household_id = p_hh
       and m.status = any(case when p_at is null then array['active','disputed','proposed'] else array['active','disputed'] end)
       and (p_at is null or ((m.valid_from is null or m.valid_from <= p_at) and (m.valid_to is null or m.valid_to > p_at)))
       and (p_member is null or m.member_id is null or m.member_id = p_member)
       and (case when sc.role = 'owner' then (p_visibility = 'all' or m.visibility = p_visibility) else m.visibility = 'household' end)
       and (sc.s is null or m.member_id = any(sc.s))
       and not exists (select 1 from family.memory_sources s where s.id = any(m.source_ids) and s.status <> 'active')), '[]') end $$;

-- Re-verify refs right before output / dispatch (frozen snapshots, stale index hits, late results): only refs that are still
-- live, same revision, readable by THIS actor now, survive.
create function family.resolve_refs(p_actor uuid, p_hh uuid, p_refs jsonb) returns jsonb
language sql stable security definer set search_path = family, pg_temp as $$
  with live as (select x from jsonb_array_elements(coalesce(family.memories_for(p_actor, p_hh, now(), null, 'all'), '[]')) x)
  select case when family.reader(p_actor, p_hh) is null then null else jsonb_build_object(
    'allowed', coalesce((select jsonb_agg(r) from jsonb_array_elements(p_refs) r where exists (select 1 from live where live.x->>'memory_id' = r->>'memory_id' and (live.x->>'revision')::int = (r->>'revision')::int)), '[]'),
    'fenced', coalesce((select jsonb_agg(r) from jsonb_array_elements(p_refs) r where not exists (select 1 from live where live.x->>'memory_id' = r->>'memory_id' and (live.x->>'revision')::int = (r->>'revision')::int)), '[]')) end $$;

create or replace function family.settings_for(p_actor uuid, p_hh uuid) returns jsonb language sql stable security definer set search_path = family, pg_temp as $$
  select jsonb_build_object('memory_paused', memory_paused, 'reminders_paused', reminders_paused, 'revision', revision,
    'setting_sequence', setting_sequence, 'memory_generation', memory_generation)
  from family.households where id = p_hh and owner_user_id = p_actor $$;

-- Owner-only authoritative readback (also for archived households): every memory row incl. tombstones, sources, grants.
create function family.memory_audit(p_actor uuid, p_hh uuid) returns jsonb language sql stable security definer set search_path = family, pg_temp as $$
  select case when not exists (select 1 from family.households where id = p_hh and owner_user_id = p_actor) then null else jsonb_build_object(
    'household', (select jsonb_build_object('status',status,'memory_paused',memory_paused,'reminders_paused',reminders_paused,'setting_sequence',setting_sequence,
       'memory_generation',memory_generation,'revision',revision) from family.households where id = p_hh),
    'memories', coalesce((select jsonb_agg(jsonb_build_object('memory_id',id,'revision',revision,'status',status,'kind',kind,'assertion',assertion,'visibility',visibility,
       'member_id',member_id,'valid_from',valid_from,'valid_to',valid_to,'conditions',conditions,'source_ids',to_jsonb(source_ids))) from family.memories where household_id = p_hh), '[]'),
    'sources', coalesce((select jsonb_agg(jsonb_build_object('source_id',id,'revision',revision,'status',status,'raw_media_available',raw_media_available)) from family.memory_sources where household_id = p_hh), '[]'),
    'grants', coalesce((select jsonb_agg(jsonb_build_object('user_id',user_id,'status',status,'revision',revision,'member_scope',to_jsonb(member_scope))) from family.household_grants where household_id = p_hh), '[]'),
    'counts', jsonb_build_object('receipts', (select count(*) from family.receipts where household_id = p_hh), 'outbox', (select count(*) from family.outbox where household_id = p_hh))) end $$;

create or replace function family.apply_command(p_actor uuid, p_cmd jsonb, p_hash text) returns jsonb
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
    if not exists (select 1 from family.households where id = rc.household_id and owner_user_id = p_actor)
       and not exists (select 1 from family.household_grants g where g.household_id = rc.household_id and g.user_id = p_actor and g.status = 'active') and typ <> 'household.ensure' then perform family.fail('not_found'); end if;
    return family.receipt_json(rc);
  end if;
  begin
    if typ = 'household.ensure' then
      select * into h from family.households where owner_user_id = p_actor and status = 'active' for update; -- an archived (deleted) household is never resurrected
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
      if h.id is null then
        -- an active read-only grantee gets a durable 'forbidden' rejection; anyone else: invisible
        if exists (select 1 from family.household_grants g join family.households x on x.id = g.household_id where g.household_id = hh and g.user_id = p_actor and g.status = 'active' and x.status = 'active')
        then perform family.reject('forbidden'); end if;
        perform family.fail('not_found');
      end if;
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

revoke execute on all functions in schema family from public, anon, authenticated;
do $$ declare f text; begin
  foreach f in array array['apply_command(uuid,jsonb,text)','memories_for(uuid,uuid,timestamptz,uuid,text)','settings_for(uuid,uuid)','reader(uuid,uuid)',
    'resolve_refs(uuid,uuid,jsonb)','memory_audit(uuid,uuid)'] loop
    execute format('grant execute on function family.%s to service_role', f);
  end loop;
end $$;
