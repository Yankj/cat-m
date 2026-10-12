#!/bin/sh
# Real, disposable PostgreSQL storage checks. No production endpoint, password or host mount.
set -eu
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
: "${CATPAW_DENO_BIN:?Supply the already verified official Deno binary}"
: "${CATPAW_PUBLIC_NPM_CACHE:?Supply the existing pinned public dependency cache}"
pg_image='postgres@sha256:3645570cccdfa447589da9f57dd740faa29b30938e861289a5574b6ca6b03826'
build="$repo_root/services/edge/build/proactive-restore-barrier"
driver="$CATPAW_PUBLIC_NPM_CACHE/npm/registry.npmjs.org/postgres/3.4.7"
mkdir -p "$build"
command -v docker >/dev/null
docker image inspect "$pg_image" >/dev/null # No automatic pull or third-party install.
test -f "$driver/src/index.js"
python3 - "$driver/package.json" <<'PY'
import json,sys
assert json.load(open(sys.argv[1]))['version']=='3.4.7'
PY
pg_test_container=''
cleanup() { if [ -n "$pg_test_container" ]; then docker rm -f "$pg_test_container" >/dev/null; fi; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
docker run --rm --detach --network none --tmpfs /var/lib/postgresql/data:rw,size=256m \
  --env POSTGRES_HOST_AUTH_METHOD=trust --env POSTGRES_DB=catpaw_goal_synthetic \
  "$pg_image" > "$build/container.cid"
pg_test_container=$(cat "$build/container.cid")
attempt=0
until docker exec "$pg_test_container" pg_isready -h 127.0.0.1 -d catpaw_goal_synthetic >/dev/null 2>&1; do
  attempt=$((attempt + 1))
  if [ "$attempt" -ge 40 ]; then docker logs "$pg_test_container"; exit 1; fi
  sleep 0.2
done
docker exec "$pg_test_container" postgres --version
docker exec "$pg_test_container" mkdir -p /tmp/catpaw-goal-test/functions /tmp/catpaw-goal-test/test-postgres /tmp/catpaw-goal-test/postgres
docker cp "$CATPAW_DENO_BIN" "$pg_test_container:/tmp/catpaw-goal-test/deno"
docker cp "$repo_root/services/edge/supabase/functions/." "$pg_test_container:/tmp/catpaw-goal-test/functions/"
docker cp "$repo_root/services/edge/test-postgres/." "$pg_test_container:/tmp/catpaw-goal-test/test-postgres/"
docker cp "$driver/." "$pg_test_container:/tmp/catpaw-goal-test/postgres/"
printf '%s\n' '{"imports":{"npm:postgres@3.4.7":"file:///tmp/catpaw-goal-test/postgres/src/index.js"}}' > "$build/pg-import-map.json"
docker cp "$build/pg-import-map.json" "$pg_test_container:/tmp/catpaw-goal-test/import-map.json"
docker exec "$pg_test_container" /tmp/catpaw-goal-test/deno test --cached-only --no-prompt --ignore-env \
  --allow-read=/tmp/catpaw-goal-test --allow-net=127.0.0.1:5432 \
  --config /tmp/catpaw-goal-test/functions/deno.json --import-map /tmp/catpaw-goal-test/import-map.json \
  /tmp/catpaw-goal-test/test-postgres/goal-storage.test.mjs
# EXIT removes this one known container and its tmpfs database, even on failure.
