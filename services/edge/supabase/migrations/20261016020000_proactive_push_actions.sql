-- B4 push-action write-back: notification button taps (open/done/snooze/dismiss). Additive.
-- Requires 20261015120000_proactive_tasks.sql. NOT APPLIED automatically (production needs explicit user approval).
alter table proactive.events add column if not exists opened_at timestamptz;
alter table proactive.events add column if not exists action text
  check (action is null or action in ('open','done','snooze_10m','snooze_1h','dismiss'));
-- owners may already update read_at; action/opened_at are written only by catpaw-proactive (service role).
