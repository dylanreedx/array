#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CONFIGURATION=release
OUTPUT=""

usage() {
  cat <<'USAGE'
Usage: scripts/make-app-bundle.sh [--configuration debug|release] --output <path>

Builds the SwiftPM continuum-revived executable and assembles a macOS .app bundle.
This bundle is unsigned/unprovisioned CloudKit-wise; use
scripts/provisioned-cloudkit-app.sh for real iCloud/CloudKit proof.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --configuration)
      [[ $# -ge 2 ]] || { echo "missing value for --configuration" >&2; exit 2; }
      CONFIGURATION="$2"
      shift 2
      ;;
    --output)
      [[ $# -ge 2 ]] || { echo "missing value for --output" >&2; exit 2; }
      OUTPUT="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "$CONFIGURATION" in
  debug|release) ;;
  *) echo "--configuration must be debug or release" >&2; exit 2 ;;
esac

[[ -n "$OUTPUT" ]] || { echo "--output <path> is required" >&2; usage >&2; exit 2; }

cd "$ROOT_DIR"
swift build -c "$CONFIGURATION" --product continuum-revived

BUILD_DIR="$ROOT_DIR/.build/$CONFIGURATION"
EXECUTABLE="$BUILD_DIR/continuum-revived"
PLIST_SOURCE="$ROOT_DIR/Packaging/Info.plist"
ICON_SOURCE="$ROOT_DIR/Packaging/AppIcon.icns"

[[ -x "$EXECUTABLE" ]] || { echo "built executable not found: $EXECUTABLE" >&2; exit 1; }
[[ -f "$PLIST_SOURCE" ]] || { echo "Info.plist source not found: $PLIST_SOURCE" >&2; exit 1; }
[[ -f "$ICON_SOURCE" ]] || { echo "icon source not found: $ICON_SOURCE" >&2; exit 1; }

rm -rf "$OUTPUT"
mkdir -p "$OUTPUT/Contents/MacOS" "$OUTPUT/Contents/Resources"
cp "$EXECUTABLE" "$OUTPUT/Contents/MacOS/continuum-revived"
chmod 0755 "$OUTPUT/Contents/MacOS/continuum-revived"
cp "$PLIST_SOURCE" "$OUTPUT/Contents/Info.plist"
cp "$ICON_SOURCE" "$OUTPUT/Contents/Resources/AppIcon.icns"

# GhosttyKit is currently linked statically by SwiftPM. Do not copy the full
# xcframework unless a future otool -L check shows a runtime Ghostty dependency.
plutil -lint "$OUTPUT/Contents/Info.plist" >/dev/null

printf 'Assembled %s\n' "$OUTPUT"
printf 'CloudKit proof: no (unsigned/unprovisioned). Use scripts/provisioned-cloudkit-app.sh with a matching identity/profile.\n'
