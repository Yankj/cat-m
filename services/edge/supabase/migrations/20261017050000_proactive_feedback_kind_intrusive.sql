-- catpaw.proactive.decision.v1 fix: proactive.feedback.kind accepts 'intrusive'.
-- Why: catpaw-proactive normalizes legacy 'disturbing' -> 'intrusive' (decision.mjs FEEDBACK_ALIASES) and iOS
-- ProactiveFeedback sends 'intrusive', but 20261016030000 only allowed helpful/not_helpful/disturbing, so every
-- "打扰到我" insert violated feedback_kind_check -> 500.
-- Requires 20261016030000_proactive_decisions.sql; apply after 20261017040000_agent_memory_choice_seq.sql.
-- Safe: constraint-only, no data rewrite. The new set is a strict superset of the old one, so existing rows still
-- pass (validation is a read-only scan). drop+add in ONE alter statement = atomic. Idempotent: re-run is a no-op.
-- 'disturbing' stays allowed so rows written by older clients/servers remain valid.
alter table proactive.feedback
  drop constraint if exists feedback_kind_check,
  add constraint feedback_kind_check check (kind in ('helpful','not_helpful','intrusive','disturbing'));

-- Rollback (remap 'intrusive' rows first, otherwise the re-added check fails):
--   update proactive.feedback set kind = 'disturbing' where kind = 'intrusive';
--   alter table proactive.feedback
--     drop constraint if exists feedback_kind_check,
--     add constraint feedback_kind_check check (kind in ('helpful','not_helpful','disturbing'));
