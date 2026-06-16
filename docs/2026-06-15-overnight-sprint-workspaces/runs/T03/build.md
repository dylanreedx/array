## Summary

T03 — ZoneHydrationOrchestrator (pure planner). Implemented the full spec:
pure budget-and-proximity planner in Core, config namespace with UserDefaults resolver,
SettingsSchema entry, and the check block with all 13 assertions (9 plan + 4 config) plus
the expectedKeys extension in the schema check.

## Files touched

- NEW `Sources/ContinuumRevivedCore/ZoneHydrationOrchestrator.swift` — `ZoneHydrationPlan` struct + `ZoneHydrationOrchestrator` enum with the proximity-ranked, pin-bypassing `plan(...)` function.
- NEW `Sources/ContinuumRevivedCore/ZoneHydrationBudgetConfig.swift` — config namespace mirroring `DragMagnetizeConfig` with `maxLiveZonesKey`, `defaultMaxLiveZones` (4), and `maxLiveZones(defaults:)` resolver with `> 0` guard and string fallback.
- EXTEND `Sources/ContinuumRevivedCore/SettingsSchema.swift` — one `.text` field appended to `general` section for `ZoneHydrationBudgetConfig.maxLiveZonesKey`.
- EXTEND `Sources/ContinuumRevivedCoreChecks/main.swift` — new `// MARK: - zone-hydration-plan-check (T03)` block (assertions 1–9) + `// MARK: - zone hydration budget config (T03)` block (assertions 10–13), and `ZoneHydrationBudgetConfig.maxLiveZonesKey` added to `expectedKeys` in the Settings schema engine block.

## git diff --stat

```
 Sources/ContinuumRevivedCore/SettingsSchema.swift |   5 +
 Sources/ContinuumRevivedCoreChecks/main.swift     | 241 ++++++++++++++++++++++
 2 files changed, 246 insertions(+)
```

(The two new Core files are untracked — not reflected in diff --stat for modified files.)

## RED output (naive stub, no budget)

Confirmed by replacing `plan(...)` with a stub that calls `CanvasEngine.hydrationTier` per zone and returns the base map with no budget logic:

```
FAIL: zone hydration plan: budget=2 demotes Z4
```

Assertion 4 fails as expected: the naive stub keeps all four visibility-live zones (Z1,Z2,Z3,Z4) as `.live` because it applies no budget or proximity ranking.

## GREEN output

```
ContinuumRevivedCoreChecks passed
```

All 13 plan/config assertions pass plus the existing Settings schema engine asserts the new key is bound.

## --fast matrix result

```
Fast matrix passed.
```

All checks green. No regressions.

## Deviations from spec

None. The implementation follows the spec exactly:
- `plan(...)` delegates per-zone to `CanvasEngine.hydrationTier` unchanged.
- Hard-pinned partition: `zone.hydrationPolicy == .pinnedLive || zone.zoneId == focusedTileZone`.
- Budget math: `B = max(1, maxLiveZones)`, `P = hardPinned.count`, `keep = max(0, B - P)`.
- Sort: proximity (squared dist from zone center to visible-rect center) ascending, input index ascending as tiebreak.
- Iterates input `zones` array (not dictionary) for the tiers assembly — deterministic.
- `ZoneHydrationBudgetConfig` matches the spec copy-paste exactly.
- SettingsSchema appended exactly one `.text` field after the Drag Snapping toggle.
- No `--zone-hydration-plan-check` CLI flag registered (Core table, not app dispatch — per spec).
- No App target files touched; `CanvasEngine`, `ZoneRuntimeController`, `BrowserRuntimeBudget`, `run-matrix.sh`, `ContinuumApp.swift` all untouched.

## Self-assessment against acceptance criteria

- [x] `ZoneHydrationOrchestrator.plan(...)` exists in Core, pure, no AppKit, no stored state, returns `ZoneHydrationPlan` total over input zones.
- [x] Single-zone verdict delegated to unchanged `CanvasEngine.hydrationTier` (assertion 3 passthrough matches existing tier table geometry).
- [x] Budget demotes farthest visibility-live zones first; pinned/focused never demoted (assertions 4–6).
- [x] Tiebreak is input order on equal proximity; `maxLiveZones <= 0` clamps to 1; budget never promotes (assertions 7–9).
- [x] `ZoneHydrationBudgetConfig` has persisted default (4), `UserDefaults` resolver with `> 0` guard + string fallback, SettingsSchema entry, and schema check asserts its key.
- [x] `--zone-hydration-plan-check` table green; fast matrix green; nothing in App target / `ZoneRuntimeController` / `--zone-hydration-lifecycle-check` / `BrowserRuntimeBudget` / `CanvasEngine` touched.
