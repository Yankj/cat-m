#!/bin/zsh
# This client imports UIKit; validate against the installed iOS Simulator SDK.
set -eu
cd "$(dirname "$0")/.."
mkdir -p .build/module-cache
sources=(Sources/Domain/*.swift Sources/Persistence/*.swift Sources/Providers/*.swift Sources/Features/*.swift Sources/Voice/*.swift Sources/DesignSystem/*.swift Sources/App/*.swift)
swiftc -swift-version 5 -typecheck -parse-as-library -module-name CatpawM \
  -target arm64-apple-ios17.0-simulator -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
  -module-cache-path .build/module-cache $sources
print 'PASS non-DEBUG iOS Simulator SDK typecheck; no link, XCTest or installation claim'
swiftc -frontend -parse -target arm64-apple-ios17.0 $sources Tests/NativeTests.swift
print 'PASS iOS source/test syntax parse'
python3 Scripts/validate-project.py
# Keep the actual product localization gate: do not mask imported untranslated UI.
python3 Scripts/check-localization.py
