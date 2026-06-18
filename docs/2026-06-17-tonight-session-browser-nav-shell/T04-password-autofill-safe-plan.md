# T04 — Password/autofill security guardrails and policy tests

Status: implementation-ready (guardrails only)
Tag: tonight [browser] [security]
Depends on: T02 policy default-off · Blocks: T04b/T04c/T04d/T04e

## Goal
Install hard no-go boundaries and deterministic security policy tests before any password vault, form detector, fill script, or save prompt is implemented.

User outcome this protects: Continuum may eventually help users sign into websites, but it must never look like or behave like credential-stealing malware.

## Implementation decision
This ticket implements **policy/guardrails only**.

Implement:
- credential integration no-go matrix;
- origin/fill policy model;
- loopback HTTP exception policy;
- redaction rules for browser credential artifacts/logs;
- app check proving no current production path reads Chrome password/cookie/profile secrets and no fixture secret lands in workspace/QA artifacts.

Do **not** implement Keychain storage, form detection, fill prompts, fill scripts, or save/update prompts in this ticket. T04b starts the isolated Keychain service after these guardrails land.

## Scope
- Add pure policy types in `Sources/ContinuumRevivedCore/`, likely new files:
  - `BrowserCredentialPolicy.swift`
  - `CredentialOriginMatcher.swift`
  - `BrowserCredentialIntegrationMatrix.swift`
  - `SecretRedactor.swift` or browser-specific redaction helper if no existing redactor exists.
- Add tests in `Sources/ContinuumRevivedCoreChecks/main.swift`.
- Add app flag in `Sources/ContinuumRevived/App/ContinuumApp.swift`:
  - `--browser-credential-guardrails-check`
- App check may live in `ContinuumApp.swift` or a browser QA helper.

## Out of scope / non-goals
- No Keychain writes/reads yet.
- No JS injected into web pages.
- No `WKScriptMessageHandler` form detector.
- No password save/fill UI.
- No import from Chrome/1Password/Bitwarden.
- No direct reads of browser profile files.

## No-go policy
Hard rejections:
- Do not read Chrome `Login Data`.
- Do not decrypt Chrome password blobs.
- Do not read Chrome `Cookies` or session tokens.
- Do not reuse or point WebKit at Chrome’s live profile directory.
- Do not use Chrome Sync APIs for passwords/cookies.
- Do not call undocumented 1Password/Bitwarden/native password-manager hosts.
- Do not store website passwords in workspace JSON, BrowserState, tile metadata, logs, crash reports, screenshots, or QA artifacts.
- Do not send a credential vault or multiple credentials into JavaScript.
- Do not fill public `http://` origins.

HTTP exception policy:
- Default: deny all `http://` credential fill/save.
- Optional dev exception must be disabled by default.
- If enabled later, allow only loopback hosts:
  - `localhost`
  - `127.0.0.0/8`
  - `::1`
- Loopback matching must preserve exact port by default (`localhost:3000` ≠ `localhost:8080`).
- Never treat LAN/private-network HTTP (`192.168.*`, `10.*`, `172.16/12`) as loopback.

Origin matching policy:
- Exact origin match (`scheme`, canonical host, port) may be `.allow`.
- HTTPS-to-HTTP downgrade is `.deny`.
- Different host is `.deny` unless a future PSL-backed policy returns `.confirm` for related subdomains.
- Without a real PSL implementation, cross-subdomain matching must be `.deny`, not naive suffix matching.
- Cross-origin iframe or cross-origin form action is `.deny` by default.

Inspectability policy:
- Browser Web Inspector (`WKWebView.isInspectable`) must be default-off from T02 before credential fill/save work starts.
- Credential QA checks must record whether inspectability is enabled and reject secret-bearing fill tests while inspectability is unexpectedly on.

## Acceptance criteria
- [ ] `BrowserCredentialIntegrationMatrix.default` rejects Chrome password/cookie/profile reads and Chrome Sync reuse.
- [ ] `CredentialOriginMatcher` covers exact HTTPS allow, HTTP downgrade deny, different host deny, cross-origin frame/action deny, and loopback exact-port policy.
- [ ] `BrowserCredentialPolicy.default` has public HTTP fill disabled and loopback exception disabled by default.
- [ ] Redaction helper removes fixture secrets, API-key-like values, auth tokens, query values, and generated fill-script strings from logs/manifests.
- [ ] App check greps workspace/QA artifacts after a fixture-secret scenario and proves the fixture secret is absent.
- [ ] App check greps source for suspicious Chrome secret/profile strings and reports only documented allowlisted files/tests, not production integration code.

## Nightly QA contract
Required pure check:

```bash
swift run ContinuumRevivedCoreChecks
```

Required app flag:

```bash
swift run continuum-revived --browser-credential-guardrails-check
```

Required artifact:

```text
qa-runs/<timestamp>/browser-credential-guardrails/manifest.json
```

Manifest fields:

```json
{
  "check": "browser-credential-guardrails",
  "chromeLoginDataReadRejected": true,
  "chromeCookieReadRejected": true,
  "chromeProfileReuseRejected": true,
  "chromeSyncPasswordReuseRejected": true,
  "publicHTTPFillDefault": "deny",
  "loopbackHTTPExceptionDefaultEnabled": false,
  "localhostPortsDistinct": true,
  "crossOriginFrameDenied": true,
  "crossOriginActionDenied": true,
  "inspectabilityDefaultOff": true,
  "fixtureSecretAbsentFromWorkspace": true,
  "fixtureSecretAbsentFromQARuns": true,
  "sourceGrepScope": ["Sources/**/*.swift"],
  "qaArtifactGrepScope": "qa-runs/<timestamp>/browser-credential-guardrails",
  "allowlistedSuspiciousHits": [],
  "fixtureSecretAbsentAfterManifestWrite": true,
  "suspiciousChromePathProductionHits": []
}
```

Reviewer rejection rules:
- Reject if any guardrail is only prose and not represented in tests or manifest.
- Reject if source grep finds production code opening Chrome `Login Data`, `Cookies`, `Local State`, `User Data/Default`, or `Chrome/Default` paths.
- Reject if artifact contains the fixture password/token used by the check.

## Stop conditions
Stop / do not mark Done if:
- implementing agent starts building Keychain/form-fill features in this ticket;
- policy allows public HTTP fill;
- loopback exception includes LAN/private IP ranges;
- origin matcher uses naive string suffix matching for eTLD+1 decisions;
- `webView.isInspectable` is still hardcoded on by default;
- artifact/log redaction cannot prove fixture secrets are absent.

## Verification commands

```bash
swift build
swift run ContinuumRevivedCoreChecks
swift run continuum-revived --browser-inspection-policy-check
swift run continuum-revived --browser-credential-guardrails-check
```

## Follow-up ticket split
- T04b — Keychain `PasswordVaultService` only, no WebKit JS.
- T04c — WKWebView login-form metadata detector, no values.
- T04d — native fill prompt + one-shot fill script.
- T04e — save/update prompt with pending secrets in memory only.
- T04f — password-manager/Chrome extension bridge spike.

Do not start T04c/T04d/T04e until T04 and T04b pass.

## Research sources
- Apple Keychain Services: https://developer.apple.com/documentation/security/keychain-services
- `kSecClassInternetPassword`: https://developer.apple.com/documentation/security/ksecclassinternetpassword
- `WKUserContentController`: https://developer.apple.com/documentation/webkit/wkusercontentcontroller
- `WKScriptMessageHandler`: https://developer.apple.com/documentation/webkit/wkscriptmessagehandler
- Public Suffix List: https://publicsuffix.org/
- OWASP Logging Cheat Sheet: https://cheatsheetseries.owasp.org/cheatsheets/Logging_Cheat_Sheet.html
- Research artifact: `.pi/agent-runs/web-research-20260618T014546Z-a73a97/final.md`
