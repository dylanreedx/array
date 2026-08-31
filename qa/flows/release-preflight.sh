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
export CONTINUUM_QA_EXTERNAL_READY_PATH="$QA_RUN_DIR/external-input-ready.json"
export CONTINUUM_QA_EXTERNAL_EVENT_OUTPUT="$QA_RUN_DIR/external-pointer-events.json"
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
IFS=',' read -r drag_x drag_y drag_w _drag_h <<< "$before_ax"
drag_start_x=$((drag_x + drag_w / 2)); drag_start_y=$((drag_y + 14)); drag_dx=24; drag_dy=12
if [[ "${CONTINUUM_QA_EXTERNAL_INPUT:-0}" == "1" ]]; then
  ready="$QA_RUN_DIR/external-input-ready.json"; done_marker="$QA_RUN_DIR/external-input-done.json"
  rm -f "$ready" "$done_marker"
  driver_path="$(canonical_path "$QA_ROOT/qa/external-input-driver.sh")"
  driver_sha="$(shasum -a 256 "$driver_path" | awk '{print $1}')"
  global_event_path="$QA_RUN_DIR/external-driver-events.json"
  target_event_path="$QA_RUN_DIR/external-pointer-events.json"
  rm -f "$global_event_path" "$target_event_path"
  ready_challenge="$(openssl rand -hex 24)"
  ready_published_ns="$(python3 -c 'import time; print(time.time_ns())')"
  input_title="ARRAY_QA_INPUT_${CONTINUUM_QA_LAUNCH_NONCE:0:10} — Array"
  python3 - "$ready" "$CONTINUUM_QA_RUN_ID" "$ready_challenge" "$CONTINUUM_QA_LAUNCH_NONCE" "$CONTINUUM_QA_CANDIDATE_SHA" "$QA_APP_PID" "$QA_WINDOW_ID" "$before_ax" "$drag_dx" "$drag_dy" "$input_title" "$CONTINUUM_QA_EXECUTABLE_PATH" "$CONTINUUM_QA_EXECUTABLE_SHA256" "$ready_published_ns" "$driver_path" "$driver_sha" "$global_event_path" "$target_event_path" "$QA_RUN_DIR" <<'PY'
import json,os,sys,tempfile
out=sys.argv[1]; payload=dict(schemaVersion='external-input-v1',runID=sys.argv[2],readyChallenge=sys.argv[3],launchNonce=sys.argv[4],candidateSHA=sys.argv[5],pid=int(sys.argv[6]),windowID=int(sys.argv[7]),beforeBounds=[int(x) for x in sys.argv[8].split(',')],requestedDelta=[int(sys.argv[9]),int(sys.argv[10])],title=sys.argv[11],executablePath=sys.argv[12],executableSHA256=sys.argv[13],readyPublishedAtNs=int(sys.argv[14]),driverPath=sys.argv[15],driverSHA256=sys.argv[16],globalEventPath=sys.argv[17],targetEventPath=sys.argv[18],runRoot=sys.argv[19])
fd,tmp=tempfile.mkstemp(dir=os.path.dirname(out)); os.write(fd,json.dumps(payload,sort_keys=True,indent=2).encode()+b'\n'); os.close(fd); os.replace(tmp,out)
PY
  append_event "external-input-ready" "pass" "" "nonce-bound scratch title=$input_title; waiting for authorized pointer input"
  wait_for_named_readiness "external-input-done-ready" "$done_marker" 60 || defer_display "external-input-timeout" "authorized external input did not produce a fresh done marker"
  assert_flow "external-input-done-identity" "done marker completely matches ready identity, digest, driver and ordering" python3 - "$ready" "$done_marker" "$QA_ROOT/qa/external-input-driver.sh" <<'PY'
import hashlib,json,os,sys
r=json.load(open(sys.argv[1])); d=json.load(open(sys.argv[2])); digest=hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest()
for k in ['schemaVersion','runID','readyChallenge','launchNonce','candidateSHA','pid','windowID','title','executablePath','executableSHA256','beforeBounds','requestedDelta','driverPath','driverSHA256','globalEventPath','targetEventPath','runRoot']: assert d.get(k)==r.get(k)
driver=os.path.realpath(sys.argv[3]); assert os.path.realpath(d.get('driverPath',''))==driver and d.get('driverSHA256')==hashlib.sha256(open(driver,'rb').read()).hexdigest()
assert d.get('readySHA256')==digest and len(d.get('cliclickArgv',[]))==4 and d.get('startedAtNs',0) < d.get('finishedAtNs',0) < d.get('doneAtNs',0)
assert [d.get('topmostPID'),d.get('topmostWindowID'),d.get('topmostTitle')]==[r['pid'],r['windowID'],r['title']]
assert os.stat(sys.argv[2]).st_mtime_ns > os.stat(sys.argv[1]).st_mtime_ns and d.get('doneAtNs',0) > r['readyPublishedAtNs']
assert d.get('actualDelta') == [d['afterBounds'][0]-r['beforeBounds'][0],d['afterBounds'][1]-r['beforeBounds'][1]]
PY
  assert_flow "external-pointer-event-proof" "passive CGEventTap observed ordered down-dragged-up with expected coordinates" python3 - "$ready" "$done_marker" <<'PY'
import hashlib,json,os,sys
r=json.load(open(sys.argv[1])); d=json.load(open(sys.argv[2])); run=os.path.realpath(r['runRoot'])
def contained(path):
 assert os.path.realpath(os.path.dirname(path))==run and os.path.dirname(path)==run and os.path.isfile(path) and not os.path.islink(path)
def strict(events, kinds):
 assert len(events)>=3 and len(kinds)==len(events) and kinds[0] in (1,'down') and kinds[-1] in (2,'up')
 assert all(x in (6,'dragged') for x in kinds[1:-1])
 assert sum(x in (1,'down') for x in kinds)==1 and sum(x in (2,'up') for x in kinds)==1
 assert all(events[i]['monotonicNs'] < events[i+1]['monotonicNs'] and events[i]['wallTimeNs'] < events[i+1]['wallTimeNs'] for i in range(len(events)-1))
 return events[0],events[-1]
path=d['eventArtifactPath']; assert path==r['globalEventPath']; contained(path); assert hashlib.sha256(open(path,'rb').read()).hexdigest()==d['eventArtifactSHA256']
ev=json.load(open(path))['events']; down,up=strict(ev,[x['type'] for x in ev]); dx,dy=r['requestedDelta']
assert abs((up['x']-down['x'])-dx)<=3 and abs((up['y']-down['y'])-dy)<=3 and abs(down['x']-d['startPoint'][0])<=3 and abs(down['y']-d['startPoint'][1])<=3 and abs(up['x']-d['endPoint'][0])<=3 and abs(up['y']-d['endPoint'][1])<=3
target=d['targetEventPath']; assert target==r['targetEventPath']; contained(target); assert hashlib.sha256(open(target,'rb').read()).hexdigest()==d['targetEventSHA256']
t=json.load(open(target)); assert [t.get(k) for k in ['runID','readyChallenge','launchNonce','windowID','title']]==[r.get(k) for k in ['runID','readyChallenge','launchNonce','windowID','title']]
tdown,tup=strict(t['events'],[x['kind'] for x in t['events']]); assert all(x['windowID']==r['windowID'] for x in t['events'])
assert abs((tup['x']-tdown['x'])-dx)<=3 and abs((tup['y']-tdown['y'])-dy)<=3
assert r['readyPublishedAtNs'] < down['wallTimeNs'] <= up['wallTimeNs'] < d['doneAtNs'] and r['readyPublishedAtNs'] < tdown['wallTimeNs'] <= tup['wallTimeNs'] < d['doneAtNs']
assert d['startedAtNs'] <= d['finishedAtNs'] <= d['doneAtNs']
PY
  assert_window_owned_by_pid || defer_display "external-input-window-identity" "exact window ownership changed during external input"
  after_ax="$(window_bounds)"
  IFS=',' read -r after_x after_y _after_w _after_h <<< "$after_ax"
  assert_flow "pointer-titlebar-drag" "authorized external pointer drag moved exact CGWindowID by intended nonzero delta" assert_pointer_drag_delta "$drag_x" "$drag_y" "$after_x" "$after_y" 16 6
else
swift - "$QA_APP_PID" <<'SWIFT'
import AppKit
import Foundation
let pid = Int32(CommandLine.arguments[1])!
guard let app = NSRunningApplication(processIdentifier: pid),
      app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps]) else { exit(1) }
SWIFT
osascript - "$QA_APP_PID" <<'APPLESCRIPT' >/dev/null
on run argv
  tell application "System Events" to set frontmost of (first process whose unix id is (item 1 of argv as integer)) to true
end run
APPLESCRIPT
sleep 0.3
if ! osascript - "$QA_APP_PID" <<'APPLESCRIPT'
on run argv
  tell application "System Events"
    set p to first process whose unix id is (item 1 of argv as integer)
    if frontmost of p is false then error "candidate not frontmost"
    set hasMain to false
    repeat with w in windows of p
      if value of attribute "AXMain" of w is true then set hasMain to true
    end repeat
    if hasMain is false then error "candidate has no main AX window"
  end tell
end run
APPLESCRIPT
then
  defer_display "accessibility-frontmost-focus" "exact scratch PID/window could not become frontmost/main on this self-hosting runner; pointer drag was not attempted or claimed"
fi
append_event "pointer-drag-focus-precondition" "pass" "" "exact candidate PID/window is frontmost and main before genuine pointer drag"
cliclick "m:${drag_start_x},${drag_start_y}" "dd:${drag_start_x},${drag_start_y}" "dm:$((drag_start_x+drag_dx)),$((drag_start_y+drag_dy))" "du:$((drag_start_x+drag_dx)),$((drag_start_y+drag_dy))"
after_ax="$(window_bounds)"
IFS=',' read -r after_x after_y _after_w _after_h <<< "$after_ax"
actual_dx=$((after_x-drag_x)); actual_dy=$((after_y-drag_y))
assert_flow "pointer-titlebar-drag" "real cliclick down/move/up moved exact CGWindowID by intended nonzero delta" assert_pointer_drag_delta "$drag_x" "$drag_y" "$after_x" "$after_y" 16 6
fi
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
