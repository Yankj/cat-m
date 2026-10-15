#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .build/native-revision-work-wire .build/module-cache
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
swiftc -swift-version 5 -target arm64-apple-macosx14.0 -sdk "$sdk_path" -module-cache-path .build/module-cache \
 Sources/Domain/*.swift Sources/Persistence/Repository.swift Sources/Persistence/BlobStore.swift Sources/Persistence/ConversationOutbox.swift \
 Sources/Features/WorkspaceService.swift Sources/Features/ConversationSessionService.swift Sources/Features/ConversationArtifactContinuationService.swift \
 Sources/Providers/NativeChatHTTPBackend.swift Sources/Providers/SupabaseUserAccessSession.swift Sources/Providers/NativeChatComposition.swift \
 Tests/NativeRevisionWorkWireRunner.swift -o .build/native-revision-work-wire/runner
if [[ "${1:-}" == "--compile-only" ]]; then exit 0; fi
: "${CATPAW_REVISION_WIRE_FIXTURE:?Set CATPAW_REVISION_WIRE_FIXTURE to the actual maintained-handler recording}"
: "${CATPAW_NODE:?Set CATPAW_NODE to the installed Node binary}"
test_dir="$(mktemp -d "$PWD/.build/native-revision-work-wire/scenario.XXXXXX")"
"$CATPAW_NODE" Tests/native-revision-work-wire-server.mjs > "$test_dir/server.log" 2>&1 &
server_pid=$!
trap 'kill "$server_pid" 2>/dev/null || true' EXIT
for attempt in {1..30}; do
 if [[ -s "$test_dir/server.log" ]]; then break; fi
 sleep 0.1
done
origin="$(sed -n 's/^ORIGIN=//p' "$test_dir/server.log")"
[[ -n "$origin" ]]
.build/native-revision-work-wire/runner "$origin" "$test_dir" "$CATPAW_REVISION_WIRE_FIXTURE"
