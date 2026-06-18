# Handoff — tonight planning / nightly readiness

Date: 2026-06-18
Repo: `/Users/dylan/Documents/personal/continuum-revived`
Branch observed: `main...origin/main [ahead 6]`
Working tree observed dirty/untracked:
- `.pi/tmux-shell-persistence-artifacts.md`
- `.pi/tmux-shell-persistence-p4-artifact.md`
- `docs/2026-06-17-tonight-session-browser-nav-shell/`
- `docs/37-ticket-authoring-style-guide.md`

## Why this handoff exists
Context is high. This session created and hardened a large ticket/planning bundle for an overnight autonomous run. Do not continue from memory; use the docs and agent artifacts below.

## Files created/edited

Main planning bundle:
- `docs/2026-06-17-tonight-session-browser-nav-shell/README.md`
- `docs/2026-06-17-tonight-session-browser-nav-shell/00-charter.md`
- `docs/2026-06-17-tonight-session-browser-nav-shell/01-canvas-navigation-feel-plan.md`
- `docs/2026-06-17-tonight-session-browser-nav-shell/02-nightly-run-readiness.md`
- `docs/2026-06-17-tonight-session-browser-nav-shell/HANDOFF.md` (this file)

Tickets created/updated:
- Browser: `T01`–`T05`
- Navigation/canvas/terminal: `T06`, `T07`, `T08`, `T12`, `T13`, `T16`
- Other planned tickets: `T09`–`T11`, `T14`–`T18`, plus later `T19`–`T22` found in the bundle

Root style guide:
- `docs/37-ticket-authoring-style-guide.md`

## Major decisions made

### Ticket-writing standard
Future implementation tickets must be strict implementation contracts, not brainstorms. See:
- `docs/37-ticket-authoring-style-guide.md`

Required: goal, implementation decision, scope, non-goals, code seams, numeric policy/defaults where relevant, acceptance criteria, nightly QA contract, artifact schema, stop conditions, verification commands.

### Navigation / terminal nightly order
Recommended safe order is now:
1. `T13` — shell scroll ergonomics: explicit wheel normalizer; remove hidden precise-delta `2x`.
2. `T12` — terminal zoom-pan stability: body-height alignment + idempotent Ghostty resize.
3. `T06` — camera-aware visible jump indicators.
4. `T16` — readability policy + zone fit framing constants.
5. `T07` — jump framing/smoothing; animation only after T12 guardrail or behind default-off flag.
6. `T08` — previous view/tile/zone history after transition semantics exist.

### T13 concrete implementation decision
Current code has a likely scroll issue:
- `Sources/ContinuumRevived/TerminalEngine/GhosttyTerminalView.swift::scrollWheel(with:)`
- It doubles precise deltas:
  ```swift
  if event.hasPreciseScrollingDeltas { x *= 2; y *= 2 }
  ```
T13 now requires `TerminalWheelNormalizer`, default precise multiplier `1.0`, settings/config, production-path app check, artifact manifest.

### T12 concrete implementation decision
Current terminal pan/zoom risk:
- `CanvasNSView.setViewport` → `layoutAllTiles` → `layoutTile` → `terminalTile.runtime.setSurfacePixelSize(...)`
- `GhosttyTerminalView.setSurfacePixelSize` currently calls Ghostty size unconditionally.
- Audit found body height mismatch too: actual tile chrome uses `TileNSView.chromeBarHeight`, but terminal surface sizing subtracted fixed `TileNSView.titleBarHeight`.
T12 now requires:
- surface height uses actual `chromeBarHeight` / body height;
- Ghostty surface resize is idempotent for unchanged normalized pixel size;
- counters for requested/applied/skipped resize;
- app check `--terminal-zoom-pan-stability-check` with manifest.

### Browser architecture decision so far
Current app is WKWebView-backed, not Electron/Chromium.
- `BrowserEngineContext.makeWebView` sets `webView.isInspectable = true`.
- Browser state is currently single URL/title/profile/interactionState per browser tile.
- Browser tabs are not implemented.
- Chrome profile/password sync is rejected.

Browser tickets require more hardening before overnight implementation. Early audit summary:
- `T01` browser tab model: partial; pure model subset okay, full runtime/UI tabs not ready until WKWebView-per-tab vs reuse decision is made.
- `T02` inspect/devtools: not implementation-ready; current wording is too Chromium/Electron. For WKWebView, first path is Safari Web Inspector / `isInspectable`, not embedded DevTools or inspect-at-point unless public API is proven.
- `T03` tab restore: not ready; depends on T01 data/runtime model.
- `T04` password/autofill: good security plan but should be split; do not implement full password fill overnight until guardrails are finalized.
- `T05` Chrome sync: decision-ready as guardrails only; open-in-Chrome/default-browser handoff is now user-deferred/out of scope. Extension/CDP/import remain spikes/design.

Security audit for T04/T05 says: do **not** allow password/autofill fill/save or Chrome extension/import/CDP implementation overnight yet. Open-in-Chrome/default-browser handoff was later removed from scope by user preference.

## Agent/audit artifacts to read next

### Navigation/terminal audits already synthesized into docs
- `code-reviewer-20260618T012440Z-d1023e` — ticket implementation readiness
- `qa-reviewer-20260618T012440Z-ab5490` — QA/oracle readiness
- `ux-reviewer-20260618T012440Z-ffed20` — UX coherence
- `code-reviewer-20260618T012440Z-430465` — repo implementation seams
- `qa-reviewer-20260618T012440Z-a9444a` — overnight harness/readiness
- `code-reviewer-20260618T012806Z-a91403` — T13 scroll seam
- `code-reviewer-20260618T012806Z-beceff` — T12 flicker seam
- `qa-reviewer-20260618T012806Z-1ce41f` — T12/T13 QA contracts
- `ux-reviewer-20260618T012806Z-aa1809` — T12/T13 UX thresholds
- `code-reviewer-20260618T012806Z-e66b35` — T12/T13 interaction with T07 smoothing

### Browser audits completed/read partially
- `code-reviewer-20260618T013948Z-aaa80a`
  - Browser implementation seams for T01–T05.
  - Summary read; final at `.pi/agent-runs/code-reviewer-20260618T013948Z-aaa80a/final.md`.
- `ux-reviewer-20260618T013948Z-f51921`
  - Browser UX/product coherence.
  - Summary read; final at `.pi/agent-runs/ux-reviewer-20260618T013948Z-f51921/final.md`.
- `code-reviewer-20260618T013948Z-57fdee`
  - Security audit for T04/T05.
  - Summary read; final at `.pi/agent-runs/code-reviewer-20260618T013948Z-57fdee/final.md`.
- `code-reviewer-20260618T013948Z-bb5d00`
  - Browser ticket implementation readiness.
  - Summary read; final at `.pi/agent-runs/code-reviewer-20260618T013948Z-bb5d00/final.md`.

### Browser audit still pending at handoff time
Check before continuing:
- `qa-reviewer-20260618T013948Z-b2247a`
  - Browser nightly QA readiness.
  - Expected final: `.pi/agent-runs/qa-reviewer-20260618T013948Z-b2247a/final.md`

### Autonomous-loop research artifacts
Completed but not deeply synthesized in this handoff:
- `web-research-20260618T013915Z-7e4b6e` — autonomous coding prompting best practices
- `web-research-20260618T013915Z-9451f3` — overnight non-interactive agent patterns
- `web-research-20260618T013915Z-8bafda` — LLM reviewer/QA guardrails

Initial conclusion: our style guide aligns well; the remaining gap is runner/preflight observability, not ticket prompt quality.

## Commands/tools run this session
No code tests were run. This was planning/research/doc writing only.

Representative commands:
- `ls`, `find`, `rg` over docs/Sources.
- Read current browser/navigation/terminal code seams.
- Multiple `delegate_agent` runs for web research, code review, QA review, UX review.
- `git status --short --branch` observed dirty/ahead state.

No `swift build`, `run-matrix`, or app checks were run.

## Key risks / blockers before any Ralph loop
1. **Do not run overnight from current dirty/ahead `main`.** Create/switch to intentional branch and clean/commit/stash planning docs first.
2. **Runner observability is weak.** Add or use `02-nightly-run-readiness.md` guidance: run-level `status.json`, `events.jsonl`, `report.md`, timeout, prompt override, branch/preflight, artifact preservation.
3. **Browser tickets are not ready as a broad batch.** Safe browser candidates are now split and bounded:
   - T02 Web Inspector default-off policy;
   - T05 Chrome guardrails matrix;
   - T04 credential guardrails;
   - T04b isolated Keychain vault after T04;
   - T01 model/schema slice;
   - T01b/T03 only after prerequisites. T05b is blocked/user-deferred.
4. **Do not implement password vault/autofill overnight yet.** Security audit requires more guardrails first: `webView.isInspectable` policy, loopback HTTP allowlist, WKScriptMessageHandler lifecycle, navigation race denial, redaction tests.
5. **T07 animation depends on T12 guardrail.** If T12 fails, T07 should only land non-animated framing or animation behind default-off flag.

## Recommended next actions

### Immediate next session
1. Read this handoff.
2. Check whether `qa-reviewer-20260618T013948Z-b2247a/final.md` exists; if yes, read it.
3. Finish browser ticket hardening:
   - rewrite/split T01 as pure model-first or make runtime choices explicit;
   - rewrite T02 as WKWebView/Safari Web Inspector spike/enablement, not Chromium DevTools;
   - mark T03 blocked on T01;
   - split T04 into guardrail tickets before implementation;
   - keep T05 as guardrails only; T05b/open-in-Chrome is blocked/user-deferred; extension/import/CDP remain spikes only if explicitly re-approved.
4. Optionally patch `scripts/overnight-loop.sh` for preflight/reporting before sleeping.

### If preparing the nightly branch
1. Create branch, e.g. `nightly/navigation-camera-terminal-2026-06-18`.
2. Decide whether to commit planning docs first.
3. Clear/archive `.pi` watches intentionally.
4. Use `02-nightly-run-readiness.md` preflight.
5. Start implementation queue with `T13`, then `T12`, not browser.

## Notes
- OpenAI API key was pasted earlier in chat; treat as compromised and revoke/rotate. Docs already warn not to use it.
- Browser/chrome decision: no direct Chrome profile/password sync; use Continuum-owned WKWebView profiles. Open-in-Chrome/default-browser handoff is out of scope unless explicitly re-approved.

## Addendum — final browser QA audit completed

After this handoff was first written, the pending browser QA audit completed:

- `qa-reviewer-20260618T013948Z-b2247a`
  - final: `.pi/agent-runs/qa-reviewer-20260618T013948Z-b2247a/final.md`
  - summary: `.pi/agent-runs/qa-reviewer-20260618T013948Z-b2247a/summary.md`
  - verdict: `DECISION: REWORK`

### Browser QA commands run by delegated QA agent
The QA reviewer reports these commands passed:
- `swift run ContinuumRevivedCoreChecks`
- `swift run continuum-revived --browser-url-focus-check`
- `swift run continuum-revived --browser-ui-delegate-check`
- `swift run continuum-revived --browser-element-context-check`
- `swift run continuum-revived --browser-target-blank-check`
  - artifact: `qa-runs/browser-target-blank-1781746866/manifest.json`
- `swift run continuum-revived --browser-restore-state-check`
  - artifact: `qa-runs/2026-06-18T014159Z/browser-restore-state/manifest.json`
- `swift run continuum-revived --browser-profile-persistence-check`
  - artifact: `qa-runs/2026-06-18T014200Z/browser-profile-persistence/manifest.json`

The reviewer first tried the wrong product command `swift run ContinuumRevived ...`; correct executable is `continuum-revived`.

### Browser audit conclusion
T01–T05 are **not ready as an overnight implementation batch**. Rewrite/split them first:

- `T01` browser tabs: model-only slice can be made ready, but full UI/runtime multi-tab needs decisions and real WKWebView app checks/artifacts.
- `T02` devtools/inspect: keep as design/spike or rewrite as honest WKWebView/Safari Web Inspector enablement. Do not promise Chromium-style DevTools or inspect-at-point.
- `T03` tab restore: blocked on T01 tab model/runtime decisions. Existing checks prove single-tile restore only.
- `T04` password/autofill: keep split/design until Keychain tests, redaction checks, origin matcher fixtures, app flags, artifact schemas, inspectability policy, and lifecycle/race guardrails are specified.
- `T05` Chrome profile sync: decision/guardrail work is good. Open-in-Chrome/default-browser handoff was later removed from scope; extension/import/CDP remain spikes/design only if re-approved.

### Updated next browser action
Before handing browser tickets to Ralph loop, rewrite T01–T05 under `docs/37-ticket-authoring-style-guide.md`.

Historical browser order from the earlier audit is superseded. Current order is in the final addendum: T02, T05, T04, T04b, T01, T01b, T03. T05b is blocked/user-deferred.

## Addendum — browser tickets researched and split into ready slices

Follow-up research completed:
- WKWebView inspectability/public API: `.pi/agent-runs/web-research-20260618T014546Z-7952f3/final.md`
- macOS external browser open patterns: `.pi/agent-runs/web-research-20260618T014546Z-9705e1/final.md`
- WKWebView/password Keychain guardrails: `.pi/agent-runs/web-research-20260618T014546Z-a73a97/final.md`

Browser ticket updates:
- `T01-browser-tab-model.md` is now implementation-ready for core tab model + BrowserState v3 schema migration only.
- `T01b-browser-tab-ui-runtime-single-live-webview.md` added as conditional UI/runtime slice after T01.
- `T02-browser-inspect-element-devtools.md` rewritten as WKWebView Web Inspector developer enablement, default-off; no Chromium DevTools promises.
- `T03-browser-tab-session-restore.md` rewritten as conditional restore ticket after T01/T01b with bounded hydration.
- `T04-password-autofill-safe-plan.md` rewritten as implementation-ready guardrails only; no fill/save/vault implementation.
- `T04b-keychain-password-vault-service.md` added as isolated Keychain storage implementation ticket.
- `T05-chrome-profile-sync-feasibility.md` rewritten as implementation-ready Chrome integration guardrails matrix.
- `T05b-open-current-browser-url-externally.md` was initially added, then changed to `blocked / user-deferred`; do not implement it.
- Bundle `README.md` browser order updated.

Superseded browser order from before user preference update. Current safe browser order:
1. T02
2. T05
3. T04
4. T04b
5. T01
6. T01b
7. T03

T05b is blocked/user-deferred.

## Addendum — open-in-Chrome removed from browser scope

User preference update: do **not** implement open-in-Chrome/default-browser handoff in this browser push.

Changes made:
- `README.md` browser order now excludes T05b.
- `T05-chrome-profile-sync-feasibility.md` now marks external-browser handoff as user-deferred/out of scope.
- `T05b-open-current-browser-url-externally.md` is now `blocked / user-deferred` and says agents must stop if selected.
- `02-nightly-run-readiness.md` now includes a browser-track readiness addendum.

Current safe browser order:
1. T02
2. T05
3. T04
4. T04b
5. T01
6. T01b
7. T03

Audit artifacts used for this patch:
- Security audit: `.pi/agent-runs/code-reviewer-20260618T015543Z-77d16d/final.md`
- QA audit: `.pi/agent-runs/qa-reviewer-20260618T015543Z-969224/final.md`
- Code-seam audit: `.pi/agent-runs/code-reviewer-20260618T015543Z-2344e9/final.md`

## Addendum — no-Linear overnight loop setup

User clarified: no Linear use; Linear free usage ran out.

Current branch:
- `nightly/browser-nav-shell-loop-2026-06-18`

Loop/script changes made:
- `scripts/overnight-loop.sh` now defaults to local-doc queue mode, not Linear.
- New prompt: `scripts/overnight-local-docs-prompt.md`
- New local queue: `docs/2026-06-17-tonight-session-browser-nav-shell/04-local-implementation-queue.md`
- Default queue starts with browser tickets in current safe order, then optional navigation/terminal queue.
- `T05b` is marked deferred/do-not-implement in the queue.

Root pi observability:
- Existing delegated-agent observability is under `~/.pi/agent-runs`.
- The updated overnight loop writes run-level observability under:
  - `~/.pi/overnight-runs/continuum-revived/run-<timestamp>/status.json`
  - `~/.pi/overnight-runs/continuum-revived/run-<timestamp>/events.jsonl`
  - `~/.pi/overnight-runs/continuum-revived/run-<timestamp>/report.md`
  - `~/.pi/overnight-runs/continuum-revived/run-<timestamp>/logs/`
- Project-local pointer:
  - `.pi/overnight-logs/latest-run.txt`
  - `.pi/overnight-logs/latest` symlink

Important: the loop preflight now refuses dirty trees by default. Current checkout still has untracked setup docs/script artifacts. Before running overnight, commit or stash setup changes, then run e.g.:

```bash
EXPECTED_BRANCH=nightly/browser-nav-shell-loop-2026-06-18 \
PUSH_MODE=local-only \
caffeinate -is ./scripts/overnight-loop.sh
```

The local prompt instructs agents to make one organized commit per completed ticket and not push unless `PUSH_MODE=push` is explicitly set.

## Addendum — API key environment

User clarified that the OpenAI API key is saved in `.env` as `OPENAI_API_KEY`.

`scripts/overnight-loop.sh` now loads only `OPENAI_API_KEY` from `.env` by default if it is not already set, without printing the value. Overrides:
- `ENV_FILE=/path/to/env`
- `LOAD_DOTENV=0`

The script writes only a redacted availability event to `events.jsonl`.
