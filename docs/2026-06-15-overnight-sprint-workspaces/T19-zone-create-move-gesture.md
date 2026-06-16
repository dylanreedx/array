# T19 — On-canvas drag-to-create-zone + move-zone gesture

Drag on empty canvas draws a new **group zone** sized to the drag rect; drag on a zone's
chrome moves the whole zone (its tiles ride along), then the zone's adaptive bounds (T11)
recompute. Implemented overnight, **staged** — do **not** auto-mark Done.

Status: todo
Tag: morning [appkit]
Depends on: T05 (mutable canvas / `ZoneLayer` set + per-layer hit-test), T11 (adaptive zone
bounds union+padding, live recompute) · Blocks: —

## Goal
The two on-canvas direct-manipulation zone gestures the charter promises (§1: "Dragging the
zone chrome moves the whole zone (tiles ride along)"; group zones are "a named/colored
boundary around tiles" the user can carve out): (a) drag on **empty** canvas → create a
**group zone** (`projectId == nil`) sized to the marquee; (b) drag on a zone's **chrome**
(its header/border, not a tile) → translate the whole zone by the drag delta, with member
tiles moving with it, then recompute the zone's adaptive bounds. This is the on-canvas
counterpart to ⌘K "create zone" (T17) and the sidebar (T16); it must not touch tile drag
(T-existing) or any deferred-v2 migration/reflow/dock behavior.

## Exact scope — files & symbols
- **`Sources/ContinuumRevived/Canvas/CanvasNSView.swift`**
  - `mouseDown(with:)` / `mouseDragged(with:)` / `mouseUp(with:)` (currently ~:797/:825/:842)
    — add zone-gesture classification + handling. Today `mouseDown` only deselects on a
    background click and starts space-pan; the *tile* drag lives in `TileNSView`, so a
    drag that reaches the **canvas** (empty background, or zone chrome that forwards to the
    canvas) is unclaimed and is the seam this task fills. Preserve the existing
    `spaceHeld` pan branch and the double-click `qaDoubleClickZoneHeaderOrBackground`
    branch ahead of the new logic (do not reorder them).
  - A small private gesture state machine on `CanvasNSView` (mirror `TileNSView`'s
    `dragKind`/`dragLastWindowPoint`): e.g. `private enum ZoneGesture { case none; case
    creating(originScreen: CGPoint); case movingZone(zoneId: UUID, lastWindowPoint: CGPoint) }`
    plus `private var zoneGesture: ZoneGesture = .none`. Names are this task's; keep them
    private.
  - Reuse the existing `DragGhostOverlayView` (`:2257`) for the create-marquee preview
    via the existing `showDragGhost(at:)`/`hideDragGhost()` (`:258`/`:265`) so the ghost
    stays click-transparent and topmost — OR add one private marquee overlay if the
    create-rect semantics differ; pick one and state it (see Implementation step 4).
  - QA accessors (static-func check reaches `private` members directly since the check is
    a static func on `CanvasNSView`, so these are only needed if the check runs from
    `AppDelegate`; prefer keeping the check on `CanvasNSView` and reading privates inline —
    add a `func qaZoneGestureState()` only if the assertions can't otherwise observe the
    in-flight state).
  - **Zone-chrome hit target:** `ZoneChromeNSView.hitTest(_:)` (`:2519`) currently returns
    `nil` (pass-through) so chrome never claims a mouse. The move gesture needs the canvas
    to *recognize* a chrome-region press. Resolve **at the canvas layer**, not by making
    chrome opaque: in `mouseDown`, after the space/double-click branches, classify the
    press via `zoneHeaderZoneId(at:)` (`:502`) / `zoneId(at:)` (`:534`) (existing screen→
    world helpers) so a press on a zone header/border → `.movingZone`, a press on empty
    canvas with no tile and no zone → `.creating`. Do **not** flip `ZoneChromeNSView.hitTest`
    to return self (that would break the "static zone chrome passes AppKit hits through"
    invariant the multi-zone-render check at `:1131` asserts) unless T05 explicitly changed
    that contract — see NEEDS-HUMAN.
- **`Sources/ContinuumRevived/App/ContinuumApp.swift`**
  - Register the new `--zone-create-gesture-check` in the `CommandLine.arguments` dispatch
    (model on the `--multi-zone-render-check` block at `:314`: `_ = NSApplication.shared;
    let artifact = try CanvasNSView.runZoneCreateGestureSelfCheck(); print(...); exit(0)`).
  - Wire the canvas's "zone created" / "zone moved" callbacks to the workspace commit path
    so a created group zone is persisted via `WorkspaceDocument` (group placement with
    `projectId == nil`) and a moved zone's new origin is persisted. The **exact** commit
    seam (a `CanvasNSViewDelegate` callback vs. a `WorkspaceRuntime` method from T06) is a
    NEEDS-HUMAN item — see below. The check must drive whatever seam this task picks.
- **`Sources/ContinuumRevivedCore/ZoneGestureConfig.swift`** (NEW) — the configurable-first
  resolver for the one new threshold this task introduces (the empty-canvas
  create-vs-deselect drag threshold, in SCREEN points → world via `/ zoom`, mirroring
  `DragMagnetizeConfig`). See Data / API changes.
- **`Sources/ContinuumRevivedCore/SettingsSchema.swift`** — append one `.text` field for
  the new threshold in the existing `general` section (`:44`), bound to
  `ZoneGestureConfig.minCreateDragScreenPointsKey`.
- **`Sources/ContinuumRevivedCoreChecks/main.swift`** — extend the existing
  `// MARK: - Settings schema engine` block (`:3931`): add the new key to the `expectedKeys`
  set (`:3949`) and a resolver round-trip (default + override) like the `DragMagnetize`
  pair at `:3963`. This IS the conflict-guard (unique-keys assertion at `:3946`). If the
  create-rect math is non-trivial, add a small pure Core table for it here too.
- **`scripts/run-matrix.sh`** — add `run_app_check .build/debug/continuum-revived
  --zone-create-gesture-check` next to `--multi-zone-render-check` (`:87`).
- **Do NOT touch:**
  - `TileNSView` mouse handlers / `dragKind` / drag-snap (tile drag is a separate, shipped
    gesture). A press that resolves to a **tile** must fall through to the tile exactly as
    today — the new canvas logic only claims empty-background or zone-chrome presses.
  - The 4 window-scoped global NSEvent monitors on `AppDelegate` (ADR-0024) — zone gestures
    are local `CanvasNSView.mouse*` overrides, not monitors.
  - `CanvasEngine` transforms (`worldToScreen`/`screenToWorld`/`tileScreenFrame`/
    `zoneWorldFrame`/`worldFrame(tile:in:)`) — consume, don't change.
  - `ZonePlacement` schema / `WorkspaceDocument` `Codable` (T01/T02 own those); this task
    *constructs* a `projectId: nil` placement and *stores* group tiles via
    `WorkspaceDocument.setTiles(_:forZone:)` (T02) — it does not alter those types.
  - The leader nav, ⌘K, sidebar.
  - **Deferred-v2 (explicitly out of scope):** tile migration **between** a project zone
    and a group zone; neighbor **auto-reflow** on overlap; cross-zone **⌥+arrow dock**.
    v1 lets zones overlap; this task does not reflow neighbors.

## Data / API changes
**New resolver (mirrors `DragMagnetizeConfig`):**
```swift
// Sources/ContinuumRevivedCore/ZoneGestureConfig.swift
import Foundation

/// Resolves on-canvas zone-gesture thresholds from UserDefaults. The only tunable
/// this task owns: how far (in SCREEN points) an empty-canvas drag must travel
/// before it commits a NEW group zone (below this it is a plain background click /
/// deselect, never an accidental zone). The live gesture converts to world via
/// `/ viewport.zoom` so the catch feels constant at any zoom — same convention as
/// `DragMagnetizeConfig.snapThresholdScreenPoints`.
public enum ZoneGestureConfig {
    public static let minCreateDragScreenPointsKey = "continuum.zoneGesture.minCreateDragScreenPoints"
    public static let defaultMinCreateDragScreenPoints: Double = 24

    public static func minCreateDragScreenPoints(defaults: UserDefaults = .standard) -> Double {
        guard defaults.object(forKey: minCreateDragScreenPointsKey) != nil else {
            return defaultMinCreateDragScreenPoints
        }
        let v = defaults.double(forKey: minCreateDragScreenPointsKey)
        return v > 0 ? v : defaultMinCreateDragScreenPoints
    }
}
```
**SettingsSchema** (one new field in `general`):
```swift
.text(
    key: ZoneGestureConfig.minCreateDragScreenPointsKey,
    label: "Zone Create Drag Threshold (px)",
    default: String(Int(ZoneGestureConfig.defaultMinCreateDragScreenPoints))
),
```
**Create math (world rect from a drag).** The committed group-zone `origin`/`size` come
from the marquee's two world endpoints (NOT screen px): `let aw =
CanvasEngine.screenToWorld(originScreen, viewport: vp)`, `let bw =
CanvasEngine.screenToWorld(currentScreen, viewport: vp)`; `origin = (min(aw.x,bw.x),
min(aw.y,bw.y))`, `size = (abs(bw.x-aw.x), abs(bw.y-aw.y))`. The new `ZonePlacement` is a
**group zone**: `projectId: nil` (requires T01), a freshly-minted `zoneId`, `color` = a
default ("teal" — the `ZoneChromeNSView.color(named:)` fallback, `:2539`), `collapsed:
false`, `hydrationPolicy: .automatic`, `name: ""` (T01 field; a higher layer backfills),
`navKey: nil`.

**Move math (origin shift from a screen delta).** A zone has no `tile(draggedByScreenDelta:)`
analog yet. Either: (i) reuse the per-event delta exactly as `TileNSView.mouseDragged`
does — `let dx = loc.x - last.x; let dy = loc.y - last.y; let delta = CGSize(width: dx,
height: -dy)` (negate dy: window-y-up vs canvas-y-down), then `newOrigin = (origin.x +
dx/zoom, origin.y + dy_world/zoom)`; the member tiles' **stored zone-local frames do not
change** (they are relative to the zone origin, so moving the origin moves them on screen
for free via `CanvasEngine.worldFrame(tile:in:)`); OR (ii) add a tiny pure
`CanvasEngine.zone(_:draggedByScreenDelta:viewport:)` returning a new `ZonePlacement` with
shifted origin, with its own Core table (preferred — keeps the screen→world math pure and
hand-derivable, matching `tile(_:draggedByScreenDelta:viewport:)` at `CanvasEngine.swift:486`).
Pick (ii); name it in the Core table assertions below.

**Adaptive-bounds recompute (T11).** After a move commits, the zone's `size`/`origin` are
re-derived from `union(member tile world frames) + padding` via T11's recompute entry point.
**The exact T11 symbol is unresolved (T11 spec not yet written)** — see NEEDS-HUMAN. The
check asserts the *observable* result (committed zone world frame == union+padding), so it
is correct regardless of which T11 helper name lands.

## The check, written FIRST (spec-as-test) — `--zone-create-gesture-check`
A NEW static func `CanvasNSView.runZoneCreateGestureSelfCheck() throws -> URL`, dispatched
from the `AppDelegate` `CommandLine.arguments` block in `ContinuumApp.swift` and registered
in `scripts/run-matrix.sh`. It drives the **real** AppKit mouse path — build a
`CanvasNSView` in a real `NSWindow` (mirror `runFocusBorderSelfCheck` `:2083` and
`runFocusScopeDispatchSelfCheck` `:2011`), synthesize `NSEvent.mouseEvent(with:
.leftMouseDown / .leftMouseDragged / .leftMouseUp, location: <window point>, ...)`, and
dispatch via `canvas.mouseDown(with:)` / `canvas.mouseDragged(with:)` /
`canvas.mouseUp(with:)`. **No** calling a create/move executor directly — the gesture is
recognized and committed entirely through the overridden mouse handlers, exactly as a real
drag. Use literal UUIDs and a `zoom: 1` (and a second pass at `zoom: 0.5`, non-origin
viewport) so every value is hand-derivable.

Setup A (CREATE): empty canvas, no zones, one viewport `CanvasViewport(x: 0, y: 0, zoom:
1)`, window 1000×700, `showsZoneChrome: true`. Wire the commit seam (the
`CanvasNSViewDelegate`/runtime callback this task adds) to a local capture so the check can
read the committed `WorkspaceDocument` / canvas zone set.

CREATE assertions (drag from screen `(120, 150)` to `(520, 470)` at zoom 1 → world rect
origin `(120,150)`, size `(400,320)`; the window points account for the canvas being the
window's flipped content view so canvas-local == content point):
1. **Below-threshold drag is NOT a create.** First, a down→tiny-drag(`< minCreateDrag`,
   e.g. +10px)→up on empty canvas commits **no** zone (canvas zone set unchanged,
   `lastActiveTileId == nil`, delegate "zone created" never fired) and behaves as the
   existing background deselect. (Proves the threshold gate; hand-derived from
   `ZoneGestureConfig.defaultMinCreateDragScreenPoints == 24`.)
2. **Above-threshold drag creates exactly one group zone.** After down(`120,150`)→drag
   (`520,470`)→up, the canvas's installed zone set grows by exactly one; the new placement
   has `projectId == nil` (group zone), `collapsed == false`, `hydrationPolicy ==
   .automatic`, `name == ""`, `navKey == nil`, `color == "teal"` (default).
3. **Created zone bounds == the drag rect (world).** `committed.origin == ZonePoint(x:
   120, y: 150)` and `committed.size == ZoneSize(width: 400, height: 320)` — the world
   rect from the two endpoints via `screenToWorld` at zoom 1 (origin viewport). Re-derive:
   at zoom 1, origin (0,0), screen == world, so `min`/`abs` of endpoints give exactly
   `(120,150)`/`(400,320)`.
4. **In-flight marquee ghost.** After the down + first above-threshold dragged event (and
   before up), `canvas.qaDragGhostFrame` (`:278`) is non-nil and equals
   `CanvasEngine.tileScreenFrame(<current marquee world rect>, viewport: vp)`; after `up`,
   `qaDragGhostFrame == nil` (ghost torn down). (Proves the preview drives the same
   click-transparent overlay; re-derive the screen rect from the marquee world rect.)
5. **Reversed drag normalizes.** A second create dragging **up-left** (down `(520,470)` →
   up `(120,150)`) yields the SAME `origin (120,150)`/`size (400,320)` (min/abs
   normalization, not negative size).
6. **Zoom + non-origin viewport.** On a fresh canvas with `CanvasViewport(x: 200, y: 100,
   zoom: 0.5)`, a drag screen `(100,100)`→`(300,300)` creates a zone with `origin ==
   screenToWorld((100,100))` and `size == (200/0.5, 200/0.5) == (400,400)`. Re-derive
   `screenToWorld` by hand: `worldX = vp.x + screenX/zoom = 200 + 100/0.5 = 400`, `worldY =
   100 + 100/0.5 = 300` → `origin (400,300)`, `size (400,400)`. (Proves screen→world, not
   raw screen px, is committed.)
7. **Persistence (real document).** The committed group zone is present in the
   `WorkspaceDocument` written through the task's commit seam: reload it (or read the
   captured doc) and assert one zone with `projectId == nil` and the world frame from
   assertion 3. (If the seam is a delegate callback that hands the runtime a placement,
   assert the placement the runtime received; if it persists, reload and assert the
   on-disk zone.)

Setup B (MOVE): a canvas with ONE group zone `gz` (`projectId: nil`, origin `(300,200)`,
size `(400,300)`, color "teal") holding TWO member tiles whose **zone-local** frames are
`t1 = (x: 20, y: 40, w: 160, h: 120)` and `t2 = (x: 200, y: 40, w: 160, h: 120)` (so their
world frames are `(320,240,160,120)` and `(500,240,160,120)`), installed via `install(
tileView:for:)`, viewport `zoom: 1` origin `(0,0)`, window 1000×700. Compute a press point
inside the zone **chrome header** (top `headerHeight≈34` world px band of the zone, NOT
over a tile): e.g. screen `(310, 210)` (zone origin + (10,10), inside the header strip,
above the first tile's top at world y=240). Drag delta = `(+80, +50)` screen px (down
`(310,210)` → drag/up `(390,260)`).

MOVE assertions (re-derived at zoom 1):
8. **Press on chrome classifies as move, not create, not tile.** Precondition asserts
   `canvas.zoneHeaderZoneId(at: pressScreen) == gz.zoneId` AND
   `canvas.tileId(at: pressScreen) == nil` (the header sits above the tiles). The gesture
   recognized is "move zone gz" (observable via the post-up result, not an internal flag
   bypass).
9. **Whole zone translates by the world delta.** After up, the committed `gz.origin ==
   ZonePoint(x: 300 + 80, y: 200 + 50) == (380, 250)` (screen delta / zoom-1 == world
   delta; dy sign handled so a downward screen drag increases world-y). `gz.size`
   unchanged at the moment of translate (before adaptive recompute) OR equal to the
   union+padding (after recompute) — see assertion 11.
10. **Tiles ride along (stored frames unchanged, world frames shifted).** The member tiles'
    **stored zone-local** frames are still `t1 (20,40,...)` / `t2 (200,40,...)` (NOT
    rewritten — they are relative to the zone), and their on-screen frames moved by the
    same `(+80,+50)`: `canvas.tileView(for: t1)?.frame ==
    CanvasEngine.tileScreenFrame(CanvasEngine.worldFrame(tile: t1, in: <moved gz>),
    viewport: vp)`, whose world origin is now `(380+20, 250+40) == (400, 290)`. Re-derive:
    new zone origin (380,250) + zone-local (20,40) = world (400,290). (Proves tiles ride
    via origin shift, not per-tile mutation — the load-bearing "membership = zone-local"
    fact.)
11. **Adaptive bounds (T11) recompute after the move.** After the move commits, the zone's
    final `size`/`origin` equal `union(member tile world frames) + padding` per T11. With
    t1 world `(400,290,160,120)` and t2 world `(580,290,160,120)` (t2 zone-local x=200 +
    new origin 380 = 580), the union is `x∈[400,740], y∈[290,410]` → union rect
    `(400,290,340,120)`; with T11 padding `P` on each side and a header band `H` above, the
    recomputed zone frame is `origin (400-P, 290-P-H)`, `size (340+2P, 120+2P+H)`.
    **Assert the observable committed zone world frame equals this T11-derived value** using
    T11's *actual* padding/header constants (resolved from T11's config, NOT hardcoded here)
    — the check reads `T11.padding`/`T11.headerBand` (or whatever T11 exposes) so it stays
    correct when the constant changes. (NEEDS-HUMAN: exact T11 symbol — see gotchas; until
    T11 lands, this assertion is written against T11's documented union+padding contract and
    will compile-fail RED, which is acceptable per the missing-dependency precedent.)
12. **No relaunch / no tile-snap side effects.** The move does not invoke the tile
    drag-snap path (`canvas.qaDragGhostFrame == nil` after up — the create-marquee ghost is
    torn down and the move does not arm a tile snap ghost), and `lastActiveTileId` is
    unchanged by a chrome drag (you grabbed the zone, not a tile).

Plus a pure **Core table** in `ContinuumRevivedCoreChecks/main.swift` for the two math
primitives this task adds (so the screen→world derivation is independently hand-checkable):
- `CanvasEngine.zone(_:draggedByScreenDelta:viewport:)`: origin `(300,200)` + delta
  `(80,50)` at zoom 1 → origin `(380,250)`; at zoom 0.5 → origin `(300+160, 200+100) ==
  (460,300)`; size never changes.
- create-rect normalization helper (if extracted): endpoints `(520,470)`,`(120,150)` →
  `(120,150,400,320)` regardless of order.
- `ZoneGestureConfig` resolver: empty defaults → `24`; override `40` → `40`; override `0`
  or negative → falls back to `24` (mirrors the `DragMagnetize` pair at main.swift `:3963`).

**RED:** with no zone-gesture handling in `mouseDown`/`mouseDragged`/`mouseUp`, assertion 2
(no zone created) fails first; with no `ZoneGestureConfig`/`CanvasEngine.zone(...
draggedByScreenDelta...)` the check fails to compile (acceptable RED for the new symbols);
assertion 11 fails to compile until T11's recompute symbol exists. Implement to GREEN.

## Implementation steps
1. **RED:** add `ZoneGestureConfig.swift`; add the SettingsSchema field; extend the
   settings-schema Core check (`expectedKeys` + resolver round-trip) and add the
   `CanvasEngine.zone(...draggedByScreenDelta...)` Core table. Write
   `runZoneCreateGestureSelfCheck` with all 12 + the Core math assertions; register it in
   `ContinuumApp.swift` dispatch and `run-matrix.sh`. Build → confirm RED (compile-missing
   for the new symbols, then assertion 2 once stubbed).
2. Add `CanvasEngine.zone(_:draggedByScreenDelta:viewport:)` (pure, shifts origin by
   `delta / zoom`, dy already negated by the caller as `TileNSView` does) → Core math green.
3. Add the `ZoneGesture` state machine + classification in `CanvasNSView.mouseDown`: after
   the existing `spaceHeld` and double-click branches, resolve the press —
   `zoneHeaderZoneId(at:)`→`.movingZone`, else (`tileId(at:) == nil && zoneId(at:) == nil`)
   →`.creating(originScreen:)`, else fall through to the existing background deselect (and
   to the tile, which `TileNSView` already claims before the canvas sees it).
4. `mouseDragged`: for `.creating`, compute the marquee world rect and call
   `showDragGhost(at:)` once the screen drag exceeds `ZoneGestureConfig`; for `.movingZone`,
   per-event `CanvasEngine.zone(placement, draggedByScreenDelta:, viewport:)`, update the
   live zone layer (T05 mutable API) so the chrome + tiles repaint, then call T11's recompute.
   **(Decide here: marquee uses the existing `DragGhostOverlayView` via `showDragGhost`;
   state it in the diff comment.)**
5. `mouseUp`: for `.creating`, if the drag exceeded the threshold, mint the `projectId:
   nil` `ZonePlacement` from the marquee world rect and fire the commit seam (create);
   else treat as a background click (deselect, existing behavior). For `.movingZone`, fire
   the commit seam (moved origin), run the T11 recompute, persist. Reset `zoneGesture =
   .none` and tear down the ghost in all paths.
6. Wire the commit seam in `ContinuumApp` to persist the new/moved group zone into the
   `WorkspaceDocument` (group placement; `setTiles(_:forZone:)` for any tiles, though a
   freshly-created zone has none). **RED→GREEN boundary is steps 3–6.**
7. `swift build` → run `--zone-create-gesture-check` (temp dirs) → full matrix focus on the
   neighbors: `--multi-zone-render-check`, `--tile-drag-grab-check`, `--add-zone-check`,
   `--drag-magnetize-check`, `--focus-scope-dispatch-check`, the settings-schema Core check.
8. **Stage for morning** (do NOT mark Done): rebuild the bundle
   (`./scripts/make-app-bundle.sh --configuration release --output
   ~/Applications/ContinuumRevived.app`), leave the diff + the "what Dylan must eyeball"
   list below. The commit may land (checks green) but the task stays `staged-for-morning`
   until Dylan confirms the visual/feel gate.

## Acceptance criteria
- [ ] Empty-canvas drag above threshold creates exactly one group zone (`projectId == nil`)
      sized to the drag rect (world); below threshold is a plain background click.
- [ ] Zone-chrome drag moves the whole zone by the world delta; member tiles ride along
      (stored zone-local frames unchanged; on-screen frames shift by the same delta).
- [ ] Adaptive bounds (T11) recompute after a move (committed zone frame == union+padding).
- [ ] All 12 gesture assertions + the Core math table pass through the **real** mouse path
      (synthesized `NSEvent`s → `canvas.mouse*`), no executor bypass.
- [ ] New `ZoneGestureConfig` threshold has a persisted default + a `SettingsSchema` field +
      conflict-guard coverage (unique-keys + resolver round-trip in the settings Core check).
- [ ] Tile drag, the 4 global monitors, `CanvasEngine` transforms, `ZonePlacement`/
      `WorkspaceDocument` schema untouched; no v2 migration/reflow/dock behavior added.
- [ ] `--zone-create-gesture-check` registered in `run-matrix.sh` + `ContinuumApp` dispatch.
- [ ] Fast matrix green; commit `feat(zones): on-canvas drag-create + move-zone gesture`
      (plain message, NO co-author footer) — but leave Status `staged-for-morning`.

## Verification commands
```
swift build
P=$(mktemp -d); A=$(mktemp -d); CONTINUUM_PROJECT_ROOT=$P CONTINUUM_APP_SUPPORT=$A \
  .build/debug/continuum-revived --zone-create-gesture-check; rm -rf "$P" "$A"
swift run ContinuumRevivedCoreChecks            # settings-schema + zone-drag math table
./scripts/run-matrix.sh --fast
```

## Review rubric (adversarial)
- **Bypass audit (critical):** the check must synthesize real `NSEvent`s and dispatch
  through `canvas.mouseDown/mouseDragged/mouseUp` (like `runFocusBorderSelfCheck` /
  `runFocusScopeDispatchSelfCheck`), NOT call a `createZone(...)` / `moveZone(...)`
  function directly and assert on its return. Trace the synthesized down→drag→up to the
  overridden handler. Would the check still pass if the `mouseDown` classification were
  stubbed out? It must go RED. If it calls an executor, REWORK.
- **Create rect is world, not screen px:** assertion 6 (zoom 0.5, non-origin viewport) is
  the bug-magnet — confirm `origin`/`size` are `screenToWorld`-derived, not the raw screen
  rect / `/zoom` applied to the wrong quantity. Re-derive `(400,300,400,400)` by hand.
- **Tiles ride via origin shift, not per-tile mutation:** assertion 10 must check the
  *stored* zone-local frames are unchanged AND the *screen* frames moved. A check that only
  asserts the screen frames moved would pass even if the implementation wrongly rewrote
  every tile's stored frame (which would corrupt persistence). Confirm both halves.
- **Threshold gate genuinely guards:** assertion 1 (below-threshold = no zone) must use the
  resolved `ZoneGestureConfig` default, and reverting the threshold check must make a tiny
  background click spuriously create a 0×N zone (RED). Confirm the dy-sign is handled
  (a downward screen drag must increase world-y, matching `TileNSView.mouseDragged`).
- **Chrome-hit contract preserved:** confirm `ZoneChromeNSView.hitTest` still returns `nil`
  (pass-through) unless T05 changed that contract — the move press is classified at the
  canvas layer via `zoneHeaderZoneId(at:)`, not by making chrome opaque. The
  `multi-zone-render-check` assertion at `:1131` ("static zone chrome passes AppKit hits
  through to canvas") must still be green.
- **Configurable-first:** the new threshold has a default + Settings field + the settings
  Core check's `expectedKeys`/resolver-round-trip coverage. A hardcoded `24` anywhere in
  `CanvasNSView` is a FAIL.
- **Scope:** diff touches only the named files; `TileNSView`, the monitors, `CanvasEngine`
  transforms, the leader/⌘K/sidebar untouched; no co-author footer; orphans removed.
- **Morning gate (this is a `[morning]` task):** the reviewer additionally confirms the
  "what Dylan must eyeball" list below is present and lists the visual items the check
  cannot see.

## What Dylan must eyeball (the `[morning]` visual/feel gate — the check can't see these)
1. **Create marquee feel:** dragging on empty canvas draws a live rectangle that tracks the
   cursor smoothly, no flicker, no lag, click-transparent (doesn't fight tiles); releasing
   "lands" a real zone where the marquee was (no jump).
2. **Move feel:** grabbing a zone header and dragging moves the whole zone + its tiles
   together as one rigid group — tiles must NOT lag, jitter, or detach from the header; the
   header stays under the cursor.
3. **Z-paint / layering:** the moving zone and its tiles paint above neighbors during the
   drag and settle into the correct z-order on release; the marquee ghost paints above
   everything and disappears cleanly on release (no ghost residue).
4. **Cursor rects:** the cursor reads correctly — a move/grab cursor over the zone header
   (the existing `pointingHand` cursor rect at `:820`), arrow/crosshair over empty canvas
   while creating; cursor restores cleanly after the gesture (no stuck closed-hand).
5. **Threshold feel:** a small accidental drag on empty canvas does NOT spawn a tiny zone
   (it deselects); the 24px threshold feels right — not so large that an intentional small
   zone is hard to make, not so small that clicks create zones.
6. **Adaptive snap-back:** after moving a zone, watch the bounds recompute (T11) — the
   border should hug the tiles + padding without a visible "pop"/flash, and the header
   should stay above the tile union.
7. **Overlap (v1 allows it):** dragging a zone over another zone just overlaps (no reflow,
   no snap) — confirm that reads as intentional, not broken.
8. **Pan/zoom interaction:** create + move feel correct at zoom 0.5 and 2.0 and at a
   non-origin pan (the math is checked, but confirm it *feels* anchored under the cursor).

## Out of scope / gotchas
- **NEEDS-HUMAN — T05 mutable-zone API shape is unresolved.** This task depends on T05
  ("Mutable canvas: `ZoneLayer` set, per-layer layout+hit-test"), whose spec is **not yet
  written** and whose symbols do **not yet exist** in real source. Today `CanvasNSView`
  holds an **immutable** `let zoneRenderModels: [ZoneRenderModel]` and an immutable
  `let activeZone`, installs chrome once in `installZoneChromeViews()`, and
  `ZoneChromeNSView.hitTest` returns `nil`. There is **no** `setZones` / `upsertZoneLayer` /
  `removeZoneLayer` / mutable zone-layer model in the codebase. The charter (T05 row) and
  T09 reference `setZones`/`upsertZoneLayer`/`removeZoneLayer`, but the exact signatures and
  whether a created zone is added by mutating an array + re-laying-out chrome vs. a new
  `ZoneLayer` type are **undecided**. This spec is written against T05's *behavioral
  contract* (a zone can be added/removed/moved live and the chrome + hit-test follow) and
  names the canvas mutation as "T05 mutable zone-layer API" without inventing a signature.
  **Resolve before building:** pin T05's add/move/remove zone method names so step 4–5 call
  the real API. Do not invent them.
- **NEEDS-HUMAN — T11 adaptive-bounds recompute symbol is unresolved.** T11 ("Adaptive zone
  bounds union+padding, live") spec is **not yet written**. Real source has
  `CanvasEngine.groupBounds(_ group: TileGroup, in tiles:)` (`:575`) for the legacy
  `TileGroup` model and `finiteTileBounds` (`:297`), but **no** zone-bounds-from-member-tiles
  recompute and **no** padding/header constants exposed for zones. Assertion 11 is written
  against T11's union+padding *contract* and references "T11's padding/header constants"
  abstractly. **Resolve before building:** pin T11's recompute entry point (e.g.
  `CanvasEngine.adaptiveZoneBounds(zone:tiles:padding:)`?) and its padding/header band
  constants so assertion 11 reads the real values, not a hardcoded guess.
- **NEEDS-HUMAN — the commit/persist seam is undecided.** Whether a created/moved zone is
  committed via a new `CanvasNSViewDelegate` callback (e.g. `canvasDidCreateZone` /
  `canvasDidMoveZone`) or via a `WorkspaceRuntime` method (T06) depends on which of those
  has landed. T06's `WorkspaceRuntime` (the natural owner of zone mutation + persistence) is
  a Wave-3 dependency not in T19's stated deps. Pick the seam at build time based on what
  exists; the check drives whatever seam is chosen. If neither exists, the minimal seam is a
  `CanvasNSViewDelegate` callback the App persists through `WorkspaceDocumentSaveController`
  (`ContinuumApp` `:2994`).
- **Coordinate traps:** `CanvasNSView`/`TileNSView` are `isFlipped` (y-down). Window-y is
  up; negate `dy` for the world delta exactly as `TileNSView.mouseDragged` does (`:282`).
  `NSView.hitTest` gets the point in the *superview's* coords; the gesture classification
  uses screen-point helpers (`zoneHeaderZoneId(at:)` / `tileId(at:)`) that already do
  `screenToWorld` internally — pass them the canvas-local point
  (`convert(event.locationInWindow, from: nil)`), not the window point.
- **Group zone needs T01 + T02.** `projectId: nil` requires T01 (optional `projectId`) to be
  landed; storing the zone's (eventual) tiles uses T02's `setTiles(_:forZone:)`. A freshly
  *created* zone has no tiles, so T02 is not strictly on the create path, but the
  charter caps deps at T05/T11 — confirm T01 is Done (it is the model floor for the whole
  sprint) before constructing a `projectId: nil` placement.
- **Stale SourceKit diagnostics are noise** ("cannot find `zone(_:draggedByScreenDelta:`" /
  T05/T11 symbols) until `swift build`; the build is authoritative.
- **Deferred-v2 reminder:** do NOT implement tile-between-zone migration, neighbor reflow,
  or cross-zone ⌥+arrow dock. v1 zones overlap freely.
