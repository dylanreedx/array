# 18 — Center-aware tile spawning

Status: **PLAN — behavior designed; implementation not started**

## Outcome

A newly created tile appears where the user is currently looking.

- If the center of the canvas viewport is empty, the new tile is centered there.
- If the center is occupied by a tile, that tile becomes the anchor and the new
  tile is placed gap-adjacent on the side that fits best.
- The choice is deterministic, nearby, and optimized for the current viewport.
  It must not feel like Array picked an arbitrary free square elsewhere.
- Explicit spatial intent remains authoritative: a file dropped at a point stays
  at that point, a file opened from an agent stays beside that agent, and a
  browser child window stays related to its opener.

This is a placement change, not a camera effect. Automatic creation should not
spawn somewhere else and then pan the canvas to hide that fact.

## The current behavior and why it feels random

Automatic tile creation currently runs through
`TileSpawner.makePlacement(...)` and then
`CanvasEngine.placementFrame(...)`.

`placementFrame` scans the visible viewport from its top-left in 32-point,
row-major steps. It returns the first rectangle that does not intersect any
existing tile frame inflated by 16 points. If the visible area is saturated, it
cascades `+24,+24` from the last stored tile.

That algorithm is deterministic, but its result depends on tile geometry and
model ordering that the user cannot see. A new tile may appear at the top-left,
far across the viewport, or stacked near the most recently stored tile. The app
then focuses the new tile without moving the camera. The result feels random
because placement has no relationship to the user's visual attention.

The existing file-anchor path contains a smaller version of the desired idea:
`anchoredFrame` tries an adjacent right slot and then a below slot. The new
policy generalizes that into a four-sided, viewport-aware decision shared by
automatic spawns.

## Product contract

| Situation | Required result |
|---|---|
| Viewport center is empty | Center the new tile on the viewport center. |
| Viewport center is inside one tile | Treat the topmost tile at that point as the anchor. |
| One adjacent side is clearly open and visible | Dock the new tile on that side with the standard tile gap. |
| Several sides are equally good | Use a stable directional tie-break; repeated runs produce the same answer. |
| Every immediate side is occupied | Search a small, bounded set of nearby outward positions; do not jump to the old top-left scan. |
| No collision-free nearby position exists | Choose the least-bad nearby candidate deterministically; keep the result related to the anchor and do not silently pan. |
| The new tile is larger than the viewport | Preserve its intended working size; center the axis that fits and use a stable padded origin on an axis that cannot fit. |
| Canvas is panned or zoomed | Compute from the actual current viewport in world coordinates. |
| Active project uses a `ZoneLayer` | Hit-test in world space, then persist the selected frame in the owning model's coordinate space. |
| Caller supplies a world point | Preserve the caller's explicit point; do not apply center-aware automatic placement. |
| File opens beside an agent/source tile | Preserve the explicit anchor relationship. The generalized side-selection helper may later replace the current right/below helper without weakening this behavior. |
| Browser opens a `_blank` child | Preserve opener-relative placement. |
| File is already open | Reveal/focus it in place; do not relocate it. |

## Proposed algorithm

### 1. Build one world-space placement context

At the instant of an automatic spawn, capture:

- current `CanvasViewport`;
- canvas bounds in screen points;
- viewport center in screen coordinates;
- viewport center converted to world coordinates;
- all relevant sibling tile frames in world coordinates, including active
  `ZoneLayer` tiles;
- the new tile's default world size;
- the resolved standard tile gap.

The placement decision should be pure over this context. Conversion back to a
zone-local frame happens only after the decision.

```text
screenCenter = (canvasWidth / 2, canvasHeight / 2)
worldCenter  = CanvasEngine.screenToWorld(screenCenter, viewport)
anchor       = topmost sibling containing worldCenter
```

Use the same z-order semantics as canvas hit-testing. Overlapping tiles must not
produce an anchor merely because they happen to occur first in storage.

### 2. Empty center: place at attention

When no anchor contains `worldCenter`, start with the new tile centered exactly
on that point:

```text
x = worldCenter.x - newWidth  / 2
y = worldCenter.y - newHeight / 2
```

If that rectangle collides with a tile whose edge happens to intrude near the
center without containing the exact center, evaluate nearby center-originated
candidates rather than reverting to the top-left scan. A compact square/ring
search on the existing 32-point grid is sufficient and deterministic.

### 3. Occupied center: generate four adjacent candidates

When an anchor exists, generate one gap-adjacent candidate on each side:

```text
right: x = anchor.maxX + gap
       y = anchor.midY - newHeight / 2

left:  x = anchor.minX - gap - newWidth
       y = anchor.midY - newHeight / 2

below: x = anchor.midX - newWidth / 2
       y = anchor.maxY + gap

above: x = anchor.midX - newWidth / 2
       y = anchor.minY - gap - newHeight
```

Center alignment on the perpendicular axis is intentional. It makes unequal
sized tiles read as a relationship, whereas top alignment makes the result look
like another row-major layout artifact.

### 4. Rank candidates lexicographically

Avoid a hard-to-explain weighted score. Compare candidates in this order:

1. **Collision class** — collision-free beats overlapping.
2. **Viewport visibility** — larger visible-area ratio wins.
3. **Useful visible area** — if ratios tie, more absolute visible area wins;
   this avoids a tiny sliver winning for a large tile.
4. **Displacement ring** — an immediate adjacent position beats one pushed
   farther outward.
5. **Open continuation** — more free distance from the candidate toward the
   viewport edge wins, reducing the chance that the new tile immediately feels
   wedged in.
6. **Stable direction** — right, left, below, above.

The last ordering is only a tie-break. It should never make a mostly offscreen
right candidate beat a fully visible left candidate.

A candidate's visibility is measured against the current viewport after
converting its world frame to screen coordinates. The infinite canvas is not
the primary optimization target: the user cares where the tile lands now.

### 5. If all four sides are occupied, search outward locally

For each direction, create a small number of outward candidates by advancing
past blocking rectangles while preserving the anchor relationship and
perpendicular center alignment.

A simple first implementation can use at most two extra rings:

```text
anchor -> immediate candidate -> ring 1 -> ring 2
```

Each ring advances far enough to clear the blocking tile plus the standard gap,
not merely another arbitrary 32 points. Add those candidates to the same ranking
pool.

This search is deliberately bounded. It prevents pathological canvases from
turning one click into an unbounded layout walk and prevents the tile from being
placed so far away that its relationship to the anchor becomes meaningless.

If no collision-free bounded candidate exists, choose the best overlapping
candidate by visibility, overlap area, displacement, and stable direction. Bring
the new tile to front as creation already does. This is a last-resort behavior,
not the normal packing strategy.

## Direction and fallback details

### Stable direction order

Use:

1. right;
2. left;
3. below;
4. above.

Right is the natural continuation for left-to-right work, left preserves a
horizontal relationship when right has no room, and vertical growth follows
only after both horizontal options. This order is intentionally visible in the
witness so it cannot drift accidentally.

### What counts as occupied

- Use strict rectangle intersection; edge-touching is legal only after the
  standard gap has been applied.
- Compare against every sibling except an explicitly excluded tile, if a caller
  is repositioning rather than creating.
- Sanitize non-finite persisted frames before ranking, using existing
  `CanvasEngine` sanitation rules.
- Zone chrome is not a tile collision. Zone bounds constrain persistence and
  coordinate conversion, but should not become an invisible obstacle unless a
  later product decision explicitly makes zones hard layout boundaries.

### No automatic camera movement in v1

Do not call `centerOnTile` merely because placement selected a partially visible
candidate. Camera movement destroys the user's current spatial reference and
would make placement appear to work even if the algorithm chose poorly.

Focus still transfers to the new tile through the existing app path. A future
animated reveal may be considered separately, with its own transition and
recording policy.

## Explicit placements that do not use this policy

These routes already carry stronger intent than "put a new tile near where I am
looking":

- canvas file drop (`worldPoint`);
- file opened beside an agent/source tile;
- browser `_blank` child beside its opener;
- any future drag-to-create or caller-provided placement point;
- restart/restore of an existing tile, which preserves its frame;
- reveal of an already-open file.

They should share low-level candidate/collision helpers where useful, but they
must not silently lose their explicit anchor or point.

## Architecture

### Core: pure placement policy

Add a Core-level policy near `CanvasEngine`/`TileArrangement`, with no AppKit
view ownership and no persistence:

```swift
struct TileSpawnPlacementContext {
    var newSize: CGSize
    var viewport: CanvasViewport
    var viewportSize: CGSize
    var siblings: [TilePlacementItem] // world frames + z-order
    var gap: Double
}

enum TileSpawnPlacement {
    static func automatic(in context: TileSpawnPlacementContext) -> TileFrame
}
```

The exact type names are not locked. The important boundary is:

- input and output are world-space geometry;
- hit-testing, candidate generation, collision checks, and ranking are pure;
- `TileSpawner` resolves the active model and converts the chosen result to its
  persisted coordinate space.

This makes the behavior cheap to witness without launching AppKit or touching a
live project.

### App: placement context and model routing

`TileSpawner.makePlacement` and `makeProjectTilePlacement` currently mix:

- viewport geometry;
- active-zone clamping;
- collision input selection;
- world/zone-local conversion;
- the old first-fit policy.

Refactor only enough to provide one world-space automatic-placement context and
one conversion/persistence step.

There is an existing correctness hazard: after an in-process workspace switch,
non-file spawns still use `canvasView.install` plus the flat
`canvasState.tiles`, while file opening uses `installProjectTile` and can target
the active `ZoneLayer`. Center-aware placement must not deepen that split.
Implementation should either:

1. migrate each participating spawn route to the active project model before
   applying the new policy; or
2. land the pure Core policy first, then enable it route-by-route only where the
   owning model and coordinate conversion are correct.

Do not compute a correct world frame and then persist it as zone-local (or vice
versa). A visually correct first frame that jumps after a workspace switch or
relaunch is a failed implementation.

### Existing machinery to reuse

- `CanvasEngine.screenToWorld`
- `CanvasEngine.tileScreenFrame`
- canvas z-aware hit testing
- `TileArrangement.dockDestination`
- `TileGapResolver.resolvedGap()`
- `CanvasNSView.navigationTileSnapshots()` or a narrower world-frame snapshot
  seam that includes flat and layer-backed tiles
- `CanvasNSView.installProjectTile`
- `TileSpawner.makeProjectTilePlacement` coordinate conversion

## Implementation phases

### Phase 1 — behavioral witness, RED

Extend or replace `TileSpawner.runSpawnPlacementSelfCheck()` with assertions for
attention-centered placement and center-tile anchoring. Capture the current
failure before modifying production placement.

The witness must assert resulting geometry, not source strings and not merely
"the tile intersects the viewport."

### Phase 2 — pure center-aware policy

Implement world-space center calculation, anchor hit-testing, four candidate
generation, lexicographic ranking, and bounded outward search in Core.

Keep explicit-point behavior untouched.

### Phase 3 — active-project integration

Route automatic spawns through the correct active project tile collection and
convert the selected world frame to the storage model's coordinate space.

Suggested order:

1. note (cheap runtime, easiest visual dogfood);
2. browser;
3. file tree and other document/tool tiles;
4. terminal;
5. managed agent after its layer reconstruction/persistence path is safe.

If the broader spawn-route migration is already complete when implementation
starts, apply the policy uniformly instead of staging by kind.

### Phase 4 — dogfood and tune only the policy constants

Use `~/Desktop/Array Dev.app` on `~/array-scratch`; never rebuild or quit the
production `/Applications/Array.app` or point another install at
`~/Documents/personal`.

Dogfood these arrangements:

- empty canvas;
- centered anchor with all sides free;
- anchor against each viewport edge;
- unequal anchor/new-tile dimensions;
- right side blocked;
- right and left blocked;
- all four immediate sides blocked;
- panned and zoomed canvas;
- workspace switch followed by spawn;
- active zone with nonzero world origin.

Tune only bounded-search depth or tie-break behavior if observed placement still
feels surprising. Do not add animation or general auto-layout in this ticket.

## Verification matrix

The deterministic witness should cover at least:

1. **Empty, origin viewport** — new tile center equals viewport center.
2. **Pan + zoom** — world center is derived correctly from screen center.
3. **Anchor detection** — topmost tile under center is selected.
4. **Right wins** — all sides free and equally visible.
5. **Left wins on visibility** — anchor near the right viewport edge.
6. **Below wins when horizontal sides collide.**
7. **Above wins when it is the only collision-free visible side.**
8. **Unequal sizes** — candidates are perpendicular-center aligned.
9. **Bounded outward search** — one blocked side clears the blocker without
   reverting to top-left scanning.
10. **Deterministic saturation fallback** — the same crowded input returns the
    same least-bad frame.
11. **Explicit point unchanged** — dropped tile remains centered on that point.
12. **Explicit anchor unchanged** — agent-local file remains gap-adjacent to its
    source relationship.
13. **Zone conversion** — nonzero zone origin produces the expected world frame
    and zone-local persisted frame.
14. **Workspace switch** — the tile enters and persists through the active
    project's model, not the departed flat canvas.
15. **No camera movement** — spawn leaves `CanvasViewport` unchanged.
16. **Focus** — the app's normal spawn completion still selects the new tile.

For user-visible confidence, the final report must distinguish:

- Core geometry checks;
- app self-check/model-routing evidence;
- actual Array Dev dogfood observation.

A green geometry test alone does not prove the live spawn route works.

## Scope boundaries

Included:

- automatic initial placement of newly created tiles;
- interaction with a tile under the viewport center;
- local collision avoidance and deterministic side choice;
- correct world/zone-local handling;
- behavioral witness and Array Dev dogfood.

Not included:

- rearranging existing tiles;
- global canvas compaction or auto-layout;
- moving a tile after it has spawned;
- animated camera transitions;
- changing default tile sizes;
- changing drag snapping;
- changing navigation reveal/work framing;
- making zones hard clipping boundaries;
- release/version/appcast work.

## Acceptance criteria

The work is ready to release when all of the following are true:

- On an empty center, a new tile is centered in the current view.
- On an occupied center, the new tile docks beside the topmost center tile on the
  best visible collision-free side.
- Side selection is deterministic and obeys the documented ranking and tie-break.
- Crowded layouts search nearby before accepting overlap and never fall back to
  the old top-left scan.
- Explicit point- and anchor-based routes retain their intent.
- Panning, zooming, active-zone offsets, workspace switching, persistence, and
  relaunch do not change the tile's intended world position.
- Spawning does not pan or zoom the viewport.
- The relevant self-check is RED against the old behavior and GREEN against the
  implementation, is included in the normal gate, and its leg is confirmed to
  run.
- The behavior is observed in the isolated Array Dev app, with the evidence
  reported separately from automated checks.

## Files expected to change later

- `Sources/ContinuumRevivedCore/CanvasEngine.swift` and/or a focused new Core
  placement-policy file
- `Sources/ContinuumRevived/App/TileSpawner.swift`
- `Sources/ContinuumRevived/Canvas/CanvasNSView.swift` only if a narrower
  world-frame/z-order snapshot seam is needed
- `Sources/ContinuumRevived/App/ContinuumApp.swift` for self-check registration
  only if the existing spawn-placement leg cannot be extended cleanly
- `scripts/run-matrix.sh` / committed check inventory only if a new leg is added
  rather than extending the existing registered leg

No production code is changed by this plan.
