#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .build/generative-ui-tests .build/generative-ui-tests/module-cache
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
swiftc -swift-version 5 -D CGUI_PORTABLE -target arm64-apple-macosx14.0 -sdk "$sdk_path" \
  -module-cache-path .build/generative-ui-tests/module-cache \
  Sources/Domain/ConversationGenerativeUI.swift Tests/ConversationGenerativeUITests.swift \
  -o .build/generative-ui-tests/runner
.build/generative-ui-tests/runner
