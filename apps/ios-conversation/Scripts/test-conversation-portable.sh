#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .build/conversation-tests .build/module-cache
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
swiftc -swift-version 5 -target arm64-apple-macosx14.0 -sdk "$sdk_path" -module-cache-path .build/module-cache \
  Sources/Domain/*.swift Sources/Persistence/Repository.swift Sources/Persistence/BlobStore.swift \
  Sources/Features/WorkspaceService.swift Sources/Features/ConversationSessionService.swift Sources/Features/ConversationArtifactContinuationService.swift \
  Tests/ConversationSessionRunner.swift -o .build/conversation-tests/runner
scenario_dir="$(mktemp -d "$PWD/.build/conversation-tests/scenario.XXXXXX")"
.build/conversation-tests/runner "$scenario_dir"
