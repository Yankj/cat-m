-- catpaw.agent-memory.v1 (Wave 2 §1). WRITTEN ONLY — NOT APPLIED. Applying to production needs the user's approval
-- (Supabase Free plan: no branch to try it on first). Gate CATPAW_AGENT_MEMORY_ENABLED stays off until then.
-- Deviations from plan §1.2 (see docs/agent-memory-contract.md): own schema like `proactive`, hard delete on
-- forget/undo/clear (no 30-day soft-delete window), privacy-first settings defaults (false, explicit consent),
-- embedding nullable (no embeddings provider is configured yet; recall falls back to lexical ranking).
create extension if not exists vector with schema extensions;
create schema if not exists agent_memory;
revoke all on schema agent_memory from public, anon;
grant usage on schema agent_memory to authenticated, service_role;

create table agent_memory.memories (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  kind text not null check (kind in ('profile','preference','person','fact','journal')),
  content text not null check (char_length(content) between 1 and 500),
  embedding extensions.vector(1536),
  pinned boolean not null default false,
  expires_at timestamptz,
  source_conversation_id uuid,
  source_turn_id uuid,
  operation_id text,
  created_by text not null default 'agent' check (created_by in ('agent','user','journal')),
  undo_token_hash text,
  undo_expires_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, operation_id)
);
create index memories_user_updated on agent_memory.memories (user_id, updated_at desc);
create index memories_embedding on agent_memory.memories using hnsw (embedding extensions.vector_cosine_ops);

create table agent_memory.memory_settings (
  user_id uuid primary key references auth.users(id) on delete cascade,
  use_memory boolean not null default false,
  auto_save boolean not null default false,
  consented_at timestamptz,
  updated_at timestamptz not null default now(),
  check ((not use_memory and not auto_save) or consented_at is not null)
);

-- Non-ephemeral user messages of the day, consumed by the journal cron; deleted when compressed or on "clear all".
create table agent_memory.journal_fragments (
  user_id uuid not null references auth.users(id) on delete cascade,
  day date not null,
  turn_id uuid not null,
  conversation_id uuid,
  text text not null check (char_length(text) <= 400),
  at timestamptz not null default now(),
  primary key (user_id, turn_id)
);
create index journal_fragments_day on agent_memory.journal_fragments (day);

alter table agent_memory.memories enable row level security;
alter table agent_memory.memory_settings enable row level security;
alter table agent_memory.journal_fragments enable row level security;
create policy memories_own on agent_memory.memories for all to authenticated using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy settings_own on agent_memory.memory_settings for all to authenticated using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy fragments_own on agent_memory.journal_fragments for select to authenticated using (user_id = (select auth.uid()));
grant select, insert, update, delete on agent_memory.memories, agent_memory.memory_settings to authenticated;
grant select on agent_memory.journal_fragments to authenticated;

-- Journal cron (needs pg_cron + pg_net and the vault secrets below; also user-approved, not applied):
-- select cron.schedule('catpaw-agent-memory-journal', '10 16 * * *',  -- 00:10 Asia/Shanghai
--   $$select net.http_post(url := (select decrypted_secret from vault.decrypted_secrets where name='catpaw_api_url') || '/catpaw/agent-memory/v1/journal/tick',
--     headers := jsonb_build_object('content-type','application/json','x-catpaw-scheduler-secret',(select decrypted_secret from vault.decrypted_secrets where name='catpaw_scheduler_secret')),
--     body := '{}'::jsonb)$$);
