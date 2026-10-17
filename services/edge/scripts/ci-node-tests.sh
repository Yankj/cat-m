#!/usr/bin/env bash
# CI node tests for services/edge. Quarantined files need Deno / Postgres / real jose — tracked in
# https://github.com/Yankj/catpaw-m/issues/81 (pre-existing on base, not caused by PR #80).
set -euo pipefail
cd "$(dirname "$0")/.."
QUARANTINE=(anonymous-auth proactive-push-pg auth-key-service generative-ui-demo-recording model-route-review-probe-next postgres-json-binding proactive-push-action proactive-tasks-pg proactive-tasks proactive-feedback-pg)
files=()
for f in test/*.test.mjs; do
  name=$(basename "$f" .test.mjs); skip=0
  for q in "${QUARANTINE[@]}"; do [[ "$name" == "$q" ]] && skip=1; done
  if [[ $skip == 1 ]]; then echo "QUARANTINED (issue #81): $f"; else files+=("$f"); fi
done
node --no-warnings --import ./test/support/node-strip-loader.mjs --test "${files[@]}"
