#!/usr/bin/env bash
# The isolated preview for the sidebar polish work: its own bundle, identity,
# store and project root, so it runs beside "Array Dev" and Dylan's Array
# without sharing a single file with either.
#
#   bundle   ~/array-scratch/apps/Array Sidebar.app (remove when the program closes)
#   identity dev.arrayapp.macos.sidebar — never the shared dev id (TCC keys folder
#            grants by bundle id; see make-app-bundle.sh)
#   store    ~/array-scratch-sidebar-support via CONTINUUM_APP_SUPPORT (also keeps
#            the updater, onboarding and CLI updates inert)
#   project  ~/array-scratch-sidebar — outside ~/Documents (no folder-grant modal)
#            and nobody else's root (hazard 10)
#
# Usage: scripts/sidebar-preview.sh [dev-app.sh args, e.g. --env ARRAY_SWARM_GLYPH=chart]
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export DEV_APP_PATH="${DEV_APP_PATH:-$HOME/array-scratch/apps/Array Sidebar.app}"
export DEV_PROJECT_ROOT="${DEV_PROJECT_ROOT:-$HOME/array-scratch-sidebar}"
export DEV_APP_SUPPORT="${DEV_APP_SUPPORT:-$HOME/array-scratch-sidebar-support}"
export DEV_BUNDLE_ID=dev.arrayapp.macos.sidebar
export DEV_BUNDLE_NAME="Array Sidebar"
mkdir -p "$(dirname "$DEV_APP_PATH")"

"$ROOT_DIR/scripts/dev-app.sh" "$@"

# dev-app.sh returns when LaunchServices takes the launch, before the app is up.
sleep 3
if pgrep -f "$DEV_APP_PATH/Contents/MacOS/Array" >/dev/null 2>&1; then
  echo "==> up: $(pgrep -f "$DEV_APP_PATH/Contents/MacOS/Array" | tr '\n' ' ')"
else
  echo "==> NOT RUNNING — the launch did not survive" >&2
  exit 1
fi
