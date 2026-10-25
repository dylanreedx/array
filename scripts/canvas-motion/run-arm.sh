#!/bin/zsh
# One benchmark arm: run-arm.sh <label> <phase zoom|pan|mixed> [KEY=VALUE ...]
# Launches the Release "Array Motion" bundle with --canvas-motion-probe in a fresh
# root and store, samples the main thread across the motion phase, waits for exit.
set -u
label=$1; phase=$2; shift 2
bundle="$HOME/array-scratch/apps/Array Motion.app"
run="$HOME/array-scratch/motion-runs/$label"
here=${0:A:h}
rm -rf "$run"; mkdir -p "$run"
out="$run/report.json"
envargs=(--env "CONTINUUM_PROJECT_ROOT=$run/root" --env "CONTINUUM_APP_SUPPORT=$run/support"
  --env "CANVAS_MOTION_OUTPUT=$out" --env "CANVAS_MOTION_PHASE=$phase"
  --env "CANVAS_MOTION_MARKDOWN_COUNT=${DOCS:-6}" --env "CANVAS_MOTION_AGENT_COUNT=${AGENTS:-8}"
  --env "CANVAS_MOTION_MARKDOWN_MODE=${MODE:-preview}" --env "CANVAS_MOTION_PHASE_SECONDS=${SECONDS_PHASE:-6}"
  --env "TMUX_TMPDIR=$(mktemp -d /tmp/motion-tmux.XXXX)" --env "TMUX=" --env "TMUX_PANE=")
for kv in "$@"; do envargs+=(--env "$kv"); done
open -n "${envargs[@]}" "$bundle" --args --canvas-motion-probe
ready="$out.ready.json"
for i in {1..200}; do
  [[ -f $ready ]] && grep -qE "warming-up|\"motion\"" "$ready" && break; sleep 0.1
done
pid=$(python3 -c "import json;print(json.load(open('$ready'))['pid'])" 2>/dev/null)
[[ -z $pid ]] && { echo "$label: never became ready"; cat "$ready" 2>/dev/null; exit 1; }
# Profiling pauses the app, so it is opt-in and never mixed into a timing arm.
if [[ ${SAMPLE:-0} == 1 ]]; then
  for i in {1..400}; do grep -q '"stage" : "motion"' "$ready" && break; sleep 0.05; done
  sample "$pid" $(( ${SECONDS_PHASE:-6} + 2 )) 1 -mayDie -file "$run/sample.txt" >/dev/null 2>&1
  python3 "$here/xtab.py" "$run/sample.txt" > "$run/xtab.txt" 2>/dev/null
fi
while kill -0 "$pid" 2>/dev/null; do sleep 0.5; done
python3 "$here/analyze.py" "$out" > "$run/summary.txt" 2>&1
echo "== $label ($phase $*)"; grep -v "^  t=" "$run/summary.txt"
