# T05 — Mutable canvas: `ZoneLayer` set, per-layer layout + hit-test ⚠

Status: todo
Tag: overnight [appkit-checkable]
Depends on: T01 (optional `projectId` + `name` + `navKey` on `ZonePlacement`) · Blocks: T06, T11, T19

> ⚠ This is docs/23 S3 — "the in-place-swap heart." It is the structural change the
> whole keystone (T06 `WorkspaceRuntime`, T09 `switchWorkspace`) stands on. Per docs/23
> §"Risk" + §"Behavior-neutral refactor sequence": do this canvas change as **its own
> commit** so a regression bisects to one layer, and keep it **behavior-neutral for the
> single-zone case** (the existing `--single-zone-compat-check` must stay byte-identical
> green). The correctness that matters here — per-layer layout, per-layer hit-test, cross-
> layer z-order, adapter register-on-add / **unregister-on-remove** — is fully headless-
> checkable; only pure visuals (flicker, z-paint, cursor rects during a live add/remove)
> are left for the morning.

## Goal
Today the canvas is **single-live-zone**: `CanvasNSView` holds immutable `let activeZone:
ZonePlacement?` + `fileprivate let zoneRenderModels: [ZoneRenderModel]` (set once at init),
one flat `tileViews: [UUID: TileNSView]`, and one `canvasState.tiles` array
(CanvasNSView.swift:67–69). Only one zone's tiles are ever live; other zones are static
header rectangles. T06/T09 need to **install, replace, and remove zone layers in place**
(N projects live at once, swap on workspace switch) without recreating the `CanvasNSView`
or relaunching. T05 introduces a mutable **`ZoneLayer`** abstraction: the canvas holds a
**set** of layers, each owning its placement + render model + its tiles' layout and hit-
test, painted back-to-front by a cross-layer z-order; adding a layer **registers** its tile
focus adapters with the broker and removing a layer **unregisters** them (the unregister is
the contract T09 assertion 3 depends on). The single-zone path becomes the degenerate
one-layer case and stays behavior-neutral.

## Exact scope — files & symbols
- **`Sources/ContinuumRevived/Canvas/CanvasNSView.swift`** — the whole of this task:
  - Add a **`ZoneLayer`** reference type (a nested `final class` or `struct`, see "Data /
    API changes" for the decision) carrying `placement: ZonePlacement`, `renderModel:
    ZoneRenderModel`, the layer's `tiles: [Tile]` (zone-local frames) and its `tileViews:
    [UUID: TileNSView]`, and its `chrome: ZoneChromeNSView?`.
  - Add the **mutable canvas API**: `setZones(_:)`, `upsertZoneLayer(placement:renderModel:)`,
    `removeZoneLayer(zoneId:)`, `setZonePlacement(_:)` (signatures below).
  - Make per-layer layout: today `layoutTile(_:)` (:702) converts `activeZone.map {
    worldFrame(tile:in:) } ?? tile.frame`. Generalize to "the tile's owning layer's
    placement" so each layer scales its own zone-local tiles → world → screen via the
    **existing** `CanvasEngine.worldFrame(tile:in:)` / `tileScreenFrame`.
  - Make per-layer hit-test: `tileId(at:)` (:521) currently special-cases the single
    `activeZone`; it must hit-test **across all installed layers**, honoring per-layer
    `collapsed` (a collapsed layer suppresses child hits, as the existing branch does) and
    the cross-layer z-order so the topmost layer's topmost tile wins.
  - Make cross-layer z-paint: extend `reorderTileSubviewsByZIndex()` (:654) so AppKit
    subview order = (zone z-order index, then within-zone tile zIndex). Keep the focus-
    border + ghost overlays topmost (existing tail of that method).
  - Adapter lifecycle: `install(tileView:for:)` (:153) and `removeTile(id:)` (:287)
    already register/unregister a tile's `focusSurfaceID` with `focusBroker`. **Route layer
    add/remove through the same broker calls**: `setZones`/`removeZoneLayer` must
    `focusBroker?.register(tileView)` for every tile a layer brings in and
    `focusBroker?.unregister(view.focusSurfaceID)` for every tile a removed layer drops
    (and remove those subviews). This is the load-bearing contract for T09.
- **Do NOT touch:**
  - `CanvasEngine` transform math — **reuse** `worldFrame(tile:in:)` / `worldToScreen` /
    `screenToWorld` / `tileScreenFrame` / `zoneWorldFrame` / `hitTest(worldPoint:zones:
    tilesByZone:)` exactly as-is (docs/23 §Risk: "All coordinate transforms stay in
    `CanvasEngine`").
  - The 4 global NSEvent monitors on `AppDelegate` (ADR-0024) — stay where they are.
  - Leader nav / `leaderJumpAssignments` / nav overlay / drag-snap / focus-border behavior
    — adjust ONLY where they read `tileViews`/`canvasState.tiles`/`activeZone` and the new
    multi-layer storage forces a mechanical read-site change; do not change their behavior.
  - `WorkspaceRuntime` (does not exist yet — T06), `ZoneRuntimeRegistry` (T04),
    `ZoneRuntimeController`, `WorkspaceDocument`, `TileSpawner` — not this task.
  - Zone **bounds adaptation** (union+padding, live) = T11; here a layer's drawn bounds is
    still its `placement.size` (the existing `zoneWorldFrame`).
  - On-canvas drag-to-create / move-zone gestures = T19.

## Data / API changes (copy-pasteable)

A reference type so a layer can be mutated in place and its tile views retained:

```swift
@MainActor
final class ZoneLayer {
    var placement: ZonePlacement          // T01: projectId is now UUID? (group zone = nil)
    var renderModel: CanvasNSView.ZoneRenderModel
    var tiles: [Tile]                     // zone-local frames, as persisted
    var tileViews: [UUID: TileNSView] = [:]
    fileprivate var chrome: ZoneChromeNSView?

    init(placement: ZonePlacement, renderModel: CanvasNSView.ZoneRenderModel, tiles: [Tile] = []) {
        self.placement = placement
        self.renderModel = renderModel
        self.tiles = tiles
    }
}
```

New `CanvasNSView` methods:

```swift
/// Replace the entire installed layer set in place. Unregisters every tile
/// adapter of layers that are leaving, registers every tile adapter of layers
/// arriving, removes/adds their tile subviews + chrome, then relays out and
/// re-z-orders. Painting order follows `zoneZOrder` (back-to-front).
func setZones(_ layers: [ZoneLayer], zoneZOrder: [UUID])

/// Add or replace a single layer (by zoneId), preserving the others. On replace,
/// unregisters the old layer's tile adapters before registering the new layer's.
func upsertZoneLayer(_ layer: ZoneLayer)

/// Remove a layer: unregister every one of its tile adapters from the broker,
/// remove its tile subviews + chrome, drop it from the set. No-op if absent.
func removeZoneLayer(zoneId: UUID)

/// Update only a layer's placement (origin/size/color/collapsed) in place;
/// relays its tiles + chrome. (T11 will drive this on live bounds recompute.)
func setZonePlacement(_ placement: ZonePlacement)

/// Test/orchestrator introspection: zoneIds of installed layers, in z-order.
var installedZoneLayerIds: [UUID] { get }
/// Test/orchestrator introspection: the tile ids a layer currently owns.
func tileIds(inZone zoneId: UUID) -> [UUID]
```

**Configurable-first:** T05 introduces **no new binding/threshold/default** — it reuses
`CanvasEngine` transforms, the existing `ZoneChromeFeature.current`, `DragMagnetizeConfig`,
`FocusBorderConfig`, and the persisted zone z-order from `WorkspaceDocument.zoneZOrder`. If
implementation discovers a genuine new tunable (e.g. an inter-layer paint gap), STOP and
add it as a persisted `UserDefaults` default + `SettingsSchema` entry + conflict-guard in
this task per `01` §1.3 — do not hardcode it. (None is expected.)

### NEEDS-HUMAN design fork — where do `activeZone` / `canvasState.tiles` go?
The existing single-zone path stores tiles in **one flat `canvasState.tiles`** and uses
`let activeZone` (CanvasNSView.swift:63–69); `canvasState.tiles` is read in **71 sites
inside `CanvasNSView`** plus from `ZoneRuntimeController`, `TileSpawner`, and
`ContinuumApp`. Two viable shapes — pick ONE with Dylan before the heavy edit (see "Out of
scope / gotchas"): (A) **`canvasState.tiles` becomes a derived/active-layer view** kept in
lockstep with the active layer's `tiles`; or (B) **layers are additive over the existing
single-zone storage** — the active zone keeps using `activeZone`+`canvasState.tiles`
(unchanged) and `ZoneLayer` is the representation for the *additional* installed zones,
with `setZones` adopting the active layer into `activeZone`/`canvasState`. (B) is the
smaller, more bisectable diff and keeps `--single-zone-compat-check` byte-identical; (A) is
cleaner long-term but ripples through the 71 read-sites. This spec is written so the check
holds under **either**, but the executor must confirm the choice (default to B) before
touching the read-sites.

## The check, written FIRST (the spec-as-test)
**Reuse / EXTEND the four existing checks** (all already registered in
`scripts/run-matrix.sh` lines 85–89 and dispatched in `ContinuumApp.swift` lines 290–348 →
`CanvasNSView.run*SelfCheck()`):

| Flag | Static func (CanvasNSView.swift) | Role here |
|---|---|---|
| `--single-zone-compat-check` | `runSingleZoneCompatSelfCheck` (:942) | **must stay byte-identical green** — proves the single-zone path is behavior-neutral after the refactor |
| `--multi-zone-render-check` | `runMultiZoneRenderSelfCheck` (:1078) | **extend** — add the multi-layer install / per-layer hit-test / unregister-on-remove assertions below |
| `--zindex-relaunch-hit-test-check` | `runZIndexRelaunchHitTestSelfCheck` (:874) | must stay green — cross-layer z-order must not regress intra-zone z semantics (docs/23 D2) |
| `--tile-world-bounds-check` | `runTileWorldBoundsSelfCheck` (:1294) | must stay green — per-layer layout still scales world→screen via AppKit frame transform |

The **new behavior** is asserted by EXTENDING `runMultiZoneRenderSelfCheck`. It already
builds a real `CanvasNSView`, installs a real `DescriptorTileNSView` via the production
`install(tileView:for:)`, and reads `tileView(for:)?.frame` / `tileId(at:)`. Add a
**multi-layer block** that drives the NEW real API end-to-end. (No bypass: it must call
`canvas.setZones(...)` / `removeZoneLayer(...)` — the same methods T06/T09 call — and a
**real `FocusBroker`** so adapter registration is observable. Calling a layer's layout/hit
helper directly would be a bypass and COUNTS AS NO CHECK.)

### Setup the extended block synthesizes (hand-derivable fixtures)
- **Use a FRESH `CanvasNSView`** for this block — do NOT reuse the existing `canvas`
  (alpha/beta/gamma) built earlier in `runMultiZoneRenderSelfCheck`; its zoneIds
  `…4811`/`…4812`/`…4813` and tileId `…4821` would collide with the layer fixtures below.
  Build a new `let layerCanvas = CanvasNSView(canvasState: CanvasState(viewport: viewport,
  tiles: [], groups: [], lastActiveTileId: nil), activeZone: nil, zoneRenderModels: [],
  showsZoneChrome: true)` (empty active layer — `setZones` installs everything), and call
  `layerCanvas.layoutSubtreeIfNeeded()` after `setZones`. (Every "canvas." below means
  `layerCanvas`.)
- A real `FocusBroker` instance held by a **strong `let broker = FocusBroker()`** (the
  `CanvasNSView.focusBroker` property is `weak` — a temporary would deallocate mid-check);
  set `layerCanvas.focusBroker = broker` **before** `setZones`. Setting it on an
  empty-active-layer canvas registers only `.canvas` (the per-layer tile adapters are NOT
  in the flat `tileViews` under choice B, so they are registered by `setZones`, not the
  `didSet` — which is exactly the register-on-add path assertion 10 must exercise).
- Two **project** layers + one **group** layer (T01 group zone = `projectId: nil`), all at
  `viewport (0,0, zoom 1)` so screen px == world units:
  - `layerA`: zoneId `…4811`, projectId `…4801`, origin `(0,0)`, size `640×420`, not
    collapsed. One tile `tA` (id `…4821`) frame `(40,52,180,120)` zIndex 1.
  - `layerB`: zoneId `…4812`, projectId `…4802`, origin `(760,0)`, size `640×420`, not
    collapsed. One tile `tB` (id `…4822`) frame `(30,40,200,140)` zIndex 1.
  - `layerG` (group): zoneId `…4814`, projectId `nil`, origin `(0,500)`, size `640×300`,
    not collapsed. One tile `tG` (id `…4824`) frame `(20,30,160,100)` zIndex 1.
  - Each layer's `tileViews` populated with a real `DescriptorTileNSView(tile:)` for its
    tile (the layer's own views, NOT the flat dict).
- `canvas.setZones([layerA, layerB, layerG], zoneZOrder: [A, B, G])`.

### Assertions the extended block enumerates (each hand-derivable)
1. **Installed set + order:** `canvas.installedZoneLayerIds == [A, B, G]` (z-order
   back-to-front, matching the passed `zoneZOrder`).
2. **Per-layer ownership:** `canvas.tileIds(inZone: A) == [tA]`,
   `tileIds(inZone: B) == [tB]`, `tileIds(inZone: G) == [tG]`; no cross-leak.
3. **Per-layer layout — A:** `canvas.tileView(for: tA)?.frame ==
   CanvasEngine.tileScreenFrame(CanvasEngine.worldFrame(tile: tA, in: layerA.placement),
   viewport: (0,0,1))`. With origin `(0,0)` zoom 1 → frame `(40,52,180,120)`.
4. **Per-layer layout — B (non-origin zone):** `tileView(for: tB)?.frame ==
   tileScreenFrame(worldFrame(tB, in: layerB.placement), …)`. layerB origin `(760,0)` →
   world `(790,40,200,140)` → at zoom 1 screen `(790,40,200,140)`. (Proves each layer
   applies ITS OWN origin, not a shared one — this is the core multi-layer correctness.)
5. **Per-layer layout — G (group zone, y-offset):** `tileView(for: tG)?.frame ==
   tileScreenFrame(worldFrame(tG, in: layerG.placement), …)`. layerG origin `(0,500)` →
   world `(20,530,160,100)`. (Proves a group zone — `projectId == nil` — lays out its own
   tiles identically; no project requirement.)
6. **Per-layer hit-test — A:** `canvas.tileId(at: CGPoint(x: 50, y: 60)) == tA`
   (inside `tA`'s world frame `(40,52,180,120)`).
7. **Per-layer hit-test — B:** `canvas.tileId(at: CGPoint(x: 800, y: 50)) == tB`
   (inside `tB`'s world frame `(790,40,200,140)`; outside A entirely — proves hit-test
   resolves the RIGHT layer by world position, not just the active one).
8. **Per-layer hit-test — G:** `canvas.tileId(at: CGPoint(x: 40, y: 560)) == tG`.
9. **Cross-layer z-order paint:** the AppKit subview order (`canvas.subviews.compactMap {
   ($0 as? TileNSView)?.tile.id }`) places `tA` before `tB` before `tG` (zone z-order A<B<G,
   each its single tile) — i.e. a higher-z-order **zone**'s tiles paint above a lower one's,
   independent of intra-zone tile zIndex. (Hand-derivable from `zoneZOrder == [A,B,G]`.)
10. **Adapter register-on-add:** after `setZones`, `broker.requestFocus(.tile(tA), reason:
    .userClick)` returns `true`, and likewise `.tile(tB)` and `.tile(tG)` — every layer's
    tile adapter is registered and focusable. (Drives the REAL broker; a tile view's
    `acquireFocus` makes it first responder.)
11. **Overlap → topmost LAYER wins:** add an overlap probe — `upsertZoneLayer` a new layer
    `layerOver` (zoneId `…4815`, projectId `…4805`) origin `(0,0)` size `200×200` with one
    tile `tOver` (id `…4825`) frame `(10,10,150,150)` zIndex 1, placed **last in z-order**
    (so its `NavigationZone.zIndex` is highest — see impl step 5). Probe at
    `canvas.tileId(at: CGPoint(x: 70, y: 70))` and assert it returns `tOver`, NOT `tA`.
    **The probe point must lie inside BOTH tiles' world frames** so this genuinely proves
    *tile-level* cross-layer resolution (not merely "the top zone has a tile"): `tOver`
    world `(10,10,150,150)` → x∈[10,160], y∈[10,160]; `tA` world `(40,52,180,120)` →
    x∈[40,220], y∈[52,172]; `(70,70)` is inside both. A bug that resolved to the lower
    layer `tA` (wrong zIndex mapping) would return `tA` and fail. (Mirrors the existing
    `zoneId(at:)` "last render model is semantic top" assertion at :1154, but at tile
    granularity across layers.)
12. **Remove layer UNREGISTERS its adapters (the T09 contract):** call
    `canvas.removeZoneLayer(zoneId: B)`. Then assert:
    - `canvas.installedZoneLayerIds` no longer contains `B`;
    - `canvas.tileView(for: tB) == nil` (subview gone);
    - `canvas.tileId(at: CGPoint(x: 800, y: 50)) == nil` (no layer there anymore);
    - **`broker.requestFocus(.tile(tB), reason: .userClick) == false`** (adapter
      unregistered — `FocusBroker.requestFocus` returns false when `adapters[id] == nil`,
      FocusBroker.swift:72). This is THE assertion T09 assertion 3 leans on.
    - The surviving layers are intact: `requestFocus(.tile(tA)) == true` and
      `tileId(at: CGPoint(x: 200, y: 100)) == tA` still hold. **Probe `(200,100)`, NOT
      `(50,60)`** here: assertion 11 left `layerOver` (origin `(0,0)`, tile world
      `(10,10,150,150)`) installed on TOP of A, so `(50,60)` now resolves to `tOver`, not
      `tA`. `(200,100)` is inside `tA`'s world frame `(40,52,180,120)` (x∈[40,220]) but
      outside `tOver`'s (x>160), so it isolates the survivor `tA`.
13. **Single-zone neutrality cross-check (in-place):** unchanged — the separate
    `--single-zone-compat-check` (its own flag) asserts the project `canvas.json` round-trips
    **byte-identical** after a single-zone install; keep it green. (Do not duplicate its body
    here; just do not regress it.)

Add the new fixtures, layers, and assertions 1–12 to `runMultiZoneRenderSelfCheck` and
extend its emitted `manifest.json` with: `installedZoneLayerIds`, `perLayerTileFrames`
(map zoneId → {tileId → frame}), `perLayerHitIds`, `crossLayerSubviewOrder`,
`adapterRegisteredOnAdd` (map tileId → Bool), `overlapTopHitId`, and
`afterRemoveB`: `{ installedIds, tBViewPresent, hitAtB, focusBFalse, aStillFocusable }`.
Keep the existing geometry-snapshot screenshot + `VisualSnapshot.metrics(...).isBlank`
guard (the grey-screen guard) — render a frame with all three layers installed.

**RED first:** the methods `setZones` / `upsertZoneLayer` / `removeZoneLayer` /
`installedZoneLayerIds` / `tileIds(inZone:)` don't exist → the extended check fails to
compile (acceptable RED for the new API surface, per `01` §1.1). Add minimal compiling
stubs (e.g. `setZones` that ignores layers) and re-run → it must then fail on a **behavioral
assertion** (e.g. assertion 4 `tileView(for: tB)` is nil, or 12's `focusBFalse`) — that is
the true behavioral RED. Implement to GREEN.

## Implementation steps
1. **(RED)** Extend `runMultiZoneRenderSelfCheck` with the fixtures + assertions 1–12 above
   and the manifest fields. Add minimal non-functional stubs for the new API so it compiles.
   `swift build` then `.build/debug/continuum-revived --multi-zone-render-check` → confirm it
   fails on a behavioral assertion (NOT only a compile error), and the OTHER three checks
   still pass. If a stub accidentally makes an assertion pass, the assertion is too weak —
   tighten it.
2. **Decide the storage shape** (NEEDS-HUMAN fork above; default B) and add the `ZoneLayer`
   class + a `private var zoneLayers: [ZoneLayer]` + `private var zoneLayerOrder: [UUID]`
   (or fold order into the array) on `CanvasNSView`.
3. Implement `setZones(_:zoneZOrder:)`: diff against current layers → for departing layers
   `focusBroker?.unregister(view.focusSurfaceID)` + `view.removeFromSuperview()` +
   `chrome?.removeFromSuperview()`; for arriving layers `addSubview(tileView)` +
   `focusBroker?.register(tileView)` + install chrome (reuse `installZoneChromeViews`
   path) ; store order. Then `layoutAllTiles()` + `reorderTileSubviewsByZIndex()`.
4. Implement `upsertZoneLayer` (replace-by-zoneId, unregister old tiles before registering
   new) and `removeZoneLayer` (unregister + remove subviews + drop) and `setZonePlacement`
   (mutate in place + relayout that layer). Implement `installedZoneLayerIds` /
   `tileIds(inZone:)`.
5. Generalize `layoutTile(_:)`: resolve the tile's owning layer's placement (instead of the
   single `activeZone`) and use `CanvasEngine.worldFrame(tile:in:)` with that placement;
   honor that layer's `collapsed` for `isHidden`. Generalize `tileId(at:)` to hit-test
   across layers in z-order (collapsed layer suppresses child hits) — route through the
   **existing** `CanvasEngine.hitTest(worldPoint:zones:tilesByZone:)` (CanvasEngine.swift:185,
   returns `ZoneHit?`; the current single-zone `tileId(at:)` at :521–530 already uses it).
   **Exact mapping (load-bearing — assertions 7/9/11 depend on it):** build one
   `CanvasEngine.NavigationZone(id: layer.placement.zoneId, frame:
   CanvasEngine.zoneWorldFrame(layer.placement), zIndex: <z-order index of that layer>)`
   per installed layer, and `tilesByZone[zoneId] = layer.tiles` (zone-local frames). That
   engine `hitTest` sorts zones by `zIndex` **descending** and returns the first containing
   the point with a tile — so the **topmost-painted** layer (LAST in `zoneZOrder`) MUST get
   the **highest** `NavigationZone.zIndex`, i.e. `zIndex = zoneLayerOrder.firstIndex(of:
   zoneId)` (later in order ⇒ higher index ⇒ wins). This is what makes the hit-test
   topmost (assertion 11) agree with the paint topmost (assertion 9). Pass a NavigationZone
   only for non-collapsed layers (or skip collapsed in the build) to preserve the
   collapsed-suppresses-child-hits contract. Note `zones:` is `[NavigationZone]`, NOT
   `[ZonePlacement]` — do not pass placements directly.
6. Extend `reorderTileSubviewsByZIndex()` to sort by (zone z-order index, then tile zIndex)
   across all layers; keep focus-border + drag-ghost overlays topmost (existing tail).
7. **Behavior-neutral single-zone:** ensure the existing init
   (`CanvasNSView(canvasState:activeZone:zoneRenderModels:)`) and `install(tileView:for:)`
   still drive the active layer so `--single-zone-compat-check` and
   `--zindex-relaunch-hit-test-check` pass UNCHANGED (under choice B, the active zone keeps
   its current storage and `setZones` adopts it).
8. **(GREEN)** `swift build` → run the 4 checks individually → fix until all green.
9. Self-review against Acceptance criteria + Review rubric; re-read the diff: every changed
   line traces to T05; orphaned single-zone code your change made dead is removed; no Core
   transform touched; no new monitor; no leader/snap/focus behavior changed.
10. `[overnight]` commit (matrix green): `feat(canvas): mutable ZoneLayer set — per-layer
    layout + hit-test + adapter lifecycle (docs/23 S3)`. Per docs/23 §Risk, keep this as a
    SEPARATE commit from any T06 delegate change. **Stage a morning note** for Dylan to
    eyeball the live add/remove (flicker, z-paint, cursor rects) on the rebuilt bundle — the
    check covers correctness, not visuals.

## Acceptance criteria
- [ ] `ZoneLayer` type + `setZones` / `upsertZoneLayer` / `removeZoneLayer` /
      `setZonePlacement` / `installedZoneLayerIds` / `tileIds(inZone:)` exist on the canvas.
- [ ] `--multi-zone-render-check` asserts (via the REAL `setZones`/`removeZoneLayer` + a real
      `FocusBroker`): installed set+order, per-layer ownership, per-layer layout for A/B/G
      (each its own origin, group zone included), per-layer hit-test, cross-layer z-paint,
      adapter register-on-add, overlap topmost-layer-wins, and **remove → `requestFocus`
      returns false** (unregister-on-remove) with survivors intact.
- [ ] `--single-zone-compat-check` is **byte-identical green** (single-zone behavior-neutral).
- [ ] `--zindex-relaunch-hit-test-check` + `--tile-world-bounds-check` green (intra-zone z +
      world-bounds layout unchanged).
- [ ] No `CanvasEngine` transform changed; no global monitor moved; no leader/snap/focus-
      border behavior changed; no new hardcoded tunable (or it ships configurable per `01`).
- [ ] Fast matrix green; committed as its own bisectable commit; morning visual gate noted.

## Verification commands
```
swift build
# Single check, clean temp env (mirrors run_app_check):
P=$(mktemp -d); A=$(mktemp -d); CONTINUUM_PROJECT_ROOT=$P CONTINUUM_APP_SUPPORT=$A \
  .build/debug/continuum-revived --multi-zone-render-check; rm -rf "$P" "$A"
# The compat + z + bounds guards must also be green:
for f in --single-zone-compat-check --zindex-relaunch-hit-test-check --tile-world-bounds-check; do
  P=$(mktemp -d); A=$(mktemp -d); CONTINUUM_PROJECT_ROOT=$P CONTINUUM_APP_SUPPORT=$A \
    .build/debug/continuum-revived "$f"; rm -rf "$P" "$A"
done
./scripts/run-matrix.sh --fast
```

## Review rubric (adversarial)
- **Bypass audit (most important):** the multi-layer assertions must go through
  `canvas.setZones(...)` / `removeZoneLayer(...)` and a real `FocusBroker` — the SAME path
  T06/T09 will call. If the check builds layers and then calls a private layout/hit helper
  directly, or reads layer state without ever installing through the real API, it is a
  bypass → REWORK. Ask: would assertion 12 still pass if `removeZoneLayer` forgot to call
  `focusBroker.unregister`? It must NOT (that is the whole point).
- **Unregister-on-remove is the bug-magnet:** assertion 12 must probe the broker
  (`requestFocus(.tile(tB)) == false`) — not merely check the subview is gone. A layer that
  drops its view but leaves the adapter registered would silently pass a view-only check and
  break T09. Confirm the false comes from `adapters[id] == nil`, not from `acquireFocus`
  returning false for another reason.
- **Per-layer origin correctness:** re-derive assertion 4 by hand — layerB origin `(760,0)`,
  tile `(30,40,…)` → world `(790,40,…)`. If the check uses origin `(0,0)` for all layers the
  bug (shared origin) hides. The B/G layers MUST be at non-zero, distinct origins.
- **Cross-layer z (D2):** confirm assertion 9/11 derive z from the **zone** z-order, and that
  `--zindex-relaunch-hit-test-check` (intra-zone tile zIndex) still passes — the per-zone
  zIndex semantics it guards must be preserved within a layer.
- **Compat byte-identity:** confirm `--single-zone-compat-check`'s `projectCanvasByteIdentical`
  is still true — the refactor must not perturb the single-zone save path.
- **Scope creep:** diff must not touch `CanvasEngine`, add a monitor, or alter leader/snap.
  Orphans from the old single-`activeZone` path that your change made dead are removed; pre-
  existing unrelated dead code is left (mention, don't delete).
- **Morning items to eyeball** (the check can't see these): flicker on live add/remove,
  z-paint correctness when a layer is upserted on top, cursor-rect (`resetCursorRects`)
  correctness for multiple zone headers, no lost first-responder when the focused tile's
  layer is removed.

## Out of scope / gotchas
- **NEEDS-HUMAN (storage fork):** the `canvasState.tiles` / `activeZone` ownership decision
  (choice A vs B in "Data / API changes") is a real design call — `canvasState.tiles` is read
  in 71 sites inside `CanvasNSView` plus `ZoneRuntimeController` / `TileSpawner` /
  `ContinuumApp`. Default to **B (additive over single-zone storage)** for the smallest,
  bisectable diff that keeps the compat check byte-identical; confirm with Dylan before
  rippling read-sites. If B proves untenable (e.g. T06 needs a uniform per-layer store),
  escalate rather than silently refactoring all 71 sites.
- **NEEDS-HUMAN (no `.zone` focus surface):** the brief says "unregister its tile/**zone**
  focus adapters." `FocusSurfaceID` has only `.canvas` (a single shared surface registered
  once by `CanvasNSView`), `.tile(id)`, `.modal`, `.appChrome`, `.settings`
  (FocusModel.swift:13–19) — **there is no per-zone focus surface today**. So the only
  per-layer adapters to register/unregister are the **tile** adapters; the canvas `.canvas`
  surface is shared and must NOT be unregistered on layer removal. The spec's assertion 12
  therefore targets tile adapters only. If a per-zone focus surface is intended (e.g. for
  zone-level keyboard focus), that is a new `FocusSurfaceID` case + adapter — **out of scope
  for T05**; flag to Dylan / fold into T06/T18, do not invent it here.
- **Coordinate traps:** tiles are zone-local; convert per-layer via
  `CanvasEngine.worldFrame(tile:in:)` then `tileScreenFrame` — never apply two origins.
  `CanvasNSView`/`TileNSView` are `isFlipped` (Y-down). `NSView.hitTest` gets the point in
  the SUPERVIEW's coords — but `tileId(at:)` already takes a screen point and goes through
  `CanvasEngine.screenToWorld`; keep that contract (don't introduce a raw-superview-point
  hit-test).
- **Collapsed layers** suppress child hit-tests (existing `activeZone.collapsed` branch at
  :522–530 and the multi-zone collapsed assertions at :1163) — preserve this per-layer.
- **Stale SourceKit diagnostics are noise** — `swift build` is authoritative.
- **Deferred:** adaptive zone bounds = T11 (here a layer's bounds is still `placement.size`);
  the `WorkspaceRuntime` that calls `setZones` on switch = T06/T09; the move/create-zone
  gestures = T19; ref-counted runtime sharing across layers = T04/T06.
