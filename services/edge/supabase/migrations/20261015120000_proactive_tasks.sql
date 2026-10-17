-- catpaw proactive tasks / reminders backend (additive; does not touch public.records or catpaw.* stores)
create schema if not exists proactive;
grant usage on schema proactive to authenticated, service_role;

create table if not exists proactive.tasks (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  conversation_id uuid,
  source_turn_id uuid,
  operation_id uuid not null,                 -- client/agent idempotency key
  title text not null check (char_length(title) between 1 and 512),
  notes text check (notes is null or char_length(notes) <= 4000),
  due_at timestamptz,
  time_zone text not null default 'Asia/Shanghai',
  recurrence jsonb,                           -- null | {"freq":"daily|weekly|monthly|interval","interval":n,"interval_seconds":n,"until":iso,"count":n}
  status text not null default 'open' check (status in ('open','done','cancelled','snoozed')),
  remind_lead_seconds integer not null default 0 check (remind_lead_seconds between 0 and 604800),
  snooze_until timestamptz,
  next_fire_at timestamptz,                   -- scheduler cursor; null = nothing pending
  fire_count integer not null default 0,
  created_by text not null default 'user' check (created_by in ('user','agent')),
  revision integer not null default 1,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, operation_id)
);
create index if not exists tasks_user_idx on proactive.tasks(user_id, status, due_at);
create index if not exists tasks_due_idx on proactive.tasks(next_fire_at) where status in ('open','snoozed') and next_fire_at is not null;

-- one row per fired reminder occurrence (idempotency for scheduler)
create table if not exists proactive.reminder_occurrences (
  task_id uuid not null references proactive.tasks(id) on delete cascade,
  scheduled_at timestamptz not null,
  user_id uuid not null references auth.users(id) on delete cascade,
  state text not null default 'claimed' check (state in ('claimed','generated','failed')),
  claimed_at timestamptz not null default now(),
  primary key (task_id, scheduled_at)
);

-- outbox of proactive events (in-app feed + push fan-out)
create table if not exists proactive.events (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  task_id uuid references proactive.tasks(id) on delete set null,
  conversation_id uuid,
  kind text not null check (kind in ('reminder_due','task_created','task_updated','agent_message')),
  title text not null,
  body text not null,
  payload jsonb not null default '{}'::jsonb,
  dedupe_key text not null,
  push_state text not null default 'pending' check (push_state in ('pending','sent','skipped','failed','no_device')),
  push_attempts integer not null default 0,
  push_error text,
  read_at timestamptz,
  created_at timestamptz not null default now(),
  unique (user_id, dedupe_key)
);
create index if not exists events_user_idx on proactive.events(user_id, created_at desc);
create index if not exists events_push_idx on proactive.events(created_at) where push_state = 'pending';

create table if not exists proactive.device_push_tokens (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  device_id text not null check (char_length(device_id) between 1 and 200),
  kind text not null check (kind in ('apns','live_activity_update','live_activity_start')),
  token text not null check (char_length(token) between 32 and 400 and token ~ '^[0-9a-fA-F]+$'),
  environment text not null default 'sandbox' check (environment in ('sandbox','production')),
  bundle_id text not null,
  activity_id text,                           -- Live Activity id for update tokens
  enabled boolean not null default true,
  last_error text,
  updated_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);
create unique index if not exists device_push_tokens_uniq on proactive.device_push_tokens(user_id, device_id, kind, coalesce(activity_id,''));

-- updated_at / revision
create or replace function proactive.touch() returns trigger language plpgsql as $$
begin new.updated_at := now(); if tg_table_name = 'tasks' then new.revision := old.revision + 1; end if; return new; end $$;
drop trigger if exists tasks_touch on proactive.tasks;
create trigger tasks_touch before update on proactive.tasks for each row execute function proactive.touch();
drop trigger if exists tokens_touch on proactive.device_push_tokens;
create trigger tokens_touch before update on proactive.device_push_tokens for each row execute function proactive.touch();

-- RLS: anonymous Supabase users are role "authenticated" with is_anonymous=true; auth.uid() works for both.
alter table proactive.tasks enable row level security;
alter table proactive.reminder_occurrences enable row level security;
alter table proactive.events enable row level security;
alter table proactive.device_push_tokens enable row level security;

drop policy if exists tasks_owner on proactive.tasks;
create policy tasks_owner on proactive.tasks for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
drop policy if exists occ_owner_read on proactive.reminder_occurrences;
create policy occ_owner_read on proactive.reminder_occurrences for select to authenticated using (user_id = (select auth.uid()));
drop policy if exists events_owner_read on proactive.events;
create policy events_owner_read on proactive.events for select to authenticated using (user_id = (select auth.uid()));
drop policy if exists events_owner_mark_read on proactive.events;
create policy events_owner_mark_read on proactive.events for update to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
drop policy if exists tokens_owner on proactive.device_push_tokens;
create policy tokens_owner on proactive.device_push_tokens for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

grant select, insert, update, delete on proactive.tasks, proactive.device_push_tokens to authenticated;
grant select on proactive.reminder_occurrences to authenticated;
grant select on proactive.events to authenticated;
grant update (read_at) on proactive.events to authenticated;
grant all on all tables in schema proactive to service_role;

-- Scheduler claim: atomically claim due tasks (service role only; called by edge scheduler)
create or replace function proactive.claim_due_reminders(p_now timestamptz, p_limit integer default 50)
returns table(task_id uuid, user_id uuid, conversation_id uuid, title text, notes text, due_at timestamptz,
              time_zone text, recurrence jsonb, scheduled_at timestamptz, fire_count integer)
language plpgsql security definer set search_path = proactive, pg_temp as $$
begin
  return query
  with due as (
    select t.* from proactive.tasks t
    where t.status in ('open','snoozed') and t.next_fire_at is not null and t.next_fire_at <= p_now
    order by t.next_fire_at limit greatest(1, least(p_limit, 200))
    for update skip locked
  ), ins as (
    insert into proactive.reminder_occurrences(task_id, scheduled_at, user_id)
    select d.id, d.next_fire_at, d.user_id from due d
    on conflict do nothing
    returning reminder_occurrences.task_id, reminder_occurrences.scheduled_at
  )
  select d.id, d.user_id, d.conversation_id, d.title, d.notes, d.due_at, d.time_zone, d.recurrence, i.scheduled_at, d.fire_count
  from due d join ins i on i.task_id = d.id;
end $$;
revoke all on function proactive.claim_due_reminders(timestamptz, integer) from public, anon, authenticated;
grant execute on function proactive.claim_due_reminders(timestamptz, integer) to service_role;

-- Expose schema to PostgREST if you want the app to read events/tasks directly:
--   Dashboard > API > Exposed schemas: add "proactive"   (optional; edge API covers all needs)
