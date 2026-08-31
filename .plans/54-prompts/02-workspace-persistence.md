# WS2 dispatch — exact workspace and zone persistence

## Shared workstream target

This packet defines **WS2: exact zone/workspace persistence** in Array. The rendered `<ROLE>` controls authority: a lead implements; a reviewer or tester evaluates the same locked target under only its selected overlay.

The fully rendered common protocol prepended to this dispatch is binding. The checked-in `00-agent-protocol.md` is an unresolved reference template and never overrides rendered values.

Read `<WORKTREE>/AGENTS.md`, the master `.plans/54-array-0.8.0-overnight-orchestration.md`, and `.plans/54-prompts/00-agent-protocol.md`. This packet is the binding persistence contract; older handoffs are historical and must not override it. Work only in `<WORKTREE>` at `<BASE_SHA>` and write evidence to `<EVIDENCE_DIR>`.

### Outcome

- One authoritative production path captures live workspace state, updates the in-memory `WorkspaceDocument`, and atomically persists it.
- Cold reload and repeated A → B → A switching restore exact zone placements, tile world frames, membership, z-order, viewport, active zone, and focus.
- Project, ambient, unhydrated, and same-project multi-zone scenes are all preserved.
- A normal window close flushes all acknowledged live state before runtime teardown, including viewport and debounced active-zone selection.
- Immediate close after a gesture does not lose the committed geometry.
- A failed save leaves the last valid document loadable, keeps the departing scene mounted, and reports failure without a false “Saved” state.
- The production boot/mount path is the witness. A checks-only call to `WorkspaceRuntime.install(into:)` is not proof.

### Known defects and false greens

- Geometry persistence is duplicated between `AppDelegate.persistLayoutTransaction` and `onZoneMoved` → `WorkspaceRuntime.commitZonePlacement`.
- Normal close tears down `WorkspaceRuntime` before some workspace-only live state is flushed.
- Some current switch checks prepare the runtime using checks-only installation, which has previously hidden production mount defects.
- Flat canvas and `ZoneLayer` mirrors use different coordinate spaces; a save from the wrong model can displace tiles or erase lower-tier tiles.

### Inspect first

- `Sources/ContinuumRevivedCore/WorkspaceDocument.swift`
- `Sources/ContinuumRevivedCore/WorkspaceStore.swift`
- `Sources/ContinuumRevivedCore/CanvasState.swift`
- `Sources/ContinuumRevived/App/WorkspaceRuntime.swift`
- `Sources/ContinuumRevived/App/WorkspaceDocumentSaveController.swift`
- workspace mount/switch/close/save paths in `Sources/ContinuumRevived/App/ContinuumApp.swift`
- persistence projection seams in `Sources/ContinuumRevived/Canvas/CanvasNSView.swift` without editing WS1-owned resize/layout hunks
- existing workspace/persistence checks and matrix registration

### Owned scope

You own WorkspaceDocument/Store/Runtime/SaveController and new focused check files. You have a narrow grant in AppDelegate boot/switch/close and check dispatch. Do not alter WS1 resize semantics, transcript providers, performance budgets, or release files. Schema changes must decode all old fixtures, preserve unknown/defaulted state, and increment only the correct document version.

### Required witnesses

1. First deliver a standalone subprocess/bundle restart-and-fault driver with fixed UUIDs, retained isolated project/app-support roots, explicit child readiness/quit protocol, per-iteration timeout/cleanup, injectable file-operation seams, a prior-valid-document oracle, and a first-hydrated-frame hook. Prove one cold-restart scenario RED before implementation continues. It must mutate through production, wait for a named persistence generation, quit, relaunch, and compare canonical state plus rendered frames.
2. Scenarios, 20 repetitions each:
   - cold restore of one project zone;
   - A → B → A repeated switching;
   - project and ambient zones together;
   - an unhydrated zone below the live tier;
   - the same project represented by multiple zones;
   - non-zero zone origins proving world ↔ local conversion;
   - close at 0, 10, 50, and 190 ms after an acknowledged placement mutation.
3. Fault injection at temporary-write, flush/synchronize, atomic replacement/rename, and permission-denied seams. The prior valid document must reopen, no tile may vanish, the visible scene must remain coherent, and success must not be reported.
4. First-hydrated-frame capture as well as eventual settled state, so a wrong boot flash cannot pass.
5. Persistence cover-then-replace: a project tile may disappear only when its own installed zone proves absence. Lower-tier/unhydrated tiles remain in the document.

Artifacts include input/final registry, workspace, and canvas JSON; normalized semantic diffs; SHA-256; save-generation trace; stdout/stderr; diagnostic-report before/after; and screenshots of mutated, first-hydrated, and settled states in both appearances.

### Required commands

```sh
export CONTINUUM_PROJECT_ROOT="<QA_PROJECT_ROOT>"
export CONTINUUM_APP_SUPPORT="<QA_APP_SUPPORT>"
export TMUX_TMPDIR="<QA_TMUX_TMPDIR>"
unset TMUX TMUX_PANE
swift build
swift run ContinuumRevivedCoreChecks
.build/debug/Array --canvas-persistence-model-check
.build/debug/Array --persistence-crash-safe-check
.build/debug/Array --workspace-boot-persistence-check
.build/debug/Array --workspace-switch-check
.build/debug/Array --workspace-scene-owner-check
.build/debug/Array --zone-save-isolation-check
.build/debug/Array --workspace-restart-fault-check
scripts/check-matrix-inventory.sh
```

Enumerate existing flags from source before first invoking the new one; do not guess. The lead must add the standalone production-path restart/failure driver under the exact `--workspace-restart-fault-check` flag and register it in the matrix. Reviewer/tester dispatch is gated on the candidate containing it; both run it directly and prove its matrix leg executed. Keep all fixtures away from Dylan's real project and production stores.

### Stop rules

Stop on ambiguous ownership, old-schema data loss, required changes to WS1-owned layout hunks, inability to isolate the project root, or any chance the production app/state was touched. Do not paper over a failed write by retrying indefinitely or rebuilding state from whichever mirror happens to be populated.

### Success

All state classes round-trip exactly across real reload/switch/close, write failure is atomic and honest, production mounting is exercised, no project tile is lost, and the evidence is reproducible from absolute paths.

## Independent reviewer overlay

Trace production boot/mount/switch/save/close in order. Verify save-before-teardown, a single authoritative geometry writer, exact coordinate conversions, cover-then-replace, atomic failure behavior, and old-schema decoding. Reject `WorkspaceRuntime.install(into:)` as the core witness; require `mountWorkspaceSceneAtBoot` or the shipped equivalent.

## Independent tester overlay

Run the fixed-UUID cold-restart matrix and fault injection from a clean candidate checkout. Repeat each core scenario 20 times as one machine-readable batch with a fresh retained store per iteration; capture one representative first/settled visual pair per unique scenario plus every failure, not 20 duplicate screenshots. Canonical-diff all state files and compare rendered frames within 0.5 pt. FAIL on tile loss, frame drift, false save success, stale first paint, failure to recover the prior valid document, or any evidence that relies only on an in-process reconstruction.
