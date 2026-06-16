# T05 Build Report

## Summary

Implemented `ZoneLayer` reference type and the full mutable canvas API on `CanvasNSView`. Storage shape B (additive over single-zone). Extended `runMultiZoneRenderSelfCheck` with assertions 1–12 covering the complete multi-layer lifecycle: install/order, per-layer ownership, per-layer layout (A at origin, B at non-origin 760,0, G group zone at y-offset 500), per-layer hit-test, cross-layer z-paint order, adapter register-on-add, overlap topmost-layer-wins (assertion 11), and unregister-on-remove with broker probe (assertion 12d — the T09 contract).

## Files touched

- `Sources/ContinuumRevived/Canvas/CanvasNSView.swift`

## git diff --stat

```
Sources/ContinuumRevived/Canvas/CanvasNSView.swift | 337 ++++++++++++++++++++-
 1 file changed, 327 insertions(+), 10 deletions(-)
```

## RED output (before implementation)

```
FAIL: assertion 3: tA frame should be (40.0, 52.0, 180.0, 120.0), got nil
Exit: 1
```

The check compiled (stubs were enough) and failed on a behavioral assertion — `tileView(for: tAId)` returned nil because `layoutAllTiles` and `tileView(for:)` did not yet consult the zone layers.

## GREEN output (after implementation)

```
ContinuumRevivedMultiZoneRenderChecks passed: .../qa-runs/multi-zone-render-.../manifest.json
Exit: 0
```

## Fast matrix result

```
Fast matrix passed.
```

All 4 individual checks green:
- `--single-zone-compat-check`: pass (byte-identical — single-zone path unchanged)
- `--zindex-relaunch-hit-test-check`: pass
- `--tile-world-bounds-check`: pass
- `--multi-zone-render-check`: pass (all 12 new assertions green)

## Deviations from spec

None. Followed spec step-by-step.

- Storage shape B: active zone retains `activeZone`+`canvasState.tiles`; `ZoneLayer` is additive.
- `ZoneLayer` is a nested `@MainActor final class` as per spec.
- `tileView(for:)` extended to search zone layers (needed so assertions 3/4/5/12b work).
- `layoutAllTiles()` extended to lay out zone layer tiles and their chrome.
- `tileId(at:)`: multi-layer path engaged when `zoneLayers` is non-empty; builds NavigationZones with `zIndex = position in zoneLayerOrder`; single-zone path unchanged.
- `reorderTileSubviewsByZIndex()`: extended to 3-component key `[zoneIndex, tileZIndex, tileArrayIndex]`; single-zone tiles get `zoneIndex = 0`; zone layer tiles get `zoneIndex = layerOrderPosition + 1`; preserves existing intra-zone zIndex semantics.
- `focusBroker.didSet` only iterates `tileViews` (the flat single-zone dict) — correct under choice B because zone layer adapters are registered by `setZones`/`upsertZoneLayer`, not by the broker didSet.
- No new hardcoded tunables; no configurable bits needed (spec confirmed none expected).

## Self-assessment against Acceptance criteria

- [x] `ZoneLayer` type + all 6 API methods exist on the canvas.
- [x] `--multi-zone-render-check` asserts via real `setZones`/`removeZoneLayer` + real `FocusBroker`: installed set+order (1), per-layer ownership (2), per-layer layout A/B/G (3/4/5), per-layer hit-test (6/7/8), cross-layer z-paint (9), adapter register-on-add (10), overlap topmost-layer-wins (11), remove → `requestFocus` returns false (12d).
- [x] `--single-zone-compat-check` byte-identical green.
- [x] `--zindex-relaunch-hit-test-check` + `--tile-world-bounds-check` green.
- [x] No `CanvasEngine` transform changed; no global monitor moved; no leader/snap/focus-border behavior changed; no new hardcoded tunable.
- [x] Fast matrix green.
- [ ] Commit not yet made (task tag is `[morning]` so this is staged for Dylan's visual gate).

## Morning items for Dylan to eyeball

- Flicker on live add/remove of a zone layer (the check can't see this).
- Z-paint correctness when a layer is upserted on top (visual confirmation).
- Cursor-rect (`resetCursorRects`) correctness when multiple zone layer chromes are installed.
- No lost first-responder when the focused tile's layer is removed via `removeZoneLayer`.
