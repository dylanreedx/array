#!/bin/bash
# Rebuild and relaunch the dev app. ~15s, not ~6min.
#
# WHY DEBUG. The release configuration builds with whole-module optimization,
# which is what makes a bundle take minutes: every edit recompiles the world.
# Debug is incremental — touching one file rebuilds that file. Release mode is
# for shipping (scripts/release-app.sh); it buys nothing for looking at a change.
#
# The bundle is DEV channel (`dev.arrayapp.macos.dev`, "Array Dev" store,
# updater inert) because that is make-app-bundle.sh's default. It cannot touch
# the prod app's state. It CAN touch a project's own state — `<project>/.array/`
# is per-project-root, not per-channel — so keep the dev app on a project the
# prod app never opens.
#
# Usage:
#   scripts/dev-app.sh              # rebuild + relaunch
#   scripts/dev-app.sh --no-launch  # rebuild only
#   DEV_APP_PATH=... scripts/dev-app.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${DEV_APP_PATH:-$HOME/Desktop/Array Dev.app}"
LAUNCH=1
[[ "${1:-}" == "--no-launch" ]] && LAUNCH=0

started=$(date +%s)

# Quit first: swapping the bundle under a running instance leaves it running the
# old binary from an inode that no longer has a path, which looks exactly like
# "my change did nothing".
if pgrep -f "$APP_PATH/Contents/MacOS/Array" >/dev/null 2>&1; then
  echo "==> quitting the running dev app"
  pkill -f "$APP_PATH/Contents/MacOS/Array" || true
  # Give it a moment to release its project lock (.array/lock is an exclusive
  # flock; relaunching into a held lock fails to open the project).
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -f "$APP_PATH/Contents/MacOS/Array" >/dev/null 2>&1 || break
    sleep 0.3
  done
fi

echo "==> building (debug, incremental)"
"$ROOT_DIR/scripts/make-app-bundle.sh" --configuration debug --output "$APP_PATH"

if [[ $LAUNCH -eq 1 ]]; then
  echo "==> launching $APP_PATH"
  open "$APP_PATH"
fi

echo "==> done in $(( $(date +%s) - started ))s"
