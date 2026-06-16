# T11 Build Log — Adaptive Zone Bounds

**Task:** Zone chrome bounds = `union(member tile world frames) + padding` instead of stored size.
**Branch:** `overnight/workspaces-zones`
**Model:** claude-sonnet-4-6
**Outcome:** GREEN — all 9 assertions pass; full fast matrix passes (no regressions)

## Files changed

```
Sources/ContinuumRevived/App/ContinuumApp.swift          +12
Sources/ContinuumRevived/Canvas/CanvasNSView.swift       +315 / -3
Sources/ContinuumRevivedCore/CanvasEngine.swift          +44
Sources/ContinuumRevivedCore/SettingsSchema.swift        +3
Sources/ContinuumRevivedCoreChecks/main.swift            +103
scripts/run-matrix.sh                                    +1
```
7 new files including `ZoneBoundsConfig.swift`.

## What was built

**ZoneBoundsConfig** (`Sources/ContinuumRevivedCore/ZoneBoundsConfig.swift`)
- UserDefaults-backed config for zone padding (default 24) and empty-zone min size (480×320)
- Guard table: absent/non-finite/out-of-range values fall through to defaults

**CanvasEngine.zoneBounds** (pure function)
- `zoneBounds(memberFrames:padding:minSize:headerHeight:) -> TileFrame`
- Empty set → returns `(0,0,minWidth,minHeight)` at world origin
- Non-empty → union of member frames, expanded by padding on all four sides, header sits above (y -= padding + headerHeight)

**SettingsSchema wiring**
- 3 new `.text` fields in the `"general"` section: Zone Padding, Zone Empty Min Width, Zone Empty Min Height

**layoutZoneChromeViews rewrite** (CanvasNSView)
- Replaced stored `zoneWorldFrame` with `zoneMemberWorldFrames → zoneBounds → tileScreenFrame` per frame
- Empty zone: uses `ZoneBoundsConfig.emptyMinSize` at the zone's stored origin
- Wired into `updateTile` so every drag commit re-evaluates bounds

**ZoneChromeNSView.headerHeight** promoted to `static let headerHeight: Double = 34`

**runZoneAdaptiveBoundsSelfCheck** (Part B — real-path check)
- 9 assertions through synthesized `NSEvent` move + resize drags
- Assertion 1-2: initial bounds match union formula; chrome screen frame matches
- Assertion 3: bounds grow after tile move (+300 right)
- Assertion 4: bounds.y rises after tile move (−40 up)
- Assertions 5-6: bottom-edge resize +60 / −60 and bounds update live
- Assertion 7: empty zone → exactly min size at stored origin (header not double-added)
- Assertion 8: two overlapping zones compute independently (no neighbor reflow)
- Assertion 9: non-blank render + PNG artifact

**ContinuumApp.swift** dispatch for `--zone-adaptive-bounds-check`
**run-matrix.sh** registration

## TDD trace

RED: CoreChecks compile-failed on unknown `zoneBounds` / `ZoneBoundsConfig` before any implementation.
GREEN: After implementation, all 9 assertions pass. `--zone-adaptive-bounds-check` exits 0.

## Notable bug found and fixed during implementation

Drag-magnetize snap interference: assertion 6 (shrink −60) was clamped to min-height (160) because tile1's bottom edge (y=182) was within the 44-pt snap threshold of tile2's shrink target bottom (y=222). Fixed by injecting `UserDefaults(suiteName: ...)` with `DragMagnetizeConfig.enabledKey = false` on the test canvas before any drags, matching the pattern used by `runFocusBorderSelfCheck`.

The spec listed tile heights of 120 but the derived expected values implied 150 (which is below the `.note` minimum of 160). Changed to height=170 to satisfy the spec's structural assertions while clearing the minimum.

## Matrix result

`./scripts/run-matrix.sh --fast` → Fast matrix passed (no regressions).
`--single-zone-compat-check` passed.
`--multi-zone-render-check` passed (beta adaptive empty-zone bounds updated from stored `640×420` to `480×320`).
