# T02 — Group-zone tile storage: REVIEW

Reviewer: strong review model (adversarial, read-only)
Verdict: **PASS**

## Summary
Implementation matches the spec exactly. `GroupZoneTiles` record type + `groupZoneTiles: [GroupZoneTiles]`
field + defaulted init param + explicit `Codable` (`decodeIfPresent ?? []`) + `tiles(forZone:)` /
`setTiles(_:forZone:)` accessors on `WorkspaceDocument`. 8-assertion Core round-trip table added to
`ContinuumRevivedCoreChecks/main.swift` between the `WorkspaceStore` and `DefaultWorkspaceMigration` MARKs.
RED proven, GREEN re-verified by me, fast matrix green.

## 1. BYPASS verdict: NOT a bypass
Assertions 1–4 and 8 drive the REAL persistence path: `WorkspaceStore.save` → `AtomicWriter.write`
(iso8601 `JSONCodec` encoder) → on-disk `workspaces/<wsId>/canvas.json` → `WorkspaceStore.load` →
`AtomicWriter.read` → `validateSchema`. Not an in-memory `JSONCodec` round-trip.
- Assertion 4a/4b (`main.swift:1340-1348`) read the actual bytes of `store.layout.canvasFile` and assert
  they contain `t1id` and `gz`. `encode(to:)` writes `groupZoneTiles` (WorkspaceDocument.swift:115), so
  this FAILS if the field is dropped on encode — a real observable-state proof.
- Would it pass if the feature were stubbed/removed? No. I reverted `decodeIfPresent ?? []` to a strict
  `decode` and re-ran `ContinuumRevivedCoreChecks`: it goes RED with
  `DecodingError.keyNotFound: Key 'groupZoneTiles'`. (See §2 for the exact failing site.)

## 2. RIGHT REASON (re-derived by hand)
- Assertion 2b `t1.frame.x == 40`: `t1 = makeTile(x: 40,...)` → `TileFrame(x:40)`. WorkspaceStore/AtomicWriter
  apply no frame transform (plain JSON), so 40 round-trips to 40, read off the *reloaded* doc
  (`loaded.tiles(forZone: gz)`, main.swift:1328). Correct — zone-local frame preserved.
- Assertion 7a upsert count: `document` has gz→[t1,t2] (1 row); `setTiles([t1], forZone: gz)` hits the
  `firstIndex` branch with non-empty tiles → in-place replace → row count stays 1, tiles == [t1]. Correct.
- Would-go-RED confirmation (decisive): with strict `decode`, the crash actually surfaces *before* T02's
  assertion 5 — at the PRE-EXISTING WorkspaceDocument fixture/migration checks (main.swift ~700, ~796,
  schemaVersion:1 literals with no `groupZoneTiles` key). I instrumented the check to confirm the T02
  assertion-5 backups dir is empty and that the throw precedes assertion 5. This makes the backward-compat
  decode broader-load-bearing than the spec predicted, and the RED genuine. Restored both files; diffstat
  back to 56/175, no debug residue (grep DEBUG5 == 0).

## 3. SCOPE — clean
- Only `WorkspaceDocument.swift` (+54/-2) and `CoreChecks/main.swift` (+175) changed; plus the T02 docs dir.
- `currentSchemaVersion` still `2` (no second bump). `SettingsSchema` NOT in diff (correct — T08 owns group
  defaults). `CanvasState`/`ProjectStore`/`Tile` NOT in diff. `appendProjectZone` untouched. No global
  `tile.zoneId` added (all `zoneId`/`Tile` diff hits are the new `GroupZoneTiles`/accessor code).
- `Equatable` is synthesized (no hand-written `==`) — so `groupZoneTiles` is in equality, making assertion 1
  meaningful. `Sendable` synthesized. Only `Codable` became explicit, as specified.
- The new init param is defaulted, so the 8 documented memberwise-init call sites
  (DefaultWorkspaceMigration, ZoneRuntimeController, ContinuumApp) compile unchanged — `swift build` clean,
  no construction-site edits, confirming they weren't touched.
- No commit made (builder correctly left it uncommitted); no co-author footer to flag.

## 4. MATRIX
`./scripts/run-matrix.sh --fast` → "Fast matrix passed." `ContinuumRevivedCoreChecks passed` in the run;
the pre-existing WorkspaceDocument round-trip/fixture/v1→v2-migration checks (which depend on the
backward-compat decode) all still pass. No regression. (The "FileTreeGitStatusProbe git status failed"
lines are expected output from the file-tree probe exercising a non-repo path, not a failure.)

## 5. Edge-case probes
- Backward-compat literal (assertion 5) is a hand-written JSON with NO `groupZoneTiles` key, decoded via the
  full `store.load()` (AtomicWriter + validateSchema) path. `schemaVersion:2` ≤ currentSchemaVersion so
  validateSchema passes. The literal includes `"name": ""` matching T01's `ZonePlacement.name`
  (`decodeIfPresent ?? ""`) so it decodes. Reverting `decodeIfPresent ?? []` makes the broader decode fixtures
  RED (verified).
- `setTiles` empty-removes (assertion 6) and upsert-no-duplicate (assertion 7) verified against the source
  logic (WorkspaceDocument.swift:43-50).
- Isolation negative scan (assertion 4c): correctly noted by the spec as near-vacuous in this Core table
  (nothing constructs a ProjectStore), but the positive on-disk content check (4a/4b) is the real proof.
