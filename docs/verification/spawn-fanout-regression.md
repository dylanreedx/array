# Spawn fan-out regression

Base: array/spawn-preview at 8d86527a. Debug builds only; no app bundle rebuild, launch or push.

## Confirmed cause

TileSpawnPlacement.automatic returned nearestVisibleSlot before calling fanOutPlacement whenever preferredAnchor existed and any sibling was visible. That shortcut ranked only distance and completely bypassed the fan-out's growth direction and cluster-envelope shape ranking. A 640x520 host has nearer vertical than horizontal neighbours, so following each spawn repeatedly chose a vertical neighbour. Focus made the anchor follow the newest tile, but focus itself was not the defect: the shape policy never ran.

## Change

Evaluate fan-out first, including when the working tile is larger than the current viewport. Preserve its existing visibility, growth-direction and shape ranking. Use the preferred anchor only as the final distance tie-break when no explicit fan-out focus exists. Keep nearest-visible-slot behavior for placements without a usable fan-out. Camera framing and usable viewport calculations remain unchanged.

Added hand-computed cases to --spawn-framing-check: a focused 640x520 host with a spacious visible rect must choose (648,0) for fan/right growth, even though (0,528) is nearer; down growth must choose (0,528). The original --auto-layout-fanout-app-check was not modified.

## Witness

Evidence logs: qa-runs/spawn-fanout-regression/ (bench-local, ignored).

- Baseline debug build: exit 0.
- RED --auto-layout-fanout-app-check: exit 1. Seven tiles formed 640x3688, aspect 0.17.
- Fixed debug build: exit 0.
- GREEN --auto-layout-fanout-app-check: exit 0. Seven tiles formed 2584x1048, aspect 2.47; real drag and lead/helper cluster assertions also passed.
- --spawn-framing-check: exit 0, including new direction/shape controls and existing mounted framing/usable-view assertions.
- --spawn-placement-check: exit 0.
- --zone-arming-check: exit 0.
- git diff --check: exit 0.

Every app leg unset ARRAY_AGENT_ID, TMUX and TMUX_PANE; set TERM=xterm-256color and isolated CONTINUUM_APP_SUPPORT; used stdin /dev/null; created its own disposable tmux namespace under /private/tmp and verified socket_path before running. The inherited Array managed-agent marker was preserved. No installed app bundle was touched. Full matrix and CoreChecks were not run for this scoped regression.
