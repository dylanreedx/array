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
[[ -n "${CONTINUUM_QA_RELEASE_ROOT:-}" ]] || { echo "release preflight requires explicit CONTINUUM_QA_RELEASE_ROOT" >&2; exit 2; }
state_root="$CONTINUUM_QA_RELEASE_ROOT/state/gui"
[[ -n "${CONTINUUM_QA_EVIDENCE_ROOT:-}" ]] || { echo "release preflight requires explicit CONTINUUM_QA_EVIDENCE_ROOT" >&2; exit 2; }
wave0_root="$CONTINUUM_QA_RELEASE_ROOT/wave0"
evidence_root="$(validate_isolated_path CONTINUUM_QA_EVIDENCE_ROOT "$CONTINUUM_QA_EVIDENCE_ROOT" "$wave0_root")" || exit 2
project_canonical="$(validate_isolated_path CONTINUUM_PROJECT_ROOT "${CONTINUUM_PROJECT_ROOT:-}" "$state_root")" || exit 2
support_canonical="$(validate_isolated_path CONTINUUM_APP_SUPPORT "${CONTINUUM_APP_SUPPORT:-}" "$state_root")" || exit 2
run_canonical="$(validate_isolated_path CONTINUUM_QA_RUN_DIR "$CONTINUUM_QA_RUN_DIR" "$evidence_root")" || exit 2
[[ "$project_canonical" != "$support_canonical" && "$project_canonical" != "$run_canonical" && "$support_canonical" != "$run_canonical" ]] || { echo "isolated roots must be distinct" >&2; exit 2; }
export CONTINUUM_PROJECT_ROOT="$project_canonical" CONTINUUM_APP_SUPPORT="$support_canonical" CONTINUUM_QA_RUN_DIR="$run_canonical"
begin_flow "release-preflight"
project_archive="$(validate_isolated_path project-archive "$QA_RUN_DIR/previous-array-state" "$evidence_root")"
support_archive="$(validate_isolated_path support-archive "$QA_RUN_DIR/previous-app-support" "$evidence_root")"

# UserDefaults launch arguments form a process-only volatile domain. This
# acknowledges Array's own explanatory gate without changing TCC or persistent
# defaults, and is limited to the exact isolated root dispatched for this run.
grant_encoded="$(printf '%s' "$CONTINUUM_PROJECT_ROOT" | base64 | tr '/+' '_-' | tr -d '=\n')"
export CONTINUUM_QA_PROJECT_GRANT_KEY="continuum.projectFolderGrantAcknowledged.${grant_encoded}"
export CONTINUUM_QA_HOLD_OPEN=1
export CONTINUUM_QA_RUN_ID="$(basename "$CONTINUUM_QA_RELEASE_ROOT")"
export CONTINUUM_QA_LAUNCH_NONCE="$(openssl rand -hex 24)"
export CONTINUUM_QA_CANDIDATE_SHA="$(git -C "$QA_ROOT" rev-parse HEAD)"
export CONTINUUM_QA_EXECUTABLE_PATH="$(canonical_path "$QA_APP")"
export CONTINUUM_QA_EXECUTABLE_SHA256="$(shasum -a 256 "$CONTINUUM_QA_EXECUTABLE_PATH" | awk '{print $1}')"
export CONTINUUM_QA_FIXTURE_ID="ARRAY_QA_RULER_V1"
defaults_domain="dev.arrayapp.macos.dev"
grant_persisted_before="$(defaults read "$defaults_domain" "$CONTINUUM_QA_PROJECT_GRANT_KEY" 2>/dev/null || true)"
probe="$CONTINUUM_PROJECT_ROOT/.array-release-preflight-write-probe"
printf 'release-preflight\n' > "$probe"
[[ "$(cat "$probe")" == "release-preflight" ]] || { echo "isolated project root is not readable/writable" >&2; exit 2; }
rm -f "$probe"
append_event "isolated-project-rw" "pass" "" "read/write probe succeeded without TCC mutation"
if [[ -e "$CONTINUUM_PROJECT_ROOT/.array" ]]; then
  mv "$CONTINUUM_PROJECT_ROOT/.array" "$project_archive"
  append_event "isolated-state-reset" "pass" "" "previous isolated .array state moved into this evidence run"
fi
if [[ -d "$CONTINUUM_APP_SUPPORT" ]]; then
  mv "$CONTINUUM_APP_SUPPORT" "$support_archive"
  mkdir -p "$CONTINUUM_APP_SUPPORT"
  append_event "isolated-app-support-reset" "pass" "" "paired app-support state moved into this evidence run"
fi

launch_continuum cmd-3-browser || defer_display "app-window-readiness" "exact launched PID did not expose a capturable window before timeout"
assert_flow "pid-window-identity" "CGWindowID belongs to exact launched PID; decoy owner names are ignored" assert_window_owned_by_pid
wait_for_named_readiness "qacapture-manifest-ready" "$QA_RUN_DIR/capture/manifest.json" 15 || defer_display "qacapture" "app-side manifest did not reach named readiness"
assert_flow "fresh-readiness-identity" "QACapture manifest matches this exact launch/candidate/binary/roots/fixture/window" python3 - "$QA_RUN_DIR/capture/manifest.json" "$QA_APP_PID" "$CONTINUUM_QA_RUN_ID" "$CONTINUUM_QA_LAUNCH_NONCE" "$CONTINUUM_QA_CANDIDATE_SHA" "$CONTINUUM_QA_EXECUTABLE_PATH" "$CONTINUUM_QA_EXECUTABLE_SHA256" "$CONTINUUM_PROJECT_ROOT" "$CONTINUUM_APP_SUPPORT" "$CONTINUUM_QA_FIXTURE_ID" "$QA_WINDOW_ID" <<'PY'
import json,sys
p=json.load(open(sys.argv[1])); keys=['pid','runID','launchNonce','candidateSHA','executablePath','executableSHA256','projectRoot','appSupportRoot','fixtureID']
expected=[int(sys.argv[2]),*sys.argv[3:]]
assert all(p.get(k)==v for k,v in zip(keys,expected)), (p,dict(zip(keys,expected)))
assert isinstance(p.get('windowID'),int) and p['windowID'] == int(sys.argv[11])
PY
assert_flow "wkwebview-ruler-semantic" "fresh QACapture records deterministic ruler fixture identity" grep -q "ARRAY_QA_RULER_V1" "$QA_RUN_DIR/capture/manifest.json"
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
assert_flow "frame-960x752" "960x720 content has independently observed 960x752 titled frame" test "$compact_width" -eq 960
assert_flow "frame-height-960x752" "observed titled frame height is 752 points" test "$compact_frame_height" -eq 752
capture_step "ruler-960x720-content-frame-960x752" "compact exact-window WKWebView ruler capture"
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
var rowR = [Int](repeating: 0, count: height), rowG = rowR, rowB = rowR
for i in stride(from: 0, to: bytes.count, by: 4) {
  let r=Int(bytes[i]), g=Int(bytes[i+1]), b=Int(bytes[i+2])
  let y = i / 4 / width
  if r > 180 && r > g * 2 && r > b * 2 { red += 1; rowR[y] += 1 }
  if g > 140 && g * 2 > r * 3 && g * 2 > b * 3 { green += 1; rowG[y] += 1 }
  if b > 160 && b > r * 2 && b > g * 2 { blue += 1; rowB[y] += 1 }
}
let threshold = 2000
func longest(_ rows: [Int]) -> (Int,Int,Int) {
  var best=(0,0,0), start=0, count=0
  for y in 0..<rows.count {
    if rows[y] > width / 3 { if count == 0 { start=y }; count += 1; if count > best.2 { best=(start,y,count) } }
    else { count=0 }
  }
  return best
}
let rr=longest(rowR), gg=longest(rowG), bb=longest(rowB)
let pass = red >= threshold && green >= threshold && blue >= threshold && rr.2 >= 80 && gg.2 >= 80 && bb.2 >= 80 && rr.0 < gg.0 && gg.0 < bb.0
let payload: [String: Any] = ["png": CommandLine.arguments[1], "width": width, "height": height, "redPixels": red, "greenPixels": green, "bluePixels": blue, "thresholdEach": threshold, "redBand":[rr.0,rr.1,rr.2], "greenBand":[gg.0,gg.1,gg.2], "blueBand":[bb.0,bb.1,bb.2], "minimumBandRows":80, "pass": pass]
try! JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .atomic)
exit(pass ? 0 : 1)
SWIFT
assert_flow "wkwebview-ruler-pixels" "external PNG contains substantial red/green/blue fixture bands; counts in $ruler_json" grep -q '"pass" : true' "$ruler_json"
before_ax="$(window_bounds)"
osascript - "$QA_APP_PID" <<'APPLESCRIPT' >/dev/null
on run argv
  tell application "System Events" to set frontmost of (first process whose unix id is (item 1 of argv as integer)) to true
end run
APPLESCRIPT
sleep 0.3
assert_flow "pointer-drag-focus-precondition" "setup made exact candidate PID/window frontmost and main before genuine pointer drag" osascript - "$QA_APP_PID" <<'APPLESCRIPT'
on run argv
  tell application "System Events"
    set p to first process whose unix id is (item 1 of argv as integer)
    if frontmost of p is false then error "candidate not frontmost"
    if value of attribute "AXMain" of window 1 of p is false then error "target AX window not main"
  end tell
end run
APPLESCRIPT
IFS=',' read -r drag_x drag_y drag_w _drag_h <<< "$before_ax"
drag_start_x=$((drag_x + drag_w / 2)); drag_start_y=$((drag_y + 14)); drag_dx=24; drag_dy=12
cliclick "m:${drag_start_x},${drag_start_y}" "dd:${drag_start_x},${drag_start_y}" "dm:$((drag_start_x+drag_dx)),$((drag_start_y+drag_dy))" "du:$((drag_start_x+drag_dx)),$((drag_start_y+drag_dy))"
after_ax="$(window_bounds)"
IFS=',' read -r after_x after_y _after_w _after_h <<< "$after_ax"
actual_dx=$((after_x-drag_x)); actual_dy=$((after_y-drag_y))
assert_flow "pointer-titlebar-drag" "real cliclick down/move/up moved exact CGWindowID by intended nonzero delta" assert_pointer_drag_delta "$drag_x" "$drag_y" "$after_x" "$after_y" 16 6
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
      set size of w to {1440, 932}
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
if [[ "$width" -ne 1440 || "$height" -ne 932 ]]; then
  capture_step "display-size-unavailable" "requested 1440x900 content (expected 1440x932 titled frame), observed frame ${width}x${height}"
  defer_display "display-size-1440x900-content" "requested 1440x900 content; expected frame 1440x932 but observed frame ${width}x${height}"
fi
assert_flow "frame-1440x932" "requested 1440x900 content has expected 1440x932 titled frame" test "$height" -eq 932
capture_step "appearance-current-1440x900-content-frame-1440x932" "specific CGWindowID capture"
# Array currently pins one process appearance. Switching the user's global macOS
# appearance would mutate unrelated live state, so this lane reports the missing
# safe per-process Aqua/Dark Aqua seam instead of labelling duplicate pixels.
defer_display "appearance-switching" "safe per-process Aqua/Dark Aqua switching is unavailable; global appearance was not modified"
