# Render the left dock — prove WorkspaceSidebarView mounts default-visible on a real launch and gate it live in the Lab

Rests on **D21** (locked decisions: *"a persistent, resizable left dock … Default-visible on first run, toggleable … width persisted … the render of the already-built `WorkspaceSidebarView`, fed by real observer data, not the mock"*). It also inherits the UX-testing contract from `38-ux-analysis.md` §5 (real-path check + non-degenerate visual gate + dogfood snippet) and the state vocabulary in §0. It does **not** touch the DRIVE fork (D1/D22) — this is pure OBSERVE-tier chrome.

## What this delivers

The left dock becomes a live, always-on activity surface. A user running multiple agents across workspaces can see — without opening any panel — which agents are working, which need their attention, and where everything sits in the workspace/zone/tile hierarchy. Clicking any tile row pans the canvas to that tile and marks it focused. The dock is default-visible, persists its width across launches, and is toggleable from the existing command palette and menu bar shortcut. Collapsing a zone still shows its rollup glyph, so a waiting agent is never hidden by a folded tree node.

This ticket is the difference between Continuum being an observer of agent activity and actively showing you that activity at a glance.

## How it fits — and what is already done

The full AppKit sidebar machinery already exists and is already wired into the main app window. Almost everything D21 names is built and green. **Read this section carefully: it names, precisely, what is already done so you do not re-do it.** The genuinely-new work is small and is spelled out in "The approach."

Already built and passing on `HEAD`:

- `WorkspaceSidebarView` (`Sources/ContinuumRevived/App/WorkspaceSidebarView.swift`) — a complete `NSOutlineView`-backed source-list rendering workspace/zone/tile rows with glyph+color status accessories, expand/collapse, selection callbacks, and a full suite of `…ForQA` accessors (`workspaceRowsRenderedForQA`, `isWorkspaceExpandedForQA(_:)`, `clickTileRowForQA(...)`, `visibleStatusTextsForQA`, etc., lines 242–331).
- `WorkspaceSidebarConfig` (`Sources/ContinuumRevivedCore/WorkspaceSidebarConfig.swift`) — persisted width (default 280 pt, clamped 220–420) and visibility (`defaultVisible = true`, line 7; `resolveVisible(defaults:)` returns the default when the key is absent, lines 12–13).
- `AppDelegate.makeWorkspaceContentView(canvasView:frame:)` (`ContinuumApp.swift:4282`) — constructs the `NSSplitView`, mounts the sidebar on the left, assigns `workspaceSidebarView`/`workspaceSplitView`, then calls `reloadWorkspaceSidebar()` **and** `applyWorkspaceSidebarVisibility(WorkspaceSidebarConfig.resolveVisible())` at the end of the mount (lines 4319–4321). This is the real cold-launch path.
- `applyWorkspaceSidebarVisibility(_:)` (`ContinuumApp.swift:4567`) — sets `sidebar.isHidden` **and** `splitView.setPosition(...)` together, then `adjustSubviews()`. Both halves are already handled here.
- `buildWorkspaceSidebarTree()` (`:4412`), `reloadWorkspaceSidebar()` (`:4476`), `currentWorkspaceIdForSidebar()` (`:4359`) — build/populate from real `Registry` + `WorkspaceDocument`s + live agent statuses (`canvasView.agentStatus(for:)` + persisted `TerminalSessionDescriptor`s). `reloadWorkspaceSidebar()` is already called on every workspace/zone/tile mutation (lines 3835, 4321, 6288, …). **All four are `private` on `AppDelegate`.**
- Toggle via `toggleWorkspaceSidebar()` / `setWorkspaceSidebarVisible(_:)` (`:4557`), palette action `LaunchPaletteAction.toggleWorkspaceSidebar`, and menu item.
- **Three real-path shell checks, all green:** `--workspace-sidebar-shell-check`, `--workspace-sidebar-actions-check`, `--workspace-sidebar-live-status-check` (`runWorkspaceSidebar{Shell,Actions,LiveStatus}SelfCheck()`, `ContinuumApp.swift:4606 / 4748 / 4979`).
- The Component Lab already hosts **one** sidebar card: `sidebarCard` (`ComponentLab.swift:404`), a `.staticCard` rendering `WorkspaceSidebarView` seeded with `LabFixtures.sidebarTree()` (a single workspace "Continuum", two zones, four tiles, with a `working`+`needsAttention` rollup on the first zone).

**Explicitly already done — do NOT add these; they exist in stronger form than any earlier draft of this ticket asked for:**

- The shell check (`runWorkspaceSidebarShellSelfCheck`) already reads `sidebar.workspaceRowsRenderedForQA` (line 4691) and `sidebar.isWorkspaceExpandedForQA(currentWorkspace)` (line 4694), and already **asserts them more strictly** than "≥ 1 / truthy": `workspaceRowsRendered == 2` (line 4698) and `currentWorkspaceExpanded` (line 4699), alongside zone/tile-count and collapse assertions.
- The same check already **emits both manifest keys** `"workspaceRowsRendered"` and `"currentWorkspaceExpanded"` (lines 4733–4734), plus `widthPersistenceWorked`, `visibilityPersistenceWorked`, `paletteActionDiscoverable`.

If you find yourself about to add a `workspaceRowsRenderedForQA >= 1` assertion or a `"workspaceRowsRendered"` manifest key, **stop** — it is already there and stronger. There is nothing to add to `runWorkspaceSidebarShellSelfCheck`.

## The one real gap this ticket closes

D21's headline property — **"Default-visible on first run"** — is the one claim not yet covered by a headless, falsifiable check. The existing shell check builds a *standalone* `WorkspaceSidebarView` and calls `sidebar.reload(...)` **directly**; it never mounts the split view via `makeWorkspaceContentView`, never sets `isHidden`, and never sets the divider position. So "the dock is visible before the user does anything, with no `continuum.workspaceSidebar.visible` key written yet" is currently only verified by the dogfood pass — not by a check.

That property *is* headless-testable, because `applyWorkspaceSidebarVisibility(WorkspaceSidebarConfig.resolveVisible())` is exactly the call the real mount makes (`ContinuumApp.swift:4321`), and both `resolveVisible` (fresh defaults → `true`) and `isHidden`/divider are observable without a window ever becoming key. **Note the boundary honestly:** window key-order is a runtime AppKit event the check does not simulate. The check does not assert "before the window becomes key"; it asserts the *state the mount produces* — the same `resolveVisible → applyWorkspaceSidebarVisibility → isHidden==false, divider>0` sequence the real launch runs — against **cleared** `UserDefaults`. That is the falsifiable, headless proxy for "default-visible on first run."

## The approach

The view, the config, the split-view layout, and the three real-path checks are all already in place and green. The remaining work is exactly two things, both genuinely new and both falsifiable against `HEAD` (each fails on the current codebase):

**Step 1 — Add a *new* default-visibility real-path check.** Add `runWorkspaceSidebarDefaultVisibleSelfCheck()` and wire a `--workspace-sidebar-default-visible-check` flag. It must:
1. Use an **isolated, empty** `UserDefaults` suite (no `visible`/`width` keys written) and assert `WorkspaceSidebarConfig.resolveVisible(defaults:) == true` and `WorkspaceSidebarConfig.setVisible`/`resolveVisible` was never called to seed it — i.e., the *default* path is what returns `true`.
2. Build the same real temp `registryStore`/`WorkspaceDocument` rig the shell check builds, assign it to a fresh `AppDelegate`, and drive the **real mount**: call `app.makeWorkspaceContentView(canvasView:frame:)` (it is `private` but this check is a `static func` on `AppDelegate`, so private access is in scope — same as the shell check accessing `app.registryStore`). This is the true path; do not hand-build a standalone view for this check.
3. After the mount, `sidebar.layoutSubtreeIfNeeded()`, then assert **the mount left the dock visible with no user action**: `sidebar.isHidden == false`, the split-view divider position for divider 0 is `> 0` (space is actually allocated, not just logically un-hidden), and `sidebar.workspaceRowsRenderedForQA >= 1` (real registry data flowed through the mount's own `reloadWorkspaceSidebar()`, not an injected fixture).
4. Write a manifest with **measured values**: `"defaultVisibleResolved"`, `"sidebarIsHiddenAfterMount"`, `"dividerPositionAfterMount"`, `"workspaceRowsRenderedAfterMount"`. No bare `"passed": true`.

Why a new check and not an edit to the shell check: the shell check deliberately exercises the *reload/render* contract on a standalone view; the default-visible property is a *mount/visibility* contract. Keeping them separate keeps each check's failure message pointing at exactly one broken thing (the "watch out for" section explains the sequencing trap this check is designed to catch).

**Step 2 — Add a second, live Lab card.** The existing `sidebarCard` renders the single-workspace fixture. Add a *second* `.staticCard` — `"chrome.sidebar.live"` — seeded with a **richer, two-workspace** fixture so the non-degenerate visual gate exercises what the single-workspace card can't: cross-workspace collapse (a second, non-current workspace row) and an unambiguous orange `needsAttention` rollup where `needsAttention` wins over `working`. This is the ticket's visual gate (contract §B).

No new types, no new protocols, no new persistence, no new reload path. The only new production code is: one new `static func` self-check + its CLI flag in `ContinuumApp.swift`, and one new `LabEntry` + one new fixture builder in `ComponentLab.swift`.

## Where it lives

**Primary seams:**

- `Sources/ContinuumRevived/App/ContinuumApp.swift` — add `runWorkspaceSidebarDefaultVisibleSelfCheck()` near the other three checks (`:4606`+), and register `--workspace-sidebar-default-visible-check` next to the existing flags (`:837`+). The check calls the **`private`** `makeWorkspaceContentView(canvasView:frame:)` (`:4282`) — legal because the check is a static method on `AppDelegate`. `buildWorkspaceSidebarTree()`/`currentWorkspaceIdForSidebar()` are **not** called directly by this check; the mount calls `reloadWorkspaceSidebar()` internally. `applyWorkspaceSidebarVisibility` (`:4567`) is exercised through the mount, not called by hand.
- `Sources/ContinuumRevived/App/ComponentLab.swift` — add one `LabEntry` (`chrome.sidebar.live`) to `LabCatalog.entries(env:)` (`:354`, currently `[tileSandbox, sidebarCard, topBarCard, commandPaletteLauncher, settingsLauncher, projectPickerLauncher]`) and one fixture builder in `LabFixtures` (`:50`). The existing `sidebarCard` (`:404`) and `LabFixtures.sidebarTree()` (`:86`) are **unchanged**.
- `Sources/ContinuumRevived/App/WorkspaceSidebarView.swift` — read-only. `reload(tree:currentWorkspaceId:...)` (`:167`) is the reload surface; `applyDefaultExpansion` (`:399`) drives initial expansion; the `…ForQA` accessors (`:242`–`:331`) are read by the new check and the Lab self-check. No edits.
- `Sources/ContinuumRevivedCore/WorkspaceSidebarConfig.swift` — read-only. `defaultVisible = true` (`:7`) and `resolveVisible(defaults:)` (`:12`) are what the new check asserts against. No edits.
- `Sources/ContinuumRevivedCore/SidebarTree.swift` — read-only. `SidebarTreeBuilder.build(...)`, `SidebarWorkspaceRow`, `SidebarZoneRow`, `SidebarTileRow`, `SidebarAgentStatusRollup` (with `dominantKind`, `needsAttention > working > stale > done > unknown`) back the fixture and the render. No edits.

## Implementation breadcrumbs

Pseudo-code — match the exact initializer/argument shapes in the real source (verified against `HEAD`), do not copy verbatim.

```swift
// (1) ComponentLab.swift — a richer, TWO-workspace fixture in LabFixtures.
//     LabFixtures already defines `workspaceId` and `altWorkspaceId` — reuse them.
static func richSidebarTree() -> SidebarTree {
    // Current workspace: one zone whose rollup is needsAttention-dominant.
    let zoneA = SidebarZoneRow(
        zoneId: UUID(), name: "continuum-revived", color: "#5B8DEF",
        navKey: "1", collapsed: false, projectId: UUID(),
        agentStatusRollup: SidebarAgentStatusRollup(working: 1, needsAttention: 1),
        tiles: [
            SidebarTileRow(tileId: UUID(), title: "claude · feature/login",
                           kind: .terminal, agentStatus: .needsAttention),  // orange ◆
            SidebarTileRow(tileId: UUID(), title: "shell",
                           kind: .terminal, agentStatus: .working),           // blue ●
            SidebarTileRow(tileId: UUID(), title: "localhost:3000",
                           kind: .browser, agentStatus: nil),                 // "no agent"
        ]
    )
    // Second, non-current workspace so cross-workspace collapse is visible.
    let zoneB = SidebarZoneRow(
        zoneId: UUID(), name: "notes", color: "#E0A458",
        navKey: "1", collapsed: false, projectId: nil,
        tiles: [SidebarTileRow(tileId: UUID(), title: "scratch.md",
                               kind: .note, agentStatus: nil)]
    )
    return SidebarTree(workspaces: [
        SidebarWorkspaceRow(workspaceId: workspaceId,    name: "Continuum", zones: [zoneA]),
        SidebarWorkspaceRow(workspaceId: altWorkspaceId, name: "Scratch",   zones: [zoneB]),
    ])
}

// (2) ComponentLab.swift — a SECOND card (the first, sidebarCard, stays as-is).
private static var sidebarLiveCard: LabEntry {
    LabEntry(
        id: "chrome.sidebar.live",
        category: "Chrome",
        title: "Workspace Sidebar — Rich Fixture",
        summary: "Two workspaces, mixed statuses, current expanded. Confirms rollup precedence + collapse.",
        content: .staticCard(preferredSize: NSSize(width: 280, height: 640)) {
            let view = WorkspaceSidebarView(frame: NSRect(x: 0, y: 0, width: 280, height: 640))
            view.reload(tree: LabFixtures.richSidebarTree(),
                        currentWorkspaceId: LabFixtures.workspaceId)
            return view
        }
    )
}

// Append to LabCatalog.entries(env:) — keep sidebarCard, add sidebarLiveCard after it:
// [tileSandbox, sidebarCard, sidebarLiveCard, topBarCard,
//  commandPaletteLauncher, settingsLauncher, projectPickerLauncher]

// (3) ContinuumApp.swift — the NEW check. Structure mirrors runWorkspaceSidebarShellSelfCheck:
//     same temp registryStore + two WorkspaceDocuments rig, but it drives the REAL mount.
static func runWorkspaceSidebarDefaultVisibleSelfCheck() throws -> URL {
    // ... build tempRoot, appSupport, registry (lastActiveWorkspaceId set),
    //     two WorkspaceEntry rows, save via RegistryStore + two WorkspaceStore saves —
    //     identical to the shell check's setup (lines ~4628–4681).

    // FRESH defaults: no visible/width key written. This is the "first run" state.
    let suiteName = "continuum-workspace-sidebar-default-visible-\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else { throw ... }
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let defaultVisibleResolved = WorkspaceSidebarConfig.resolveVisible(defaults: defaults)   // must be true
    try expect(defaultVisibleResolved, "fresh UserDefaults must resolve sidebar visible == defaultVisible (true)")

    let app = AppDelegate()
    app.registryStore = registryStore
    // Drive the REAL mount — the path the app runs on cold launch:
    let canvas = CanvasNSView(canvasState: CanvasState(
        viewport: CanvasViewport(x: 0, y: 0, zoom: 1), tiles: [], groups: [], lastActiveTileId: nil))
    let content = app.makeWorkspaceContentView(
        canvasView: canvas, frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
    content.layoutSubtreeIfNeeded()
    guard let split = app.workspaceSplitViewForQA ?? (content as? NSSplitView),
          let sidebar = app.workspaceSidebarViewForQA else { throw ... }
    sidebar.layoutSubtreeIfNeeded()

    // The mount already ran reloadWorkspaceSidebar() + applyWorkspaceSidebarVisibility(resolveVisible()).
    let sidebarIsHidden = sidebar.isHidden                       // must be false
    let dividerPosition = split.frame(ofDividerAt: 0)... // read the sidebar pane's width; must be > 0
    let rows = sidebar.workspaceRowsRenderedForQA               // must be >= 1 from real registry data
    try expect(!sidebarIsHidden, "mount must leave sidebar visible with no user action (isHidden == false)")
    try expect(dividerPosition > 0, "mount must allocate sidebar width (divider > 0), not merely un-hide it")
    try expect(rows >= 1, "mount's own reload must render >= 1 workspace row from real registry data")

    // Manifest carries measured values — never a bare passed:true.
    // "defaultVisibleResolved", "sidebarIsHiddenAfterMount", "dividerPositionAfterMount",
    // "workspaceRowsRenderedAfterMount", "artifactPath".
}
```

**On reading the divider/sidebar width and reaching private state:** `workspaceSidebarView`/`workspaceSplitView` are `private` stored properties on `AppDelegate`; because the check is a static method on `AppDelegate` it can read them directly (no `…ForQA` shim needed — the `?? …ForQA` in the pseudo-code is illustrative; use whichever the file already exposes, and if neither is reachable from the check's scope, read `app.workspaceSidebarView` directly since same-type private access applies). Measure the allocated sidebar width from `sidebar.frame.width` after `layoutSubtreeIfNeeded()` if the divider-position API is awkward; a positive allocated width is the same signal as `divider > 0`. Pick one and assert it — do not assert both if they are redundant.

## How we test it

### Logic (pure Core checks)

Already green; this ticket adds none. They cover the primitives it assembles:

- `SidebarTreeBuilder.build` with a populated registry + non-empty `agentStatusesByTileId` produces `SidebarTileRow.agentStatus` values matching the input (existing Core check, `ContinuumRevivedCoreChecks/main.swift`).
- `SidebarAgentStatusRollup.dominantKind` returns `needsAttention` when `needsAttention > 0` even with `working > 0` — the precedence the rich fixture relies on (`SidebarTree.swift:42`).
- `WorkspaceSidebarConfig.defaultVisible == true` — a constant (`WorkspaceSidebarConfig.swift:7`).

### Backend (real-path integration, not bypassed)

Four checks must all pass. The first is **new** (this ticket adds it); the other three are pre-existing and must **stay** green:

```
.build/debug/ContinuumRevived --workspace-sidebar-default-visible-check   # NEW
.build/debug/ContinuumRevived --workspace-sidebar-shell-check
.build/debug/ContinuumRevived --workspace-sidebar-actions-check
.build/debug/ContinuumRevived --workspace-sidebar-live-status-check
```

For the **new** check, read the manifest at the printed path (`qa-runs/<timestamp>/workspace-sidebar-default-visible/manifest.json`) and confirm the measured values:
- `"defaultVisibleResolved": true` (fresh defaults resolved to visible — the D21 default),
- `"sidebarIsHiddenAfterMount": false` (the real mount left it visible with no user action),
- `"dividerPositionAfterMount"` (or the allocated sidebar width) is `> 0` (space actually allocated),
- `"workspaceRowsRenderedAfterMount"` is `>= 1` (real registry data flowed through the mount's own reload).

Do **not** trust the exit code alone — the manifest carries measured values, never `"passed": true`.

The shell/actions/live-status checks are **not modified** by this ticket; running them is a regression guard, not new work.

### UX (visual gate + dogfood snippet)

**Visual gate.** Open the Component Lab and select "Chrome → Workspace Sidebar — Rich Fixture" (the new `sidebarLiveCard`). You must see:

- Two workspace rows: "Continuum" (bold, current) expanded showing its zone, and "Scratch" collapsed.
- The "continuum-revived" zone row shows a rollup in **orange** — the `◆ 1 working · 1 needs you` text in `.systemOrange`, confirming `dominantKind == .needsAttention` wins over `working`.
- The "claude · feature/login" tile row shows `◆` in orange with text "needs you".
- The "shell" tile row shows `●` in blue with text "working".
- The "localhost:3000" tile row shows `○` in tertiary label color with text "no agent".
- Clicking "Scratch" expands it to show the "notes" zone with the "scratch.md" note tile.

Any deviation means the fixture, the view's `statusPresentation(for:)`, or the rollup precedence is broken. This card is also picked up automatically by `ComponentLab.runSelfCheck()` (`ComponentLab.swift:706`), which renders every static card over the opaque dark backdrop and asserts each is non-blank (Tier-1 non-degenerate gate, `docs/26`) — so the new card gets a `!metrics.isBlank` gate for free the moment it is in `entries(env:)`.

**Dogfood snippet.**
Open the real app on a **fresh install** (or after removing the `continuum.workspaceSidebar.visible` key from `defaults`). The left dock should appear on the left of the window **before you do anything** — showing the workspace name, the zone, and the tile. It is visible because `WorkspaceSidebarConfig.defaultVisible == true` and the mount applied it (this is exactly what the new `--workspace-sidebar-default-visible-check` proves headlessly).

Next, confirm toggle: press `⌘K` to open the command palette, type "sidebar", select "Toggle Workspace Sidebar". The dock collapses (divider slides to x=0). Press again — it expands to its previous width. Quit and relaunch — it opens at the same width (persistence).

Finally, confirm jump-to-tile: click a tile row in the dock. The canvas pans and zooms to center that tile; if the tile is in a different workspace, the workspace switches and the canvas repositions.

## Execution mode

Supervised. The logic checks and all four shell checks are headless and fully automated, and the new default-visible check turns D21's headline property into a headless assertion. But the dock's correctness as a *rendered surface* — that the rollup color is orange, not blue; that the expand animation settles; that clicking a row pans the canvas — requires a real-app run with eyes on the output. The Lab visual gate is the minimum gate; the dogfood snippet exercises the live plumbing. Neither reduces to a manifest value.

## Done when

Every item below is falsifiable and fails on `HEAD` before the change (or, for the regression guards, is a check that must remain green):

- [ ] **NEW:** `--workspace-sidebar-default-visible-check` exists, exits 0, and its manifest shows `"defaultVisibleResolved": true`, `"sidebarIsHiddenAfterMount": false`, an allocated sidebar width / divider position `> 0`, and `"workspaceRowsRenderedAfterMount" >= 1` — proving the real `makeWorkspaceContentView` mount leaves the dock visible from fresh `UserDefaults` with no user action. *(Fails on HEAD: the check does not exist.)*
- [ ] **NEW:** A "Chrome → Workspace Sidebar — Rich Fixture" entry appears in the Component Lab as a **second** sidebar card and renders exactly as the visual gate describes (two workspaces, orange `◆` rollup on the current zone, correct glyphs/status texts, "Scratch" collapsed then expandable). *(Fails on HEAD: only one sidebar card exists.)*
- [ ] **NEW (dogfood):** Launching the real app with fresh `UserDefaults` (or after removing `continuum.workspaceSidebar.visible`) shows the dock visible without any user action.
- [ ] **Regression guard:** `--workspace-sidebar-shell-check` still exits 0 with its existing manifest keys intact (`workspaceRowsRendered == 2`, `currentWorkspaceExpanded: true`, width/visibility/palette keys). *This ticket adds nothing to this check — it must be byte-for-byte unchanged.*
- [ ] **Regression guard:** `--workspace-sidebar-actions-check` still exits 0 (unchanged).
- [ ] **Regression guard:** `--workspace-sidebar-live-status-check` still exits 0 (unchanged).
- [ ] **Dogfood:** the toggle keybind (discoverable via `⌘K` + "sidebar") collapses/expands the dock; width round-trips across quit/relaunch; clicking a tile row focuses that tile on the canvas (camera pans, tile becomes active).

## Depends on / unblocks

Rests on **D21** and on the three sidebar shell checks already passing. It does **not** depend on `SessionObserver` or any active agent reader — only the machinery already green: `makeWorkspaceContentView`, `reloadWorkspaceSidebar()`, `buildWorkspaceSidebarTree()`, `WorkspaceSidebarConfig`, and the `NSSplitView` layout.

It unblocks the observer-feed ticket, which will replace the `workspaceSidebarAgentStatuses` implementation (currently reading persisted `TerminalSessionDescriptor` records) with live `SessionObserver` push — an additive change that calls the *same* `reloadWorkspaceSidebar()` entry point this ticket's mount check exercises. It also unblocks the jump-to-tile navigation polish ticket, which can assume `focusTileFromSidebar` → `jumpToTileFromPalette` is a proven path.

## Watch out for

**The mount is where "default-visible" is decided — assert against the mount, not a standalone view.** The pre-existing shell check builds a standalone `WorkspaceSidebarView` and calls `sidebar.reload(...)` directly (`ContinuumApp.swift:~4689`); it deliberately never touches `isHidden` or the divider. Do not extend *that* check to cover visibility — build the **new** check on `makeWorkspaceContentView`, which is the only path that runs `applyWorkspaceSidebarVisibility(resolveVisible())`. If you assert visibility on a standalone view you will prove nothing about the real launch.

**`isHidden == false` alone is not enough — the divider must be positive.** `applyWorkspaceSidebarVisibility` sets both `sidebar.isHidden` **and** `splitView.setPosition(...)`. A sidebar can be logically un-hidden while its pane has zero width (divider at 0), which looks identical to hidden. The new check must assert **both** un-hidden **and** a positive allocated width; asserting only `isHidden == false` would pass on a broken layout.

**`layoutSubtreeIfNeeded()` before every QA read.** `workspaceRowsRenderedForQA` reads `outlineView.numberOfRows`, which only reflects reality after a layout pass. Call `content.layoutSubtreeIfNeeded()` (and `sidebar.layoutSubtreeIfNeeded()`) before reading any accessor. Missing this yields false zeros — the most common spurious failure in the existing checks.

**Private access is fine from the check.** `makeWorkspaceContentView`, `reloadWorkspaceSidebar`, `currentWorkspaceIdForSidebar`, and the `workspaceSidebarView`/`workspaceSplitView` stored properties are all `private` on `AppDelegate`, but the check is a `static func` on `AppDelegate`, so same-type private access applies (the existing shell check already relies on this to assign `app.registryStore`). You do not need to widen any access level.

**Do not add a second reload path.** The observer will later call `reloadWorkspaceSidebar()` — the single entry point the mount already uses. Do not introduce a direct `sidebar.reload(...)` in production code (the Lab card's direct `reload` is fine — it is a fixture-seeded static card, not a live surface). Keeping one production reload path is what lets the observer integration wire in cleanly.

**Stop if the mount yields zero workspace rows.** If `workspaceRowsRenderedAfterMount` is 0, the temp registry was not written before the mount's `reloadWorkspaceSidebar()` read it, or the `WorkspaceDocument` was never persisted — the same sequencing trap the shell check's setup already solves (save `RegistryStore` and both `WorkspaceStore`s before constructing the `AppDelegate`). Do not paper over it with a fixture injection; the point of this check is that the *real data path* renders on mount. Fix the sequencing.
