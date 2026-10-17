#!/bin/zsh
set -euo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p .build/memory-tests .build/module-cache
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
swiftc -D MEMORY_PORTABLE -swift-version 5 -target arm64-apple-macosx14.0 -sdk "$sdk_path" -module-cache-path .build/module-cache -framework JavaScriptCore Sources/Domain/*.swift Sources/Persistence/Repository.swift Sources/Persistence/BlobStore.swift Sources/Persistence/L2SecureStore.swift Sources/Features/WorkspaceService.swift Sources/Features/ConversationMemoryService.swift Tests/ConversationMemoryTests.swift -o .build/memory-tests/runner
.build/memory-tests/runner Tests/Fixtures/memory-wire-v1.json Tests/Fixtures/memory-wire-v2.json Tests/Fixtures/memory-canonical-v1.json
