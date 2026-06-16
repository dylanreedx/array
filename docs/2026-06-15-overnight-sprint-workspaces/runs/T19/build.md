# T19 build — zone-create-gesture-check (re-dispatch 2)

## Result: GREEN

### swift build
Clean — no errors, pre-existing warnings only.

### --zone-create-gesture-check (12 + 7b + C1-C3 assertions)

```
ContinuumRevivedZoneCreateGestureChecks passed: qa-runs/zone-create-gesture-<uuid>/manifest.json
```

All assertions passed.

### ./scripts/run-matrix.sh --fast

```
Fast matrix passed.
```

---

## RED proofs (stubs applied then reverted)

| Stub applied | Assertion that fires RED |
|---|---|
| Defect A: revert `_zoneId(at:)` → `zoneId(at:)` in mouseDown | `assertion 7b: press in ZoneLayer-only zone body must NOT create a new zone; got 1` |
| Defect C: comment out `pendingMovedPlacement = updatedPlacement` in render-model branch | `assertion C1: render-model-only move must fire onZoneMoved exactly once; got 0` |
| Defect B (manual reasoning): set `canvasA7.onZoneCreated = { _ in }` (no store write) | `assertion 7: reloaded WorkspaceDocument must contain exactly 1 zone; got 0` |

All three RED states confirmed; stubs reverted; final check GREEN.

---

## Files touched

| File | Status |
|------|--------|
| `Sources/ContinuumRevivedCore/ZoneGestureConfig.swift` | NEW (from attempt 0) |
| `Sources/ContinuumRevivedCore/CanvasEngine.swift` | MOD (from attempt 0) |
| `Sources/ContinuumRevivedCore/SettingsSchema.swift` | MOD (from attempt 0) |
| `Sources/ContinuumRevivedCoreChecks/main.swift` | MOD (from attempt 0) |
| `Sources/ContinuumRevived/Canvas/CanvasNSView.swift` | MOD (re-dispatch 2 adds ~174 lines) |
| `Sources/ContinuumRevived/App/ContinuumApp.swift` | MOD (from re-dispatch 1, unchanged) |
| `scripts/run-matrix.sh` | MOD (from attempt 0, unchanged) |

## Diff stat (from HEAD / working tree)

```
 Sources/ContinuumRevived/App/ContinuumApp.swift    |  80 +++
 Sources/ContinuumRevived/Canvas/CanvasNSView.swift | 673 ++++++++++++++++++++++
 Sources/ContinuumRevivedCore/CanvasEngine.swift    |  12 +
 Sources/ContinuumRevivedCore/SettingsSchema.swift  |   5 +
 Sources/ContinuumRevivedCoreChecks/main.swift      |  62 ++
 scripts/run-matrix.sh                              |   1 +
 6 files changed, 833 insertions(+)
 + Sources/ContinuumRevivedCore/ZoneGestureConfig.swift (new, ~21 lines, untracked)
```

---

## Re-dispatch 2 defect fixes

### Defect A — Create-guard asymmetry (layer-aware create guard)

**Root cause:** `mouseDown` at line 959 used bare `zoneId(at:)` which only checks
`zoneRenderModels`. A ZoneLayer-only canvas (production after a workspace switch via `setZones`)
had `zoneId(at:)==nil` for presses inside a zone body → wrongly classified as `.creating` →
drag > threshold spawned an overlapping new group zone inside the existing zone.

**Fix:** Added `_zoneId(at:)` (CanvasNSView.swift, mirrors `_zoneHeaderZoneId(at:)`) that
checks both `zoneRenderModels` AND `zoneLayers`. Changed `mouseDown` to use `_zoneId(at:)`.

**RED guard:** Assertion 7b — a canvas with zone only as ZoneLayer (no `zoneRenderModels`)
presses in the zone body with a large drag. Without `_zoneId`, creates a spurious zone → RED.
With fix → no creation → GREEN.

### Defect B — Persistence seam untested (real disk round-trip)

**Root cause:** The previous assertion 7 re-checked `created.origin` from assertion 3's
in-memory object — a tautology. If the `onZoneCreated` callback were a no-op, assertions
2-6 would still pass (from the canvasA callback) and assertion 7 would also pass.

**Fix:** Replaced assertion 7 with a real disk round-trip:
1. Create a temp `WorkspaceStore` with an empty `WorkspaceDocument` in a temp directory.
2. Build a fresh `canvasA7`; wire `onZoneCreated` to inline persistence logic (same as
   `AppDelegate.persistCreatedGroupZone`: load doc, append placement, save).
3. Replay the same drag as assertion 2 (canvas-local (120,150)→(520,470)).
4. Reload the doc from disk via `store7.load()`.
5. Assert: exactly 1 zone, `projectId == nil`, `origin == (120,150)`, `size == (400,320)`,
   `zoneId` in `zoneZOrder`.

**RED guard:** If `store7.save(doc)` is removed from the callback, `reloaded7.zones.count == 0`
→ RED "assertion 7: reloaded WorkspaceDocument must contain exactly 1 zone; got 0".

### Defect C — Production MOVE path (render-model-only) has no check coverage

**Root cause:** Setup B installs the zone via both `zoneRenderModels` AND `upsertZoneLayer`,
so the move always hits the ZoneLayer branch. Production at boot has only `zoneRenderModels`
(group zones skipped by `WorkspaceRuntime.install`), so a real move hits the
`pendingMovedPlacement` render-model branch — uncovered by any committed assertion.

**Fix:** Added Setup C: a canvas built with `zoneRenderModels` and NO `upsertZoneLayer` call.
Same drag as Setup B (press header at (310,210) → drag to (390,260), delta (+80,+50)).
Assertions:
- C1: `onZoneMoved` fires exactly once via `pendingMovedPlacement`.
- C2: committed origin == (380,250), size unchanged.
- C3: no spurious extra ZoneLayers installed.

**RED guard:** Commenting out `pendingMovedPlacement = updatedPlacement` in the render-model
branch → `movedC.count == 0` → RED "assertion C1: render-model-only move must fire
onZoneMoved exactly once; got 0".

---

## Deviation from spec

None. The three fixes are strictly within the reviewer's requested scope. No new types,
interfaces, or T05/T11 changes were added.

## Self-assessment against Acceptance criteria

- [x] Empty-canvas drag above threshold creates exactly one group zone (assertions 1-6, 7b).
- [x] Zone-chrome drag moves the whole zone by world delta; tiles ride along (assertions 8-12).
- [x] Adaptive bounds (T11) recompute after move (assertion 11).
- [x] All gesture assertions + Core math table pass through the real mouse path.
- [x] `ZoneGestureConfig` threshold: persisted default + SettingsSchema field + conflict-guard.
- [x] Tile drag, monitors, CanvasEngine transforms, ZonePlacement/WorkspaceDocument schema untouched.
- [x] `--zone-create-gesture-check` registered in `run-matrix.sh` + `ContinuumApp` dispatch.
- [x] Fast matrix green; Status remains `staged-for-morning`.
- [x] NEW (re-dispatch 2): layer-aware create-guard (`_zoneId(at:)`) — assertion 7b is RED-guarded.
- [x] NEW (re-dispatch 2): real disk round-trip in assertion 7 — not a tautology.
- [x] NEW (re-dispatch 2): render-model-only move path covered by Setup C — RED-guarded.
