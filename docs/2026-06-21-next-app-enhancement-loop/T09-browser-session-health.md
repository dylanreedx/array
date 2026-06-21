# T09 — Browser session health panel

Status: implementation-ready

## Goal
Users can understand browser runtime pressure: live WebViews, restored tabs, suspended/inactive tab counts, and profile/storage group per browser tile.

## Implementation decision
Add a read-only health/debug panel first. This is useful for validating the browser overhaul and does not require new product semantics.

## Scope
- For each browser tile show:
  - active URL/title;
  - tab count;
  - live WKWebView count impact;
  - profile/storage group id;
  - last persisted update time if available.
- Add app check artifact using existing browser restore/profile checks.

## Out of scope
- Controls to kill/suspend webviews.
- Profile switching.
- Memory byte accounting unless already available.

## Deterministic checks
Add app flag:

```text
--browser-session-health-check
```

Verify multi-browser/multi-tab state produces expected counts and no secrets/URLs beyond fixture URLs are leaked in artifacts.

## QA artifact

```text
qa-runs/<timestamp>/browser-session-health/manifest.json
```

Required fields:
- `browserTileCount`
- `tabCountTotal`
- `liveWebViewCount`
- `profileIdsPresent: true`
- `artifactSecretFree: true`
