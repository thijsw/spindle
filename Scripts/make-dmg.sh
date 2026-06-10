#!/bin/zsh
# Packages dist/Spindle.app into a distributable disk image.
# Usage: Scripts/make-dmg.sh
set -euo pipefail

cd "$(dirname "$0")/.."
APP="dist/Spindle.app"
DMG="dist/Spindle.dmg"
STAGE="dist/dmg-stage"

[[ -d "$APP" ]] || { echo "Run Scripts/make-app.sh first."; exit 1; }

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

hdiutil create -volname "Spindle" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"

echo "Built $DMG"
