-- catpaw.agent-memory.v1: catpaw-api's role cannot resolve extensions.vector. WRITTEN ONLY — NOT APPLIED (apply needs the user's approval).
-- Evidence (prod, read-only, 2026-10-17 16:28 UTC+8): turn 9b7a391a events turn_started, model_route, tool_call memory_save,
-- turn_failed turn_interrupted; log catpaw_chat_interrupted phase=tool_or_completion sqlstate=42501. pg-store.mjs inserts/updates
-- `$n::extensions.vector`; catpaw_records has DML on agent_memory.memories (20261016110000) but no USAGE on schema extensions
-- (has_schema_privilege('catpaw_records','extensions','USAGE') = false). memory_save/memory_update therefore always fail.
-- Minimal fix: schema USAGE only (no table/function grants in extensions; pgvector's functions are already EXECUTE to PUBLIC).
grant usage on schema extensions to catpaw_records;
