-- catpaw.proactive.decision.v1: evaluate / feedback / explanation. Additive.
-- Requires 20261015120000_proactive_tasks.sql (+ 20261016013000, 20261016020000). NOT APPLIED automatically.
alter table proactive.events drop constraint if exists events_kind_check;
alter table proactive.events add constraint events_kind_check
  check (kind in ('reminder_due','task_created','task_updated','agent_message','proactive_decision'));
create index if not exists events_decision_idx on proactive.events(user_id, created_at desc) where kind = 'proactive_decision';

create table if not exists proactive.signal_seen (          -- signal_hash dedupe window
  user_id uuid not null references auth.users(id) on delete cascade,
  signal_hash text not null check (char_length(signal_hash) between 16 and 64),
  seen_at timestamptz not null default now(),
  primary key (user_id, signal_hash)
);
create table if not exists proactive.trigger_weights (      -- learned from feedback; read by evaluate
  user_id uuid not null references auth.users(id) on delete cascade,
  trigger text not null check (char_length(trigger) between 1 and 64),
  weight numeric(5,3) not null default 1 check (weight between 0.3 and 1.5),
  threshold_bump numeric(5,3) not null default 0 check (threshold_bump between -0.1 and 0.3),
  updated_at timestamptz not null default now(),
  primary key (user_id, trigger)
);
create table if not exists proactive.feedback (             -- one feedback per event (idempotent)
  event_id uuid primary key references proactive.events(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  kind text not null check (kind in ('helpful','not_helpful','disturbing')),
  created_at timestamptz not null default now()
);
alter table proactive.signal_seen enable row level security;
alter table proactive.trigger_weights enable row level security;
alter table proactive.feedback enable row level security;
drop policy if exists weights_owner_read on proactive.trigger_weights;
create policy weights_owner_read on proactive.trigger_weights for select to authenticated using (user_id = (select auth.uid()));
drop policy if exists feedback_owner_read on proactive.feedback;
create policy feedback_owner_read on proactive.feedback for select to authenticated using (user_id = (select auth.uid()));
grant select on proactive.trigger_weights, proactive.feedback to authenticated;
grant all on proactive.signal_seen, proactive.trigger_weights, proactive.feedback to service_role;
