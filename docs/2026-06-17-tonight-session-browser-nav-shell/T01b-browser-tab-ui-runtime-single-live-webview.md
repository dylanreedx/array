# T01b — Browser tab strip + single-live-WKWebView runtime slice

Status: conditional
Tag: tonight [browser]
Depends on: T01 · Blocks: T03

## Goal
Make browser tiles visibly tabbed while preserving the current runtime budget: each browser tile has one live `WKWebView`; inactive tabs are stored URL/title/favicon/interaction snapshots, not background webviews.

## Implementation decision
Use a **single-live-webview tab model** for the first UI/runtime slice.

- One browser tile owns one live `WKWebViewBrowserRuntime` at a time.
- The active tab is loaded in that runtime.
- Inactive tabs are persisted snapshots from T01 (`url`, `title`, optional `faviconURL`, optional `interactionState`).
- Switching tabs snapshots the current active tab, activates the target tab, then loads/restores the target into the same live runtime.
- `target=_blank` / `window.open` stays current behavior: spawn a new browser tile. Do not convert popups into in-tile tabs in this slice.

This deliberately avoids “one WKWebView per tab” until a later performance/memory design exists.

## Scope
- `Sources/ContinuumRevived/Canvas/BrowserTileNSView.swift`
  - add compact tab strip above/near the existing nav row;
  - show active tab title clearly;
  - add new-tab and close-tab affordances;
  - expose QA snapshots for tab count, active tab id/title/url, and tab-strip visibility.
- `Sources/ContinuumRevived/BrowserEngine/BrowserRuntime.swift`
  - extend `BrowserRuntime` with snapshot/restore requirements, because `BrowserTileNSView` stores `runtime` as `any BrowserRuntime` and cannot call `WKWebViewBrowserRuntime.capturedInteractionState` / `restoreInteractionState(_:)` directly.
- `Sources/ContinuumRevived/BrowserEngine/WKWebViewBrowserRuntime.swift`
  - keep using the existing `capturedInteractionState` and `restoreInteractionState(_:)` seams.
- `Sources/ContinuumRevived/App/TileSpawner.swift`
  - initialize `BrowserTileNSView` with the persisted tab model from `BrowserTile`;
  - persist tab-model changes via existing browser persistence flow;
  - keep `spawnBrowserForNewWindow` behavior as “new tile.”
- `Sources/ContinuumRevived/App/ContinuumApp.swift`
  - keep `browserRuntimes.count` tied to live browser tiles, not tabs;
  - add app flag `--browser-tab-ui-single-live-check`.

## Out of scope / non-goals
- No background live tabs.
- No tab dragging between browser tiles.
- No cross-window tab restore beyond persisted model.
- No in-canvas DevTools.
- No password/autofill.
- No Chrome profile/sync integration.
- Do not change `target=_blank` behavior in this slice.

## Product / UX policy
- The active tab must be visually obvious in the browser tile, not only in the outer tile bar.
- The outer tile bar title mirrors the active tab title, falling back to URL, then `Browser`.
- Closing the last tab leaves one safe `about:blank` tab.
- Keyboard focus rules:
  - switching tabs should focus browser content unless URL field/find field is actively editing;
  - `⌘L`, `⌘F`, `⌘R`, `⌘[`, `⌘]` keep using existing tile-action paths.
- Inactive tabs may reload when first activated after app launch; that limitation must be reflected in code comments and manifest fields.
- When switching tabs, clear a tab's persisted `interactionState` if the live runtime returns nil; do not reuse the previous nonnil blob from `TileSpawner.upsertBrowserTile` semantics.

## Acceptance criteria
- [ ] One browser tile can create at least 3 tabs through production UI/test hooks.
- [ ] Switching tabs updates the active tab strip state, URL field, and outer tile title.
- [ ] Closing the active middle tab selects the right neighbor; closing the rightmost active tab selects left.
- [ ] Closing the last tab leaves exactly one `about:blank` fallback tab.
- [ ] `BrowserEngineContext.webViewCreationCountForQA` proves tab create/switch/close does not create a WKWebView per tab.
- [ ] `target=_blank` still creates a new browser tile and still passes `--browser-target-blank-check`.
- [ ] Existing browser note/action and URL focus checks still pass.

## Nightly QA contract
Required pure check:

```bash
swift run ContinuumRevivedCoreChecks
```

Required app flag:

```bash
swift run continuum-revived --browser-tab-ui-single-live-check
```

Required regression flags:

```bash
swift run continuum-revived --browser-url-focus-check
swift run continuum-revived --browser-note-action-check
swift run continuum-revived --browser-target-blank-check
```

Required artifact:

```text
qa-runs/<timestamp>/browser-tab-ui-single-live/manifest.json
```

Manifest fields:

```json
{
  "check": "browser-tab-ui-single-live",
  "tabCountAfterCreate": 3,
  "activeTitleSequence": ["A", "B", "C"],
  "urlFieldSequence": ["data:text/html...A", "data:text/html...B", "data:text/html...C"],
  "outerTileTitleMirrorsActiveTab": true,
  "webViewCreationCountAfterSpawn": 1,
  "webViewCreationCountAfterTabSwitches": 1,
  "browserRuntimeCount": 1,
  "closeMiddleSelectedRightNeighbor": true,
  "closeLastCreatedAboutBlank": true,
  "targetBlankRemainsNewTile": true,
  "usedProductionBrowserTileNSView": true,
  "tabStripVisible": true,
  "tabActionsDrivenThroughViewOrDocumentedQAActionPath": true,
  "urlFieldVisibleTextMatchedActiveTab": true
}
```

Reviewer rejection rules:
- Reject if each tab creates a live `WKWebView` in this slice.
- Reject if tests exercise only the pure model and not `BrowserTileNSView` / production tab actions.
- Reject if `target=_blank` behavior silently changes.

## Stop conditions
Stop / do not mark Done if:
- switching tabs requires broad rewrites of `WorkspaceRuntime`/browser LRU budget;
- tab UI breaks existing URL-field focus, find, back/forward/reload tile actions;
- browser runtime count scales with tab count;
- any tab action corrupts or drops existing `BrowserState` profile/storageGroup data;
- artifact omits webview creation/runtime-count evidence.

## Verification commands

```bash
swift build
swift run ContinuumRevivedCoreChecks
swift run continuum-revived --browser-tab-ui-single-live-check
swift run continuum-revived --browser-url-focus-check
swift run continuum-revived --browser-note-action-check
swift run continuum-revived --browser-target-blank-check
swift run continuum-revived --browser-profile-persistence-check
```
