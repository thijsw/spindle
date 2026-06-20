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
    APP="dist/Spindle.app"
    SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"

    sign() { codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$@"; }

    # Sparkle embeds nested helpers (XPC services, Autoupdate, Updater.app) that
    # must EACH be signed with the hardened runtime and a secure timestamp, or
    # notarization rejects the whole app. `--deep` can't do this reliably, so
    # sign inside-out: deepest code first, the app bundle last (which then seals
    # everything already signed beneath it).
    if [[ -d "$SPARKLE" ]]; then
        for xpc in "$SPARKLE"/Versions/B/XPCServices/*.xpc(N); do sign "$xpc"; done
        [[ -e "$SPARKLE/Versions/B/Autoupdate" ]] && sign "$SPARKLE/Versions/B/Autoupdate"
        [[ -d "$SPARKLE/Versions/B/Updater.app" ]] && sign "$SPARKLE/Versions/B/Updater.app"
        sign "$SPARKLE"
    fi

    # Any other embedded dylibs/frameworks Xcode bundled.
    for lib in "$APP"/Contents/Frameworks/*.dylib(N) "$APP"/Contents/Frameworks/*.framework(N); do
        [[ "$lib" == "$SPARKLE" ]] && continue
        sign "$lib"
    done

    sign "$APP"
fi

echo "Built dist/Spindle.app"
codesign -dv dist/Spindle.app 2>&1 | head -3
