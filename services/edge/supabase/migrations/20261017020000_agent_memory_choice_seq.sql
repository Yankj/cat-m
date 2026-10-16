-- Codex PR91 v3-2: client choice sequence for the 使用记忆 switch. A PATCH carrying use_memory_seq is applied only when
-- strictly newer than the stored one, so a late (timed-out) older choice never overwrites a newer one.
alter table agent_memory.memory_settings add column if not exists use_memory_seq bigint;
