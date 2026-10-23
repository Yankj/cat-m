-- M1 MEM-03/04: deletion fences for agent memory.
-- (a) tombstones remember the deleted row's operation_id, so replaying the original save cannot recreate it;
-- (b) a per-user clear generation lets an in-flight journal write detect that "clear all" ran meanwhile.
alter table agent_memory.memory_tombstones add column if not exists operation_id text;
create index if not exists memory_tombstones_op_idx on agent_memory.memory_tombstones(user_id, operation_id) where operation_id is not null;
create or replace function agent_memory.record_tombstone() returns trigger language plpgsql security definer set search_path = agent_memory, pg_temp as $$
begin insert into agent_memory.memory_tombstones(memory_id, user_id, operation_id) values (old.id, old.user_id, old.operation_id)
  on conflict (user_id, memory_id) do update set deleted_at = now(), operation_id = excluded.operation_id; return old; end $$;
create table if not exists agent_memory.clear_generations (
  user_id uuid primary key references auth.users(id) on delete cascade,
  generation bigint not null default 0
);
alter table agent_memory.clear_generations enable row level security;
grant all on agent_memory.clear_generations to service_role;
