#!/bin/zsh
# Clean DeviceTrial build for BE5C with CatpawGitSHA derived from git (content SHA = HEAD at build time).
set -euo pipefail
cd "$(dirname "$0")/.."
SHA=$(git rev-parse --short HEAD)
PLIST=Configuration/DeviceTrial.Info.plist
/usr/libexec/PlistBuddy -c "Set :CatpawGitSHA $SHA" "$PLIST"
DD=/tmp/dd-v2
rm -rf "$DD"
xcodebuild -project CatpawM.xcodeproj -scheme DeviceTrial \
  -destination 'id=BE5C60E0-B415-4BF4-8F36-8975FB5314AA' -derivedDataPath "$DD" clean build
echo "Built CatpawGitSHA=$SHA"
