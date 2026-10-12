#!/bin/sh
# Extract only the known committed pure validator, never a mutable owner's worktree.
set -eu
package_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
repo_root=$(git -C "$package_dir" rev-parse --show-toplevel)
source_ref=8ce77b450f51c93faf5e1fee100d7c0968086b98
build_dir="$package_dir/.build-ios-sdk/pinned-v2"
mkdir -p "$build_dir/src" "$build_dir/facade-r2/src"
git -C "$repo_root" show "$source_ref:services/edge/supabase/functions/_shared/core/src/vision-contract.mjs" > "$build_dir/src/vision-contract.mjs"
git -C "$repo_root" show "$source_ref:services/edge/supabase/functions/_shared/core/facade-r2/src/common.mjs" > "$build_dir/facade-r2/src/common.mjs"
"${CATPAW_IMAGE_NODE_BIN:-node}" "$package_dir/Verification/vision-v2-interop.mjs" \
    "$build_dir/src/vision-contract.mjs" "$package_dir/.build-ios-sdk/interop.json"
