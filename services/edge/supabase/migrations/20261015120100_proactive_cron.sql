-- Invoke the scheduler edge function every minute via pg_cron + pg_net.
-- Requires Vault secrets: catpaw_project_url, catpaw_scheduler_secret (see docs/backend/proactive-tasks.md).
create extension if not exists pg_cron;
create extension if not exists pg_net;
select cron.unschedule(jobid) from cron.job where jobname = 'catpaw-proactive-tick';
select cron.schedule('catpaw-proactive-tick', '* * * * *', $cron$
  select net.http_post(
    url := (select decrypted_secret from vault.decrypted_secrets where name = 'catpaw_project_url') || '/functions/v1/catpaw-proactive/scheduler/tick',
    headers := jsonb_build_object('content-type','application/json',
      'x-catpaw-scheduler-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'catpaw_scheduler_secret')),
    body := '{}'::jsonb, timeout_milliseconds := 25000);
$cron$);
