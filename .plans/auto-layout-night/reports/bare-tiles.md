# Drag a tile out of its zone and have it stay out

Date: 2026-11-09. Branch: array/bare-tiles (local, not pushed, not merged).
Base: ceb37f6c (array/auto-layout-night).

## Outcome

Stopped at the witness and this design, as the brief allows when fix A is
much bigger than it looks. Nothing in production code changed.

What it is: a project tile cannot be bare in the layered canvas today.
Why it happened: since the mount fix (599126a2) every project tile lives in
some zone's `ZoneLayer`; the flat scene that held bare tiles is retired at
mount. There is no place for a dropped-outside tile to go, so it keeps its
stamp, and everything that settles a zone pulls it back.

Commit: e2c1f42a test(canvas): witness a tile dragged out of its zone staying bare

## The witness: --bare-tile-check (red at e2c1f42a)

Real drag through `NSApp.sendEvent` (key window, first-mouse swizzle,
focus monitor installed, offscreen), note A1a dragged by world
(-840, +1220) to (-200, 1500), clear of every zone. Both auto-layout modes.
After each step it checks on-screen membership, on-screen WORLD frame, and
`canvas.json`'s `zoneId` and WORLD frame:

1. the drop
2. auto layout off then on (the settings notification production posts)
3. zone A1 dragged by its header, -150 x
4. quit and remount (`WorkspaceInvariantsFixture.remount`)
5. drag back in: adopted by zone A1, stamped, inside its world rect

Red result, 30 failures, matching Dylan's report exactly:
- auto layout off: lands at (-200,1500) but stays a member of A1; the
  off-to-on toggle pulls it to (952,488).
- auto layout on: the drop itself is pulled back to (672,480).
- both: the zone move carries it; after remount it is still in A1.
Step 5 passes trivially today (the tile never left).

Not yet in run-matrix.sh: a red leg would add an unexplained failure.
Register it when it turns green.

## Why fix A is bigger than it looks

`CanvasNSView.swift` is 15,046 lines and names `zoneLayers` 125 times:
46 lookups by zone id, 38 enumerations, 10 tile lookups. Each answers
either "a zone" or "where a tile lives". A bare tile needs the second
without the first. Every site must be classified; one wrong answer either
loses an operation on bare tiles (close, resize, focus, z-order, selection,
sidebar, navigation) or writes a phantom zone id into `canvas.json`.
`WorkspaceRuntime` adds 7 layer call sites (build, park, hydrate, switch).

Two homes were weighed:

(a) Revive the flat `canvasState.tiles` for bare tiles, with a
tileId-to-project map. Rejected: about 25 `flatCompatibilitySceneActive`
gates, closed by the confidence pass, would each reopen, and it brings back
the two-model hazard 9 describes.

(b) Recommended: one bare layer per mounted project. A `ZoneLayer` with
`isBare = true`, origin (0,0), so local frames are world frames. It is never
a live zone and has no chrome.

## Design (b), in landing order

Each phase keeps the build green and the witness at least as red as before.

### Phase 1: the model (Core, pure, CoreChecks)
- `resolveZoneMembership` rule 2: a nil stamp whose centre is outside
  every zone of this project stays bare (new `bare` bucket); a nil stamp
  inside a zone is still rescued into it. Rule 4 (never drop) and rule 5
  (never move) hold. CoreChecks cases for both.
- `mergeProjectTilesForPersistence`: a nil-stamped persisted tile is
  covered when the project's bare layer is installed (new
  `bareCovered: Bool`), so a deleted bare tile stays deleted. Today a
  nil-stamped tile can never vanish from the file.
- No new persisted field. `tile.zoneId` is already classified
  `.exposed(.canvasApply)` in `WorkspaceAPIExposure`.

### Phase 2: the bare layer (CanvasNSView)
- `ZoneLayer.isBare`; `bareLayer(forProjectId:)`, created on demand.
- Kept OUT of the zone surfaces: `setZones` / `upsertZoneLayer` (7446,
  7600) never put it in `liveZones` or chrome; `installedZoneIds` (8213),
  `projectId(forZone:)` (8270), arming, `zoneId(containing:)`, sidebar zone
  rows and API zone listings skip it.
- Kept IN the tile surfaces: `tileView(for:)` (2552), `tileRecord(for:)`
  (8139), `allTilesInWorldFrames` (8121), `tilesInWorldFrames(forProjectId:)`
  (8170), `navigationTileSnapshots` (6229), `removeTile` (3493),
  `layoutAllTiles` / `_layoutLayerTile` (6615, 8556), capture/commit geometry.
- Stamp writers emit nil for it: `autoLayoutScene` (506) gives its tiles
  `zoneId: nil`, so the engine treats them as bare peers (zones push them,
  tidy never targets them; this is already the engine's rule);
  `persistLayoutTransaction` (ContinuumApp 21756) writes nil;
  `tileZoneMembership` has no entry.
- Zone moves (`applyConcreteZonePlacement`, 257) never touch it.

### Phase 3: the gestures
- Break-out in `reevaluateLayerMembership` (2285): a drop whose centre is
  more than `ZoneBreakoutConfig` distance (48pt) outside its zone and
  inside no zone of the project moves the record to the bare layer at its
  exact WORLD frame (`transferLayerTile` generalised), then settles the
  old zone.
- Adoption: a bare tile dropped with its centre in a zone of its project
  transfers in (the same path the zone-to-zone transfer takes today).
- Into another project's zone: refused, as today; the tile stays bare.

### Phase 4: load, park, hydrate (WorkspaceRuntime, ContinuumApp)
- `makeProjectZoneLayer` (1671) siblings: build the bare layer from the
  `bare` bucket for every mounted project, whatever the live hydration
  tier. A bare tile has no zone to be below the tier of.
- Park and restore it with its project's layers on workspace switch.
- Hydrate it through `hydrateZoneLayerTiles` (24125), Phase A and B,
  resolving through `controller(for: projectId)`.

### Phase 5: green the witness, then the regression set
Register `--bare-tile-check` in run-matrix.sh and the inventory. Run the
offscreen legs: zone-arming, auto-layout-fanout-app, spawn-framing,
spawn-placement, canvas-undo, workspace-scene-owner, zone-runtime-duplication,
zone-truth legs, workspace-api-open, workspace-api-exposure, the persistence
merge CoreChecks, canvas-pointer-path.

## Risks to watch
- Phantom stamp: any enumeration that treats the bare layer as a zone
  writes its synthetic id into `canvas.json`. Guard: a CoreChecks-level
  assertion that no persisted tile ever names a zone absent from the
  document, plus the witness's persisted-`zoneId` checks.
- A tile with nowhere to render: if the resolver buckets a tile bare but
  no bare layer is built (a project with no live controller), it is kept
  on disk but drawn nowhere. That is today's "deferred" behaviour; the
  witness's remount step catches the mounted case.
- Spawns never land bare: `installProjectTile` keeps refusing a nil zone.

## For the lead
- Fix A is a multi-phase change across about 100 sites in the canvas plus
  the runtime's layer lifecycle. It needs a daytime slot and review, not an
  unattended night. Dylan is AFK, and this sits on `canvas.json` writes.
- The red witness is ready to drive it. Phase 1 is pure and safe to do
  first.
- Not done here: no production change, no matrix registration.
