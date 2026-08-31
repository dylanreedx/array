#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=qa/flows/lib.sh
source "$ROOT/qa/flows/lib.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
allowed="$tmp/qa-runs/run/state/gui"; mkdir -p "$allowed/project" "$tmp/victim"
printf 'DO_NOT_MOVE\n' > "$tmp/victim/sentinel"
validate_isolated_path project "$allowed/project" "$allowed" >/dev/null
if validate_isolated_path app-support "$tmp/victim" "$allowed" >/dev/null 2>&1; then exit 1; fi
[[ -f "$tmp/victim/sentinel" ]]
stale="$tmp/stale.json"; printf '{}\n' > "$stale"
QA_FLOW_NAME=test; QA_STARTED_AT=x; QA_RUN_DIR="$tmp"; QA_MANIFEST_EVENTS="$tmp/events"; : > "$QA_MANIFEST_EVENTS"
QA_LAUNCHED_AT_EPOCH=$(( $(date +%s) + 60 ))
if wait_for_named_readiness stale "$stale" 1; then exit 1; fi
# A cliclick shim that returns success without input leaves geometry unchanged;
# the same predicate used by the live flow must reject it.
cliclick() { return 0; }
cliclick c:10,10
if assert_pointer_drag_delta 10 10 10 10 16 6; then exit 1; fi
echo "Wave0 GUI adversarial checks passed"
