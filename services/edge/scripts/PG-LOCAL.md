# Proactive PG tests — reproducible local run

```bash
# 1) a throwaway Postgres 17 on a unix socket (any PG ≥15 works)
initdb -D /tmp/pg17 -U postgres --auth=trust
pg_ctl -D /tmp/pg17 -o "-k /tmp -p 55432 -c listen_addresses=''" -l /tmp/pg17.log start
pg_isready -h /tmp -p 55432
# 2) from services/edge (needs deno on PATH): applies migrations in order with old-data seeds, then runs *-pg tests
PGHOST=/tmp PGPORT=55432 PGUSER=postgres bash scripts/pg-proactive-local.sh
```
Expected: `17 passed | 0 failed`. A skipped test counts as a failure.
