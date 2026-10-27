#!/bin/zsh
# Replay arms on a real workspace: replay-arms.sh <spec.json> [rep]
# Streaming agents 0/1/3/8 = none, measured p50, p90 and max concurrency;
# residency on (as in the source app's defaults) and off. 40 ms deltas.
spec=$1; rep=${2:-1}; here=${0:A:h}
common=(CANVAS_MOTION_REPLAY=$spec CANVAS_MOTION_DELTA_MS=40)
for phase in pan zoom; do
  for streaming in 0 1 3 8; do
    for residency in 1 0; do
      $here/run-arm.sh replay-$phase-s$streaming-r$residency-$rep $phase "${common[@]}" \
        CANVAS_MOTION_STREAMING_AGENTS=$streaming ARRAY_TILE_SURFACE_RESIDENCY=$residency
    done
  done
done
