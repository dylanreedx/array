# Audit/reimplementation queue — overnight branch quality gate

Status: active audit queue for `scripts/overnight-audit-reimpl-prompt.md`.

Purpose: audit and, where safe, repair the work produced on branch `nightly/browser-nav-shell-loop-2026-06-18` before anything is merged.

Legend:
- `[ ]` not audited
- `[x]` audited/fixed and acceptable
- `[!]` needs human / revert candidate / blocked

Rules:
- One queue item per loop iteration.
- Start with product pain points, then cover all ticket commits.
- Passing generated checks is not enough; inspect real code and user path.
- Mark `[!]` instead of pretending quality is acceptable.

## Priority pain-point audits

- [x] A01 — Shell zoom/pan performance around terminal tiles
  Focus: T12/T07/T16/T06 interactions, `CanvasNSView` layout loops, `GhosttyTerminalView` resize behavior, expensive terminal invalidation during camera movement.
  Relevant commits: `e44c979`, `cddf716`, `3a959c9`, `db22a3b`.
  Required output: identify why zooming around shell tiles still feels bad; fix if scoped and safe, otherwise produce concrete reimplementation ticket.
  Audit note: fixed camera-only terminal churn. Rows/columns now stay invariant across zoom sweep and pure viewport changes no longer mark tile content dirty; see `/Users/dylan/.pi/overnight-runs/continuum-revived/run-20260620T212451/audits/A01.md` and artifact `qa-runs/2026-06-21T013203Z/terminal-zoom-pan-stability/manifest.json`.

- [x] A02 — Shell default readability / Ghostty-tmux initial scale too small
  Focus: default terminal font/cell sizing, tile dimensions, tmux profile startup, Ghostty surface scale, app settings defaults.
  Relevant commits: terminal/tmux history plus T12/T13.
  Required output: make default shell tile usable without immediate zoom if scoped and safe, or write exact change plan.
  Audit note: fixed new-shell defaults. Terminal tiles now default to 900×584 at zoom 1 with an embedded Ghostty font-size default of 16 (0 setting = inherit Ghostty); production spawner/tmux check measured 112×24 cells, tmux wrapping, and input in `qa-runs/2026-06-21T014507Z/terminal-default-readability/manifest.json`; see `/Users/dylan/.pi/overnight-runs/continuum-revived/run-20260620T212451/audits/A02.md`.

- [x] A03 — Browser inspect element / devtools product reality
  Focus: T02 implementation, real context-menu/menu path, WebKit inspectability policy, `TileSpawner.spawnBrowserForNewWindow`, default-off developer setting.
  Relevant commit: `07c7d0b`.
  Required output: verify whether inspect element actually exists in app; implement/fix if missing.
  Audit note: fixed product-visible Web Inspector enablement without pretending public WebKit can open Inspect Element. Settings now exposes `Browser > Enable Safari Web Inspector for Browser Tiles (open from Safari Develop)`, live webviews re-apply the policy on settings change, and `target=_blank` children use `BrowserEngineContext` policy; artifact `qa-runs/1782007004/browser-inspection-policy/manifest.json`; see `/Users/dylan/.pi/overnight-runs/continuum-revived/run-20260620T212451/audits/A03.md`.

- [x] A04 — Browser tabs/session restore product reality  
  Focus: T01/T01b/T03, actual tab UI, one-live-webview runtime behavior, restore semantics, user-visible behavior.  
  Relevant commits: `0bf2934`, `b8a88c8`, `ddfd301`.  
  Required output: determine whether browser was truly touched and useful; fix or mark revert-candidate.  
  Audit note: fixed stale title/interaction-state stamping during tab loads and hardened the app check to use `TileSpawner.spawnBrowser` with real WKWebView title changes plus persisted tab-model evidence; see `/Users/dylan/.pi/overnight-runs/continuum-revived/run-20260620T212451/audits/A04.md` and artifact `qa-runs/1782007704/browser-tab-ui-single-live/manifest.json`.

- [ ] A05 — tmux shell tile persistence reality check  
  Focus: tmux session lifecycle, restart/reload behavior, delete lifecycle, app support roots, shell identity.  
  Relevant prior commits: `0a16ff1`, `ecc7321`, `2c3b1d5`, `d1cd54d`; current branch terminal commits.  
  Required output: verify persistence in real app path; fix or precise handoff.

- [ ] A06 — Shell theme fidelity vs Dylan's Ghostty/tmux theme  
  Focus: Ghostty config/theme loading, tmux colors, TERM, default shell env, font/theme mismatch.  
  Relevant files: terminal engine/runtime/settings.  
  Required output: concrete gap list and safe implementation if obvious.

## Full branch audits

- [ ] A07 — T13 shell scroll ergonomics audit  
  Commit: `e5a7492`.  
  Focus: scroll delta normalization, trackpad/mouse feel, no hidden regressions.

- [ ] A08 — T12 terminal zoom-pan stability audit  
  Commit: `e44c979`.  
  Focus: body-height alignment, idempotent Ghostty resize, flicker/perf.

- [ ] A09 — T06/T16/T07 navigation framing audit  
  Commits: `cddf716`, `3a959c9`, `db22a3b`.  
  Focus: camera readability, jump indicators, animation defaults, shell tile interactions.

- [ ] A10 — T08 previous navigation audit  
  Commit: `118dc28`.  
  Focus: real user path, no over-broad `fileprivate`, focus history semantics, checks not self-fulfilling.

- [ ] A11 — T04/T04b password/keychain guardrails audit  
  Commits: `5892973`, `a61ad02`.  
  Focus: no credential leakage, namespace boundary, no accidental fill/save behavior.

- [ ] A12 — T05 Chrome integration guardrail audit  
  Commit: `993f630`.  
  Focus: no open-in-Chrome/default-browser handoff, no Chrome profile scraping path.

- [ ] A13 — T01/T01b/T03 browser architecture code audit  
  Commits: `0bf2934`, `b8a88c8`, `ddfd301`.  
  Focus: schema, runtime, snapshots, restore correctness, memory/live-webview budget.

- [ ] A14 — T02 Web Inspector code audit  
  Commit: `07c7d0b`.  
  Focus: inspectability applied everywhere, default-off, UX discoverability.

- [ ] A15 — Whole-branch revert/squash recommendation  
  Focus: summarize all audit artifacts and recommend keep/fix/revert for each commit before merge.
