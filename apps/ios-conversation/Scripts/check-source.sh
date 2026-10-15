#!/bin/zsh
# This client imports UIKit; validate against the installed iOS Simulator SDK.
set -eu
cd "$(dirname "$0")/.."
python3 ../../scripts/check-typography.py --self-test
mkdir -p .build/module-cache
sdk_path="$(xcrun --sdk iphonesimulator --show-sdk-path)"
mkdir -p .build/check-modules
# Emit only the two checked-in local modules. No download, linking or runtime claim.
for package in ios-navigation ios-image-composer; do
  if [[ "$package" == ios-navigation ]]; then module=CatpawNavigation; else module=CatpawImageComposer; fi
  swiftc -swift-version 5 -emit-module -parse-as-library -module-name "$module" \
    -target arm64-apple-ios17.0-simulator -sdk "$sdk_path" \
    -module-cache-path .build/module-cache -emit-module-path ".build/check-modules/$module.swiftmodule" \
    ../../packages/$package/Sources/$module/*.swift
done
sources=(Sources/Domain/*.swift Sources/Persistence/*.swift Sources/Providers/*.swift Sources/Features/*.swift Sources/Voice/*.swift Sources/DesignSystem/*.swift Sources/App/*.swift)
swiftc -swift-version 5 -typecheck -parse-as-library -module-name CatpawM \
  -target arm64-apple-ios17.0-simulator -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
  -module-cache-path .build/module-cache -I .build/check-modules $sources
print 'PASS non-DEBUG iOS Simulator SDK typecheck; no link, XCTest or installation claim'
swiftc -frontend -parse -target arm64-apple-ios17.0 $sources Tests/NativeTests.swift
print 'PASS iOS source/test syntax parse'
python3 Scripts/validate-project.py
# Keep the actual product localization gate: do not mask imported untranslated UI.
python3 Scripts/check-localization.py
