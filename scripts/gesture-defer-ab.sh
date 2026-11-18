#!/bin/zsh
# usage: scripts/gesture-defer-ab.sh [runs] [agents]
# Runs `--gesture-defer-check` with the governor OFF (base) and ON (fix), alternating,
# off-screen, and prints the missed-slot percentage during the gesture for each.
# Needs a debug build: swift build --product Array. Never takes the screen.
runs=${1:-3} agents=${2:-24}
bin=${BIN:-.build/debug/Array}
out=${OUT:-/tmp/gesture-defer-ab}
mkdir -p $out
for i in $(seq 1 $runs); do
  for arm in off on; do
    arm_dir=$out/$arm-$i
    rm -rf $arm_dir; mkdir -p $arm_dir/tmux
    env -u TMUX -u TMUX_PANE -u ARRAY_AGENT_ID \
      CONTINUUM_PROJECT_ROOT=$arm_dir/project CONTINUUM_APP_SUPPORT=$arm_dir/support \
      TMUX_TMPDIR=$arm_dir/tmux GESTURE_DEFER=$arm GESTURE_DEFER_AGENTS=$agents \
      GESTURE_DEFER_OUTPUT=$out/$arm-$i.json CANVAS_MOTION_VARIANT=full CANVAS_MOTION_ZOOM=0.35 \
      CANVAS_MOTION_DELTA_MS=${DELTA_MS:-50} CANVAS_MOTION_TURN_DELTAS=0 CANVAS_MOTION_HISTORY_TURNS=12 \
      $bin --gesture-defer-check -continuum.agentSounds.enabled NO -agentCharacters.sounds NO \
      > $arm_dir/stdout.log 2>&1 < /dev/null
    code=$?
    echo "$arm run $i exit=$code $(python3 -c "
import json,sys
try:
  r=json.load(open('$out/$arm-$i.json')); h=r['motionHeartbeat']
  print('missed=%.1f%% p99gap=%.1fms maxgap=%.1fms ingests=%d tileApplied=%d deferred=%d'%(h['missedPercent'],h['gapMsP99'],h['gapMsMax'],r['supervisorIngestsDuringMotion'],r['tileEventsAppliedDuringMotion'],r['deferredDuringMotion']))
except Exception as e: print('no result',e)")"
    rm -rf $arm_dir/project $arm_dir/support $arm_dir/tmux
  done
done
