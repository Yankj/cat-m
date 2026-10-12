#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .build/openmuse-http .build/module-cache
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
swiftc -swift-version 5 -target arm64-apple-macosx14.0 -sdk "$sdk_path" -module-cache-path .build/module-cache \
  Sources/Domain/*.swift Sources/Persistence/Repository.swift Sources/Persistence/BlobStore.swift \
  Sources/Features/*Service.swift Sources/Features/GatewayAssistantImporter.swift Sources/Providers/*.swift \
  Tests/OpenMuseHTTPRunner.swift -o .build/openmuse-http/client-runner
