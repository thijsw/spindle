#!/bin/zsh
# Builds dist/Spindle.app via xcodebuild.
#
# Usage:
#   Scripts/make-app.sh                 # Debug, current arch
#   Scripts/make-app.sh release         # Release, universal (arm64 + x86_64)
#   SIGN_IDENTITY="Developer ID Application: …" Scripts/make-app.sh release
set -euo pipefail

cd "$(dirname "$0")/.."

EXTRA_ARGS=()
if [[ "${1:-debug}" == "release" ]]; then
    CONFIG="Release"
    EXTRA_ARGS+=(ONLY_ACTIVE_ARCH=NO 'ARCHS=arm64 x86_64')
else
    CONFIG="Debug"
fi

echo "Building ($CONFIG)…"
xcodebuild \
    -project Spindle.xcodeproj \
    -scheme Spindle \
    -configuration "$CONFIG" \
    -destination 'platform=macOS' \
    SYMROOT="$PWD/.build/xcode" \
    "${EXTRA_ARGS[@]}" \
    -quiet build

mkdir -p dist
rm -rf dist/Spindle.app
cp -R ".build/xcode/$CONFIG/Spindle.app" dist/

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    echo "Re-signing with: $SIGN_IDENTITY"
    codesign --force --deep --options runtime --sign "$SIGN_IDENTITY" dist/Spindle.app
fi

echo "Built dist/Spindle.app"
codesign -dv dist/Spindle.app 2>&1 | head -3
