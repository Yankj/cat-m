#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .build/native-chat-wire .build/module-cache
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
swiftc -swift-version 5 -target arm64-apple-macosx14.0 -sdk "$sdk_path" -module-cache-path .build/module-cache \
 Sources/Domain/*.swift Sources/Persistence/Repository.swift Sources/Persistence/BlobStore.swift \
 Sources/Features/WorkspaceService.swift Sources/Features/ConversationSessionService.swift Sources/Providers/NativeChatHTTPBackend.swift Sources/Providers/SupabaseUserAccessSession.swift Sources/Providers/NativeChatComposition.swift \
 Tests/NativeChatWireRunner.swift -o .build/native-chat-wire/runner
test_dir="$(mktemp -d "$PWD/.build/native-chat-wire/scenario.XXXXXX")"
"${CATPAW_NODE:?Set CATPAW_NODE to the installed Node binary}" Tests/native-chat-wire-server.mjs > "$test_dir/server.log" 2>&1 &
server_pid=$!
trap 'kill "$server_pid" 2>/dev/null || true' EXIT
for attempt in {1..30}; do
 if [[ -s "$test_dir/server.log" ]]; then break; fi
 sleep 0.1
done
origin="$(sed -n 's/^ORIGIN=//p' "$test_dir/server.log")"
.build/native-chat-wire/runner "$origin" "$test_dir"
