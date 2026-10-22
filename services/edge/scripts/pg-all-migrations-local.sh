#!/usr/bin/env bash
# Applies EVERY migration in order (one transaction each, like `supabase db push`) to a scratch DB on a local PG17
# (+ postgresql-17-pgvector), then runs the given deno PG tests with CATPAW_PG_TEST_URL. Never touches a remote DB.
#   PGHOST=/tmp PGPORT=55432 PGUSER=postgres bash scripts/pg-all-migrations-local.sh test/family-*-pg.test.mjs
# pg_cron/pg_net/vault are unavailable locally: 20261015120100_proactive_cron.sql is skipped and cron is stubbed.
set -euo pipefail
cd "$(dirname "$0")/.."
DB="catpaw_all_pg_$$"
P=(psql -v ON_ERROR_STOP=1 -q)
"${P[@]}" -d postgres -c "create database $DB"
[ -n "${KEEP_DB:-}" ] || trap '"${P[@]}" -d postgres -c "drop database if exists $DB" >/dev/null 2>&1 || true' EXIT
"${P[@]}" -d "$DB" -f test/fixtures/supabase-stub.sql >/dev/null
"${P[@]}" -d "$DB" -f test/fixtures/supabase-local-extra.sql >/dev/null
echo "pg-evidence: head=$(git rev-parse HEAD) dirty=$(git status --porcelain | wc -l) server=$("${P[@]}" -At -d "$DB" -c 'show server_version') at=$(date -u +%FT%TZ)"
n=0
for f in $(ls supabase/migrations/*.sql | sort); do
  case "$f" in *20261015120100_proactive_cron.sql) echo "skip (pg_cron/pg_net/vault): $f"; continue;; esac
  "${P[@]}" -1 -d "$DB" -f "$f" >/dev/null; n=$((n+1))
done
echo "applied $n migrations"
[ $# -gt 0 ] || exit 0
CATPAW_PG_TEST_URL="postgres://${PGUSER:-postgres}@localhost:${PGPORT:-5432}/$DB" deno test -A --no-check "$@"
