#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .build/device-effect-contract-tests .build/module-cache
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
swiftc -D DEVICE_EFFECT_CONTRACT_PORTABLE -swift-version 5 -target arm64-apple-macosx14.0 -sdk "$sdk_path" -module-cache-path .build/module-cache Sources/Domain/*.swift Sources/Persistence/Repository.swift Sources/Persistence/BlobStore.swift Sources/Features/WorkspaceService.swift Tests/ConversationDeviceEffectContractTests.swift -o .build/device-effect-contract-tests/runner
.build/device-effect-contract-tests/runner
