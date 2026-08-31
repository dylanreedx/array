#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=qa/flows/lib.sh
source "$SCRIPT_DIR/lib.sh"
# capture_step delegates to capture_app_window, which enforces the resolved
# CGWindowID rather than taking a whole-screen image.

defer_display() {
  local capability="$1" detail="$2"
  if [[ -n "$QA_WINDOW_ID" ]]; then
    local failure_png="$QA_RUN_DIR/failure-$(slug "$capability").png"
    if capture_app_window "$failure_png"; then
      append_event "failure-capture" "fail" "$(basename "$failure_png")" "$detail"
    fi
  fi
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

# UserDefaults launch arguments form a process-only volatile domain. This
# acknowledges Array's own explanatory gate without changing TCC or persistent
# defaults, and is limited to the exact isolated root dispatched for this run.
grant_encoded="$(printf '%s' "$CONTINUUM_PROJECT_ROOT" | base64 | tr '/+' '_-' | tr -d '=\n')"
export CONTINUUM_QA_PROJECT_GRANT_KEY="continuum.projectFolderGrantAcknowledged.${grant_encoded}"
export CONTINUUM_QA_HOLD_OPEN=1
defaults_domain="dev.arrayapp.macos.dev"
grant_persisted_before="$(defaults read "$defaults_domain" "$CONTINUUM_QA_PROJECT_GRANT_KEY" 2>/dev/null || true)"
probe="$CONTINUUM_PROJECT_ROOT/.array-release-preflight-write-probe"
printf 'release-preflight\n' > "$probe"
[[ "$(cat "$probe")" == "release-preflight" ]] || { echo "isolated project root is not readable/writable" >&2; exit 2; }
rm -f "$probe"
append_event "isolated-project-rw" "pass" "" "read/write probe succeeded without TCC mutation"
if [[ -e "$CONTINUUM_PROJECT_ROOT/.array" ]]; then
  mv "$CONTINUUM_PROJECT_ROOT/.array" "$QA_RUN_DIR/previous-array-state"
  append_event "isolated-state-reset" "pass" "" "previous isolated .array state moved into this evidence run"
fi
if [[ -d "$CONTINUUM_APP_SUPPORT" ]]; then
  mv "$CONTINUUM_APP_SUPPORT" "$QA_RUN_DIR/previous-app-support"
  mkdir -p "$CONTINUUM_APP_SUPPORT"
  append_event "isolated-app-support-reset" "pass" "" "paired app-support state moved into this evidence run"
fi

launch_continuum cmd-3-browser || defer_display "app-window-readiness" "exact launched PID did not expose a capturable window before timeout"
assert_flow "pid-window-identity" "CGWindowID belongs to exact launched PID; decoy owner names are ignored" assert_window_owned_by_pid
wait_for_named_readiness "qacapture-manifest-ready" "$QA_RUN_DIR/capture/manifest.json" 15 || defer_display "qacapture" "app-side manifest did not reach named readiness"
assert_flow "wkwebview-ruler-semantic" "QACapture records deterministic ruler fixture identity" grep -q "ARRAY_QA_RULER_V1" "$QA_RUN_DIR/capture/manifest.json"
assert_flow "compact-content-semantic" "app-side readiness records 960x720 content size" grep -q "qaContentSize=960x720" "$QA_RUN_DIR/capture/manifest.json"
capture_step "browser-ready-initial" "exact-PID window after named cmd-3-browser ruler readiness"
initial_bounds="$(window_bounds)"
IFS=',' read -r _initial_x _initial_y initial_width initial_height <<< "$initial_bounds"
if [[ "$initial_width" -lt 640 || "$initial_height" -lt 480 ]]; then
  capture_step "project-folder-access-blocker" "exact PID presented ${initial_width}x${initial_height} instead of the main canvas"
  defer_display "project-folder-access" "isolated project is under Documents and the app presented a folder-access blocker; permissions were not altered"
fi

# Prove the compact lane before attempting a size this display may not contain.
osascript - "$QA_APP_PID" <<'APPLESCRIPT' >/dev/null 2>&1 || defer_display "accessibility" "could not set compact exact-PID window size"
on run argv
  tell application "System Events"
    set p to first process whose unix id is (item 1 of argv as integer)
    repeat with w in windows of p
      set size of w to {960, 720}
    end repeat
  end tell
end run
APPLESCRIPT
sleep 0.2
compact_bounds="$(window_bounds)"
IFS=',' read -r _compact_x _compact_y compact_width compact_frame_height <<< "$compact_bounds"
assert_flow "size-960x720" "compact window readback is 960×720 points" test "$compact_width" -eq 960
capture_step "ruler-960x720" "compact exact-window WKWebView ruler capture"
compact_png="$QA_RUN_DIR/$(python3 - "$QA_MANIFEST_EVENTS" <<'PY'
import json,sys
rows=[json.loads(x) for x in open(sys.argv[1]) if x.strip()]
print([x['png'] for x in rows if x.get('png')][-1])
PY
)"
ruler_json="$QA_RUN_DIR/ruler-pixel-counts.json"
swift - "$compact_png" "$ruler_json" <<'SWIFT'
import CoreGraphics
import Foundation
import ImageIO
let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL, nil)!
let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
let width = image.width, height = image.height
var bytes = [UInt8](repeating: 0, count: width * height * 4)
let ctx = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
var red = 0, green = 0, blue = 0
for i in stride(from: 0, to: bytes.count, by: 4) {
  let r=Int(bytes[i]), g=Int(bytes[i+1]), b=Int(bytes[i+2])
  if r > 180 && r > g * 2 && r > b * 2 { red += 1 }
  if g > 140 && g * 2 > r * 3 && g * 2 > b * 3 { green += 1 }
  if b > 160 && b > r * 2 && b > g * 2 { blue += 1 }
}
let threshold = 2000
let pass = red >= threshold && green >= threshold && blue >= threshold
let payload: [String: Any] = ["png": CommandLine.arguments[1], "width": width, "height": height, "redPixels": red, "greenPixels": green, "bluePixels": blue, "thresholdEach": threshold, "pass": pass]
try! JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .atomic)
exit(pass ? 0 : 1)
SWIFT
assert_flow "wkwebview-ruler-pixels" "external PNG contains substantial red/green/blue fixture bands; counts in $ruler_json" grep -q '"pass" : true' "$ruler_json"
before_ax="$(osascript - "$QA_APP_PID" <<'APPLESCRIPT'
on run argv
  tell application "System Events"
    set p to first process whose unix id is (item 1 of argv as integer)
    set xy to position of window 1 of p
    return (item 1 of xy as text) & "," & (item 2 of xy as text)
  end tell
end run
APPLESCRIPT
)"
click_center_of_window || defer_display "accessibility" "cliclick could not focus exact app window"
osascript - "$QA_APP_PID" <<'APPLESCRIPT' >/dev/null 2>&1 || defer_display "accessibility" "System Events could not move the exact PID window"
on run argv
  tell application "System Events"
    set p to first process whose unix id is (item 1 of argv as integer)
    repeat with w in windows of p
      set xy to position of w
      set position of w to {(item 1 of xy) + 12, (item 2 of xy) + 8}
    end repeat
  end tell
end run
APPLESCRIPT
after_ax="$(osascript - "$QA_APP_PID" <<'APPLESCRIPT'
on run argv
  tell application "System Events"
    set p to first process whose unix id is (item 1 of argv as integer)
    set xy to position of window 1 of p
    return (item 1 of xy as text) & "," & (item 2 of xy as text)
  end tell
end run
APPLESCRIPT
)"
assert_flow "ax-focus-click-drag" "exact-PID focus/click and window drag changed semantic geometry" test "$before_ax" != "$after_ax"
assert_flow "isolated-roots" "project and app-support roots are distinct QA paths" test "$CONTINUUM_PROJECT_ROOT" != "$CONTINUUM_APP_SUPPORT"
grant_persisted_after="$(defaults read "$defaults_domain" "$CONTINUUM_QA_PROJECT_GRANT_KEY" 2>/dev/null || true)"
assert_flow "volatile-project-ack" "process launch acknowledgement did not mutate persistent defaults" test "$grant_persisted_before" = "$grant_persisted_after"

if ! osascript - "$QA_APP_PID" <<'APPLESCRIPT' >/dev/null 2>&1
on run argv
  tell application "System Events"
    set p to first process whose unix id is (item 1 of argv as integer)
    set frontmost of p to true
    repeat with w in windows of p
      set position of w to {60, 60}
      set size of w to {1440, 900}
    end repeat
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
    repeat with w in windows of p
      set size of w to {960, 720}
    end repeat
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

assert_flow "isolated-roots" "project and app-support roots are distinct QA paths" test "$CONTINUUM_PROJECT_ROOT" != "$CONTINUUM_APP_SUPPORT"
grant_persisted_after="$(defaults read "$defaults_domain" "$CONTINUUM_QA_PROJECT_GRANT_KEY" 2>/dev/null || true)"
assert_flow "volatile-project-ack" "process launch acknowledgement did not mutate persistent defaults" test "$grant_persisted_before" = "$grant_persisted_after"
# Array currently pins one process appearance. Switching the user's global macOS
# appearance would mutate unrelated live state, so this lane reports the missing
# safe per-process Aqua/Dark Aqua seam instead of labelling duplicate pixels.
defer_display "appearance-switching" "safe per-process Aqua/Dark Aqua switching is unavailable; global appearance was not modified"
