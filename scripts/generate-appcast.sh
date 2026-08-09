#!/usr/bin/env bash
set -euo pipefail

# Phase 2 step 6 (docs/38-tickets/95-go-live.md): regenerate the Sparkle appcast
# from the local archive of shipped DMGs and write the copy the site deploys.
#
# releases/ is the source of truth: every shipped Array-<version>.dmg from the
# first Sparkle-capable version on lands there (gitignored — DMGs don't belong
# in the repo; back the directory up). generate_appcast signs each item with the
# private EdDSA key in the login Keychain and writes releases/appcast.xml; the
# site copy then gets each enclosure URL rewritten to that version's
# array-releases tag, because --download-url-prefix is global while our GitHub
# download URLs embed the version tag.

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
RELEASES_DIR="${1:-$ROOT_DIR/releases}"
SITE_APPCAST="$ROOT_DIR/website/public/appcast.xml"
GENERATE_APPCAST="$ROOT_DIR/.build/artifacts/sparkle/Sparkle/bin/generate_appcast"

[[ -x "$GENERATE_APPCAST" ]] || { echo "generate_appcast not found: $GENERATE_APPCAST (run swift build first)" >&2; exit 1; }
[[ -d "$RELEASES_DIR" ]] || { echo "releases dir not found: $RELEASES_DIR" >&2; exit 1; }
ls "$RELEASES_DIR"/Array-*.dmg >/dev/null 2>&1 || { echo "no Array-<version>.dmg archives in $RELEASES_DIR" >&2; exit 1; }

# --maximum-versions 0 keeps every shipped version in the feed (nothing is
# moved to old_updates/); deltas are off until delta files are part of the
# GitHub upload flow.
"$GENERATE_APPCAST" "$RELEASES_DIR" \
  --link "https://arrayapp.dev" \
  --maximum-versions 0 \
  --maximum-deltas 0

/usr/bin/python3 - "$RELEASES_DIR/appcast.xml" "$SITE_APPCAST" <<'PY'
import sys
import xml.etree.ElementTree as ET

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)
src, dst = sys.argv[1], sys.argv[2]
tree = ET.parse(src)
channel = tree.getroot().find("channel")
items = channel.findall("item") if channel is not None else []
if not items:
    raise SystemExit(f"no update items found in {src}")
for item in items:
    enclosure = item.find("enclosure")
    if enclosure is None:
        raise SystemExit("update item without enclosure")
    short = item.findtext(f"{{{SPARKLE}}}shortVersionString") or enclosure.get(f"{{{SPARKLE}}}shortVersionString")
    if not short:
        raise SystemExit("update item without sparkle:shortVersionString")
    enclosure.set("url", f"https://github.com/dylanreedx/array-releases/releases/download/v{short}/Array-{short}.dmg")
    if item.find(f"{{{SPARKLE}}}releaseNotesLink") is None:
        notes = ET.SubElement(item, f"{{{SPARKLE}}}releaseNotesLink")
        notes.text = f"https://github.com/dylanreedx/array-releases/releases/tag/v{short}"
tree.write(dst, encoding="UTF-8", xml_declaration=True)
with open(dst, "a") as handle:
    handle.write("\n")
print(f"wrote {dst} ({len(items)} update item(s))")
PY
