#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .build/memory-transport-tests .build/memory-transport-cache
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
swiftc -D MEMORY_TRANSPORT_PORTABLE -swift-version 5 -target arm64-apple-macosx14.0 -sdk "$sdk_path" -module-cache-path .build/memory-transport-cache Sources/Domain/*.swift Sources/Persistence/Repository.swift Sources/Persistence/BlobStore.swift Sources/Persistence/ConversationOutbox.swift Sources/Features/WorkspaceService.swift Sources/Features/ConversationSessionService.swift Sources/Persistence/L2SecureStore.swift Sources/Features/ConversationMemoryService.swift Sources/Features/ConversationDeviceEffectService.swift Sources/Providers/NativeChatHTTPBackend.swift Sources/Providers/NativeMemoryHTTPBackend.swift Sources/Providers/NativeDeviceEffectHTTPBackend.swift Sources/Providers/SupabaseUserAccessSession.swift Sources/Providers/NativeChatComposition.swift Tests/DeviceEffectApplicationFixture.swift Tests/ConversationMemoryTransportTests.swift -o .build/memory-transport-tests/runner
.build/memory-transport-tests/runner
