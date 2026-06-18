# Canvas navigation feel plan — camera, smoothing, stability

Status: draft brainstorm
Related: T06, T07, T08, T12, T16

## Core feel goal
Canvas navigation should feel like moving a camera through a stable workspace.

The user should feel:
- oriented;
- in control;
- never surprised by wild zoom jumps;
- able to return to the previous view;
- confident that terminals and live tiles remain stable while the camera moves.

## Camera model
Shared language:

- **Camera / viewport:** `x`, `y`, `zoom`.
- **Visible rect:** world-space rectangle currently visible through the camera.
- **Focus target:** tile, zone, selection, or world rect being navigated to.
- **Framing policy:** how much of the target should be visible and at what readable scale.
- **Camera transition:** pan/zoom from current viewport to target viewport.
- **Readable band:** zoom range where a tile type is useful.

## Subtle smoothing
Jumping should not be an instant teleport unless the distance is tiny or motion is disabled.

Default feel:
- duration: ~140–220ms for normal jumps;
- max duration: ~280ms for very large jumps;
- easing: ease-out cubic or similar;
- no bounce, overshoot, spring wobble, or cinematic flourish;
- cancel/replace current transition when the user gives new input;
- respect Reduce Motion: snap instantly or use very short fade/pan.

The animation should communicate spatial movement, not perform a showy effect.

## Framing rules
Prefer preserving zoom when possible.

1. If target is already mostly visible and readable:
   - pan minimally or only focus/highlight;
   - do not zoom.
2. If target is visible but clipped:
   - pan enough to reveal it with padding;
   - only zoom if it is below readable scale.
3. If target is far/offscreen and too small:
   - zoom toward minimum readable scale for its tile type.
4. If target is huge:
   - fit useful bounds with padding;
   - for terminal/browser, bias toward top/title/content start.
5. After landing:
   - briefly pulse/highlight target;
   - push previous camera state to history.

## Stability/performance guardrails
Smoothing must never create unstable UI/UX. We need explicit budgets and instrumentation.

### Camera transition budget
Track per transition:
- start viewport;
- target viewport;
- duration;
- number of frames;
- dropped/late frames if measurable;
- max frame time;
- final viewport error from target;
- whether transition was cancelled/replaced.

Initial target budgets:
- normal jump completes within 300ms;
- no more than one active camera transition at a time;
- final viewport within small epsilon of target;
- no oscillation around target;
- no unbounded chain of layout invalidations.

### Live tile stability budget
During camera transitions:
- terminal PTY/grid must not resize every frame;
- browser webview should not be recreated;
- tile model frames should not mutate unless the action is actually moving/resizing a tile;
- hydration/reconcile should be debounced until the camera settles or intentionally budgeted.

### Visual stability budget
Watch for:
- jitter from fractional pixels;
- jump badge flicker/reassignment during animation;
- labels changing mid-transition;
- terminal bottom/input area being clipped;
- focus border lagging target tile;
- repeated zoom/pan causing accumulated drift.

## Testing strategy

### Pure math tests
- visible rect calculation;
- tile/viewport intersection for jump badges;
- camera target calculation for fit/preserve/readable policies;
- easing monotonicity: viewport moves toward target without overshoot;
- final camera equals target within epsilon.

### Real-path UI checks
Add app checks that synthesize the real leader/palette path rather than calling executors directly:
- hold leader → press label → animated camera transition starts;
- after transition settle, focused tile is visible/readable;
- rapid jump A→B→C cancels/replaces previous transitions cleanly;
- Reduce Motion disables/shortens animation;
- previous-view command restores pre-jump camera.

### Performance/stability checks
Add a small camera-transition recorder:

```swift
struct CameraTransitionSample {
    let reason: CameraTransitionReason
    let durationMs: Double
    let frameCount: Int
    let maxFrameMs: Double
    let cancelled: Bool
    let finalViewportError: Double
    let terminalResizeCountDuringTransition: Int
    let webViewCreationCountDuringTransition: Int
}
```

Assertions for automated checks:
- terminal resize count during jump is 0 or bounded;
- webview creation count during jump is 0;
- transition completes under budget;
- final viewport error is below epsilon;
- no more than one active transition exists.

### Manual dogfood checks
Record short clips for:
- near tile jump;
- far tile jump;
- partially visible tile jump;
- jump to huge terminal/browser;
- rapid sequential jumps;
- jump while terminal is actively printing output;
- jump between zones.

## Implementation sequence for the nightly branch
1. T13: explicit terminal wheel normalizer; remove hidden precise-delta `2x`.
2. T12: terminal body-height alignment + idempotent Ghostty resize; add stability check.
3. T06: visible-intersection jump indicators.
4. T16: readability policy constants + fit-zone framing.
5. T07: camera framing; enable smoothing only after T12 guardrail or behind default-off flag.
6. T08: previous-view/tile/zone history after transition completion semantics exist.

## Decisions for this run
- Smoothing applies to programmatic leader jump, palette jump, previous-view, and zone navigation only.
- Direct mouse/trackpad pan and wheel zoom remain immediate.
- Current zoom percentage UI is deferred; checks must not depend on visible zoom UI.
- Readability minima for this run:
  - note readable: `0.60`, editable/detail: `0.85`
  - browser readable: `0.70`, editable/detail: `0.90`
  - terminal readable: `0.85`, editable/detail: `0.95`
  - zone overview target clamp: `0.20...0.80`
- T07 animation must not ship unless T12 terminal stability guardrails pass or animation is disabled by default.
