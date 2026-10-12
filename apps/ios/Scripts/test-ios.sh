#!/bin/zsh
# Use an already installed Xcode and existing Simulator. This script changes no global selection.
set -euo pipefail
cd "${0:A:h:h}"
: "${DEVELOPER_DIR:?Set DEVELOPER_DIR to an existing Xcode Contents/Developer directory}"
: "${CATPAW_SIMULATOR_UDID:?Set CATPAW_SIMULATOR_UDID to an existing Simulator device ID}"
mode="${1:-all}"
case "$mode" in
  unit) tests=(-only-testing:CatpawMTests) ;;
  ui) tests=(-only-testing:CatpawMUITests) ;;
  all) tests=() ;;
  *) print -u2 'Usage: test-ios.sh [unit|ui|all]'; exit 2 ;;
esac
run="$(date -u +%Y%m%dT%H%M%SZ)-$mode"
output=".build/ios-native-$run"
mkdir -p "$output"
xcodebuild -version > "$output/toolchain.txt"
xcodebuild -project CatpawM.xcodeproj -scheme CatpawM -sdk iphonesimulator \
  -destination "platform=iOS Simulator,id=$CATPAW_SIMULATOR_UDID" \
  -derivedDataPath "${CATPAW_DERIVED_DATA:-.build-ios/IntegratedDerivedData}" -resultBundlePath ".build-ios/$run.xcresult" \
  -parallel-testing-enabled NO "${tests[@]}" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM= test \
  > "$output/test.log" 2>&1
print "PASS native $mode test; log: $output/test.log; result: .build-ios/$run.xcresult"
