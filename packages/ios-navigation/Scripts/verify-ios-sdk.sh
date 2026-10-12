#!/bin/sh
# Use an already installed Xcode; caller supplies DEVELOPER_DIR when necessary.
set -eu
package_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
build_dir="$package_dir/.build-ios-sdk"
mkdir -p "$build_dir"
sdk_path=$(xcrun --sdk iphonesimulator --show-sdk-path)
xcrun --sdk iphonesimulator swiftc -target arm64-apple-ios17.0-simulator -sdk "$sdk_path" \
    -module-name CatpawNavigation -emit-library -o "$build_dir/libCatpawNavigation.dylib" -emit-module -emit-module-path "$build_dir/CatpawNavigation.swiftmodule" \
    "$package_dir"/Sources/CatpawNavigation/*.swift
xcrun --sdk iphonesimulator swiftc -target arm64-apple-ios17.0-simulator -sdk "$sdk_path" \
    "$package_dir/Sources/CatpawNavigation/SidebarModel.swift" "$package_dir/Verification/PolicySmoke.swift" \
    -o "$build_dir/SidebarPolicySmoke"
printf '%s\n' 'PASS iOS simulator SDK library compile/link (SwiftUI + UIKit bridge); no App installed'
# Optional: run policy smoke in an existing dedicated arm64 simulator. Never pick a device automatically.
if [ -n "${SIDEBAR_TEST_DEVICE:-}" ]; then
    xcrun simctl spawn "$SIDEBAR_TEST_DEVICE" "$build_dir/SidebarPolicySmoke"
fi
