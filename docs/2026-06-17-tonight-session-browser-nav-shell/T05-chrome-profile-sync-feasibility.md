# T05 — Chrome integration guardrails matrix

Status: implementation-ready (guardrail matrix only)
Tag: tonight [browser] [security]
Depends on: — · Blocks: unsafe Chrome/profile work

## Goal
Encode the Chrome-profile/sync decision as testable guardrails so future agents cannot accidentally implement direct Chrome profile reuse, password/cookie scraping, Chrome Sync reuse, or CDP attachment to the user’s default profile.

## Implementation decision
Continuum must not sync with Chrome by reading, reusing, or mutating the user’s live Chrome profile.

Safe direction for this bundle:
1. Continuum-owned WKWebView profiles for in-canvas browsing.
2. Later companion Chrome extension + Native Messaging only if explicitly re-approved, with explicit permissions.
3. User-mediated import/export only as explicit migration.
4. Optional isolated Chrome/CDP mode only with an app-owned separate `--user-data-dir`.

User preference update: do **not** implement open-in-Chrome/default-browser handoff in this bundle. Any external-browser handoff requires a fresh product decision.

This ticket implements the guardrail matrix only.

## Scope
- Add pure model/tests, likely in `Sources/ContinuumRevivedCore/`:
  - `ChromeIntegrationMatrix`
  - `ChromeIntegrationDataKind`
  - `ChromeIntegrationMethod`
  - `ChromeIntegrationVerdict`
- Add `ContinuumRevivedCoreChecks` assertions for rejected/safe paths.
- Add app flag:
  - `swift run continuum-revived --chrome-integration-guardrails-check`
- App check greps production Swift for suspicious Chrome profile/password/cookie path access and writes a manifest.

## Out of scope / non-goals
- No opening Chrome/default browser in this ticket.
- No open-in-Chrome/default-browser follow-up in this bundle unless the user explicitly reverses the decision.
- No companion extension implementation.
- No bookmark/history import.
- No CDP/Chrome automation.
- No reading Chrome files, even read-only.

## No-go matrix
Hard rejected:
- Passwords × direct profile/database read.
- Cookies/session tokens × direct profile/database read.
- Any data kind × live profile reuse as Continuum profile.
- Passwords/cookies × Chrome Sync.
- CDP attach to the user’s default Chrome profile.
- Scanning `~/Library/Application Support/Google/Chrome/Default` automatically.

Conditionally safe with consent:
- Bookmarks/history via user-chosen export/import file.
- Active tab URL/title via companion extension with explicit user action/permissions.
- External-browser handoff is user-deferred/out of scope for this bundle.
- Isolated Chrome/CDP with separate app-owned `--user-data-dir` for developer automation only.

## Acceptance criteria
- [ ] Matrix exists for bookmarks, history, cookies, passwords, extensions, tabs, Chrome Sync, CDP/default profile.
- [ ] Matrix rejects direct Chrome password/cookie/profile reads.
- [ ] Matrix states Chrome Sync is not an available third-party app path.
- [ ] Matrix marks external-browser handoff as user-deferred/out of scope for this bundle.
- [ ] Matrix marks companion extension/native messaging as design/spike with explicit permissions, not automatic sync.
- [ ] App check reports zero production hits for suspicious Chrome profile secret paths, except allowlisted docs/tests.

## Nightly QA contract
Required pure check:

```bash
swift run ContinuumRevivedCoreChecks
```

Required app flag:

```bash
swift run continuum-revived --chrome-integration-guardrails-check
```

Required artifact:

```text
qa-runs/<timestamp>/chrome-integration-guardrails/manifest.json
```

Manifest fields:

```json
{
  "check": "chrome-integration-guardrails",
  "passwordDirectReadRejected": true,
  "cookieDirectReadRejected": true,
  "liveProfileReuseRejected": true,
  "chromeSyncUnavailable": true,
  "defaultProfileCDPRejected": true,
  "externalBrowserHandoffOutOfScope": true,
  "extensionBridgeRequiresConsent": true,
  "sourceGrepScope": ["Sources/**/*.swift"],
  "allowlistedDocTestHits": [],
  "productionSwiftFilesScanned": true,
  "suspiciousProductionHits": []
}
```

Suspicious grep strings:
- `Login Data`
- `Cookies`
- `Local State`
- `User Data/Default`
- `Chrome/Default`
- `~/Library/Application Support/Google/Chrome`
- `--remote-debugging-port` with default profile paths

Reviewer rejection rules:
- Reject if any unsafe path is represented as “supported,” “maybe,” or “investigate in implementation.”
- Reject if app check only inspects docs and not production Swift sources.
- Reject if matrix blesses attaching CDP to the default user profile.

## Stop conditions
Stop / do not mark Done if:
- implementation starts touching Chrome profile files;
- guardrail matrix leaves passwords/cookies undecided;
- app check finds production code reading Chrome secret/profile paths;
- a future extension/native-messaging path lacks extension ID allowlist and message-schema constraints.

## Verification commands

```bash
swift build
swift run ContinuumRevivedCoreChecks
swift run continuum-revived --chrome-integration-guardrails-check
```

## Safe follow-up tickets
- No T05b/open-in-Chrome/default-browser implementation in this bundle; user explicitly removed it from scope.
- Later spike — companion Chrome extension + Native Messaging with explicit permission/message schema, only if explicitly re-approved.
- Later spike — bookmark import/export with user-chosen file.
- Later spike — isolated Chrome/CDP developer mode with separate user data directory.

## Research sources
- Chromium user data dir: https://chromium.googlesource.com/chromium/src/+/HEAD/docs/user_data_dir.md
- Chrome Sync API restrictions: https://blog.chromium.org/2021/01/limiting-private-api-availability-in.html
- Chrome native messaging: https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging
- Chrome remote debugging profile restriction: https://developer.chrome.com/blog/remote-debugging-port
- Chrome DevTools Protocol: https://chromedevtools.github.io/devtools-protocol/
