# Migration version drift (repo ↔ production)

Status as of 2026-10-17, from production `list_migrations` (project dbyklgxdvjbutxzsjeth, read-only).

## Why the versions differ
Production migrations were applied with the Supabase MCP `apply_migration`, which records the **apply-time timestamp** as the version, not the filename version in the repo. Every repo migration from 2026-10-15 onward was applied this way, so no repo version equals its production version. The schema matches (spot-checked: 050000 ↔ 053708, the statements md5 is identical). Only the version labels differ. `supabase db push` / `migration list` would report each one as both "local only" and "remote only".

The first four production migrations (2026-10-11/12, Catpaw foundation) had no repo file at all. This branch adds them **verbatim from `supabase_migrations.schema_migrations.statements`**, using the production version as the filename. Their versions already match, so the CLI treats them as applied. A secret scan found no credentials in them; the `catpaw_runtime` role is created without a password.

## Mapping
| repo file | prod version | prod name | note |
|---|---|---|---|
| 20261011235322_catpaw_foundation_server_only | 20261011235322 | catpaw_foundation_server_only | added here, versions match |
| 20261011235413_catpaw_trigger_search_path | 20261011235413 | catpaw_trigger_search_path | added here, versions match |
| 20261012002243_catpaw_runtime_role | 20261012002243 | catpaw_runtime_role | added here, versions match |
| 20261012003243_catpaw_application_auth_reader | 20261012003243 | catpaw_application_auth_reader | added here, versions match |
| 20261015120000_proactive_tasks | 20261015174355 | proactive_tasks | drift |
| 20261015120100_proactive_cron | 20261017053601 | proactive_cron | drift |
| 20261015140000_chat_attachments_bucket | 20261015133955 | chat_attachments_bucket | drift (prod version is *earlier*) |
| 20261015150000_proactive_task_tools_runtime | 20261015174401 | proactive_task_tools_runtime | drift |
| 20261016013000_proactive_push_throttle | 20261015174405 | proactive_push_throttle | drift |
| 20261016020000_proactive_push_actions | 20261015174408 | proactive_push_actions | drift |
| 20261016030000_proactive_decisions | 20261015174412 | proactive_decisions | drift |
| 20261016040000_proactive_suggestions_runtime | 20261017053615 | proactive_suggestions_runtime | drift |
| 20261016090000_agent_memory | 20261015174415 | agent_memory | drift |
| 20261016100000_agent_memory_tombstones | 20261017053622 | agent_memory_tombstones | drift |
| 20261016110000_feature_enrollment | 20261017053627 | feature_enrollment | drift |
| 20261017010000_proactive_delivery_owner | 20261017053639 | proactive_delivery_owner | drift |
| 20261017020000_proactive_push_sending | 20261017053645 | proactive_push_sending | drift |
| 20261017030000_proactive_push_generation | 20261017053656 | proactive_push_generation | drift |
| 20261017040000_agent_memory_choice_seq | 20261017053702 | agent_memory_choice_seq | drift |
| 20261017050000_proactive_feedback_kind_intrusive | 20261017053708 | proactive_feedback_kind_intrusive | drift; content verified identical |
| 20261017060000 (grant; Mac commit cf5287a8, **not in repo yet**) | 20261017090112 | agent_memory_extensions_usage | drift; file lands with that commit |

Other than 20261017060000, every repo file has a production counterpart and every production version has a repo file.

## Options
1. **Rename repo files to the production versions** (`git mv 20261015120000_proactive_tasks.sql 20261015174355_proactive_tasks.sql`, …). This is repo-only and needs no production write. Afterwards `supabase migration list` is clean. Costs:
   - Rename order ≠ authoring order in a few places (e.g. chat_attachments_bucket 133955 sorts before proactive_tasks, and agent_memory 174415 before proactive_suggestions_runtime 053615). That matches the real production apply order, so this is acceptable.
   - Hard-coded filenames have to be updated: `test/feature-enrollment.test.mjs`, `test/agent-memory-settings-seq.test.mjs`, the `test/fixtures/pg-upgrade-seed-before-0X0000.sql` names, and `scripts/pg-proactive-local.sh` (it globs `*proactive*`, so the order changes).
2. **`supabase migration repair`**: mark each repo version as applied and each production-only version as reverted in `supabase_migrations.schema_migrations`. This **writes to production** and needs the user's explicit approval. It keeps the repo filenames but leaves production history out of step with what was actually run.
3. Do nothing and never use `supabase db push` against this project. Keep applying through MCP and record each mapping in deploy-log.md.

## Recommendation
Option 1 as a separate small PR, after cf5287a8 (the 060000 grant) lands, so it can be renamed to 20261017090112 in the same pass. Update the hard-coded test and fixture names and run the PG harness (`scripts/pg-proactive-local.sh`) before merging. Going forward, after each `apply_migration`, either rename the repo file to the recorded version the same day or apply with the CLI so the versions stay equal. Avoid option 2 unless the user specifically wants production history rewritten.
