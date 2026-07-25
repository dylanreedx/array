# Implementor packets — tickets 01–10 dry run

These packets are **supplements** for unattended Fable/Sonnet implementation. They do not replace the
original ticket files and must not weaken the original directives. Use them to make each ticket easier
to deliver in a Ralph-style loop with explicit shell stages and durable logs.

Rules for every packet:
- Worktree: `/Users/dylan/Documents/personal/continuum-overnight`.
- Branch: `overnight/agent-orchestration`.
- One ticket only; no batching.
- No push. No co-authoring/AI footer.
- New files must be visible to reviewers via `git add -N <file>` before review.
- Verification must gate through `swift build`, relevant `swift run *Checks`, and
  `./scripts/run-matrix.sh`.
- Do **not** use XCTest as proof unless the matrix is explicitly changed to run it. Current project
  convention is executable `*Checks` targets wired into `run-matrix.sh`.
- If `CONTINUUM_SKIP_SURFACE_CHECKS=1` is set, record result as `matrix: green (headless)` and keep
  the supervised GUI matrix debt.

---

## 01 — `store-protocol-seam`

**Current state:** done (`c71d601`), headless/supervised matrix debt still applies.

**Contract:** introduce `ProjectStoring` and `WorkspaceStoring` protocols while keeping
`ProjectStore`/`WorkspaceStore` as default concrete implementations. Move store dependencies to
protocol existentials. Do not expose `layout` or path helpers through `ProjectStoring`; add the four
intent methods required by the ticket.

**Likely files/seams:**
- `Sources/ContinuumRevivedCore/StoreProtocols.swift`
- `Sources/ContinuumRevivedCore/ProjectStore.swift`
- `Sources/ContinuumRevivedCore/WorkspaceStore.swift`
- `Sources/ContinuumRevivedCore/SessionPruner.swift`
- `Sources/ContinuumRevived/App/ZoneRuntimeController.swift`
- `Sources/ContinuumRevived/App/TileSpawner.swift`
- `Sources/ContinuumRevived/App/WorkspaceDocumentSaveController.swift`
- `Sources/ContinuumRevived/App/ContinuumApp.swift`

**Acceptance gates:** protocol round-trips through existentials; exactly four intent methods; no
`layout` on protocol; concrete-only path access remains concrete; matrix green.

**Common failure modes:** adding `layout` to the protocol, adding extra path methods, using `some`
in stored properties, changing store behavior during type refactor.

**Subdivision:** none; already digestible and landed.

---

## 02 — `op-enum-logged-op-envelope`

**Current state:** done (`a4cba75`), headless/supervised matrix debt still applies.

**Contract:** define pure spatial op-log identity layer: `OpId`, closed hand-coded `Op`, `LoggedOp`,
`FracIndex`, canonical op-log JSON encoder. No materialization, transport, runtime handles, pids,
pane targets, paths, or `TerminalSessionDescriptor` in op payloads.

**Likely files/seams:**
- `Sources/ContinuumRevivedCore/SpatialOp.swift`
- `Sources/ContinuumRevivedCore/JSONCodec.swift`
- executable checks under `Sources/ContinuumRevivedCoreChecks/`

**Acceptance gates:** hard-coded fixture decode; unknown discriminator fails; `LoggedOp` exactly
`opId` + `op`; lexicographic `OpId`; frozen `FracIndex` anchors; sorted/non-pretty encoder; I5 taint
scan records nonzero bytes and `taint:none`.

**Common failure modes:** synthesized `Op.Codable`, generated-only fixture tests, accidental runtime
fields, drifting into materialize/apply logic.

**Subdivision:** none; additive and landed.

---

## 03 — `membership-tile-register`

**Current state:** conflicted; do not retry as monolith. See `_CONFLICT_LOG.md` C-20260701-001.

**Contract:** make membership a tile-level LWW register via `Tile.zoneId: UUID?`; replace
`WorkspaceDocument.groupZoneTiles` with flat `ambientTiles`; keep only private legacy decode shape if
needed; bump canvas/workspace schema versions; preserve forward-incompat safety.

**Likely files/seams:**
- `Sources/ContinuumRevivedCore/CanvasState.swift`
- `Sources/ContinuumRevivedCore/WorkspaceDocument.swift`
- `Sources/ContinuumRevivedCore/ProjectStore.swift` / save re-stamp path if explicitly allowed
- `Sources/ContinuumRevivedCore/WorkspaceProfileStore.swift` / nested document persistence if relevant
- `Sources/ContinuumRevivedCoreChecks/main.swift`
- production render/projection paths in `WorkspaceRuntime` / `CanvasNSView` / related app code

**Acceptance gates:**
- old v1 canvas decodes with `zoneId == nil` and re-saves with new schema version;
- old v2 workspace with `groupZoneTiles` decodes to `ambientTiles` with stamped `zoneId`;
- re-save emits only `ambientTiles`;
- `setTiles(_:forZone:)` changes only membership and preserves frame/runtimeRef/metadata/kind;
- production rendering reads the new membership signal;
- I5 taint check uses production projection, not a local allow-list helper.

**Known failure modes:** schema re-stamp under old version; stale caller clobbers whole `Tile`; nested
profile save bypasses v3; tautological I5 test; production rendering not wired.

**Recommended split:**
1. `03A-schema-restamp-contract`
2. `03B-zoneid-ambienttiles-migration`
3. `03C-membership-mutation-semantics`
4. `03D-production-membership-projection`

**Fable policy:** select only after the scope fence is amended or the micro-sequence is authored.

---

## 04 — `zorder-fractional-index`

**Current state:** conflicted; do not retry as monolith. See `_CONFLICT_LOG.md` C-20260701-002.

**Contract:** replace integer z-order with `FracIndex`-backed `Tile.zPosition` and
`ZonePlacement.zPosition`; migrate legacy `zIndex`/`zoneZOrder`; sort render/hit-test by z-position
with deterministic tie-break; add spatial op cases.

**Likely files/seams:**
- `Sources/ContinuumRevivedCore/CanvasState.swift`
- `Sources/ContinuumRevivedCore/WorkspaceDocument.swift`
- `Sources/ContinuumRevivedCore/CanvasEngine.swift`
- `Sources/ContinuumRevivedCore/SpatialOp.swift`
- many `Tile(...)` construction call sites
- executable checks under `Sources/ContinuumRevivedCoreChecks/`

**Acceptance gates:** `FracIndex: Codable, Comparable, Hashable, Sendable`; no production
`Tile.init(zIndex:)` shim; all call sites migrated compile-enforced; legacy rank order preserved;
encoder omits legacy keys; `bringToFront` does not lower frontmost item; hit-testing sorts by
`zPosition`, not array order.

**Known failure modes:** missing `Hashable`; keeping compatibility shim; collapsed legacy ranks;
array-order hit-testing; insufficient migration/backend tests.

**Recommended split:**
1. `04A-fracindex-hardening`
2. `04B-tile-zposition-migration`
3. `04C-workspace-zone-zposition-migration`
4. `04D-engine-render-hittest-order`

**Fable policy:** remove shims early so the compiler exposes all call sites; require grep proof that
`zIndex` remains only as decode-only legacy key.

---

## 05 — `delete-tombstone`

**Current state:** retryable only with file-hygiene guard; see `_CONFLICT_LOG.md` C-20260701-003.

**Contract:** add delete op cases and tombstone vocabulary/policy. Prove delete-wins using local
folds. Do **not** implement production materializer, compactor, or op-emitting close path here.

**Likely files/seams:**
- `Sources/ContinuumRevivedCore/SpatialOp.swift` or sync target op home
- `Sources/ContinuumRevivedSync/Tombstone.swift` if sync target exists/gets created
- `Package.swift` if new target/check executable is introduced
- `Sources/ContinuumRevivedSyncChecks/main.swift` or existing check executable

**Acceptance gates:** `Op.deleteTile` / `Op.deleteZone`; `TombstoneSet.absorb`; idempotent duplicate
deletes; move-vs-delete and zone-delete-vs-field-set local folds prove no resurrection; ledger
canonical JSON round-trip; delete op taint scan clean; every new source/check file tracked or
intent-to-add before review.

**Known failure modes:** untracked `Tombstone.swift`; drifting into ticket 06 materialize/compaction;
pretending a production close-path op emitter exists.

**Recommended split:** optional but safer:
1. `05A-sync-target-file-hygiene`
2. `05B-tombstone-vocabulary`
3. `05C-delete-policy-checks`

**Fable policy:** safe unattended candidate after dirty tree is clean and `git add -N` guard is in the
script; do not use it to paper over unresolved 03/04 semantics.

---

## 06 — `oplog-apply-compaction`

**Current state:** dependency-blocked by 03/04/05. See `_CONFLICT_LOG.md` C-20260701-006.

**Contract:** build materialization and compaction for the spatial op-log using the real membership,
z-order, and tombstone types.

**Likely files/seams:**
- `Package.swift` — likely `ContinuumRevivedSync` target + `ContinuumRevivedSyncChecks`
- `Sources/ContinuumRevivedCore/SpatialOp.swift`
- `Sources/ContinuumRevivedCore/CanvasState.swift`
- `Sources/ContinuumRevivedCore/WorkspaceDocument.swift`
- `Sources/ContinuumRevivedCore/ProjectStore.swift`
- `Sources/ContinuumRevivedSync/OpLog.swift`
- `Sources/ContinuumRevivedSync/Compaction.swift`
- `Sources/ContinuumRevivedSyncChecks/main.swift`

**Acceptance gates:** permutation-stable LWW; delete/tombstone wins; exactly one zone register per
tile; zone order sorted by `(FracIndex, zoneId)`; canonical JSON stable; no runtime refs; compaction
boundary drops `lamport <= lowWaterMark`; backend ProjectStore round-trip; no stubbing missing models.

**Ambiguities to clarify:** ticket may refer to op types in a new sync module while current landed
code has `SpatialOp.swift` in Core. Consume the actual landed location; do not duplicate names.
Make `materialize(ops:ontop:)` explicit if 07 depends on it.

**Fable policy:** do not attempt until 03/04/05 or their micro-sequence lands.

---

## 07 — `convergence-fuzz-red-green`

**Current state:** dependency-blocked by 06. See `_CONFLICT_LOG.md` C-20260701-007.

**Contract:** deterministic convergence fuzz proving replicas settle to byte-identical canonical
state, including compaction snapshot + tail behavior.

**Likely files/seams:**
- `Package.swift` target dependency if checks need Sync
- `Sources/ContinuumRevivedCoreChecks/main.swift` or `Sources/ContinuumRevivedSyncChecks/main.swift`
- `Sources/ContinuumRevivedSync/OpLog.swift`
- `Sources/ContinuumRevivedSync/Compaction.swift`

**Acceptance gates:** `swift run <Checks>` and matrix; manifest line includes 50 seeds, 10,000 total
steps, compaction count with compaction firing in at least 30 seeds, seed-1 canonical byte count;
seed-specific failure output; Codable op round-trip; compacted replica uses snapshot + tail.

**Ambiguities to clarify:** CoreChecks vs SyncChecks home; breadcrumbs using `UUID()` must be replaced
with seed-derived fixed UUIDs.

**Fable policy:** do not attempt before 06; reject nondeterministic UUID/time fixtures.

---

## 08 — `sync-observation-type-split`

**Current state:** current dirty attempt exists; classify before any new ticket. See `_CONFLICT_LOG.md`
C-20260701-004.

**Contract:** split bidirectional spatial sync (`SpatialOp`) from one-way activity observation
(`AgentActivityEvent`); add `ActivityStore` actor with pure fold, snapshot-then-tail stream, and
whole-document `AtomicWriter` persistence.

**Likely files/seams:**
- `Sources/ContinuumRevivedCore/AgentActivityEvent.swift`
- `Sources/ContinuumRevivedCore/ActivityStore.swift`
- `Sources/ContinuumRevivedCoreChecks/ActivityStoreTests.swift` or equivalent check file
- `Sources/ContinuumRevivedCoreChecks/main.swift`
- `Sources/ContinuumRevivedCore/TerminalSessionDescriptor.swift`
- `Sources/ContinuumRevivedCore/AtomicWriter.swift`
- `Sources/ContinuumRevivedCore/SpatialOp.swift`

**Acceptance gates:** append stamps sequence + replicaId; `apply(_:_:)` is the single fold used by
append/init; snapshot-then-tail subscribe order; replay sorted strictly after cursor for one replica;
recent ring caps at 200; mirror forbidden-field/I5 check; real `AtomicWriter` flush/load;
concurrent append actor isolation.

**Known failure modes:** XCTest-only verification; quadratic append re-fold; replay insertion order;
snapshot/tail divergence with foreign higher-sequence events; unchecked AsyncStream observer lifecycle.

**Fable policy:** first classify current dirty work as continue/stash/discard. If continued, require
all checks in executable `*Checks` path and do not start another ticket until this diff is committed or
preserved.

---

## 09 — `taint-scan-i5`

**Current state:** dependency-blocked by 08 and possibly op cases from 03/04/05. See `_CONFLICT_LOG.md`
C-20260701-008.

**Contract:** build a sync/activity payload taint scanner proving invariant I5: no pid, pane target,
runtime handle, transcript body, or host-local path crosses sync/activity boundaries.

**Likely files/seams:**
- `Sources/ContinuumRevivedCore/SyncPayloadTaintScanner.swift`
- `Sources/ContinuumRevivedCoreChecks/main.swift`
- `Sources/ContinuumRevivedCore/SpatialOp.swift`
- `Sources/ContinuumRevivedCore/AgentActivityEvent.swift`
- `Sources/ContinuumRevivedCore/TerminalSessionDescriptor.swift`

**Acceptance gates:** every shipped `Op` case represented; 4 tones × 6 statuses = 24 activity events;
fixture `sequence`/`lamport` above pid ceiling; deliberate poison yields at least four violations;
`NSNumber` UInt64 overflow branch safe; `isKnownSafeInteger` initially false unless explicitly
commented/safelisted.

**Ambiguity to clarify:** geometry/z-order integers can look pid-shaped. Prompt must specify whether
to use safe fixture values, key-path allow-listing with comments, or stricter scanner behavior.

**Fable policy:** wait for 08; do not implement against stale activity event shape.

---

## 10 — `session-topology-snapshot`

**Current state:** retryable after prompt/ticket amendment. See `_CONFLICT_LOG.md` C-20260701-005.

**Contract:** parse tmux session/window topology into a pure Codable snapshot. No process/daemon calls.

**Likely files/seams:**
- `Sources/ContinuumRevivedCore/SessionTopologySnapshot.swift`
- `Sources/ContinuumRevivedCoreChecks/main.swift`
- later consumers: `TmuxSession.swift`, `TerminalSessionDescriptor.swift`

**Acceptance gates:** `swift build`; `swift run ContinuumRevivedCoreChecks`; matrix; empty or
whitespace-only input returns zero-session snapshot; five-field line malformed; non-numeric pid invalid;
pid `0` succeeds; tab split preserves empty command; format string has exactly six variables in order;
session order preserved; JSON round-trip for empty/single/multi snapshots; no process calls.

**Winning ruling:** no `ParseError.emptyInput`. Empty string, newline-only, spaces, and tabs are valid
zero-session snapshots.

**Known failure modes:** stale ticket prose/breadcrumbs reintroduce `emptyInput`; parser uses default
split that drops empty command fields; checks cover only newline-empty, not spaces/tabs.

**Fable policy:** safe unattended candidate after the amendment is injected into the implementor prompt.
