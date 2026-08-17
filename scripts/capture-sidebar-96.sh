#!/usr/bin/env bash
set -euo pipefail

# Program 96 / P0.2 — assemble gate S0's artifact.
#
# Builds a program-specific dev bundle, launches it once per sidebar width to
# capture the LIVE window, runs the offscreen leg, and merges everything into one
# manifest carrying the §3.3 provenance a visual review has to be traceable to.
#
# Not a matrix leg: the live half needs a WindowServer and Screen Recording
# permission. Run it deliberately, read the images, then present them.
#
# Four things here are deliberate and were each learned the hard way:
#   * `open --env`, never the executable directly — a direct launch makes the app a
#     child of this shell's process group and it dies when the shell is torn down,
#     which is exactly what happens when an agent runs a script.
#   * a program-specific DEV_APP_PATH/DEV_PROJECT_ROOT, so this never swaps the
#     shared preview bundle out from under the canvas-perf stream and never shares
#     a project root (AGENTS.md hazard 10).
#   * a sentinel file, because an `open`-launched bundle has no usable stdout.
#   * no osascript keystrokes. A stray one once typed a prompt into an unrelated
#     tmux Claude session.

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

APP_PATH="${DEV_APP_PATH:-$HOME/Desktop/Array Dev 96.app}"
PROJECT_ROOT="${DEV_PROJECT_ROOT:-$HOME/array-scratch-96}"
WIDTHS="${SIDEBAR_96_WIDTHS:-220 280 360}"
TIMESTAMP="$(date -u +%Y-%m-%dT%H%M%SZ)"
RUN_DIR="$REPO_ROOT/qa-runs/$TIMESTAMP/sidebar-96"
mkdir -p "$RUN_DIR"

case "$PROJECT_ROOT" in
  */Documents/personal*)
    echo "refusing to run against Dylan's workspace root: $PROJECT_ROOT" >&2
    exit 2
    ;;
esac
mkdir -p "$PROJECT_ROOT"

COMMIT="$(git rev-parse HEAD)"
# Tracked and untracked dirt separately: the first changes what was built, the
# second usually belongs to another stream.
DIRTY_TRACKED="$(git status --porcelain | grep -v '^??' | sed 's/^...//' || true)"
DIRTY_UNTRACKED="$(git status --porcelain | grep '^??' | sed 's/^...//' || true)"

echo "[sidebar-96] commit $COMMIT"
echo "[sidebar-96] building $APP_PATH"
DEV_APP_PATH="$APP_PATH" DEV_PROJECT_ROOT="$PROJECT_ROOT" \
  scripts/dev-app.sh --no-launch >/dev/null

BINARY="$APP_PATH/Contents/MacOS/Array"
BUNDLE_SHA="$(shasum -a 256 "$BINARY" | cut -d' ' -f1)"
BUNDLE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
  "$APP_PATH/Contents/Info.plist" 2>/dev/null || echo unknown)"
echo "[sidebar-96] binary sha256 $BUNDLE_SHA (build $BUNDLE_VERSION)"

for WIDTH in $WIDTHS; do
  CAPTURE_DIR="$RUN_DIR/live-w$WIDTH"
  SUPPORT_DIR="$RUN_DIR/app-support-w$WIDTH"
  SENTINEL="$RUN_DIR/sentinel-w$WIDTH.txt"
  mkdir -p "$CAPTURE_DIR" "$SUPPORT_DIR"

  echo "[sidebar-96] launching at ${WIDTH}pt"
  # Single-dash keys are the NSArgumentDomain, the highest-priority defaults
  # domain, so the width applies without persisting into any real domain. They do
  # not collide with the `--*-check` cascade.
  open -n "$APP_PATH" \
    --env "CONTINUUM_PROJECT_ROOT=$PROJECT_ROOT" \
    --env "CONTINUUM_APP_SUPPORT=$SUPPORT_DIR" \
    --env "CONTINUUM_QA_CAPTURE=$CAPTURE_DIR" \
    --args \
    --sidebar-live-capture-check \
    --launch-probe-sentinel "$SENTINEL" \
    -continuum.workspaceSidebar.width "$WIDTH" \
    -continuum.workspaceSidebar.visible YES \
    -continuum.onboarding.shown YES \
    -continuum.terminal.tmux.enabled NO

  # Wait for the check to write its own manifest rather than guessing at a sleep.
  for _ in $(seq 1 60); do
    [ -f "$CAPTURE_DIR/manifest.json" ] && break
    sleep 1
  done
  if [ ! -f "$CAPTURE_DIR/manifest.json" ]; then
    echo "[sidebar-96] WARN: no manifest at ${WIDTH}pt — the app may not have reached" >&2
    echo "[sidebar-96]       the check, or Screen Recording permission is missing." >&2
  else
    echo "[sidebar-96] ${WIDTH}pt: $(/usr/bin/python3 -c \
      'import json,sys;d=json.load(open(sys.argv[1]));print(d["verdict"], d["rowsRendered"], "rows")' \
      "$CAPTURE_DIR/manifest.json")"
  fi
done

echo "[sidebar-96] offscreen set"
CONTINUUM_QA_CAPTURE="$RUN_DIR/offscreen" .build/debug/Array --sidebar-screenshot-check

# Merge: one manifest per run, with the provenance the individual legs cannot know
# (the git state and the bundle they were launched from).
COMMIT="$COMMIT" BUNDLE_SHA="$BUNDLE_SHA" BUNDLE_VERSION="$BUNDLE_VERSION" \
APP_PATH="$APP_PATH" PROJECT_ROOT="$PROJECT_ROOT" RUN_DIR="$RUN_DIR" \
DIRTY_TRACKED="$DIRTY_TRACKED" DIRTY_UNTRACKED="$DIRTY_UNTRACKED" \
/usr/bin/python3 - <<'PY'
import json, os, pathlib

run = pathlib.Path(os.environ["RUN_DIR"])
merged = {
    "check": "sidebar-96-s0-artifact",
    "verdict": "PASS",
    "program": "96-P0.2",
    "commit": os.environ["COMMIT"],
    "dirtyTracked": [p for p in os.environ["DIRTY_TRACKED"].splitlines() if p],
    "dirtyUntracked": [p for p in os.environ["DIRTY_UNTRACKED"].splitlines() if p],
    "bundlePath": os.environ["APP_PATH"],
    "bundleSHA256": os.environ["BUNDLE_SHA"],
    "bundleVersion": os.environ["BUNDLE_VERSION"],
    "buildChannel": "dev",
    "scratchProjectRoot": os.environ["PROJECT_ROOT"],
    "legs": [],
}
for manifest in sorted(run.rglob("manifest.json")):
    if manifest.parent == run:
        continue
    with manifest.open() as handle:
        payload = json.load(handle)
    merged["legs"].append({
        "path": str(manifest.relative_to(run)),
        "check": payload.get("check"),
        "verdict": payload.get("verdict"),
        "entries": len(payload.get("entries", payload.get("captures", []))),
    })
if any(leg["verdict"] != "PASS" for leg in merged["legs"]) or not merged["legs"]:
    merged["verdict"] = "FAIL"
(run / "manifest.json").write_text(json.dumps(merged, indent=2, sort_keys=True))

lines = ["# Gate S0 artifact", "",
         f"Commit `{merged['commit']}`  ",
         f"Bundle `{merged['bundlePath']}`  ",
         f"Binary SHA-256 `{merged['bundleSHA256']}` (build {merged['bundleVersion']})  ",
         f"Scratch root `{merged['scratchProjectRoot']}`  ",
         f"Dirty tracked: {merged['dirtyTracked'] or 'none'}  ",
         f"Verdict **{merged['verdict']}**", "", "## Legs", "",
         "| leg | check | verdict | images |", "|---|---|---|---|"]
for leg in merged["legs"]:
    lines.append(f"| `{leg['path']}` | {leg['check']} | {leg['verdict']} | {leg['entries']} |")
(run / "index.md").write_text("\n".join(lines) + "\n")
print(f"[sidebar-96] merged manifest: {run / 'manifest.json'}")
print(f"[sidebar-96] index: {run / 'index.md'}")
PY
