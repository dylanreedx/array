# T06 — Camera-aware jump indicators for partially visible tiles

Status: implementation-ready
Tag: tonight [navigation] [camera]
Depends on: —
Blocks: T07

## Goal
When hold-leader/jump navigation is active, every tile that is meaningfully visible through the current camera should have a visible, readable jump indicator. If only part of a tile is visible, place the indicator inside the visible part of that tile instead of at the tile center/title area offscreen.

## Mental model
The viewport is a camera. A tile can intersect the camera even when its origin, center, or title bar is outside the frame. Jump indicators must be projected into the **visible intersection** between tile and camera.

## Implementation decisions
No open UX choice for the overnight agent:

1. **Eligibility:** normal jump mode includes tiles whose screen frame intersects the canvas viewport. Fully offscreen tiles do not get labels.
2. **Placement:** place the badge inside `tileScreenFrame ∩ viewportBounds`, inset by padding.
3. **Tiny slivers:** if the visible intersection cannot fit a normal badge plus padding, render a deterministic edge pill/chevron anchored inside the intersection near the closest viewport edge. Do not suppress the tile solely because it is a sliver.
4. **Stability:** label/key assignment order remains the existing deterministic tile order; placement changes must not reorder labels.
5. **No flicker:** while jump mode is open, camera movement must not reassign labels unless the eligible tile set actually changes.

## Code seams
Likely files/symbols:

- `Sources/ContinuumRevived/Canvas/CanvasNSView.swift`
  - `leaderJumpAssignments()`
  - `leaderJumpTarget(forLabel:)`
  - `NavModeOverlayNSView.drawTileLabels` / overlay drawing path
- `Sources/ContinuumRevivedCore/TileArrangement.swift`
  - `jumpLabels(for:alphabet:)`
- New pure helper, suggested:
  - `Sources/ContinuumRevivedCore/JumpIndicatorPlacement.swift`

Do not add a second label assignment source. The drawn badge and pressed key must both come from the same assignment list.

## Geometry policy
Suggested types:

```swift
public enum JumpIndicatorPlacementKind: Equatable, Sendable {
    case normal
    case edgePill(edge: ViewportEdge)
}

public struct JumpIndicatorPlacement: Equatable, Sendable {
    public var point: CGPoint
    public var kind: JumpIndicatorPlacementKind
    public var visibleIntersection: CGRect
}
```

Default constants:

```text
badgePaddingScreenPx = 12
normalBadgeMinScreenSize = 28 × 24
sliverThreshold = normalBadgeMinScreenSize + 2 × padding
```

Rules:
- convert tile world frame to screen frame using existing `CanvasEngine.tileScreenFrame`;
- compute intersection in screen/canvas coordinates;
- normal badge point should be inside `intersection.insetBy(dx: padding, dy: padding)` when that inset is non-empty;
- otherwise use `.edgePill` and clamp point inside the raw intersection and viewport bounds;
- offscreen/no-intersection returns nil/no placement.

## Acceptance criteria
- [ ] Partially visible tiles get visible jump indicators.
- [ ] Fully visible tiles keep expected/current label assignment behavior.
- [ ] Tiny slivers use deterministic edge-pill/chevron placement inside the visible intersection.
- [ ] Offscreen tiles do not render badges in normal jump mode.
- [ ] Badge/key identity remains stable; placement changes do not reorder labels.
- [ ] Geometry is covered by pure tests.
- [ ] Real leader path check proves overlay placement, not only math.

## Nightly QA contract

### Required checks
Pure/Core:

```text
JumpIndicatorPlacement table in ContinuumRevivedCoreChecks
```

App flag:

```text
--leader-jump-visible-indicators-check
```

The app check must:
- create a canvas with tiles clipped left/right/top/bottom/corner plus one fully offscreen tile;
- open leader mode via real `.flagsChanged` path where practical;
- capture overlay assignments/placements from production overlay path;
- assert every visible/clipped tile has a badge point inside viewport bounds and inside the visible intersection or edge-pill rule;
- assert offscreen tile has no badge;
- write artifact manifest.

### Required artifact

```text
qa-runs/<timestamp>/leader-jump-visible-indicators/manifest.json
```

Minimum fields:

```json
{
  "check": "leader-jump-visible-indicators",
  "viewportBounds": {"x":0,"y":0,"w":1200,"h":800},
  "placements": [
    {
      "tileId": "...",
      "label": "a",
      "tileScreenFrame": {"x":900,"y":100,"w":400,"h":300},
      "visibleIntersection": {"x":900,"y":100,"w":300,"h":300},
      "badgePoint": {"x":912,"y":112},
      "kind": "normal",
      "insideVisibleIntersection": true
    }
  ],
  "offscreenTilesLabeled": 0
}
```

### Stop conditions
Do not mark Done if:
- check calls only pure geometry and does not exercise production assignment/drawing seam;
- badge placement is computed from tile center/title without clipping to visible intersection;
- tiny sliver policy is left as a choice;
- label assignment and drawing can diverge.

## Verification commands

```bash
swift build
swift run ContinuumRevivedCoreChecks
CONTINUUM_SMOKE_TEST=1 .build/debug/continuum-revived --leader-jump-visible-indicators-check
./scripts/run-matrix.sh --fast
```
