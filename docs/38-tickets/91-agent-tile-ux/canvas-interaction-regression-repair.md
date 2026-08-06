# Canvas interaction regression repair evidence

Date: 2026-08-06
Status: implemented and focused-headless verified; not manually/end-to-end verified
Base commit: `14bfc68e107d63b4f67b29006e806272a2276c70`
Branch: `overnight/agent-ux`

## Scope

Three owner-reported regressions:

1. Cmd-drag over a previously selected tile resized the tile instead of panning the canvas.
2. Tile resizing appeared to work only from the top corners.
3. Zone header/background paint escaped the zone's rounded top-right corner.

The release-candidate app already running for Queue 94 P3.6 was not quit, relaunched, probed, or
used for these checks. Every self-check ran from a temporary current directory and temporary HOME.
No owner store or committed visual baseline was read, changed, or blessed.

Original visual report:

`/var/folders/3s/qqwk1k6n6dq40lmvnzh_jzcw0000gn/T/pi-clipboard-97fd2ee3-63b3-4ffd-9ef0-e669546c5ada.png`

## Root causes

### Bottom/side resize routing

`TileNSView.hitTest(_:)` receives its point in the coordinate system of the tile's superview. The
implementation treated that canvas/superview point as if it were already in tile-local bounds.
That worked accidentally near the canvas origin but missed bottom, left, right, and bottom-corner
rings for panned/non-origin tiles. Body subviews then consumed those presses. The top appeared to
work because the title bar has its own forwarding path.

Authoritative AppKit contract:

<https://developer.apple.com/documentation/appkit/nsview/hittest(_:)?changes>

> A point that is in the coordinate system of the view's superview, not of the view itself.

The resize classifier and `CanvasEngine` resize math already supported all edges/corners. The repair
is limited to converting the incoming superview point into the tile's local coordinates before ring
and grab-strip classification.

### Cmd-drag precedence

The canvas had a Space-held pointer-pan path but no Cmd-drag path. `TileNSView.mouseDown` classified
resize before inspecting modifiers, so a Cmd press delivered to a tile resize ring became a resize.
Selection/focus state was incidental; the ring was active whether or not its chrome was visibly
selected.

The repair centralizes pointer-pan state and camera math in `CanvasNSView`. Canvas background and
tile chrome both ask the canvas whether Cmd or canvas-owned Space requests pan, then use the same
begin/continue/end lifecycle. Tile chrome checks this before resize/move classification.

Interception remains limited to canvas/tile chrome events. Cmd-clicks or Space typing delivered to
terminal, browser, text, and other body content are not globally swallowed.

The shared lifecycle also keeps cursor-stack ownership explicit when Space is released during a
drag: closed-hand teardown happens before a deferred open-hand pop.

### Zone clipping

`ZoneChromeNSView.draw(_:)` filled `zoneRect` and `headerRect` as rectangles, stroked only the
rounded outline, and painted the header after the stroke. A border is not a clipping mask, so the
semi-transparent teal header remained square and could cover the outline.

The repair creates one rounded path, clips all interior body/header/text drawing to it, restores the
graphics state, and strokes the outline last.

## Changed production seams

- `Sources/ContinuumRevived/Canvas/TileNSView.swift`
  - correct superview-to-local hit-test conversion;
  - Cmd/Space pan precedence before tile resize/move;
  - `.canvasPan` drag state delegates drag/up to the canvas.
- `Sources/ContinuumRevived/Canvas/CanvasNSView.swift`
  - shared `pointerPanRequested`, begin, continue, and end lifecycle;
  - balanced Space/open-hand and pointer-pan/closed-hand cursor state;
  - rounded zone interior clipping and outline-last drawing.

## Regression coverage

### `--tile-drag-grab-check`

The expanded check uses a real `NSWindow` hierarchy and panned/zoomed canvas.

- Starts at `canvas.hitTest(...)` using the documented canvas-superview coordinate contract.
- Requires bottom, left, right, bottom-left, and bottom-right ring points to resolve to
  `TileNSView`, while a deep body point does not.
- Drives real tile mouse down/drag/up handlers from all four production-routed corners.
- Requires both axes to grow and the correct top/left origin edges to move.
- Starts Cmd-pan and Space-pan on a selected tile's bottom-right resize ring.
- Requires each pan to change the viewport and preserve the tile frame.
- Retains low-zoom grab-strip, title-bar, body, and top-edge assertions.

Final manifest:

`/tmp/continuum-tile-corners.Ob5OOs/qa-runs/2026-08-06T142607Z/tile-drag-grab/manifest.json`

Key results:

```text
pointerPanProductionHitRoutedToTile = true
commandPanPreservedTileFrame        = true
commandPanChangedViewport           = true
spacePanPreservedTileFrame          = true
spacePanChangedViewport             = true
cornerResizeProductionPasses:
  topLeft     = true
  topRight    = true
  bottomLeft  = true
  bottomRight = true
ringReclaim:
  bottom      = true
  left        = true
  right       = true
  bottomLeft  = true
  bottomRight = true
```

### `--multi-zone-render-check`

The check renders the real `ZoneChromeNSView` on transparency. It requires a visible interior header
pixel and a nearly clear pixel at the extreme rounded top-right corner. The sampled values are saved
in the manifest rather than existing only as transient assertions.

Final manifest:

`/tmp/continuum-zone-final.BwGUed/qa-runs/multi-zone-render-0392CCAA-2003-433D-A1AD-BA1D870F436D/manifest.json`

```text
cornerAlpha                 = 0
interiorHeaderAlpha         = 0.31764705882352939
cornerToInteriorAlphaRatio  = 0
```

## RED evidence

Before production repair, using corrected/new assertions:

```text
--tile-drag-grab-check
FAIL: ... resize ring ...
[bottomLeft:false, right:false, bottomRight:false, bottom:false, left:false]
```

Log: `/tmp/continuum-tile-red.0GfFR1/output.log`

```text
--multi-zone-render-check
FAIL: zone header/background escaped the rounded top-right clip
corner alpha 0.23921568627450981
interior alpha 0.3176470588235294
```

Log: `/tmp/continuum-zone-red.EY4YaD/output.log`

After only the hit-test and clipping repairs, the zone check passed and the tile check advanced to
the independent Cmd precedence failure:

```text
FAIL: Cmd+drag from a selected tile's resize ring resized the tile instead of preserving its frame
```

Log: `/tmp/continuum-tile-stage1.DGiDKY/output.log`

This separates the resize-routing defect from the Cmd-pan defect rather than treating one changed
test as proof of both.

## Final focused GREEN evidence

Build:

```text
swift build — PASS
```

Final build log: `/tmp/continuum-canvas-fixes-build-corner.log`

One intermediate build of the new four-corner test failed because its first typed closure omitted
the required unused parameter. The closure was corrected and the next build passed; no production
code was changed to hide the compile failure.

Checks, all PASS:

| Check | Artifact |
|---|---|
| `--tile-drag-grab-check` | `/tmp/continuum-tile-corners.Ob5OOs/qa-runs/2026-08-06T142607Z/tile-drag-grab/manifest.json` |
| `--multi-zone-render-check` | `/tmp/continuum-zone-final.BwGUed/qa-runs/multi-zone-render-0392CCAA-2003-433D-A1AD-BA1D870F436D/manifest.json` |
| `--tile-world-bounds-check` | `/tmp/continuum-world-final.mabuUl/qa-runs/2026-08-06T142629Z/tile-world-bounds/manifest.json` |
| `--zone-resize-check` | `/tmp/continuum-zresize-final.NcZbIE/qa-runs/zone-resize-AA6B6F4C-C064-4D88-A365-308D0D36CD8C/manifest.json` |
| `--zone-chrome-zorder-check` | `/tmp/continuum-zzorder-final.hwVdXI/qa-runs/zone-chrome-zorder-2638B2AA-DDFE-4799-99F3-1F108A3E25AD/manifest.json` |
| `--resize-snap-check` | `/tmp/continuum-rsnap-final.i5NTX9/qa-runs/2026-08-06T142629Z/resize-snap/manifest.json` |

Final `git diff --check` — PASS.

## Independent review record

Read-only project `code-reviewer` run:

`.pi/agent-runs/code-reviewer-20260806T141836Z-074f08/final.md`

Accepted finding:

- Space-held drag over tile chrome was not entering the shared pointer-pan lifecycle.
- Production-route and Space-drag checks were missing.

Repair:

- Tile chrome now asks `CanvasNSView.pointerPanRequested(for:)`, covering Cmd and canvas-owned
  Space before resize/move.
- The check now begins at the canvas/window hit-test route and covers Space-pan.

Rejected finding:

- The reviewer stated that `NSView.hitTest(_:)` receives local coordinates. Apple documents the
  opposite: the point is in the receiver's superview coordinate system. The implementation was not
  reverted to the known-bad local assumption. The production-route check was strengthened instead.

The first review's verdict was `REWORK`. A second and final read-only review assessed the repaired
Space lifecycle, production canvas hit-test route, all-corner gestures, Apple coordinate contract,
and rounded pixel oracle:

`.pi/agent-runs/code-reviewer-20260806T142754Z-ae3bf8/final.md`

Final review verdict: `DECISION: APPROVE`.

## Verification limits

- These checks exercise real AppKit view hierarchies, hit-test routing, mouse handlers, layout, and
  rendered pixels in headless windows.
- They are not evidence that the exact user interaction has been manually repeated in a launched
  application.
- Cursor appearance/stack balance is not directly introspectable; lifecycle branches are covered,
  but human cursor/taste verification remains appropriate.
- Rounded antialiasing and visual taste still require owner inspection.
- No visual baseline was compared or blessed for this repair.
- Nothing is committed or pushed.
