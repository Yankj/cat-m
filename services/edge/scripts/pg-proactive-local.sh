#!/usr/bin/env bash
# Real-Postgres proactive tests (Codex PR90f #6). Needs a local PostgreSQL (PG17 tested) and deno.
#   PGHOST=/tmp PGPORT=55432 PGUSER=postgres bash scripts/pg-proactive-local.sh
# Creates a scratch database, applies test/fixtures/supabase-stub.sql + every proactive migration in order (pg_cron /
# pg_net / vault are not available locally: 20261015120100_proactive_cron.sql is skipped and `cron` is stubbed), then
# runs the deno PG tests. Never touches a remote database.
set -euo pipefail
cd "$(dirname "$0")/.."
DB="catpaw_proactive_pg_$$"
P=(psql -v ON_ERROR_STOP=1 -q)
"${P[@]}" -d postgres -c "create database $DB"
trap '"${P[@]}" -d postgres -c "drop database if exists $DB" >/dev/null 2>&1 || true' EXIT
"${P[@]}" -d "$DB" -f test/fixtures/supabase-stub.sql >/dev/null
"${P[@]}" -d "$DB" <<'SQL' >/dev/null
do $$ begin if not exists (select 1 from pg_roles where rolname='catpaw_records') then create role catpaw_records nologin; end if; end $$;
create schema if not exists cron;
create table if not exists cron.job(jobid bigserial primary key, jobname text);
create or replace function cron.schedule(text, text, text) returns bigint language sql as 'select 1::bigint';
create or replace function cron.unschedule(bigint) returns boolean language sql as 'select true';
SQL
for f in $(ls supabase/migrations/*proactive*.sql | sort); do
  case "$f" in *20261015120100_proactive_cron.sql) echo "skip (pg_cron/pg_net/vault): $f"; continue;; esac
  echo "apply $f"; "${P[@]}" -d "$DB" -f "$f" >/dev/null
done
URL="postgres://${PGUSER:-postgres}@${PGTCPHOST:-localhost}:${PGPORT:-5432}/$DB"
CATPAW_PG_TEST_URL="$URL" deno test -A --no-check test/proactive-push-pg.test.mjs test/proactive-tasks-pg.test.mjs
