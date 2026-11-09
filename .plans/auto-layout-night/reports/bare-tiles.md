# Drag a tile out of its zone and have it stay out

Date: 2026-11-09. Branch: array/bare-tiles (local, not pushed, not merged).
Base: ceb37f6c (array/auto-layout-night).

## Outcome (updated 01:50)

Fix A is built and the witness is green. A tile dragged clearly outside
every zone becomes bare: its stamp is cleared on screen and in
`canvas.json`, and its WORLD frame is kept. It stays bare through an
auto-layout off-to-on toggle, a move of its old zone, undo and redo, and a
remount, with auto layout off and on. Dropping it back into a zone of its
project adopts it.

The lead's first stop note (below "Why fix A is bigger") still holds as the
risk statement; the lead chose to build it tonight on this isolated branch,
which never merges into array/auto-layout-night.

Commits (array/bare-tiles, local, not pushed, not merged):
- e2c1f42a test(canvas): witness a tile dragged out of its zone staying bare (red)
- 48b5005c docs(canvas): this design
- 11cb2b29 feat(canvas): let membership and persistence keep a bare project tile (Phase 1)
- f655189f feat(canvas): give bare project tiles a layer and let a drag break out (Phases 2-3)
- 5274378e feat(canvas): mount each project's bare tiles from its membership (Phase 4)
- 214578f5 test(canvas): cover undo of a drag out and register the bare tile leg (Phase 5)
- 1afdcbd2 docs(canvas): this report's build section and classification
- bd8a6c06 fix(canvas): mark a dragged-out tile bare so legacy tiles still rescue

Phases 2-3 and 4 were built and tested together, then committed apart.
f655189f alone was not built or run on its own; the tree at 5274378e was.

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


## What was built

### Phase 1 (11cb2b29), pure core, CoreChecks witnesses
- `resolveZoneMembership(keepsBare:)` (rule 6): a nil stamp whose centre is
  outside every zone of its project goes to a `bare` bucket, unstamped. A
  nil stamp inside a zone, and a foreign stamp anywhere, are still rescued.
  Default off. CoreChecks case 10 covers all three plus rule 4 (every tile
  in exactly one bucket) and the default-off behaviour.
- `mergeProjectTilesForPersistence(bareCovered:)`: with the project's bare
  layer installed, an absent nil-stamped tile was deleted. CoreChecks case 8.

### Phases 2-3 (f655189f), CanvasNSView
- `ZoneLayer.bare(projectId:)`: origin (0,0), size 0, a private zone id never
  written to a tile. `coversPersistedBareTiles` is true only when the runtime
  built it from resolved membership; one created on demand by a drag never
  lets the merge delete anything.
- Storage: `bareLayers`, held apart from `zoneLayers`. `tileLayers` is
  `zoneLayers + bareLayers` for tile surfaces. A missed site therefore costs
  a missing operation on a bare tile, never a phantom zone stamp.
- Break-out: `reevaluateLayerMembership` moves a record whose centre is in no
  zone and at least `ZoneBreakoutConfig` (48pt) past its zone's edge into the
  bare layer, then settles the zone it left.
- Adoption: a bare record dropped with its centre in a zone of its project
  transfers in (`transferLayerTile` now accepts a bare source).
- Auto layout: bare tiles enter the scene with `zoneId: nil`, so the engine
  treats them as bare peers (zones push them, settle and tidy never target
  them).
- Commit: `CanvasLayoutTransaction.bareTileIds` (Core); the app's
  `persistLayoutTransaction` clears the stamp for those tiles.
- Undo/redo: `applyGeometrySnapshot` transfers a tile back into its zone, or
  back out to bare, when the snapshot's stamp differs from where it lives.
- Stacking: bare tiles rank above every zone's tiles. Hit-test checks bare
  layers first. Navigation snapshots include them with no zone.

### Phase 4 (5274378e), WorkspaceRuntime
- `membership(forProject:)` resolves with `keepsBare: true` and returns
  `ProjectMembership { byZone, bare }`.
- `install(into:)`, `buildLayers` (switch) and `installZoneLayerIfMissing`
  build each mounted project's bare layer (even empty) and pass it in the
  same `layers` array as the zone layers. `setZones` and `upsertZoneLayer`
  route it to `bareLayers`; `parkZoneLayers` parks it with them; the
  hydration hook needed no change.

### Phase 5 (214578f5)
- `--bare-tile-check` gained undo/redo of the drag out, and is registered
  in run-matrix.sh beside `--canvas-pointer-path-check`; inventory updated
  (C locale, only this leg added).

## Classification of every layer use in CanvasNSView

Generated from the source at 5274378e (line numbers there). Z = zone-only,
bare layers stay out. T = tile surface, reads `tileLayers`. B = bare-specific.

Zone surfaces (Z), unchanged on purpose:
- Model B and chrome: rebuildLayerDerivedProjections (liveZones, tile
  membership), setZones, upsertZoneLayer, removeZoneLayer, _installLayer,
  setZoneChromeVisible, reorderTileSubviewsByZIndex (chrome order),
  allZonePlacements, zoneWorldBounds.
- Zone gestures and menus: mountedLayer, gestureRoutingMode, sameIDTopology,
  applyConcreteZonePlacement, registerConcreteUndo, mouseDragged (zone move,
  resize), zoneHeaderTarget, zoneResizeEdge, _zoneId, menu,
  changeZoneScopeFromMenu, toggleZoneCollapsedFromMenu, requestZoneScopeChange,
  toggleZoneAutoLayout, presentZoneColorPicker, applyZoneRename,
  fitZoneToViewport, setZoneAutoLayoutMode, setZoneScope,
  mutateZonePlacement, setZonePlacement, closeZone, growZone.
- Zone placement in transactions: applyLayoutTransaction (resolvedOrigin),
  applyGeometrySnapshot (zone origins and placements).
- Zone lookups and arming: zonePlacement, installedZonePlacement,
  activeProjectZonePlacement, setActiveProjectZone, projectId(forZone:),
  zoneId(containing:) (nil for a bare tile, which is the truth),
  installedZoneIds, tileIds(inZone:), tiles(inZone:),
  tilesInWorldFrames(forZoneId:), geometryTileIds(inZone:), moveLayerTiles,
  transferLayerTile (destination), applyProgrammaticTileGeometry (the API
  names a zone), installProjectTile (spawns never land bare).
- Sharing: lendableTile, lendTilesToSharedArea, returnLentTiles (a bare tile
  cannot be lent: lending needs a home zone).
- Hit-test per zone: tileId(at:) zone branch (bare checked before it).
- Autolayout zone list: autoLayoutScene placements.
- QA: qaInstalledLayerZoneIds, qaZoneLayerPlacement.

Tile surfaces (T), now read `tileLayers`:
- Lookup: tileView(for:), tileRecord(for:), allWorkspaceTiles,
  allTilesInWorldFrames, tiles(forProjectId:), tilesInWorldFrames(forProjectId:)
  (persistence), worldFrame(forTileFrame:), tileFrame(fromWorldFrame:).
- Mutation: updateTile, applySelectionFrames, removeTile, setBrowserURL,
  materializeProjectTile (Phase B hydration), transferLayerTile (source),
  reevaluateZoneMembership.
- Geometry: applyLayoutTransaction (tile occurrences), captureGeometry,
  applyGeometrySnapshot (tile frames and transfers).
- Layout and views: layoutAllTiles, refreshRunArtifactsTiles,
  updateDocumentRelationshipOverlay, restAgentChromeForCameraMotion,
  appDidResignActiveForOverlays, cancelActiveGeometryCapture.
- QA counters: qaTotalInstalledTileCount, qaTileScreenFrameMismatchCount,
  qaTilesIntersectingViewport.

Bare-specific (B): autoLayoutScene (nil-zone peers), tileId(at:) (bare
first), navigationTileSnapshots, reorderTileSubviewsByZIndex (rank above
zones), canvasStateForPersistence (bareCovered), setZones / parkZoneLayers
(install, park), installBareLayer, bareLayer(forProjectId:),
hasResolvedBareLayer, bareTileIds, transferLayerTileToBare.

Outside CanvasNSView: WorkspaceRuntime builds, parks and hydrates the bare
layer with the zone layers. SidebarTree and SharedAreaInventory still call
the resolver with keepsBare off (see Open).

## The bare marker (bd8a6c06), found by the sweep

What it is: `--workspace-runtime-install-check` failed ("zoneB layer should
contain noteB"). Its note has never been stamped (nil `zoneId`, the legacy
shape) and sits outside its zone, so the first design left it bare.
Why it happened: a nil stamp alone cannot tell "dragged out" from "never
stamped". In real data every legacy unstamped tile outside its zone would
have floated free of its project on the next mount.

Fix: `Tile.isBare`, persisted as `"bare": true` only when set (every
existing canvas.json decodes unchanged). A break-out sets it, an adoption
or a rescue clears it. The resolver keeps a tile bare only when it is
marked, and the merge deletes only marked tiles. Classified in
`WorkspaceAPIExposure` as `tile.bare: notExposed` (the exposure audit
passes, 127 keys). CoreChecks gained the legacy case in both sections, and
`--bare-tile-check` now asserts the mark on disk after a drag out and its
absence after a drag back in.

## Checks on the final tree (bd8a6c06)

All offscreen, each with its own CONTINUUM_APP_SUPPORT and TMUX_TMPDIR,
ARRAY_AGENT_ID unset, managed-agent marker inherited, stdin /dev/null.

- `--bare-tile-check`: exit 0, both auto-layout modes, every step.
- Regression set: zone-arming, workspace-scene-owner, spawn-framing,
  spawn-placement, canvas-undo, auto-layout-fanout-app,
  canvas-persistence-model, zone-runtime-duplication, workspace-runtime-install,
  helper-tile-lifecycle, helper-tile-auto-fold: all exit 0.
  CoreChecks `--unreadable-canvas-store-check`: exit 0.
- Full CoreChecks (isolated tmux, socket path verified): exit 1 on one line
  only, "bridge concurrency: turn completes" (a 15 s wait in the pi host
  bridge, unrelated, load). Membership, merge and exposure sections pass.
- Sweep over zones, tiles, layout, workspace, persistence and sharing,
  offscreen: batch 1 ran 44 app legs before the marker (39 exit 0), batch 2
  ran 34 after it (32 exit 0): zone-breakout, zone-layer-move, zone-close-*,
  zone-tier-transition, workspace-switch*, workspace-restart-fault,
  stranded-tile-recovery, shared-area-zone and tile-insert-slide among them.
  Of batch 1's five failures: the two helper-tile legs needed the
  array-workspace-mcp product built and then passed;
  workspace-runtime-install found the marker bug and passes after it; the
  other two are below.
- Failures shared with the binary that has no bare-tile code (8ae82646),
  so not caused here: `--note-click-focus-check` ("keyDown should edit note
  text"), `--tile-reveal-work-check` (padding 16.00000000000002),
  `--tile-surface-residency-check` (idle display), and
  `--previous-focus-navigation-check`, which hangs on both binaries and was
  stopped by PID after 3 minutes.

## Found on the night branch, not caused here

`--subagent-tile-zone-check` fails on the night branch and on the
spawn-sizing binary alike: "the first child must open docked beside its
parent (2112, 880) 576x640; got (2112, 1528) 576x316". The lead is now
576x640 (stream 3's new agent default) and its half-height helper docks
below it instead of to its right, probably because `visibleSpawnSlot`
picks the free slot nearest the lead's centre, which is below once the
lead is taller than wide. Stream 3 (mine) missed it: the leg was not in
that stream's check list. Helper geometry belongs to Stream 1, so it is
left for the lead.

## Open

- Sidebar: `SidebarTree` resolves membership with keepsBare off, so a bare
  tile is listed under its project's home zone. Display only; nothing
  persists from it. Turning it on needs a sidebar row for zoneless tiles.
- Workspace API: `canvas.apply` with an explicit zone still requires a zone;
  the API cannot make a tile bare. Not asked for.
- A bare tile cannot be lent to a shared area.
- A project whose zones are all below the live hydration tier has no bare
  layer, so its bare tiles are kept on disk but not drawn until a zone of it
  goes live. That matches how its zone tiles behave.
