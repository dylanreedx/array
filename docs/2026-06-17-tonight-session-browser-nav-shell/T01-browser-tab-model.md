# T01 — Browser tab model + schema migration (core slice)

Status: implementation-ready
Tag: tonight [browser]
Depends on: — · Blocks: T01b, T03

## Goal
Add the pure browser-tab model and BrowserState schema needed for tabbed browser tiles, without changing the live browser UI/runtime yet. After this ticket, existing single-page browser behavior must keep working, and legacy BrowserState files must decode into a one-tab model.

## Implementation decision
This is a **model/schema-only slice**.

Implement:
- `BrowserTab` value type;
- `BrowserTabModel` / tab-list helper operations;
- `BrowserState` schema version bump and backwards-compatible decode;
- tests and an app check proving legacy one-page tiles migrate safely.

Do **not** add tab strip UI, tab switching, multiple WKWebViews, or session-restore behavior in this ticket. Those are T01b/T03.

Schema policy:
- Bump `BrowserState.currentSchemaVersion` from `2` to `3`.
- Keep existing `BrowserTile.url`, `BrowserTile.title`, and `BrowserTile.interactionState` as the active-tab mirror for compatibility with current `TileSpawner` / restore code.
- Add tab fields to `BrowserTile`:
  - `tabs: [BrowserTab]`
  - `activeTabId: UUID`
- Decoding a v1/v2 tile without `tabs` must synthesize exactly one tab from the legacy tile fields.
- Decoding a v3 tile with missing/invalid `activeTabId` must select the first tab and record a deterministic fallback in tests, not crash.
- Empty tab lists are not allowed in memory. Closing the last tab creates a fallback tab at `DefaultBrowserURL.fallback` (`about:blank`).

## Scope
- `Sources/ContinuumRevivedCore/BrowserState.swift`
  - add `BrowserTab`;
  - add `BrowserTabModel` or equivalent pure helper;
  - extend `BrowserTile` encode/decode;
  - add helpers such as `activeTab`, `activeTabIndex`, `withActiveTabMirrorUpdated()` if useful.
- `Sources/ContinuumRevivedCoreChecks/main.swift`
  - add pure tests for tab operations and Codable round trips.
- `Sources/ContinuumRevived/App/ContinuumApp.swift`
  - add app flag `--browser-tab-model-schema-check`.
- App-check helper can live near existing browser checks in `TileSpawner.swift` or `ContinuumApp.swift`.

## Out of scope / non-goals
- No visible tab UI.
- No tab switching inside `BrowserTileNSView`.
- No change to `target=_blank`; it remains current behavior until T01b/T03 explicitly change it.
- No password/autofill work.
- No Chrome profile/sync work.
- No attempt to interpret or redact opaque `WKWebView.interactionState` in this ticket.

## Product / data model policy
`BrowserTab` fields for this slice:

```swift
public struct BrowserTab: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var url: String
    public var title: String
    public var faviconURL: String?
    public let createdAt: Date
    public var lastAccessedAt: Date
    public var interactionState: Data?
}
```

Do not persist transient loading state in `BrowserTab`; loading belongs to the live runtime/UI.

Tab operation semantics:
- `activate(tabId:)` updates `activeTabId` and the selected tab's `lastAccessedAt`.
- `appendTab(url:title:now:)` appends a tab and makes it active by default.
- `close(tabId:)` selects the nearest right neighbor; if none, nearest left; if closing the last tab, creates one `about:blank` fallback tab.
- `updateActiveTab(url:title:faviconURL:interactionState:now:)` updates the active tab and legacy active-tab mirror.
- Passing `interactionState: nil` to active-tab update must clear the tab's stored interaction state and the legacy mirror, not preserve stale state.

## Acceptance criteria
- [ ] `BrowserState.currentSchemaVersion == 3`.
- [ ] v1/v2 JSON without `profileId`, `interactionState`, or `tabs` still decodes.
- [ ] Legacy BrowserTile `url/title/interactionState` decode into one synthesized active tab.
- [ ] v3 BrowserTile round-trips with multiple tabs and the same active tab id.
- [ ] Closing the active tab selects right neighbor, then left neighbor when needed.
- [ ] Closing the last tab leaves exactly one `about:blank` fallback tab.
- [ ] Existing browser checks still pass because legacy active-tab mirror fields remain usable.

## Nightly QA contract
Required pure check:

```bash
swift run ContinuumRevivedCoreChecks
```

Required app flag:

```bash
swift run continuum-revived --browser-tab-model-schema-check
```

Required artifact:

```text
qa-runs/<timestamp>/browser-tab-model-schema/manifest.json
```

Manifest fields:

```json
{
  "check": "browser-tab-model-schema",
  "schemaVersion": 3,
  "legacyDecodeSynthesizedTabCount": 1,
  "legacyActiveURL": "https://legacy.example/",
  "multiTabRoundTripCount": 3,
  "activeTabIdStable": true,
  "legacyFieldsMirrorActiveTab": true,
  "closeLastCreatesFallback": true,
  "usedProductionBrowserStateLoadPath": true,
  "legacyProfileIdPreserved": true,
  "legacyStorageGroupIdPreserved": true,
  "seedStatePath": "...",
  "artifactWrittenAfterAppFlag": true
}
```

Reviewer rejection rules:
- Reject if migration drops legacy URL/title/profile/storageGroup fields.
- Reject if production browser spawn/restore code must be updated just to keep single-page behavior working.
- Reject if model tests pass but no app artifact is written.

## Stop conditions
Stop / do not mark Done if:
- the ticket starts adding visible tab UI;
- the ticket starts creating more than one live `WKWebView` per browser tile;
- legacy BrowserState decode fails;
- any app check overwrites corrupt/unreadable BrowserState instead of failing safely;
- the artifact omits migration and active-tab mirror evidence.

## Verification commands

```bash
swift build
swift run ContinuumRevivedCoreChecks
swift run continuum-revived --browser-tab-model-schema-check
swift run continuum-revived --browser-restore-state-check
swift run continuum-revived --browser-profile-persistence-check
```
