-- catpaw.family.v1 grant roles + explicit relearn (M3 full-gate findings). WRITTEN ONLY — NOT APPLIED (needs the user's approval).
-- (a) grant role 'caregiver' (household adult, full read of household-visible memories) beside 'viewer' (read-only account).
--     Both stay write-forbidden in v1 (every command from a grantee is a rejected 'forbidden' receipt).
-- (b) memory.upsert payload.explicit_relearn=true: the parent explicitly re-teaches something after a forget; this opens a NEW
--     memory generation (late jobs admitted under the old one stay fenced) and never revives the forgotten row.
alter table family.household_grants drop constraint if exists household_grants_role_check;
alter table family.household_grants add constraint household_grants_role_check check (role in ('viewer','caregiver'));

create or replace function family.cmd_grant_upsert(p_actor uuid, p_hh uuid, c jsonb) returns jsonb language plpgsql as $$
declare g family.household_grants; p jsonb := coalesce(c->'payload','{}'); u uuid := family.uuid_or_null(p,'user_id'); sc uuid[];
  rl text := coalesce(p->>'role','viewer');
begin
  if u is null or u = p_actor or rl not in ('viewer','caregiver') then perform family.fail('command_invalid'); end if;
  if not exists (select 1 from auth.users where id = u) then perform family.reject('user_not_found'); end if;
  if p->'member_scope' is not null and jsonb_typeof(p->'member_scope') = 'array' then
    select array_agg(x::uuid) into sc from jsonb_array_elements_text(p->'member_scope') x;
  end if;
  insert into family.household_grants(household_id, user_id, role, member_scope) values (p_hh, u, rl, sc)
  on conflict (household_id, user_id) do update set role = excluded.role, member_scope = excluded.member_scope, status = 'active',
    revision = family.household_grants.revision + 1, updated_at = now()
  returning * into g;
  return jsonb_build_array(jsonb_build_object('type','grant','id',u,'revision',g.revision));
end $$;

create or replace function family.cmd_memory_upsert_fenced(p_actor uuid, p_hh uuid, c jsonb) returns jsonb language plpgsql as $$
declare g bigint; relearn boolean := false;
begin
  if c->'payload' ? 'explicit_relearn' then
    if jsonb_typeof(c#>'{payload,explicit_relearn}') <> 'boolean' then perform family.fail('command_invalid'); end if;
    relearn := (c#>>'{payload,explicit_relearn}')::boolean;
  end if;
  if c->'payload' ? 'admitted_generation' then
    if jsonb_typeof(c#>'{payload,admitted_generation}') <> 'number' then perform family.fail('command_invalid'); end if;
    select memory_generation into g from family.households where id = p_hh;
    if (c#>>'{payload,admitted_generation}')::bigint < g then perform family.reject('stale_generation'); end if;
  end if;
  if relearn then update family.households set memory_generation = memory_generation + 1 where id = p_hh; end if;
  return family.cmd_memory_upsert(p_actor, p_hh, jsonb_set(c, '{payload}', (c->'payload') - 'admitted_generation' - 'explicit_relearn'));
end $$;

create or replace function family.memory_audit(p_actor uuid, p_hh uuid) returns jsonb language sql stable security definer set search_path = family, pg_temp as $$
  select case when not exists (select 1 from family.households where id = p_hh and owner_user_id = p_actor) then null else jsonb_build_object(
    'household', (select jsonb_build_object('status',status,'memory_paused',memory_paused,'reminders_paused',reminders_paused,'setting_sequence',setting_sequence,
       'memory_generation',memory_generation,'membership_revision',membership_revision,'revision',revision) from family.households where id = p_hh),
    'memories', coalesce((select jsonb_agg(jsonb_build_object('memory_id',id,'revision',revision,'status',status,'kind',kind,'assertion',assertion,'visibility',visibility,
       'member_id',member_id,'valid_from',valid_from,'valid_to',valid_to,'conditions',conditions,'source_ids',to_jsonb(source_ids),'superseded_by',superseded_by)) from family.memories where household_id = p_hh), '[]'),
    'sources', coalesce((select jsonb_agg(jsonb_build_object('source_id',id,'revision',revision,'status',status,'raw_media_available',raw_media_available)) from family.memory_sources where household_id = p_hh), '[]'),
    'grants', coalesce((select jsonb_agg(jsonb_build_object('user_id',user_id,'role',role,'status',status,'revision',revision,'member_scope',to_jsonb(member_scope))) from family.household_grants where household_id = p_hh), '[]'),
    'counts', jsonb_build_object('receipts', (select count(*) from family.receipts where household_id = p_hh), 'outbox', (select count(*) from family.outbox where household_id = p_hh),
       'memories', (select count(*) from family.memories where household_id = p_hh))) end $$;
revoke execute on all functions in schema family from public, anon, authenticated;
grant execute on function family.memory_audit(uuid,uuid) to service_role;
