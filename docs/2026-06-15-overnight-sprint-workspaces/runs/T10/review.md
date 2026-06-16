# T10 Review — Viewport-driven tier transitions

**Reviewer:** strong model (adversarial, read-only)
**Branch:** overnight/workspaces-zones
**Verdict:** PASS WITH RISKS

---

## Summary

T10 implements debounced `reconcileHydration` on viewport change, applying the T03 pure
planner to the live N-controller runtime via `setTier`, layering the T07 budget, and wiring
the production `canvasDidChange` viewport-delta gate to `onViewportChanged()`. The check drives
the real production entry (`onViewportChanged()` + `flushPendingHydrationReconcile()`), asserts
observable runtime/canvas teardown state (not just tier enums), and re-derives the expected
tiers against `CanvasEngine.hydrationTier`. Build clean, all 10 assertions + T09 carry-forward
pass, fast matrix green, all 4 neighbor checks green. RED reproduced.

I independently re-ran everything below; results are first-hand, not taken from the build report.

---

## 1. BYPASS audit (#1 gate) — PASS (with one weak sub-assertion)

The check drives the REAL path: `freshRuntime.onViewportChanged()` then
`flushPendingHydrationReconcile()` (ContinuumApp.swift:6194-6195, 6251-6252, 6292-6293, etc.),
NOT `setTier`/`reconcileHydration`/`orchestrator.plan` directly. Assertions read observable
state: `controller.browserRuntimes.count`, `tile.runtimeRef`, and the installed view class
(`BrowserSnapshotTileNSView`/`BrowserTileNSView`), e.g. ContinuumApp.swift:6265-6277 (assertion
3) and 6303-6311 (assertion 4) — not a tier string.

**Re-ran RED myself.** Stubbed `reconcileHydration` to `{ reconcileCount += 1; return }`
(no-op) → check FAILS at `assertion 1: Pb tier after initial reconcile at (0,0,1) should be
cold, got live`. So it genuinely goes RED without the feature. GREEN restored after revert.

**Bypass verdict: would NOT pass if the feature were stubbed.** Confirmed by direct experiment.

**Weakness (RISK, not a defect):** Assertion 9's *coalescing* sub-claim is not independently
proven. I replaced `onViewportChanged()` with a synchronous `reconcileHydration()` call (NO
debounce at all) and rebuilt: **assertion 9 still passed** — the run failed later at assertion
10 (delta=2). Reason: in the headless check the 200ms `Timer` never fires (no run-loop spin
between calls), so `reconcileCount` only moves on the explicit `flush`; the `+1` delta holds
whether or not the timer coalesces. The no-debounce regression is caught *incidentally* by
assertion 10 (double-increment), not by assertion 9. The debounce/coalescing guarantee itself
is therefore asserted only indirectly. The resolver round-trip sub-asserts (default 200,
override "50"→50) ARE real and pass.

---

## 2. RIGHT REASON — PASS (hand-derived, non-coincidental)

Re-derived the fixture geometry by hand against `CanvasEngine.hydrationTier`
(CanvasEngine.swift:131-162, margin 256):

- **Assertion 1, B → cold @ (0,0,1):** B world x∈[2000,2400]; visible x∈[0,1000]; not
  intersecting; snapshot band x∈[-256,1256]; 2000 > 1256 → **cold**. ✓
- **Assertion 2, A → cold @ (2000,0,1):** A world x∈[0,400]; visible x∈[2000,3000]; not
  intersecting; band x∈[1744,3256]; 400 < 1744 → **cold**. ✓
- **Assertion 7 budget @ zoom 0.4:** visible world width 1000/0.4=2500, x∈[0,2500]; A
  [0,400] and B [2000,2400] both intersect → both live-eligible; budget 1, A focused/protected
  → B evicted. ✓

Tiers differ across zones/viewports (live vs cold), so a coincidental all-Live pass is
excluded. The asserted values match the planner intent.

---

## 3. SCOPE — PASS WITH ONE ORPHAN

Diff is exactly the 5 spec files + the new Core config (919 insertions). Verified untouched:
`ZoneHydrationOrchestrator.swift`, `CanvasEngine.swift`, `ZoneRuntimeController.swift`
(setTier internals), `Canvas/CanvasNSView.swift` (gesture math) — none appear in
`git diff --name-only`. `WorkspaceRuntime` diff is a single additive hunk at :552, after
`enforceBrowserRuntimeBudget`; `switchWorkspace` (390-507) untouched. Production
`canvasDidChange` change is surgical (preserves `scheduleCanvasSave()`, adds delta gate). No
co-author/Generated footer in the T10 docs.

Config wiring complete: `ZoneHydrationReconcileConfig` resolver (new file) + `SettingsSchema`
`.text` field in `general` section (SettingsSchema.swift:85-89) + conflict-guard `expectedKeys`
(main.swift:4247) + Core resolver round-trip (main.swift:4262-4270). Debounce interval is read
from `ZoneHydrationReconcileConfig.intervalMs()` (WorkspaceRuntime.swift:566), not hardcoded.

**ORPHAN (defect, minor):** `WorkspaceRuntime.lastReconciledViewport` (WorkspaceRuntime.swift:558)
is declared but never read or written. The functional viewport-delta gate lives in
`AppDelegate.canvasDidChange` with its own `lastReconciledViewport` (ContinuumApp.swift:3239).
The WorkspaceRuntime copy is dead code introduced by this change. Swift does not warn on unused
stored properties so it compiles silently. Per the repo's "remove orphans your change created"
rule it should be deleted. Non-blocking.

---

## 4. MATRIX — PASS

- `swift build` → clean (only pre-existing ghostty `_ImFont/_ImGui` link warnings).
- `swift run ContinuumRevivedCoreChecks` → `ContinuumRevivedCoreChecks passed`.
- `--zone-tier-transition-check` → passed (manifest written).
- `./scripts/run-matrix.sh --fast` → **Fast matrix passed.**
- Neighbors: `--zone-hydration-lifecycle-check`, `--browser-lru-budget-check`,
  `--zone-save-isolation-check`, `--focus-broker-activation-check` → all passed.

---

## 5. Domain / edge-case probes

- **Demote/promote real teardown (3/4):** asserts `browserRuntimes` count, `runtimeRef==nil`,
  and view class — passes the rubric's "not a tier string" bar.
- **Budget over the union (7):** `enforceBrowserRuntimeBudget` flat-maps `liveControllers`'
  browsers (WorkspaceRuntime.swift:537-538) → union, not per-controller; focused A protected,
  B evicted. Correct.
- **Focused-zone guard (8):** Passes via `setTier`'s `dehydrate` guard reading the *zone*
  canvas `lastActiveTileId` (ZoneRuntimeController.swift:160-161), throwing, swallowed by
  `try?` in reconcile (WorkspaceRuntime.swift:615) → A stays live. NOTE: in the check the
  planner's `focusedTileZone` is nil (the workspace-canvas `lastActiveTileId` is unset; only
  the zone canvas was `markActive`'d), so the planner does NOT pin A — only the guard saves it.
  Spec explicitly allows "either the planner pins it OR setTier's guard rejects." Acceptable,
  but see RISK on production focus derivation.
- **Idempotence (10):** asserts runtime-id stability. RISK: `setTier` has its own internal
  `guard targetTier != hydrationTier` (ZoneRuntimeController.swift:142), so even if reconcile's
  own short-circuit (WorkspaceRuntime.swift:614) were removed, runtime ids stay stable →
  assertion 10 cannot distinguish "reconcile skips setTier" from "setTier skips internally."
  The observable no-flicker invariant holds regardless; the assertion's discriminating power is
  weaker than the spec implies.

---

## Findings (actionable, non-blocking)

1. Remove the dead `WorkspaceRuntime.lastReconciledViewport` (WorkspaceRuntime.swift:558) — an
   orphan this change created; the real gate is in AppDelegate.

## Risks

- Assertion 9 does not actually prove debounce *coalescing* in the headless check (timer never
  fires without a run loop; the `+1` delta is flush-driven and holds with or without debounce).
  The no-debounce regression is caught only incidentally by assertion 10. The debounce timer
  IS correctly implemented for production (`Timer.scheduledTimer` on the run loop), but the
  check's coalescing guarantee is under-verified.
- Assertion 10's idempotence is masked by `setTier`'s own internal short-circuit, so it does
  not independently verify the reconcile-level `planned==current` skip.
- Production `focusedTileZone` derivation (WorkspaceRuntime.swift:595-602) reads the *workspace*
  canvas `lastActiveTileId` and maps to a zone via each controller's canvas tiles. The check
  exercises the `setTier` guard path instead (zone-canvas active), so the planner-pin branch of
  the focused-zone behavior is NOT exercised by any assertion. Whether the planner correctly
  pins the focused zone in production is unverified by this check.
- Debounce timer fires on the run loop via a detached `Task { @MainActor }` (WorkspaceRuntime.
  swift:572-573); production reconcile-on-real-pan is not exercised by any automated check
  (only the synchronous flush path is). Real pan/zoom-driven reconcile is unverified end-to-end.

## Unverified

- Real interactive pan/zoom in the running app triggering reconcile (no UI check; only the
  synchronous self-check path was run). Needs a human/manual confirmation if real-feel matters.
- Group zones (`projectId == nil`) skip is correct per spec but not asserted here.

## Needs human

- Confirm the debounce coalescing guarantee is acceptable as currently (under-)verified, or ask
  the builder to strengthen assertion 9 (e.g. assert reconcileCount==0 immediately after the
  burst before flush, and/or use intervalKey=0 synchronous path to prove the burst would
  otherwise multi-fire). Design call.
- Confirm it's acceptable that the planner's `focusedTileZone` pin branch is exercised only in
  production, not by an assertion (the check covers the setTier-guard branch only).
