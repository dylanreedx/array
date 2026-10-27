#!/bin/zsh
# Today's tiles vs the canvas renderer on a replayed workspace, interleaved so both
# share the machine's load: renderer-arms.sh <spec.json> [reps]
# Uses BUNDLE (default: the Debug motion bundle). Residency off: real tiles only.
spec=$1; reps=${2:-2}; here=${0:A:h}
export BUNDLE=${BUNDLE:-$HOME/array-scratch/apps/Array Motion Debug.app}
common=(CANVAS_MOTION_REPLAY=$spec CANVAS_MOTION_PIN_ZONES=1 CANVAS_MOTION_DELTA_MS=40 ARRAY_TILE_SURFACE_RESIDENCY=0)
for rep in $(seq 1 $reps); do
  for arm in "zoom 0" "zoom 3" "pan 3"; do
    set -- ${=arm}
    for rr in list canvas; do
      $here/run-arm.sh ra-$1-s$2-$rr-$rep $1 "${common[@]}" CANVAS_MOTION_STREAMING_AGENTS=$2 ARRAY_TRANSCRIPT_RENDERER=$rr >/dev/null 2>&1
    done
  done
done
for rr in list canvas; do
  $here/run-arm.sh ra-fidelity-$rr zoom "${common[@]}" CANVAS_MOTION_STREAMING_AGENTS=0 ARRAY_TRANSCRIPT_RENDERER=$rr \
    CANVAS_MOTION_FIDELITY=1 CANVAS_MOTION_CENSUS=1 >/dev/null 2>&1
done
cd $HOME/array-scratch/motion-runs
python3 -I $here/table.py ra-zoom-s0-* ra-zoom-s3-* ra-pan-s3-*
for rr in list canvas; do
  echo "== fidelity $rr"; python3 -I $here/analyze.py ra-fidelity-$rr/report.json | grep "^fidelity"
  python3 -c "import json;c=json.load(open('ra-fidelity-$rr/report.json'))['baseline'].get('viewCensus') or {};print('views in canvas:', sum(c.values()))"
done
for r in ra-*; do python3 -c "import json;r=json.load(open('$r/report.json'));e=[x for x in (r.get('errors') or []) if 'occluded' in x];print('$r: window covered, discard') if e else None" 2>/dev/null; done
