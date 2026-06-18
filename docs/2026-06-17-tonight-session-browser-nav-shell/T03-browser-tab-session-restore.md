# T03 — Browser tab session restore for single-live-webview tabs

Status: conditional
Tag: tonight [browser]
Depends on: T01, T01b

## Goal
Restore tabbed browser tiles after app restart without hydrating every tab as a live WKWebView. A restored browser tile should show the same tab list and active tab; inactive tabs remain snapshots until selected.

## Implementation decision
Build on T01/T01b’s model:
- BrowserState persists `BrowserTile.tabs` and `activeTabId`.
- On restart, `TileSpawner.restartBrowserTile(tileId:)` loads/restores only the active tab into the tile’s single live `WKWebViewBrowserRuntime`.
- The tab strip renders all persisted tabs immediately from metadata.
- Inactive tabs are not live webviews and do not count against browser runtime budget.
- If an inactive tab has `interactionState`, it may be restored when selected; otherwise load its URL.

## Scope
- `Sources/ContinuumRevivedCore/BrowserState.swift`
  - use T01’s schema/model helpers.
- `Sources/ContinuumRevived/App/TileSpawner.swift`
  - restore active tab URL/title/interactionState;
  - pass full tab model into `BrowserTileNSView`;
  - persist active-tab snapshots before eviction/termination.
- `Sources/ContinuumRevived/App/ZoneRuntimeController.swift`
  - ensure browser snapshot/eviction still records the active tab and tab model.
- `Sources/ContinuumRevived/App/ContinuumApp.swift`
  - add app flag `--browser-tab-restore-check`.
- `Sources/ContinuumRevived/Canvas/BrowserTileNSView.swift`
  - render restored tab strip from persisted model;
  - expose QA snapshot for restored tab count/title/active id.

## Out of scope / non-goals
- No background tab hydration.
- No multi-webview-per-tab model.
- No cross-tile tab drag/drop.
- No password/form-value persistence guarantees beyond existing opaque `interactionState`; T04 handles credential guardrails.
- No Chrome profile/session import.

## Product / UX policy
Restore semantics:
- Restored tab list appears immediately from persisted titles/URLs.
- Active tab is restored first.
- Inactive tabs may show cached title/favicon and load only when selected.
- Missing/invalid tab URLs degrade to `about:blank` with an error note in the manifest; they must not crash launch.
- If `activeTabId` is missing/invalid, select first tab and persist the repair on the next browser save.
- Before eviction/termination and tab switch, persist the full tab model with nil interaction-state clears; do not rely on the current `upsertBrowserTile` behavior that only writes `interactionState` when nonnil.

Performance policy:
- Restoring one browser tile with 20 tabs creates at most one live browser runtime and one WKWebView at boot.
- Restoring N visible browser tiles creates at most N live browser runtimes, subject to existing browser LRU/budget enforcement.

## Acceptance criteria
- [ ] A seeded BrowserState with one tile and 3 tabs restores with 3 visible tabs.
- [ ] The seeded active tab remains active and drives the URL field/tile title.
- [ ] Inactive tabs do not create extra live WKWebViews at restore.
- [ ] Switching to an inactive restored tab loads/restores that tab and updates active-tab persistence.
- [ ] 20-tab restore is bounded: no startup freeze and no 20 WKWebViews.
- [ ] Legacy one-page BrowserState still restores through T01 migration.

## Nightly QA contract
Required app flag:

```bash
swift run continuum-revived --browser-tab-restore-check
```

Required regression flags:

```bash
swift run continuum-revived --browser-restore-state-check
swift run continuum-revived --browser-lru-budget-check
swift run continuum-revived --browser-profile-persistence-check
```

Required artifact:

```text
qa-runs/<timestamp>/browser-tab-restore/manifest.json
```

Manifest fields:

```json
{
  "check": "browser-tab-restore",
  "seededTabCount": 20,
  "restoredTabCount": 20,
  "activeTabURL": "data:text/html...active",
  "activeTabTitle": "Active Restored Tab",
  "webViewCreationCountAtBoot": 1,
  "browserRuntimeCountAtBoot": 1,
  "inactiveTabsHydratedAtBoot": 0,
  "switchInactiveUpdatedActiveTab": true,
  "legacyOneTabMigrationStillWorks": true,
  "invalidActiveTabFallbackUsed": true,
  "usedTileSpawnerRestartBrowserTile": true,
  "restoredBrowserTileNSView": true,
  "seedStatePath": "...",
  "profileIdPreserved": true,
  "storageGroupIdPreserved": true,
  "restoreDurationMs": 0,
  "restoreDurationWithinBudget": true
}
```

Reviewer rejection rules:
- Reject if boot creates one WKWebView per tab.
- Reject if app check seeds state but does not drive `TileSpawner.restartBrowserTile` / real `BrowserTileNSView`.
- Reject if restore silently drops profile/storageGroup data.
- Reject if a 20-tab fixture is claimed but artifact omits webview/runtime counts.

## Stop conditions
Stop / do not mark Done if:
- T01/T01b are not merged or equivalent model/UI seams do not exist;
- restoring multi-tab state requires broad changes to workspace/zone runtime ownership;
- interactionState restore causes crashes or corrupts active tab URL/title;
- test only round-trips JSON and never exercises app restore;
- artifact omits bounded hydration evidence.

## Verification commands

```bash
swift build
swift run ContinuumRevivedCoreChecks
swift run continuum-revived --browser-tab-restore-check
swift run continuum-revived --browser-restore-state-check
swift run continuum-revived --browser-lru-budget-check
swift run continuum-revived --browser-profile-persistence-check
```
