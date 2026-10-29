#!/usr/bin/env bash
set -euo pipefail
[[ ${ARRAY_DEVICE_BROWSER_LIVE:-} == 1 ]] || { echo 'Set ARRAY_DEVICE_BROWSER_LIVE=1 to authorize real provider turns.' >&2; exit 2; }
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT_DIR"
LIVE_OUT=${ARRAY_DEVICE_BROWSER_LIVE_OUT:-$(mktemp -d /tmp/array-device-browser-live.XXXXXX)}
mkdir -p "$LIVE_OUT"
LIVE_OUT=$(cd "$LIVE_OUT" && pwd -P)
export ARRAY_DEVICE_BROWSER_LIVE_OUT="$LIVE_OUT"
export ARRAY_DEVICE_BROWSER_LIVE_EVIDENCE="$LIVE_OUT/evidence.json"
export CONTINUUM_APP_SUPPORT="$LIVE_OUT/app-support"
export CONTINUUM_PROJECT_ROOT="$LIVE_OUT/project"
mkdir -p "$CONTINUUM_APP_SUPPORT" "$CONTINUUM_PROJECT_ROOT"
LIVE_TMUX_ROOT=$(mktemp -d /tmp/array-device-browser-tmux.XXXXXX)
export TMUX_TMPDIR="$LIVE_TMUX_ROOT"
unset TMUX TMUX_PANE
LIVE_TMUX_VERIFIED=0
cleanup() {
  if [[ "$LIVE_TMUX_VERIFIED" == 1 ]]; then tmux kill-server 2>/dev/null || true; fi
  rm -rf "$LIVE_TMUX_ROOT"
}
trap cleanup EXIT
if command -v tmux >/dev/null; then
  LIVE_SOCKET=$(tmux start-server \; display-message -p '#{socket_path}')
  LIVE_TMUX_CANONICAL=$(cd "$LIVE_TMUX_ROOT" && pwd -P)
  [[ "$LIVE_SOCKET" == "$LIVE_TMUX_CANONICAL/"* ]] || { echo 'Refusing nonisolated tmux socket' >&2; exit 1; }
  LIVE_TMUX_VERIFIED=1
fi
swift build --product Array
swift build --product array-workspace-mcp
python3 Tools/DeviceBrowserLive/run.py 2>&1 | tee "$LIVE_OUT/run.log"
printf 'Device/browser live evidence: %s\n' "$ARRAY_DEVICE_BROWSER_LIVE_EVIDENCE"
