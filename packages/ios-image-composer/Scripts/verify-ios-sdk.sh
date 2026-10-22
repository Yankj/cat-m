#!/bin/sh
set -eu
package_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
build_dir="$package_dir/.build-ios-sdk"
mkdir -p "$build_dir"
sdk_path=$(xcrun --sdk iphonesimulator --show-sdk-path)
xcrun --sdk iphonesimulator swiftc -swift-version 5 -target arm64-apple-ios17.0-simulator -sdk "$sdk_path" \
    -module-name catImageComposer -emit-library -o "$build_dir/libcatImageComposer.dylib" \
    -emit-module -emit-module-path "$build_dir/catImageComposer.swiftmodule" "$package_dir"/Sources/catImageComposer/*.swift
xcrun --sdk iphonesimulator swiftc -swift-version 5 -target arm64-apple-ios17.0-simulator -sdk "$sdk_path" \
    "$package_dir/Sources/catImageComposer/ImageAttachment.swift" \
    "$package_dir/Sources/catImageComposer/SystemImageAttachmentEncoder.swift" \
    "$package_dir/Tests/catImageComposerTests/SyntheticImages.swift" "$package_dir/Verification/CodecSmoke.swift" \
    -o "$build_dir/CodecSmoke"
printf '%s\n' 'PASS iOS SDK image component library compile/link (PhotosPicker included); no installation'
if [ -n "${CATPAW_IMAGE_TEST_DEVICE:-}" ]; then
    xcrun simctl spawn "$CATPAW_IMAGE_TEST_DEVICE" "$build_dir/CodecSmoke" "$build_dir/interop.json"
fi
