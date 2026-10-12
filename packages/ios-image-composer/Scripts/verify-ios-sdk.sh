#!/bin/sh
set -eu
package_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
build_dir="$package_dir/.build-ios-sdk"
mkdir -p "$build_dir"
sdk_path=$(xcrun --sdk iphonesimulator --show-sdk-path)
xcrun --sdk iphonesimulator swiftc -swift-version 5 -target arm64-apple-ios17.0-simulator -sdk "$sdk_path" \
    -module-name CatpawImageComposer -emit-library -o "$build_dir/libCatpawImageComposer.dylib" \
    -emit-module -emit-module-path "$build_dir/CatpawImageComposer.swiftmodule" "$package_dir"/Sources/CatpawImageComposer/*.swift
xcrun --sdk iphonesimulator swiftc -swift-version 5 -target arm64-apple-ios17.0-simulator -sdk "$sdk_path" \
    "$package_dir/Sources/CatpawImageComposer/ImageAttachment.swift" \
    "$package_dir/Sources/CatpawImageComposer/SystemImageAttachmentEncoder.swift" \
    "$package_dir/Tests/CatpawImageComposerTests/SyntheticImages.swift" "$package_dir/Verification/CodecSmoke.swift" \
    -o "$build_dir/CodecSmoke"
printf '%s\n' 'PASS iOS SDK image component library compile/link (PhotosPicker included); no installation'
if [ -n "${CATPAW_IMAGE_TEST_DEVICE:-}" ]; then
    xcrun simctl spawn "$CATPAW_IMAGE_TEST_DEVICE" "$build_dir/CodecSmoke" "$build_dir/interop.json"
fi
