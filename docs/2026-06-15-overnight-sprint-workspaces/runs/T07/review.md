# T07 Review — BrowserRuntimeBudget over the live-zone union

Reviewer: adversarial, read-only. Branch `overnight/workspaces-zones` (uncommitted).

## Verdict: PASS WITH RISKS

The check drives the real production method, the headline cross-zone derivations are
correct and would go RED without the change (I proved it by stubbing the enforcer), and
the fast matrix is green with no regressions. The one material concern — focus-mode
protected tiles are no longer unioned into the eviction-protected set — was explicitly
flagged as a NEEDS-HUMAN by the spec author and documented as deferred by the builder, so
it is a named, sanctioned risk rather than an unspec'd defect.

## 1. BYPASS audit (#1 gate) — PASS

The new multi-zone phase calls the production method `mzRuntime.enforceBrowserRuntimeBudget()`
(ContinuumApp.swift:5486, :5510, :5534) — NOT `budget.evictionCandidates(...)` directly — and
asserts on observable state: `mzControllerA/B.browserRuntimes` counts, `canvasA.tileView(for:)`
view types (`BrowserSnapshotTileNSView` vs `BrowserTileNSView`), and the canvas `Tile.runtimeRef`.

I re-ran the check myself: GREEN, exit 0
(`ContinuumRevivedBrowserLRUBudgetChecks passed`, artifact `mzTotalLive=2`).

I then independently PROVED RED: I temporarily inserted an env-gated `return` at the top of
`WorkspaceRuntime.enforceBrowserRuntimeBudget()`, rebuilt, and ran with the stub active →
`FAIL: mz assertion 1: total live browser runtimes should be 2, got 4`, exit 1. I reverted
the stub (working tree confirmed back to +39/-0 on WorkspaceRuntime.swift, `grep T07_STUB`
returns 0). This confirms assertion 1 is the discriminator and the check is not a bypass:
a stubbed/no-op enforcer leaves 4 live and fails.

Would it pass if the feature were stubbed? NO — proven empirically (got 4, expected 2).

## 2. RIGHT REASON — PASS (hand-derived assertion 6, the "recency is global" proof)

`BrowserRuntimeBudget.evictionCandidates` (Core, unchanged) walks the recency list, skipping
protected ids, popping `overflow = live − maxLive` oldest. Enforcer then `unregister`s each
evicted id.

- 1st enforce: recency `[a1,a2,b1,b2]`, live=4, maxLive=2, overflow=2, protected={b2}.
  Walk → evict a1, a2. unregister(a1),(a2) → recency `[b1,b2]`. A=∅, B=[b1,b2]. ✓ (assert 1,2,4)
- Idempotent: live `[b1,b2]`, overflow=0 → []. ✓ (assert 5)
- assert 6: register a3 → recency `[b1,b2,a3]`, live=3, overflow=1, protected={b2}.
  Walk → b1 evicted. → A=[a3], B=[b2], b1 snapshot on canvasB. ✓ — this only holds for a
  UNION enforcer; a per-zone enforcer would evict within zone A (or leave 4), so the
  assertion is meaningful, not coincidental.

Protected set is genuinely derived, not fabricated: the check sets
`mzCanvasB.markActive(tileId: mzB2)`, and `markActive` (CanvasNSView.swift:349) sets
`canvasState.lastActiveTileId = tileId`; the enforcer's `currentProtectedBrowserTileIds()`
reads `controller.canvasView?.canvasState.lastActiveTileId`. Controller A's canvas keeps
`lastActiveTileId = nil` (seeded nil, never marked), so protected = {b2} exactly. The cap is
driven by the real resolver: the check writes `"2"` to `BrowserRuntimeBudget.defaultsKey` in
`UserDefaults.standard` BEFORE constructing the runtime, whose
`BrowserRuntimeBudget(maxLive: resolveMaxLive())` reads it. Not a hardcoded `maxLive: 2`.

## 3. SCOPE — PASS

- Diff = exactly the 5 files in scope (237 ins / 39 del), matching the build report.
- Orphans removed: AppDelegate `browserRuntimeBudget` field, `registerBrowserRuntimeForBudget`,
  and the body of the old `enforceBrowserRuntimeBudget` are gone. `grep` for
  `registerBrowserRuntimeForBudget` / `self.browserRuntimeBudget` / `private lazy var
  browserRuntimeBudget` returns no matches. `tileSpawner` field still used (31 refs) — not
  orphaned.
- All 6 production call sites repointed to `workspaceRuntime?.…` (1201, 1623, 1673, 2556,
  2724, 2740); the click-recency-touch site repointed to `registerLiveBrowser` (1823 area).
- `browserBudgetSnapshotImage` relaxed `private static func` → `static func`; body byte-identical
  (verified against HEAD). The single permitted visibility delta — respected.
- Configurable-first wired end-to-end: `SettingsSchema` `.text` field binds
  `BrowserRuntimeBudget.defaultsKey` ("continuum.browserLiveBudget"), default
  `String(defaultMaxLive)` = "6"; added to `expectedKeys` in CoreChecks (conflict-guard =
  existing unique-keys assertion now covers it). No new default invented.
- Do-NOT-touch list respected: LRU primitives in BrowserRuntimeBudget.swift unchanged; no PTY
  budget; no T10 viewport wiring; no edits to registry ref-count semantics (only a read-only
  `liveControllers` accessor added, which the spec explicitly permits — "add a minimal
  read-only one and note it").
- Uncommitted; no commit/co-author footer to check (memory rule: none must be added when committed).

## 4. MATRIX — PASS

`./scripts/run-matrix.sh --fast` → "Fast matrix passed." I confirmed the relevant checks ran
and passed: `ContinuumRevivedCoreChecks`, `--zone-hydration-lifecycle-check`,
`--zone-save-isolation-check`, `--zone-registry-refcount-check`,
`--workspace-runtime-install-check`, `--add-zone-check`, `--browser-lru-budget-check`. No
regression.

## 5. Domain / edge-case probes

- Union (not loop-over-zones): enforcer flat-maps ALL `liveControllers` into ONE
  `evictionCandidates` call (WorkspaceRuntime.swift:262-264). Confirmed.
- Routing correctness: assertion 3 inspects `canvasA.tileView(for: a1/a2)` specifically AND
  asserts b-tiles on canvasB untouched. Confirmed (not a global blob).
- Shared-project dedupe: registry is one Box per projectId; `liveControllers` =
  `boxes.values.map(\.controller)` — one controller per projectId, so the union counts a
  shared project's browsers once. No double-enumeration. Confirmed.

## Confirmed defects

None.

## Risks (named — committable)

- **R1 (production behavior change — focus-mode protection dropped).** The deleted single-zone
  enforcer unioned `focusModeSession.protectedTileIds` (primary + companion tiles) into the
  protected set. The new `WorkspaceRuntime.currentProtectedBrowserTileIds()`
  (WorkspaceRuntime.swift:249-257) only reads each controller's `canvasState.lastActiveTileId`
  and does NOT union the focus-mode set (`focusModeSession` lives on AppDelegate, line ~8300,
  unreachable from WorkspaceRuntime). Concretely: the focus-mode entry path calls
  `workspaceRuntime?.enforceBrowserRuntimeBudget()` (ContinuumApp.swift:2556); if the
  focus-mode companion browser (or a primary that is not the active `lastActiveTileId`) is the
  globally-oldest, it can now be evicted to a snapshot while the user is viewing it in focus
  mode. The single-zone check phase has no assertion covering focus-mode protection, so this
  is unguarded. Spec explicitly flagged this as NEEDS-HUMAN gotcha #2 and the builder
  documented deferring it — sanctioned, but it is a real regression that needs a fix once
  focusModeSession ownership is resolved (closure/accessor into WorkspaceRuntime).
- **R2 (cross-zone eviction only partially exercisable until T08).** In production today only
  the ACTIVE controller gets `attachUI` (so only it has a non-nil `tileSpawner`); the
  enforcer's eviction loop skips any controller with `tileSpawner == nil`
  (WorkspaceRuntime.swift:268 `guard … else { continue }`). So a non-active live zone's
  oldest browser would currently be selected by `evictionCandidates` but NOT actually
  snapshotted/removed — it would be silently skipped, leaving the live count above budget. The
  check sidesteps this by calling `attachUI` on BOTH controllers, so the mechanism is proven,
  but the production guarantee "live count never exceeds maxLive across all zones" only holds
  once T08 attaches UI to all live controllers. This is forward-integration risk, not a T07
  scope defect.

## Unverified

- I did not run the full (non-fast) matrix or the GUI/smoke paths; focus-mode eviction
  behavior (R1) is reasoned from source, not executed.
- I trust `swift build` over SourceKit; the build was green (cached + a clean relink during
  my stub experiment).

## Needs human (Dylan)

- **Decide focusModeSession ownership / protection wiring (R1).** Either move/forward
  `focusModeSession.protectedTileIds` into `WorkspaceRuntime`'s protected-set derivation, or
  accept that focus-mode browsers rely solely on being `lastActiveTileId`. Today it is a
  silent behavior regression with no check coverage.
- **Confirm R2 is acceptable for the shell phase** (cross-zone eviction is structurally
  correct but only fully effective once T08 attaches UI to all live controllers).
