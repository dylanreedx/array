#!/usr/bin/env bash
# Paid, opt-in: a Managed lead on the REAL claude or codex CLI (.plans/102).
# Usage: ARRAY_MANAGED_LIVE=1 scripts/check-managed-live.sh [claude|codex]
set -euo pipefail
[[ ${ARRAY_MANAGED_LIVE:-} == 1 ]] || { echo 'Set ARRAY_MANAGED_LIVE=1 to authorize real provider turns.' >&2; exit 2; }
HARNESS=${1:-claude}
[[ "$HARNESS" == claude || "$HARNESS" == codex ]] || { echo 'harness: claude or codex' >&2; exit 2; }
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT_DIR"
LIVE_OUT=${ARRAY_MANAGED_LIVE_OUT:-$HOME/array-scratch/managed-live/run-$HARNESS}
mkdir -p "$LIVE_OUT"
LIVE_OUT=$(cd "$LIVE_OUT" && pwd -P)
export ARRAY_MANAGED_LIVE_HARNESS="$HARNESS"
export ARRAY_MANAGED_LIVE_EVIDENCE="$LIVE_OUT/evidence.json"
export CONTINUUM_APP_SUPPORT="$LIVE_OUT/app-support-boot"
# The fixture's disposable project root is created in the system temp dir.
mkdir -p "$CONTINUUM_APP_SUPPORT"
LIVE_TMUX_ROOT=$(mktemp -d /tmp/array-managed-live-tmux.XXXXXX)
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
if [[ ${ARRAY_MANAGED_LIVE_SKIP_BUILD:-} != 1 ]]; then
  swift build --product Array
  swift build --product array-workspace-mcp
fi
# Managed is pinned ON in a private typed Settings suite inside the check.
set +e
.build/debug/Array --managed-mode-live-check -continuum.terminal.tmux.enabled NO -continuum.terminal.tmux.path '' > "$LIVE_OUT/run.log" 2>&1
STATUS=$?
set -e
cat "$LIVE_OUT/run.log"
printf 'Managed live evidence: %s (exit %s)\n' "$ARRAY_MANAGED_LIVE_EVIDENCE" "$STATUS"
exit "$STATUS"
