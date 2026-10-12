#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
mkdir -p .build/module-cache
cp Resources/UIStrings.json .build/UIStrings.json
sdk="$(xcrun --sdk macosx --show-sdk-path)"
swiftc -target arm64-apple-macosx14.0 -sdk "$sdk" -module-cache-path .build/module-cache \
  Sources/Domain/*.swift Sources/Persistence/Repository.swift Sources/Persistence/BlobStore.swift \
  Sources/Features/*Service.swift Sources/Features/GatewayAssistantImporter.swift Sources/Providers/*.swift Tests/DomainRunner.swift Tests/ProductRegression.swift \
  -o .build/domain-tests
.build/domain-tests
