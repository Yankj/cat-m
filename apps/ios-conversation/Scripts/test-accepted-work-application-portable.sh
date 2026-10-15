#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .build/accepted-work-application-tests .build/module-cache
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
swiftc -D ACCEPTED_WORK_APPLICATION_PORTABLE -swift-version 5 -target arm64-apple-macosx14.0 -sdk "$sdk_path" -module-cache-path .build/module-cache Sources/Domain/*.swift Sources/Persistence/Repository.swift Sources/Persistence/BlobStore.swift Sources/Features/WorkspaceService.swift Sources/Features/ConversationSessionService.swift Sources/Features/ConversationArtifactContinuationService.swift Sources/Features/ConversationAcceptedWorkDraftService.swift Sources/Features/ConversationFollowupQueueService.swift Sources/Features/ConversationDeviceEffectService.swift Sources/Providers/NativeChatHTTPBackend.swift Sources/Providers/NativeDeviceEffectHTTPBackend.swift Sources/Providers/SupabaseUserAccessSession.swift Sources/Providers/NativeChatComposition.swift Tests/DeviceEffectApplicationFixture.swift Tests/ConversationAcceptedWorkApplicationTests.swift -o .build/accepted-work-application-tests/runner
.build/accepted-work-application-tests/runner
