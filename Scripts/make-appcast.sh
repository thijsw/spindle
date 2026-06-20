#!/bin/zsh
# Builds/updates a Sparkle appcast.xml for one release and merges it into the
# existing feed, so the published appcast keeps every prior version's item.
#
# The DMG itself stays hosted on GitHub Releases (proper binary hosting); only
# this small XML lives on GitHub Pages. The DMG is EdDSA-signed here and the
# signature embedded in the enclosure.
#
# Inputs (env):
#   DMG              path to the signed+notarized .dmg to add            (required)
#   DOWNLOAD_URL     public URL the .dmg is served from                 (required)
#   VERSION          marketing version, e.g. 0.2.0                       (required)
#   BUILD            build number (CFBundleVersion)                      (required)
#   RELEASE_URL      GitHub release page, shown as the item's link       (optional)
#   MIN_OS           minimum system version (default 14.0)              (optional)
#   EXISTING_APPCAST path to the current appcast.xml to merge into       (optional)
#   OUT              output path (default: appcast.xml)                  (optional)
#   SPARKLE_BIN      Sparkle bin/ dir holding sign_update               (required)
#   SPARKLE_PRIVATE_KEY  EdDSA private key string; if unset, the
#                        Keychain key is used (local dev)               (optional)
set -euo pipefail
cd "$(dirname "$0")/.."

: "${DMG:?set DMG}"
: "${DOWNLOAD_URL:?set DOWNLOAD_URL}"
: "${VERSION:?set VERSION}"
: "${BUILD:?set BUILD}"
: "${SPARKLE_BIN:?set SPARKLE_BIN to Sparkle's bin/ directory (contains sign_update)}"
MIN_OS="${MIN_OS:-14.0}"
OUT="${OUT:-appcast.xml}"
RELEASE_URL="${RELEASE_URL:-}"

[[ -f "$DMG" ]] || { echo "No such DMG: $DMG"; exit 1; }
SIGN_UPDATE="$SPARKLE_BIN/sign_update"
[[ -x "$SIGN_UPDATE" ]] || { echo "sign_update not found/executable at $SIGN_UPDATE"; exit 1; }

# Sign the DMG. Prefer the private key from the environment (CI); otherwise the
# tool reads it from the Keychain (local development).
KEYFILE=""
cleanup() { [[ -n "$KEYFILE" ]] && rm -f "$KEYFILE"; }
trap cleanup EXIT
if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
    KEYFILE="$(mktemp)"
    printf '%s' "$SPARKLE_PRIVATE_KEY" > "$KEYFILE"
    SIG_LINE="$("$SIGN_UPDATE" --ed-key-file "$KEYFILE" "$DMG")"
else
    SIG_LINE="$("$SIGN_UPDATE" "$DMG")"
fi
# SIG_LINE looks like: sparkle:edSignature="…" length="…"
echo "Signature: $SIG_LINE"

PUBDATE="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"

DMG="$DMG" DOWNLOAD_URL="$DOWNLOAD_URL" VERSION="$VERSION" BUILD="$BUILD" \
RELEASE_URL="$RELEASE_URL" MIN_OS="$MIN_OS" OUT="$OUT" \
EXISTING_APPCAST="${EXISTING_APPCAST:-}" SIG_LINE="$SIG_LINE" PUBDATE="$PUBDATE" \
python3 - <<'PY'
import os, re, xml.etree.ElementTree as ET

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)
def sp(tag): return f"{{{SPARKLE}}}{tag}"

version  = os.environ["VERSION"]
build    = os.environ["BUILD"]
url      = os.environ["DOWNLOAD_URL"]
rel_url  = os.environ.get("RELEASE_URL", "")
min_os   = os.environ["MIN_OS"]
out      = os.environ["OUT"]
pubdate  = os.environ["PUBDATE"]
existing = os.environ.get("EXISTING_APPCAST", "")
dmg      = os.environ["DMG"]

m = re.search(r'edSignature="([^"]*)"', os.environ["SIG_LINE"])
ed_sig = m.group(1) if m else ""
m = re.search(r'length="([^"]*)"', os.environ["SIG_LINE"])
length = m.group(1) if m else str(os.path.getsize(dmg))

# Load the existing feed (to preserve older items) or start a fresh one.
if existing and os.path.exists(existing):
    rss = ET.parse(existing).getroot()
    channel = rss.find("channel")
else:
    rss = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = "Spindle"
    ET.SubElement(channel, "description").text = "Spindle release updates"
    ET.SubElement(channel, "language").text = "en"

# Preserve all existing items except any with this same build (idempotent re-runs).
preserved = [it for it in channel.findall("item")
             if (it.find(sp("version")) is None or it.find(sp("version")).text != build)]

# Build the new item.
item = ET.Element("item")
ET.SubElement(item, "title").text = f"Version {version}"
if rel_url:
    ET.SubElement(item, "link").text = rel_url
ET.SubElement(item, "pubDate").text = pubdate
ET.SubElement(item, sp("version")).text = build
ET.SubElement(item, sp("shortVersionString")).text = version
ET.SubElement(item, sp("minimumSystemVersion")).text = min_os
ET.SubElement(item, "enclosure", {
    "url": url,
    sp("edSignature"): ed_sig,
    "length": length,
    "type": "application/octet-stream",
})

# Rewrite the item list: newest (this build) first, then the rest by build desc.
for it in channel.findall("item"):
    channel.remove(it)
def build_key(it):
    v = it.find(sp("version"))
    try: return int(v.text)
    except (AttributeError, TypeError, ValueError): return -1
ordered = [item] + sorted(preserved, key=build_key, reverse=True)
for it in ordered:
    channel.append(it)

ET.indent(rss, space="  ")
ET.ElementTree(rss).write(out, encoding="UTF-8", xml_declaration=True)
PY
echo "Wrote $OUT"
