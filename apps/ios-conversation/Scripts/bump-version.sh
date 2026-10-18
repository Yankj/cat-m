#!/bin/sh
# Bump the marketing version (SemVer) and open its CHANGELOG section. The build number is automatic (git commit count).
# Usage: Scripts/bump-version.sh major|minor|patch
#        Scripts/bump-version.sh --version 1.2.0
set -eu
if [ "$#" -lt 1 ]; then
  echo "usage: $0 major|minor|patch | --version X.Y.Z" >&2
  exit 64
fi
exec /usr/bin/env python3 "$(dirname "$0")/app-version.py" bump "$@"
