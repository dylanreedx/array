# Spawn placement and framing verification

Branch: array/spawn-framing, based on d41dad04. No push. Main checkout and installed app bundles untouched.

## Changes by slice

- f304748f: placement and sidebar framing read the camera destination during flight.
- 2ec79c24: user focus queues one reveal after a 250 ms burst; union when it fits at working zoom, newest otherwise. Camera/geometry motion defers the reveal; workspace epoch changes discard it. Shared sidebar reveal, distinct tileSpawned history, fallback scope entry.
- 6cc49eb2: overlay-aware usable bounds, focus recency, synchronous zone resolution.
- 38991f51: nearest free visible slots and pinned post-spawn settle; pure geometry CoreChecks rows. Offscreen auto-layout clusters retain docking fallback.
- ac9463bc: file-drop conversion corrected; helpers and delegation prefer visible free slots without adding agent camera policy.
- Follow-up: pinned growth must remain enabled (the old engine clamped pinned movers first); file convenience overloads resolve their target zone before converting frame space; explicit project arming survives a camera over another project; inspector user reveals share the queue; visible helper placement retains existing size policy.
- Witness slice: mounted --spawn-framing-check, zone-arming visibility assertions, updated placement expectations and matrix registration/inventory.

## Recorded RED and GREEN

Evidence: qa-runs/spawn-framing-evidence/ in this bench.

- Original destination witness RED: expected (1480,650,640x400), got (580,250,640x400). Original debug build exit 0; fixed build exit 0 and placement check exit 0.
- Framing negative control: disable only the focusSpawnedTile queue. RED exit 1: camera stayed (20000,20000,1), sidebar expected (-144,-24,1). Restored queue GREEN.
- Final debug Array build: exit 0.
- --spawn-framing-check: exit 0. Mounts through WorkspaceInvariantsFixture; production palette note/agent/board, toolbar harness, typed Command-K via NSApp.sendEvent; offscreen/empty/focus cameras, 0.4 zoom, overlay exclusion, actual camera-driver pan before hydration debounce, three-tile burst, pending workspace-switch cancellation. Reuses production-entry zone-arming full, float-dust and roomy auto-layout cases.
- --spawn-placement-check: exit 0. Bare-canvas positive controls retained. Explicit file position now asserted in WORLD coordinates through pinned settle.
- --zone-arming-check: exit 0, including new post-settle top-left visibility assertions in sections 9 and 10b.
- CoreChecks rebuilt successfully, then ran to exit 1. Exact unrelated upstream failure: `wall-clock guard: ProcessTmuxControl.swift must not call Date() directly (route through Clock)`. The unchanged upstream Sources/ContinuumRevivedCore/Substrates/ProcessTmuxControl.swift calls Date() at lines 57 and 59. New free-slot rows produced no failures. Deliberate crash witnesses were deferred under the inherited managed-agent marker; remote-reach backend reported no controlling terminal.
- git diff --check: clean.
- Full matrix intentionally not run per task instruction. New flag is registered with a literal run_app_check invocation and in the committed inventory; no full matrix summary is claimed.

App legs unset ARRAY_AGENT_ID, use stdin /dev/null, TERM=xterm-256color and unique CONTINUUM_APP_SUPPORT. Final runs and CoreChecks use disposable tmux namespaces under /private/tmp, unset TMUX/TMUX_PANE, and verify socket_path before the suite. The managed-agent marker remains inherited. Scripts/benches.sh ran at pickup and completion; bench retained because the branch is unlanded and CoreChecks remains RED.

## Drop verdict and limits

Confirmed and fixed: performDragOperation converted screen to WORLD then to zone-local, before placement converted it a second time. The callback now receives WORLD coordinates. Also fixed the file convenience overload's missing target-zone conversion, exposed by the pinned-settle witness.

No manual UI preview or separate custom-route visual sweep was performed. Shell handoff and explicit beside placement keep their spatial intent and existing user-focus routes; this change does not provide an individual new witness for every custom route or settle-undo restoration. No claim of a fully GREEN Core gate or full matrix is made.
