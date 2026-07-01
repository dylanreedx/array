# Jump-to-tile via sidebar row click

## What this delivers

Clicking a tile row in the left dock pans the canvas to that tile and transfers keyboard focus to it — the same result you get from the command palette's "Jump to…" action, just driven by the sidebar instead. After this ticket, a user can glance at the dock, see which tile holds the agent that needs them, click it, and land on that tile without touching the keyboard. The sidebar row becomes a first-class navigation entry point, not a decorative selection list. The existing `workspace → zone → tile` expansion is already in place; this is the last wire between "clicking a tile row" and "the canvas actually moving."

This ticket rests on **decision D21** (activity surface = persistent left dock; "jump-to-tile reuses the **existing `focus(tileId:)`** plumbing — one resolver for sidebar click, leader-jump, and palette-jump"). It does not reopen D21: it does not add a second resolver, it verifies the one D21 names. The shared resolver here is `jumpToTileFromPalette`, which both the palette and `focusTileFromSidebar` call.

## How it fits

The activity surface work established the left dock as the fleet index: `WorkspaceSidebarView` renders the `workspace → zone → tile` tree, rows fire `onSelection` callbacks, and `handleWorkspaceSidebarSelection` in the main app delegate routes those callbacks. The routing for workspace and zone rows is already complete and test-covered. The tile-row branch calls `focusTileFromSidebar`, which delegates immediately to `jumpToTileFromPalette` — the same function the command palette uses for its "Jump to tile" action (this single-resolver reuse is exactly what D21 locks). The viewport-pan-and-focus plumbing exists end-to-end; this ticket verifies the routing is correct, extends the existing real-path check to also assert the viewport moved (the zone-row assertion already does this; the tile-row assertion currently only checks broker scope and `lastActiveTileId`, not the camera position), and adds the Component Lab visual gate that the UX contract requires.

This ticket unblocks the "replace mock rollup with real observer data" work: once a user can jump to a tile from the dock, the dock becomes the primary attention-response loop and the correctness of the jump matters in practice, not just in theory. It also closes the one remaining gap in the `runWorkspaceSidebarActionsSelfCheck` check's tile-row coverage.

## The approach

The routing path is already assembled. `WorkspaceSidebarView.outlineRowClicked` fires `performSelection`, which fires `onSelection?(selection)`. The app delegate has `onSelection` wired to `handleWorkspaceSidebarSelection` (configured in both `configureWorkspaceSidebar` and the test scaffold at the `runWorkspaceSidebarActionsSelfCheck` setup). For a `.tile` selection, `handleWorkspaceSidebarSelection` calls `focusTileFromSidebar(tileId)`, which guards on `canvasView.navigationTileSnapshot(for:)` existing, then calls `jumpToTileFromPalette(tileId)`. That function computes `canvasView.framedViewportForTileJump(tileId)`, calls `recordViewBeforeProgrammaticJumpIfNeeded`, sets the viewport with `canvasView.setViewport(targetViewport)`, records a `paletteJump` in `focusHistory`, and enters the tile scope via `focusBroker.enterScope(.tile(tileId), reason: .tileSpawned)`.

The gap this ticket closes: the existing `runWorkspaceSidebarActionsSelfCheck` check asserts `focusBroker.activeSurface == .tile(tileA)` and `canvas.canvasState.lastActiveTileId == tileA` after the tile-row click, but it does not assert that `canvas.viewport` moved to frame the tile. The zone-row assertion in the same check does use `viewportsNearlyEqual`. Extend the tile-row assertion to match: compute `expectedTileViewport = canvas.framedViewportForTileJump(tileA)` before the click, then after the click assert `viewportsNearlyEqual(canvas.viewport, expectedTileViewport)`. Apply the same extension to the cross-workspace tile-row case. Record the measured viewport in the manifest.

No changes to `WorkspaceSidebarView`, `FocusDispatch`, or `jumpToTileFromPalette` are expected — the logic is already correct. This ticket is verification, one manifest amendment, and a Component Lab fixture change (named IDs + a selection variant card), not a behavioral fix.

## Where it lives

**`Sources/ContinuumRevived/App/WorkspaceSidebarView.swift`** — `WorkspaceSidebarView` (`line 13`). The `onSelection` closure (`line 58`) and `clickTileRowForQA` (`line 317`) are the real-path entry points for the check. `select(workspaceId:zoneId:tileId:)` (`line 267`, `@discardableResult`, returns `Bool`) is the programmatic selector the Lab visual gate uses to render the post-click highlighted state. `performSelection(for:)` (`line 470`) and `selection(for:)` (`line 475`) are the two functions that convert a clicked `SidebarItem` into a `WorkspaceSidebarSelection.tile` value — they are read-only for this ticket.

**`Sources/ContinuumRevived/App/ComponentLab.swift`** — `LabFixtures` (`line 50`) currently mints the fixture zone/tile IDs inline with `UUID()` inside `sidebarTree()` (`line 86`), so there is **no named ID to hand to `select()`**. This ticket adds two stable constants to `LabFixtures` and threads them into `sidebarTree()` (see breadcrumbs). `sidebarCard` (`line 404`) reloads the tree but never selects a row, so the current card renders the tree *unselected*. This ticket adds a second Lab entry that selects the fixture tile row so the highlighted post-click state is gated. `runSelfCheck()` (`line 711`) is where the falsifiable selection gate lives.

**`Sources/ContinuumRevived/App/ContinuumApp.swift`** — `handleWorkspaceSidebarSelection` (`line 4495`) dispatches the `.tile` case to `focusTileFromSidebar` (`line 4545`). `focusTileFromSidebar` calls `jumpToTileFromPalette` (`line 6160`). `jumpToTileFromPalette` calls `canvasView.framedViewportForTileJump`, `canvasView.setViewport`, `focusHistory.recordTileFocus`, and `focusBroker.enterScope`. `runWorkspaceSidebarActionsSelfCheck` (`line 4748`) is the check that receives the new viewport assertions. Its manifest (`line 4962`) gains two new measured-viewport entries.

**`Sources/ContinuumRevivedCore/FocusDispatch.swift`** — `FocusDispatch` (`line 13`). No changes; listed as a primary seam because the ticket spec names it and it is the authority on what `.tile` scope entry means. `focusBroker.enterScope(.tile(tileId), reason: .tileSpawned)` is the call that makes `FocusDispatch.resolve` start routing key events to the tile's chord catalog — this is what makes the jump feel like a real focus transfer, not just a camera pan.

## Implementation breadcrumbs

```swift
// LabFixtures (near line 51): promote the selected zone/tile IDs to stable
// named constants so the Lab can both build the tree AND select into it.
// Today these are inline UUID() calls inside sidebarTree() and cannot be named.
static let selectedZoneId = UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!
static let selectedTileId = UUID(uuidString: "00000000-0000-0000-0000-0000000000C1")!
```

```swift
// sidebarTree() (line 86): use the named constants for the zone we will select
// into and its first tile row (the "claude · feature/login" working tile).
// The other rows keep their inline UUID()s — only the row we select needs a name.
let alpha = SidebarZoneRow(
    zoneId: selectedZoneId, name: "continuum-revived", color: "#5B8DEF",
    navKey: "1", collapsed: false, projectId: UUID(),
    agentStatusRollup: SidebarAgentStatusRollup(working: 1, needsAttention: 1),
    tiles: [
        SidebarTileRow(tileId: selectedTileId, title: "claude · feature/login", kind: .terminal, agentStatus: .working),
        // ...remaining rows unchanged...
    ]
)
```

```swift
// A NEW Lab entry beside sidebarCard (near line 404): the same tree, but with the
// fixture tile row SELECTED so the highlighted post-click state is what gets gated.
// This is definitive — always call select() here; do not condition it on inspection.
private static var sidebarSelectedCard: LabEntry {
    LabEntry(
        id: "chrome.sidebar.selected", category: "Chrome", title: "Workspace Sidebar — tile selected",
        summary: "Same tree with a tile row in its clicked/selected state.",
        content: .staticCard(preferredSize: NSSize(width: 280, height: 560)) {
            let view = WorkspaceSidebarView(frame: NSRect(x: 0, y: 0, width: 280, height: 560))
            view.reload(tree: LabFixtures.sidebarTree(), currentWorkspaceId: LabFixtures.workspaceId)
            _ = view.select(workspaceId: LabFixtures.workspaceId,
                            zoneId: LabFixtures.selectedZoneId,
                            tileId: LabFixtures.selectedTileId)  // renders the selection highlight band
            return view
        }
    )
}
// Register it in the catalog next to sidebarCard so runSelfCheck() renders it.
```

```swift
// Inside runWorkspaceSidebarActionsSelfCheck, near line 4910:
// Before the click, snapshot the expected viewport.
guard let expectedTileAViewport = canvas.framedViewportForTileJump(tileA) else {
    throw CheckError.failed("tileA must be frameable before sidebar click")
}

let currentTileClickDelivered = sidebar.clickTileRowForQA(workspaceId: workspaceA, zoneId: zoneA, tileId: tileA)
let currentTileFocusWorked = currentTileClickDelivered
    && app.focusBroker.activeSurface == .tile(tileA)
    && canvas.canvasState.lastActiveTileId == tileA
    && sidebar.selectedTargetForQA == .tile(workspaceId: workspaceA, zoneId: zoneA, tileId: tileA)
    && viewportsNearlyEqual(canvas.viewport, expectedTileAViewport)  // NEW: camera landed on the tile
try expect(currentTileFocusWorked, "current workspace tile row should pan canvas to tile, focus it, and select its row")
let measuredTileAViewport = canvas.viewport  // capture for manifest
```

```swift
// Apply the same pattern to the cross-workspace tile case (near line 4937).
// DETERMINISTIC ORDERING: always run layout after the switch before framing —
// do NOT gate this on a nil probe (see "Watch out for").
sidebar.clickWorkspaceRowForQA(workspaceB)          // triggers switchWorkspace(to: B)
canvas.layoutSubtreeIfNeeded()                       // ALWAYS, unconditionally, post-switch
guard let expectedTileCViewport = canvas.framedViewportForTileJump(tileC) else {
    throw CheckError.failed("tileC must be frameable after workspace switch")
}
// ... existing click + broker/lastActive assertions ...
    && viewportsNearlyEqual(canvas.viewport, expectedTileCViewport)  // NEW
```

```swift
// Extend the manifest dictionary to record the measured values:
let manifest: [String: Any] = [
    // ... existing keys ...
    "tileAViewport": ["x": measuredTileAViewport.x, "y": measuredTileAViewport.y, "zoom": measuredTileAViewport.zoom],
    "expectedTileAViewport": ["x": expectedTileAViewport.x, "y": expectedTileAViewport.y, "zoom": expectedTileAViewport.zoom],
    // tileCViewport similarly
]
```

```swift
// The routing path — no changes needed, but read this to confirm wiring before touching the check:
// WorkspaceSidebarView.outlineRowClicked (line 339)
//   → performSelection(for: item) (line 343)
//     → onSelection?(.tile(workspaceId:, zoneId:, tileId:)) (line 472)
//       → handleWorkspaceSidebarSelection(.tile(workspaceId, zoneId, tileId)) (line 4507)
//         → focusTileFromSidebar(tileId) (line 4545)
//           → jumpToTileFromPalette(tileId) (line 6160)   ← the single D21 resolver, shared with the palette
//             → canvasView.framedViewportForTileJump(tileId) → canvasView.setViewport(...)
//             → focusBroker.enterScope(.tile(tileId), reason: .tileSpawned)
```

The `framedViewportForTileJump` call may return `nil` if the tile has no renderable frame (e.g. it was removed between the check setup and the click). `jumpToTileFromPalette` already guards on this: if `framedViewportForTileJump` returns `nil`, the viewport is not changed. The check must therefore compute `expectedTileViewport` from `framedViewportForTileJump` before the click and fail fast with a `throw` if it returns `nil`, so that a nil result is a check-setup failure rather than a silent false-positive. This is exactly the pattern the zone check already uses with `fitZoneToViewport`.

## How we test it

### Logic (pure Core checks)

`FocusDispatch` itself requires no new test here — its existing tests already cover the `.tile` scope routing. The pure-logic check for this ticket is the `viewportsNearlyEqual` geometry predicate already tested in the workspace-switch check suite. Confirm that predicate's tolerance (0.001 in x, y, and zoom) is tight enough to catch a no-op viewport (i.e. the canvas did not pan at all), not just a float-rounding difference. If the tile starts on-screen and `framedViewportForTileJump` returns a viewport very close to the current one, the check should still pass — a "pan to already-visible tile" is a valid outcome, not a failure. The logic check is: given a tile at a known world frame, assert that `framedViewportForTileJump` returns a viewport that places that tile's center within the canvas view's visible rect. This is a pure function call on a `CanvasNSView` instance with no live rendering, so it can run in the existing check scaffold without a display.

### Backend (real-path / integration)

This extends the existing `runWorkspaceSidebarActionsSelfCheck` check, which is already a real-path check: it creates a real `WorkspaceSidebarView`, a real `CanvasNSView`, a real `WorkspaceRuntime`, and wires `onSelection` to `handleWorkspaceSidebarSelection`. The call chain from click to viewport change runs through the production code paths without any mock or bypass. The `--workspace-sidebar-actions-check` flag at the command-line entry point (near line 849) invokes this check with a non-zero exit code on failure, so it is matrix-gated.

The assertions to add: after `clickTileRowForQA`, assert `viewportsNearlyEqual(canvas.viewport, expectedTileViewport)` for both the same-workspace tile case and the cross-workspace tile case. The cross-workspace case also triggers a `switchWorkspace` call before the jump, so the viewport assertion covers the full cross-workspace click path end-to-end. The manifest must carry the measured and expected viewport values as numbers, not as `true/false`.

### UX (visual gate + dogfood snippet)

**Visual gate — falsifiable, selection-specific.** The `isBlank` non-blank gate cannot prove selection: the sidebar card renders a full tree and is non-blank *with or without* a selected row, so `!metrics.isBlank` passes identically either way. Do **not** claim the non-blank gate proves selection. Instead, gate on a **distinct-color delta** between the unselected and selected renders, which is what an actual selection highlight band produces:

1. Render the existing `sidebarCard` (unselected) and capture `unselected.distinctSampledColors` from `VisualSnapshot.metrics`.
2. Render the new `sidebarSelectedCard` (which calls `select(workspaceId:zoneId:tileId:)` on the fixture IDs) and capture `selected.distinctSampledColors`.
3. Assert **both** are non-blank (the existing floor) **and** `selected.distinctSampledColors > unselected.distinctSampledColors`. The selection highlight adds the system accent-color band behind the selected row — new sampled colors that are absent from the unselected render. If `select()` silently no-ops (e.g. a wrong fixture ID that `selectItem` can't resolve, returning `false`), the two color counts are equal and the gate fails. That is the falsifiability the earlier version lacked.

Record both counts and the delta in the component-lab manifest so the gate is auditable, and write both PNGs to `qa-runs/<ts>/component-lab/` (the loop already writes `<entry.id>.png`, so the two cards land as `chrome.sidebar.png` and `chrome.sidebar.selected.png` for eyeball comparison). Because `select()` returns `Bool`, also assert its return value is `true` inside `sidebarSelectedCard` construction path (or, if the closure can't throw, verify in `runSelfCheck` that the selected render's delta is positive — a `false` return can't produce a delta).

**Dogfood snippet:** Open Continuum with a workspace that has at least two tiles in different zones. Make the left dock visible (use the dock toggle keybind from the nav/leader scheme). In the dock, expand the workspace's zones until a tile row is visible. Click any tile row. The canvas should pan smoothly to center that tile in the viewport and the tile should gain the focus border (accent-colored marching-ants outline). The dock row should remain highlighted to show it is the selected tile. If the canvas does not pan — the viewport stays where it was — the `framedViewportForTileJump` guard at line 6161 is failing, most likely because `navigationTileSnapshot(for: tileId)` is returning `nil` (the tile is not in the canvas's rendered snapshot set). Confirm by adding a temporary `print` at the guard in `jumpToTileFromPalette`.

## Execution mode

Supervised. The behavioral change is a manifest amendment and two new assertions inside an existing real-path check — logic that is fully deterministic and needs no human eyes for the matrix gate. The Lab fixture change (named IDs + selection card + color-delta gate) is also deterministic and matrix-gated via `runSelfCheck`. However, the UX contract requires a real-app run to verify the visual: that the canvas pans, the focus border appears, and the dock row stays highlighted. The dogfood snippet above is the concrete gate Dylan needs to run before signing off.

## Done when

- [ ] `runWorkspaceSidebarActionsSelfCheck` asserts `viewportsNearlyEqual(canvas.viewport, expectedTileViewport)` for the same-workspace tile-row click, and the assertion passes with the tile placed at a non-origin world frame so the pan is non-trivial.
- [ ] The same viewport assertion is added and passes for the cross-workspace tile-row click (the case that triggers a workspace switch followed by a jump), with `canvas.layoutSubtreeIfNeeded()` called unconditionally after the switch.
- [ ] The manifest written to `qa-runs/<ts>/workspace-sidebar-actions/manifest.json` contains `tileAViewport` and `expectedTileAViewport` as measured coordinate/zoom dictionaries, not booleans.
- [ ] `--workspace-sidebar-actions-check` exits 0 with the updated assertions in place.
- [ ] `LabFixtures` exposes `selectedZoneId` and `selectedTileId` constants, and `sidebarTree()` builds the selected zone + its first tile row from those constants.
- [ ] A `sidebarSelectedCard` Lab entry (`chrome.sidebar.selected`) renders the tree with `select(workspaceId: LabFixtures.workspaceId, zoneId: LabFixtures.selectedZoneId, tileId: LabFixtures.selectedTileId)` applied, and it is registered in the catalog.
- [ ] `runSelfCheck` asserts the selected render's `distinctSampledColors` is strictly greater than the unselected render's, and records both counts in the component-lab manifest. (The non-blank floor still applies to both, but the delta is the selection proof.)
- [ ] Dogfood: clicking a tile row in the real app pans the canvas to that tile and the tile gains the focus border, confirmed in a real run.

## Depends on / unblocks

This ticket depends on the left dock being rendered — the `WorkspaceSidebarView` must be visible and populated with a real `SidebarTree` (decision D21: the dock is the activity surface). The dock-rendering work is the named prerequisite ("render the left dock") in the plan. Without the dock visible and wired into a real canvas, the dogfood step cannot be executed and the `focusTileFromSidebar` path is never exercised from a human gesture.

This work unblocks the "replace mock rollup" surface work: once a user can jump to a tile from the dock, the dock's correctness is in active use rather than incidental, and the pressure to fill it with real observer data becomes immediate. It also closes the last assertion gap in the sidebar-actions check, making that check a complete integration proof of the sidebar's three navigation actions (workspace switch, zone pan, tile jump).

## Watch out for

**`framedViewportForTileJump` returning `nil` when the tile is in the model but not in the canvas snapshot.** `navigationTileSnapshot(for:)` only covers tiles that are currently rendered and part of the active canvas state. If the tile was added to the model after the last `layoutSubtreeIfNeeded` call (common in check scaffolding), it will not appear in the snapshot and `focusTileFromSidebar` will return `false` without panicking. The check's `tile` fixture objects must be placed in the canvas state before `layoutSubtreeIfNeeded` is called, and `framedViewportForTileJump` must be called after layout. Getting this order wrong produces a silent `false` from `focusTileFromSidebar` — the click appears to do nothing, and the viewport assertion fails with a misleading diff because the expected viewport was computed from `nil` (caught by the `guard` throw). Always compute the expected viewport and assert it is non-nil as the first step of the tile-click sub-block.

**The cross-workspace case requires the canvas to re-layout after the workspace switch — do this unconditionally.** `switchWorkspaceFromSidebarIfNeeded` calls `workspaceRuntime.switchWorkspace(to:)` and `reloadWorkspaceSidebar`, but the canvas may not run its layout pass before `framedViewportForTileJump` is called (the run loop has not necessarily cycled), so the tile from the new workspace may not yet be in the snapshot. Do **not** phrase this as "if it returns nil, then layout" — an unattended agent cannot know the run-loop state at that instant. The deterministic rule: **always call `canvas.layoutSubtreeIfNeeded()` immediately after the workspace switch and before `framedViewportForTileJump(tileC)`**, in the cross-workspace sub-block. It is idempotent and cheap when layout is already current, so calling it every time is correct and removes the guess.

**The visual gate must be a color-delta, not a bare non-blank check.** The sidebar renders a full tree even with nothing selected, so `!metrics.isBlank` is true regardless of selection — it cannot distinguish the selected state acceptance criterion #5 (and #7) claims. Gate on `selected.distinctSampledColors > unselected.distinctSampledColors` instead; that is the only assertion here that actually observes the selection highlight. Keep the non-blank floor on both cards, but do not let it stand in for the selection proof.

**Do not move the `framedViewportForTileJump` call inside `focusTileFromSidebar` just to share it with the check.** The check's pattern of computing the expected viewport before the click and comparing after is a deliberate real-path discipline — it proves the production call produced the right answer, not that a test-internal call agreed with itself. Keep the production function call inside `jumpToTileFromPalette` where it is, and let the check call it independently as the oracle.
