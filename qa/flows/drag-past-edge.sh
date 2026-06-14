#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=qa/flows/lib.sh
source "$SCRIPT_DIR/lib.sh"

require_external_drivers
begin_flow "drag-past-edge"
diagnostic_snapshot "$QA_RUN_DIR/diagnostics-before.txt"
launch_continuum

# Marker for structural check: CONTINUUM_QA_FLOW=canvas-drag-resize uses cliclick drag.
capture_step "before-drag" "app launched before external drag"
click_center_of_window
sleep 0.1
drag_window_center_by -900 -700
sleep 0.3
capture_step "after-drag-past-edge" "drag moved tile far past the visible top-left edge"
assert_flow "app-window-after-drag" "app window remains queryable after drag beyond the visible edge" assert_app_window_present
diagnostic_snapshot "$QA_RUN_DIR/diagnostics-after.txt"
assert_flow "diagnosticreports-clean" "no new DiagnosticReports entries after drag" assert_no_new_diagnostics "$QA_RUN_DIR/diagnostics-before.txt" "$QA_RUN_DIR/diagnostics-after.txt" "$QA_RUN_DIR/diagnostics-new.txt"

finish_flow pass
