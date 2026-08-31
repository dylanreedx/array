# WS1 dispatch — zone HUD and non-destructive layout

Use only as part of a self-contained rendered dispatch. The fully rendered common protocol prepended by root is binding; the checked-in `00-agent-protocol.md` is an unresolved reference template.

## Shared workstream target

This packet defines **WS1: zone resize HUD and non-destructive resize/auto-layout** in Array. The rendered `<ROLE>` controls authority: a lead implements; a reviewer or tester evaluates the same locked target under only its selected overlay.

Read `<WORKTREE>/AGENTS.md`, `<WORKTREE>/.plans/54-array-0.8.0-overnight-orchestration.md`, and `<WORKTREE>/.plans/54-prompts/00-agent-protocol.md` completely. Work only in `<WORKTREE>` at `<BASE_SHA>`. Store evidence under `<EVIDENCE_DIR>`.

### Outcome

Make direct manipulation trustworthy:

- Tile resize changes only the active tile and minimally expands its owning zone when required. Every passive tile world frame and size stays byte-for-byte equal.
- Manual zone resize changes only that zone's placement. It never packs or shrinks members and never pushes peer zones or outside tiles. Clamp inward edges to the padded member envelope; overlap on outward growth is allowed.
- Only explicit Tidy or deliberate drop/slot exchange may broadly reflow tiles.
- The dimensions HUD appears for tile and zone resize, updates from the real drag path in world dimensions, and disappears on mouse-up, cancellation, lost mouse capture, or window resignation. It remains noninteractive and ignored by accessibility.
- Flat canvas and hydrated `ZoneLayer` scenes obey the same contract. Render mirrors and persistence callbacks see the committed placement immediately.

### Known defects and false greens

- `CanvasNSView` incorrectly shows the HUD during an auto-layout zone **move**, leaks it on move mouse-up, and never shows it during zone **resize**. The corrected witness must assert that moving a zone shows no dimensions HUD at all.
- `CanvasAutoLayoutEngine` currently shrinks passive neighbors under tile-resize pressure before growing the zone.
- The `.zone` resize mutation currently repacks members and propagates collisions into neighboring zones.
- `growZoneToFitMembers` has a flat-model blind spot for hydrated layer tiles.
- `applyLayoutTransaction` does not update every zone render mirror.
- Current `runCanvasAutoLayoutChecks` expectations explicitly require the unwanted shrink/reflow/push behavior. Rewrite those behavioral expectations; do not preserve them merely to keep old checks green.

### Inspect first

- `Sources/ContinuumRevivedCore/CanvasAutoLayoutEngine.swift`
- `Sources/ContinuumRevivedCore/CanvasAutoLayoutConfig.swift`
- `Sources/ContinuumRevivedCore/ResizeHUDConfig.swift`
- `Sources/ContinuumRevivedCore/ZoneBoundsConfig.swift`
- `Sources/ContinuumRevived/Canvas/CanvasNSView.swift`
- `Sources/ContinuumRevived/Canvas/ResizeDimensionsOverlayView.swift`
- `Sources/ContinuumRevived/Canvas/CanvasFrameHUDView.swift`
- `Sources/ContinuumRevived/Canvas/TileNSView.swift`
- the auto-layout section of `Sources/ContinuumRevivedCoreChecks/main.swift`
- existing zone/HUD checks and their dispatch in `ContinuumApp.swift` and `scripts/run-matrix.sh`

### Owned scope

You own the files above only where required for this contract, plus new focused check files. You have a narrow grant for check dispatch/registration in `ContinuumApp.swift` and `scripts/run-matrix.sh`. Do not edit workspace save/close ownership, transcript code, background settings, or unrelated canvas behavior.

### Required witnesses

1. A pure/reducer witness over at least 100 deterministic seeded scenes:
   - horizontal, vertical, and corner tile resize;
   - flat and layered zones;
   - unequal multi-row members;
   - neighboring zones and an outside tile;
   - auto-layout global/on/off/inherit.
   - Assert passive tile frames exact, non-active zone placements exact, active zone equals the minimal required union+padding when it must grow, and only the explicit user-invoked **Tidy Zone Now** action may broadly change member frames.
2. A production AppKit event witness, repeated 10 times per gesture:
   - actual mouseDown/drag/mouseUp for tile and zone resize at canvas zoom 0.50, 1.00, and 1.50;
   - cancel/lost capture/window resign paths;
   - HUD visible only during resize, never during zone move, text matching snapped world dimensions within 0.5 pt, and gone by the next run-loop turn;
   - member and peer frames unchanged within exact model equality and 0.5 pt rendered tolerance.
3. Immediate fit/navigation after the transaction must read the new placement, proving render mirrors are synchronized.
4. Non-auto-layout layered zone growth must include hydrated member frames.
5. The explicit user-invoked **Tidy Zone Now** action retains its independent reflow test and undo behavior. Identical scenes must not broadly reflow from resize, focus, save, hydration, or automatic layout settlement.

Capture `reference`, `mid-drag`, `after-release`, `clamped-shrink`, `cancelled`, and `explicit-tidy` in Aqua and Dark Aqua. The primary visual fixture is two visible zones and six unequal tiles in a `1440×900 pt` content area. Store semantic world/local frames and HUD text beside each PNG. Root must be able to open every image by absolute path.

### Required commands

Build the relevant products before trusting results. At minimum run and retain:

```sh
export CONTINUUM_PROJECT_ROOT="<QA_PROJECT_ROOT>"
export CONTINUUM_APP_SUPPORT="<QA_APP_SUPPORT>"
export TMUX_TMPDIR="<QA_TMUX_TMPDIR>"
unset TMUX TMUX_PANE
swift build
swift run ContinuumRevivedCoreChecks
.build/debug/Array --resize-dimensions-hud-check
.build/debug/Array --zone-resize-check
.build/debug/Array --zone-adaptive-bounds-check
.build/debug/Array --jelly-auto-layout-check
.build/debug/Array --resize-snap-check
scripts/check-matrix-inventory.sh
```

Run the new focused check directly and prove its invocation appears in a real matrix run. Use isolated app/project state for every AppKit launch.

### Stop rules

Stop rather than widening scope if preserving passive frames requires changing workspace persistence ownership, if another branch owns the same `CanvasNSView` hunk, or if the desired contract conflicts with deliberate drop/slot exchange. Report the exact seam. Do not solve manual resize by disabling all auto layout or the explicit **Tidy Zone Now** action.

### Success

All direct resize cases preserve unrelated geometry, the HUD lifecycle is finite on every exit path, **Tidy Zone Now** remains the explicit functional reflow command, layered and flat scenes agree, new RED/GREEN/tooth evidence exists, and no unexpected matrix failure is introduced.

## Independent reviewer overlay

Review production event → layout engine → render mirrors → persistence callback. Reject any fix that only changes the QA path, hides the HUD without clearing lifecycle state, rounds in screen coordinates, disables auto layout globally, or replaces unwanted reflow with silent overlap correction elsewhere. Verify old expectations enforcing passive shrink/peer push were intentionally inverted and only the user-invoked **Tidy Zone Now** path retains broad reflow coverage.

## Independent tester overlay

In a clean candidate checkout, drive tile resize, zone resize, zone move, inward clamp, cancel, lost capture, window resign, and user-invoked **Tidy Zone Now** through real events 10 times. Batch all 10 semantic/geometry repetitions, then capture one deterministic representative PNG per unique visual state/zoom/appearance plus every failure—do not multiply captures by repetition count. FAIL on any passive/member/peer movement over 0.5 pt, any model inequality where exact equality is promised, any HUD during zone move, any HUD surviving one run-loop turn, or any missing matrix invocation.
