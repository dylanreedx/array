#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=qa/flows/lib.sh
source "$SCRIPT_DIR/lib.sh"

require_command osascript
require_command screencapture
begin_flow "quit-during-load"
diagnostic_snapshot "$QA_RUN_DIR/diagnostics-before.txt"
launch_continuum "cmd-3-browser"

# Marker for structural check: CONTINUUM_QA_FLOW=cmd-3-browser checks DiagnosticReports after quit.
capture_step "before-quit" "browser flow started before quit"
quit_app_with_osascript
sleep 0.8
diagnostic_snapshot "$QA_RUN_DIR/diagnostics-after.txt"

if comm -13 "$QA_RUN_DIR/diagnostics-before.txt" "$QA_RUN_DIR/diagnostics-after.txt" > "$QA_RUN_DIR/diagnostics-new.txt" && [[ ! -s "$QA_RUN_DIR/diagnostics-new.txt" ]]; then
  append_event "diagnosticreports-clean" "pass" "" "no new DiagnosticReports entries after quit"
  QA_APP_PID=""
  finish_flow pass
else
  append_event "diagnosticreports-clean" "fail" "" "new DiagnosticReports entries appeared after quit"
  QA_APP_PID=""
  finish_flow fail
fi
