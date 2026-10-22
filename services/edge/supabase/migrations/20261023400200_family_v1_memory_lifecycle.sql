-- catpaw.family.v1 memory lifecycle (M3 full-gate findings). WRITTEN ONLY — NOT APPLIED to production (needs the user's approval).
-- (a) 'superseded' status + memory.supersede: replacing a fact by ANOTHER memory (e.g. an old summary copy replaced by the
--     authoritative plan) keeps the old row as superseded instead of forgetting it; superseded rows are never recalled.
-- (b) memory_generation now moves ONLY on forget (memory.delete / household.delete). Source retraction and member removal
--     no longer bump it: late writes from a closed source are rejected source_inactive, about a removed member member_not_found.
-- (c) households.membership_revision counts membership changes (member added/removed, grant upserted/revoked).
-- (d) closing a source no longer clears raw_media_available; media expiry is its own command (source.expire_media).
alter table family.memories drop constraint if exists memories_status_check;
alter table family.memories add constraint memories_status_check check (status in ('active','proposed','disputed','superseded','retracted','rejected','deleted'));
alter table family.memories add column if not exists superseded_by uuid;
alter table family.households add column if not exists membership_revision integer not null default 1;

create function family.cmd_memory_supersede(p_actor uuid, p_hh uuid, c jsonb) returns jsonb language plpgsql as $$
declare m family.memories := family.memory_target(p_hh, c); v_by uuid := family.uuid_or_null(coalesce(c->'payload','{}'),'by_id');
begin
  if m.status not in ('active','disputed') then perform family.reject('invalid_state'); end if;
  if v_by is not null and not exists (select 1 from family.memories where id = v_by and household_id = p_hh and status in ('active','disputed')) then perform family.reject('not_found'); end if;
  perform family.need_rev(c, m.revision);
  update family.memories set status = 'superseded', superseded_by = v_by, revision = revision + 1, updated_at = now() where id = m.id returning * into m;
  perform family.emit(p_hh, 'memory.changed', 'memory', m.id, m.revision, p_actor, (c->>'command_id')::uuid);
  return jsonb_build_array(family.obj('memory', m.id, m.revision));
end $$;
insert into family.command_types(type, fn) values ('memory.supersede','cmd_memory_supersede');

create or replace function family.source_close(p_actor uuid, p_hh uuid, c jsonb, p_status text) returns jsonb language plpgsql as $$
declare s family.memory_sources; r jsonb; x record;
begin
  select * into s from family.memory_sources where id = family.uuid_or_null(c,'target_id') and household_id = p_hh for update;
  if s.id is null then perform family.fail('not_found'); end if;
  if s.status <> 'active' then perform family.reject('invalid_state'); end if;
  perform family.need_rev(c, s.revision);
  update family.memory_sources set status = p_status, revision = revision + 1, updated_at = now() where id = s.id returning * into s;
  r := jsonb_build_array(family.obj('source', s.id, s.revision));
  for x in update family.memories set status = 'retracted', revision = revision + 1, updated_at = now()
           where household_id = p_hh and s.id = any(source_ids) and status in ('active','proposed','disputed') returning id, revision loop
    perform family.emit(p_hh, 'memory.changed', 'memory', x.id, x.revision, p_actor, (c->>'command_id')::uuid);
    r := r || family.obj('memory', x.id, x.revision);
  end loop;
  return r;
end $$;

create or replace function family.cmd_child_delete_cascade(p_actor uuid, p_hh uuid, c jsonb) returns jsonb language plpgsql as $$
declare r jsonb; mid uuid := family.uuid_or_null(c,'target_id'); x record;
begin
  r := family.cmd_child_delete(p_actor, p_hh, c);
  for x in update family.memories set status = 'deleted', text = '已删除', deleted_at = now(), delete_command_id = (c->>'command_id')::uuid,
             revision = revision + 1, updated_at = now() where household_id = p_hh and member_id = mid and status in ('active','proposed','disputed','superseded') returning id, revision loop
    perform family.emit(p_hh, 'memory.deleted', 'memory', x.id, x.revision, p_actor, (c->>'command_id')::uuid);
    r := r || family.obj('memory', x.id, x.revision);
  end loop;
  update family.households set membership_revision = membership_revision + 1 where id = p_hh;
  return r;
end $$;

-- membership changes: new member, grant upsert / revoke
create or replace function family.cmd_member_kind(p_actor uuid, p_hh uuid, c jsonb) returns jsonb language plpgsql as $$
declare r jsonb; k text := coalesce(c#>>'{payload,member_kind}','child'); is_new boolean := c->>'target_id' is null;
begin
  if k not in ('child','adult','other') then perform family.fail('command_invalid'); end if;
  r := family.cmd_child_upsert(p_actor, p_hh, jsonb_set(c, '{payload}', coalesce(c->'payload','{}') - 'member_kind'));
  update family.members set member_kind = k where id = (r->0->>'id')::uuid;
  if is_new then update family.households set membership_revision = membership_revision + 1 where id = p_hh; end if;
  return r;
end $$;
create or replace function family.cmd_grant_upsert_counted(p_actor uuid, p_hh uuid, c jsonb) returns jsonb language plpgsql as $$
declare r jsonb := family.cmd_grant_upsert(p_actor, p_hh, c);
begin update family.households set membership_revision = membership_revision + 1 where id = p_hh; return r; end $$;
create or replace function family.cmd_grant_revoke_counted(p_actor uuid, p_hh uuid, c jsonb) returns jsonb language plpgsql as $$
declare r jsonb := family.cmd_grant_revoke(p_actor, p_hh, c);
begin update family.households set membership_revision = membership_revision + 1 where id = p_hh; return r; end $$;
update family.command_types set fn = 'cmd_grant_upsert_counted' where type = 'grant.upsert';
update family.command_types set fn = 'cmd_grant_revoke_counted' where type = 'grant.revoke';

create or replace function family.memory_audit(p_actor uuid, p_hh uuid) returns jsonb language sql stable security definer set search_path = family, pg_temp as $$
  select case when not exists (select 1 from family.households where id = p_hh and owner_user_id = p_actor) then null else jsonb_build_object(
    'household', (select jsonb_build_object('status',status,'memory_paused',memory_paused,'reminders_paused',reminders_paused,'setting_sequence',setting_sequence,
       'memory_generation',memory_generation,'membership_revision',membership_revision,'revision',revision) from family.households where id = p_hh),
    'memories', coalesce((select jsonb_agg(jsonb_build_object('memory_id',id,'revision',revision,'status',status,'kind',kind,'assertion',assertion,'visibility',visibility,
       'member_id',member_id,'valid_from',valid_from,'valid_to',valid_to,'conditions',conditions,'source_ids',to_jsonb(source_ids),'superseded_by',superseded_by)) from family.memories where household_id = p_hh), '[]'),
    'sources', coalesce((select jsonb_agg(jsonb_build_object('source_id',id,'revision',revision,'status',status,'raw_media_available',raw_media_available)) from family.memory_sources where household_id = p_hh), '[]'),
    'grants', coalesce((select jsonb_agg(jsonb_build_object('user_id',user_id,'status',status,'revision',revision,'member_scope',to_jsonb(member_scope))) from family.household_grants where household_id = p_hh), '[]'),
    'counts', jsonb_build_object('receipts', (select count(*) from family.receipts where household_id = p_hh), 'outbox', (select count(*) from family.outbox where household_id = p_hh),
       'memories', (select count(*) from family.memories where household_id = p_hh))) end $$;

revoke execute on all functions in schema family from public, anon, authenticated;
grant execute on function family.memory_audit(uuid,uuid) to service_role;
