#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p ../../build/goal-amend-20261014/portable-runtime .build/module-cache
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
swiftc -D DEBUG -D ARTIFACT_EDIT_PORTABLE -swift-version 5 -target arm64-apple-macosx14.0 -sdk "$sdk_path" -module-cache-path .build/module-cache Sources/Domain/*.swift Sources/Persistence/Repository.swift Sources/Persistence/BlobStore.swift Sources/Features/WorkspaceService.swift Sources/Features/ConversationLocalDraftDrains.swift Sources/Features/ConversationArtifactEditService.swift Sources/Features/ConversationArtifactEditModel.swift Sources/App/ConversationArtifactEditFixture.swift Tests/ConversationArtifactEditTests.swift -o ../../build/goal-amend-20261014/portable-runtime/artifact-edit-tests
ARTIFACT_EDIT_TEST_ROOT="${PWD}/../../build/goal-amend-20261014/portable-runtime" ../../build/goal-amend-20261014/portable-runtime/artifact-edit-tests
