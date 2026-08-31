#!/usr/bin/env bash
set -euo pipefail
[[ $# -eq 3 ]] || { echo "usage: $0 READY DONE LOG" >&2; exit 2; }
ready="$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$1")"; done_path="$2"; log="$3"
driver="$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$0")"; driver_sha="$(shasum -a 256 "$driver"|awk '{print $1}')"; ready_sha="$(shasum -a 256 "$ready"|awk '{print $1}')"
read_field() { python3 - "$ready" "$1" <<'PY'
import json,sys
v=json.load(open(sys.argv[1]))[sys.argv[2]]
print(','.join(map(str,v)) if isinstance(v,list) else v)
PY
}
pid="$(read_field pid)"; windowID="$(read_field windowID)"; title="$(read_field title)"
executablePath="$(read_field executablePath)"; executableSHA256="$(read_field executableSHA256)"
beforeBounds="$(read_field beforeBounds)"; requestedDelta="$(read_field requestedDelta)"
actual_exe="$(ps -p "$pid" -o comm= | xargs)"; [[ "$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$actual_exe")" == "$executablePath" ]]
[[ "$(shasum -a 256 "$executablePath"|awk '{print $1}')" == "$executableSHA256" ]]
query_window() { swift - "$pid" "$windowID" "$title" <<'SWIFT'
import CoreGraphics; import Foundation
let pid=Int32(CommandLine.arguments[1])!, id=UInt32(CommandLine.arguments[2])!, title=CommandLine.arguments[3]
let ws=CGWindowListCopyWindowInfo(.optionAll,kCGNullWindowID) as? [[String:Any]] ?? []
guard let w=ws.first(where:{ ($0[kCGWindowNumber as String] as? UInt32)==id && ($0[kCGWindowOwnerPID as String] as? Int32)==pid && ($0[kCGWindowName as String] as? String)==title }), let b=w[kCGWindowBounds as String] as? [String:Any] else { exit(1) }
let x=b["X"]!, y=b["Y"]!, width=b["Width"]!, height=b["Height"]!
print("\(x),\(y),\(width),\(height)")
SWIFT
}
observed_before="$(query_window)"; [[ "$observed_before" == "$beforeBounds" ]]
osascript - "$pid" <<'APPLESCRIPT' >/dev/null
on run argv
 tell application "System Events" to perform action "AXRaise" of window 1 of (first process whose unix id is (item 1 of argv as integer))
end run
APPLESCRIPT
IFS=',' read -r x y w h <<< "$observed_before"; IFS=',' read -r dx dy <<< "$requestedDelta"
sx=$((x+w/2)); sy=$((y+14)); args=("m:${sx},${sy}" "dd:${sx},${sy}" "dm:$((sx+dx)),$((sy+dy))" "du:$((sx+dx)),$((sy+dy))")
started="$(python3 -c 'import time;print(time.time_ns())')"; cliclick "${args[@]}"; finished="$(python3 -c 'import time;print(time.time_ns())')"; after="$(query_window)"
python3 - "$ready" "$done_path" "$ready_sha" "$driver" "$driver_sha" "$after" "$started" "$finished" "${args[*]}" <<'PY'
import json,os,sys,tempfile,time
r=json.load(open(sys.argv[1])); a=[int(x) for x in sys.argv[6].split(',')]; b=r['beforeBounds']; d=dict(r,readySHA256=sys.argv[3],driverPath=sys.argv[4],driverSHA256=sys.argv[5],afterBounds=a,actualDelta=[a[0]-b[0],a[1]-b[1]],startedAtNs=int(sys.argv[7]),finishedAtNs=int(sys.argv[8]),doneAtNs=time.time_ns(),cliclickArgv=sys.argv[9].split())
fd,tmp=tempfile.mkstemp(dir=os.path.dirname(sys.argv[2])); os.write(fd,(json.dumps(d,sort_keys=True,indent=2)+'\n').encode()); os.close(fd); os.replace(tmp,sys.argv[2])
PY
cp "$done_path" "$log"
