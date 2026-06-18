# T07 — Jump-to-tile framing + subtle camera smoothing

Status: implementation-ready after T12 guardrail, or implement non-animated framing first
Tag: tonight [navigation] [camera]
Depends on: T06
Recommended prerequisite: T12 terminal camera resize stability before enabling animation

## Goal
Jumping to a tile should frame it as a readable focus target, not merely select it at the current zoom. The camera should pan/zoom subtly and predictably, preserving zoom when possible and avoiding terminal/browser instability.

## Implementation decisions
No open UX choice for the overnight agent:

1. **Do not blindly fit every tile.** Preserve current zoom if the target is already readable.
2. **Use readable bands.** Each tile type has a minimum readable zoom.
3. **Use subtle smoothing for programmatic jumps only.** Mouse/trackpad pan and wheel zoom remain immediate.
4. **Cancel/replace animations.** New user input or a new jump cancels the active transition; never queue camera animations.
5. **Push previous view before transition starts** only when the viewport will actually change beyond epsilon.
6. **If T12 guardrails are not implemented yet, implement camera target/framing math and snap-to-target first; leave animation disabled behind a default-off flag.**

## Code seams
Likely files/symbols:

- `Sources/ContinuumRevived/Canvas/CanvasNSView.swift`
  - `centerOnTile(_:)`
  - `setViewport(_:)`
  - likely new `frameTileForJump(_:)` or transition coordinator owner
- `Sources/ContinuumRevivedCore/CanvasEngine.swift`
  - `fit(...)`
  - `centeredViewport(...)`
  - `visibleWorldRect(...)` if present/added
- `Sources/ContinuumRevived/App/ContinuumApp.swift`
  - leader jump handling
  - palette jump handling
- `Sources/ContinuumRevivedCore/LaunchPaletteModel.swift`
  - `jumpToTile`
- New pure helper, suggested:
  - `Sources/ContinuumRevivedCore/CameraFraming.swift`
- New app helper, suggested:
  - `CameraTransitionCoordinator`
  - `CameraTransitionRecorder`

## Framing policy defaults
Use these defaults for the first implementation; tune later with dogfood evidence.

```text
mostlyVisibleAreaRatio = 0.75
tilePaddingScreenPx = 64
zonePaddingScreenPx = 96
minJumpZoom = 0.25
maxJumpZoom = 1.25
finalViewportEpsilonScreenPx = 0.5
```

Readable zoom by tile type:

| Tile kind | Minimum readable zoom | Editable/usable target |
|---|---:|---:|
| note | 0.60 | 0.85 |
| browser | 0.70 | 0.90 |
| terminal | 0.85 | 0.95 |
| file/file-tree/diff/other | 0.70 | 0.90 |

First implementation target:
- if current zoom >= minimum readable zoom and tile is mostly visible: keep zoom and only focus/highlight;
- if current zoom >= minimum readable zoom but tile is clipped/offscreen: pan/reveal with padding, keep zoom;
- if current zoom < minimum readable zoom: zoom to minimum readable zoom, capped at `maxJumpZoom`;
- if tile is larger than viewport at target zoom: fit useful bounds with padding, capped at `maxJumpZoom`; for terminal/browser bias toward top/body rather than arbitrary center if feasible;
- never zoom above `maxJumpZoom` just because a tiny tile could fill the screen.

## Smoothing policy
Default animation:

```text
normalDurationMs = 180
minDurationMs = 120
maxDurationMs = 280
easing = easeOutCubic
```

Rules:
- programmatic leader jump, palette jump, previous-view, and zone jump may animate;
- direct mouse/trackpad pan and wheel zoom do not animate;
- Reduce Motion: snap immediately or use duration <= 50ms;
- active transition count must be 0 or 1;
- user input/new jump cancels existing transition and starts from current viewport;
- no bounce, spring, overshoot, or oscillation.

## Terminal/browser stability guardrails
During any camera transition:
- terminal same-size applied resize delta must be 0;
- webview creation delta must be 0 unless a deliberate hydration transition is documented;
- final viewport lands within epsilon;
- transition recorder writes measured frame count/duration/cancellation.

If T12's terminal stability check is not present, animation must be disabled by default and the ticket may only land framing math + snap-to-target path.

## Acceptance criteria
- [ ] Leader jump and palette jump use the same framing policy.
- [ ] Jump preserves zoom when target is already mostly visible and readable.
- [ ] Jump zooms in only when below tile kind's minimum readable zoom.
- [ ] Target lands visible/readable within final viewport epsilon.
- [ ] Subtle smoothing is cancellable and bounded, or disabled behind default-off flag pending T12.
- [ ] Reduce Motion path snaps/shortens transition.
- [ ] Transition recorder proves no repeated terminal resize and no webview creation during camera-only transitions.
- [ ] Previous view state is captured before transition starts when viewport changes.

## Nightly QA contract

### Required checks
Pure/Core:

```text
CameraFraming table in ContinuumRevivedCoreChecks
```

App flags:

```text
--leader-jump-framing-check
--palette-jump-framing-check
--camera-transition-stability-check   # required only if animation is enabled
```

App checks must use real input/palette paths where practical, not call `centerOnTile` directly.

### Required artifact

```text
qa-runs/<timestamp>/camera-framing/manifest.json
```

Minimum fields:

```json
{
  "check": "leader-jump-framing",
  "startViewport": {"x":0,"y":0,"zoom":0.3},
  "targetViewport": {"x":100,"y":200,"zoom":0.85},
  "finalViewport": {"x":100,"y":200,"zoom":0.85},
  "tileKind": "terminal",
  "readableZoom": 0.85,
  "mostlyVisibleBefore": false,
  "finalViewportErrorScreenPx": 0.2,
  "durationMs": 180,
  "frameCount": 11,
  "cancelled": false,
  "terminalAppliedResizeDelta": 0,
  "webViewCreationDelta": 0,
  "animationEnabled": true
}
```

### Stop conditions
Do not mark Done if:
- implementation uses only `fit`/`center` without readable policy;
- thresholds are left undefined;
- animation ships before terminal stability guardrails exist;
- rapid A→B→C queues multiple transitions instead of cancelling/replacing;
- real leader/palette path is not tested;
- UX “smoothness” is claimed without recorder artifact and manual/PENDING note.

## Verification commands

```bash
swift build
swift run ContinuumRevivedCoreChecks
CONTINUUM_SMOKE_TEST=1 .build/debug/continuum-revived --leader-jump-framing-check
CONTINUUM_SMOKE_TEST=1 .build/debug/continuum-revived --palette-jump-framing-check
CONTINUUM_SMOKE_TEST=1 .build/debug/continuum-revived --camera-transition-stability-check   # if animation enabled
./scripts/run-matrix.sh --fast
```
