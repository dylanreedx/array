# Spawn framing work — partial slice

Bench: array/spawn-framing, based on d41dad04. Main checkout and both installed apps untouched.

## Slice 1: camera destination coordinates

Placement and sidebar tile-jump framing use navigationViewport, preserving the destination during a running camera flight. Added a forced-flight behavioral case to the existing matrix-registered --spawn-placement-check, retaining all bare-canvas positive controls.

Debug build before fix: exit 0.
RED --spawn-placement-check: exit 1: expected (1480,650,640x400), got (580,250,640x400).
Debug build after fix: exit 0.
GREEN --spawn-placement-check: exit 0; ContinuumRevivedSpawnPlacementChecks passed (2026-11-06T201045Z).
Commands used env -u ARRAY_AGENT_ID TERM=xterm-256color, isolated CONTINUUM_APP_SUPPORT under /tmp, stdin /dev/null. No tmux commands ran.

## Confirmed finding, not fixed

CanvasNSView.performDragOperation converts screen to world then world to active-zone-local. TileSpawner.onFileURLDrop calls spawnFile(at:) with that point, which makeProjectTilePlacement converts world to local again. Nonzero zone origins therefore cause a double conversion.

## Outstanding

Full user spawn camera framing; distinct history reason; burst coalescing; gesture and workspace-switch cancellation; overlay-aware usable rect; focus recency anchor; synchronous target-zone resolution; free-slot ranking and settle pinning; custom routes including file-drop fix; mounted production-entry --spawn-framing-check; zone-arming extensions; CoreChecks rows and run; matrix registration/report for the new leg. Full matrix intentionally not run. This slice is not completion of the requested task.
