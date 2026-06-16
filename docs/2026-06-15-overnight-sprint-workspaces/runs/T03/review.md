# T03 Review — ZoneHydrationOrchestrator (pure planner)

Reviewer: adversarial / independent. Branch: `overnight/workspaces-zones`. READ-ONLY (no edits committed; two temporary RED-proof stubs applied and restored byte-identical, verified via `diff -q`).

## Verdict: PASS

All 13 assertions green, fast matrix green, RED independently proven two ways, one asserted value hand-re-derived, scope clean, configurable-first genuinely wired. No open defects.

## 1. Bypass audit (#1 gate) — NOT A BYPASS

The check drives the real path: `ZoneHydrationOrchestrator.plan(...)` composed with the production `CanvasEngine.hydrationTier(...)`. For a pure planner with no AppKit/lifecycle surface, this Core derivation table IS the real path (per 01 §2 / spec rubric). I did not take the builder's word — I independently proved RED two ways:

- **Base-map-only stub** (replace step-5/6 with `tiers[zone]=baseTier`, no budget): `FAIL: zone hydration plan: budget=2 demotes Z4`. (`expect` exits on first failure, so only assertion 4 surfaces — matches builder's reported RED.)
- **Input-order-keep stub** (sort eligible by input index, ignore proximity): `FAIL: zone hydration plan: budget=2 keeps Z2 (closest)`. This is the discriminator the spec rubric demanded — Z1 is the first eligible (index 0) but is FARTHER than Z2, so an input-order stub keeps Z1 and fails. Proximity ranking is genuinely exercised, not coincidental.

A stubbed/removed feature does NOT pass the check. Real implementation: `swift run ContinuumRevivedCoreChecks` → `passed`.

## 2. Right reason — hand re-derivation of assertion 4 (maxLiveZones: 2)

Visible center = (0 + 800/1/2, 0 + 600/1/2) = (400,300) [matches ZoneHydrationOrchestrator.swift:75-76].
Base verdicts (all 200x120, automatic except Z6): Z1..Z4 intersect (0,0,800,600) → .live; Z5 origin (1200,100) is past the snapshot band right edge (1057 already cold per main.swift:639) → .cold; Z6 pinnedLive → .live.
- Z6 hard-pinned ⇒ P=1. Eligible-live = {Z1,Z2,Z3,Z4}. B=max(1,2)=2 ⇒ keep=max(0,2-1)=1.
- dist²: Z2 (400,160)=19600; Z4 (200,360)=43600; Z1 (200,160)=59600; Z3 (650,160)=82100.
- Sorted asc: Z2,Z4,Z1,Z3. Keep top 1 → Z2 .live; Z4,Z1,Z3 → .snapshot; Z6 .live; Z5 .cold.

Matches the asserted values exactly (main.swift:4377-4382). The assertion encodes intent (farthest-first demotion), not a coincidence.

## 3. Scope

- Exactly the 4 spec-named artifacts: NEW `ZoneHydrationOrchestrator.swift`, NEW `ZoneHydrationBudgetConfig.swift`, `SettingsSchema.swift` (one `.text` field appended after Drag Snapping, general section, SettingsSchema.swift:77-81), `CoreChecks/main.swift` (one new plan block + one config block + one `expectedKeys` line at :4246). diff --stat: 2 files / 246 insertions + 2 untracked Core files.
- Do-NOT-touch list respected: `git diff` shows NO change to ZoneRuntimeController.swift, BrowserRuntimeBudget.swift, CanvasEngine.swift, run-matrix.sh. No `--zone-hydration-plan-check` CLI dispatch added anywhere. No `ContinuumApp.swift` change. `--zone-hydration-lifecycle-check` (the applying half) untouched at run-matrix.sh:106.
- No invented `.warm` tier (grep clean). Iterates ordered `bases`/`zones`, never `Dictionary`. Zoom conversion `/ viewport.zoom` present (not hardcoded zoom 1), so the proximity center derivation tracks the base verdict at non-1 zoom.
- No commit made; no co-author footer to assess (work is uncommitted, as expected for review).

## 4. Matrix

`./scripts/run-matrix.sh --fast` → `Fast matrix passed.` No regression. The existing "Hydration tier visibility math" table and Settings-schema engine block both still green; the schema block now also asserts the new key via `expectedKeys.isSubset`.

## 5. Configurable-first

Default (4) + resolver with `>0` guard + string fallback (ZoneHydrationBudgetConfig.swift) + SettingsSchema `.text` field + `expectedKeys` membership (main.swift:4246, proven by the subset assertion and the uniqueness check). Schema default `String(defaultMaxLiveZones)` = "4" matches resolver default 4 — no silent mismatch. Config assertions 10-13 (default / Int override / 0 & -3 fallback / string "3") all green in an isolated scrubbed suite.

## 6. Edge probes (all confirmed correct)

- **Focus counts toward P**: with `focusedTileZone: Z1`, Z1 base = .live (forced by hydrationTier), classified hard-pinned via `zoneId == focusedTileZone`; P=2, keep=0; Z2/Z3/Z4 demote, Z1+Z6 survive (assertion 6). Pin/focus not demoted, not double-counted.
- **Tiebreak determinism**: Za/Zb same origin → dist²=0.0 exactly (integer-valued), `lhsDist2 != rhsDist2` false → explicit `lhsIndex < rhsIndex` tiebreak (does not rely on `sorted` stability). Assertion 7 shows the keep flips on input-order swap.
- **Clamp**: maxLiveZones 0 and -3 both clamp to B=1; single-zone stays live, two-zone keeps closer Z2 (never zero-live when something is visibility-live).
- **No promotion**: Z5 .cold with maxLiveZones 99 stays .cold (assertion 9). Budget is demote-only.

## Risks (named, non-blocking)

- **R1 (design call, already flagged by spec, low):** The charter names the guard `--zone-hydration-plan-check` but it is implemented as a tagged Core `do`-block, not a discrete CLI flag. The spec §"Out of scope" explicitly flags this as NEEDS-HUMAN and argues a pure-model task should stay a Core table (forcing a flag would push the planner into the App target and add no real-path coverage). I concur for a pure planner; recorded as a human sanity-check, not a defect.
- **R2 (downstream, expected):** The planner is dead code until T06/T10 wire it. T03's scope is the planner only; the budget threshold is never read into `plan(...)` by any caller yet (the resolver and `plan`'s `maxLiveZones` parameter are not connected — that connection is T06's). Expected per spec; the check exercises `plan` directly. Reviewer of T06/T10 must confirm `ZoneHydrationBudgetConfig.maxLiveZones(defaults:)` is actually passed into `plan(maxLiveZones:)` then.
- **R3 (cosmetic, low):** Float `!=` on `dist²` for the proximity tiebreak is exact here because all fixture coords are integer-valued; in production with fractional world coords two zones could be near-but-not-exactly equidistant and the input-order tiebreak would not engage. Not a correctness bug (any total order is acceptable; the only contract is determinism, which holds because the comparator is a strict total order). Noting only because the spec leans on `!=` exactness for assertion 7.

## needsHuman

- Confirm the Core-table interpretation of the `--zone-hydration-plan-check` charter name is acceptable (no discrete CLI flag) — spec's own NEEDS-HUMAN, R1 above.
- Settings UI: a "Max Live Zones" free-text field with no min/numeric validation in the UI layer (resolver guards `>0`, but the Settings field is `.text`). Whether the UI should constrain input is a product call for a human; out of T03 scope but worth a glance when the Settings pane is reviewed visually.

## Confirmed defects: NONE
