#!/bin/zsh
# Clean DeviceTrial build for BE5C. Version, build number (git commit count), CatpawGitSHA and CatpawBuildDate are
# stamped into the packaged Info.plist by the "Stamp Build Info" phase; nothing in the source tree is edited.
set -euo pipefail
cd "$(dirname "$0")/.."
DD=/tmp/dd-v2
rm -rf "$DD"
xcodebuild -project CatpawM.xcodeproj -scheme DeviceTrial \
  -destination 'id=BE5C60E0-B415-4BF4-8F36-8975FB5314AA' -derivedDataPath "$DD" clean build
APP=$(find "$DD/Build/Products" -maxdepth 2 -name CatpawM.app -type d | head -1)
/usr/bin/python3 Scripts/app-version.py check --app "$APP"
