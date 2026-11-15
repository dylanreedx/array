#!/usr/bin/env bash
set -euo pipefail

# Ship a stable release from a reviewed, green integration head in minutes.
#
#   scripts/ship-release.sh --version X.Y.Z --notes FILE [--summary TEXT]
#   scripts/ship-release.sh --version X.Y.Z --publish      # Dylan's go only
#
# Prepare (the default) compiles nothing and runs no full matrix. It reuses the
# gate nightly-gate.sh already ran for this commit (or for an ancestor whose
# later commits touch only release paths) and the optimized candidate the gate
# built, runs the awake group at that commit if it has not run, then signs,
# notarizes, audits the bundle, appends one appcast item and one ledger row and
# commits them locally. It stops there and prints the publish command.
#
# --publish uploads both DMGs, fast-forwards array/integration and main, and
# returns only when arrayapp.dev serves the new build and both downloads answer.

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT_DIR"
VERSION="" NOTES="" SUMMARY="" PUBLISH=0
usage() { echo "Usage: ship-release.sh --version X.Y.Z (--notes FILE [--summary TEXT] | --publish)" >&2; exit 2; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) [[ $# -ge 2 ]] || usage; VERSION=$2; shift 2 ;;
    --notes) [[ $# -ge 2 ]] || usage; NOTES=$2; shift 2 ;;
    --summary) [[ $# -ge 2 ]] || usage; SUMMARY=$2; shift 2 ;;
    --publish) PUBLISH=1; shift ;;
    *) usage ;;
  esac
done
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || usage

RELEASES_REPO=dylanreedx/array-releases
GH=${ARRAY_SHIP_GH:-gh}
STATE_DIR="$ROOT_DIR/qa-runs/ship-$VERSION"
STATE="$STATE_DIR/state.json"
STARTED=$SECONDS
step() { printf '\n==> [%dm%02ds] %s\n' $(((SECONDS - STARTED) / 60)) $(((SECONDS - STARTED) % 60)) "$*"; }
die() { printf 'ship-release: %s\n' "$*" >&2; exit 1; }
state() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$STATE" "$1"; }

[[ -z "$(git status --porcelain --untracked-files=no)" ]] || die "the working tree has uncommitted changes"
git fetch --quiet origin

if [[ "$PUBLISH" == 1 ]]; then
  [[ -f "$STATE" ]] || die "nothing prepared for $VERSION; run without --publish first"
  BUILD=$(state build)
  [[ "$(git rev-parse HEAD)" == "$(state commit)" ]] || die "HEAD is not the prepared release commit $(state commit)"
  git merge-base --is-ancestor origin/array/integration HEAD || die "origin/array/integration moved; prepare again"
  git merge-base --is-ancestor origin/main HEAD ||
    die "origin/main has commits HEAD lacks; merge origin/main, then prepare again (never force)"
  step "GitHub release v$VERSION (both assets)"
  ASSETS=("$STATE_DIR/release/Array.dmg" "$STATE_DIR/release/Array-$VERSION.dmg")
  if "$GH" release view "v$VERSION" --repo "$RELEASES_REPO" >/dev/null 2>&1; then
    # A rerun after a partial upload: replace both assets before anything is pushed.
    echo "v$VERSION already exists; uploading both assets again."
    "$GH" release upload "v$VERSION" --repo "$RELEASES_REPO" --clobber "${ASSETS[@]}"
  else
    "$GH" release create "v$VERSION" --repo "$RELEASES_REPO" --title "Array $VERSION" \
      --notes-file "$STATE_DIR/notes.md" "${ASSETS[@]}"
  fi
  UPLOADED=$("$GH" release view "v$VERSION" --repo "$RELEASES_REPO" --json assets --jq '.assets[].name')
  for asset in Array.dmg "Array-$VERSION.dmg"; do
    grep -qxF "$asset" <<<"$UPLOADED" || die "v$VERSION lacks $asset after upload; nothing pushed"
  done
  step "Fast-forward array/integration and main"
  git push origin HEAD:array/integration
  git push origin HEAD:main
  step "Wait for arrayapp.dev to serve build $BUILD and both downloads"
  wait_args=(--build "$BUILD" --version "$VERSION" --timeout "${ARRAY_SHIP_WAIT_SECONDS:-900}")
  [[ -z "${ARRAY_SHIP_FEED_URL:-}" ]] || wait_args+=(--feed-url "$ARRAY_SHIP_FEED_URL")
  [[ -z "${ARRAY_SHIP_DOWNLOAD_BASE:-}" ]] || wait_args+=(--download-base "$ARRAY_SHIP_DOWNLOAD_BASE")
  [[ -z "${ARRAY_SHIP_WAIT_INTERVAL:-}" ]] || wait_args+=(--interval "$ARRAY_SHIP_WAIT_INTERVAL")
  python3 scripts/wait-live-release.py "${wait_args[@]}"
  step "Array $VERSION (build $BUILD) is live"
  exit 0
fi

[[ -s "$NOTES" ]] || die "--notes must name a non-empty release-notes file (friend-readable)"
[[ ! -e "$STATE" ]] || die "$STATE exists; this version is already prepared"
HEAD_SHA=$(git rev-parse HEAD)
[[ "$HEAD_SHA" == "$(git rev-parse origin/array/integration)" ]] ||
  die "ship from origin/array/integration; HEAD is $(git rev-parse --short HEAD)"

step "Find the gate and release candidate covering $(git rev-parse --short HEAD)"
mkdir -p "$STATE_DIR"
bash scripts/nightly-gate.sh --ship-base "$HEAD_SHA" > "$STATE_DIR/gate.json"
gate() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2], {}, d))' "$STATE_DIR/gate.json" "$1"; }
GATE=$(gate gate)
CANDIDATE=$(gate candidate)
echo "gate $GATE: $(gate "summary['passed']") legs green; candidate $CANDIDATE"

if [[ "$(gate "bool(awake and awake.get('green'))")" != True ]]; then
  step "Awake group at $GATE (display/focus legs the unattended gate skips)"
  bash scripts/nightly-gate.sh --awake "$GATE" > "$STATE_DIR/awake.json" ||
    die "awake group did not pass at $GATE: $(head -c 2000 "$STATE_DIR/awake.json")"
  python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])).get("green") is True else 1)' \
    "$STATE_DIR/awake.json" 2>/dev/null || die "awake group reported no green result at $GATE"
fi

step "Allocate the build number"
BUILD=$(python3 - <<'PY'
import pathlib, re, xml.etree.ElementTree as E
ns = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
nums = [int(n) for n in re.findall(r'^\|[^|]+\|\s*(\d+)\s*\|', pathlib.Path('docs/VERSIONING.md').read_text(), re.M)]
nums += [int(i.findtext(ns + 'version')) for i in E.parse('website/public/appcast.xml').findall('./channel/item')
         if (i.findtext(ns + 'version') or '').isdigit()]
print(max(nums) + 1)
PY
)
if grep -qE "^\| *${VERSION//./\\.} *\|" docs/VERSIONING.md; then die "$VERSION is already in the ledger"; fi
if "$GH" release view "v$VERSION" --repo "$RELEASES_REPO" >/dev/null 2>&1; then die "v$VERSION is already published"; fi
echo "Array $VERSION = build $BUILD"

step "Sign, notarize and staple the gate's candidate (no compile)"
scripts/release-app.sh --bundle "$CANDIDATE" --output-dir "$STATE_DIR/release" \
  --identity "${ARRAY_CODESIGN_IDENTITY:-Developer ID Application: Dylan Reed (46TTB6J9DZ)}" \
  --notary-profile "${ARRAY_NOTARY_PROFILE:-array-notary}" --set-version "$VERSION" --set-build "$BUILD"
DMG="$STATE_DIR/release/Array-$VERSION.dmg"
cp "$DMG" "$STATE_DIR/release/Array.dmg"

step "Production bundle audit"
scripts/check-app-bundle.sh --configuration release --channel prod --bundle "$STATE_DIR/release/Array.app"

step "Archive the DMG, append one appcast item and one ledger row"
MAIN_ROOT=$(cd "$(git rev-parse --git-common-dir)/.." && pwd)
mkdir -p "$MAIN_ROOT/releases"
cp "$DMG" "$MAIN_ROOT/releases/"
SIGN_UPDATE="$ROOT_DIR/.build/artifacts/sparkle/Sparkle/bin/sign_update"
if [[ -z "${SPARKLE_SIGN_UPDATE:-}" && ! -x "$SIGN_UPDATE" ]]; then
  # A release bench need not have built; the gate's checkout has Sparkle's tools.
  export SPARKLE_SIGN_UPDATE="${ARRAY_NIGHTLY_BASE:-$HOME/array-scratch/nightly-gate}/checkout/.build/artifacts/sparkle/Sparkle/bin/sign_update"
fi
scripts/generate-appcast.sh --dmg "$DMG" --version "$VERSION" --build "$BUILD"
SHA=$(shasum -a 256 "$DMG" | cut -d' ' -f1)
BYTES=$(stat -f %z "$DMG")
HEADLINE=${SUMMARY:-$(head -n 1 "$NOTES")}
HEADLINE=${HEADLINE//|/\\|}
GATE_LINE=$(python3 - "$STATE_DIR/gate.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); s = d['summary']
parts = [f"{s['passed']} legs green"]
if s.get('known'): parts.append('listed known failures ' + ', '.join(s['known']))
if s.get('retry_passed'): parts.append('passed on serial retry ' + ', '.join(s['retry_passed']))
print(f"Gate {d['gate'][:12]}: " + '; '.join(parts) + '; awake group green.'
      + (f" Later commits touch release paths only ({len(d['inert_changes'])} file(s))." if d['inert_changes'] else ''))
PY
)
printf '| %s | %s | %s | `v%s` | %s Source `%s`. %s Optimized candidate built by the gate; app and DMG Developer ID signed, notarized, stapled; production bundle audit passed. Both assets SHA-256 `%s`, %s bytes. Feed appends one signed item; older items untouched. |\n' \
  "$VERSION" "$BUILD" "$(date +%F)" "$VERSION" "$HEADLINE" "${GATE:0:8}" "$GATE_LINE" "$SHA" "$BYTES" >> docs/VERSIONING.md
git add website/public/appcast.xml docs/VERSIONING.md
git commit --quiet -m "chore(release): ship Array $VERSION (build $BUILD)"
cp "$NOTES" "$STATE_DIR/notes.md"
python3 - "$STATE" "$VERSION" "$BUILD" "$GATE" "$(git rev-parse HEAD)" "$SHA" <<'PY'
import json, sys
path, version, build, gate, commit, sha = sys.argv[1:]
json.dump(dict(version=version, build=int(build), gate=gate, commit=commit, sha256=sha), open(path, 'w'), indent=2)
PY

step "Prepared Array $VERSION (build $BUILD) at $(git rev-parse --short HEAD). Nothing uploaded or pushed."
cat <<EOF
Review: git show --stat HEAD; $STATE_DIR/notes.md
Publish (only on Dylan's go):
  scripts/ship-release.sh --version $VERSION --publish
EOF
