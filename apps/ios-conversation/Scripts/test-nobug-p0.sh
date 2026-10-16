#!/bin/zsh
# NoBug P0 portable unit tests (memory persistence/migration, device-call durability/dedupe, contract, ProactiveRules).
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .build/nobug-p0 .build/module-cache
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
swiftc -parse-as-library -D MEMORY_PORTABLE -swift-version 5 -target arm64-apple-macosx14.0 -sdk "$sdk_path" -module-cache-path .build/module-cache -framework JavaScriptCore \
  Sources/Domain/*.swift Sources/Persistence/Repository.swift Sources/Persistence/BlobStore.swift Sources/Features/WorkspaceService.swift Sources/Features/ConversationMemoryService.swift \
  Sources/Features/Memory/MemoryLibrary.swift Sources/Features/Memory/MemoryLibraryLocal.swift \
  Sources/Features/DeviceCalls/DeviceCall.swift Sources/Features/DeviceCalls/DeviceToolContract.swift Sources/Features/Proactive/ProactiveRules.swift Sources/Features/Proactive/ProactiveQuota.swift Sources/Features/Proactive/ProactiveAccountGate.swift Sources/Features/Nearby/NearbyRules.swift \
  Tests/NoBugP0Shims.swift Tests/NoBugP0Runner.swift -o .build/nobug-p0/runner
.build/nobug-p0/runner
# Codex PR90: proactive delivery/quota/account/queue runner (pure; ProactiveEngine itself needs the iOS SDK).
bash Scripts/test-proactive-pr90.sh
