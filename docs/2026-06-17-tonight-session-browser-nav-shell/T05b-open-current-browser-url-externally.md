# T05b — External browser handoff (parked / do not implement)

Status: blocked / user-deferred
Tag: browser [parked]
Depends on: fresh product approval

## Decision
Do **not** implement open-in-Chrome or external-browser handoff in the current browser push.

The user explicitly said: “i dont want open in chrome”. Treat this file as parked research only, not an implementation ticket and not a nightly candidate.

## Scope for current bundle
- No command palette action to open the current browser tile in Chrome.
- No browser tile menu action to open externally.
- No Chrome bundle-id targeting.
- No default-browser fallback implementation.
- No QA app flag for external opening.

## If this is reopened later
A future ticket must be rewritten from scratch and must include:
- fresh product approval;
- exact UX label and target browser semantics;
- URL scheme allowlist;
- URL userinfo/query/fragment redaction;
- fake opener/workspace QA so real browsers are not launched;
- no Chrome profile/password/cookie access.

Minimum future security wording if reopened:

```markdown
URL userinfo policy:
- Logs, manifests, status messages, and QA artifacts must never include URL username/password userinfo.
- Redaction must remove userinfo before recording a URL, e.g. `https://user:pass@example.com/path?token=x#frag` becomes `https://example.com/path?<redacted>#<redacted>` or otherwise omits userinfo entirely.
- Add a fixture URL containing username, password, query token, and fragment secret; prove none of those secret values appear in manifests/logs.
```

## Stop condition for agents
If an overnight or autonomous agent selects this ticket, it must stop and report:

> T05b is blocked/user-deferred. No open-in-Chrome or external-browser handoff should be implemented in this bundle.
