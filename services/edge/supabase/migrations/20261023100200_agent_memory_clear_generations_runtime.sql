-- NoBug B1: catpaw-api connects as a dedicated login in catpaw_records (no BYPASSRLS; verifyDedicatedPool refuses
-- superuser/bypassrls). 20261023100100 granted clear_generations to service_role only, with RLS on and no policy, so
-- POST /memory/clear (removeAll) and the journal clear-generation fence fail for every user. Mirror memories_catpaw_api.
-- Re-runnable.
grant select, insert, update on agent_memory.clear_generations to catpaw_records;
drop policy if exists clear_gen_catpaw_api on agent_memory.clear_generations;
create policy clear_gen_catpaw_api on agent_memory.clear_generations for all to catpaw_records using (true) with check (true);
