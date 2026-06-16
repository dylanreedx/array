# T01 Review — Zone model: optional projectId + name + navKey

**Reviewer:** opus (strong model, adversarial, read-only)
**Verdict:** PASS

## Summary
T01 changes `ZonePlacement.projectId` to `UUID?` (nil = group zone), adds `name: String`
and `navKey: String?`, replaces synthesized `Codable` with a custom backward-compatible
encode/decode, and bumps `WorkspaceDocument.currentSchemaVersion` 1→2. Four Core
assertions added (v2 project zone, v2 group zone, v1→v2 migration, mixed doc). Two orphan
fixes in existing checks. Fast matrix green; no regressions.

## 1. Bypass (#1 gate) — NOT a bypass
For a pure-model task the production path is the persistence codec. The check uses
`JSONCodec.makeEncoder()` / `JSONCodec.makeDecoder()` (main.swift:748-749, 768-769, 797,
838-839) — the **same codecs** `AtomicWriter.swift:26,52` and `ProjectStore.swift:113` use
to write/read workspace docs on disk. So it drives the real serialization path and asserts
observable state (decoded field values, JSON substrings).

**Would it still pass if the feature were stubbed?** No. Proven empirically: I built a
standalone probe (a v2-shaped struct with a *synthesized* Codable, i.e. the no-op/default
implementation) and decoded the exact v1 JSON literal from assertion 3. It throws
`DecodingError.keyNotFound: 'name'`. The custom decoder's `decodeIfPresent(...) ?? ""` is
load-bearing — assertion 3 goes RED without it. The builder's reported RED was a
compile-error (missing members), which is the acceptable RED shape for a pure-model task
per spec line 55-57; the *behavioral* RED (assertion 3) is real, as I verified directly.

## 2. Right reason — hand-derived value matches
Re-derived assertion 3 by hand from the v1 JSON literal (main.swift:783-795):
projectId present → preserved `E5E5...`; `name` absent → `""`; `navKey` absent → `nil`.
My probe decoded the same literal through the real custom Codable and produced exactly
`projectId=E5E5E5E5-… name="" navKey=nil`, matching the assertions at main.swift:799-801
and the spec (lines 50-51). The value is intent, not coincidence. The substring assertion
`"schemaVersion":2` (main.swift:609) is consistent with `currentSchemaVersion = 2`.

## 3. Scope — clean
- Only the two spec-named files changed (`WorkspaceDocument.swift`, checks `main.swift`)
  + the T01 run docs dir. No AppKit/runtime files touched (spec Do-NOT list respected).
- No global `tile.zoneId` introduced; no tile-storage migration (correctly deferred to T02).
- `appendProjectZone` call site updated with `name: ""`, `navKey: nil` (WorkspaceDocument.swift:56-57).
- The two "orphan fixes" in checks both trace directly to spec-mandated deltas:
  `zone.projectId?.uuidString` (optionality) and `"schemaVersion":2` (version bump). Not refactors.
- App-target `ZonePlacement(...)` call sites (ContinuumApp/CanvasNSView/TileSpawner/
  ZoneRuntimeController/DefaultWorkspaceMigration) and `projectId` comparisons
  (e.g. ContinuumApp.swift:1064 `placement.projectId == project.id`, a `UUID? == UUID`
  optional-promotion) all compile under the new optional type — the App target binary at
  `.build/debug/continuum-revived` was freshly built and its checks ran green.
- No co-author footer (nothing committed; run notes only attribute the builder model).
- Configurable-first rule: `navKey` is per-zone *document* data, not a global
  binding/threshold; the keybind behavior + its configurability is explicitly owned by T18
  (T18 header: "Depends on: T01 (`ZonePlacement.navKey`)"). Correctly deferred, not a gap.

## 4. Matrix — green
`./scripts/run-matrix.sh --fast` passed end-to-end (full build + all Core/Palette/FileTree/
Perf check tables + every app check + git-hygiene). No other check regressed. Core checks
run in isolation also pass. (Note: a benign "Switched to branch 'main' / create mode
branch.txt" line in Core-check output comes from the pre-existing git-diff-engine fixture
at main.swift:226 operating in its own temp repo — the real working tree stayed on
`overnight/workspaces-zones` with only the expected diffs.)

## 5. Edge-case probes (spec rubric)
- Migration uses a **hand-written v1 JSON literal** (not a re-encoded v2 doc) — confirmed
  (main.swift:783-795). Does not round-trip v2. PASS the rubric's REWORK trigger.
- `projectId == nil` asserted for group zone (main.swift:772) and mixed-doc group zone
  (main.swift:841) — optionality proven, not just compiled. PASS.
- No persisted doc invalidated: `validateSchema` only throws on `schemaVersion > 2`
  (WorkspaceDocument.swift:27), so v1 (1 ≤ 2) still loads. PASS.
- Group-zone encode omits `projectId` via `encodeIfPresent` and re-decodes to nil
  (asserted by assertion 2). `name` always encoded even when "". Matches spec lines 36-39.

## Confirmed defects
None.

## Risks / unverified
- The check exercises the codec directly, not the full on-disk
  `ProjectStore.saveWorkspace`/`loadWorkspace` round-trip. This is the correct altitude for
  a pure-model task and `ProjectStore` uses the identical `JSONCodec`, so the path is the
  same — but a real file-write+reload of a v1 doc through `ProjectStore` is not asserted
  here (acceptable; T12 "bulletproof restore" is the on-disk lifecycle task). Low risk.
- Backfilling a project zone's `name` from the registry at load is explicitly NOT done here
  (spec lines 28-29) — deferred to runtime T06. Group zones currently always encode name ""
  unless set; consumers (T15/T17) must handle empty names. By design, not a defect.
