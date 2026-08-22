# 41 — Zone lifecycle, navigation truth, and cleanup

Date: 2026-08-22

Status: **brainstorming / architecture discussion draft.** No implementation has
started. This document records the current system, the bugs found during a
four-agent read-only investigation, and several repair shapes. It is not yet a
ticket breakdown or an approved migration plan.

Repository state while investigating: `main` at `736cb93`, clean checkout. The
findings below come from the current checkout, not another agent's worktree.

## Why this exists

A closed zone remained in Cmd+K and could still be selected. Separately, tile
jumps have sometimes landed at what looked like an earlier location. Source
inspection found deterministic paths for both reports. They are two symptoms of
the same architectural problem:

> Array has more than one in-memory representation of the current zones and
> tiles, but navigation and close do not consistently consult or invalidate the
> representation that currently owns the UI.

The problem is broader than a stale menu row, but the repair should remain
focused: establish one authoritative *current scene* for zone/tile identity and
geometry, then make close and navigation go through it.

---

# Part I — Current architecture

## 1. Persistent ownership

### Workspace document

`WorkspaceDocument` owns workspace-level state:

- zone placements and z-order;
- `lastActiveZoneId`;
- workspace viewport;
- ambient/group-zone tile storage.

Relevant code:

- `Sources/ContinuumRevivedCore/WorkspaceDocument.swift`
- `Sources/ContinuumRevivedCore/WorkspaceStore.swift`
- `Sources/ContinuumRevived/App/WorkspaceDocumentSaveController.swift`

### Project canvas

A project's `.array` state owns its project tiles and canvas state. Project
tiles survive closing a workspace zone because the tiles belong to the project,
not to the zone view.

Relevant code:

- `Sources/ContinuumRevivedCore/CanvasState.swift`
- `Sources/ContinuumRevived/App/ZoneRuntimeController.swift`

## 2. Canvas compatibility model

`CanvasNSView` still carries the original single-project model:

- `canvasState.tiles` — flat tiles with **world-space** frames;
- `liveZones` — mutable zone placements seeded at initialization;
- `tileZoneMembership` — flat tile ID → zone ID;
- `zoneRenderModels` — initialization/display models;
- `zoneDisplayByZoneId` — display metadata keyed by zone ID.

`liveZones` is documented as the mutable authoritative placement for this path.
`zoneRenderModels`, however, remains a separate stored array.

Relevant code:

- initialization and seeding: `CanvasNSView.swift:1140-1208`;
- membership seeding: `CanvasNSView.swift:1266-1290`;
- fields and ownership comments: `CanvasNSView.swift:80-150`.

## 3. Workspace runtime model

`WorkspaceRuntime` installs the active workspace as `CanvasNSView.ZoneLayer`s.
Each layer owns:

- a `ZonePlacement`;
- a `ZoneRenderModel`;
- zone-owned tile records;
- tile views and zone chrome.

Layer tiles use **zone-local** frames. Their rendered/navigation world frame is:

```text
world frame = zone-local tile frame + zone placement origin
```

`WorkspaceRuntime.install` and `switchWorkspace` build layers from persisted
workspace/project state and call `CanvasNSView.setZones`.

Relevant code:

- `WorkspaceRuntime.install`: `WorkspaceRuntime.swift:163-275`;
- workspace switch layer construction: `WorkspaceRuntime.swift:600-680`;
- `ZoneLayer` and `setZones`: `CanvasNSView.swift:4980-5040`;
- local→world projection: `CanvasEngine.worldFrame`.

## 4. The split after `setZones`

`setZones` replaces `zoneLayers`, but deliberately does **not** replace
`canvasState.tiles` or `liveZones`. The source now explicitly warns that the
flat array may describe the departed workspace:

- `CanvasNSView.swift:5171-5178` (`tileRecord` ownership warning);
- `CanvasNSView.swift:5227+` (stale flat spawn warning);
- `AGENTS.md`, hazard 9.

This means the canvas can simultaneously contain:

```text
flat compatibility state              installed workspace state
------------------------              -------------------------
canvasState.tiles (WORLD)             zoneLayers[].tiles (ZONE-LOCAL)
liveZones                             zoneLayers[].placement
zoneRenderModels                      zoneLayers[].renderModel
possibly departed project             current workspace/project
```

Some APIs are already layer-aware (`tileRecord`, `projectTiles`,
`installProjectTile`). Others still read flat or boot-time state first.

## 5. Navigation model

Cmd+K does not hold a live query. Opening it builds a snapshot of rows:

- tile rows from `CanvasNSView.navigationTileSnapshots()`;
- zone rows from `CanvasNSView.navZoneRenderModels`;
- rows are stored in `LaunchProfilePalette.rootRows` and filtered locally.

Relevant code:

- row construction: `ContinuumApp.swift:7490-7575`;
- palette snapshot: `LaunchProfilePalette.swift:59-70`;
- tile snapshots: `CanvasNSView.swift:4094-4119`;
- zone source: `CanvasNSView.swift:3670`.

A tile snapshot contains durable ID, title, kind, current world frame, and zone
ID. The intended design is good: every navigation surface should consume the
same projected snapshot. The flaw is which backing model wins when building it.

## 6. Current close lifecycle

A zone close begins in `CanvasNSView` chrome and is confirmed by `AppDelegate`:

```text
zone close button
  → onZoneCloseRequested(zoneId)
  → AppDelegate confirmation
  → CanvasNSView.closeZone(zoneId, keepTiles)
  → onZoneClosed(zoneId)
  → AppDelegate.persistClosedZone(zoneId)
```

Intended semantics:

| Zone type | Keep Tiles | Delete Tiles |
|---|---|---|
| Group/ambient | Remove zone; spill members to bare canvas | Remove zone and member tiles |
| Project | Remove zone; retain project tiles | Remove zone; still retain project tiles |

Project tiles are never destroyed by closing the zone view.

`persistClosedZone` removes the zone from `WorkspaceDocument`, repairs
`lastActiveZoneId`, clears ambient tiles for that zone, flushes, updates
`WorkspaceRuntime.document`, and reloads the sidebar.

Relevant code:

- in-memory close: `CanvasNSView.swift:1449-1473`;
- confirmation/persistence: `ContinuumApp.swift:12494-12537`.

---

# Part II — Confirmed bugs and gaps

Labels:

- **[confirmed]** deterministic from the current source;
- **[high-confidence]** complete source chain, needs an executable witness before
  claiming end-to-end behavior;
- **[gap]** absent ownership or test coverage rather than a reproduced bug.

## A. Closed zones remain Cmd+K destinations — [confirmed]

`closeZone` removes the zone from `liveZones`, but not from
`zoneRenderModels`. `navZoneRenderModels` is a direct alias of the unchanged
`zoneRenderModels` array. Cmd+K builds zone rows from that alias.

Selecting the stale row succeeds because `jumpToZoneFromPalette` validates
against the same stale array. `fitZoneToViewport` then prefers the stale
`zoneRenderModels` placement before checking live/layer placements.

Path:

```text
closeZone
  removes liveZones entry
  leaves zoneRenderModels entry

open Cmd+K
  navZoneRenderModels == zoneRenderModels
  stale zone becomes JumpZoneRow

select stale row
  guard checks stale navZoneRenderModels → passes
  fitZoneToViewport checks stale zoneRenderModels first
  camera moves to closed zone's old frame
```

Evidence:

- `CanvasNSView.swift:1453-1472`;
- `CanvasNSView.swift:3670-3676`;
- `ContinuumApp.swift:7541-7543`;
- `ContinuumApp.swift:12400-12409`.

This directly explains the observed stale zone row and successful jump.

## B. Close does not close a ZoneLayer — [confirmed]

Production workspace zones are installed through `setZones`, but `closeZone`:

- searches only `liveZones`;
- collects members only from flat `canvasState.tiles`;
- never calls `removeZoneLayer`;
- never releases a project controller/reference;
- never unregisters tile adapters belonging to that layer.

Conversely, `removeZoneLayer` removes views/adapters but does not mutate
persistence or apply keep/delete semantics.

The lifecycle is split across two methods with no shared owning operation.

Evidence:

- `CanvasNSView.swift:1453-1472`;
- `CanvasNSView.swift:5065-5077`;
- `WorkspaceRuntime.swift:163-299`.

Possible outcomes depend on which representation the clicked chrome belongs to:

- silent no-op if the ID exists only in `zoneLayers`;
- persistent document deletion while a layer remains installed;
- layer tiles remain navigable after the zone placement is removed;
- group keep/delete semantics apply only to flat members.

## C. Tile navigation includes departed flat tiles — [confirmed]

`setZones` leaves `canvasState.tiles` intact. `navigationTileSnapshots()` then
enumerates flat tiles first and layer tiles second, deduplicating by UUID.

Therefore:

1. departed-workspace flat tiles can remain navigation candidates;
2. if a current layer contains the same tile UUID, the stale flat record wins;
3. the stale world frame shadows the current layer's projected world frame.

Evidence:

- `CanvasNSView.swift:5009-5040`;
- `CanvasNSView.swift:4094-4116`;
- `CanvasNSView.swift:5171-5178`.

This is a direct mechanism for jumping to a tile's previous location.

## D. Zone navigation remains tied to boot models after switching — [confirmed]

`WorkspaceRuntime.switchWorkspace` replaces layers but does not update
`zoneRenderModels`. Comments already acknowledge that `zoneRenderModels` can be
stale after a switch (`CanvasNSView.swift:4022-4029`). Navigation nevertheless
uses it.

Consequences:

- departed zones remain offered;
- arriving zones may be absent from Cmd+K and leader assignments;
- a real arriving layer can be fit by `fitZoneToViewport`, yet rejected before
  that by the palette guard because it is absent from `navZoneRenderModels`.

## E. Stale `lastActiveTileId` can reactivate an old location — [confirmed]

`setZones` does not replace `canvasState.lastActiveTileId`. A canvas-focus
fallback does not clear it. “Focus Current Tile” / hold-Option Return reads that
scalar and validates it using the contaminated navigation snapshot.

The old ID can therefore remain actionable after a workspace switch.

Evidence:

- `CanvasNSView.swift:5009-5040`;
- `WorkspaceRuntime.swift:850-865`;
- `ContinuumApp.swift:6742-6747`.

## F. A stale navigation action may cross a persistence boundary — [high-confidence]

The source chain is:

```text
tile jump
  → setViewport
  → CanvasDelegate.canvasDidChange
  → active ZoneRuntimeController schedules canvas save
  → controller snapshots canvasView.canvasState
```

After `setZones`, `canvasView.canvasState` can still describe the departed
project while the active controller belongs to the arriving project. A
camera-only navigation action could therefore save the departed flat model
through the arriving project's store.

Evidence:

- jump/reveal: `ContinuumApp.swift:12310-12322`;
- viewport change notification: `CanvasNSView.setViewport`;
- delegate save scheduling: `ContinuumApp.swift:13641-13648`;
- controller snapshot/save: `ZoneRuntimeController.swift:599-628, 665-673`.

This must receive a RED witness before implementation. It is more severe than a
camera bug if confirmed end to end.

## G. Palette contents do not live-invalidate — [gap]

`LaunchProfilePalette.show` materializes `rootRows`. Search only filters that
snapshot. There is no subscription for zone/tile removal while the palette is
open.

This is secondary to the backing-model bug: reopening the palette should always
rebuild cleanly. Still, a captured stale row should fail safely without moving
the camera, changing focus/history, or entering recents.

## H. Hydration and inactive-zone reachability are underspecified — [gap]

Only live-tier zones receive installed project layers. Navigation indexes
installed layers, so snapshot/cold zones may not expose their tiles. There is no
clear “select result → hydrate zone → resolve tile → jump” contract.

This does not need to block the stale-state repair, but the authoritative scene
API must define whether it represents:

- only installed/reachable entities; or
- every persistent entity, with asynchronous activation before navigation.

---

# Part III — Why current checks stayed green

## Zone close witness

`--zone-close-keep-delete-check` proves:

- a real close-button click reaches `closeZone`;
- flat group Keep spills a tile;
- flat group Delete removes a tile;
- project Delete retains the project tile.

It does not assert:

- `navZoneRenderModels` after close;
- Cmd+K rows or dispatch after close;
- removal of a `ZoneLayer`;
- layer-owned tile semantics;
- controller release;
- persisted reload;
- stale history/recents/focus cleanup.

## Navigation witnesses

Current tile and zone jump checks predominantly use flat canvases. They do not
combine:

1. nonempty workspace A flat state;
2. a switch to workspace B;
3. B tiles installed in a layer with a nonzero zone origin;
4. duplicate IDs or departed A-only IDs;
5. a jump followed by inspection of both project stores.

The file-opening check does cover correct layer-aware installation and
persistence, but only for that explicit route. It is not evidence that general
navigation or canvas saving uses the right owner.

---

# Part IV — Repair shapes considered

## Option 1 — Patch each stale array

On close, remove the zone from `zoneRenderModels`; on switch, replace
`zoneRenderModels`; make tile snapshots enumerate layers first.

**Advantages**

- smallest diff;
- likely removes the two visible symptoms quickly.

**Problems**

- preserves mirrored mutable state;
- every future mutation must remember to update every copy;
- does not solve close ownership/controller cleanup;
- does not establish safe persistence ownership;
- “layers first” still leaves ambiguous flat eligibility.

**Assessment:** useful as an emergency patch, poor target architecture.

## Option 2 — Keep both storage models, add one authoritative scene projection

Introduce one current-scene projection owned by `CanvasNSView` (or a small core
adapter) that resolves zones and tiles from their actual owners.

Conceptually:

```swift
struct CurrentCanvasScene {
    let zones: [NavigableZone]
    let tiles: [NavigableTile]
}

struct NavigableZone {
    let id: UUID
    let placement: ZonePlacement
    let displayName: String
    let owner: ZoneOwner
}

struct NavigableTile {
    let id: UUID
    let worldFrame: TileFrame
    let zoneId: UUID?
    let owner: TileOwner
}

enum ZoneOwner {
    case flat
    case layer(UUID)
}

enum TileOwner {
    case flat
    case layer(zoneId: UUID, projectId: UUID?)
}
```

Rules:

1. Installed layers are authoritative for IDs they own.
2. Flat state participates only when the compatibility path is currently active,
   never merely because records remain in `canvasState.tiles`.
3. World projection happens once at this boundary.
4. Cmd+K, leader labels, previous navigation, hit testing, focus validation, and
   sidebar actions consume this projection.
5. Mutation routes resolve an owner before acting.

**Advantages**

- focused refactor rather than full storage migration;
- makes stale flat eligibility explicit;
- creates one identity/geometry contract for all navigation;
- allows checks to inspect ownership.

**Problems**

- compatibility and layer models still coexist beneath it;
- persistence writes must also become owner-aware;
- close needs a runtime-level transaction, not only a projection.

**Assessment:** recommended near-term architecture.

## Option 3 — Finish the ZoneLayer migration

Eliminate the flat compatibility model after boot by adopting the active project
fully into a layer and replacing direct `canvasState` reads throughout the app.

**Advantages**

- one model and one coordinate convention;
- strongest long-term simplification.

**Problems**

- very large blast radius (`canvasState.tiles` has many callers);
- live terminal/browser/agent reconstruction and persistence are not yet fully
  layer-native;
- likely entangles unrelated spawning, hydration, residency, and runtime work.

**Assessment:** plausible destination, too broad for this bug repair.

---

# Part V — Recommended architecture

Adopt **Option 2** now: one authoritative current-scene projection plus one
runtime-owned close transaction.

## 1. Current scene is the only navigation source

Replace direct navigation reads of `zoneRenderModels`, `liveZones`,
`canvasState.tiles`, and `zoneLayers` with APIs such as:

```swift
func navigationScene() -> CanvasNavigationScene
func navigationTileSnapshot(for id: UUID) -> NavigationTileSnapshot?
func navigationZoneSnapshot(for id: UUID) -> NavigationZoneSnapshot?
```

The scene decides whether flat state is active. Callers do not decide precedence.

Invariant:

> One durable ID appears at most once, from the model that currently owns it.

## 2. Display metadata follows identity, not stored boot arrays

A navigation zone snapshot should combine:

- current placement from `liveZones` or `ZoneLayer.placement`;
- display metadata from `zoneDisplayByZoneId` or `ZoneLayer.renderModel`.

`zoneRenderModels` should become initialization input or be removed from runtime
navigation. It must not remain a competing placement source.

## 3. Close is a workspace-runtime transaction

The app should ask `WorkspaceRuntime` to close a zone, because the runtime owns:

- the current `WorkspaceDocument`;
- installed layers;
- project controller references;
- the canvas attachment;
- persistence coordination.

Possible shape:

```swift
func closeZone(
    id: UUID,
    disposition: ZoneCloseDisposition
) throws -> ZoneCloseResult

enum ZoneCloseDisposition {
    case keepTiles
    case deleteTiles
}
```

The operation should:

1. Resolve the zone and its owner.
2. Determine project versus ambient semantics.
3. Apply group keep/delete or project retention.
4. Update the correct tile store.
5. Remove/unregister the layer/chrome/views.
6. Release the project controller if this was its last workspace reference.
7. Remove the zone from `WorkspaceDocument` and repair active-zone selection.
8. Flush persistence.
9. Repair current tile, focus scope, nav selection, and history.
10. Publish/rebuild the navigation scene.

The canvas close button should request this transaction rather than independently
mutating one representation and notifying persistence afterward.

## 4. Camera state and tile state must persist through their owners

A viewport mutation should update workspace viewport ownership. It must not cause
an active project controller to snapshot a stale compatibility `canvasState`.

At minimum, saving must choose among:

- workspace viewport/document save;
- flat active-project canvas save, only when flat owns the active project;
- layer/project tile save through the layer's project store.

A camera-only change should not rewrite unrelated tile membership or replace a
project's tile collection.

## 5. Stale actions fail without side effects

Even with correct rebuilding, palette rows are snapshots. Dispatch must re-resolve
ID against the current scene.

A missing target must produce:

- `false` result;
- no viewport mutation;
- no focus/history/nav-selection mutation;
- no recent entry;
- palette may remain open or communicate that the item disappeared.

## 6. History stores IDs but validates through current scene

`FocusHistory` may continue storing durable IDs. Every restoration route must
validate through the authoritative scene and prune invalid entries. Closing a
zone should explicitly clear or invalidate:

- `navSelectedZoneId` when it matches;
- remembered tile-by-zone entries;
- previous-zone entries that no longer resolve;
- stale current tile if its owner disappeared.

---

# Part VI — Proposed implementation sequence

This is a brainstorming order, not yet an approved set of tickets.

## Step 0 — Capture RED behavior

Before changing production code, add deterministic witnesses for:

### Close → Cmd+K

1. Create a valid zone and tile.
2. Confirm it appears in navigation rows.
3. Close it through the real close callback.
4. Rebuild/open Cmd+K.
5. Assert the zone row is absent.
6. Dispatch a previously captured row and assert no camera/focus/history/recent
   side effects.

### Layer-owned close

Exercise group Keep, group Delete, and project retention with a real `ZoneLayer`.
Assert:

- layer removed;
- adapters unregistered;
- tile records stored/deleted through the correct owner;
- project tiles retained;
- closed IDs absent from navigation.

### Previous-location tile jump

1. Workspace A has a nonempty flat canvas.
2. Switch to workspace B with a layer at a distinct nonzero origin.
3. Include an A-only ID and optionally a duplicate ID in B.
4. Assert navigation excludes A-only and projects the duplicate from B.
5. Jump and inspect exact viewport/focus destination.

### Persistence boundary

Snapshot project stores before and after a camera-only jump in B. Assert:

- B does not receive A's tiles;
- A is unchanged;
- only intended viewport/document state changes.

These are the acceptance criteria. Existing expectations should not be edited to
make a proposed implementation pass.

## Step 1 — Introduce current-scene projection

- Add zone snapshots alongside tile snapshots.
- Encode owner/coordinate provenance internally or in QA-only fields.
- Define flat eligibility explicitly.
- Make duplicate-ID resolution deterministic and layer-authoritative.

## Step 2 — Migrate navigation consumers

Move these to the current scene:

- Cmd+K tile and zone rows;
- tile and zone jump validation;
- leader tile/zone assignments;
- previous tile/zone restoration;
- sidebar navigation if still reachable in checks;
- focus/current-tile validation.

No consumer should read `navZoneRenderModels` as a placement source afterward.

## Step 3 — Move close into `WorkspaceRuntime`

- resolve zone owner;
- apply keep/delete policy;
- remove layer and adapters;
- release controller references;
- update document and project/ambient stores;
- repair selection/focus/history;
- flush once at the transaction boundary.

Keep the current product semantics unless Dylan changes them: “Delete Tiles” on
a project zone still retains project tiles.

## Step 4 — Separate viewport persistence from stale flat tile persistence

Audit `canvasDidChange` and `ZoneRuntimeController` save scheduling. Ensure a
camera change cannot serialize a model that does not belong to the active
controller.

## Step 5 — Decide hydration behavior separately

After current live-zone correctness is green, decide whether Cmd+K should list
cold/snapshot tiles. Do not silently expand this repair into hydration work.

Possible later contract:

```text
select cold tile
  → identify persistent zone
  → hydrate/install owner
  → re-resolve tile in current scene
  → jump only after successful resolution
```

---

# Part VII — Acceptance criteria

The repair is complete when:

- Closing a zone removes it from every navigation surface immediately and after
  reopening Cmd+K.
- A captured stale zone/tile action cannot move the camera or mutate focus,
  history, recents, or persistence.
- Group Keep spills tiles; group Delete removes them; project close retains
  project tiles.
- Layer tile adapters/views/chrome and controller references are cleaned up.
- Workspace switching cannot expose departed tiles or zones in navigation.
- Duplicate tile IDs resolve to the currently installed owner and current world
  frame.
- A tile jump lands at the same frame the current scene renders/hit-tests.
- Hold-Option Return cannot reactivate a departed `lastActiveTileId`.
- A camera-only jump cannot write one project's tiles through another project's
  store.
- Relaunch reconstructs the same surviving zones/tiles and no deleted zone.
- New witnesses run through the matrix and are reported as executed.

Manual sanity after deterministic checks:

1. Create a group zone with two tiles.
2. Close with Keep; verify tiles remain and Cmd+K has no zone row.
3. Create another group zone; close with Delete; verify neither zone nor tiles
   appear in Cmd+K.
4. Switch between two workspaces with visually distant zones and similarly named
   tiles; jump repeatedly and verify every camera destination matches the visible
   tile.
5. Relaunch and repeat Cmd+K search.

---

# Part VIII — Open product/architecture decisions

These should be answered before ticket decomposition:

1. **Project-zone wording:** should the confirmation continue to offer “Delete
   Tiles” when project tiles are never deleted, or should project zones show a
   clearer one-action close?
2. **Open-palette invalidation:** if an entity disappears while Cmd+K is open,
   should rows live-refresh, or is safe refusal on selection sufficient?
3. **Cold zones:** should Cmd+K list all persistent tiles or only installed,
   immediately reachable tiles?
4. **Bare tiles after group Keep:** which persistent owner holds spilled ambient
   tiles once they no longer have a zone?
5. **Last project zone:** does closing the final view of a project merely remove
   it from this workspace, or should it also affect workspace/project registry
   membership?
6. **Transition direction:** is the current-scene projection an enduring adapter,
   or explicitly a bridge toward eliminating flat compatibility state?

Recommended defaults for a focused first repair:

- retain current project-tile semantics;
- rebuild Cmd+K on open and safely refuse stale captured rows;
- index only currently installed/reachable tiles;
- treat the scene projection as a bridge with enough ownership metadata to make
  a later full ZoneLayer migration possible.

---

# Part IX — Jelly resize direction and zone growth

Added after Dylan reported that bottom-edge tile resize feels correct while
resizing from the top fails to grow the zone and can make the surrounding tile
layout flip rapidly.

This belongs in the same architecture discussion. Close/navigation expose
**identity-owner disagreement**; Jelly resize exposes **geometry-owner and
mutation-intent loss**. In both cases, a downstream subsystem receives a
flattened projection without enough ownership information to mutate the real
zone correctly.

## 1. Intended resize behavior

Raw direct manipulation already has the correct opposite-edge contract:

| Dragged edge | Tile fields changed | Fixed edge |
|---|---|---|
| Left | `x`, `width` | right |
| Right | `width` | left |
| Top | `y`, `height` | bottom |
| Bottom | `height` | top |

Corners combine the matching horizontal and vertical contracts.
`CanvasEngine.tile(_:resizedByScreenDelta:edge:viewport:)` implements this
correctly (`CanvasEngine.swift:560-601`).

For an auto-layout zone, the intended pressure order remains:

1. consume/compress configured gap and padding;
2. shrink only affected neighboring tiles toward their kind minimums;
3. grow the zone in the direction of the dragged edge;
4. preserve the pointer-owned tile's requested frame and opposite edge;
5. avoid reinterpreting unrelated rows/columns.

The freeform canvas remains primary. Resize pressure should feel local, not like
an implicit Tidy.

## 2. Confirmed directional information loss

The gesture knows the exact `ResizeEdge`, but that information is discarded
before the Jelly solver:

```text
TileNSView dragKind = .resize(edge)
  → CanvasEngine computes an edge-correct frame
  → CanvasNSView.updateTile(frame)
  → CanvasAutoLayoutEngine.Mutation.tile(id, frame)
```

`Mutation.tile` carries only the resulting frame. The solver infers one Boolean:

```swift
activeTileResizeIsHorizontal = widthDelta >= heightDelta
```

It therefore knows horizontal versus vertical, but not:

- left versus right;
- top versus bottom;
- corner identity;
- fixed/opposite edge;
- pressure direction;
- whether both axes should participate.

Evidence:

- gesture edge ownership: `TileNSView.swift:731-851`;
- raw frame math: `CanvasEngine.swift:560-601`;
- mutation shape and inference: `CanvasAutoLayoutEngine.swift:50-90`;
- canvas handoff: `CanvasNSView.swift:1949-1974`.

A solver that receives no edge cannot preserve edge-specific zone growth by
construction.

## 3. Why bottom works and top fails — [confirmed]

`expandZoneAndPack` grows only `zone.size.width` or `zone.size.height`. It never
changes `zone.origin`.

That implements growth toward the **right** or **bottom** only.

A minimal source-derived example:

```text
zone origin       (100, 100)
zone size         624 × 440
header            32
padding           8
content top       y = 140
active tile       y = 140, height = 300
```

### Bottom resize by 20

The raw frame becomes:

```text
y = 140, height = 320, bottom = 460
```

If it eventually exceeds the content bottom, increasing zone height moves the
content bottom downward. Packing can become feasible. This is why bottom feels
correct.

### Top resize upward by 20

The raw frame becomes:

```text
y = 120, height = 320, bottom still = 440
```

The pinned tile now begins above the content top. Increasing zone height only
moves the **bottom** farther down; content top remains tied to
`zone.origin.y + header + padding`. No amount of bottom growth can make `y=120`
valid.

The same defect exists horizontally:

- right-edge growth can work by increasing width;
- left-edge growth cannot work because origin.x never moves left.

The existing `expandZoneToContainMembers` helper demonstrates the missing
semantics: it computes `newX`/`newY` from member minima and then recomputes size
while preserving the old far edges. Jelly resize does not use that directional
operation.

Evidence:

- `expandZoneAndPack`: `CanvasAutoLayoutEngine.swift:561-588`;
- pinned containment in `pack`: `CanvasAutoLayoutEngine.swift:637-680`;
- direction-aware containment helper: `CanvasNSView.swift:440-476`.

## 4. Why layouts can appear to flip — [high confidence]

Several discontinuities compound.

### 4.1 Feasible → impossible phase transition

While a top-growing tile remains inside the zone, the generic packer may place
siblings around it. The instant its `minY` crosses the content top, every pack,
gap-compression, neighbor-shrink, and max-edge expansion attempt can become
unsatisfiable because the pinned frame itself is outside the unchanged min edge.

`applyAutoLayout` then applies an absolute scene from the gesture baseline.
Passive tiles that were packed on the prior pointer frame can abruptly return to
baseline. If the pointer jitters across that threshold, the layout alternates
between packed and baseline states.

### 4.2 Corner resize flips solver axis

For a corner drag:

```text
width delta 120, height delta 119 → horizontal mode
width delta 119, height delta 120 → vertical mode
```

One pixel of diagonal jitter can switch which dimensions are removed from every
neighbor and which zone dimension grows. Those are entirely different packing
problems, so the topology can alternate frame-to-frame.

### 4.3 Pressure is global rather than local

`shrinkNeighborsAndPack` shrinks every non-active member on the chosen axis. It
does not identify the contacted neighbor or propagate pressure only away from
the dragged edge. A right-edge resize can therefore resize a left-side or distant
member; a top resize treats every member's height as pressure capacity.

Once feasibility changes, the generic packer can move unrelated members into a
different lane.

### 4.4 Animation amplifies solver discontinuity

Each pointer update may start a 0.14-second implicit animation for passive tiles
and zones. New drag events arrive before prior animations finish. Deterministic
but discontinuous solver outputs can therefore look like oscillation, crossing,
or tiles trying to occupy several layouts.

Evidence:

- absolute baseline application: `CanvasNSView.swift:321-333`;
- passive animation: `CanvasNSView.swift:345-388`;
- global neighbor shrink: `CanvasAutoLayoutEngine.swift:517-558`;
- topology-sensitive pack: `CanvasAutoLayoutEngine.swift:637-680`.

## 5. Existing witnesses are directionally blind

Current Jelly pressure coverage proves rightward horizontal behavior:

- Core checks grow the active tile's width to the right;
- the production AppKit/ZoneLayer check synthesizes only a right-edge resize;
- trajectory instrumentation is focused on move/swap behavior, not resize.

There is no equivalent coverage for:

- top growth changing `zone.origin.y` while fixing the old bottom;
- left growth changing `zone.origin.x` while fixing the old right;
- mirrored top/bottom and left/right pressure results;
- corners under diagonal jitter;
- local versus global neighbor pressure;
- intermediate resize trajectories;
- animation continuity during repeated pointer updates.

Relevant checks:

- `ContinuumRevivedCoreChecks/main.swift:11194-11244`;
- `CanvasNSView.swift:6676-6734`.

## 6. Recommended mutation architecture

Do not patch top resize by special-casing a negative coordinate after solving.
Preserve intent at the mutation boundary.

Possible shape:

```swift
enum Mutation {
    case resizeTile(
        id: UUID,
        requestedFrame: TileFrame,
        edge: ResizeEdge,
        baselineFrame: TileFrame
    )
    case moveTile(id: UUID, requestedFrame: TileFrame)
    case zone(id: UUID, placement: ZonePlacement)
    case tidy(zoneId: UUID?)
    case settle(zoneId: UUID, anchor: UUID?, pin: Bool)
}
```

The resize solver should derive:

```text
pressure axis      from edge
pressure sign      min-edge versus max-edge
fixed edge(s)      from baseline + edge
zone growth        origin + size for min edges; size only for max edges
contact chain      neighbors intersected in pressure direction
```

Required invariants:

1. The requested active tile frame remains pointer-owned.
2. The opposite tile edge remains fixed, including through minimum clamping.
3. Zone growth follows the dragged edge:
   - left: move origin.x left and increase width, old right fixed;
   - right: increase width, origin.x fixed;
   - top: move origin.y up and increase height, old bottom fixed;
   - bottom: increase height, origin.y fixed.
4. Corner growth can operate on both axes in one solve; it never chooses one axis
   from a dominant-delta tie.
5. Only the contact/pressure chain yields before zone growth.
6. Unrelated members retain frame and size.
7. Retreating the pointer relaxes pressure continuously from the gesture baseline.
8. Preview and committed geometry are identical at mouse-up.

## 7. Product clarification: outward growth is not layout pressure

Dylan's additional live report:

- an end tile at the zone boundary grows the zone when resized straight out,
  perpendicular to that edge;
- a diagonal/corner resize can let the tile escape the zone instead;
- when the zone finally grows, unrelated tiles also resize/reflow;
- Tidy itself is not a satisfying model for direct manipulation and should not
  define live resize behavior.

This sharpens the desired rule. The current pressure order is too global because
it treats every larger member as a packing problem. A boundary tile growing
**outward into new space** is not exerting pressure on the existing composition.
The container can grow around it without changing any sibling frame.

### Separate resize delta into outward growth and inward pressure

For each dragged edge component, classify its movement relative to the owning
zone's content boundary:

```text
OUTWARD component
  tile edge moves away from zone interior at/near the matching boundary
  → grow zone one-for-one in that direction
  → do not pack, shrink, move, tidy, or animate siblings

INWARD component
  tile edge moves into occupied zone interior
  → preserve zone
  → consume local gap
  → pressure only contacted neighbors along that direction
  → grow zone only if local pressure cannot be resolved and product policy wants it

FREE component
  edge changes within unoccupied interior space
  → resize tile only
  → no sibling or zone mutation
```

This means direct resize is not one global `solve(packEverything)` operation. It
is an edge-aware decomposition.

### Boundary examples

#### Rightmost tile, right edge dragged outward

```text
tile.width += dx
zone.width += overflowRight
all sibling frames and sizes unchanged
```

There is no reason to shrink a left-side tile first: the pointer is creating new
space outside the composition, not consuming space inside it.

#### Topmost tile, top edge dragged outward

```text
oldZoneBottom fixed
zone.origin.y -= overflowTop
zone.height += overflowTop
active tile follows pointer
all sibling world frames unchanged
```

For a `ZoneLayer`, local member coordinates may shift when origin changes, but
their **world frames must remain byte-for-byte identical**. That conversion is an
ownership detail, not a visible layout event.

#### Bottom-right corner dragged diagonally outward

Resolve both axes independently in one frame:

```text
right overflow  → zone.width grows right
bottom overflow → zone.height grows down
```

Do not choose horizontal or vertical from the larger delta. Diagonal corner
resize is a two-axis operation, not a dominant-axis gesture.

#### Mixed corner gesture

A corner can have one outward component and one inward/free component. Example:
a top-right corner moves upward and left:

- top component grows zone upward;
- right component shrinks the active tile within its existing lane;
- only actual inward contact on the horizontal axis may pressure a neighbor.

The axes should not force each other into a global re-layout.

### No-op stability invariant

> If a tile or zone dimension/frame is not required to change by direct pointer
> geometry or a contacted pressure chain, it must not change at all.

In particular:

- zone expansion alone never invokes Tidy or generic packing;
- growing available space never shrinks a sibling;
- an unrelated tile's width, height, origin, and lane remain exact;
- zone chrome growth is presentation of new bounds, not permission to recompute
  the composition;
- an explicit Tidy command, if retained, is a separate user-requested operation
  with separate acceptance criteria. It is not reused as a live-resize primitive.

### Recommended solver split

Instead of sending every resize through the general packer:

```text
1. Resolve current tile + zone owner in world coordinates.
2. Apply raw edge-preserving tile resize.
3. Compute overflow against current zone content bounds per edge.
4. Expand zone directly for outward overflow, preserving every sibling world frame.
5. Build a directional contact graph only for inward overlap/under-gap.
6. Apply local gap/neighbor pressure along that graph.
7. Return one explicit tile+zone transaction; never run Tidy implicitly.
```

Generic packing remains appropriate for explicit Tidy, initial arrangement, or a
separately approved recovery operation. It should not sit in the per-pointer
path for an ordinary boundary resize.

## 8. Required RED witnesses

Before implementation, add a mirrored table over all edges and corners.

### Pure solver table

For each edge:

- same fixture and pressure distance;
- expected active frame exact;
- expected fixed opposite edge exact;
- expected zone origin/size exact after capacity exhaustion;
- no member outside content/header;
- identical pressure order under mirrored geometry.

### Outward boundary growth

Place an end tile exactly at each zone content edge, with at least two unrelated
siblings. Resize outward from the matching edge and assert:

- zone growth equals only the overflow amount;
- min-edge growth changes origin and preserves the old far edge;
- max-edge growth preserves origin;
- every sibling world frame and size is exactly unchanged;
- no generic pack/Tidy phase executes;
- repeating the same pointer sample is an idempotent no-op.

Add four corner cases, including a bottom-right diagonal where both zone axes
grow simultaneously and no sibling changes.

### Local pressure chain

Use at least three members where only one lies in the dragged edge's inward
pressure path. Assert the contacted chain alone consumes gap/shrinks, while the
distant/opposite-side member never changes size or lane.

### Corner jitter trajectory

Drive a sequence around equal deltas, e.g. `(118,120)`, `(120,119)`,
`(121,121)`. Assert:

- no horizontal/vertical mode flip;
- both requested edges track the pointer;
- passive topology has no direction reversals;
- zone origin/size change continuously.

### Real AppKit path

Synthesize top, bottom, left, right, and four corner drags through
`TileNSView.mouseDown/mouseDragged/mouseUp` on both:

- flat compatibility zone;
- installed `ZoneLayer` with nonzero origin.

Record intermediate frames, not only the endpoint. Assert one durable geometry
transaction and exact undo restoration.

### Presentation gate

After deterministic geometry is green, Dylan should manually verify:

- no passive-tile flicker or lane switching;
- no pointer resistance;
- top/left feel like mirrored bottom/right;
- zone chrome grows smoothly under the pointer;
- repeated grow/shrink cycles do not resurrect old layouts.

## 9. Relationship to the current-scene repair

The two efforts should share boundaries but not become one giant rewrite:

- **Current scene** answers: which zone/tile owner is current, and what is its
  world geometry?
- **Resize intent** answers: which edge is manipulated, what stays fixed, and how
  does its owning zone change?
- **Runtime transaction** persists the resulting tile and zone geometry through
  the correct owner.

A future scene mutation API can therefore be explicit:

```text
resolve current tile owner
  → construct edge-preserving resize intent in world coordinates
  → solve local pressure + directional zone growth
  → apply one owner-aware tile+zone transaction
  → persist through matching workspace/project stores
```

This avoids repeating the current failure mode where a flattened frame survives
but the information needed to update its real owner has already been lost.

---

# Investigation sources

Two read-only investigation rounds examined separate parts of the problem.

Zone lifecycle/navigation:

- zone creation, close, persistence, and runtime lifecycle;
- Cmd+K row construction, caching, dispatch, and invalidation;
- tile identity and coordinate projection across flat/layer models;
- docs, git history, checks, and regression windows.

Jelly resize:

- edge/corner pointer geometry and gesture transactions;
- pressure, packing, zone expansion, and animation;
- directional invariance and minimal numerical fixtures;
- test/history evidence and missing real-path witnesses.

The first round converged on stale boot zone models and stale flat tile
precedence. The second converged on loss of `ResizeEdge` intent and max-edge-only
zone growth, with generic global packing and per-frame animation amplifying the
visible layout flips.

No production source or test implementation was changed during either
investigation. Only this brainstorming document was updated.

---

# Cross-reference from the transcript program (`.plans/46`), 2026-08-22

Added by the agent working the agent-tile transcript program. Verified against
`09de0b0`. Not edits to your findings — status updates on them, because
`ecf3bf3` ("Fix workspace switching and linked document focus") landed in 0.5.10
**after** this document was written.

- **Finding C** (flat tiles contaminate `navigationTileSnapshots`; a stale flat
  record shadows the layer record) — **fixed by `ecf3bf3`.**
  `retireFlatCompatibilityScene()` (`CanvasNSView.swift:5051-5066`) empties
  `tileViews` and gates every accessor behind `flatCompatibilitySceneActive`.
- **Finding E** (a stale `canvasState.lastActiveTileId` reactivates an old
  location) — **fixed by `ecf3bf3`**; retirement nils it (`:5063`).
- **Finding D** (zone navigation tied to `zoneRenderModels`) — **not fixed, and
  arguably inverted.** `retireFlatCompatibilityScene()` clears
  `zoneRenderModels` and neither `setZones` nor `_installLayer` repopulates it,
  so post-switch Cmd+K rows and `fitZoneToViewport`'s first lookup now see an
  **empty** array where they previously saw a stale one.
- **Findings A and B** (a closed zone remains a Cmd+K destination; `closeZone`
  never calls `removeZoneLayer`) — **untouched**, and they bear directly on
  document links: a "closed" project zone can still be the zone `openDocument`
  activates.

## Two things from our investigation that belong in your repair, not ours

Your recommended shape — one authoritative current-scene projection plus one
runtime-owned close transaction — is the right home for both:

1. **The ungated flat read.** `updateDocumentRelationshipOverlay()` reads
   `tileViews` **directly and ungated** (`CanvasNSView.swift:1703`). Benign only
   because retirement empties that dictionary; if retirement were ever skipped
   while the flag flipped, the overlay would index views the rest of the app
   considers gone.
2. **The `tiles(forProjectId:)` truncation.** `persistProjectCanvas`
   (`TileSpawner.swift:2213-2232`, ten call sites) writes
   `state.tiles = canvasView.tiles(forProjectId:)`, and that helper
   (`CanvasNSView.swift:5214-5220`) reads **installed layers only**. A spawn in
   one zone therefore erases un-hydrated zones' tiles from the project's canvas
   file. We are fixing this as ledger ticket **S0.3** because it destroys user
   work today — but the durable home for it is your projection.

Also on the same seam, and ours to fix (ledger **S0.1/S0.2**): all four
ZoneLayer builders produce `DescriptorTileNSView` placeholders
(`WorkspaceRuntime.swift:229-234`, `:361-365`, `:393-396`, `:680-684`), and real
views are built only by the boot walk. After the first in-process workspace
switch every tile is a placeholder. Coordinate before touching
`WorkspaceRuntime`.
