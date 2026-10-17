# Reproducible edge-function bundle

`services/edge/scripts/bundle-function.sh <git-ref> <function> <out-dir>` builds the deploy payload from
`git archive <ref>` only, so the working tree has no effect. It uses esbuild 0.24.0 with these flags:
`--bundle --format=esm --platform=neutral --target=es2022 --keep-names --external:npm:* node:* jsr:* https:*`.

Output: `<function>/index.ts`, `deno.json`, `files.json` (`[{name,content}]` for Supabase deploy `files`),
`esbuild-meta.json`, `manifest.json`, `SHA256SUMS`. The script never deploys anything.

Needs node ≥ 22 (`npx`) and python3.

Reference hashes (index.ts sha256):
| ref | function | index.ts |
|---|---|---|
| 792587e | catpaw-api (v48) | d75898a2… |
| 792587e | catpaw-proactive (v9) | 445abb73ecab52df… |
| 99e5296 / e9383ca | catpaw-api (v49) | 447f9ceaec6d952f… |
| 42897a64 | catpaw-api (chat-context candidate) | ecf189ef065a4321… |

Compare `<function>/index.ts` against the production source from Supabase `get_edge_function`.
`files.json` is byte-stable for the same ref, but older hand-built payloads may have serialized it differently.
