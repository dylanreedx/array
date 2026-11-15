#!/usr/bin/env bash
set -euo pipefail

PHASED_ROLLOUT_INTERVAL=3600

# Phase 2 step 6 (docs/38-tickets/95-go-live.md): add ONE new stable release to
# the Sparkle appcast the site deploys.
#
# Usage: generate-appcast.sh --dmg releases/Array-X.Y.Z.dmg --version X.Y.Z --build N [--feed PATH]
#
# This used to regenerate the whole feed from releases/ with generate_appcast.
# That dropped the 0.2.0 item (its DMG was never archived), rewrote old pubDates
# from DMG mtimes, and re-serialized every item, so each release needed a hand
# repair. Now append-appcast.py signs the one DMG with sign_update (private
# EdDSA key in the login Keychain) and splices its item above the newest one;
# every existing byte of the feed is left as it was. The new item gets a
# one-hour phased rollout; older items keep whatever they were published with.

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FEED="$SCRIPT_DIR/../website/public/appcast.xml"
DMG= VERSION= BUILD=
usage() { echo "Usage: generate-appcast.sh --dmg PATH --version X.Y.Z --build N [--feed PATH]" >&2; exit 2; }
while [[ $# -gt 0 ]]; do
  [[ $# -ge 2 ]] || usage
  case "$1" in
    --dmg) DMG="$2" ;;
    --version) VERSION="$2" ;;
    --build) BUILD="$2" ;;
    --feed) FEED="$2" ;;
    *) usage ;;
  esac
  shift 2
done
[[ -n "$DMG" && -n "$VERSION" && -n "$BUILD" ]] || usage

/usr/bin/python3 "$SCRIPT_DIR/append-appcast.py" --feed "$FEED" --dmg "$DMG" \
  --version "$VERSION" --build "$BUILD" --rollout-seconds "$PHASED_ROLLOUT_INTERVAL"
