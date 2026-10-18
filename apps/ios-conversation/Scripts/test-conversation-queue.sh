#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .build/conversation-queue .build/module-cache
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
swiftc -swift-version 5 -target arm64-apple-macosx14.0 -sdk "$sdk_path" -module-cache-path .build/module-cache Sources/Domain/*.swift Sources/Persistence/Repository.swift Sources/Persistence/BlobStore.swift Sources/Persistence/ConversationOutbox.swift Sources/Features/WorkspaceService.swift Sources/Features/ConversationSessionService.swift Sources/Providers/NativeChatHTTPBackend.swift Sources/Features/ConversationArtifactContinuationService.swift Sources/Features/ConversationFollowupQueueService.swift Sources/Features/ConversationAcceptedWorkDraftService.swift Tests/ConversationQueueRunner.swift -o .build/conversation-queue/runner
scenario_dir="$(mktemp -d "$PWD/.build/conversation-queue/scenario.XXXXXX")"
.build/conversation-queue/runner "$scenario_dir"
