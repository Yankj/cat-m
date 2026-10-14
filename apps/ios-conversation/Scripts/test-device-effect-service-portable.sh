#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .build/device-effect-service-tests .build/module-cache
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
variant=DEVICE_EFFECT_SERVICE_PORTABLE
test_source=Tests/ConversationDeviceEffectServiceTests.swift
runner=runner
if [[ "${1:-}" == "--transport" ]]; then
  variant=DEVICE_EFFECT_TRANSPORT_PORTABLE
  test_source=Tests/NativeDeviceEffectTransportTests.swift
  runner=transport
fi
swiftc -D "$variant" -swift-version 5 -target arm64-apple-macosx14.0 -sdk "$sdk_path" -module-cache-path .build/module-cache Sources/Domain/*.swift Sources/Persistence/Repository.swift Sources/Persistence/BlobStore.swift Sources/Features/WorkspaceService.swift Sources/Features/ConversationSessionService.swift Sources/Features/ConversationDeviceEffectService.swift Sources/Providers/NativeChatHTTPBackend.swift Sources/Providers/NativeDeviceEffectHTTPBackend.swift Sources/Providers/SupabaseUserAccessSession.swift Sources/Providers/NativeChatComposition.swift Tests/DeviceEffectApplicationFixture.swift "$test_source" -o ".build/device-effect-service-tests/$runner"
".build/device-effect-service-tests/$runner"
