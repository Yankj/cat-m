-- catpaw.family.v1 v0.4 (M3 gate findings): no-relearn fence and household deletion. WRITTEN ONLY — NOT APPLIED.
-- (a) households.memory_generation is bumped by every memory.delete; a write that carries payload.admitted_generation
--     older than the current generation (late extraction job admitted before the forget) is rejected stale_generation.
-- (b) household.delete archives the household and tombstones its memories; later commands on it are not_found.
alter table family.households add column if not exists memory_generation bigint not null default 1;

create or replace function family.cmd_memory_upsert_fenced(p_actor uuid, p_hh uuid, c jsonb) returns jsonb language plpgsql as $$
declare g bigint;
begin
  if c->'payload' ? 'admitted_generation' then
    if jsonb_typeof(c#>'{payload,admitted_generation}') <> 'number' then perform family.fail('command_invalid'); end if;
    select memory_generation into g from family.households where id = p_hh;
    if (c#>>'{payload,admitted_generation}')::bigint < g then perform family.reject('stale_generation'); end if;
  end if;
  return family.cmd_memory_upsert(p_actor, p_hh, jsonb_set(c, '{payload}', (c->'payload') - 'admitted_generation'));
end $$;

create or replace function family.cmd_memory_delete_fenced(p_actor uuid, p_hh uuid, c jsonb) returns jsonb language plpgsql as $$
declare r jsonb;
begin
  r := family.cmd_memory_delete(p_actor, p_hh, c);
  update family.households set memory_generation = memory_generation + 1 where id = p_hh;
  return r;
end $$;

create or replace function family.cmd_household_delete(p_actor uuid, p_hh uuid, c jsonb) returns jsonb language plpgsql as $$
declare h family.households;
begin
  select * into h from family.households where id = p_hh and owner_user_id = p_actor for update;
  perform family.need_rev(c, h.revision);
  update family.memories set status = 'deleted', text = '已删除', deleted_at = now(), delete_command_id = (c->>'command_id')::uuid,
    revision = revision + 1, updated_at = now() where household_id = p_hh and status = 'active';
  update family.reminders set status = 'cancelled', revision = revision + 1, updated_at = now() where household_id = p_hh and status = 'scheduled';
  update family.households set status = 'archived', memory_generation = memory_generation + 1, revision = revision + 1, updated_at = now()
    where id = p_hh returning * into h;
  perform family.emit(p_hh, 'household.changed', 'household', p_hh, h.revision, p_actor, (c->>'command_id')::uuid);
  return jsonb_build_array(family.obj('household', p_hh, h.revision));
end $$;

update family.command_types set fn = 'cmd_memory_upsert_fenced' where type = 'memory.upsert';
update family.command_types set fn = 'cmd_memory_delete_fenced' where type = 'memory.delete';
insert into family.command_types(type, fn) values ('household.delete', 'cmd_household_delete');
revoke execute on all functions in schema family from public, anon, authenticated;

-- (c) deleting a member tombstones the facts about that member (a rebuilt member with the same name starts clean).
create or replace function family.cmd_child_delete_cascade(p_actor uuid, p_hh uuid, c jsonb) returns jsonb language plpgsql as $$
declare r jsonb; mid uuid := family.uuid_or_null(c,'target_id'); x record;
begin
  r := family.cmd_child_delete(p_actor, p_hh, c);
  for x in update family.memories set status = 'deleted', text = '已删除', deleted_at = now(), delete_command_id = (c->>'command_id')::uuid,
             revision = revision + 1, updated_at = now() where household_id = p_hh and member_id = mid and status = 'active' returning id, revision loop
    perform family.emit(p_hh, 'memory.deleted', 'memory', x.id, x.revision, p_actor, (c->>'command_id')::uuid);
    r := r || family.obj('memory', x.id, x.revision);
  end loop;
  update family.households set memory_generation = memory_generation + 1 where id = p_hh;
  return r;
end $$;
update family.command_types set fn = 'cmd_child_delete_cascade' where type = 'child.delete';
revoke execute on all functions in schema family from public, anon, authenticated;
