#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .build/artifact-projection-tests .build/module-cache
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
swiftc -D ARTIFACT_PROJECTION_PORTABLE -swift-version 5 -target arm64-apple-macosx14.0 -sdk "$sdk_path" -module-cache-path .build/module-cache Sources/Domain/*.swift Sources/Persistence/Repository.swift Sources/Persistence/BlobStore.swift Sources/Persistence/ConversationOutbox.swift Sources/Features/WorkspaceService.swift Sources/Features/ConversationSessionService.swift Tests/ConversationArtifactProjectionTests.swift -o .build/artifact-projection-tests/runner
.build/artifact-projection-tests/runner
