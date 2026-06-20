#!/bin/zsh
# Notarizes and staples a Developer ID-signed artifact — the .app or the .dmg.
#
# Prerequisites (either authentication method works):
#   - The target was signed with a "Developer ID Application" certificate
#     (Scripts/make-app.sh release / Scripts/make-dmg.sh with SIGN_IDENTITY set)
#   - Interactive/local: a notarytool keychain profile —
#       xcrun notarytool store-credentials spindle-notary \
#         --apple-id you@example.com --team-id TEAMID
#   - CI/headless: set NOTARY_APPLE_ID, NOTARY_TEAM_ID and NOTARY_PASSWORD
#     (an app-specific password) in the environment; they take precedence.
#
# Usage: Scripts/notarize.sh [target] [profile-name]
#   target defaults to dist/Spindle.app; pass dist/Spindle.dmg to staple the image.
set -euo pipefail

cd "$(dirname "$0")/.."
TARGET="${1:-dist/Spindle.app}"
PROFILE="${2:-spindle-notary}"

[[ -e "$TARGET" ]] || { echo "Missing $TARGET — build it first."; exit 1; }

# Prefer explicit credentials from the environment (CI); otherwise fall back
# to a stored keychain profile (local development).
if [[ -n "${NOTARY_APPLE_ID:-}" && -n "${NOTARY_TEAM_ID:-}" && -n "${NOTARY_PASSWORD:-}" ]]; then
    AUTH=(--apple-id "$NOTARY_APPLE_ID" --team-id "$NOTARY_TEAM_ID" --password "$NOTARY_PASSWORD")
else
    AUTH=(--keychain-profile "$PROFILE")
fi

# notarytool accepts a .dmg/.pkg directly, but an .app bundle must be zipped.
ZIP=""
if [[ "$TARGET" == *.app ]]; then
    ZIP="${TARGET%.app}-notarize.zip"
    echo "Zipping…"
    ditto -c -k --keepParent "$TARGET" "$ZIP"
    SUBMIT="$ZIP"
else
    SUBMIT="$TARGET"
fi

echo "Submitting $SUBMIT to Apple notary service…"
xcrun notarytool submit "$SUBMIT" "${AUTH[@]}" --wait

echo "Stapling $TARGET…"
xcrun stapler staple "$TARGET"
[[ -n "$ZIP" ]] && rm -f "$ZIP"

echo "Verifying…"
if [[ "$TARGET" == *.dmg ]]; then
    spctl -a -t open --context context:primary-signature -vv "$TARGET"
else
    spctl -a -t exec -vv "$TARGET"
fi
echo "Done — $TARGET is notarized."
