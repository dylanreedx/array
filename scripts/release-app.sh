#!/usr/bin/env bash
set -euo pipefail

# Phase 1 release pipeline (docs/38-tickets/95-go-live.md):
#   release build → Array.app → sign inside-out (hardened runtime) → notarize app
#   → staple app → DMG → sign DMG → notarize DMG → staple DMG → verify.
#
# Runs end-to-end with a Developer ID Application identity + notarytool keychain
# profile. Without them it still produces a signed (ad-hoc) app and DMG for local
# testing: pass --skip-notarize, or omit --identity to ad-hoc sign.

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CONFIGURATION=release
OUTPUT_DIR=""
IDENTITY="${ARRAY_CODESIGN_IDENTITY:-}"
NOTARY_PROFILE="${ARRAY_NOTARY_PROFILE:-}"
SKIP_NOTARIZE=0
SET_VERSION=""
SET_BUILD=""

usage() {
  cat <<'USAGE'
Usage: scripts/release-app.sh [options]

Options:
  --configuration debug|release   SwiftPM configuration (default: release)
  --output-dir <dir>              Artifact directory (default: qa-runs/<stamp>/release)
  --identity <identity>           Developer ID Application identity
                                  (or ARRAY_CODESIGN_IDENTITY; default: ad-hoc "-")
  --notary-profile <name>         notarytool keychain profile
                                  (or ARRAY_NOTARY_PROFILE; required to notarize)
  --skip-notarize                 Stop after signed DMG (no notarization/stapling)
  --set-version <x.y.z>           Stamp CFBundleShortVersionString in the bundle
  --set-build <n>                 Stamp CFBundleVersion in the bundle
  -h, --help                      Show this help

Typical release:
  scripts/release-app.sh \
    --identity "Developer ID Application: Dylan Reed (TEAMID)" \
    --notary-profile array-notary \
    --set-version 0.2.0 --set-build 2
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --configuration) [[ $# -ge 2 ]] || { echo "missing value for $1" >&2; exit 2; }; CONFIGURATION="$2"; shift 2 ;;
    --output-dir)    [[ $# -ge 2 ]] || { echo "missing value for $1" >&2; exit 2; }; OUTPUT_DIR="$2"; shift 2 ;;
    --identity)      [[ $# -ge 2 ]] || { echo "missing value for $1" >&2; exit 2; }; IDENTITY="$2"; shift 2 ;;
    --notary-profile)[[ $# -ge 2 ]] || { echo "missing value for $1" >&2; exit 2; }; NOTARY_PROFILE="$2"; shift 2 ;;
    --skip-notarize) SKIP_NOTARIZE=1; shift ;;
    --set-version)   [[ $# -ge 2 ]] || { echo "missing value for $1" >&2; exit 2; }; SET_VERSION="$2"; shift 2 ;;
    --set-build)     [[ $# -ge 2 ]] || { echo "missing value for $1" >&2; exit 2; }; SET_BUILD="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$CONFIGURATION" in
  debug|release) ;;
  *) echo "--configuration must be debug or release" >&2; exit 2 ;;
esac

cd "$ROOT_DIR"
if [[ -z "$OUTPUT_DIR" ]]; then
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  OUTPUT_DIR="$ROOT_DIR/qa-runs/$stamp/release"
fi
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR=$(cd "$OUTPUT_DIR" && pwd)
APP="$OUTPUT_DIR/Array.app"
LOG="$OUTPUT_DIR/release.log"
: > "$LOG"

log() { printf '%s\n' "$*" | tee -a "$LOG"; }

ADHOC=0
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="-"
  ADHOC=1
  log "WARNING: no signing identity supplied — ad-hoc signing. NOT distributable."
fi
if [[ "$SKIP_NOTARIZE" == 0 && "$ADHOC" == 1 ]]; then
  log "WARNING: ad-hoc signature cannot be notarized — implying --skip-notarize."
  SKIP_NOTARIZE=1
fi
if [[ "$SKIP_NOTARIZE" == 0 && -z "$NOTARY_PROFILE" ]]; then
  echo "notarization requested but no --notary-profile / ARRAY_NOTARY_PROFILE set" >&2
  echo "(create one with: xcrun notarytool store-credentials array-notary --apple-id <id> --team-id <team>)" >&2
  exit 2
fi

log "==> build + assemble bundle ($CONFIGURATION)"
"$ROOT_DIR/scripts/make-app-bundle.sh" --configuration "$CONFIGURATION" --output "$APP" >>"$LOG" 2>&1

PLIST="$APP/Contents/Info.plist"
if [[ -n "$SET_VERSION" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $SET_VERSION" "$PLIST"
fi
if [[ -n "$SET_BUILD" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $SET_BUILD" "$PLIST"
fi
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")
DMG="$OUTPUT_DIR/Array-$VERSION.dmg"
log "version: $VERSION ($BUILD)"

# Sign inside-out: embedded frameworks/dylibs/XPC first (today: Sparkle and its
# updater pieces), then the app itself with hardened runtime. Sparkle's
# Autoupdate is a bare executable, hence the extra -name; its XPC services
# carry sandbox entitlements that must survive re-signing.
SIGN_FLAGS=(--force --options runtime --sign "$IDENTITY")
if [[ "$ADHOC" == 0 ]]; then
  SIGN_FLAGS+=(--timestamp)
fi
log "==> codesign (hardened runtime)"
if [[ -d "$APP/Contents/Frameworks" ]]; then
  while IFS= read -r -d '' nested; do
    log "    signing nested: $nested"
    nested_flags=("${SIGN_FLAGS[@]}")
    if [[ "$nested" == *.xpc ]]; then
      nested_flags+=(--preserve-metadata=entitlements)
    fi
    codesign "${nested_flags[@]}" "$nested" >>"$LOG" 2>&1
  done < <(find "$APP/Contents/Frameworks" -depth \( -name '*.framework' -o -name '*.dylib' -o -name '*.xpc' -o -name '*.app' -o -name 'Autoupdate' \) -print0)
fi
codesign "${SIGN_FLAGS[@]}" "$APP" >>"$LOG" 2>&1
codesign --verify --deep --strict --verbose=2 "$APP" >>"$LOG" 2>&1
log "codesign verify: OK"

if [[ "$SKIP_NOTARIZE" == 0 ]]; then
  log "==> notarize app"
  APP_ZIP="$OUTPUT_DIR/Array-$VERSION-app.zip"
  ditto -c -k --keepParent "$APP" "$APP_ZIP"
  notary_out=$(xcrun notarytool submit "$APP_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1) || true
  printf '%s\n' "$notary_out" >>"$LOG"
  grep -q "status: Accepted" <<<"$notary_out" \
    || { echo "FAIL: app notarization not accepted — see $LOG" >&2; exit 1; }
  xcrun stapler staple "$APP" >>"$LOG" 2>&1
  log "app notarized + stapled"
fi

log "==> build DMG"
STAGING=$(mktemp -d "${TMPDIR:-/tmp}/array-dmg-staging.XXXXXX")
ditto "$APP" "$STAGING/Array.app"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG"
hdiutil create -volname "Array" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >>"$LOG" 2>&1
rm -rf "$STAGING"

if [[ "$ADHOC" == 0 ]]; then
  codesign --force --timestamp --sign "$IDENTITY" "$DMG" >>"$LOG" 2>&1
  log "DMG signed"
fi

if [[ "$SKIP_NOTARIZE" == 0 ]]; then
  log "==> notarize DMG"
  notary_out=$(xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1) || true
  printf '%s\n' "$notary_out" >>"$LOG"
  grep -q "status: Accepted" <<<"$notary_out" \
    || { echo "FAIL: DMG notarization not accepted — see $LOG" >&2; exit 1; }
  xcrun stapler staple "$DMG" >>"$LOG" 2>&1
  log "DMG notarized + stapled"
  log "==> Gatekeeper verification"
  spctl -a -t open --context context:primary-signature -vv "$DMG" >>"$LOG" 2>&1 && log "spctl DMG: OK" || { echo "FAIL: spctl rejects DMG" >&2; exit 1; }
  spctl -a -vv "$APP" >>"$LOG" 2>&1 && log "spctl app: OK" || { echo "FAIL: spctl rejects app" >&2; exit 1; }
else
  log "skipped notarization/stapling — DMG is for LOCAL TESTING ONLY"
fi

log ""
log "Artifacts:"
log "  app: $APP"
log "  dmg: $DMG"
log "  log: $LOG"
