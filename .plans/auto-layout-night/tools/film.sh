#!/bin/bash
# usage: film.sh <app path> <label>   (before|after). Runs in my screen window only.
set -u
APP="$1"; LABEL="$2"
SUP=/tmp/aln/film-$LABEL-support; ROOT=$HOME/array-scratch/aln-film-$LABEL; OUT=$HOME/Movies/Array/auto-layout-night
mkdir -p "$OUT" /tmp/aln/tmux-film
idle=$(ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {print int($NF/1000000000); exit}')
echo "HID idle ${idle}s"; [ "$idle" -lt 300 ] && [ -z "${ALN_SKIP_IDLE:-}" ] && { echo "Dylan may be active; abort"; exit 3; }
launch() { open -n --env CONTINUUM_PROJECT_ROOT="$ROOT" --env CONTINUUM_APP_SUPPORT="$SUP" --env TMUX_TMPDIR=/tmp/aln/tmux-film --env ARRAY_SKIP_USER_GHOSTTY_CONFIG=1 "$APP"; }
apppid() { pgrep -f "$APP/Contents/MacOS/Array" | head -1; }
# A boot blocked by a consent prompt shows no window: give up after 30 s, quit by PID, never click the prompt.
waitwindow() { for i in $(seq 1 60); do sleep 0.5; P=$(apppid); [ -n "$P" ] && R=$(/tmp/aln/tools/winrect "$P") && [ "$R" != "0,0,0,0" ] && return 0; done
  echo "NO WINDOW after 30s (prompt?): quitting pid $P, fall back to offscreen render"; [ -n "$P" ] && kill -TERM "$P"; exit 4; }
if [ ! -f "$ROOT/.aln-seeded" ]; then
  rm -rf "$SUP" "$ROOT"; mkdir -p "$SUP" "$ROOT"
  launch; waitwindow; sleep 3; echo "first boot pid $P"; kill -TERM "$P"; for i in $(seq 1 20); do kill -0 "$P" 2>/dev/null || break; sleep 0.3; done
  echo "zone docs:"; grep -rl "zones" "$SUP" 2>/dev/null | head
  exit 10   # lead seeds manually (zone id lookup), touches .aln-seeded, then reruns
fi
launch; waitwindow; sleep 6; R=$(/tmp/aln/tools/winrect "$P"); echo "pid $P rect $R"
osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $P) to true" 2>/dev/null
sleep 1.5
rm -f "$OUT/tidy-$LABEL.mov"; ( for i in $(seq 1 40); do sleep 0.25; /tmp/aln/tools/wins | grep -q UserNotificationCenter && { echo PROMPT-ABORT; kill -TERM $P; exit 0; }; done ) & screencapture -x -v -V 9 -R "$R" "$OUT/tidy-$LABEL.mov" &
REC=$!; sleep 2
X=$(echo $R | cut -d, -f1); Y=$(echo $R | cut -d, -f2)
if [ "${ALN_TRIGGER:-menu}" = key ]; then
  /tmp/aln/tools/rclick $((X+700)) $((Y+500)); sleep 0.3; /tmp/aln/tools/keys esc; sleep 0.8; /tmp/aln/tools/keys optcmdt
else
  /tmp/aln/tools/rclick $((X+1000)) $((Y+72)); sleep 0.8; screencapture -x -R "$R" /tmp/aln/menu-$LABEL.png
  /tmp/aln/tools/keys2 "tidy zone"; sleep 0.5; /tmp/aln/tools/keys enter
fi
wait $REC; screencapture -x -R "$R" "$OUT/tidy-$LABEL-end.png"
cp "$ROOT/.array/canvas.json" "$OUT/tidy-$LABEL-canvas.json"
kill -TERM "$P"; echo "done: $OUT/tidy-$LABEL.mov"
