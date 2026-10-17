-- Recovered verbatim from production supabase_migrations.schema_migrations (version 20261011235413) on 2026-10-17.
-- Already applied in production; added to the repo to close version drift. See docs/migration-drift.md.
ALTER FUNCTION catpaw.sync_time_columns() SET search_path = pg_catalog;
ALTER FUNCTION catpaw.check_memory_generation() SET search_path = pg_catalog;
ALTER FUNCTION catpaw.check_event_sequence() SET search_path = pg_catalog;
ALTER FUNCTION catpaw.check_scope_change() SET search_path = pg_catalog;
ALTER FUNCTION catpaw.reject_mutation() SET search_path = pg_catalog;
ALTER FUNCTION catpaw.check_source_change() SET search_path = pg_catalog;
