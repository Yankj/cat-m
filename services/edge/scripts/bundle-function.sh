#!/usr/bin/env bash
# Reproducible Supabase edge-function deploy payload (the recipe used for catpaw-api v48/v49 and proactive v9).
# Usage: services/edge/scripts/bundle-function.sh <git-ref> <function-name> <out-dir>
# Needs node >= 22 (npx) and python3. Never deploys anything; prints SHA256SUMS.
set -euo pipefail
[[ $# -eq 3 ]] || { echo "usage: $0 <git-ref> <function-name> <out-dir>" >&2; exit 2; }
REF=$1 FN=$2 OUT=$3
ESBUILD_VERSION=0.24.0
F=services/edge/supabase/functions
ROOT=$(git rev-parse --show-toplevel)
SHA=$(git -C "$ROOT" rev-parse --verify "$REF^{commit}")
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
git -C "$ROOT" archive "$SHA" "$F" | tar -x -C "$TMP"
[[ -f "$TMP/$F/$FN/index.ts" ]] || { echo "no $F/$FN/index.ts at $SHA" >&2; exit 1; }
mkdir -p "$OUT/$FN"; OUT=$(cd "$OUT" && pwd)
( cd "$TMP/$F" && npx -y "esbuild@$ESBUILD_VERSION" "$FN/index.ts" --bundle --format=esm \
    --platform=neutral --target=es2022 --keep-names \
    '--external:npm:*' '--external:node:*' '--external:jsr:*' '--external:https:*' \
    --metafile="$OUT/esbuild-meta.json" --outfile="$OUT/$FN/index.ts" --log-level=error )
cp "$TMP/$F/deno.json" "$OUT/deno.json"
python3 - "$OUT" "$FN" "$SHA" "$ESBUILD_VERSION" <<'PY'
import hashlib, json, sys, os
out, fn, sha, ver = sys.argv[1:]
h = lambda p: hashlib.sha256(open(os.path.join(out, p), 'rb').read()).hexdigest()
files = [{"name": f"{fn}/index.ts", "content": open(f"{out}/{fn}/index.ts").read()},
         {"name": "deno.json", "content": open(f"{out}/deno.json").read()}]
json.dump(files, open(f"{out}/files.json", "w"))
manifest = {"name": fn, "entrypoint_path": f"{fn}/index.ts", "import_map_path": "deno.json",
            "verify_jwt": False, "source": sha, "esbuild": ver,
            "files_json": "files.json (array of {name,content}; pass as `files`)",
            "sha256": {p: h(p) for p in (f"{fn}/index.ts", "deno.json", "files.json")}}
json.dump(manifest, open(f"{out}/manifest.json", "w"), indent=1)
with open(f"{out}/SHA256SUMS", "w") as s:
    for p in (f"{fn}/index.ts", "deno.json", "files.json", "esbuild-meta.json", "manifest.json"):
        s.write(f"{h(p)}  {p}\n")
PY
cat "$OUT/SHA256SUMS"
