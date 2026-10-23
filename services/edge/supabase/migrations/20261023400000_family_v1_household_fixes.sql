-- catpaw.family.v1 household fixes (M3 follow-up). WRITTEN ONLY — NOT APPLIED to production (needs the user's approval).
-- (a) household.ensure after household.delete created nothing and returned the ARCHIVED household. One ACTIVE household per
--     owner is now the rule (partial unique index); ensure only looks at the active one, so a re-created household gets a new id.
-- (b) projection/home: an archived household is not_found; home.children lists member_kind='child' only and adults are listed
--     separately under home.adults (items keep the member display name whatever the kind).
alter table family.households drop constraint if exists households_owner_user_id_key;
create unique index if not exists households_one_active_per_owner on family.households(owner_user_id) where status = 'active';

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
    if not exists (select 1 from family.households where id = rc.household_id and owner_user_id = p_actor) and typ <> 'household.ensure' then perform family.fail('not_found'); end if;
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

create or replace function family.projection(p_actor uuid, p_hh uuid, p_date date) returns jsonb
language sql stable security definer set search_path = family, pg_temp as $$
  with h as (select * from family.households where id = p_hh and owner_user_id = p_actor and status = 'active'),
  mem as (select * from family.members m where m.household_id = (select id from h) and m.status = 'active'),
  kids as (select * from mem where member_kind = 'child')
  select case when not exists (select 1 from h) then null else jsonb_build_object(
    'protocol','catpaw.family.v1','schema_version',1,'household_id',p_hh,
    'projection_revision', (select seq from h), 'local_date', p_date, 'timezone', (select timezone from h),
    'today', jsonb_build_object(
      'schedule', coalesce((select jsonb_agg(jsonb_build_object('item_id',i.id,'revision',i.revision,'title',i.title,'status',i.status,
          'member_id',i.member_id,'child_display_name',k.display_name,'local_date',i.local_date,'local_time',to_char(i.local_time,'HH24:MI'),
          'timezone',i.timezone,'place',i.place,'bring',to_jsonb(i.bring)) order by i.local_time nulls first, i.title)
        from family.items i left join mem k on k.id = i.member_id
        where i.household_id = p_hh and i.status = 'scheduled' and i.confirmed_command_id is not null and i.local_date = p_date), '[]'),
      'pending_confirmations', coalesce((select jsonb_agg(jsonb_build_object('item_id',i.id,'revision',i.revision,'proposal_id',pr.id,
          'title',i.title,'status',i.status,'member_id',i.member_id,'child_display_name',k.display_name,'local_date',i.local_date,
          'local_time',to_char(i.local_time,'HH24:MI'),'place',i.place,'bring',to_jsonb(i.bring),'source_kind',i.source->>'source_kind') order by i.created_at)
        from family.items i join family.proposals pr on pr.target_id = i.id and pr.status = 'open' left join mem k on k.id = i.member_id
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
      'adults', coalesce((select jsonb_agg(jsonb_build_object('member_id',a.id,'display_name',a.display_name,'member_kind',a.member_kind,
          'revision',a.revision) order by a.created_at) from mem a where a.member_kind <> 'child'), '[]'),
      'plans', coalesce((select jsonb_agg(jsonb_build_object('plan_id',p.id,'title',p.title,'member_id',p.member_id,'domain',p.domain,
          'status',p.status,'revision',p.revision) order by p.created_at) from family.plans p where p.household_id = p_hh and p.status <> 'deleted'), '[]'),
      'memories', '[]'::jsonb,
      'observations', coalesce((select jsonb_agg(jsonb_build_object('observation_id',o.id,'member_id',o.member_id,'text',o.text,
          'observed_on',o.observed_on,'source',o.source,'revision',o.revision) order by o.observed_on desc) from family.observations o
          where o.household_id = p_hh and o.status = 'recorded'), '[]'))
  ) end $$;

revoke execute on all functions in schema family from public, anon, authenticated;
grant execute on function family.apply_command(uuid,jsonb,text) to service_role;
grant execute on function family.projection(uuid,uuid,date) to service_role;
