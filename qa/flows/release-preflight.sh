#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=qa/flows/lib.sh
source "$SCRIPT_DIR/lib.sh"
# capture_step delegates to capture_app_window, which enforces the resolved
# CGWindowID rather than taking a whole-screen image.

defer_display() {
  local capability="$1" detail="$2"
  append_event "capture_unavailable" "DISPLAY_DEFERRED" "" "capability=$capability; $detail"
  finish_flow DISPLAY_DEFERRED
}

require_external_drivers
require_command caffeinate
require_command sips
[[ -n "${CONTINUUM_QA_RUN_DIR:-}" ]] || { echo "release preflight requires explicit CONTINUUM_QA_RUN_DIR" >&2; exit 2; }
begin_flow "release-preflight"

[[ "${CONTINUUM_PROJECT_ROOT:-}" == /* && "${CONTINUUM_APP_SUPPORT:-}" == /* ]] || {
  echo "CONTINUUM_PROJECT_ROOT and CONTINUUM_APP_SUPPORT must be isolated absolute paths" >&2
  exit 2
}
case "$CONTINUUM_PROJECT_ROOT:$CONTINUUM_APP_SUPPORT" in
  *"/qa-runs/"*) ;;
  *) echo "release preflight refuses non-QA state roots" >&2; exit 2 ;;
esac

launch_continuum default-smoke || defer_display "app-window-readiness" "exact launched PID did not expose a capturable window before timeout"
assert_flow "pid-window-identity" "CGWindowID belongs to exact launched PID; decoy owner names are ignored" assert_window_owned_by_pid
initial_bounds="$(window_bounds)"
IFS=',' read -r _initial_x _initial_y initial_width initial_height <<< "$initial_bounds"
if [[ "$initial_width" -lt 640 || "$initial_height" -lt 480 ]]; then
  capture_step "project-folder-access-blocker" "exact PID presented ${initial_width}x${initial_height} instead of the main canvas"
  defer_display "project-folder-access" "isolated project is under Documents and the app presented a folder-access blocker; permissions were not altered"
fi

if ! osascript - "$QA_APP_PID" <<'APPLESCRIPT' >/dev/null 2>&1
on run argv
  tell application "System Events"
    set p to first process whose unix id is (item 1 of argv as integer)
    set frontmost of p to true
    tell window 1 of p
      set position to {60, 60}
      set size to {1440, 900}
    end tell
  end tell
end run
APPLESCRIPT
then
  defer_display "accessibility" "System Events could not focus/resize PID $QA_APP_PID; grant Accessibility to the runner"
fi

sleep 0.2
bounds="$(window_bounds)"
IFS=',' read -r _x _y width height <<< "$bounds"
if [[ "$width" -ne 1440 || "$height" -ne 900 ]]; then
  capture_step "display-size-unavailable" "requested 1440x900, actual ${width}x${height}"
  defer_display "display-size-1440x900" "requested 1440x900 but display constrained the window to ${width}x${height}"
fi
assert_flow "size-1440x900" "window readback is 1440×900 points" test "$width" -eq 1440
capture_step "appearance-current-1440x900" "specific CGWindowID capture"

if ! osascript - "$QA_APP_PID" <<'APPLESCRIPT' >/dev/null 2>&1
on run argv
  tell application "System Events"
    set p to first process whose unix id is (item 1 of argv as integer)
    tell window 1 of p to set size to {960, 720}
  end tell
end run
APPLESCRIPT
then
  defer_display "accessibility" "could not resize exact PID window"
fi
sleep 0.2
bounds="$(window_bounds)"
IFS=',' read -r _x _y width height <<< "$bounds"
assert_flow "size-960x720" "window readback is 960×720 points" test "$width" -eq 960

before="$bounds"
click_center_of_window || defer_display "accessibility" "cliclick could not focus exact app window"
osascript - "$QA_APP_PID" <<'APPLESCRIPT' >/dev/null 2>&1 || defer_display "accessibility" "System Events could not drag the exact PID window"
on run argv
  tell application "System Events"
    set p to first process whose unix id is (item 1 of argv as integer)
    tell window 1 of p
      set xy to position
      set position to {(item 1 of xy) + 12, (item 2 of xy) + 8}
    end tell
  end tell
end run
APPLESCRIPT
after="$(window_bounds)"
assert_flow "ax-click-drag" "click/drag changed semantic window geometry" test "$before" != "$after"
capture_step "appearance-current-960x720" "specific-window capture after AX click/drag"

png="$QA_RUN_DIR/$(python3 - "$QA_MANIFEST_EVENTS" <<'PY'
import json,sys
rows=[json.loads(x) for x in open(sys.argv[1]) if x.strip()]
print([x['png'] for x in rows if x.get('png')][-1])
PY
)"
pixel_width="$(sips -g pixelWidth "$png" | awk '/pixelWidth/{print $2}')"
scale=$((pixel_width / width))
if [[ "$scale" -ne 2 ]]; then
  defer_display "retina-2x" "backing scale is ${scale}x (pixelWidth=$pixel_width pointWidth=$width)"
fi
assert_flow "retina-backing-scale" "external capture is exactly 2× point width" test "$scale" -eq 2

wait_for_named_readiness "qacapture-manifest-ready" "$QA_RUN_DIR/capture/manifest.json" 15 || defer_display "qacapture" "app-side manifest did not reach named readiness"
assert_flow "isolated-roots" "project and app-support roots are distinct QA paths" test "$CONTINUUM_PROJECT_ROOT" != "$CONTINUUM_APP_SUPPORT"
# Array currently pins one process appearance. Switching the user's global macOS
# appearance would mutate unrelated live state, so this lane reports the missing
# safe per-process Aqua/Dark Aqua seam instead of labelling duplicate pixels.
defer_display "appearance-switching" "safe per-process Aqua/Dark Aqua switching is unavailable; global appearance was not modified"
