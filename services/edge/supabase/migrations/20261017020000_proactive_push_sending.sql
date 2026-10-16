-- Codex PR90e #6: 'sending' = the sender holds the send licence (claimed atomically from 'pending' while the suggestion
-- is still pending). A dismiss/snooze only cancels 'pending'; terminal states are never overwritten (store guards).
alter table proactive.events drop constraint if exists events_push_state_check;
alter table proactive.events add constraint events_push_state_check
  check (push_state in ('pending','sending','sent','skipped','failed','no_device'));
