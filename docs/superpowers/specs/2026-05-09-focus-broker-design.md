# FocusBroker Subsystem Design

**Status:** Proposed
**Date:** 2026-05-09
**Scope:** Design only. No production implementation is included in this task.

## Problem Statement

The architecture calls out FocusBroker as core infrastructure, but focus is still split across AppDelegate, canvas hit testing, terminal views, and browser runtimes. `applicationDidBecomeActive` forwards focus into Ghostty, tries `canvasState.lastActiveTileId`, then falls back to the last terminal runtime. `TileNSView.mouseDown` brings a tile forward before deciding whether the click is resize, move, or content interaction. `GhosttyTerminalView` makes itself first responder and sets Ghostty surface focus from inside the terminal view. `WKWebViewBrowserRuntime` exposes a direct `focus()` wrapper that makes the web view first responder.

That shape worked for early phases, but Phase 7 needs focus to be explicit and testable. The missing parts are a single active-surface authority, modal dismissal restore, first-responder recovery, and reserved app-level shortcut routing for Cmd-K and Cmd-1 through Cmd-4. Without that authority, every new surface has to learn the same focus rules, and terminal/browser adapters can accidentally consume app shortcuts that should stay global.

## Decision

Introduce a `@MainActor` `FocusBroker` owned by AppDelegate during the current AppShell era and movable into AppShell when that boundary lands. The broker owns transient focus state, surface registration, modal focus snapshots, app activation/resignation handling, and reserved shortcut classification. It does not own canvas geometry, runtime lifecycle, or tile persistence.

`CanvasState.lastActiveTileId` remains the persisted resume field. FocusBroker becomes the runtime source of truth for the active surface and writes `lastActiveTileId` through a canvas callback only when a tile surface is accepted as active. This keeps saved project state in the existing model while avoiding a second runtime authority in `CanvasState`.

Reserved shortcuts stay enforced through the existing local NSEvent monitor at the app boundary, but FocusBroker becomes the policy object behind that monitor. Terminal and browser adapters ask the broker before consuming command-modified keys. The monitor remains the earliest interception point for app commands; adapters provide the second line of defense for embedded surfaces that receive key events directly.

Plain Escape is not reserved globally in Phase 7. While terminal or browser content is focused, Escape belongs to the embedded surface unless a modal is open or the first responder is invalid. Emergency recovery is explicit: modal dismissal restores the previous focus snapshot, app activation repairs the expected first responder, and a future user-configurable recovery shortcut can move focus to canvas without stealing terminal Escape.

## What's In

- `FocusSurfaceID`: a small identifier for `.canvas`, `.tile(TileID)`, `.modal(FocusModalKind)`, `.appChrome`, and `.settings`.
- `FocusSurfaceKind`: semantic kind values for canvas, terminal, browser, note, file, palette, settings, and app chrome.
- `FocusSurfaceAdapter`: a MainActor protocol implemented by focus-capable views or runtime wrappers.
- `FocusBroker`: the central coordinator that registers adapters, accepts focus requests, restores snapshots, classifies reserved shortcuts, and repairs first responder state.
- `FocusBrokerDelegate` or closure callbacks owned by AppDelegate for persistence-adjacent actions such as updating `canvasState.lastActiveTileId` and scheduling canvas save.
- `FocusRequest`: an enum or struct for `.userClick`, `.appActivated`, `.modalOpened`, `.modalDismissed`, `.tileSpawned`, `.tileClosed`, `.runtimeExited`, and `.recovery`.
- `ReservedShortcut`: a pure classification model for Cmd-K, Cmd-1, Cmd-2, Cmd-3, Cmd-4, and future app commands.
- Adapter registration during boot for canvas, every terminal runtime, every browser runtime, and text-based note/file views.
- Modal snapshot calls around command palette and future settings sheets.
- First-responder repair that verifies the active adapter can still focus and falls back to canvas when the adapter is gone or rejected.

Suggested API shape:

```swift
@MainActor
protocol FocusSurfaceAdapter: AnyObject {
    var focusSurfaceID: FocusSurfaceID { get }
    var focusSurfaceKind: FocusSurfaceKind { get }
    func acquireFocus(reason: FocusRequest) -> Bool
    func releaseFocus(reason: FocusRequest)
    func canHandleReservedShortcut(_ shortcut: ReservedShortcut) -> Bool
}

@MainActor
final class FocusBroker {
    func register(_ adapter: FocusSurfaceAdapter)
    func unregister(_ id: FocusSurfaceID)
    func requestFocus(_ id: FocusSurfaceID, reason: FocusRequest)
    func openModal(_ kind: FocusModalKind)
    func closeModal(_ kind: FocusModalKind)
    func applicationDidBecomeActive()
    func applicationDidResignActive()
    func reservedShortcut(for event: NSEvent) -> ReservedShortcut?
    func shouldSurfaceReceive(_ shortcut: ReservedShortcut, surface: FocusSurfaceID) -> Bool
    func recoverToCanvas(reason: FocusRequest)
}
```

## Integration Plan

1. Add the pure focus identifiers, request types, and reserved shortcut classifier in Core or in an App-facing module that can be exercised without running the app.
2. Add `FocusBroker` as a MainActor app service owned by AppDelegate next to the existing runtime arrays.
3. Register the canvas after `CanvasNSView` is created and before tile runtimes are installed.
4. Register terminal adapters when `TileSpawner` returns a `GhosttyTerminalRuntime`, and unregister them when runtime exit or window close tears the runtime down.
5. Register browser adapters when `WKWebViewBrowserRuntime` is installed, and unregister them during content-process termination or tile teardown.
6. Add lightweight note and file adapters so text surfaces participate in focus restore even though they have no process runtime.
7. Replace AppDelegate's direct activation focus walk with `focusBroker.applicationDidBecomeActive()`.
8. Replace direct runtime blur loops on resign with `focusBroker.applicationDidResignActive()`.
9. Route `TileNSView.mouseDown` through a focus request before or alongside `bringToFront` so z order and focus move together.
10. Route palette open and close through modal snapshot calls so dismissal returns to the previous accepted surface.

## Reserved Shortcuts

FocusBroker owns shortcut classification; AppDelegate's local monitor continues to own event interception. Cmd-K and Cmd-1 through Cmd-4 are app-level commands unless a modal already owns that exact command. Terminal and browser adapters do not get to reinterpret those commands as surface-local input.

The broker should expose both `reservedShortcut(for:)` and `shouldSurfaceReceive(_:surface:)`. The first function lets the local monitor dispatch app commands before they reach the responder chain. The second lets terminal/browser key paths defend themselves if a command-modified event reaches them directly through AppKit or WebKit.

## Escape Recovery

Escape has three tiers:

1. Modal tier: Escape dismisses the active modal if the modal explicitly supports Escape dismissal, then FocusBroker restores the snapshot taken before the modal opened.
2. Embedded-surface tier: terminal and browser content receive plain Escape as normal input while they are the active surface.
3. Recovery tier: if the active adapter is missing, cannot become first responder, or its window is no longer key, FocusBroker repairs focus to the last valid tile or canvas.

This avoids turning Escape into a global terminal-breaking shortcut while still giving the app a deterministic recovery path.

## Verification

- Pure classifier checks: Cmd-K and Cmd-1 through Cmd-4 classify as reserved shortcuts, while non-command keys and plain Escape do not.
- Broker transition checks: focus moves canvas -> terminal -> browser -> modal -> previous surface with the expected active surface after each request.
- Persistence-adjacent check: accepting a tile focus request updates `CanvasState.lastActiveTileId`, while focusing modal/app chrome does not.
- App activation check: activation restores the last active registered tile if present and falls back to canvas if the registered adapter is missing.
- App resignation check: the active runtime adapter receives release focus and Ghostty app focus is cleared through the terminal integration path.
- Tile click check: clicking a tile brings it forward and requests focus through the broker.
- Palette check: Cmd-K opens the palette regardless of terminal/browser focus, and closing the palette restores the previous tile or canvas focus.
- Browser/terminal adapter check: reserved shortcuts are withheld from embedded surfaces, while ordinary input still reaches them.
- Visual/manual sanity: no visual design change is expected, but QA should verify that readable tile text is not clipped or overlapped after focus transitions because first-responder repair must not resize or re-layout tile content.

## Phase Exit Criteria

Phase 7 FocusBroker is ready to implement when all of the following are true in the implementation plan:

1. There is exactly one runtime authority for active focus.
2. `CanvasState.lastActiveTileId` is documented as persisted resume state, not runtime focus authority.
3. Every interactive embedded surface has an adapter or an explicit reason it is out of scope.
4. Cmd-K and Cmd-1 through Cmd-4 are classified in one place.
5. Terminal and browser adapters ask before consuming reserved shortcuts.
6. Modal dismissal restores the pre-modal focus snapshot.
7. App activation and app resignation flow through FocusBroker.
8. The test plan covers reserved shortcuts, app activation restore, modal restore, adapter removal, tile click focus, and first-responder recovery.

## What's Deferred

- Configurable user shortcut bindings. Phase 7 keeps the existing app command set.
- Global Escape-to-canvas behavior. Plain Escape remains embedded-surface input unless a modal or broken first responder requires recovery.
- Cross-window focus brokerage. The current app has one main window, so the broker can be window-scoped.
- Accessibility focus announcements. The broker can become the integration point later, but Phase 7 is about first responder and runtime focus correctness.
- Minimap and focus mode integration. Architecture mentions future hooks, but those surfaces are not part of this FocusBroker design.
- Full AppShell extraction. AppDelegate owns the broker now so the focus fix can land before the broader shell refactor.

## Consequences

Positive:

- Focus behavior becomes explicit, centralized, and testable.
- New tile kinds integrate through a small adapter instead of duplicating activation rules.
- Reserved shortcuts stop depending on scattered responder-chain behavior.
- Modal restore becomes deterministic instead of relying on whichever view AppKit leaves as first responder.

Tradeoffs:

- The broker adds an app-level service that must be wired into every focus-capable surface.
- The first implementation will touch AppDelegate, TileNSView, terminal runtime wiring, browser runtime wiring, and palette presentation.
- Keeping `lastActiveTileId` in `CanvasState` means the broker needs a persistence callback, but that is less risky than moving persisted canvas schema during the focus refactor.

Rejected alternatives:

- Put focus state entirely in `CanvasState`. This would make transient modal/app-chrome state look like project data and would force AppKit first-responder repair into a persistence model.
- Let each surface keep its own shortcut policy. This preserves today's duplication and does not satisfy the architecture rule that terminal and browser adapters ask before consuming reserved shortcuts.
- Reserve Escape globally. This would make terminal and browser behavior surprising because Escape is meaningful input inside both embedded surfaces.
