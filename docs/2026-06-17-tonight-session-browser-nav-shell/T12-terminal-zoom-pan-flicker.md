# T12 — Terminal zoom-pan stability: body-height alignment + idempotent Ghostty resize

Status: implementation-ready
Tag: tonight [terminal] [performance] [navigation]
Depends on: —
Blocks: animated camera transitions in T07 should not ship without this check or equivalent

## Goal
Reduce terminal flicker, bottom clipping, and scroll/grid jitter during canvas pan/zoom by fixing two concrete terminal sizing problems and adding production-path instrumentation.

Reported symptoms:
- height flicker covering the bottom/typing area;
- scroll/jitter to another terminal section;
- performance spikes while zooming/panning.

## Implementation decision
Do **not** leave this as an open-ended investigation. Implement the first safe stabilization slice:

1. **Body-height alignment:** size the Ghostty surface to the actual terminal body height, not a stale/fixed title-bar subtraction.
2. **Idempotent resize:** do not call `ghostty_surface_set_size` again when the normalized pixel size is unchanged.
3. **Production counters + QA artifact:** prove camera-only pan/zoom does not reflow terminal grid or repeatedly resize Ghostty.

This is low-risk because canvas zoom is navigation. Camera movement should composite/scale the existing terminal surface; it should not resize/reflow the terminal grid.

## Current code seam / likely causes
Relevant files/symbols:

- `Sources/ContinuumRevived/Canvas/CanvasNSView.swift`
  - `func setViewport(_:)`
  - `private func layoutAllTiles()`
  - `private func layoutTile(_:)`
- `Sources/ContinuumRevived/Canvas/TileNSView.swift`
  - `var chromeBarHeight`
  - `private func layoutContentView()`
- `Sources/ContinuumRevived/Canvas/TerminalTileNSView.swift`
- `Sources/ContinuumRevived/TerminalEngine/GhosttyTerminalRuntime.swift`
  - `func setSurfacePixelSize(_:)`
  - `var qaTerminalView`
- `Sources/ContinuumRevived/TerminalEngine/GhosttyTerminalView.swift`
  - `func setSurfacePixelSize(_:)`
  - `func updateSurfaceSize()`

Current path:

```text
CanvasNSView.setViewport
  → layoutAllTiles
  → layoutTile(each tile)
  → terminalTile.runtime.setSurfacePixelSize(worldContentSize × backing)
  → GhosttyTerminalView.setSurfacePixelSize
  → ghostty_surface_set_size(...)
```

Concrete issues found by code audit:

### Issue 1 — repeated same-size Ghostty resize during camera movement
`CanvasNSView.setViewport(_:)` always calls `layoutAllTiles()`. `layoutTile(_:)` always calls `terminalTile.runtime.setSurfacePixelSize(...)` for terminal tiles. `GhosttyTerminalView.setSurfacePixelSize(_:)` currently calls `ghostty_surface_set_size(...)` unconditionally.

During pure pan/zoom, terminal world content size is usually unchanged, so repeated same-size Ghostty resize calls can cause redraw/reflow/compositor churn.

### Issue 2 — fixed title-bar height disagrees with actual chrome height
`TileNSView.layoutContentView()` uses `chromeBarHeight`, which is zoom-dependent:

```swift
chromeBarHeight == max(TileNSView.titleBarHeight, TileNSView.minScreenGrabPx / zoom)
```

But `CanvasNSView.layoutTile(_:)` currently sizes the terminal surface using:

```swift
tile.frame.height - Double(TileNSView.titleBarHeight)
```

At low zoom, actual chrome/body split can be larger than `titleBarHeight`; Ghostty can be sized taller than the visible terminal body, causing bottom clipping/input-area overlap.

## Required implementation

### 1. Use actual terminal body height in `CanvasNSView.layoutTile(_:)`
Change terminal surface height from fixed `titleBarHeight` subtraction to the same chrome/body policy used by `TileNSView.layoutContentView()`.

Suggested implementation:

```swift
if let terminalTile = view as? TerminalTileNSView {
    let backing = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
    let contentWorldWidth = max(0, tile.frame.width)
    let chromeWorldHeight = Double(terminalTile.chromeBarHeight)
    let contentWorldHeight = max(0, tile.frame.height - chromeWorldHeight)
    terminalTile.runtime.setSurfacePixelSize(
        CGSize(width: contentWorldWidth * backing, height: contentWorldHeight * backing)
    )
}
```

Notes:
- `chromeBarHeight` is internal in the same module; prefer reusing it over duplicating the formula.
- This keeps Ghostty's pixel height aligned with the actual visible body frame.
- The app check must assert height/rows, not only width/columns.

### 2. Normalize Ghostty surface pixel size to integer pixels
Represent the actual Ghostty pixel size as integer pixels, not fractional `CGSize`.

Suggested helper:

```swift
struct TerminalSurfacePixelSize: Equatable, Sendable {
    var width: UInt32
    var height: UInt32

    static func from(_ size: CGSize) -> TerminalSurfacePixelSize {
        TerminalSurfacePixelSize(
            width: UInt32(max(0, size.width.rounded(.toNearestOrAwayFromZero))),
            height: UInt32(max(0, size.height.rounded(.toNearestOrAwayFromZero)))
        )
    }
}
```

If this helper needs to live in app/terminal code rather than Core, keep a pure equivalent test seam.

### 3. Make `GhosttyTerminalView.setSurfacePixelSize` idempotent
Add QA-visible state:

```swift
private var lastAppliedSurfacePixelSize: TerminalSurfacePixelSize?
private(set) var qaSurfaceResizeRequestedCount = 0
private(set) var qaSurfaceResizeAppliedCount = 0
private(set) var qaSurfaceResizeSkippedUnchangedCount = 0
```

Behavior:

```swift
func setSurfacePixelSize(_ size: CGSize) {
    guard let surface else { return }
    qaSurfaceResizeRequestedCount += 1
    let next = TerminalSurfacePixelSize.from(size)
    guard next != lastAppliedSurfacePixelSize else {
        qaSurfaceResizeSkippedUnchangedCount += 1
        return
    }
    lastAppliedSurfacePixelSize = next
    qaSurfaceResizeAppliedCount += 1
    ghostty_surface_set_size(surface, next.width, next.height)
    reportSurfaceSize()
}
```

Important:
- repeated viewport zoom/pan with unchanged tile world size and unchanged `chromeBarHeight` should increment requested/skipped, not applied;
- crossing the low-zoom chrome-height floor may legitimately change body height and apply a resize — this must be measured;
- actual tile resize must still apply exactly once per new terminal content size;
- backing-scale change must apply because requested pixel size changes.

### 4. Add production-path app check
Add a check flag, suggested:

```text
--terminal-zoom-pan-stability-check
```

The check should install a real terminal tile in a `CanvasNSView`, then:
1. wait for terminal attach;
2. record baseline Ghostty surface size, rows, and columns;
3. sweep viewport zooms/pans through real `canvas.setViewport(...)`, including zooms below and above the chrome floor threshold (`0.6`, `1.0`, `1.8` is a good start);
4. assert surface size matches expected body size: `tile world width × backing`, `(tile world height - chromeBarHeight) × backing`;
5. assert rows/columns remain stable when expected body size remains stable;
6. assert same-size camera changes skip Ghostty resize applications;
7. perform an actual tile resize and assert a new applied resize occurs;
8. verify terminal input still works after the sweep.

### 5. Emit artifact
Write:

```text
qa-runs/<timestamp>/terminal-zoom-pan-stability/manifest.json
```

Minimum fields:

```json
{
  "check": "terminal-zoom-pan-stability",
  "baselineSurfaceSize": { "width": 1600, "height": 992 },
  "baselineRows": 40,
  "baselineColumns": 120,
  "samples": [
    {
      "viewport": { "x": 0, "y": 0, "zoom": 1.0 },
      "chromeWorldHeight": 24,
      "expectedBodyWorldHeight": 496,
      "surfaceSize": { "width": 1600, "height": 992 },
      "rows": 40,
      "columns": 120,
      "resizeRequestedCount": 1,
      "resizeAppliedCount": 1,
      "resizeSkippedUnchangedCount": 0
    }
  ],
  "sameSizeCameraAppliedResizeDelta": 0,
  "tileResizeAppliedResizeDelta": 1,
  "inputAfterCameraSweepWorked": true,
  "manualVideoPending": true
}
```

## Relationship to camera smoothing / T07
T07 animated jumps may call `setViewport` every frame. T12 must land first or T07 must include equivalent instrumentation.

T07 guardrail:
- same-size terminal applied resize delta during camera-only transition = 0;
- terminal rows/columns do not change unless expected body size changes;
- webview creation count during transition = 0;
- final viewport lands within epsilon.

## Acceptance criteria
- [ ] Terminal surface height uses actual `chromeBarHeight`/body height, not fixed `TileNSView.titleBarHeight`.
- [ ] `GhosttyTerminalView.setSurfacePixelSize` is idempotent for unchanged normalized pixel sizes.
- [ ] QA counters distinguish requested, applied, and skipped-unchanged resize calls.
- [ ] Camera-only same-size pan/zoom does not apply repeated Ghostty surface resizes.
- [ ] Surface width/height and rows/columns are sampled across zooms.
- [ ] Actual tile resize still applies a new Ghostty surface size.
- [ ] Terminal input still works after pan/zoom sweep.
- [ ] Artifact manifest records measured counts/sizes, not constants.

## Nightly QA contract
Required command:

```bash
CONTINUUM_SMOKE_TEST=1 .build/debug/continuum-revived --terminal-zoom-pan-stability-check
```

Also run:

```bash
swift build
swift run ContinuumRevivedCoreChecks
./scripts/run-matrix.sh --fast
```

Reviewer must reject completion if:
- implementation only adds comments/instrumentation but does not fix body height and idempotent resizing;
- counters are test-only constants rather than production-path measurements;
- same-size viewport changes still apply repeated Ghostty resizes;
- height/rows are not asserted;
- terminal input after the sweep is not proven;
- the ticket claims visual flicker is fully fixed without screenshot/video/manual PENDING.

## Manual dogfood / PENDING allowed
This ticket can close with deterministic stability evidence plus a PENDING/manual note for subjective visual flicker.

Manual matrix:
- rapid trackpad pan/zoom while terminal is active;
- zoom sweep while terminal is printing output;
- tmux pane active;
- long scrollback visible;
- typing after zoom/pan;
- watch specifically for bottom/input-line clipping at zoomed-out scales.

If visual flicker remains after this slice, create a follow-up with evidence. Do not keep this ticket open indefinitely.

## Out of scope
- Full camera transition coordinator.
- Full terminal scroll ergonomics — see T13.
- GPU/compositor architecture changes.
- Deep tmux redraw behavior changes.
