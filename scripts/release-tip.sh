#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DRY=0
if [[ "${1:-}" == --dry-run ]]; then DRY=1; shift; fi
[[ $# == 2 ]] || { echo 'Usage: release-tip.sh [--dry-run] <built-notarized.app> <source-commit>'; exit 2; }
APP="$1"
COMMIT=$(git -C "$ROOT_DIR" rev-parse --verify "$2^{commit}")
PLIST="$APP/Contents/Info.plist"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")
[[ "$BUILD" =~ ^[0-9]+$ ]] || exit 2
[[ "$VERSION" == *"tip.${COMMIT:0:12}" ]] || { echo "Version must end in tip.${COMMIT:0:12} (stamp before signing)" >&2; exit 2; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")" == dev.arrayapp.macos ]] || exit 2
# Shared +1 sequence across BOTH channels, validated against ledger and feed.
python3 - "$ROOT_DIR" "$BUILD" <<'PY'
import pathlib,re,sys,xml.etree.ElementTree as E
root=pathlib.Path(sys.argv[1]); n=int(sys.argv[2]); ns='{http://www.andymatuschak.org/xml-namespaces/sparkle}'
nums=[int(x) for x in re.findall(r'^\|[^|]+\|\s*(\d+)\s*\|', (root/'docs/VERSIONING.md').read_text(),re.M)]
for item in E.parse(root/'website/public/appcast.xml').findall('./channel/item'):
 v=item.findtext(ns+'version') or item.find('enclosure').get(ns+'version')
 if v and v.isdigit(): nums.append(int(v))
if n != max(nums)+1: raise SystemExit(f'Expected next global build {max(nums)+1}, got {n}')
PY
OUT="$ROOT_DIR/releases/tip-$BUILD"
DMG="$OUT/Array-$VERSION.dmg"
FEED="$ROOT_DIR/website/public/appcast.xml"
TAG="v$VERSION"
printf 'Prepare DMG %q from %q; sign with Sparkle Keychain key; append tip build %s to %q (existing items untouched)\n' "$DMG" "$APP" "$BUILD" "$FEED"
printf 'Append ledger: | %s | %s | %s | `%s` | Tip %s |\n' "$VERSION" "$BUILD" "$(date -u +%F)" "$TAG" "$COMMIT"
printf 'gh release create %q --repo dylanreedx/array-releases --prerelease --title %q --notes %q %q %q\n' "$TAG" "Array $VERSION" "Tip $COMMIT" "$DMG" "$OUT/Array.dmg"
printf 'git add website/public/appcast.xml docs/VERSIONING.md\ngit commit -m %q\ngit push origin HEAD:array/integration\n' "chore(release): publish tip $VERSION (build $BUILD)"
printf 'After approval, fast-forward remote main: git push origin HEAD:main\n'
[[ "$DRY" == 0 ]] || exit 0
codesign --verify --deep --strict "$APP"
xcrun stapler validate "$APP"
mkdir -p "$OUT/staging"
ditto "$APP" "$OUT/staging/Array.app"
ln -s /Applications "$OUT/staging/Applications"
hdiutil create -volname Array -srcfolder "$OUT/staging" -ov -format UDZO "$DMG"
cp "$DMG" "$OUT/Array.dmg"
python3 "$ROOT_DIR/scripts/append-appcast.py" --feed "$FEED" --dmg "$DMG" --version "$VERSION" --build "$BUILD" --channel tip
python3 - "$VERSION" "$BUILD" "$ROOT_DIR/docs/VERSIONING.md" "$COMMIT" <<'PY'
import sys,datetime
version,build,ledger,commit=sys.argv[1:]
with open(ledger,'a') as f:f.write(f'| {version} | {build} | {datetime.date.today()} | `v{version}` | Tip {commit} |\n')
PY
printf 'Local artifacts and feed prepared. STOP: no upload, commit, or push executed. Review and run the commands printed above after approval.\n'
