# T06 Build Report — WorkspaceRuntime shell + AppDelegate proxy

## Summary

Implemented `WorkspaceRuntime` as a new `@MainActor final class` that owns the current workspace's live zone set: a `WorkspaceDocument`, per-project `ZoneRuntimeController`s via the ref-counted `ZoneRuntimeRegistry`, installed canvas `ZoneLayer`s, and focus restoration. `AppDelegate` was migrated from a raw `zoneRuntimeController: ZoneRuntimeController?` field to a `workspaceRuntime: WorkspaceRuntime?` field — all 60+ call sites in `ContinuumApp.swift` were repointed. The migration exposed a real `windowWillClose` bug: `runtimes` and `browserRuntimes` are computed via `workspaceRuntime?.activeController?`, so calling `closeAll()` (which releases the controller from the registry) before the termination loops left `runtimes` returning `[]` — Ghostty surfaces were never terminated before `ghostty?.shutdown()`, which crashed the `--palette-captures-keys-over-browser-check`. Fixed by moving `closeAll()` after the termination loops.

All three ORCHESTRATOR CARRY-FORWARD requirements are covered: (1) `ZoneHydrationBudgetConfig.maxLiveZones()` fed into `ZoneHydrationOrchestrator.plan(maxLiveZones:)` in `install(into:)`; (2) zone layer chrome uses `CanvasEngine.zoneBounds(memberFrames:...)` rather than stored `zoneWorldFrame` (check assertion 9 verifies adaptive layout); (3) storage-shape B confirmed — active zone tiles live in `canvasState.tiles`, non-active zones get `DescriptorTileNSView` in a `ZoneLayer`.

## Files touched

- `Sources/ContinuumRevived/App/WorkspaceRuntime.swift` — NEW, 635 lines: `WorkspaceRuntime` class with `init(workspaceId:document:...)`, `init(boot:)` convenience init, `install(into:appRegistry:)`, `flushAll()`, `closeAll()`, `runWorkspaceRuntimeInstallSelfCheck()` (10 assertions + 2 carry-forward probes)
- `Sources/ContinuumRevived/App/ContinuumApp.swift` — 157 net lines changed: `zoneRuntimeController` → `workspaceRuntime` rename throughout; `windowWillClose` fix (move `closeAll()` after termination loops); four harness rewrites; `--workspace-runtime-install-check` dispatch
- `Sources/ContinuumRevived/App/ZoneRuntimeRegistry.swift` — +9 lines: `liveProjectIds` computed property, `register(_:for:)` method
- `Sources/ContinuumRevived/Canvas/CanvasNSView.swift` — +33 lines: `_zoneLayerChromeScreenFrame` helper, `zoneLayerChromeFrame(for:)` test introspection, updated `layoutAllTiles()` and `setZonePlacement(_:)` to use adaptive bounds
- `scripts/run-matrix.sh` — +1 line: `--workspace-runtime-install-check` entry

## git diff --stat

```
 Sources/ContinuumRevived/App/ContinuumApp.swift    | 157 +++++++++++++++------
 Sources/ContinuumRevived/App/ZoneRuntimeRegistry.swift |   9 ++
 Sources/ContinuumRevived/Canvas/CanvasNSView.swift  |  33 ++++-
 scripts/run-matrix.sh                               |   1 +
 4 files changed, 154 insertions(+), 46 deletions(-)
 (+ WorkspaceRuntime.swift NEW 635 lines, untracked)
```

## RED output (before implementation)

```
FAIL: assertion 1: workspaceId should match document workspaceId
Exit: 1
```

The check compiled against a stub `WorkspaceRuntime` (init + empty methods) and failed immediately on the first behavioral assertion — `workspaceId` was not stored.

## GREEN output (after implementation)

```
ContinuumRevivedWorkspaceRuntimeInstallChecks passed: .../qa-runs/2026-06-16T045227Z/workspace-runtime-install/manifest.json
Exit: 0
```

All 10 lifecycle assertions green plus budget carry-forward (zoneB demotes to snapshot tier) and adaptive chrome carry-forward (chrome screen frame matches `CanvasEngine.zoneBounds` within 1pt).

## Fast matrix result

```
Fast matrix passed.
EXIT:0
```

All checks green. No regressions. Notable fix: `--palette-captures-keys-over-browser-check` was failing due to the `windowWillClose` ordering bug described in the summary above — the fix moved `workspaceRuntime?.closeAll()` to after the `runtimes`/`browserRuntimes` termination loops so that the computed getters (which proxy through `workspaceRuntime?.activeController?`) remain readable during teardown.

## Deviations from spec

- `closeAll()` ordering: spec required clearing zone layers BEFORE releasing controllers (the T09 contract for focusBroker adapter unregister). The `windowWillClose` fix did NOT change `closeAll()`'s internal order — zone layers are still cleared first inside `closeAll()`. The fix only moved WHEN `closeAll()` is called within `windowWillClose`, placing it after the runtime termination loops.
- Harness rewrites: four existing harness methods (`runAgentStatusBadgeSelfCheck`, `runPaletteBrowserSpawnSelfCheck`, `runSpawnFocusPolicySelfCheck`, nav-mode check) each gained a `ZoneRuntimeRegistry(closeOnZero:makeController:)` stub registry since `ZoneRuntimeRegistry.init` requires a factory parameter. This was not described in the spec but is a mechanical consequence of the API.

## Self-assessment

- [x] Named check written first (stub → RED assertion 1).
- [x] 10 lifecycle assertions + 2 carry-forward probes all GREEN.
- [x] `grep zoneRuntimeController` → 0 results (symbol fully retired).
- [x] `swift build` → Build complete, warnings pre-existing only.
- [x] `--workspace-runtime-install-check` → pass.
- [x] Fast matrix → pass (all checks).
- [x] `windowWillClose` bug found and fixed: `closeAll()` moved after termination loops.
- [x] No git add/commit; changes left in working tree for reviewer.
