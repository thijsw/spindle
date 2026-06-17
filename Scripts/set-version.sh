#!/bin/zsh
# Stamps the marketing version and build number into Spindle/Info.plist.
#
# The release workflow calls this with the version derived from the git tag so
# the app's About box and Finder "Get Info" match the release. Run it by hand
# before Scripts/make-app.sh for a versioned local build (it edits the tracked
# Info.plist — don't commit that change).
#
# Usage: Scripts/set-version.sh <marketing-version> [build-number]
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${1:?usage: set-version.sh <marketing-version> [build-number]}"
BUILD="${2:-1}"
PLIST="Spindle/Info.plist"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$PLIST"

echo "Set version $VERSION (build $BUILD) in $PLIST"
