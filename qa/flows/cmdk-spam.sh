#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=qa/flows/lib.sh
source "$SCRIPT_DIR/lib.sh"

require_external_drivers
begin_flow "cmdk-spam"
diagnostic_snapshot "$QA_RUN_DIR/diagnostics-before.txt"
launch_continuum

# Marker for structural check: CONTINUUM_QA_FLOW=palette-open-close uses cliclick.
capture_step "initial" "app launched before external Cmd-K spam"

iterations="${CONTINUUM_FLOW_ITERATIONS:-20}"
for _ in $(seq 1 "$iterations"); do
  cmd_k
  sleep 0.04
  escape_key
  sleep 0.04
done

cmd_k
sleep 0.2
capture_step "cmdk-spam-final" "opened and closed Cmd-K ${iterations} times"
assert_flow "app-window-after-cmdk-spam" "app window remains queryable after ${iterations} Cmd-K iterations" assert_app_window_present
diagnostic_snapshot "$QA_RUN_DIR/diagnostics-after.txt"
assert_flow "diagnosticreports-clean" "no new DiagnosticReports entries after Cmd-K spam" assert_no_new_diagnostics "$QA_RUN_DIR/diagnostics-before.txt" "$QA_RUN_DIR/diagnostics-after.txt" "$QA_RUN_DIR/diagnostics-new.txt"
escape_key

finish_flow pass
