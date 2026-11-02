#!/bin/zsh
# Agent characters off vs on (Small) vs on at Large (plan 110, slice 8 and the
# character size setting): one variable per arm, each twice,
# zoom and pan, with the agents streaming before and during the gesture.
# Needs what every arm needs: the Release "Array Motion" bundle built from this
# checkout, an idle Mac, an unlocked display and an uncovered window. It takes the
# screen and focus while it runs, so never start it while Dylan is working.
here=${0:A:h}
for rep in 1 2; do
  for phase in zoom pan; do
    $here/run-arm.sh characters-off-$phase-$rep $phase CANVAS_MOTION_CHARACTERS=0 CANVAS_MOTION_STREAM_LEAD_SECONDS=3
    $here/run-arm.sh characters-on-$phase-$rep  $phase CANVAS_MOTION_CHARACTERS=1 CANVAS_MOTION_STREAM_LEAD_SECONDS=3
    $here/run-arm.sh characters-large-$phase-$rep $phase CANVAS_MOTION_CHARACTERS=1 CANVAS_MOTION_CHARACTER_SIZE=large CANVAS_MOTION_STREAM_LEAD_SECONDS=3
  done
done
