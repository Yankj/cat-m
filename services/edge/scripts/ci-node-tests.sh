#!/usr/bin/env bash
# CI node tests for services/edge. Real pinned jose/postgres are installed into test/support/vendor
# (the loader falls back to stubs without them). Remaining quarantine: https://github.com/Yankj/catpaw-m/issues/81
# model-route-review-probe-next imports a build/ artifact (packages-r8/catpaw-api-v21) that is not in git.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ ! -d test/support/vendor/node_modules/jose ]]; then
  mkdir -p test/support/vendor && (cd test/support/vendor && echo '{"private":true}' > package.json && npm i --no-audit --no-fund --silent jose@6.2.12 postgres@3.4.7)
fi
QUARANTINE=(model-route-review-probe-next)
files=()
for f in test/*.test.mjs; do
  name=$(basename "$f" .test.mjs); skip=0
  for q in "${QUARANTINE[@]}"; do [[ "$name" == "$q" ]] && skip=1; done
  if [[ $skip == 1 ]]; then echo "QUARANTINED (issue #81): $f"; else files+=("$f"); fi
done
node --no-warnings --import ./test/support/node-strip-loader.mjs --test "${files[@]}"
