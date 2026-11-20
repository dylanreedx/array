#!/usr/bin/env bash
# Paid, opt-in: one usage run on the REAL claude CLI through Array's real runner,
# in an isolated CONTINUUM_APP_SUPPORT and a throwaway project (never Dylan's store).
#   ARRAY_MANAGED_LIVE=1 scripts/helper-usage-live.sh <helpers3|single|lead> [task-index] [label]
# Run from the worktree whose .build/debug/Array should be measured. Evidence:
# $ARRAY_USAGE_OUT/<label>/evidence.json (session ids), read by helper-usage-bench.py.
set -euo pipefail
[[ ${ARRAY_MANAGED_LIVE:-} == 1 ]] || { echo 'Set ARRAY_MANAGED_LIVE=1 to authorize real provider turns.' >&2; exit 2; }
MODE=${1:?mode: helpers3|single|lead}; TASK=${2:-0}; LABEL=${3:-$MODE-$TASK-$(date +%H%M%S)}
OUT=${ARRAY_USAGE_OUT:-$HOME/array-scratch/helper-usage/runs}/$LABEL
mkdir -p "$OUT/app-support-boot"; OUT=$(cd "$OUT" && pwd -P)
export ARRAY_MANAGED_LIVE_HARNESS=claude ARRAY_MANAGED_LIVE_EVIDENCE="$OUT/evidence.json"
export CONTINUUM_APP_SUPPORT="$OUT/app-support-boot"
export ARRAY_USAGE_MODE=$MODE ARRAY_USAGE_TASK=$TASK ARRAY_USAGE_TASKS_FILE=${ARRAY_USAGE_TASKS_FILE:-$HOME/array-scratch/helper-usage/tasks.json}
LIVE_TMUX_ROOT=$(mktemp -d /tmp/array-usage-live-tmux.XXXXXX)
export TMUX_TMPDIR="$LIVE_TMUX_ROOT"; unset TMUX TMUX_PANE ARRAY_AGENT_ID
trap 'rm -rf "$LIVE_TMUX_ROOT"' EXIT
set +e
.build/debug/Array --managed-mode-live-check -continuum.terminal.tmux.enabled NO -continuum.terminal.tmux.path '' > "$OUT/run.log" 2>&1 < /dev/null
STATUS=$?
set -e
tail -5 "$OUT/run.log"; echo "usage evidence: $OUT/evidence.json (exit $STATUS)"; exit "$STATUS"
