#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .build/generative-ui-state-tests/module-cache
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
swiftc -swift-version 5 -D CGUI_STATE_PORTABLE -target arm64-apple-macosx14.0 -sdk "$sdk_path" \
  -module-cache-path .build/generative-ui-state-tests/module-cache Sources/Domain/*.swift \
  Sources/Persistence/Repository.swift Sources/Persistence/BlobStore.swift Sources/Features/WorkspaceService.swift \
  Sources/Features/ConversationGenerativeUIStateService.swift Tests/ConversationGenerativeUIStateTests.swift \
  -o .build/generative-ui-state-tests/runner
.build/generative-ui-state-tests/runner
