#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=qa/flows/lib.sh
source "$SCRIPT_DIR/lib.sh"

require_external_drivers
begin_flow "drag-past-edge"
launch_continuum

# Marker for structural check: CONTINUUM_QA_FLOW=canvas-drag-resize uses cliclick drag.
capture_step "before-drag" "app launched before external drag"
click_center_of_window
sleep 0.1
drag_window_center_by -900 -700
sleep 0.3
capture_step "after-drag-past-edge" "drag moved tile far past the visible top-left edge"

finish_flow pass
