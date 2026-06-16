# T04 Build Report

## Summary

Implemented `ZoneRuntimeRegistry` — a `@MainActor` per-project, ref-counted controller registry. Factory is injected so the check builds lock-free controllers. All 9 assertions pass through the real `acquire`/`release` API. `closeOnZero == false` skips `close()` (option a per spec's NEEDS-HUMAN note — box is dropped, controller stays warm but re-acquire rebuilds). `ZoneRuntimeBudgetConfig` provides the persisted default + `SettingsSchema` entry.

## Files Touched

- `Sources/ContinuumRevivedCore/ZoneRuntimeBudgetConfig.swift` — NEW, Core target
- `Sources/ContinuumRevived/App/ZoneRuntimeRegistry.swift` — NEW, App target
- `Sources/ContinuumRevivedCore/SettingsSchema.swift` — appended one toggle in `general` section
- `scripts/run-matrix.sh` — one new `run_app_check` line (grouped with zone checks)
- `Sources/ContinuumRevived/App/ContinuumApp.swift` — one new dispatch block for `--zone-registry-refcount-check`

## git diff --stat

```
 Sources/ContinuumRevived/App/ContinuumApp.swift   | 11 +++++++++++
 Sources/ContinuumRevivedCore/SettingsSchema.swift |  5 +++++
 scripts/run-matrix.sh                             |  1 +
 3 files changed, 17 insertions(+)
```

(The two new files do not appear in the diff stat as they are untracked.)

## RED Output (stub — assertion 2 failure)

```
FAIL: assertion 2: c2 === c1 (same instance — sharing guarantee)
exit: 1
```

Stub's `acquire` always called `makeController` ignoring any existing box, so `c2` was a different instance from `c1`. Exactly the expected RED per spec Stage B.

## GREEN Output (real implementation)

```
ContinuumRevivedZoneRegistryRefcountChecks passed: /Users/dylan/Documents/personal/continuum-revived/qa-runs/2026-06-16T031438Z/zone-registry-refcount/manifest.json
exit: 0
```

## Fast Matrix Result

`Fast matrix passed.` — all checks green including the new `--zone-registry-refcount-check`.

## Deviations from Spec

**`closeOnZero == false` semantics (assertion 8):** Implemented option (a) per the spec's NEEDS-HUMAN note: `closeOnZero == false` drops the box at zero (so `isLive` is false and re-acquire rebuilds) but skips `close()`. Assertion 8 matches this: `warm.isLive(P) == false`, `warm.refCount(P) == 0`, and `w1.setTier` throws `.uiUnavailable` (not `.controllerClosed`) proving the controller was not closed.

No other deviations.

## Acceptance Criteria Self-Assessment

- [x] `ZoneRuntimeRegistry` (App, `@MainActor`) with `acquire`/`release` + introspection, controller factory injected.
- [x] All 9 check assertions pass through the REAL `acquire`/`release` API; no `boxes` hand-mutation; identity by `===`; close proven by `.controllerClosed` throw.
- [x] Acquire twice → same instance, factory invoked once; release-to-zero closes; acquire after zero builds fresh; two projects independent; over-release safe; `closeOnZero` knob gates `close()`.
- [x] `ZoneRuntimeBudgetConfig` has persisted default + `SettingsSchema` entry; default resolution asserted (absent → `true`, explicit → honored).
- [x] `--zone-registry-refcount-check` registered in `run-matrix.sh` + `ContinuumApp.swift`.
- [x] No `ZoneRuntimeController` internals / AppKit / `WorkspaceRuntime` / `zoneRuntimeController` field touched.
- [x] Fast matrix green.
