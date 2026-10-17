-- Recovered verbatim from production supabase_migrations.schema_migrations (version 20261012002243) on 2026-10-17.
-- Already applied in production; added to the repo to close version drift. See docs/migration-drift.md.
BEGIN;
CREATE ROLE catpaw_runtime LOGIN INHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
GRANT catpaw_records TO catpaw_runtime WITH INHERIT TRUE;
GRANT CONNECT ON DATABASE postgres TO catpaw_runtime;
COMMIT;
