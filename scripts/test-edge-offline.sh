#!/bin/sh
# Read existing public dependencies in place; do not copy owner assets or install packages.
set -eu
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
deno_bin=${CATPAW_DENO_BIN:-deno}
: "${CATPAW_PUBLIC_NPM_CACHE:?Set CATPAW_PUBLIC_NPM_CACHE to an existing public Deno cache; no automatic install}"
command -v "$deno_bin" >/dev/null
cd "$repo_root/services/edge"
mkdir -p build/integration-deno-cache
python3 - "$CATPAW_PUBLIC_NPM_CACHE" <<'PY'
import json
from pathlib import Path
import sys
cache = Path(sys.argv[1]).resolve()
root = Path.cwd()
imports = {}
for name, version, entry in [('jose', '6.2.12', 'dist/webapi/index.js'), ('postgres', '3.4.7', 'src/index.js')]:
    package = cache / 'npm/registry.npmjs.org' / name / version
    assert json.loads((package / 'package.json').read_text())['version'] == version
    assert (package / entry).is_file()
    imports[f'npm:{name}@{version}'] = (package / entry).as_uri()
imports[(root / 'build/cache').as_uri() + '/'] = cache.as_uri() + '/'
(root / 'build/integration-import-map.json').write_text(json.dumps({'imports': imports}) + '\n')
PY
DENO_DIR="$PWD/build/integration-deno-cache" "$deno_bin" test --cached-only --no-prompt --deny-net --ignore-env \
    --allow-read --config supabase/functions/deno.json --import-map build/integration-import-map.json test
