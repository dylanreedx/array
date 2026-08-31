#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=qa/flows/lib.sh
source "$ROOT/qa/flows/lib.sh"
# Compact functional failures must never share the physical-capability defer
# status. These direct cases cover readiness, accessibility, timeout, ownership,
# and the two narrowly permitted physical defer capabilities.
for capability in app-window-readiness qacapture project-folder-access accessibility accessibility-frontmost-focus external-input-timeout external-input-window-identity pointer-titlebar-drag cleanup; do
  [[ "$(qa_capability_status "$capability")" == "fail" ]]
done
[[ "$(qa_capability_status display-size-1440x900-content)" == "DISPLAY_DEFERRED" ]]
[[ "$(qa_capability_status appearance-switching)" == "DISPLAY_DEFERRED" ]]
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
# The shipped driver must reject fake identity before invoking input or writing done.
fake_ready="$tmp/fake-ready.json"; fake_done="$tmp/fake-done.json"; fake_log="$tmp/fake-log.json"
python3 - "$fake_ready" "$ROOT" "$tmp" <<'PY'
import hashlib,json,os,subprocess,sys,time
root,tmp=sys.argv[2:]; driver=os.path.realpath(root+'/qa/external-input-driver.sh'); nonce='0123456789abcdef'
victim='/usr/bin/false'; json.dump(dict(schemaVersion='external-input-v1',runID='x',readyChallenge='wrong',launchNonce=nonce,candidateSHA=subprocess.check_output(['git','-C',root,'rev-parse','HEAD'],text=True).strip(),pid=os.getpid(),windowID=1,title=f'ARRAY_QA_INPUT_{nonce[:10]} — Array',executablePath=victim,executableSHA256=hashlib.sha256(open(victim,'rb').read()).hexdigest(),beforeBounds=[0,0,1,1],requestedDelta=[24,12],readyPublishedAtNs=time.time_ns(),driverPath=driver,driverSHA256=hashlib.sha256(open(driver,'rb').read()).hexdigest(),globalEventPath=tmp+'/global.json',targetEventPath=tmp+'/target.json',runRoot=tmp),open(sys.argv[1],'w'))
PY
if "$ROOT/qa/external-input-driver.sh" "$fake_ready" "$fake_done" "$fake_log" >/dev/null 2>&1; then exit 1; fi
[[ ! -e "$fake_done" ]]
# A fully self-consistent ordinary/production executable is rejected before input.
# READY-bound driver substitution and out-of-root/symlink artifacts also reject.
for attack in ordinary_title modified_driver out_of_root symlink_event; do
  attack_ready="$tmp/$attack.json"; cp "$fake_ready" "$attack_ready"
  python3 - "$attack_ready" "$attack" "$tmp" <<'PY'
import json,os,sys
p=json.load(open(sys.argv[1])); a=sys.argv[2]
if a=='ordinary_title': p['title']='work — Array'
elif a=='modified_driver': p['driverSHA256']='0'*64
elif a=='out_of_root': p['globalEventPath']='/tmp/victim-events.json'
elif a=='symlink_event':
 os.symlink(sys.argv[3]+'/victim',sys.argv[3]+'/linked-events'); p['globalEventPath']=sys.argv[3]+'/linked-events'
json.dump(p,open(sys.argv[1],'w'))
PY
  if "$ROOT/qa/external-input-driver.sh" "$attack_ready" "$tmp/$attack.done" "$tmp/$attack.log" >/dev/null 2>&1; then exit 1; fi
  [[ ! -e "$tmp/$attack.done" ]]
done
# Strict stream grammar rejects duplicates, unrelated events, missing/stale app
# artifacts, and modified app hashes; only down, dragged+, terminal up passes.
python3 <<'PY'
def valid(k): return len(k)>=3 and k[0]=='down' and k[-1]=='up' and all(x=='dragged' for x in k[1:-1]) and k.count('down')==1 and k.count('up')==1
assert valid(['down','dragged','dragged','up'])
for attack in (['down','down','dragged','up'],['down','dragged','up','up'],['move','down','dragged','up'],['down','up'],[]): assert not valid(attack)
# The target stream is bound to exact absolute start/end and exact window ID;
# preserving relative delta while shifting all coordinates cannot pass.
def target_valid(events,start,end,window):
 return all(e['windowID']==window for e in events) and abs(events[0]['x']-start[0])<=3 and abs(events[0]['y']-start[1])<=3 and abs(events[-1]['x']-end[0])<=3 and abs(events[-1]['y']-end[1])<=3
good=[dict(x=1140,y=128,windowID=7),dict(x=1164,y=140,windowID=7)]
assert target_valid(good,[1140,128],[1164,140],7)
shifted=[dict(e,x=e['x']+400,y=e['y']+200) for e in good]
wrong_window=[dict(e,windowID=8) for e in good]
assert not target_valid(shifted,[1140,128],[1164,140],7)
assert not target_valid(wrong_window,[1140,128],[1164,140],7)
PY
rg -q "targetEventSHA256" "$ROOT/qa/external-input-driver.sh" "$ROOT/qa/flows/release-preflight.sh"
rg -q "NSEvent.removeMonitor" "$ROOT/Sources/ContinuumRevived/App/ContinuumApp.swift"
echo "Wave0 GUI adversarial checks passed"
