-- Recovered verbatim from production supabase_migrations.schema_migrations (version 20261012003243) on 2026-10-17.
-- Already applied in production; added to the repo to close version drift. See docs/migration-drift.md.
BEGIN;
CREATE ROLE catpaw_auth NOLOGIN NOSUPERUSER NOBYPASSRLS;
GRANT USAGE ON SCHEMA public,catpaw TO catpaw_auth;
GRANT SELECT ON public.records,catpaw.scopes TO catpaw_auth;
CREATE POLICY catpaw_auth_application_mapping ON public.records FOR SELECT TO catpaw_auth USING (kind IN ('scope-memberships','app-sessions') AND owner LIKE 'system:supabase:%');
GRANT catpaw_auth TO catpaw_runtime WITH INHERIT TRUE;
COMMIT;
