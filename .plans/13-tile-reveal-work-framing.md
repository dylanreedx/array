# Tile Reveal/Work Framing

Status: plan, 2026-08-11

## Outcome

Keyboard navigation has two camera modes:

1. **Overview** frames a zone or the canvas so its spatial structure is clear.
2. **Reveal/work** frames one current tile closely enough to use while retaining a
   visible gutter of the surrounding canvas whenever geometry allows.

A zone jump stays in overview. A precise tile jump goes directly to reveal/work.
If a zone jump has already highlighted a tile, the user can activate that same
tile without selecting it again; Array reapplies reveal/work framing and gives
the tile input focus.

The feature is done when this flow works without a mouse:

```text
⌘K → Jump to zone → zone overview, remembered/first tile current
                         ↓
                  hold ⌥ + Return
                         ↓
             current tile revealed for work
             with nearby tile edges still visible
```

## Product rules

### Two modes only

- Zone and fit-all commands produce **overview**.
- Tile labels, `⌘K` tile rows, previous-tile navigation, and current-tile
  activation produce **reveal/work**.
- There is no intermediate readable-only camera state exposed to the user.
- Existing `⌘F` Focus Mode remains a separate isolation/split-layout feature;
  this work does not use or replace it.

### Reveal/work framing

- Use the tile's real world frame and kind.
- Raise zoom to at least `CameraFraming.editableTargetZoom(for:)` when arriving
  from overview. This uses the existing intended working thresholds rather than
  stopping at `minimumReadableZoom(for:)`.
- Preserve a higher current zoom when the tile is already well framed; a jump
  must not unexpectedly zoom out.
- Keep the whole tile visible when it fits at working zoom.
- Center it with a generous screen-space context gutter. Gap-adjacent tiles
  should naturally show an edge in that gutter, keeping spatial navigation
  legible.
- When a tile cannot fit at a usable zoom, usability wins: keep working zoom and
  reveal its useful top/left area with padding. Showing neighboring edges is
  best-effort in this physically constrained case.
- Never resize or move the tile to satisfy camera framing.
- Record the previous camera before a real move so `Back to Previous View`
  returns from reveal/work to the zone overview.

### Current tile and input focus

- `CanvasState.lastActiveTileId` remains the current/highlighted navigation
  target. Do not add a second tile-selection model.
- Every zone-jump path chooses the zone's remembered tile, falling back to its
  first tile, and makes that ID current consistently.
- Making a tile current does not itself force reveal/work during a zone jump.
- Activating the current tile enters `FocusBroker` tile scope and applies
  reveal/work even when the tile ID has not changed.
- Direct tile jumps both make the tile current and activate it.
- Tile body/title/content focus continues through the existing focus broker;
  camera movement must not become a competing focus system.

## Interaction contract

| Action | Camera result | Current tile | Input scope |
| --- | --- | --- | --- |
| Jump to zone | Overview of zone | Remembered tile, else first | Preserve safe navigation/modal restoration until activation |
| Jump to tile from `⌘K` | Reveal/work | Target | Target tile |
| Hold-`⌥` tile label | Reveal/work | Target | Target tile |
| Hold `⌥` + Return | Reveal/work | Existing current tile | Existing current tile |
| Previous tile | Reveal/work | Previous tile | Previous tile |
| Back to Previous View | Restored snapshot | Snapshot tile | Snapshot scope when valid |

`Return` is the activation key because legacy nav mode already uses Return to
enter its selected tile. In the hold-`⌥` leader it is currently swallowed but
unassigned, so it can express the same action without consuming another tile
label.

## Implementation

### 1. Make the framing policy explicitly reveal/work

Update `Sources/ContinuumRevivedCore/CameraFraming.swift`.

- Replace the current "minimum readable and mostly visible" stopping rule for
  tile navigation with a reveal/work target based on
  `editableTargetZoom(for:)`.
- Keep the current `minJumpZoom`, maximum clamp, screen-space padding, and
  oversized top/left behavior unless the Core table proves a constant must move.
- Name the API by intent, for example `revealWorkViewport`, rather than adding a
  third camera-mode abstraction.
- Return the current viewport only when the tile is already at working zoom and
  properly composed with the intended gutter—not merely 75% visible.

The pure policy should remain independent of AppKit and tile views.

### 2. Use one app helper for every tile reveal

Update `Sources/ContinuumRevived/Canvas/CanvasNSView.swift` and
`Sources/ContinuumRevived/App/ContinuumApp.swift`.

- Have `CanvasNSView.framedViewportForTileJump(_:)` call the reveal/work policy
  using `navigationTileSnapshot(for:)`, preserving correct world coordinates for
  both canvas tiles and `ZoneLayer` tiles.
- Funnel leader-label jumps, `⌘K` tile jumps, previous-tile navigation, and
  current-tile activation through one AppDelegate helper that:
  1. resolves the navigation snapshot;
  2. records the previous view only if the camera changes;
  3. applies the reveal/work viewport;
  4. records tile/zone focus history;
  5. enters the target's `FocusBroker` tile scope with the correct modal-dismissal
     reason.
- Preserve the existing palette snapshot rule that prevents palette dismissal
  from bouncing focus back to the pre-palette tile.

### 3. Activate the already-current tile from the keyboard

Update the hold-leader handling in `ContinuumApp.swift`.

- In `handleLeaderKey(_:)`, handle Return (`keyCode == 36`) before label lookup.
- Resolve `canvasState.lastActiveTileId`; if valid, close the leader and invoke
  the shared tile-reveal helper.
- If there is no valid current tile, close the leader without moving the camera
  or send the existing quiet failure feedback.
- Keep the current fully visible tile excluded from letter labels. Return now
  supplies the intentional self-action that exclusion was missing.
- Include the activation in the leader HUD hint and settings/shortcut catalogue
  where hold-leader actions are described. Do not create a new global chord.

Expose the same operation as a `Focus Current Tile` command-center row through
`CanvasCommand` for discoverability and a fully searchable keyboard path. It
must call the same helper and must not be a separate behavior path.

### 4. Normalize zone-jump current-tile handling

Update the shared zone-jump paths in `ContinuumApp.swift`.

- Palette zone jump, leader zone jump, ordinal jump, and next/previous zone
  should all resolve the remembered tile through `FocusHistory`, falling back to
  `CanvasNSView.firstNavigationTileId(inZone:)`.
- Make that tile current/highlighted without changing the zone overview camera.
- Do not run tile reveal/work framing as a side effect of choosing a zone.
- Keep empty zones valid overview targets with no fabricated current tile.

This step removes the current inconsistency where some zone paths enter a tile
scope while others only record focus history.

### 5. Witness the real keyboard workflow

Add a focused app self-check such as `--tile-reveal-work-check` and register it in
`scripts/run-matrix.sh`.

The check should drive real events/actions and prove:

1. A `⌘K` zone jump fits the zone and makes its remembered tile current.
2. Hold `⌥` + Return keeps the same tile ID, raises the camera to that kind's
   working zoom, and enters its tile scope.
3. A gap-adjacent neighbor has a visible edge when both tiles can fit under the
   reveal/work constraints.
4. An oversized terminal stays at usable zoom and reveals the useful area rather
   than shrinking to overview.
5. `Back to Previous View` restores the exact zone-overview snapshot.
6. A direct `⌘K` tile jump and a leader-label jump land on the same framing
   policy.
7. Re-activating a tile already well framed is a viewport no-op but still repairs
   tile input focus.
8. Empty-zone and deleted/stale-current-tile cases do not move the camera or
   focus a nonexistent tile.

Extend the Core camera-framing table in
`Sources/ContinuumRevivedCoreChecks/main.swift` with small, default, wide, tall,
and oversized tile frames. Rebuild the check products before trusting the run.

## Scope boundaries

- No third camera mode.
- No automatic full-screen or single-tile isolation.
- No changes to `⌘F` Focus Mode or browser `⌘F` dispatch.
- No tile resize, reposition, snapping, or layout mutation.
- No camera animation in the first slice; framing remains deterministic and
  immediate.
- No semantic zoom renderer changes, minimap, or multi-tile selection.
- No requirement that another tile edge be visible when canvas geometry makes
  that impossible at a usable scale.

## Verification sequence

1. Build and run the updated Core camera-framing checks.
2. Build the debug app and run `--tile-reveal-work-check`.
3. Run the existing leader-jump, palette-jump, zone-framing/readability,
   previous-view, focus-scope, and focus-mode checks to catch behavioral overlap.
4. Run `scripts/run-matrix.sh`; report the documented KNOWN-RED legs separately
   and do not accept a new red leg.
5. Rebuild `~/Desktop/Array Dev.app` only through `scripts/dev-app.sh`, pinned to
   `~/array-scratch`, for the final witnessed keyboard dogfood:
   zone overview → current highlight → hold `⌥` + Return → usable tile with
   neighboring canvas context → jump to an adjacent tile → previous view.
