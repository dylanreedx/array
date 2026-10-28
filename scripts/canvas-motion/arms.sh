#!/bin/zsh
# The comparison: one variable per arm, each twice. Residency takes its ordinary
# env override; far parking takes CANVAS_MOTION_FAR_PARK.
here=${0:A:h}
for rep in 1 2; do
  $here/run-arm.sh zoom-native-$rep        zoom ARRAY_TILE_SURFACE_RESIDENCY=0
  $here/run-arm.sh zoom-resident-$rep      zoom ARRAY_TILE_SURFACE_RESIDENCY=1
  $here/run-arm.sh pan-native-$rep         pan  ARRAY_TILE_SURFACE_RESIDENCY=0
  $here/run-arm.sh pan-resident-$rep       pan  ARRAY_TILE_SURFACE_RESIDENCY=1
  $here/run-arm.sh zoom-native-nopark-$rep zoom ARRAY_TILE_SURFACE_RESIDENCY=0 CANVAS_MOTION_FAR_PARK=off
done
