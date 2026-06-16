# T13 — Reviewer verdict (re-dispatch 2, round 3 review)

**Verdict: CHANGES REQUESTED**

Adversarial, read-only review of the uncommitted T13 changes on `overnight/workspaces-zones`.
Build cached-clean; `--session-resume-check` GREEN; fast matrix GREEN; Core checks GREEN.
12 of 14 assertions are genuinely load-bearing (proven by RED probes). **One confirmed
bypass (A7)** plus two weaker-than-spec assertions (A2 bound, A12) require changes.

## Bypass audit (#1 gate)

Ran the check myself: GREEN. Then ran targeted RED probes against each load-bearing
production path (each reverted after; `grep REVIEWER RED PROBE Sources/` → none;
`git diff --numstat` matches the builder's reported diffstat):

| Probe (production code stubbed) | Result | Verdict |
|---|---|---|
| `restartTerminalTile` cwd-preference → `restoredCwd = profile.cwd` | EXIT 1 | A5 load-bearing ✓ |
| `GhosttyTerminalRuntime.capturedCwd` → `launchProfile.cwd` (bypass OSC 7) | EXIT 1 (step-4 tick timeout) | A1 load-bearing ✓ |
| `WKWebViewBrowserRuntime.restoreInteractionState` → no-op | EXIT 1, `A10 FAIL: canGoBack=false, blobRoundTrip=false` | A10 load-bearing ✓ |
| `capturedInteractionState` → `nil` | EXIT 1, `A8 FAIL: interactionState should be non-nil` | A8 load-bearing ✓ |
| **`flushTerminalSessionSnapshot` gate removed (always persist scrollback)** | **EXIT 0 — STILL PASSES** | **A7 BYPASS ✗** |

**A1/A5 (terminal cwd) — REAL.** Seeds descriptor with launch cwd (`termRoot.path`,
ContinuumApp.swift:9894), drives real `cd sub`, emits real OSC 7 from the shell, ticks until
`runtime.capturedCwd == subDir.path`, calls real `flushTerminalSessionSnapshot`, reloads via
`store.loadSession(id:)`, terminates the old runtime, restarts via real `restartTerminalTile`,
probes the fresh shell's live `pwd`. Reloads through ProjectStore; restores through the real
spawner. Right-reason: A1 expects `<projectRoot>/sub` NOT the seeded `<projectRoot>` — only a
live OSC-7 capture flips it (confirmed by the OSC-7 RED probe).

**A8/A10/A11 (browser) — REAL.** Capture, apply, fresh-WebView identity all load-bearing.
A10 passes via the **blob-round-trip fallback**, not `canGoBack` (which is `false` in the
headless harness even after a real restore — the no-op probe printed `canGoBack=false`).
Spec lines 178-182 sanction this fallback; acceptable but weaker than "history navigable".

## Confirmed defect (CHANGES REQUESTED)

**A7 config-gate is a self-contained bypass.** ContinuumApp.swift:10027-10044 does NOT drive
the production gate. It computes
`gatedScrollback = SessionResumeConfig.scrollbackEnabled(defaults: gateDefaults) ? capturedScrollback : nil`
**inline in the check** and asserts that is nil — re-implementing the production ternary
rather than exercising it. Proof: deleting `guard SessionResumeConfig.scrollbackEnabled()
else { return nil }` from the real `flushTerminalSessionSnapshot` (TileSpawner.swift:351)
leaves the check **GREEN (EXIT 0)**. Violates spec assertion 7 and review-rubric lines
270-272 ("toggling the default off must observably suppress replay **through the real path**").
The builder's build.md lines 142-146 admit this.

Required fix: drive `flushTerminalSessionSnapshot` with the gate actually off and assert the
**reloaded descriptor's** `scrollback == nil`. Production reads `scrollbackEnabled()` from
`.standard`, so either (a) flip `.standard`'s key around a real flush (restore after), or
(b) thread a `defaults:` param into `flushTerminalSessionSnapshot`.

## Scope

- Inline descriptor at TileSpawner.swift:308 replaces the `makeTerminalSessionDescriptor`
  helper call but is behavior-equivalent (`env: [:]`, same `agentDescriptor(for:projectRoot:at:)`,
  `spec.id`, `createdAt: now`) plus the spec-mandated `cwd: restoredCwd` and `scrollback:`
  carry-forward. No adjacent refactor; helper still used by the spawn path (line 180), not
  orphaned. `action_cb` C closure preserved `return false`; only adds the PWD intercept.
- Do-NOT-touch respected: `--terminal-snapshot-tier-check` passes unchanged; T12 autosave
  untouched (flush driven directly per the dependency gotcha); no PID-survival attempt; no
  WorkspaceDocument/ZonePlacement/NSEvent/CanvasEngine edits.
- Configurable-first: `SessionResumeConfig` resolver (default + override) + two SettingsSchema
  fields bound to the exact keys (A13/A14 genuine).
- All `TerminalSessionDescriptor(` / `BrowserTile(` construction sites compile via the
  defaulted memberwise init; no site stubbed with a wrong value.
- Read-only review; no commit, no co-author footer.

## Matrix

`./scripts/run-matrix.sh --fast` → Fast matrix passed (incl. session-resume,
terminal-snapshot-tier, settings-panel, browser-restore-state, browser-profile-persistence,
persistence-crash-safe — all run before the FAST gate at run-matrix.sh:132; only the Xcode
app-bundle build is skipped). `swift run ContinuumRevivedCoreChecks` → passed. NOTE: spec line
252 asks for the full (non-fast) matrix; builder ran only `--fast` (delta = app-bundle build,
irrelevant to persistence logic).

## Risks / weaker-than-spec

- **A2 scrollback bound is non-observable.** Harness terminal is 137x30 → `capturedScrollback`
  ~30 lines; `suffix(2000)` is a no-op and `lineCount <= 2000` trivially true. The bounding
  logic (TileSpawner.swift:353) is never exercised. A2 proves "present + contains con13-line"
  (real) but NOT "bounded". Acceptance criterion "bounded by maxLines… proven via the real
  path" is unmet.
- **A10 proves blob-equality, not navigability** (`canGoBack` false post-restore in headless).
- **A12 asserts on the re-persisted store URL, not `newRuntime.url`** (spec says `newRuntime.url`).
  The interactionState path skips `loadURL` (TileSpawner.swift:676-680), so the check reads
  `store.loadBrowserState()…url` ("Page2") instead — partly redundant with
  `--browser-restore-state-check`.
- **A6 deferred** (spec option c); `replayScrollback` is a documented no-op. Persisted+carried
  scrollback is never displayed.

## Needs human

- Scrollback replay mechanism (spec NEEDS-HUMAN / `flaggedNeedsHuman`): echo-banner vs future
  Ghostty API vs permanent display-only-skip. Until decided, persisted scrollback is dead weight.
- Whether A10's blob-equality (no live `canGoBack`) is an acceptable ceiling for "session, not
  URL, restored," or whether a real-window navigability probe is wanted.
- Whether A12's store-value assertion is acceptable or `newRuntime.url` is required.
