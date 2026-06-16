## T10 Build Summary — Viewport-driven tier transitions

**Builder:** cheap model (claude-sonnet-4-6)
**Branch:** overnight/workspaces-zones
**Date:** 2026-06-16

---

### Files Touched

| File | Change |
|------|--------|
| `Sources/ContinuumRevivedCore/ZoneHydrationReconcileConfig.swift` | NEW — debounce config resolver (25 lines), mirrors DragMagnetizeConfig |
| `Sources/ContinuumRevivedCore/SettingsSchema.swift` | +5 lines — append `.text(key: ZoneHydrationReconcileConfig.intervalKey, …)` to `general` section |
| `Sources/ContinuumRevivedCoreChecks/main.swift` | +10 lines — `expectedKeys` extended + resolver round-trip (default=200, override "50"→50) |
| `Sources/ContinuumRevived/App/WorkspaceRuntime.swift` | +66 lines — `onViewportChanged()`, `reconcileHydration()`, `flushPendingHydrationReconcile()`, `reconcileCount`, `hydrationReconcileTimer`, `lastReconciledViewport` |
| `Sources/ContinuumRevived/App/ContinuumApp.swift` | +837 lines — arg dispatch block `--zone-tier-transition-check`, `runZoneTierTransitionSelfCheck()` (10 assertions + T09 carry-forward), viewport-delta gate in `canvasDidChange`, `lastReconciledViewport` property |
| `scripts/run-matrix.sh` | +1 line — register `--zone-tier-transition-check` after `--browser-lru-budget-check` |

**git diff --stat (tracked files):**
```
Sources/ContinuumRevived/App/ContinuumApp.swift    | 837 +++++++++++++++++++++
Sources/ContinuumRevived/App/WorkspaceRuntime.swift |  66 ++
Sources/ContinuumRevivedCore/SettingsSchema.swift  |   5 +
Sources/ContinuumRevivedCoreChecks/main.swift      |  10 +
scripts/run-matrix.sh                              |   1 +
5 files changed, 919 insertions(+)
+ untracked: Sources/ContinuumRevivedCore/ZoneHydrationReconcileConfig.swift (new file, 25 lines)
```

---

### RED Output (stub — confirmed before implementing)

Temporarily replaced `reconcileHydration()` body with a no-op (counter only) and ran:

```
FAIL: assertion 1: Pb tier after initial reconcile at (0,0,1) should be cold, got live
```

Assertion 1 fails because without the real plan-apply, B remains live after the initial reconcile. Assertion 2 (demote on pan-away) would also fail. The check is genuine — it goes RED without `reconcileHydration`.

---

### GREEN Output

```
ContinuumRevivedZoneTierTransitionChecks passed: .../qa-runs/.../zone-tier-transition/manifest.json
```

All 10 assertions + T09 carry-forward pass.

---

### --fast matrix result

```
Fast matrix passed.
```

All neighbor checks also pass:
- `--zone-hydration-lifecycle-check` passed
- `--browser-lru-budget-check` passed
- `--zone-save-isolation-check` passed
- `--focus-broker-activation-check` passed

---

### Deviations from Spec

1. **Check structure**: The spec calls for a static func on `AppDelegate`. The func is implemented as a static `AppDelegate` method, as specified. The check uses multiple sub-runtimes (freshRuntime, pinnedRuntime, budgetRuntime, etc.) rather than one monolithic runtime, because reusing controllers across different WorkspaceRuntime instances required explicit `attachUI` re-calls and re-seeding. This is faithful to the intent.

2. **`focusedTileZone` detection in `reconcileHydration`**: The spec says to derive `focusedTileZone` from the live state. The implementation finds the focused tile ID from `canvasView.canvasState.lastActiveTileId` (workspace canvas), then finds which zone's controller canvas contains that tile. For assertion 8, `zoneCanvasA.markActive(tileId: browserA)` marks the tile on the zone canvas; the workspace canvas's `lastActiveTileId` is not set, so `focusedTileZone` is nil. Instead, assertion 8 relies on `setTier`'s focused-zone guard (`allowDehydratingFocusedZone: false`), which checks `controller.canvasView.canvasState.lastActiveTileId`. This correctly protects the focused tile — consistent with the spec's note that "either the planner pins it (focusedTileZone) or setTier's guard rejects the demote."

3. **Assertion 9 debounce timing**: The spec says to set the intervalKey to a "measurable value" and confirm `reconcileCount == 1` after the burst+flush. Since `flushPendingHydrationReconcile()` cancels the timer and runs synchronously, the burst of 3 `onViewportChanged()` calls each cancel the previous timer and schedule a new one. The final `flush()` cancels the pending timer and runs once → `reconcileCount` increments by exactly 1. The test confirms `reconcileAfterFlush - reconcileBeforeFlush == 1`. This is correct.

4. **T09 carry-forward**: Added as a dedicated carry-forward test (not one of the numbered 10). Uses zoom=0.1 at install time so both zones are live-eligible and acquired (refCount=1). After reconcile at (0,0,1) demotes B, `closeAll()` still releases B (refCount→0) because B remains in `acquiredProjectIds`. This proves no leak.

---

### Acceptance Criteria Self-Assessment

- [x] `--zone-tier-transition-check` drives `workspaceRuntime.onViewportChanged()` (the REAL pan/zoom-triggered entry), NOT `setTier`/`reconcileHydration`/the planner directly.
- [x] All 10 assertions pass; demote (2/3) and promote (4) assert observable runtime+canvas state (controller `hydrationTier`, `browserRuntimes` count, tile `runtimeRef`, `BrowserSnapshotTileNSView`/`BrowserTileNSView` installed), re-derived against `CanvasEngine.hydrationTier`.
- [x] `pinnedLive` (6), budget cap (7), focused-zone guard (8), debounce coalescing (9), and idempotence (10) all asserted.
- [x] New debounce config: resolver + persisted UserDefaults default (200ms) + `SettingsSchema` `.text` entry + conflict-guard `expectedKeys` coverage + resolver round-trip in Core checks. Nothing hardcoded.
- [x] T03 planner untouched; `switchWorkspace` untouched; gesture math untouched.
- [x] Fast matrix green; neighbor checks (hydration-lifecycle, lru-budget, save-isolation, focus-broker) green.
- [x] T09 carry-forward: demoted controller released on closeAll (refCount → 0, no leak).
