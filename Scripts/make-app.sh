#!/bin/zsh
# Builds Spindle.app from the SPM package.
#
# Usage:
#   Scripts/make-app.sh                 # debug build, ad-hoc signed
#   Scripts/make-app.sh release         # optimized universal build
#   SIGN_IDENTITY="Developer ID Application: …" Scripts/make-app.sh release
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${1:-debug}"
BUILD_ARGS=(--product SpindleApp)
if [[ "$CONFIG" == "release" ]]; then
    BUILD_ARGS+=(-c release --arch arm64 --arch x86_64)
    BIN_DIR=".build/apple/Products/Release"
else
    BUILD_ARGS+=(-c debug)
    BIN_DIR=".build/debug"
fi

echo "Building ($CONFIG)…"
swift build "${BUILD_ARGS[@]}"

APP="dist/Spindle.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/SpindleApp" "$APP/Contents/MacOS/Spindle"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/Spindle.icns "$APP/Contents/Resources/Spindle.icns"

# Regenerate the icon if it's missing.
if [[ ! -f Resources/Spindle.icns ]]; then
    swift Scripts/make-icon.swift Resources
fi

IDENTITY="${SIGN_IDENTITY:--}"
echo "Signing with: $IDENTITY"
codesign --force --options runtime --sign "$IDENTITY" "$APP"

echo "Built $APP"
codesign -dv "$APP" 2>&1 | head -3
