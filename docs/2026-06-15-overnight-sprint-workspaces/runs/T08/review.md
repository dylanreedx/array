# T08 Review — `addZone` spins a real controller + ambient controller for group zones

Reviewer: adversarial / independent. Branch `overnight/workspaces-zones`, uncommitted working tree.
Verdict: **PASS WITH RISKS**

## What I verified (evidence)

### 1. Bypass audit (#1 gate) — PASS, proven by mutation
The rewritten `runAddZoneSelfCheck` (ContinuumApp.swift:3702+) drives the REAL path:
`delegate.addProjectZone(P)` → `workspaceRuntime.addZone(projectId:)` → `_addProjectZone`/`_addGroupZone`
→ `registry.acquire` + `canvasView.upsertZoneLayer` + `WorkspaceDocumentSaveController.flushPendingSave`,
then asserts on registry contents, the **real** `CanvasNSView.installedZoneLayerIds`, and an **on-disk
reload** via a fresh `WorkspaceStore`. The old bypass (direct `appendProjectZone` + `WorkspaceStore` round-trip)
is fully gone.

I re-ran the check (green) and ran 5 mutation tests; **all went RED on the expected assertion**:
- Comment out `canvasView?.upsertZoneLayer(layer)` in `_addProjectZone` → `FAIL: assertion 3 ... got 0`.
- Hardcode `let home = NSHomeDirectory()` instead of `AmbientZoneHome.current` → `FAIL: assertion 6 ... ambient controller.projectRoot.path should be .../Hgroup, got /Users/dylan`.
- Comment out `canvasView?.upsertZoneLayer(layer)` in `_addGroupZone` → `FAIL: assertion 9 ... got 1`.
- Disable the de-dupe early-return → `FAIL: assertion 5: refCount(P) should still be 1 ... got 2`.
- Skip `flushPendingSave()` in `_addProjectZone` → `FAIL: assertion 4: reloaded document must contain a zone for P`.

All mutations reverted; working tree confirmed pristine (`git diff` shows no MUTATION residue).
**Answer to "would it pass if addZone were stubbed?": No** — for the layer/controller/persistence/de-dupe paths.
(Exceptions called out in Risks below.)

### 2. Right reason (hand-derivation)
Assertion 1 (refCount(P)==1): empty doc + registry with P at refCount 0 → first `addProjectZone(P)` → no
existing zone → single `registry.acquire(P)` → box created at refCount 1. Hand-derived expected = 1; check
asserts 1; mutation #4 (no de-dupe → second acquire → 2) confirms it discriminates. Right reason, not coincidence.
Manifest from green run: `refCountP: 1`, `installedLayerCount: 2`, `ambientControllerRoot` = temp `Hgroup`
(not `$HOME`), `groupZoneName: "Group"`.

### 3. Scope — PASS
- Files touched are exactly the 5 named (ContinuumApp.swift, WorkspaceRuntime.swift, SettingsSchema.swift,
  CoreChecks/main.swift, + new AmbientZoneHome.swift). diffstat matches the build report.
- `ZoneRuntimeRegistry.swift` NOT modified (registry internals respected — `acquire`/`release`/`refCount` only called).
- No `switchWorkspace`, `removeZone`, or tile-migration changes in the diff.
- Old `addProjectZone` body fully migrated; the AppDelegate forwarder (ContinuumApp.swift:2984) now only does
  registry workspace-membership metadata + `try workspaceRuntime.addZone(projectId:)`. No dead duplicate.
- `--add-zone-check` dispatch (ContinuumApp.swift:578) + matrix entry (run-matrix.sh:111) unchanged; return type still URL.
- Configurable-first: `AmbientZoneHome.userDefaultsKey` has a default (`AmbientZoneHome.fallback`), a SettingsSchema
  `.text` field in the general section, is in `expectedKeys` (main.swift:4250), and the uniqueness conflict-guard
  (`Set(fieldKeys).count == fieldKeys.count`, main.swift:4233) is still green.
- Uncommitted; no co-author footer present anywhere in T08 run docs (matches Dylan's no-co-authoring rule).

### 4. Matrix — PASS
`./scripts/run-matrix.sh --fast` → **Fast matrix passed.** `--add-zone-check` IS in the matrix (line 111;
--fast only skips the bundle probe). Separately re-ran clean-state: `--add-zone-check`, `--zone-save-isolation-check`,
`--multi-zone-render-check`, `--workspace-runtime-install-check` all exit 0. Core checks green.

## Risks (committable, but a human should weigh these)

- **R1 — Production `_addGroupZone` writes into the user's `$HOME`.** With the default `AmbientZoneHome`
  (no override), `_addGroupZone` calls `ZoneRuntimeController(root: $HOME, acquireLock: false)`, whose
  `init` → `loadOrCreateProject` → `ProjectStore.saveProject` materializes `$HOME/.continuum-revived/project.json`
  ("name":"dylan","rootPath":"/Users/dylan"). I observed this file get created (timestamp 06:10:22Z) during a
  mutation run that exercised the `$HOME` path, and removed it. The green check does NOT exercise this (it overrides
  the ambient home to a temp `Hgroup`), so it is invisible to the matrix. This is "by design" per the spec's
  "default `$HOME`" wording, but the spec did not anticipate that rooting a controller there writes a project dir.
  **Design call needed:** do we want the first group-zone creation to drop a `.continuum-revived/project.json`
  into the user's home directory? (See needsHuman.)

- **R2 — `acquireLock: false` is not guarded by the check.** Mutating the group controller to `acquireLock: true`
  leaves the check GREEN. The spec rubric explicitly requires "the group controller must be created
  `acquireLock: false`." A future regression to `true` would silently pass and could deadlock a second group zone
  rooted at the same home (lock contention). The implementation is currently correct (`false`); only the *guard* is missing.

- **R3 — Assertion 8 (group tiles in the workspace store) is tautological.** `WorkspaceDocument.tiles(forZone:)`
  returns `[]` for ANY zoneId not present in `groupZoneTiles`, and `_addGroupZone` never stores an entry
  (`setTiles([], forZone:)` is a no-op for empty lists, and it is not even called). The check asserts
  `groupTiles.count == 0` for both the group zoneId and the project zoneId — it would pass for a random UUID too.
  It proves the accessor is callable but proves NOTHING about group tiles being routed to the workspace store vs a
  ProjectStore. The builder flagged this (deviation #2) and it matches the spec's literal "empty on create is fine —
  assert it exists and is addressable," but it is weaker than rubric line 284 ("Persistence proves group tiles live
  in the workspace store, not ProjectStore"). Real group-tile storage routing is genuinely unverified until a tile is
  added to a group zone (out of T08 scope — T08 only creates the empty zone).

- **R4 — Behavioral change in the AppDelegate forwarder.** Old `addProjectZone` resolved the workspace from the
  active project / `lastActiveWorkspaceId`; the new forwarder uses `workspaceRuntime.workspaceId` and no-ops via
  `guard let workspaceRuntime` if the runtime isn't booted. Equivalent in the single-active-workspace world
  (T09 not done) and runtime is always set post-boot (assigned at ContinuumApp.swift:1150). Low risk; flagged for completeness.

## Unverified
- Group-tile persistence routing (workspace store vs ProjectStore) under a non-empty group zone — not exercised
  by any T08 check (no tile is ever added). See R3.
- I did not run the full (non-`--fast`) matrix (`check-app-bundle.sh`) — only `--fast`. Per spec the bundle probe is
  out of the fast gate.
- Visual/interactive behavior of an installed group layer on the live canvas (chrome placement, tile rendering)
  was not eyeballed — headless checks assert layer presence + placement identity only, per spec coordinate-model note.

## TDD / RED
RED was not separately confirmed before implementation (builder deviation #1: check + impl written in one pass
because the check references `WorkspaceRuntime.addZone`/`AmbientZoneHome` which didn't pre-exist). I substituted
post-hoc RED via 5 mutation tests (above), which is the strongest available evidence that the check is non-bypassable
for the asserted paths. This satisfies the *intent* of the RED gate for the covered assertions but not the letter of
the TDD doctrine; the two genuinely-unguarded behaviors (R2, R3) are exactly the kind of gap a true RED-first pass
might have surfaced.
