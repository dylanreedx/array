# Browser Tile Polish Design

**Status:** Proposed
**Date:** 2026-05-09
**Scope:** Design only. No production implementation is included in this task.

## Problem Statement

Phase 5 landed live `WKWebView` browser tiles with a working back/forward/reload row, an editable URL field, a spinner, and an error banner. The tile passes its smoke gate, persists URL/title, and survives the close path documented in ADR-0015. It is functionally correct but it does not feel like the rest of the canvas.

User-reported feel issues:

1. **Visual chrome looks bare.** The nav row reads as raw AppKit chrome (`bezelStyle = .rounded` arrow buttons, an unstyled `NSTextField`, a default `NSProgressIndicator`). It does not match the dark, dense, glass-like canvas around it. The tile body's `NSColor(white: 0.10, alpha: 1.0)` background and the page background show as a flat black rectangle until the page paints, which reads as a broken or empty tile during navigation and after a failed load.
2. **Practical features are missing.** No favicon, no determinate progress, no URL autocomplete, no find-in-page, no zoom controls, no copy-link, no open-in-system-browser, no smart-paste, no devtools. The tile is a navigation harness rather than a usable everyday browser.
3. **Resize feels off.** Drag-resizing a tile during a load can leave the host view briefly mismatched with the WKWebView's internal layout, and resizing while inspecting a long page sometimes leaves the toolbar at a different scale than the content.
4. **Empty state is blank black.** A new browser tile shows a black rectangle until the user types a URL. There is no project-default page, no recent-URL list, no entry affordance other than the tiny URL field at the top.

These are surface and interaction issues only. The runtime, navigation state machine, persistence, error reporting, and storage-group plumbing in `BrowserEngineContext` and `WKWebViewBrowserRuntime` already work and should not be touched by this polish work.

## Decision

Treat browser tile polish as a contained UX upgrade in three layers:

1. **Visual chrome rewrite** in `BrowserTileNSView` and a new `BrowserChromeView` to match the rest of the canvas (dark, dense, glass-like surface, rounded URL pill, custom symbol buttons, determinate progress strip, favicon, hover affordances).
2. **Practical browser features** delivered as discrete additions on top of the existing `BrowserRuntime` protocol — find-in-page, zoom, smart-paste, copy-link, open-in-system-browser, recent-URL autocomplete, optional devtools — each gated behind explicit user action so they cannot regress smoke or steal focus.
3. **Empty state and resize correctness** — in-tile new-tab-style page, deterministic resize behavior driven by `NSScrollView`-free direct WKWebView frame management plus an explicit live-resize hook into the runtime, and a uniform background that reads as "loading" not "broken".

All three layers stay in the `ContinuumRevived` app target. No new SPM products. No AppKit/WebKit code added to `ContinuumRevivedCore`. The Core-side `BrowserState`/`BrowserTile` model expands only enough to carry the new persisted bits (zoom level, recent URLs per tile/project, find-in-page query, last-used view-source flag) and stays free of UI types.

## What's In

### Core additions

- Extend `BrowserTile` with optional fields:
  - `zoomFactor: Double` (default 1.0; clamped 0.25...3.0).
  - `recentURLs: [String]` (capped at the 16 most recent unique URLs for that tile, MRU-ordered).
  - `findQuery: String?` (last find-in-page query, restored next launch).
  - `viewSource: Bool` (toggle for inline view-source rendering).
- Extend `BrowserState` with project-level `recentURLs: [String]` (capped at 64) so a brand-new browser tile can offer recent URLs from any prior tile in the same project.
- Add `BrowserDefaultPage.swift` in Core: a Sendable struct that emits the in-tile new-tab HTML/CSS bundle as a string. Pure data, no rendering. The struct lives in Core because the HTML mentions project-relative state (project name, recent URLs); generation is deterministic and trivially testable.

### Chrome rewrite

- New private `BrowserChromeView` inside `BrowserTileNSView` replaces the inline `NSStackView` and ad-hoc constraints. It owns:
  - Custom 18×18 symbol buttons for back/forward/reload using `NSImage(systemSymbolName:)` (`chevron.left`, `chevron.right`, `arrow.clockwise`) with hover layer-color transitions.
  - A single rounded URL pill: `NSView` with `cornerRadius`, custom dark-blur background (`NSVisualEffectView` with `.contentBackground`), and an inset `NSTextField`. Favicon, security indicator, and progress sit inside the pill at the leading edge.
  - A determinate progress strip rendered as a 2px-tall `CALayer` slid horizontally from 0 → 1 with `runtime.estimatedProgress` (KVO already exists on `WKWebView`; expose via `BrowserRuntime`).
  - Action overflow menu (kebab) with: open-in-system-browser, copy-link, view-source toggle, devtools toggle, zoom 100%/+/–, find-in-page.
  - Hover highlight on every button via `NSTrackingArea`.
- Body background switches from flat `0.10` black to a subtle vertical gradient layer plus a 1px hairline against the chrome — matches the title-bar hairline added in Issue 2 of the May 2026 UX sweep.

### Practical features

- **Favicon**: `BrowserRuntime` exposes `iconURL: String?` (resolved from `<link rel="icon">` via a small `WKUserScript` injected at `documentEnd`). `BrowserChromeView` fetches the icon with `URLSession` (per-storage-group config so cookies/auth flow correctly) and caches in-memory per `tileId`. Persistence is post-MVP.
- **Find-in-page**: `BrowserRuntime.find(_:options:)` wrapping `WKWebView`'s `findString(_:configuration:)` (macOS 14+). UI is an inline `NSSearchField` overlay anchored at the top-right of the host view, dismissed with Escape or the chrome action, with prev/next arrows. The query persists into `BrowserTile.findQuery`.
- **Zoom**: `BrowserRuntime.setPageZoom(_:)` wrapping `WKWebView.pageZoom`. Cmd-= / Cmd-– hotkeys at the tile level (only when the tile is first responder, so the existing canvas Cmd-K hotkey monitor in `ContinuumApp` does not need to learn about them). The current zoom factor is shown in the chrome overflow menu and persists into `BrowserTile.zoomFactor`.
- **Smart paste**: `NSTextField` subclass for the URL pill that intercepts `paste(_:)` — if the pasteboard contains a single URL string, paste it and immediately commit (Return is implied). If multi-line text, paste only the first line.
- **Copy link**: chrome action writes `runtime.url` to the general pasteboard.
- **Open in system browser**: chrome action calls `NSWorkspace.shared.open(URL(string: runtime.url)!)` guarded against an invalid URL.
- **Recent URLs autocomplete**: extend the URL pill's `NSTextField` with an `NSComboBox`-style dropdown (or a custom `NSTableView`-in-`NSPopover`) populated from `BrowserTile.recentURLs ∪ BrowserState.recentURLs`. Filtered as the user types. On Return, push the chosen URL onto both lists.
- **Devtools toggle**: `WKWebView.isInspectable` is settable on macOS 14+. Chrome action toggles it and prints the `Develop` menu hint once. Devtools open into the system Web Inspector; we do not host them in-tile.
- **View-source toggle**: when on, `BrowserRuntime` reloads the current URL with `WKWebView.loadHTMLString(_:baseURL:)` showing the page source as preformatted text. Persisted per tile.

### Empty state

- Default URL for a freshly spawned browser tile is the in-tile new-tab page, served as a `data:text/html;base64,…` URL produced by `BrowserDefaultPage.html(project: recentURLs:)`. The page renders:
  - Project name in a quiet header.
  - "Recents" grid of up to 8 most-recent URLs (project-level), each as a tile-size button that posts `window.location = "<url>"` on click.
  - A focus-trapping URL input that submits to the same chrome URL pill via `webkit.messageHandlers.continuum.postMessage({type: "navigate", url})` (a small `WKScriptMessageHandler` intercepts and forwards to `BrowserRuntime.loadURL`).
  - A "How to use" line ("⌘F find · ⌘= zoom · ⌘L focus URL") sized down so it does not overpower the action grid.
- The page styling matches the canvas dark surface with the same hairline and pill conventions used in the chrome rewrite — so the new tab is visually continuous with the tile chrome above it.

### Resize correctness

- `BrowserHostView` already wraps the WKWebView. Tighten the resize path:
  - Remove any implicit `NSScrollView` usage if present; WKWebView manages its own scrolling inside the surface.
  - Override `resizeSubviews(withOldSize:)` to set `webView.frame = bounds` directly, then call `runtime.notifyResize(bounds.size)` so `WKWebView`'s `evaluateJavaScript("window.dispatchEvent(new Event('resize'))")` fires once per drag-end (debounced in the runtime, not on every pixel of drag).
  - During a live drag the WKWebView sizes itself (frame = bounds is enough); the JS resize event is the expensive piece and only needs to fire on `mouseUp`.
- Add a regression check in the smoke harness: spawn a browser tile, programmatically resize the canvas tile by 200pt, then assert `webView.frame == hostView.bounds` (within 1pt) and that the page reports the new viewport via `evaluateJavaScript("[innerWidth, innerHeight].join(',')")` matching the new bounds.

## What's Deferred

- Tabs inside a single browser tile. (Multiple tiles do this job today.)
- Cross-tile session sharing beyond the existing per-project storage group.
- Reader mode.
- Built-in ad blocker, content blocker rules, or `WKContentRuleList` integration.
- Profile-aware download manager (`WKDownloadDelegate`).
- Per-site permissions UI (camera, microphone, location).
- Devtools hosted in-tile (we punt to the system Web Inspector).
- Offline / cached-page fallback.
- Pinned tabs, history search, syncing recent URLs across projects.
- Element picker / agent DOM context (already deferred per ADR-0015).
- Visual element inspection or screenshot annotation.
- Touch-bar / Stage-Manager integration.

## Verification

- **Build gate:** `swift build` completes cleanly with no new Swift concurrency or deprecation warnings.
- **Core checks gate:** `swift run ContinuumRevivedCoreChecks` covers `BrowserTile` (with new `zoomFactor`/`recentURLs`/`findQuery`/`viewSource` fields), `BrowserState` (with project-level `recentURLs`), and `BrowserDefaultPage.html` round trips and HTML-escaping.
- **Smoke gate:** `CONTINUUM_SMOKE_TEST=1 .build/debug/continuum-revived` continues to exit 0. Existing `browserOk` and `browserCardinalityOk` gates remain green. New gates assert: chrome view installed (subview of `BrowserTileNSView`), favicon URL captured for a seeded fixture page, in-tile new-tab page is the default URL of a freshly spawned browser tile (when `BrowserState.recentURLs` is empty, a sentinel string in the data URL must be present), `webView.frame == hostView.bounds` after a programmatic resize, and `BrowserTile.zoomFactor` round-trips through persistence.
- **Manual visual gate:** the user verifies — run `./.build/release/continuum-revived` on a real project, spawn three browser tiles, confirm chrome reads as glass/modern (not flat AppKit), confirm a fresh tile shows the new-tab page with recent URLs, confirm Cmd-F opens find-in-page, confirm Cmd-= / Cmd-– zoom, confirm dragging a tile edge during a load does not desync chrome from page, confirm the kebab menu's open-in-system-browser opens Safari/Chrome with the current URL.
- **Crash gate:** `~/Library/Logs/DiagnosticReports/continuum-revived*` shows no new entries after three back-to-back smoke runs and a five-minute interactive session with three browser tiles.

## Phase Exit Criteria

The browser polish phase is ready to ship when all of the following are concurrently true:

1. The browser tile chrome no longer reads as raw AppKit; it matches the canvas's dark, dense, glass-like surface.
2. A freshly spawned browser tile shows the in-tile new-tab page with project-level recent URLs.
3. Find-in-page (Cmd-F), zoom (Cmd-=/Cmd-–), copy-link, open-in-system-browser, smart-paste, and devtools toggle all work and are reachable from chrome buttons or the overflow menu.
4. Favicon and determinate progress are visible during a real navigation.
5. Resizing a tile during a load leaves the WKWebView and chrome perfectly aligned at every frame and after `mouseUp`.
6. Persistence round-trips zoom factor, recent URLs (per tile and per project), find query, and view-source flag.
7. ADR-0015's close-path order is unchanged: canvas + browser save flush → mark terminal session exits → remove monitors + close palette → terminate browser runtimes → terminate terminal runtimes → `ghostty.shutdown()` → `browserEngine.shutdown()`.
8. `swift build`, Core checks, and the smoke gate all pass; no new diagnostic reports.

## Consequences

Positive:

- The browser tile reads as a first-class surface alongside terminals, notes, file tiles, and the file tree.
- Power-user features (find, zoom, devtools, autocomplete) raise the daily-driver ceiling.
- The new-tab default removes the "blank black rectangle" first impression.
- The resize correctness fix removes a class of "did the tile break?" doubts during drag-resize.

Tradeoffs:

- More UI surface inside one tile means more places for focus bugs to hide. The future FocusBroker has to learn about the URL pill, the find overlay, and the autocomplete popover. The spec keeps focus locally containable (Escape always returns focus to the host view) but it is more than the current single-text-field model.
- `BrowserTile` grows new optional fields. The persistence layer must handle older project state without those fields (defaults applied at decode).
- `BrowserDefaultPage` lives in Core and emits HTML; HTML escaping must be tested. We accept that as tradeoff in exchange for keeping AppKit/WebKit out of Core.
- Custom chrome means more drawing code to maintain. Apple system chrome would be cheaper but would not match the rest of the canvas.

Rejected alternatives:

- **Tabs inside one browser tile.** Multiple tiles already serve this need on a spatial canvas; in-tile tabs would create a focus broker conflict and a second persistence axis.
- **Hosting devtools inside the tile.** WebKit's inspector is a separate process; embedding it would risk lifecycle bugs that ADR-0015's tear-down ordering does not yet handle. Punt to the system inspector.
- **Putting recent URLs in `ContinuumRevivedCore` as a single global file.** Recent URLs are project-scoped state, like canvases and notes. They belong inside `BrowserState`, not a workspace-wide registry.
- **Switching off WKWebView.** SwiftUI `WebView` (macOS 15+) and the third-party Brave/Bromite shells were considered and rejected — WKWebView is the only stable, supported, sandboxed browser engine on macOS, and the existing runtime contract works.
- **Adding a content blocker / ad blocker.** Out of scope for polish; adds rule-set persistence, update channels, and per-site overrides that exceed the polish brief.
