# T11 — Adaptive zone bounds (union + padding, live)

Status: todo
Tag: overnight [pure+wiring]
Depends on: T05 (mutable canvas / `ZoneLayer` set) · Blocks: T19 (on-canvas drag-to-create / move-zone gesture)

## Goal
A zone's drawn boundary should *hug its tiles*. Instead of a fixed stored `size`, a zone
renders at `union(member tile world frames) + padding`, with its header sitting **above**
that union; an empty group zone falls back to a configurable minimum size. The boundary
recomputes **live** as a member tile moves / grows / shrinks. This is what makes a zone
read as "a box around these tiles" rather than an arbitrary rectangle, and it is the
geometry T19's move-zone gesture rides on. v1 lets zones overlap (no neighbor reflow).

## Exact scope — files & symbols
- **`Sources/ContinuumRevivedCore/CanvasEngine.swift`** — add ONE pure function (mirror the
  existing `groupBounds` / `finiteTileBounds` union shape already in this file):
  ```
  public static func zoneBounds(
      memberFrames: [TileFrame],
      padding: Double,
      minSize: CGSize,
      headerHeight: Double
  ) -> TileFrame
  ```
  Returns the world-space outer rectangle of the zone chrome (origin = top-left, y-down).
  Keep `zoneWorldFrame(_:)` as-is (it stays the *stored* placement rect, still used by
  hydration-tier math and persistence) — `zoneBounds` is the *adaptive drawn* rect.
- **`Sources/ContinuumRevivedCore/ZoneBoundsConfig.swift`** — NEW file, a `public enum
  ZoneBoundsConfig` mirroring `DragMagnetizeConfig` / `TileGapResolver` exactly: the
  persisted UserDefaults keys + defaults + guarded resolvers for `padding` and
  `emptyMinSize` (width/height). AppKit-free.
- **`Sources/ContinuumRevivedCore/SettingsSchema.swift`** — append three `.text` fields to
  the existing **General** section (`id: "general"`) binding the new keys (Zone Padding,
  Zone Empty Min Width, Zone Empty Min Height), shaped like the existing "Tile Gap" field.
- **`Sources/ContinuumRevived/Canvas/CanvasNSView.swift`** — wire the adaptive rect into the
  zone-chrome layout (the T05 `ZoneLayer`; in the current tree this is the private
  `ZoneChromeNSView` set managed by `zoneChromeViews` / `installZoneChromeViews()` /
  `layoutZoneChromeViews()`):
  - replace the body of `layoutZoneChromeViews()` so each chrome view's screen `frame`
    comes from `CanvasEngine.zoneBounds(memberFrames:…)` (converted via
    `tileScreenFrame`), **not** `zoneWorldFrame(placement)`.
  - add a private helper `func zoneMemberWorldFrames(_ model: ZoneRenderModel) ->
    [TileFrame]` that returns the zone's member tile **world** frames (for the single
    project-zone case = `canvasState.tiles` mapped through `CanvasEngine.worldFrame(tile:
    in: activeZone)`; the multi-zone / group-zone member source lands with T05/T02 — see
    gotchas).
  - call `layoutZoneChromeViews()` from `updateTile(_:)` so a committed move/resize
    recomputes bounds **live** (today `updateTile` only re-lays the tile).
  - add a QA reader `func qaZoneDrawnWorldBounds(for zoneId: UUID) -> TileFrame?` returning
    the chrome's current world-space bounds (screen `frame` back through
    `CanvasEngine.screenToWorld` ÷ zoom), so the real-path check can assert the recomputed
    rect without re-deriving it from internals.
- **`Sources/ContinuumRevived/App/ContinuumApp.swift`** — register the new app check in the
  `CommandLine.arguments` dispatch chain (~line 314, next to `--multi-zone-render-check`).
- **`scripts/run-matrix.sh`** — register the new app check (next to `--multi-zone-render-check`,
  ~line 87). The Core table needs no new registration — `ContinuumRevivedCoreChecks` already
  runs in the matrix (run-matrix.sh:62).

- **Do NOT touch:** neighbor auto-reflow on overlap (deferred v2 — zones may overlap freely
  here). The drag / move-zone gesture (T19). `CanvasEngine` transforms
  (`worldToScreen`/`screenToWorld`/`tileScreenFrame`/`zoneWorldFrame`/`worldFrame(tile:in:)`)
  — call them, don't change them. `CanvasEngine.hydrationTier` (it intentionally keys off
  the *stored* `zoneWorldFrame`, not the adaptive rect). `ZoneChromeNSView.draw(_:)` /
  `headerRect` / `headerHeight` internals (the header geometry inside the chrome view is
  unchanged — we change the chrome view's outer `frame`, and `headerHeight` is the value we
  feed `zoneBounds` so the union sits *below* the header band). Persistence /
  `WorkspaceDocument` (the stored `size` stays the v2 fallback origin/anchor — T11 does not
  rewrite stored sizes).

## Data / API changes
New pure function (copy-pasteable signature):
```
// CanvasEngine.swift
public static func zoneBounds(
    memberFrames: [TileFrame],
    padding: Double,
    minSize: CGSize,
    headerHeight: Double
) -> TileFrame
```
Semantics (world coords, y-DOWN, top-left origin):
- **Non-empty:** `u = union(memberFrames)` (minX/minY/maxX/maxY over the member frames).
  Drawn rect:
  - `x = u.minX - padding`
  - `y = u.minY - padding - headerHeight`   *(header band sits ABOVE the union)*
  - `width  = u.width  + 2·padding`
  - `height = u.height + 2·padding + headerHeight`
- **Empty (no members):** `width = max(minSize.width, …)` etc. — return a rect of size
  `minSize` whose body union would be empty, with the header band included:
  `TileFrame(x: anchor.x, y: anchor.y, width: minSize.width, height: minSize.height)`,
  where `anchor` is the zone's stored `origin` (so an empty group zone keeps its placed
  position). The empty rect's height already accounts for the header (minSize is the whole
  chrome incl. header) — do NOT add `headerHeight` again on the empty branch.
- **Guards:** `padding`, `minSize`, `headerHeight` are clamped to `max(0, …)` /
  `max(1, …)` for sizes so a malformed config can never produce a negative or zero-area
  rect. (The resolvers in `ZoneBoundsConfig` already guard; the function re-guards
  defensively because it is `public` and called from checks with raw inputs.)

New config (mirror `DragMagnetizeConfig`):
```
// ZoneBoundsConfig.swift
public enum ZoneBoundsConfig {
    public static let paddingKey = "continuum.zoneBounds.padding"
    public static let defaultPadding: Double = 24

    public static let emptyMinWidthKey = "continuum.zoneBounds.emptyMinWidth"
    public static let defaultEmptyMinWidth: Double = 480
    public static let emptyMinHeightKey = "continuum.zoneBounds.emptyMinHeight"
    public static let defaultEmptyMinHeight: Double = 320

    public static func padding(defaults: UserDefaults = .standard) -> Double {
        let v = defaults.double(forKey: paddingKey)
        return (defaults.object(forKey: paddingKey) != nil && v.isFinite && v >= 0) ? v : defaultPadding
    }
    public static func emptyMinSize(defaults: UserDefaults = .standard) -> CGSize {
        func dim(_ key: String, _ fallback: Double) -> Double {
            let v = defaults.double(forKey: key)
            return (defaults.object(forKey: key) != nil && v.isFinite && v > 0) ? v : fallback
        }
        return CGSize(width: dim(emptyMinWidthKey, defaultEmptyMinWidth),
                      height: dim(emptyMinHeightKey, defaultEmptyMinHeight))
    }
}
```
(Resolver guard shape is identical to `TileGapResolver.resolvedGap` / `DragMagnetizeConfig.enabled`
— absent OR non-finite OR out-of-range → declared default. This IS the conflict-guard for
these numeric settings: a `.text` field that fails to parse to a valid value falls back,
matching how "Tile Gap" and the focus-border numeric fields already behave.)

SettingsSchema deltas (append to the existing `general` section, after the "Tile Gap" field):
```
.text(key: ZoneBoundsConfig.paddingKey,        label: "Zone Padding",          default: String(Int(ZoneBoundsConfig.defaultPadding))),
.text(key: ZoneBoundsConfig.emptyMinWidthKey,  label: "Zone Empty Min Width",  default: String(Int(ZoneBoundsConfig.defaultEmptyMinWidth))),
.text(key: ZoneBoundsConfig.emptyMinHeightKey, label: "Zone Empty Min Height", default: String(Int(ZoneBoundsConfig.defaultEmptyMinHeight))),
```

## The check, written FIRST (spec-as-test)

### Part A — pure bounds table (`ContinuumRevivedCoreChecks/main.swift`)
A new `// MARK: - Zone adaptive bounds` block of `expect(...)` calls. This IS the real
path for the pure math (Core round-trip/derivation table). `headerHeight = 34` (the
`ZoneChromeNSView.headerHeight` value) is used throughout. Every value is hand-derivable:

1. **Single member, default padding/header.** member `TileFrame(x: 100, y: 100, w: 200,
   h: 150)`, `padding = 24`, `minSize = 480×320`, `headerHeight = 34`.
   Expect `zoneBounds == TileFrame(x: 76, y: 42, width: 248, height: 232)`.
   Derivation: union = (100,100,200,150). x = 100−24 = 76. y = 100−24−34 = 42.
   w = 200+48 = 248. h = 150+48+34 = 232.
2. **Two members → union spans both.** frames `(100,100,200,150)` and `(400,300,100,100)`.
   union minX=100, minY=100, maxX=500, maxY=400 → union (100,100,400,300).
   Expect `TileFrame(x: 76, y: 42, width: 448, height: 382)`.
   (x=76, y=42, w=400+48=448, h=300+48+34=382.)
3. **Negative-coordinate member (y-down world allows negatives).** frame `(−50, −80, 60, 40)`.
   Expect `TileFrame(x: −74, y: −138, width: 108, height: 122)`.
   (x=−50−24=−74, y=−80−24−34=−138, w=60+48=108, h=40+48+34=122.)
4. **Empty group zone → min size at anchor, header NOT double-added.** `memberFrames = []`,
   `minSize = 480×320`, anchor passed as the empty-branch origin (the test calls the
   overload / passes anchor; if `zoneBounds` takes no anchor, the empty branch returns
   origin (0,0) and the *caller* offsets — assert the size only here):
   Expect `width == 480 && height == 320` (NOT 320+34). Assert exactly
   `TileFrame(x: 0, y: 0, width: 480, height: 320)` for the no-anchor signature.
5. **Header sits above the union (the load-bearing assertion).** For case 1, assert the
   header band — the top `headerHeight` of the drawn rect — is entirely above the union's
   top edge: `bounds.y + headerHeight <= union.minY` i.e. `42 + 34 == 76 ==` `union.minY −
   padding`… concretely assert `bounds.y == unionMinY − padding − headerHeight` AND
   `bounds.y + headerHeight == unionMinY − padding` (the header's bottom edge is exactly
   `padding` above the topmost tile). This proves the header does not overlap any member.
6. **Padding scales the rect, not the union.** Re-run case 1 with `padding = 0`:
   Expect `TileFrame(x: 100, y: 66, width: 200, height: 184)` (x=100, y=100−0−34=66,
   w=200, h=150+0+34=184). Confirms padding is purely additive.
7. **Config guard table.** With a scratch `UserDefaults` (suiteName):
   - absent keys → `ZoneBoundsConfig.padding() == 24`, `emptyMinSize() == 480×320`.
   - `set(0, paddingKey)` → `padding() == 0` (0 is valid for padding).
   - `set(-5, paddingKey)` → `padding() == 24` (negative rejected → default).
   - `set(Double.nan, paddingKey)` → `padding() == 24`.
   - `set(0, emptyMinWidthKey)` → width `== 480` (≤0 rejected for a size dimension).
   - `set(640, emptyMinWidthKey)` → width `== 640`.
8. **SettingsSchema wiring.** Assert `SettingsSchema.sections()` contains the three new
   fields by key in the `general` section, and each field's `default` matches
   `String(Int(ZoneBoundsConfig.defaultX))`. (Mirrors how the Tile Gap field is verifiable.)

### Part B — real-path live-recompute check (`--zone-adaptive-bounds-check`, NEW app check)
A static `CanvasNSView.runZoneAdaptiveBoundsSelfCheck() throws -> URL`, dispatched in
`ContinuumApp.swift` and registered in `run-matrix.sh`. Model it on
`runMultiZoneRenderSelfCheck` (CanvasNSView.swift:1078): build a real `CanvasNSView` with an
`activeZone` project zone + `showsZoneChrome: true`, install real `DescriptorTileNSView`s,
host it in an `NSWindow`, `layoutSubtreeIfNeeded()`. The DRIVEN path is a **real
`NSEvent` move/resize through `TileNSView.mouseDown`/`mouseDragged`/`mouseUp`** (the same
synthesis pattern used at CanvasNSView.swift:1806/2011 — `NSEvent.mouseEvent(with: .leftMouseDown/.leftMouseDragged/.leftMouseUp, location:…, windowNumber: window.windowNumber, …)`),
NOT a direct call to `updateTile`/`zoneBounds`. Assertions (each hand-derivable; use
`viewport.zoom == 1` so world == screen for easy derivation, and `padding = 24`,
`headerHeight = 34`):

1. **Initial bounds = union+padding of the installed tiles.** Two tiles at zone-local
   `(40,52,180,120)` and `(260,52,180,120)` in a zone at `origin (0,0)`. World union =
   (40,52,400,120). Drawn world bounds (via `qaZoneDrawnWorldBounds`) ==
   `TileFrame(x: 16, y: −6, width: 448, height: 232)`. (x=40−24=16, y=52−24−34=−6,
   w=400+48=448, h=120+48+34=232.) Assert exactly.
2. **The chrome SCREEN frame matches** `CanvasEngine.tileScreenFrame(thatWorldBounds,
   viewport:)` — i.e. `zoneChromeSnapshot(for:).frame` equals the converted adaptive rect,
   proving the *drawn* view, not just an internal number, moved. (At zoom 1 with viewport
   origin 0, screen frame == world bounds.)
3. **Move a member right by Δx=300 (screen px) via a real drag → bounds grow.** Synthesize
   `mouseDown` on the second tile's grab strip, a `mouseDragged` of +300x, `mouseUp`. The
   tile commits to zone-local `(560,52,180,120)` (300 world units at zoom 1). New world
   union = (40,52,700,120). Assert `qaZoneDrawnWorldBounds == TileFrame(x: 16, y: −6,
   width: 748, height: 232)` AND the chrome snapshot frame updated to match — proving LIVE
   recompute through the production move handler (assertion fails RED until
   `updateTile` calls `layoutZoneChromeViews`).
4. **Move a member UP by Δy=−40 → top edge (and header) rises with it.** Drag the first
   tile up 40px → zone-local y 12. New union minY = 12. Assert
   `qaZoneDrawnWorldBounds.y == 12 − 24 − 34 == −46` and that the header band's bottom edge
   `(bounds.y + 34) == −12 == unionMinY − padding`. (Header stays above the union after a
   live move.)
5. **Grow a member via a real resize drag → bounds grow on that axis.** Resize the second
   tile's bottom edge down by +60px (drag from its `.bottom` resize edge). union maxY rises
   by 60. Assert `qaZoneDrawnWorldBounds.height` increased by exactly 60 vs. the
   pre-resize value, and the bottom edge equals `unionMaxY + padding`.
6. **Shrink → bounds shrink (symmetry).** Resize the same edge back up by −60px; assert the
   drawn bounds returns to the case-3 value (no residual growth — proves recompute is a
   pure function of current members, not monotonic).
7. **Empty zone → min size at the stored origin.** Build a second canvas: a zone at
   `origin (200,100)` with `activeZone` set but `canvasState.tiles == []`. Assert
   `qaZoneDrawnWorldBounds == TileFrame(x: 200, y: 100, width:
   ZoneBoundsConfig.defaultEmptyMinWidth, height: ZoneBoundsConfig.defaultEmptyMinHeight)`
   (480×320 at the placed origin; header not double-counted).
8. **Overlap is allowed (v1).** Build two zones whose adaptive bounds overlap; assert both
   chrome snapshots exist and neither bounds was reflowed/shifted to avoid the other
   (`qaZoneDrawnWorldBounds` for each == its own union+padding, unchanged by the neighbor).
   This pins the "no neighbor auto-reflow" decision so a future reflow can't silently land.
9. **Non-blank render (grey-screen guard).** Same `VisualSnapshot.metrics` / `!isBlank`
   assertion `runMultiZoneRenderSelfCheck` uses, plus write a PNG + manifest artifact under
   `qa-runs/zone-adaptive-bounds-<uuid>/` (matches the existing artifact convention).

Run Part A (`swift run ContinuumRevivedCoreChecks`) and Part B
(`--zone-adaptive-bounds-check`) → both RED (Part A: missing `zoneBounds`/`ZoneBoundsConfig`
symbols, then assertion 5/7; Part B: assertion 3 — bounds do NOT recompute on move until the
`updateTile` wiring lands). Implement to GREEN.

## Implementation steps
1. **RED — Part A.** Add the Core table (all 8 groups). Run `swift run
   ContinuumRevivedCoreChecks` → fails to compile (no `zoneBounds`, no `ZoneBoundsConfig`).
2. Add `ZoneBoundsConfig.swift` (keys + defaults + guarded resolvers). Add the three
   `SettingsSchema` fields. Add `CanvasEngine.zoneBounds(...)` with the union+padding+header
   math and the empty-branch min size. Re-run Core checks → now fails on the *assertions*
   (confirm it's an assertion failure, not a compile error) → fix the math to GREEN.
3. **RED — Part B.** Add `--zone-adaptive-bounds-check` dispatch in `ContinuumApp.swift` +
   register in `run-matrix.sh`; write `runZoneAdaptiveBoundsSelfCheck` with all 9
   assertions + the `qaZoneDrawnWorldBounds` reader + `zoneMemberWorldFrames` helper, but do
   NOT yet call `layoutZoneChromeViews()` from `updateTile`. `swift build`; run the check →
   RED on assertion 3 (bounds stale after a move).
4. **GREEN — wiring.** Rewrite `layoutZoneChromeViews()` to size each chrome view from
   `CanvasEngine.zoneBounds(memberFrames: zoneMemberWorldFrames(model), padding:
   ZoneBoundsConfig.padding(), minSize: ZoneBoundsConfig.emptyMinSize(), headerHeight:
   ZoneChromeNSView.headerHeight)` → `tileScreenFrame`. Add the `layoutZoneChromeViews()`
   call in `updateTile(_:)`. Run the check → GREEN.
5. `swift build` → run BOTH checks → `./scripts/run-matrix.sh --fast`. This touches zone
   chrome layout, so additionally run `--multi-zone-render-check` and
   `--single-zone-compat-check` (they assert chrome frames; update their expected frames if
   they previously asserted the *static* `zoneWorldFrame` — see gotchas).
6. Self-review vs. Acceptance criteria + Review rubric; commit
   `feat(zones): adaptive zone bounds — union+padding, live recompute`.

## Acceptance criteria
- [ ] `CanvasEngine.zoneBounds(memberFrames:padding:minSize:headerHeight:)` exists; Part A
      table green incl. the header-above-union assertion (5) and empty-min-size assertion (7).
- [ ] Zone chrome renders at the adaptive union+padding rect, not the stored
      `zoneWorldFrame`, and the header band sits above the topmost member.
- [ ] `--zone-adaptive-bounds-check` drives a **real** `NSEvent` move/resize through
      `TileNSView` and asserts the chrome's drawn bounds recompute live (assertions 3–6).
- [ ] Empty group zone falls back to the configurable min size at its origin (assertion 7).
- [ ] Overlap is allowed; no neighbor reflow (assertion 8).
- [ ] `ZoneBoundsConfig` has persisted defaults + guarded resolvers; three `SettingsSchema`
      entries added; guard table green (Part A group 7).
- [ ] `--multi-zone-render-check` / `--single-zone-compat-check` updated to the adaptive
      frames and still green; fast matrix green.
- [ ] No reflow/transform/persistence files touched; commit message has no co-author footer.

## Verification commands
```
swift build
swift run ContinuumRevivedCoreChecks
P=$(mktemp -d); A=$(mktemp -d); CONTINUUM_PROJECT_ROOT=$P CONTINUUM_APP_SUPPORT=$A \
  .build/debug/continuum-revived --zone-adaptive-bounds-check; rm -rf "$P" "$A"
# regression on the two checks that assert chrome frames:
.build/debug/continuum-revived --multi-zone-render-check
.build/debug/continuum-revived --single-zone-compat-check
./scripts/run-matrix.sh --fast
```

## Review rubric
- **Bypass audit (critical):** Part B must commit the new member frame through a synthesized
  `TileNSView.mouseDown→mouseDragged→mouseUp` (or resize edge drag), the REAL path the user
  takes — NOT a direct `canvas.updateTile(...)` and definitely NOT a direct
  `CanvasEngine.zoneBounds(...)` call. If the move is faked by calling `updateTile`/`zoneBounds`,
  REWORK. Trace the synthesized event to `TileNSView.mouseDragged` → `canvas.updateTile`.
- **Live, not initial:** the recompute assertion (3) must read the drawn bounds *after* the
  move and prove they changed; an only-initial check (1–2) would pass even if `updateTile`
  never re-laid the chrome. Confirm assertion 3 goes RED if you revert the `updateTile →
  layoutZoneChromeViews` line.
- **Header-above-union** is asserted by geometry (header bottom edge == union top −
  padding), not merely "bounds are bigger." Re-derive case-1 by hand: y=42, header bottom
  76, union top 100 ✓.
- **Empty branch** does NOT add `headerHeight` twice (assert exact 320, not 354) and is
  anchored at the stored origin, not (0,0)-on-canvas.
- **Symmetry:** the shrink assertion (6) returns to the prior value — proves `zoneBounds`
  is a pure function of *current* members, not accumulated deltas.
- **Config guard:** negative/NaN padding → default; ≤0 min dimension → default; 0 padding
  is accepted (it's a valid value). Settings entries present with correct defaults.
- **No reflow:** assertion 8 proves overlapping zones keep their own bounds. If any code
  shifts a zone to avoid overlap, that's out-of-scope v2 work — REWORK.
- **Hydration untouched:** confirm `CanvasEngine.hydrationTier` still uses
  `zoneWorldFrame` (stored), not `zoneBounds` — tiers must not start flickering off the
  adaptive rect. Confirm `zoneWorldFrame` itself is unchanged.

## Out of scope / gotchas
- **NEEDS-HUMAN — T05 `ZoneLayer` does not exist in the tree yet.** The brief and charter
  name a T05 "`ZoneLayer` set, per-layer layout+hit-test"; the real current source has NO
  `ZoneLayer` type. Zone chrome today is the private inline `ZoneChromeNSView` (CanvasNSView.swift:2422)
  managed by `zoneChromeViews: [UUID: ZoneChromeNSView]` + `installZoneChromeViews()` /
  `layoutZoneChromeViews()` (CanvasNSView.swift:127/137), and member-tile world frames for a
  *project* zone come from `canvasState.tiles` × `CanvasEngine.worldFrame(tile: in:
  activeZone)`. **This spec wires T11 into whatever T05 lands as the zone-chrome layout
  unit** — if T05 renames `ZoneChromeNSView`→`ZoneLayer` / introduces a per-zone member
  source / makes the canvas multi-zone, the executor must re-point the three named
  touch-points (`layoutZoneChromeViews`, the `zoneMemberWorldFrames` helper, the
  `updateTile` recompute hook) onto T05's actual API. If T05 has NOT merged when T11 runs,
  STOP — T11 is blocked on its dependency. Decision needed from a human if T05's shipped
  shape diverges from "one layout/hit-test unit per zone holding a `ZonePlacement`."
- **Group-zone members live in the workspace store (T02), not `canvasState.tiles`.** The
  `zoneMemberWorldFrames` helper here covers the single project-zone case provable today;
  the group-zone member source is supplied by T02/T05's multi-zone render models. The Part B
  check uses a project zone (`activeZone`) because that's the only member source buildable
  before T05/T02. Note for the executor: when T05 provides per-zone members, extend
  `zoneMemberWorldFrames` to read them — do not hardcode `canvasState.tiles`.
- **`runMultiZoneRenderSelfCheck` / `runSingleZoneCompatSelfCheck` assert chrome frames via
  `CanvasEngine.zoneWorldFrame`** (e.g. CanvasNSView.swift:1124). After T11 those frames
  become the adaptive `zoneBounds` rect. Update their expected values (the zones in those
  checks have tiles, so the union+padding rect is hand-derivable the same way) — do NOT
  weaken them to `> 0` checks; keep them exact. This is in-scope fallout of your change.
- **Coordinate trap:** world is y-DOWN, top-left origin; the header sits *above* the union
  means *smaller y* (`y = unionMinY − padding − headerHeight`). The chrome view is
  `isFlipped`, so its internal `headerRect` at local y=0 is the TOP — consistent. The
  chrome view's outer `frame` is screen px; convert world `zoneBounds` via
  `CanvasEngine.tileScreenFrame`.
- **Stale SourceKit:** "Cannot find `ZoneBoundsConfig`/`zoneBounds` in scope" before a build
  is noise; `swift build` is authoritative.
- Drawing the actual header *visual* fit (does the title still center in the band now that
  the band is above the tiles) is a morning eyeball item if T19's gesture work surfaces it;
  the geometry is checked here, the pixels are not.
