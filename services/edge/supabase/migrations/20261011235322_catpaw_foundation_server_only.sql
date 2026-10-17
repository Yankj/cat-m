-- Recovered verbatim from production supabase_migrations.schema_migrations (version 20261011235322) on 2026-10-17.
-- Already applied in production; added to the repo to close version drift. See docs/migration-drift.md.
BEGIN;
-- PostgreSQL 17+; additive migration. Existing OpenMuse records contract is preserved.
-- Run only against a newly isolated Catpaw database; no extension, external service or credentials.
CREATE TABLE IF NOT EXISTS public.records (
  owner text NOT NULL, kind text NOT NULL, id text NOT NULL, data jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY(owner,kind,id)
);
CREATE INDEX IF NOT EXISTS records_kind_updated ON public.records(kind,updated_at,id);
CREATE SCHEMA catpaw;

CREATE TABLE catpaw.scopes (
  scope_id uuid PRIMARY KEY,
  data jsonb NOT NULL,
  profile_id uuid GENERATED ALWAYS AS ((data->'identity'->>'profile_id')::uuid) STORED NOT NULL,
  workspace_id uuid GENERATED ALWAYS AS ((data->'identity'->>'workspace_id')::uuid) STORED NOT NULL,
  owner text GENERATED ALWAYS AS (data->'identity'->>'owner') STORED NOT NULL,
  generation bigint GENERATED ALWAYS AS ((data->>'generation')::bigint) STORED NOT NULL CHECK(generation > 0),
  last_sequence bigint GENERATED ALWAYS AS ((data->>'last_sequence')::bigint) STORED NOT NULL CHECK(last_sequence >= 0),
  CHECK(scope_id = (data->'identity'->>'scope_id')::uuid),
  CHECK(jsonb_typeof(data->'enabled') = 'boolean'),
  UNIQUE(profile_id,workspace_id), UNIQUE(owner)
);
CREATE FUNCTION catpaw.check_scope_change() RETURNS trigger LANGUAGE plpgsql AS $body$
BEGIN
  IF NEW.data->'identity' IS DISTINCT FROM OLD.data->'identity' OR
    (NEW.data->>'generation')::bigint < (OLD.data->>'generation')::bigint OR
    (NEW.data->>'last_sequence')::bigint < (OLD.data->>'last_sequence')::bigint THEN
    RAISE EXCEPTION 'scope_identity_or_fence_regressed' USING ERRCODE='23514';
  END IF;
  RETURN NEW;
END $body$;
CREATE TRIGGER scope_no_regression BEFORE UPDATE ON catpaw.scopes FOR EACH ROW EXECUTE FUNCTION catpaw.check_scope_change();

-- JSONB payloads keep the JS contract adaptable; relational keys, FK, invariants and indexes are explicit.
DO $migration$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['conversation_refs','source_records','goals','execution_bindings','artifact_versions',
    'approval_bindings','memory_jobs','memory_candidates','memory_claims','episode_summaries','memory_guards','memory_commands','events']
  LOOP
    EXECUTE format('CREATE TABLE catpaw.%I (
      scope_id uuid NOT NULL REFERENCES catpaw.scopes(scope_id), id uuid NOT NULL, data jsonb NOT NULL,
      PRIMARY KEY(scope_id,id),
      CHECK(jsonb_typeof(data) = ''object''),
      CHECK(data ? ''id'' AND data ? ''scope_id''),
      CHECK(id = (data->>''id'')::uuid AND scope_id = (data->>''scope_id'')::uuid)
    )',t);
  END LOOP;
END $migration$;

ALTER TABLE catpaw.source_records
  ADD COLUMN occurred_at timestamptz NOT NULL DEFAULT now(),
  ADD COLUMN ingested_at timestamptz NOT NULL DEFAULT now(),
  ADD COLUMN conversation_id uuid GENERATED ALWAYS AS ((data->>'conversation_id')::uuid) STORED NOT NULL,
  ADD COLUMN source_sequence bigint GENERATED ALWAYS AS ((data->>'source_sequence')::bigint) STORED NOT NULL CHECK(source_sequence > 0),
  ADD CONSTRAINT source_conversation_fk FOREIGN KEY(scope_id,conversation_id) REFERENCES catpaw.conversation_refs(scope_id,id),
  ADD CONSTRAINT source_sequence_unique UNIQUE(scope_id,conversation_id,source_sequence),
  ADD CONSTRAINT source_type_check CHECK(data->>'type' IN ('user_message','assistant_message','tool_event')),
  ADD CONSTRAINT source_class_check CHECK(data->>'data_class' IN ('synthetic','private'));

ALTER TABLE catpaw.execution_bindings
  ADD COLUMN conversation_id uuid GENERATED ALWAYS AS ((data->>'conversation_id')::uuid) STORED NOT NULL,
  ADD COLUMN goal_id uuid GENERATED ALWAYS AS ((data->>'goal_id')::uuid) STORED,
  ADD COLUMN run_id uuid GENERATED ALWAYS AS ((data->>'run_id')::uuid) STORED NOT NULL,
  ADD COLUMN operation_id uuid GENERATED ALWAYS AS ((data->>'operation_id')::uuid) STORED NOT NULL,
  ADD COLUMN turn_id uuid GENERATED ALWAYS AS ((data->>'turn_id')::uuid) STORED NOT NULL,
  ADD COLUMN call_id text GENERATED ALWAYS AS (data->>'call_id') STORED NOT NULL,
  ADD CONSTRAINT binding_conversation_fk FOREIGN KEY(scope_id,conversation_id) REFERENCES catpaw.conversation_refs(scope_id,id),
  ADD CONSTRAINT binding_goal_fk FOREIGN KEY(scope_id,goal_id) REFERENCES catpaw.goals(scope_id,id),
  ADD CONSTRAINT binding_run_unique UNIQUE(scope_id,run_id),
  ADD CONSTRAINT binding_operation_unique UNIQUE(scope_id,operation_id),
  ADD CONSTRAINT binding_call_unique UNIQUE(scope_id,turn_id,call_id);

ALTER TABLE catpaw.artifact_versions
  ADD COLUMN artifact_id uuid GENERATED ALWAYS AS ((data->>'artifact_id')::uuid) STORED NOT NULL,
  ADD COLUMN version bigint GENERATED ALWAYS AS ((data->>'version')::bigint) STORED NOT NULL CHECK(version > 0),
  ADD COLUMN run_id uuid GENERATED ALWAYS AS ((data->>'run_id')::uuid) STORED NOT NULL,
  ADD CONSTRAINT artifact_run_fk FOREIGN KEY(scope_id,run_id) REFERENCES catpaw.execution_bindings(scope_id,run_id),
  ADD CONSTRAINT artifact_version_unique UNIQUE(scope_id,artifact_id,version);
ALTER TABLE catpaw.approval_bindings
  ADD COLUMN run_id uuid GENERATED ALWAYS AS ((data->>'run_id')::uuid) STORED NOT NULL,
  ADD COLUMN artifact_id uuid GENERATED ALWAYS AS ((data->>'artifact_id')::uuid) STORED NOT NULL,
  ADD COLUMN artifact_version bigint GENERATED ALWAYS AS ((data->>'artifact_version')::bigint) STORED NOT NULL,
  ADD CONSTRAINT approval_run_fk FOREIGN KEY(scope_id,run_id) REFERENCES catpaw.execution_bindings(scope_id,run_id),
  ADD CONSTRAINT approval_artifact_fk FOREIGN KEY(scope_id,artifact_id,artifact_version) REFERENCES catpaw.artifact_versions(scope_id,artifact_id,version);

DO $migration$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['memory_jobs','memory_candidates','memory_claims'] LOOP
    EXECUTE format('ALTER TABLE catpaw.%I ADD COLUMN source_id uuid GENERATED ALWAYS AS ((data->>''source_id'')::uuid) STORED NOT NULL,
      ADD CONSTRAINT %I FOREIGN KEY(scope_id,source_id) REFERENCES catpaw.source_records(scope_id,id)',t,t || '_source_fk');
  END LOOP;
END $migration$;
ALTER TABLE catpaw.memory_jobs
  ADD COLUMN next_attempt_at timestamptz NOT NULL DEFAULT now(),
  ADD COLUMN lease_until timestamptz,
  ADD COLUMN idempotency_key text GENERATED ALWAYS AS (data->>'idempotency_key') STORED NOT NULL,
  ADD CONSTRAINT job_idempotency_unique UNIQUE(scope_id,idempotency_key),
  ADD CONSTRAINT job_status_check CHECK(data->>'status' IN ('ready','leased','done','cancelled','failed'));
CREATE INDEX job_ready ON catpaw.memory_jobs(scope_id,(data->>'status'),next_attempt_at,id);
CREATE INDEX job_source ON catpaw.memory_jobs(scope_id,source_id);
CREATE INDEX candidate_source ON catpaw.memory_candidates(scope_id,source_id);
CREATE INDEX candidate_key ON catpaw.memory_candidates(scope_id,(data->>'subject_key_hmac'));

ALTER TABLE catpaw.memory_claims
  ADD COLUMN observed_at timestamptz NOT NULL DEFAULT now(),
  ADD COLUMN recorded_at timestamptz NOT NULL DEFAULT now(),
  ADD COLUMN valid_from timestamptz,
  ADD COLUMN valid_until timestamptz,
  ADD COLUMN expires_at timestamptz,
  ADD COLUMN review_after timestamptz,
  ADD COLUMN search_vector tsvector GENERATED ALWAYS AS (to_tsvector('simple'::regconfig,coalesce(data->>'search_text',''))) STORED,
  ADD CONSTRAINT claim_status_check CHECK(data->>'status' IN ('active','disputed')),
  ADD CONSTRAINT claim_version_check CHECK((data->>'version')::bigint > 0),
  ADD CONSTRAINT claim_confidence_check CHECK((data->>'confidence')::numeric BETWEEN 0 AND 1);
CREATE INDEX claims_search_gin ON catpaw.memory_claims USING gin(search_vector);
CREATE INDEX claims_scope_key ON catpaw.memory_claims(scope_id,(data->>'subject_key_hmac'),(data->>'status'));
CREATE INDEX claims_source ON catpaw.memory_claims(scope_id,source_id);
CREATE INDEX claims_validity ON catpaw.memory_claims(scope_id,valid_until,expires_at);
ALTER TABLE catpaw.memory_candidates ADD COLUMN candidate_expires_at timestamptz NOT NULL DEFAULT now();
ALTER TABLE catpaw.episode_summaries
  ADD COLUMN expires_at timestamptz NOT NULL DEFAULT now(),
  ADD COLUMN conversation_id uuid GENERATED ALWAYS AS ((data->>'conversation_id')::uuid) STORED NOT NULL,
  ADD CONSTRAINT summary_conversation_fk FOREIGN KEY(scope_id,conversation_id) REFERENCES catpaw.conversation_refs(scope_id,id);
CREATE INDEX summaries_conversation ON catpaw.episode_summaries(scope_id,conversation_id);
CREATE INDEX guards_key ON catpaw.memory_guards(scope_id,(data->>'subject_key_hmac'));
ALTER TABLE catpaw.events
  ADD COLUMN sequence bigint GENERATED ALWAYS AS ((data->>'sequence')::bigint) STORED NOT NULL CHECK(sequence > 0),
  ADD CONSTRAINT event_sequence_unique UNIQUE(scope_id,sequence);

CREATE FUNCTION catpaw.reject_mutation() RETURNS trigger LANGUAGE plpgsql AS $body$
BEGIN RAISE EXCEPTION 'immutable_record' USING ERRCODE='23514'; END $body$;
DO $migration$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['artifact_versions','execution_bindings','approval_bindings','memory_commands','memory_guards','events'] LOOP
    EXECUTE format('CREATE TRIGGER immutable_record BEFORE UPDATE OR DELETE ON catpaw.%I FOR EACH ROW EXECUTE FUNCTION catpaw.reject_mutation()',t);
  END LOOP;
END $migration$;

CREATE FUNCTION catpaw.check_source_change() RETURNS trigger LANGUAGE plpgsql AS $body$
BEGIN
  IF OLD.data->>'deleted_at' IS NOT NULL AND NEW.data IS DISTINCT FROM OLD.data THEN
    RAISE EXCEPTION 'deleted_source_cannot_reappear' USING ERRCODE='23514';
  END IF;
  IF (OLD.data->>'suppressed_for_memory')::boolean AND NOT (NEW.data->>'suppressed_for_memory')::boolean THEN
    RAISE EXCEPTION 'source_barrier_cannot_reset' USING ERRCODE='23514';
  END IF;
  IF NEW.data->>'text' IS DISTINCT FROM OLD.data->>'text' AND NOT (NEW.data->>'text' = '' AND NEW.data->>'deleted_at' IS NOT NULL) THEN
    RAISE EXCEPTION 'source_content_immutable' USING ERRCODE='23514';
  END IF;
  RETURN NEW;
END $body$;
CREATE TRIGGER source_no_resurrection BEFORE UPDATE ON catpaw.source_records FOR EACH ROW EXECUTE FUNCTION catpaw.check_source_change();

CREATE FUNCTION catpaw.sync_time_columns() RETURNS trigger LANGUAGE plpgsql AS $body$
BEGIN
  IF TG_TABLE_NAME='source_records' THEN
    NEW.occurred_at := (NEW.data->>'occurred_at')::timestamptz; NEW.ingested_at := (NEW.data->>'ingested_at')::timestamptz;
  ELSIF TG_TABLE_NAME='memory_jobs' THEN
    NEW.next_attempt_at := (NEW.data->>'next_attempt_at')::timestamptz; NEW.lease_until := (NEW.data->>'lease_until')::timestamptz;
  ELSIF TG_TABLE_NAME='memory_claims' THEN
    NEW.observed_at := (NEW.data->>'observed_at')::timestamptz; NEW.recorded_at := (NEW.data->>'recorded_at')::timestamptz;
    NEW.valid_from := (NEW.data->>'valid_from')::timestamptz; NEW.valid_until := (NEW.data->>'valid_until')::timestamptz;
    NEW.expires_at := (NEW.data->>'expires_at')::timestamptz; NEW.review_after := (NEW.data->>'review_after')::timestamptz;
  ELSIF TG_TABLE_NAME='memory_candidates' THEN NEW.candidate_expires_at := (NEW.data->>'candidate_expires_at')::timestamptz;
  ELSIF TG_TABLE_NAME='episode_summaries' THEN NEW.expires_at := (NEW.data->>'expires_at')::timestamptz;
  END IF;
  RETURN NEW;
END $body$;
DO $migration$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['source_records','memory_jobs','memory_claims','memory_candidates','episode_summaries'] LOOP
    EXECUTE format('CREATE TRIGGER sync_utc_time BEFORE INSERT OR UPDATE ON catpaw.%I FOR EACH ROW EXECUTE FUNCTION catpaw.sync_time_columns()',t);
  END LOOP;
END $migration$;

CREATE FUNCTION catpaw.check_memory_generation() RETURNS trigger LANGUAGE plpgsql AS $body$
DECLARE current_generation bigint; source_data jsonb; ref jsonb;
BEGIN
  SELECT generation INTO current_generation FROM catpaw.scopes WHERE scope_id=NEW.scope_id FOR UPDATE;
  IF TG_TABLE_NAME='memory_jobs' AND NEW.data->>'status' IN ('cancelled','failed') THEN RETURN NEW; END IF;
  IF TG_TABLE_NAME='memory_claims' AND TG_OP='UPDATE' AND
    NEW.data->'value' IS NOT DISTINCT FROM OLD.data->'value' AND NEW.data->>'source_id' IS NOT DISTINCT FROM OLD.data->>'source_id' THEN RETURN NEW; END IF;
  IF (NEW.data->>'memory_generation')::bigint IS DISTINCT FROM current_generation THEN
    RAISE EXCEPTION 'memory_generation_fenced' USING ERRCODE='23514';
  END IF;
  IF TG_TABLE_NAME='episode_summaries' THEN
    IF jsonb_array_length(NEW.data->'source_ids')=0 THEN RAISE EXCEPTION 'summary_sources_missing' USING ERRCODE='23514'; END IF;
    FOR ref IN SELECT value FROM jsonb_array_elements(NEW.data->'source_ids') LOOP
      SELECT data INTO source_data FROM catpaw.source_records WHERE scope_id=NEW.scope_id AND id=(ref #>> '{}')::uuid;
      IF source_data IS NULL OR source_data->>'deleted_at' IS NOT NULL OR (source_data->>'suppressed_for_memory')::boolean OR
        source_data->>'conversation_id' IS DISTINCT FROM NEW.data->>'conversation_id' THEN
        RAISE EXCEPTION 'summary_source_fenced' USING ERRCODE='23514';
      END IF;
    END LOOP;
  ELSE
    SELECT data INTO source_data FROM catpaw.source_records WHERE scope_id=NEW.scope_id AND id=(NEW.data->>'source_id')::uuid;
    IF source_data IS NULL OR source_data->>'type' IS DISTINCT FROM 'user_message' OR source_data->>'trust' IS DISTINCT FROM 'user_direct' OR
      source_data->>'deleted_at' IS NOT NULL OR (source_data->>'suppressed_for_memory')::boolean OR
      (source_data->>'memory_generation')::bigint IS DISTINCT FROM current_generation THEN
      RAISE EXCEPTION 'source_fenced' USING ERRCODE='23514';
    END IF;
  END IF;
  RETURN NEW;
END $body$;
DO $migration$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['memory_jobs','memory_candidates','memory_claims','episode_summaries'] LOOP
    EXECUTE format('CREATE TRIGGER generation_fence BEFORE INSERT OR UPDATE ON catpaw.%I FOR EACH ROW EXECUTE FUNCTION catpaw.check_memory_generation()',t);
  END LOOP;
END $migration$;

CREATE FUNCTION catpaw.check_event_sequence() RETURNS trigger LANGUAGE plpgsql AS $body$
DECLARE scope_sequence bigint; previous_sequence bigint;
BEGIN
  SELECT last_sequence INTO scope_sequence FROM catpaw.scopes WHERE scope_id=NEW.scope_id FOR UPDATE;
  SELECT coalesce(max(sequence),0) INTO previous_sequence FROM catpaw.events WHERE scope_id=NEW.scope_id;
  IF (NEW.data->>'sequence')::bigint <> scope_sequence OR scope_sequence <> previous_sequence+1 THEN
    RAISE EXCEPTION 'event_cursor_not_commit_ordered' USING ERRCODE='23514';
  END IF;
  RETURN NEW;
END $body$;
CREATE TRIGGER event_commit_cursor BEFORE INSERT ON catpaw.events FOR EACH ROW EXECUTE FUNCTION catpaw.check_event_sequence();

-- Client cannot set this GUC directly: DB pool is a trusted server capability, not an exposed SQL endpoint.
-- This isolation layer supplements server principal checks. records Store remains internal to the existing worker.
DO $migration$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['scopes','conversation_refs','source_records','goals','execution_bindings','artifact_versions',
    'approval_bindings','memory_jobs','memory_candidates','memory_claims','episode_summaries','memory_guards','memory_commands','events'] LOOP
    EXECUTE format('ALTER TABLE catpaw.%I ENABLE ROW LEVEL SECURITY',t);
    EXECUTE format('ALTER TABLE catpaw.%I FORCE ROW LEVEL SECURITY',t);
    EXECUTE format('CREATE POLICY scope_isolation ON catpaw.%I USING (scope_id=nullif(current_setting(''catpaw.scope_id'',true),'''')::uuid)
      WITH CHECK (scope_id=nullif(current_setting(''catpaw.scope_id'',true),'''')::uuid)',t);
  END LOOP;
END $migration$;
REVOKE ALL ON SCHEMA catpaw FROM PUBLIC;
REVOKE ALL ON ALL TABLES IN SCHEMA catpaw FROM PUBLIC;

-- Supabase-compatible server-only ACL. NOLOGIN capability roles are not credentials or frontend identities.
-- Applies only after 001 in an independently authorized Catpaw DB. Never run against unrelated old projects.
DO $migration$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='catpaw_records') THEN CREATE ROLE catpaw_records NOLOGIN NOSUPERUSER NOBYPASSRLS; END IF;
  IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='catpaw_memory') THEN CREATE ROLE catpaw_memory NOLOGIN NOSUPERUSER NOBYPASSRLS; END IF;
END $migration$;

-- public.records must not become an exposed Data API table merely because public is an exposed schema.
ALTER TABLE public.records ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.records FORCE ROW LEVEL SECURITY;
CREATE POLICY catpaw_records_server ON public.records TO catpaw_records USING (true) WITH CHECK (true);
REVOKE ALL ON public.records FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO catpaw_records;
GRANT SELECT,INSERT,UPDATE,DELETE ON public.records TO catpaw_records;

GRANT USAGE ON SCHEMA catpaw TO catpaw_records,catpaw_memory;
GRANT SELECT,INSERT,UPDATE,DELETE ON ALL TABLES IN SCHEMA catpaw TO catpaw_records,catpaw_memory;
REVOKE INSERT,DELETE ON catpaw.scopes FROM catpaw_memory;
-- A memory-only service may read source conversations/tasks but cannot rewrite worker authority.
GRANT SELECT ON public.records TO catpaw_memory;
CREATE POLICY catpaw_memory_snapshot ON public.records FOR SELECT TO catpaw_memory
  USING (owner=(SELECT owner FROM catpaw.scopes WHERE scope_id=nullif(current_setting('catpaw.scope_id',true),'')::uuid));
REVOKE UPDATE,DELETE ON catpaw.execution_bindings,catpaw.artifact_versions,catpaw.approval_bindings,catpaw.memory_commands,catpaw.memory_guards,catpaw.events FROM catpaw_records,catpaw_memory;

DO $migration$
DECLARE r text;
BEGIN
  FOREACH r IN ARRAY ARRAY['anon','authenticated','service_role'] LOOP
    IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname=r) THEN
      EXECUTE format('REVOKE ALL ON SCHEMA catpaw FROM %I',r);
      EXECUTE format('REVOKE ALL ON ALL TABLES IN SCHEMA catpaw FROM %I',r);
      EXECUTE format('REVOKE ALL ON ALL FUNCTIONS IN SCHEMA catpaw FROM %I',r);
      EXECUTE format('REVOKE ALL ON public.records FROM %I',r);
      EXECUTE format('REVOKE catpaw_records,catpaw_memory FROM %I',r);
    END IF;
  END LOOP;
END $migration$;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA catpaw FROM PUBLIC;
-- Trusted SQL login membership/password is a separate operator step. This migration creates no LOGIN role/key.
-- app_metadata/JWT subject -> allowed scopes is provided by chat owner; user_metadata is never an ACL source.

COMMIT;
