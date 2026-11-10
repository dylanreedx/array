# Spawn framing release handoff

Base: c476ced90566e4b8ca6715de054fe723d7bf4ce4
Branch: array/spawn-framing-release
Fetched origin before creating this bench. No push.

## What ships

New user tiles land near the focused tile or usable view centre.
Creation frames them through the same navigation used by sidebar jumps.
Bursts coalesce after gestures, with a bounded reveal wait.
Explicit drops retain their coordinates. Pinned frames stay pinned.
Fan-out keeps its intended shape before considering anchor proximity.
Agent-created tiles default to camera preserve.
This changes the workspace API default, including document opens.
Typing defers explicitly requested reveals.
Offscreen agent results get a silent, clickable edge indicator.
UUID ordering, canvas decode and placement avoid redundant work.

The stalled camera-flight fix also changes existing 0.7.44 navigation.
It applies outside tile creation whenever the display link stalls.
The backstop commits the exact destination and clears the flight.
Spawn reveals have a separate 1.5-second monotonic deadline.

## Commits

3484c038 fix(spawn): place tiles at the camera flight destination
4ed73300 fix(spawn): coalesce user tile framing after gestures settle
16c8644e fix(spawn): resolve anchors and zones against usable camera bounds
244fd48c fix(spawn): prefer visible free slots and pin post-spawn placement
46413c87 fix(spawn): preserve drop coordinates and prefer visible helper slots
afb91942 fix(spawn): preserve pinned frames and explicit project intent
6fa63f96 test(spawn): witness user framing through mounted production routes
5834ff40 feat(workspace-api): keep the camera still for agent-created tiles
60cc8b92 perf(auto-layout): order ids by their bytes, not by uuidString
97db8f19 perf(spawn): decode canvas.json once per write, not twice
00020956 perf(spawn): reuse placement inputs and settle scene
846b7ccb fix(spawn): preserve fan-out shape before anchor proximity
74bd096f fix(spawn): finish stalled camera flights and bound reveal deferral

Preview merges and PREVIEW/REPORT files were not shipped.
The preview-only dev-app.sh change was excluded.
The source spawn-framing branch has seven non-merge feature commits.
All seven are included, despite the request describing nine.

## Integration conflicts

156e4568 conflicted in run-matrix.sh and matrix-inventory.txt.
Kept integration's current runner, grouping and opt-in film behavior.
Added the UUID check without restoring the old serial leg block.
4903e0ee conflicted in matrix-inventory.txt.
Kept both spawn-placement and spawn-live-framing entries.
Regenerated the inventory using check-matrix-inventory.sh directly.
Current check counts and agent-camera registrations are included.

## Verification

Debug `swift build -c debug`: exit 0, 200.83 seconds.
Built Array and all checks products in this fresh bench.
The build's own exit code was captured, without a pipeline.
Matrix inventory check: exit 0. git diff --check: exit 0.

- Array --spawn-framing-check: exit 0.
- Array --spawn-live-framing-check: exit 0.
- Array --spawn-placement-check: exit 0.
- Array --zone-arming-check: exit 0.
- Array --auto-layout-fanout-app-check: exit 0.
- Array --workspace-api-open-check: exit 0.
- Array --workspace-api-grants-check: exit 0.
- Array --workspace-api-device-check: exit 0.
- Array --canvas-undo-check: exit 0.
- Array --refused-spawn-teardown-check: exit 0.
- ContinuumRevivedCoreChecks --uuid-string-order-check: exit 0.
- ContinuumRevivedCoreChecks --unreadable-canvas-store-check: exit 0.
- ContinuumRevivedCoreChecks --layout-pressure-check: exit 0.
- ContinuumRevivedCoreChecks --exact-rebase-performance-check: exit 0.
- ContinuumRevivedCoreChecks --workspace-api-contract-check: exit 0.
- ContinuumRevivedCoreChecks full CoreChecks: exit 0.

Each listed check ran once.
Flags were enumerated from source and validated before invocation.
App legs unset ARRAY_AGENT_ID, used stdin /dev/null and TERM=xterm-256color.
Each invocation used disposable app support and a disposable project root.
Tmux inherited neither TMUX nor TMUX_PANE.
Its unique /tmp namespace was checked via canonical socket_path.
Only that server was cleaned up. The managed-agent marker stayed inherited.
The runner's first socket check rejected /private/tmp versus /tmp spelling.
No check ran in that attempt; its isolated server was cleaned up.
Canonical path validation corrected the runner before the actual run.

Full CoreChecks passed, including the added free-slot section.
The pre-existing ProcessTmuxControl Date() guard failure did not reproduce.
The two calls remain at source lines 57 and 59.
This result does not establish that the prior guard still exists unchanged.
Full CoreChecks reported these environment limits:
- Crash witnesses RemoteReach.tunnel.wrap and FracIndex.between.equal skipped.
- Remote-reach backend skipped: no controlling terminal for script's pty.
The release gate must retain complete external crash-witness coverage.

Logs: qa-runs/spawn-release in the release bench (ignored).

## Release gate and skipped work

The release agent must run scripts/run-matrix.sh and read its summary.
No full matrix was run for this preparation.
Run all targeted legs below again through that gate.
Run --workspace-api-agent-camera-check on an available QA display.
It calls makeKeyAndOrderFront and was skipped to protect Dylan's screen.
That single leg covers camera preserve, the indicator and its activation,
and renders the indicator in light and dark appearances.
No manual appearance sweep, simulator UI or sustained benchmark was run.
The existing full matrix owns the remaining release verification.

## Open decision for Dylan

AtomicWriter's read-back decode costs about one third of each spawn write.
The prior profiling measured 9–12 ms on main.
This handoff does not change that safety read-back.
No new timing benchmark was performed during release preparation.

## Earlier preview findings

The combined preview originally failed the fan-out shape witness.
1f61b1ac fixed it; 4903e0ee fixed the later camera-flight starvation.
The preview reported the ProcessTmuxControl.swift Date() guard as pre-existing.
The current run result is recorded below.
Prior preview light/dark and simulator coverage was incomplete.
No installed app bundle or main-checkout working file was changed here.

## Bench

Benches inventory ran at pickup and completion, exit 0.
This unlanded release bench is retained for the release agent's gate and logs.
No staging, commit or other working-file mutation occurred in the main checkout.
All commits use Dylan's configured identity, without attribution trailers.
