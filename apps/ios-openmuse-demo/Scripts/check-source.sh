#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
mkdir -p .build/module-cache
sources=(Sources/Domain/*.swift Sources/Persistence/*.swift Sources/Providers/*.swift Sources/Features/*.swift Sources/Voice/*.swift Sources/DesignSystem/*.swift Sources/App/*.swift)
swiftc -typecheck -target arm64-apple-macosx14.0 -sdk "$(xcrun --sdk macosx --show-sdk-path)" -module-cache-path .build/module-cache $sources
print 'PASS macOS conditional typecheck; iOS-only bodies excluded'
swiftc -frontend -parse -target arm64-apple-ios17.0 $sources Tests/NativeTests.swift
print 'PASS iOS syntax parse only; no SDK/API/macro/link validation'
python3 Scripts/validate-project.py
python3 Scripts/check-localization.py
