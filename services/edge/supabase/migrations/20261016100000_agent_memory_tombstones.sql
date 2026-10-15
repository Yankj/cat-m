-- S2: incremental memory sync (GET /catpaw/agent-memory/v1/memories?since=) needs delete tombstones.
-- Requires 20261016090000_agent_memory.sql. NOT APPLIED automatically.
create table if not exists agent_memory.memory_tombstones (
  memory_id uuid not null,
  user_id uuid not null references auth.users(id) on delete cascade,
  deleted_at timestamptz not null default now(),
  primary key (user_id, memory_id)
);
create index if not exists memory_tombstones_since_idx on agent_memory.memory_tombstones(user_id, deleted_at);
create index if not exists memories_updated_idx on agent_memory.memories(user_id, updated_at);
create or replace function agent_memory.record_tombstone() returns trigger language plpgsql security definer set search_path = agent_memory, pg_temp as $$
begin insert into agent_memory.memory_tombstones(memory_id, user_id) values (old.id, old.user_id)
  on conflict (user_id, memory_id) do update set deleted_at = now(); return old; end $$;
drop trigger if exists memories_tombstone on agent_memory.memories;
create trigger memories_tombstone after delete on agent_memory.memories for each row execute function agent_memory.record_tombstone();
alter table agent_memory.memory_tombstones enable row level security;
drop policy if exists tombstones_owner_read on agent_memory.memory_tombstones;
create policy tombstones_owner_read on agent_memory.memory_tombstones for select to authenticated using (user_id = (select auth.uid()));
grant select on agent_memory.memory_tombstones to authenticated;
grant all on agent_memory.memory_tombstones to service_role;  -- inserts come from the security-definer trigger
