# T10 — Viewport-driven tier transitions (docs/23 S8)

Status: todo
Tag: overnight
Depends on: T06 (WorkspaceRuntime shell + registry + orchestrator wired) · Blocks: —

Keystone stage: docs/23 **S8** — "Viewport-driven tier transitions (debounced
`reconcileHydration` on pan/zoom)". This task is the **application of the T03 pure planner
to the live N-controller runtime** when the viewport moves: a zone that pans off-screen
demotes Live → Snapshot; a zone that pans back into view promotes Snapshot → Live; all
respecting the T07 browser budget and each zone's `hydrationPolicy`.

> NEEDS-HUMAN coupling (see "Out of scope / gotchas"): the symbols this task drives —
> `WorkspaceRuntime`, `ZoneRuntimeRegistry`, `ZoneHydrationOrchestrator` — are **planned**
> (docs/23 "Target architecture") and are created by T03/T04/T06; they do **not** exist in
> `Sources/` yet. This spec is written against their planned shape and the exemplar T09's
> usage of them. The implementing agent MUST reconcile the exact method names/signatures
> with T06 as landed before writing the check, and re-confirm the RED→GREEN boundary.

## Goal
Panning or zooming the canvas so a project zone leaves the visible rect should let its
runtime **demote to a cheaper tier** (Live → Snapshot for browsers, per docs/23 D3/D4),
and panning it back into view should **re-promote it to Live** — automatically, debounced,
with no relaunch and no manual hydrate. This is what makes a large multi-zone workspace
stay responsive: only on-screen (plus a margin band) work is live. CON-51 (zone hydration
gate) lands here.

## ⚠ ORCHESTRATOR CARRY-FORWARD (added mid-sprint from the T09 review — IN SCOPE for T10)
T09's `switchWorkspace` acquire loop tier-filters to `.live`, which the T09 reviewer found can LEAK ref-counts: a target project whose zone is budget-demoted to a non-live tier falls in neither `departing` nor `newlyAcquired`, so it drops from `acquiredProjectIds` while its registry refCount stays > 0 — never released by a later switch/teardown. Since T10 OWNS tier transitions (promote/demote), T10 MUST keep registry ref-count bookkeeping correct across demote: a demoted (Snapshot/Cold) controller must remain tracked + releasable (refCount reflects that the workspace still holds it), and re-promotion must not double-acquire. Add a check assertion: demote a zone via a viewport change so it's non-live, then tear down the workspace (closeAll) and assert the demoted project's controller is released exactly once (refCount → 0), not leaked. (Note: like T07–T09, T10's live behavior is gated on T20 wiring the boot registry factory; the check injects a real registry.)

## Exact scope — files & symbols
- **`Sources/ContinuumRevived/App/WorkspaceRuntime.swift`** (created in T06) — add the
  public entry point `onViewportChanged()` and its debounced internal
  `reconcileHydration()`:
  - `onViewportChanged()` — called when the canvas viewport changes (pan/zoom). Schedules
    a debounced `reconcileHydration()` (interval from the new config below). Exposes a
    `flushPendingHydrationReconcile()` (or equivalent synchronous drain) so checks/tests
    are deterministic — model it on the existing `flushCanvasSave()` pattern.
  - `reconcileHydration()` — the apply step. Builds the orchestrator inputs from the live
    state (current `WorkspaceDocument.zones`, `canvasView.viewport`, `canvasView.bounds.size`
    as `visibleSize`, the focused zone id, the budget), calls the **T03 pure planner**
    (`ZoneHydrationOrchestrator.plan(...)` → `[zoneId: HydrationTier]`), then for each zone
    whose planned tier differs from its controller's current `hydrationTier`, applies it by
    calling that controller's existing `ZoneRuntimeController.setTier(_:)` via the
    **`ZoneRuntimeRegistry`** (look up the controller for the zone's `projectId`). Group
    zones (`projectId == nil`) have no project controller — skip them in v1 (their ambient
    controller is T08; tiering ambient zones is out of scope here).
- **`Sources/ContinuumRevived/App/ContinuumApp.swift`** — wire the production viewport-change
  path to `workspaceRuntime.onViewportChanged()`. The viewport changes flow through
  `CanvasNSView.setViewport(_:)` → `delegate?.canvasDidChange(self)` (CanvasNSView.swift:451)
  and the trackpad/scroll entry points `scrollWheel` / `handlePinch` (CanvasNSView.swift:762,
  789). Hook `onViewportChanged()` off the **viewport-changed branch** of the existing
  `canvasDidChange` delegate handler (the AppDelegate already routes `canvasDidChange`).
  Do NOT add a new gesture; reuse the existing pan/zoom plumbing. If `canvasDidChange`
  cannot distinguish a viewport change from a tile change cheaply, gate the reconcile call
  on a viewport-delta compare against a stored `lastReconciledViewport` (cheap, no new
  gesture surface).
- **`Sources/ContinuumRevivedCore/ZoneHydrationReconcileConfig.swift`** (NEW, ~25 lines) —
  the debounce-interval resolver, mirroring `DragMagnetizeConfig` / `TileGapResolver`
  exactly (see "Data / API changes").
- **`Sources/ContinuumRevivedCore/SettingsSchema.swift`** — append ONE `.text` field for
  the new debounce key to the `navigation` (or `general`) section; add its key to the
  `expectedKeys` set in the Core settings-schema conflict guard (next bullet).
- **`Sources/ContinuumRevivedCoreChecks/main.swift`** — extend the existing settings-schema
  conflict guard (`SettingsSchema.sections()` block, ~:3934) `expectedKeys` set with
  `ZoneHydrationReconcileConfig.intervalKey`, and add a 2-line resolver round-trip
  (default-on-empty + reads-override) next to the `DragMagnetizeConfig` block (~:3963).
- **`scripts/run-matrix.sh`** — register `--zone-tier-transition-check` (append a
  `run_app_check` line after `--zone-hydration-lifecycle-check`, :106).
- **`Sources/ContinuumRevived/App/ContinuumApp.swift`** (arg dispatch ~:75–590) — add the
  `if CommandLine.arguments.contains("--zone-tier-transition-check") { … }` block,
  modeled on the `--zone-save-isolation-check` / `--browser-lru-budget-check` blocks.
- **Do NOT touch:**
  - The **T03 pure planner** itself (`ZoneHydrationOrchestrator`) — reuse it as-is; this
    task only *applies* it. If the planner is missing a needed input, that is a T03 gap —
    flag it, do not extend the planner here.
  - **`switchWorkspace`** (T09) — the post-switch tier set is T09's job; T10 is the
    *ongoing* pan/zoom reconcile on an already-live workspace.
  - **Pan/zoom gesture handling** (`scrollWheel`, `handlePinch`, space-drag in
    `CanvasNSView`) — reuse; do not modify the gesture math.
  - `CanvasEngine.hydrationTier` / `CanvasEngine.zoom` / any coordinate transform.
  - The 4 window-scoped NSEvent monitors (ADR-0024), FocusBroker, the budget *math*
    (`BrowserRuntimeBudget` Core — reused, not edited).
  - `ZoneRuntimeController.setTier` internals (reused exactly; do not change its
    focused-zone guard or its signature).

## Data / API changes
New config resolver (copy-pasteable shape, mirrors `DragMagnetizeConfig`):
```swift
// Sources/ContinuumRevivedCore/ZoneHydrationReconcileConfig.swift
import Foundation

/// Debounce interval (ms) between a viewport change settling and the
/// WorkspaceRuntime re-planning + applying zone hydration tiers. Coalesces a
/// flick/pinch burst into one reconcile. Mirrors TileGapResolver's resolve shape.
public enum ZoneHydrationReconcileConfig {
    public static let intervalKey = "continuum.zoneHydration.reconcileDebounceMs"
    public static let defaultIntervalMs = 200
    public static let minIntervalMs = 0
    public static let maxIntervalMs = 2000

    /// Reads the interval in ms; clamps to [min,max]; falls back to the default
    /// for absent/non-numeric/out-of-range values.
    public static func intervalMs(defaults: UserDefaults = .standard) -> Int {
        guard let raw = defaults.object(forKey: intervalKey) else { return defaultIntervalMs }
        let value: Int?
        if let i = raw as? Int { value = i }
        else if let s = raw as? String, let i = Int(s) { value = i }
        else { value = nil }
        guard let v = value, v >= minIntervalMs, v <= maxIntervalMs else { return defaultIntervalMs }
        return v
    }
}
```
SettingsSchema (one new `.text` field, in the `navigation` section):
```swift
.text(
    key: ZoneHydrationReconcileConfig.intervalKey,
    label: "Zone Hydration Debounce (ms)",
    default: String(ZoneHydrationReconcileConfig.defaultIntervalMs)
),
```
WorkspaceRuntime (planned shape — confirm against T06 as landed):
```swift
func onViewportChanged()                 // production entry; schedules debounced reconcile
func reconcileHydration()                // re-plan + apply tiers across the registry
func flushPendingHydrationReconcile()    // synchronous drain for checks (like flushCanvasSave)
```
No change to `HydrationTier`, `ZoneHydrationPolicy`, `ZonePlacement`, `BrowserRuntimeBudget`,
`ZoneRuntimeController.setTier`, or `CanvasEngine`. No new public Core types beyond the
config resolver. The orchestrator output is consumed, not redefined.

## The check, written FIRST (spec-as-test) — `--zone-tier-transition-check`
Static func on `AppDelegate` in `ContinuumApp.swift` (so it reaches `private`
`workspaceRuntime` + `ZoneRuntimeRegistry` internals), registered in `scripts/run-matrix.sh`
and the arg dispatch. Modeled structurally on `runBrowserLRUBudgetSelfCheck` /
`runHydrationLifecycleSelfCheck` (real `ProjectStore` + `CanvasState` fixtures, real
controllers attached, drive a production method, assert observable state).

**Fixture (hand-derivable geometry).** A `1000×1000` visible canvas (`visibleSize`,
`zoom = 1`, so 1 world unit = 1 screen px). Two project zones, both
`hydrationPolicy == .automatic`, each holding one browser tile (use a `data:` URL like the
existing lifecycle/budget checks so no network):
- Zone **A** (project Pa): `origin (0,0)`, `size 400×400` → world frame `[0,400]×[0,400]`.
- Zone **B** (project Pb): `origin (2000,0)`, `size 400×400` → world frame `[2000,2400]×[0,400]`.

Snapshot margin = the default `CanvasEngine.defaultHydrationSnapshotMargin` (256). Build a
`WorkspaceRuntime` over these two zones via the registry (acquire Pa, Pb), attach the
canvas, and seed both browsers live (`spawner.restartBrowserTile` + `controller.setTier(.live)`
as the budget check does). Initial viewport `(0,0,1)`:
- A intersects `[0,1000]×[0,1000]` → **Live**.
- B is at x∈[2000,2400], visible band x∈[0,1000], snapshot band (margin 256) x∈[-256,1256]
  → B does **not** touch the snapshot band → **Cold** initially is the planner's call;
  but since both were seeded Live, do an **initial reconcile** and assert the planner pulls
  B down. (If T03 cold-on-distant differs, assert B's planned tier == `CanvasEngine.hydrationTier(zone: B, …)` re-derived — see assertion 1.)

Then drive **the real path**: pan so B enters and A leaves view. Pan to viewport
`(2000,0,1)` via `canvasView.setViewport(CanvasViewport(x: 2000, y: 0, zoom: 1))` (the
production pan write), then `workspaceRuntime.onViewportChanged()` + `flushPendingHydrationReconcile()`.
At `(2000,0,1)`: visible band x∈[2000,3000] → B Live; A at x∈[0,400], snapshot band
x∈[1744,3256] → A not in band → A demotes (toward Cold/Snapshot per planner). Then pan
**back** to `(0,0,1)` and reconcile again.

**Assertions (every one hand-derivable):**
1. **Initial reconcile matches the planner, not a guess.** After the first
   `onViewportChanged()`+flush at `(0,0,1)`: `registry.controller(for: Pa).hydrationTier`
   equals `CanvasEngine.hydrationTier(zone: A, viewport: (0,0,1), visibleSize: 1000×1000,
   focusedTileZone: nil)` (== `.live`), and `registry.controller(for: Pb).hydrationTier`
   equals the same call for B (B at x≥2000, band ≤1256 → `.cold`). Re-derive both by hand
   and assert against the controller's *observed* tier — proves the runtime applied the
   plan, and proves it agrees with the pure tier function.
2. **Demote on pan-away (real observable).** After panning to `(2000,0,1)` + reconcile:
   `controller(for: Pa).hydrationTier != .live` (A left the band → demoted). Assert it
   equals the re-derived `CanvasEngine.hydrationTier(zone: A, viewport: (2000,0,1), …)`.
3. **Demote tears down the live browser runtime (not just a flag).** After step-2 demote of
   A: `controller(for: Pa).browserRuntimes.isEmpty == true`, the A browser tile's
   `runtimeRef == nil` in `canvas.canvasState`, and a `BrowserSnapshotTileNSView` is
   installed for it (`canvas.tileView(for: aBrowserTileId) is BrowserSnapshotTileNSView`).
   This is the same observable surface the lifecycle check asserts — proves the apply went
   through the real `setTier`/`dehydrate` path, not a tier-string write.
4. **Promote on pan-back (real observable).** After panning to `(2000,0,1)` then back to
   `(0,0,1)` + reconcile: `controller(for: Pa).hydrationTier == .live`,
   `controller(for: Pa).browserRuntimes.count == 1`, the A browser tile's `runtimeRef?.kind
   == .browserTile`, and `canvas.tileView(for: aBrowserTileId) is BrowserTileNSView`.
   Proves the round-trip re-hydrates, symmetric to assertion 3.
5. **Symmetric B.** At `(2000,0,1)`: `controller(for: Pb).hydrationTier == .live` and
   `controller(for: Pb).browserRuntimes.count == 1` (B came into view). Proves the
   transition is per-zone, not global.
6. **`pinnedLive` respected.** Re-run a minimal variant with zone B's
   `hydrationPolicy == .pinnedLive`: pan A into view and B fully off-screen → after
   reconcile `controller(for: Pb).hydrationTier == .live` (never demoted) while A behaves as
   in assertions 1–5. Proves the apply consults the per-zone policy via the planner
   (`CanvasEngine.hydrationTier` short-circuits `.pinnedLive` to `.live`).
7. **Budget respected (T07).** With a `BrowserRuntimeBudget(maxLive: 1)` on the runtime and
   both A and B in a viewport that makes both Live-eligible (e.g. zoom out to `(0,0, 0.4)`
   so visible band covers both world frames), after reconcile **at most 1** browser runtime
   is live across the union (`controller(for: Pa).browserRuntimes.count +
   controller(for: Pb).browserRuntimes.count == 1`), and the **focused** zone's browser is
   the surviving one (mark one tile active via `canvas.markActive`; assert that zone's
   controller kept its runtime). Proves the apply layers the LRU budget over the plan, not
   just the geometric tier.
8. **Focused zone never demoted.** Mark the A browser tile active
   (`canvas.markActive(tileId: aBrowserTileId)`), then pan A off-screen + reconcile.
   `controller(for: Pa).hydrationTier == .live` (the focused-zone guard in `setTier` blocks
   the demote, OR the planner pins the focused zone via `focusedTileZone`). Assert the
   focused browser runtime is intact. Proves reconcile honors the existing focused-zone
   invariant (no surprise teardown of the tile the user is in).
9. **Debounce coalesces (config-driven, real).** With
   `ZoneHydrationReconcileConfig.intervalKey` set to a measurable value in an isolated
   `UserDefaults` suite, call `onViewportChanged()` 3× in a tight burst WITHOUT flushing,
   then flush once. Assert `reconcileHydration` ran a bounded number of times (instrument a
   private counter, e.g. `reconcileCount`, exposed for the check) — `reconcileCount == 1`
   after the burst+flush (the burst coalesced). Then assert the resolver itself:
   `ZoneHydrationReconcileConfig.intervalMs(defaults: emptySuite) == 200` (default) and a
   `set("50")` override reads back `50`. Proves the debounce exists, is config-driven, and
   is not hardcoded.
10. **No reconcile churn when the viewport doesn't move.** Call `onViewportChanged()` +
    flush twice at the SAME viewport with no controller change in between → no tier
    transitions on the second pass (`reconcileCount` increments by the expected amount but
    no `setTier` is invoked when planned == current — assert via an unchanged
    `browserRuntimes` identity / a `setTierCallCount` spy on the registry == 0 on the
    no-op pass). Proves idempotence (no flicker from redundant re-hydrates).

Write a manifest JSON artifact (like the lifecycle/budget checks) recording every observed
tier, runtime count, `reconcileCount`, and the re-derived expected tiers, to
`qa-runs/<ts>/zone-tier-transition/manifest.json`.

**RED:** with no `onViewportChanged`/`reconcileHydration` (or T06's runtime stubbed),
assertions 2/4 fail on the assertion (A never demotes / never re-promotes), not on a
compile error once the stubs exist. Implement to GREEN.

## Implementation steps
1. **(RED)** Write `runZoneTierTransitionSelfCheck()` with all 10 assertions on `AppDelegate`;
   add minimal compiling stubs for `onViewportChanged`/`reconcileHydration`/
   `flushPendingHydrationReconcile`/`reconcileCount` on `WorkspaceRuntime` (no behavior).
   Register the arg-dispatch block + the `run-matrix.sh` line. Build + run the single check
   → confirm it FAILS on assertion 2 (demote) or 4 (promote), not a compile error.
2. Add `ZoneHydrationReconcileConfig` (Core) + its `SettingsSchema` `.text` field + extend
   the Core conflict-guard `expectedKeys` and add the resolver round-trip. Run
   `swift run ContinuumRevivedCoreChecks` → green (config wired before behavior).
3. Implement `reconcileHydration()`: gather `(zones, viewport, visibleSize, focusedZone,
   budget)` from live state → call the T03 planner → diff planned-vs-current per zone →
   for project zones, look up the controller via `registry` and call `setTier(plannedTier,
   allowDehydratingFocusedZone: false)`; skip when planned == current (assertion 10);
   layer the budget eviction over the Live set exactly as `runBrowserLRUBudgetSelfCheck`
   does via `onBrowserRuntimeHydrated` (assertion 7). Skip group zones (`projectId == nil`).
4. Implement `onViewportChanged()` debounce: a `Timer`/`DispatchWorkItem` scheduled at
   `ZoneHydrationReconcileConfig.intervalMs(...)`, coalescing bursts; `flushPendingHydrationReconcile()`
   cancels the timer and runs `reconcileHydration()` synchronously; bump `reconcileCount`
   in `reconcileHydration`.
5. Wire `ContinuumApp` `canvasDidChange` viewport-changed branch (or a viewport-delta gate
   against `lastReconciledViewport`) to call `workspaceRuntime.onViewportChanged()`.
6. **(GREEN)** `swift build` → run `--zone-tier-transition-check` → all 10 assertions pass.
7. `./scripts/run-matrix.sh --fast`; then also run the neighbors this could regress:
   `--zone-hydration-lifecycle-check`, `--browser-lru-budget-check`,
   `--zone-save-isolation-check`, `--focus-broker-activation-check`.
8. Self-review against Acceptance + Review rubric; commit
   `feat(zones): viewport-driven tier transitions (reconcile on pan/zoom)`.

## Acceptance criteria
- [ ] `--zone-tier-transition-check` drives `workspaceRuntime.onViewportChanged()` (the REAL
      pan/zoom-triggered entry), NOT `setTier`/`reconcileHydration`/the planner directly.
- [ ] All 10 assertions pass; demote (2/3) and promote (4) assert observable runtime+canvas
      state (controller `hydrationTier`, `browserRuntimes` count, tile `runtimeRef`,
      `BrowserSnapshotTileNSView`/`BrowserTileNSView` installed), re-derived against
      `CanvasEngine.hydrationTier`.
- [ ] `pinnedLive` (6), budget cap (7), focused-zone guard (8), debounce coalescing (9),
      and idempotence (10) all asserted.
- [ ] New debounce config: resolver + persisted UserDefaults default (200ms) +
      `SettingsSchema` `.text` entry + conflict-guard `expectedKeys` coverage + resolver
      round-trip in Core checks. Nothing hardcoded.
- [ ] T03 planner untouched; `switchWorkspace` untouched; gesture math untouched.
- [ ] Fast matrix green; neighbor checks (hydration-lifecycle, lru-budget, save-isolation,
      focus-broker) green.

## Verification commands
```
swift build
swift run ContinuumRevivedCoreChecks
P=$(mktemp -d); A=$(mktemp -d); CONTINUUM_PROJECT_ROOT=$P CONTINUUM_APP_SUPPORT=$A \
  .build/debug/continuum-revived --zone-tier-transition-check; rm -rf "$P" "$A"
./scripts/run-matrix.sh --fast
# regression neighbors:
.build/debug/continuum-revived --zone-hydration-lifecycle-check
.build/debug/continuum-revived --browser-lru-budget-check
.build/debug/continuum-revived --zone-save-isolation-check
.build/debug/continuum-revived --focus-broker-activation-check
```

## Review rubric (adversarial)
- **Bypass audit (critical).** The check must call `workspaceRuntime.onViewportChanged()`
  (what the production `canvasDidChange`/pan/zoom path calls), then flush — NOT
  `controller.setTier`, NOT `reconcileHydration` directly, NOT `orchestrator.plan` in
  isolation. If it pokes `setTier` or asserts only the planner's pure output, it is the
  banned "executor bypass" — REWORK. Ask: would it still pass if `reconcileHydration` were
  a no-op? (It must go RED — assertions 2/4.)
- **Demote/promote assert real teardown, not a tier string.** Assertion 3/4 must check
  `browserRuntimes` count + `runtimeRef` + the installed snapshot/live view class, not just
  `controller.hydrationTier == .snapshot`. A check that only reads the tier enum could pass
  with the runtime leaked live. REWORK if so.
- **Re-derived expectation.** Assertions 1/2 must compare the observed tier to a hand-run
  `CanvasEngine.hydrationTier(...)` with the exact fixture geometry — confirm the geometry
  (origins, sizes, margin 256, zoom) produces the asserted Live/Cold by hand. A coincidental
  pass (e.g. everything happens to be Live) is a FAIL.
- **Budget over the union (7).** Confirm the cap is applied across **both** zones' browsers
  (the union), not per-controller — that is the whole point of S5/T07. The surviving live
  browser must be the focused one (LRU + protected), matching `BrowserRuntimeBudget`
  semantics. REWORK if the cap is enforced per-zone.
- **Focused-zone guard (8).** Confirm panning the focused zone off-screen does NOT tear down
  its runtime — either the planner pins it (`focusedTileZone`) or `setTier`'s guard rejects
  the demote. If the focused browser dies on pan-away, that's a real-feel regression.
- **Debounce is config-driven (9).** Confirm the interval comes from
  `ZoneHydrationReconcileConfig.intervalMs(...)`, has a Settings entry + conflict-guard, and
  is not a literal `200` in `WorkspaceRuntime`. REWORK a hardcoded interval.
- **Idempotence (10).** A no-op viewport reconcile must not re-hydrate (no flicker). Confirm
  the `planned == current` short-circuit skips `setTier`.
- **Scope.** Diff: every line traces to T10; T03 planner, `switchWorkspace`, gesture math,
  `setTier` internals untouched; orphans removed; no co-author footer.

## Out of scope / gotchas
- **NEEDS-HUMAN — dependency-shape coupling.** `WorkspaceRuntime`, `ZoneRuntimeRegistry`,
  and `ZoneHydrationOrchestrator` do not exist in `Sources/` yet (only planned in docs/23;
  used by name in the T09 exemplar). T03/T04/T06 are not yet even spec-written. Before
  writing the check, the implementing agent MUST read T06 *as landed* and confirm: (a) the
  registry's controller-lookup-by-projectId accessor name (this spec assumes
  `registry.controller(for: projectId)`); (b) the orchestrator's `plan(...)` parameter list
  and whether it already layers the T07 budget or expects T10 to (this spec assumes T10
  layers the budget over the planner's Live set, matching `runBrowserLRUBudgetSelfCheck`);
  (c) whether `WorkspaceRuntime` exposes the active `WorkspaceDocument.zones`,
  `canvasView`, and `visibleSize` to build the planner inputs. If any of these differs,
  adjust the check's plumbing (NOT its 10 observable assertions). If T03's planner does not
  accept a `focusedTileZone`/policy and does not produce a budget-aware Live set, that is a
  T03 gap — flag it; do not patch the planner from T10.
- **Group zones / ambient runtime** (`projectId == nil`) are NOT tiered here — they have no
  project controller until T08's ambient controller; their tiering is a follow-up. v1
  reconcile skips them.
- **Post-switch tiering is T09**, not T10. T10 is the steady-state pan/zoom reconcile on an
  already-installed workspace. Do not duplicate switch logic.
- **Determinism.** The debounce makes naive checks flaky — always
  `flushPendingHydrationReconcile()` before asserting (the codebase's `flush*Save()`
  pattern). Never `sleep` to wait for the timer.
- **Coordinate trap.** `visibleSize` is `canvasView.bounds.size` (screen px); the planner's
  visible *world* rect is `visibleSize / zoom` (CanvasEngine.hydrationTier:99–104). At
  `zoom != 1` (assertion 7 zooms out to 0.4), re-derive the visible band as
  `viewport.x … viewport.x + bounds.width/zoom`. Get the zoom math right in the fixture or
  assertion 7's expected Live-set is wrong.
- **Browser-only budget (D3).** PTYs stay live while their zone is Live in v1; the budget
  caps WKWebViews only. Do not attempt a PTY budget here.
- Stale SourceKit "cannot find WorkspaceRuntime" errors are noise until T06 lands; `swift
  build` is authoritative.
