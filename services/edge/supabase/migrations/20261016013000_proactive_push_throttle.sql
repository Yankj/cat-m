-- B2 interruption guard: quiet-hours deferral + daily push cap. Additive. Requires 20261015120000_proactive_tasks.sql.
-- NOT APPLIED automatically (production needs explicit user approval).
alter table proactive.events add column if not exists push_after timestamptz;   -- deferred until quiet hours end
alter table proactive.events add column if not exists pushed_at timestamptz;    -- set when push_state becomes 'sent' (daily cap counter)
drop index if exists proactive.events_push_idx;
create index if not exists events_push_idx on proactive.events(coalesce(push_after, created_at)) where push_state = 'pending';
create index if not exists events_pushed_idx on proactive.events(user_id, pushed_at) where push_state = 'sent';
