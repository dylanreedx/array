# o3 — Layout drift root cause (tiles/zones move without the user)

HEAD 1451c030, read-only investigation. No edits, no GUI launch, no default tmux socket.

## Summary

The frame-space conversion itself holds. Every path that converts WORLD to ZONE-LOCAL and back uses one origin per trip, and a hydrated tile's world frame survives switch and relaunch exactly: `--workspace-scene-owner-check` is GREEN on "every tile returned to the pixel it started on". The drift comes from four other defects, and none of them is a frame-space bug:

1. **The workspace document has several writers holding snapshots of different ages, and one of them writes to the wrong workspace.** `WorkspaceRuntime.armingSaveController` is created once, bound to whatever `workspaceId` was current at the first ambient arming, and never rebound when `switchWorkspace` changes `self.workspaceId`. After an A→B switch, every `.click`/`.focus`/`.camera` arming in B writes **B's whole document into A's file** 200 ms later. When the user switches back, A is rebuilt from that file. The same controller holds a struct snapshot that can also land *after* a newer synchronous save in the same workspace (the orchestrator's lead, confirmed). `persistLayoutTransaction` then re-reads that stale disk copy and `replaceDocument`s it over the in-memory truth.
2. **Zones below the live hydration tier are geometry-only ghosts.** They are in `liveZones`, so the jelly solver pushes them. Their tiles are not in the scene, so the tiles never move with them. The push is persisted to the document while `canvas.json` keeps the old world frames. At the next mount the zone sits in its new place and its tiles sit where they were, outside it but still stamped as members.
3. **Auto-layout runs without user input.** It fires on hydration tier changes, on browser budget eviction, on WebContent crash restarts, on page-opened popups and on agent/API spawns. Each of those goes through `installProjectTile` → `growZoneOnSpawn` + `arrangeAutoLayoutAfterSpawn`, which re-settles (magnetizes and clamps) the entire zone and commits it. `withAutoLayoutSuppressed` guards only the Phase-B hydration block, and `enforceBrowserRuntimeBudget()` is called right *after* that block closes.
4. **Zone growth never looks at neighbouring zones.** That covers resize pressure, `expandZoneToContainMembers`, `growZone`-on-spawn and tidy. Only an actively dragged zone pushes peers. So a non-user grow (item 3) can make a zone overlap its neighbour.

In the layer world, which is every persisted workspace since M1.10, membership is also frozen. `reevaluateZoneMembership` bails for layer tiles, so drop-to-rehome and break-out are dead. With auto-layout off for a zone, a member dragged outside stays a member outside the rect. And `resolveZoneMembership` rescues nil or foreign stamps into the home zone when nothing contains them, without moving the tile.

Top hypothesis per symptom:
- **(a) Tiles shift inside a zone:** non-user `arrangeAutoLayoutAfterSpawn` via browser snapshot/restart on tier change and budget eviction (H-A1, ~70%).
- **(b) Zones overlap on return:** stale or cross-workspace document snapshots revert or replace zone placements, plus non-user grow with no peer resolution (H-B1 ~60%, H-B2 ~55%).
- **(c) Tiles outside their zone but still members:** a ghost (unhydrated) zone moved by a jelly push without its tiles (H-C1, ~65%), then stale arming snapshots and home-zone rescue.

`--file-tile-zoom-check`'s red (2.439717294900222) is a **title compositor pixel difference**, not geometry. It fails at `expect(difference <= 2, "title compositor drift…")` (`CanvasZoomInvalidationProbeChecks.swift:~231`), before the zoom world-frame assertion (`:~291`) is ever reached. It is unrelated to this complaint, but it currently masks that zoom geometry assertion.

## Frame lifecycle trace

Notation: **W** = world frame, **L** = zone-local, **O(x)** = origin taken from source x. The sources are **doc** (the `WorkspaceDocument.zones` entry), **layer** (`ZoneLayer.placement`) and **live** (`CanvasNSView.liveZones`, which also drives chrome).

| Step | Tile frame | Zone rect | Origin used | Code |
|---|---|---|---|---|
| Boot, persisted workspace | canvas.json W → `worldToZoneLocal(W, O(doc))` → L | doc → layer AND live (`setZones` writes both from the same doc placement) | doc | `ContinuumApp.swift:16235-16249` (retire flat, `runtime.install`); `WorkspaceRuntime.swift:705-725`; `CanvasNSView.swift:6232-6277` |
| Render | `worldFrame(tile, in: layer.placement)` | chrome from `liveZones` | tiles: layer; chrome: live | `CanvasNSView.swift:6879-6887`, `1854-1869` |
| User drag / resize (auto-layout on) | solver in W over `autoLayoutScene()`: tiles W via layer origin; **zones = liveZones first, layer only if absent** | solver output lands in live AND layer | scene: live wins | `CanvasNSView.swift:437-457`, `476-520`, `720-731` |
| Commit | `captureGeometry` W via layer origin; zones via `allZonePlacements()`, where **layer wins over live** | `persistLayoutTransaction`: **re-reads disk doc**, writes zones and ambient W, writes project canvas.json W, saves, `replaceDocument` | capture: layer wins | `CanvasNSView.swift:2570-2620`, `2750-2783`; `ContinuumApp.swift:14663-14755` |
| Zone drag without auto-layout | `setZonePlacement` → layer, live, chrome together; tiles ride as a rigid body (L unchanged) | `onZoneMoved` → `commitZonePlacement` (in-memory doc, sync save) | layer = live | `CanvasNSView.swift:6008-6013`, `6400-6425`; `WorkspaceRuntime.swift:108-114` |
| Debounced project save | `canvasStateForPersistence` → `mergeProjectTilesForPersistence(persisted, tilesInWorldFrames)` — W via layer origin; uncovered zones keep disk W | — | layer | `ZoneRuntimeController.swift:~660-700`; `CanvasNSView.swift:6600-6690` |
| Switch away | `flushAll` (W via layer); `flushPendingArmingSave` (**stale snapshot, possibly for another workspace**); then `persistDepartingWorkspaceState` overlays `allZonePlacements()` (layer wins) onto the in-memory doc and saves it. **Ambient tiles are not overlaid.** | overlay rescues every mounted zone's rect | layer wins | `WorkspaceRuntime.swift:798-809`, `1861-1885` |
| Switch back | the target doc is loaded from disk at `:1482`, *before* the departing flush at `:1495`; `memberTiles` W → L with O(doc); `setZones` | doc → layer + live | doc | `WorkspaceRuntime.swift:1466-1626` |
| Quit | `applicationShouldTerminate` → `flushMountedWorkspaceState` (same as switch away). A crash, jetsam or SIGKILL skips it. | same | — | `ContinuumApp.swift:~16708-16750` |
| Relaunch | same as boot (persisted-workspace branch; the flat walk never runs) | same | doc | as boot |

**Round-trip invariant.** Tile world frames are persisted with O(layer) and re-read with O(doc). Those can differ, for example after `growZoneToFitMembers`, which updates only `liveZones` (`CanvasNSView.swift:1954-1979`). Even then the tile keeps its world position: W = L + O(layer) goes out, and L' = W − O(doc) comes back rendered at O(doc) + L' = W. So **a tile never drifts in world space from a conversion mismatch**. Visible drift is always either (i) a real mover changing W, or (ii) the zone rect changing without its members.

**Zone move persistence.**
- **Hydrated zone:** consistent. Layer, live and doc update together, and members move as a rigid body (`resolveOuterCollisions` translates pushed zones' member tiles too, `CanvasAutoLayoutEngine.swift:928-933`).
- **Unhydrated zone:** only `liveZones` and the doc move; its tiles (disk W) do not. This is H-C1.
- **Divergence case (auto-layout off only):** `growZoneToFitMembers` leaves layer ≠ live. The switch overlay then persists the stale *layer* rect (`allZonePlacements` picks the layer), so the growth reverts on return.

## Non-user movers

| Mover | Moves | Runs without user input? | Evidence |
|---|---|---|---|
| `arrangeAutoLayoutAfterSpawn` (expand + settle whole zone, commits and persists) | tiles + zone | **Yes**: on any `installProjectTile` outside `withAutoLayoutSuppressed` | `CanvasNSView.swift:829-845`, `6800-6850` |
| Browser snapshot on dehydrate (camera settle → `reconcileHydration` → `setTier(.snapshot)` → `installBrowserSnapshotTile`) | same | **Yes**: every pan that moves a zone out of the viewport + 256pt band | `WorkspaceRuntime.swift:1758-1814`; `ZoneRuntimeController.swift:570-589`; `TileSpawner.swift:1056-1078` |
| Browser restart on hydrate (`hydrateToLive` → `restartBrowserTile`) | same | **Yes**: pan back | `ZoneRuntimeController.swift:591-612`; `TileSpawner.swift:1082-1127` |
| `enforceBrowserRuntimeBudget` eviction → `installBrowserSnapshotTile` | same | **Yes**: after every reconcile, after Phase B hydration **outside the suppression block** (`ContinuumApp.swift:16525` vs block at `16496`), and at boot | `WorkspaceRuntime.swift:1708-1725`, `1816` |
| WebContent crash restart; page `window.open` (`spawnBrowserForNewWindow`) | same | **Yes**: page- or OS-driven | `ContinuumApp.swift:~7170-7230`; `TileSpawner.swift:979-1034` |
| Agent/API spawns (file open, run artifacts, workspace API) and `applyProgrammaticTileGeometry` | same | agent-driven (grants) | `CanvasNSView.swift:~6746-6780`; `TileSpawner.swift` spawn sites |
| `settleMembers` itself: `clampIntoContent` plus greedy gap-contact magnetism | tiles | only a fixed point for layouts that are already gap-contact | `CanvasAutoLayoutEngine.swift:590-632` |
| `resolveOuterCollisions`: an active zone pushes ALL scene zones, including unhydrated ones | zones (+ scene tiles) | only during a user zone drag/resize, but it hits zones the user cannot see | `CanvasAutoLayoutEngine.swift:888-947` |
| Resize-pressure grow / `expandZoneToContainMembers` / `growZone` / explicit tidy (`zone.origin = minX - padding`) | zone rect | grow-on-spawn: yes (see above); tidy: user, onboarding (`ContinuumApp.swift:9154`), tile-gap or auto-layout settings change (`CanvasNSView.swift:3483-3498`) | `CanvasAutoLayoutEngine.swift:130-160`, `202-212`; `CanvasNSView.swift:847-873`, `1888-1941` |
| `resolveZoneMembership` rescue to home zone | membership only (the tile stays outside the rect) | **Yes**: every mount | `ZoneMembershipRepair.swift:83-96`; `WorkspaceRuntime.swift:497-548` |
| Arming debounce (`armingSaveController`, 200 ms timer) | whole-document snapshot | **Yes**: camera settle | `WorkspaceRuntime.swift:347`, `418-428`; `WorkspaceDocumentSaveController.swift:39-52` |
| Zoom / camera restore / `fitAllToViewport` / resize handlers | camera only | no tile or zone frame writes found | `CanvasNSView` camera driver; `WorkspaceRuntime.swift:1908-1915` |
| Hydration Phase B restarts | none (suppressed; local frames reused via `tileRecord`) | — | `ContinuumApp.swift:16496-16523`; `TileSpawner.swift:579-650` |

## Ranked hypotheses per symptom

### (a) Tiles shift within a zone after a switch or after time

- **H-A1 (~70%). Non-user settle through spawn-shaped reinstalls.**
  - `installBrowserSnapshotTile` and `restartBrowserTile` both call `installProjectTile(targetZoneId: zoneId(containing:))`. That ends in `growZoneOnSpawn` + `arrangeAutoLayoutAfterSpawn(zoneId)`, which settles every member of the zone and commits it through `onLayoutCommitted`, so the move is durable.
  - The triggers are panning (tier change), browser budget eviction (including right after switch hydration, `ContinuumApp.swift:16525`), WebContent crashes and popups.
  - This matches "after a period of time" and "when switching".
  - Settle is not idempotent for hand-spaced layouts, for layouts made with auto-layout off, or after a gap setting change.
- **H-A2 (~40%). Ambient (group) zone tiles revert on disk.** A stale arming snapshot (H-B1) lands after a drag. The next `persistLayoutTransaction` re-reads that disk copy and `replaceDocument`s it (`ContinuumApp.swift:14677`, `14746`). The departing overlay restores zone rects but **not `ambientTiles`** (`WorkspaceRuntime.swift:1861-1885`), so ambient tiles come back at their pre-drag positions. This only applies to project-less zones.
- **H-A3 (~25%). Agent-driven geometry** (`applyProgrammaticTileGeometry`, agent file opens), where granted.

### (b) Zones overlap after returning

- **H-B1 (~60%). The document is overwritten by a stale or foreign whole-document snapshot.** This part is confirmed in code; the lead supplied by the orchestrator is verified.
  - Same workspace: `armingSaveController` stores a struct snapshot and writes it 200 ms later. No other writer cancels it, because every other save builds a fresh controller. A jelly drag that pushes zones and commits within that window is reverted on disk. The in-memory document is repaired only by a clean switch or quit overlay. A crash, jetsam or force-quit relaunches with pre-push zone positions, while `canvas.json` holds post-push tile world frames. The result is chained zones overlapping and members outside their rect.
  - **Worse (new finding): the arming controller is never rebound on `switchWorkspace`.** It is created at `WorkspaceRuntime.swift:422-426` with the workspaceId current at that moment, it is only created when nil, and nothing resets it (grep shows the only other uses at `:474`, `:478`, `:483`). After A→B, any arming change in B writes **B's document into A's `canvas.json`**. `WorkspaceStore.save` has no identity guard (`WorkspaceStore.swift:62-64`, and `WorkspaceDocument` carries no workspaceId). Returning to A loads that file (`:1482`); `mountableZones` drops B-owned project zones and keeps ambient ones (`:1677-1686`); the departing save then makes the loss durable. The clearest presentation is "A is empty, or shows B's group zones". It is the strongest "came back to a workspace and it changed" mechanism in the code, but its visible form fits (b) only partially.
- **H-B2 (~55%). Non-user or unilateral zone growth with no peer resolution.** `resolveOuterCollisions` runs only when `activeZone != nil` (`CanvasAutoLayoutEngine.swift:895`). The resize-pressure branch returns before it (`:128-160`). `expandZoneToContainMembers` and `growZone` apply directly. Combined with H-A1, a zone the user is not looking at grows into its neighbour.
- **H-B3 (~30%). A ghost zone was pushed (H-C1) and its neighbour later grew back into it.** Push chains hit zones the user cannot see, and a revert of only some of them (H-B1) leaves overlaps.

### (c) Tiles lie outside their zone's rect while still members

- **H-C1 (~65%). A ghost zone moves without its tiles.**
  - Zones below `.live` get no layer, both at mount (`WorkspaceRuntime.swift:686`, `1543`) and at any time afterwards: `reconcileHydration`/`setTier` never installs a layer, and `installedLayers` is written only at `:770`, `:904` and `:1599`.
  - Their placements are still in `liveZones` (`setZones(documentZones:)`) and therefore in `autoLayoutScene().zones`.
  - A user zone drag pushes them through `resolveOuterCollisions` (`peers = zones.keys`, `CanvasAutoLayoutEngine.swift:890`). The push translates only *scene* tiles, and the ghost zone has none.
  - `finishAutoLayoutGesture` → `persistLayoutTransaction` writes the new zone placement to the document; the ghost's tiles in `canvas.json` keep their old world frames.
  - At the next mount, `memberTiles` converts W with the new O(doc), so the tiles paint at their old world pixels, outside the moved zone, still stamped as members.
  - A direct drag of a ghost zone has the same effect (`CanvasNSView.swift:6015-6027`).
- **H-C2 (~50%).** H-B1's stale snapshot reverts the zone while `canvas.json` keeps its moved members, or the reverse.
- **H-C3 (~40%). Rescue without containment, and frozen membership.** `resolveZoneMembership` rescues nil or foreign stamps into `home` when no project zone contains the centre, and never moves the tile (`ZoneMembershipRepair.swift:83-96`). The legs log such repairs routinely. Also, in the layer world, `reevaluateZoneMembership` returns false for every layer tile (`CanvasNSView.swift:1986-1987`, guard on `canvasState.tiles`). With a zone's auto-layout off, dragging a member out leaves it a member outside the rect. With auto-layout on, settle's `clampIntoContent` snaps it back instead, and re-home and break-out never happen.
- **H-C4 (~15%). Auto-layout off only.** `growZoneToFitMembers` updates `liveZones` and not `layer.placement` (`:1977`), while `allZonePlacements` persists the layer rect on switch (`:2577-2583`). The chrome growth reverts and the resized tile ends up outside.

## Repro recipe

All steps are headless, driven through `mountWorkspaceSceneAtBoot`, with a temp `CONTINUUM_APP_SUPPORT` and project roots.

- **R1 (cross-workspace arming, deterministic).**
  1. Workspace A has zones A1 and A2 (projects PA1, PA2); B has zones B1 and B2 (PB1, PB2).
  2. Mount A. Run `setActiveZone(A2, .camera)` so the controller binds to A.
  3. `switchWorkspace(to: B)`. Run `setActiveZone(B2, .click)`, then `flushPendingArmingSave()`.
  4. Read A's store. **RED today:** A's `canvas.json` zones == B's zones.
  5. `switchWorkspace(to: A)`. **RED:** the mounted zone ids ⊄ {A1, A2}.
- **R2 (same-workspace stale snapshot).**
  1. Mount A, with A1 and A2 adjacent on the x axis.
  2. `setActiveZone(A2, .focus)`, which schedules the snapshot.
  3. Drag A1 into A2 with auto-layout on (jelly push), and commit.
  4. `flushPendingArmingSave()`, then load the disk doc. **RED:** A2's origin equals its pre-push origin while the canvas shows the pushed one.
  5. Skip the switch or quit flush (simulating a crash) and remount. **RED:** A2's members lie outside A2's rect, and A1 ∩ A2 ≠ ∅.
- **R3 (ghost push).**
  1. Set `maxLiveZones=1` (a suite-injected default), with zone Z2 off-screen so it is `.cold`.
  2. Drag Z1 until it pushes Z2, and commit.
  3. Flush and remount with Z2 live. **RED:** Z2's tiles are outside Z2's rect.
- **R4 (non-user settle).**
  1. Place a zone with 3 hand-spaced tiles, one of them a browser, with gaps larger than the resolved gap.
  2. Pan until the zone leaves the viewport + 256pt band, then `flushPendingHydrationReconcile()`. The browser is snapshotted.
  3. **RED:** the other tiles' world frames changed, and `canvas.json` changed.
  4. Also run it with a browser budget of 0 right after `switchWorkspace`.

## Witness spec

Proposed flag: `--layout-stability-roundtrip-check`. It needs a new `ContinuumApp.main()` arm; do not reuse a guessed flag.

- Drive `mountWorkspaceSceneAtBoot` (never `install(into:)`) with two persisted workspaces. Each has 2 or 3 project zones with hand-spaced members (non gap-contact, and one browser tile), plus one ambient zone with tiles. Include one zone below the live tier (`maxLiveZones` injected via suite defaults) and one adjacent zone pair.
- Capture **S0**: every tile's world frame (`allTilesInWorldFrames` plus disk W for unhydrated zones), every zone rect (`workspaceZonePlacementsForPersistence`), and the disk docs for both workspaces.

The leg then runs these phases:

1. **Idle movers.** Pan away and back through the real delegate chain (`setViewport` → `canvasDidChange`), then `flushPendingHydrationReconcile()`. Run `enforceBrowserRuntimeBudget()`. Assert S == S0 byte-for-byte (tolerance 0).
2. **Arming.** Run `setActiveZone(other, .click)` and `flushPendingArmingSave()` in each workspace. Assert both disk docs are unchanged except `lastActiveZoneId`, and that neither file contains the other workspace's zone ids.
3. **Switch A→B→A.** Assert S == S0.
4. **Gesture then crash-equivalent.** Commit one programmatic zone move that pushes its neighbour and the below-tier zone (`applyLayoutTransaction` via the real drag route, or `applyProgrammaticTileGeometry` for a tile), then `flushPendingArmingSave()`. Remount from disk with no `flushMountedWorkspaceState`. Assert disk doc zones == live zones, and assert the member world frames of every moved zone moved by exactly the zone's delta.
5. **Clean quit-equivalent.** Run `flushMountedWorkspaceState()` and remount. Assert S == S_expected.

**Global outcome assertions**, checked after every phase:
- No two zone rects intersect.
- Every member tile's world frame is contained in its zone's `zoneWorldFrame`.
- The disk document for workspace X contains only zones X owns.

**Positive control.** In the same leg, deliberately `commitZonePlacement` a zone by +137 on x without moving its tiles. The containment assertion must fire (catch the failure and expect it). Separately, a legitimate rigid zone drag must pass. This proves the containment and overlap predicates have teeth.

**Teeth-verify.** Run the leg against HEAD and confirm phases 1, 2 and 4 are RED before any fix.

## Fix plan

Each item lists the change, then its risk and the witnesses it touches.

1. **Arming controller identity (critical, small).**
   - Change: in `switchWorkspace`, after the departing flush at `:1495`, set `armingSaveController = nil`. Better, bind the scheduled write to `(workspaceId, document)`, or route arming through `saveWorkspaceDocument(document, workspaceId: self.workspaceId)` with a debounce keyed by workspace.
   - Also: make the arming write merge only `lastActiveZoneId` into the *current* in-memory document at fire time, not a stale snapshot. Simplest: have the timer call `persistWorkspaceDocument()` reading `self.document` when it fires, instead of holding `pendingDocument`.
   - Risk: low.
   - Witnesses: `--zone-arming-check` stays green; add phase 2.
2. **Single in-memory document authority.**
   - Change: `persistLayoutTransaction` must mutate `workspaceRuntime.document` (a new `commitLayoutTransaction(_:)` on the runtime) instead of `store.load()` + `replaceDocument`. That is the doctrine `commitZonePlacement` already states (`WorkspaceRuntime.swift:105-108`).
   - Also: extend `persistDepartingWorkspaceState` to overlay ambient tile W frames from the mounted ambient layers.
   - Risk: medium. The rollback path currently restores disk project canvases, and a failure must also roll back the in-memory document.
   - Witnesses: `--ambient-tile-frame-space-check`, `--canvas-undo-check`, `--zone-move-unified-check`.
3. **Ghost zones are immovable, or they carry their tiles.**
   - Change: in `autoLayoutScene()`, exclude from `peers` (or mark as fixed obstacles) any zone with no installed layer. The alternative is pushing a ghost's persisted W frames through the persistence merge in the same transaction. The minimal correct fix is to treat unhydrated zones as immovable obstacles in `resolveOuterCollisions` and to refuse a direct drag of a ghost zone, or to hydrate it on grab.
   - Longer term: install layers lazily on tier promotion. Today below-tier zones never get tiles until the next switch, which is its own visible bug.
   - Risk: medium (jelly semantics).
   - Witnesses: `--jelly-auto-layout-check`, `--zone-tier-transition-check`, `--zone-hydration-lifecycle-check`, `--zone-lazy-resume-check`.
4. **Reinstall is not a spawn.**
   - Change: add a `reinstallProjectTile` (or an `arranges: false` parameter) used by `installBrowserSnapshotTile`, `restartBrowserTile`, `restartTerminalTile`, the file-tree restarts and the note restore. It swaps the view in place with no `growZoneOnSpawn` and no `arrangeAutoLayoutAfterSpawn`. At minimum, wrap `enforceBrowserRuntimeBudget()` and `reconcileHydration`'s `setTier` calls in `withAutoLayoutSuppressed`.
   - Risk: low. A reinstall reuses the tile's existing frame, so nothing needs arranging.
   - Witnesses: `--zone-tile-hydration-check`, and any browser budget or zone-hydration leg that asserts on zone size.
5. **Growth resolves peers** (policy decision for Dylan).
   - Change: after any non-drag zone growth (resize pressure, expand, grow-on-spawn, tidy), either run `resolveOuterCollisions` with the grown zone as active, or refuse or clip the growth. Once item 4 is in, only user-caused growth remains, so this may be deferrable.
   - Risk: medium. Pushing zones the user did not touch is itself a "change without my doing".
6. **Membership in the layer world.**
   - Change: port `reevaluateZoneMembership` to layer tiles (re-home by centre, break-out). Make the rescue in `resolveZoneMembership` prefer the nearest zone and grow it to contain, or leave the tile bare, instead of stamping home without containment.
   - Risk: medium.
   - Witnesses: `--zone-breakout-check`, `--workspace-scene-owner-check` (rescue assertions), `--zone-runtime-duplication-check`.
7. **Auto-layout off only.** `growZoneToFitMembers` must write `layer.placement` as well, or go through `mutateZonePlacement`. `setZoneAutoLayoutMode`'s `.immediately` tidy is a user act and is fine.

Separately, `--file-tile-zoom-check` needs its compositor threshold resolved so that its geometry assertion ("zoom must preserve every tile's world frame") actually runs.

## Commands run

The macOS sandbox has no `timeout` binary, so the first attempt exited 127 for every leg and ran nothing. The legs were re-run with the equivalent `perl -e 'alarm shift; exec @ARGV' 180`.

Environment for each leg: `env -u TMUX -u TMUX_PANE TMUX_TMPDIR=<mktemp -d /tmp/claude-501/tmx.XXXX> CONTINUUM_APP_SUPPORT=<mktemp -d /private/tmp/claude-501/o3legs/as.*> CONTINUUM_PROJECT_ROOT=<mktemp -d /private/tmp/claude-501/o3legs/pr.*>`. Binary: `.build/release/Array`, not rebuilt. Every flag was verified against the source flag list.

| Command | Exit | Result |
|---|---|---|
| `… Array --file-tile-zoom-check` | 1 | `FAIL: title compositor drift; difference 2.439717294900222` (pixel difference, not geometry) |
| `… Array --workspace-switch-check` | 0 | passed; logs "repaired zone membership for 1 tile(s)" |
| `… Array --workspace-boot-persistence-check` | 0 | passed |
| `… Array --zone-tier-transition-check` | 0 | passed; logs a membership repair |
| `… Array --workspace-scene-owner-check` | 0 | passed ("every tile returned to the pixel it started on") |
| `… Array --zone-move-unified-check` | 0 | passed |
| `… Array --zone-arming-check` | 0 | passed. Single-workspace only; it never arms after a `switchWorkspace`, so it cannot see H-B1's cross-workspace write |

Some legs wrote their own manifests under `<repo>/qa-runs/2026-09-28T020449Z/…`; that is normal leg behaviour. Logs are in `/private/tmp/claude-501/o3legs/*.log`.
