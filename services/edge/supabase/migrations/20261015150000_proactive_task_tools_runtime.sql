-- A2: catpaw-api runs catpaw.task-tools.v1 in-process with its dedicated login (member of catpaw_records,
-- not superuser, no BYPASSRLS). Requires 20261015120000_proactive_tasks.sql. NOT APPLIED automatically.
-- pg-store.mjs filters every query by user_id = authenticated subject; these policies are the second layer
-- and only cover the task tool paths (create/list/update tasks, task_created/task_updated events).
grant usage on schema proactive to catpaw_records;
grant select, insert, update on proactive.tasks to catpaw_records;
grant select, insert on proactive.events to catpaw_records;
drop policy if exists tasks_catpaw_api on proactive.tasks;
create policy tasks_catpaw_api on proactive.tasks for all to catpaw_records using (true) with check (created_by in ('user','agent'));
drop policy if exists events_catpaw_api on proactive.events;
create policy events_catpaw_api on proactive.events for all to catpaw_records using (true) with check (kind in ('task_created','task_updated'));
