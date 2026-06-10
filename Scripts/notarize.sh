#!/bin/zsh
# Notarizes and staples dist/Spindle.app.
#
# Prerequisites:
#   - Scripts/make-app.sh release was run with SIGN_IDENTITY set to a
#     "Developer ID Application" certificate
#   - A notarytool keychain profile: xcrun notarytool store-credentials \
#       spindle-notary --apple-id you@example.com --team-id TEAMID
#
# Usage: Scripts/notarize.sh [profile-name]
set -euo pipefail

cd "$(dirname "$0")/.."
PROFILE="${1:-spindle-notary}"
APP="dist/Spindle.app"
ZIP="dist/Spindle-notarize.zip"

[[ -d "$APP" ]] || { echo "Run Scripts/make-app.sh release first."; exit 1; }

echo "Zipping…"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "Submitting to Apple notary service…"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait

echo "Stapling…"
xcrun stapler staple "$APP"
rm -f "$ZIP"

echo "Verifying…"
spctl -a -vv "$APP"
echo "Done — $APP is notarized."
