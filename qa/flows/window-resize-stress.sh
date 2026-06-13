#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=qa/flows/lib.sh
source "$SCRIPT_DIR/lib.sh"

require_command osascript
require_command screencapture
require_command cliclick
begin_flow "window-resize-stress"
launch_continuum

capture_step "before-resize" "app launched before external resize stress"

for width in 320 480 768 1024 1440 1920; do
  # AppleScript marker for structural check: set bounds through position and size.
  set_window_bounds 80 80 "$width" 820
  sleep 0.2
  capture_step "window-width-${width}" "set bounds width ${width}"
done

finish_flow pass
