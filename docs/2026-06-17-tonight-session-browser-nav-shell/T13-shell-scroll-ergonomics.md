# T13 — Shell scroll ergonomics: explicit wheel normalizer + no hidden precise-delta 2x

Status: implementation-ready
Tag: tonight [terminal] [ux] [performance]
Depends on: —
Related: T12 terminal zoom-pan stability

## Goal
Make shell tile scrolling usable by replacing the hidden hardcoded precise-scroll `2x` multiplier with an explicit, testable terminal wheel normalization policy.

Reported symptom: one scroll moves ~2.5× too far; tmux copy-mode is controllable but awkward.

## Implementation decision
Do **not** leave this as a vague scroll investigation. Implement the first safe terminal-scroll slice:

1. Add a pure `TerminalWheelNormalizer`.
2. Default precise-delta multiplier to **1.0**, not hidden `2.0`.
3. Wire production `GhosttyTerminalView.scrollWheel(with:)` through the normalizer.
4. Add settings/config for future tuning.
5. Add a production-path QA check that synthesizes `scrollWheel(with:)`, records raw/normalized deltas, and proves terminal input still works.

This does not promise full tmux/vim/native-terminal parity. It removes the obvious hidden acceleration and creates evidence for further tuning.

## Current code seam / suspected issue
Primary seam:

- `Sources/ContinuumRevived/TerminalEngine/GhosttyTerminalView.swift`
  - `override func scrollWheel(with event: NSEvent)`
  - `func scrollDirectly(deltaX:deltaY:)`

Current production behavior:

```swift
var x = event.scrollingDeltaX
var y = event.scrollingDeltaY
// Match upstream's 2x speedup for precision deltas; it "feels right."
if event.hasPreciseScrollingDeltas {
    x *= 2
    y *= 2
}
ghostty_surface_mouse_scroll(surface, x, y, 0)
```

The local GhosttyKit header exposes `ghostty_surface_mouse_scroll(surface, Double, Double, mods)` but does not justify doubling precise AppKit deltas. AppKit precise deltas are already high-resolution point deltas, so the hidden `2x` multiplier plausibly explains the reported overscroll.

## Required implementation

### 1. Add `TerminalWheelNormalizer` in Core
Create a pure, AppKit-free normalizer, suggested file:

```text
Sources/ContinuumRevivedCore/TerminalWheelNormalizer.swift
```

Suggested shape:

```swift
public struct TerminalWheelSettings: Equatable, Sendable {
    public var preciseMultiplier: Double
    public var lineMultiplier: Double
    public var maxAbsDeltaPerEvent: Double?

    public static let `default` = TerminalWheelSettings(
        preciseMultiplier: 1.0,
        lineMultiplier: 1.0,
        maxAbsDeltaPerEvent: nil
    )
}

public struct TerminalWheelInput: Equatable, Sendable {
    public var deltaX: Double
    public var deltaY: Double
    public var hasPreciseScrollingDeltas: Bool
}

public struct TerminalWheelOutput: Equatable, Sendable {
    public var deltaX: Double
    public var deltaY: Double
}

public enum TerminalWheelNormalizer {
    public static func normalize(_ input: TerminalWheelInput, settings: TerminalWheelSettings) -> TerminalWheelOutput
}
```

Rules:
- non-finite deltas become `0`;
- precise events use `preciseMultiplier`;
- non-precise events use `lineMultiplier`;
- optional symmetric clamp applies after multiplier if set;
- do **not** invert signs;
- do **not** quantize to integer lines in this slice because Ghostty accepts `Double` and current behavior is continuous.

### 2. Add `TerminalScrollConfig`
Suggested file:

```text
Sources/ContinuumRevivedCore/TerminalScrollConfig.swift
```

Suggested keys:

```swift
public enum TerminalScrollConfig {
    public static let preciseMultiplierKey = "continuum.terminal.scroll.preciseMultiplier"
    public static let lineMultiplierKey = "continuum.terminal.scroll.lineMultiplier"
    public static let maxAbsDeltaPerEventKey = "continuum.terminal.scroll.maxAbsDeltaPerEvent"

    public static let preciseMultiplierDefault = 1.0
    public static let lineMultiplierDefault = 1.0
    public static let maxAbsDeltaPerEventDefault: Double? = nil

    public static func settings(defaults: UserDefaults = .standard) -> TerminalWheelSettings
}
```

Parsing/clamping guidance:
- parse text/defaults as `Double`;
- multiplier allowed range: `0.1 ... 2.0`;
- invalid/missing values fall back to defaults;
- `maxAbsDeltaPerEvent` is optional; if provided, clamp to a sane positive range, e.g. `1 ... 500`.

### 3. Surface settings in SettingsSchema
Add fields to the existing Terminal settings section:

```text
Shell Scroll Precise Multiplier  default "1.0"
Shell Scroll Wheel Multiplier    default "1.0"
```

`maxAbsDeltaPerEvent` can remain hidden/deferred unless implementation already needs it.

### 4. Wire production `scrollWheel(with:)`
Change `GhosttyTerminalView.scrollWheel(with:)` from inline multiplier logic to:

```swift
let settings = TerminalScrollConfig.settings()
let normalized = TerminalWheelNormalizer.normalize(
    TerminalWheelInput(
        deltaX: event.scrollingDeltaX,
        deltaY: event.scrollingDeltaY,
        hasPreciseScrollingDeltas: event.hasPreciseScrollingDeltas
    ),
    settings: settings
)
ghostty_surface_mouse_scroll(surface, normalized.deltaX, normalized.deltaY, 0)
```

Add QA-visible last-sample/counter state on `GhosttyTerminalView`:

```swift
private(set) var qaGhosttyScrollCallCount = 0
private(set) var qaLastWheelSample: TerminalWheelQASample?
```

Sample should include raw deltas, precise flag, normalized deltas, and whether delivery came through production `scrollWheel`.

Important:
- keep `scrollDirectly(deltaX:deltaY:)` as a raw lower-level QA/FFI path; document that it bypasses normalization;
- do not modify scroll modifier bits in this ticket;
- do not change canvas scroll routing except to assert terminal-targeted wheel events do not pan the canvas.

## UX defaults
Default policy:

```text
preciseMultiplier = 1.0
lineMultiplier = 1.0
maxAbsDeltaPerEvent = nil
```

Rationale:
- removes hidden 2x acceleration;
- keeps behavior simple and reversible;
- avoids overfitting without live device samples;
- slower is safer than overshoot for terminal scrollback trust.

If manual dogfood still feels too fast, tune precise multiplier to `0.75` in a follow-up or via user setting. Do not hardcode a new magic multiplier.

## tmux/vim behavior decision
This ticket does not attempt to own tmux/vim scroll semantics.

Document observed behavior for:
- normal shell scrollback;
- tmux mouse off;
- tmux mouse on;
- tmux copy-mode;
- vim/nvim alternate screen.

Escape hatch to document:

```text
prefix + [    enter tmux copy-mode
q / Esc       exit copy-mode
```

A later UX ticket can add a tile action/help hint for tmux copy-mode. T13's implementation scope is wheel magnitude and evidence.

## Acceptance criteria
- [ ] `TerminalWheelNormalizer` exists and is covered by Core checks.
- [ ] Default precise wheel input is **not** secretly doubled.
- [ ] Production `GhosttyTerminalView.scrollWheel(with:)` uses the normalizer.
- [ ] Terminal scroll config parses defaults/user settings with clamp/fallback behavior.
- [ ] SettingsSchema exposes terminal scroll multiplier settings or explicitly documents why hidden config is used for this slice.
- [ ] App check proves production `scrollWheel(with:)` records raw and normalized deltas.
- [ ] Terminal input still works after synthetic scroll events.
- [ ] Manual dogfood matrix is completed or marked PENDING; no claim of native parity without it.

## Nightly QA contract

### Required checks
Pure check:

```text
TerminalWheelNormalizer table in ContinuumRevivedCoreChecks
```

Required app flag:

```text
--terminal-scroll-ergonomics-check
```

The app check must prove:
- production `scrollWheel(with:)` path uses the normalizer;
- default precise event `rawDeltaY = -3` normalizes to `-3 ± 0.001`, not `-6`;
- tuned setting `preciseMultiplier = 0.5` normalizes `-3` to `-1.5 ± 0.001`;
- `ghosttyScrollCallCount == syntheticScrollEventCount`;
- terminal-targeted scroll does not change canvas viewport;
- terminal input works after scroll.

### Required artifact

```text
qa-runs/<timestamp>/terminal-scroll-ergonomics/manifest.json
```

Minimum manifest fields:

```json
{
  "check": "terminal-scroll-ergonomics",
  "settings": {
    "preciseMultiplier": 1.0,
    "lineMultiplier": 1.0,
    "maxAbsDeltaPerEvent": null
  },
  "samples": [
    {
      "rawDeltaX": 0,
      "rawDeltaY": -3,
      "precise": true,
      "normalizedDeltaX": 0,
      "normalizedDeltaY": -3,
      "deliveredViaProductionScrollWheel": true
    }
  ],
  "ghosttyScrollCallCount": 1,
  "canvasViewportChanged": false,
  "inputAfterScrollWorked": true,
  "manualMatrixPending": true
}
```

### Stop conditions
Stop / do not mark Done if:
- implementation bypasses `scrollWheel(with:)` and only calls `scrollDirectly`;
- artifact omits raw or normalized deltas;
- hidden unexplained multiplier remains;
- terminal input breaks after scroll;
- tmux/vim/native parity is claimed without manual evidence;
- scroll changes also alter zoom/pan behavior without T12 artifact evidence.

## Verification commands

```bash
swift build
swift run ContinuumRevivedCoreChecks
CONTINUUM_SMOKE_TEST=1 .build/debug/continuum-revived --terminal-scroll-ergonomics-check
./scripts/run-matrix.sh --fast
```

## Manual dogfood matrix
Minimum manual/PENDING matrix:

| Scenario | Pass threshold |
|---|---|
| Trackpad precise scroll in long shell output | No obvious overshoot; can stop near intended lines |
| Wheel mouse if available | Not sluggish, not wildly accelerated |
| Type after scrolling | Focus/input still trustworthy |
| tmux mouse off | Behavior observed and documented |
| tmux mouse on | Behavior observed; no false claim of app-owned scrollback |
| tmux copy-mode | `prefix + [` enters; `q`/Esc exits; scrolling controllable |
| vim/nvim alternate screen | Does not break app-owned shell scrolling assumptions |

## TDD sketch

```swift
let precise = TerminalWheelNormalizer.normalize(
    TerminalWheelInput(deltaX: 0, deltaY: -3, hasPreciseScrollingDeltas: true),
    settings: .default
)
expect(abs(precise.deltaY - -3) < 0.001, "precise wheel is not secretly doubled by default")

let tuned = TerminalWheelNormalizer.normalize(
    TerminalWheelInput(deltaX: 0, deltaY: -3, hasPreciseScrollingDeltas: true),
    settings: TerminalWheelSettings(preciseMultiplier: 0.5, lineMultiplier: 1.0, maxAbsDeltaPerEvent: nil)
)
expect(abs(tuned.deltaY - -1.5) < 0.001, "lower precise multiplier reduces jumpiness")

let nonFinite = TerminalWheelNormalizer.normalize(
    TerminalWheelInput(deltaX: .nan, deltaY: .infinity, hasPreciseScrollingDeltas: true),
    settings: .default
)
expect(nonFinite.deltaX == 0 && nonFinite.deltaY == 0, "non-finite deltas are sanitized")
```
