# T09 Review (Re-dispatch 1) — `switchWorkspace(to:)` in-process swap

**Reviewer:** Opus 4.8 (adversarial, read-only)
**Branch:** overnight/workspaces-zones · uncommitted working tree
**Verdict:** PASS WITH RISKS

This review supersedes the prior CHANGES-REQUESTED review (which triggered the re-dispatch).
All three prior defects were independently re-verified as fixed. One high-severity
production-integration risk that the prior review did not surface is hoisted below.

---

## What I ran (re-executed, not reasoned)
- `swift build` → clean.
- `--workspace-switch-check` → **GREEN** (`ContinuumRevivedWorkspaceSwitchChecks passed`, exit 0).
- **Bypass probe (stub the whole method to a no-op):** edited `switchWorkspace` to early-return →
  rebuilt → ran → **RED at inv1** (`zoneBb (Pb) must be installed after switch to WB`). Reverted.
- **Targeted RED probe for the re-dispatch's viewport fix:** removed only the 5-line viewport-persist
  block → rebuilt → ran → **RED at inv8** (`got CanvasViewport(x: 10.0, y: 20.0…)` — the stale on-disk
  value), exactly matching the builder's reported RED. Reverted; confirmed `git diff --stat` back to
  143 insertions.
- `./scripts/run-matrix.sh --fast` → **Fast matrix passed.**
- Spec-named regression checks, run individually → all exit 0:
  `--focus-broker-activation-check`, `--zone-save-isolation-check`, `--multi-zone-render-check`,
  `--zindex-relaunch-hit-test-check`, `--workspace-runtime-install-check`,
  `--zone-registry-refcount-check`, `--add-zone-check`.

## Bypass verdict: NOT a bypass (of T09's own contract)
The check drives the REAL `runtime.switchWorkspace(to:)` — the same method the repointed production
call sites now invoke. Inv1/3/4/5/6/8 assert observable state through real APIs (canvas
`installedZoneLayerIds`, broker `requestFocus` round-trips, `ZoneRuntimeRegistry.refCount`/`controller`/
`===` identity, `canvas.viewport`/`tileId(at:)`). A no-op stub fails at inv1 (proven by my own run).
The feature could NOT be stubbed/removed and still pass.

## Right-reason spot check (hand-derived)
- **inv2b hit-test** (the re-dispatch's headline addition): screenPoint `(60,10)`, viewport
  `(50,60,zoom 1)` → `screenToWorld` = `(60/1+50, 10/1+60)` = `(110,70)`. Zone Bb origin `(0,0)`,
  world frame `0..640 × 0..480` → point is inside Bb, not Bp (Bp world frame starts at x=700).
  zone-local = `(110,70)`. tileInPb frame `(x:10,y:10,w:200,h:120)` spans `10..210 × 10..130` →
  `(110,70)` inside → returns `tileInPb`. Assertion `hitTileId == tileInPb` is exact and unambiguous
  (no second zone collides at that world point). Correct, not coincidental.
- **inv8 viewport** (RED→GREEN): the mutated in-memory value `(77,88)` is restored only because
  `switchWorkspace` step 1 now reads `canvasView?.viewport` into `document.viewport` and saves the
  departing `WorkspaceDocument` before loading the target. Proven RED without the block.

## Prior defects — re-verified FIXED
1. **inv7 vacuity** → now asserts `runtime.workspaceId == workspaceWB` (a genuine in-process
   reachability proof: a relaunched process would not hold a live `runtime` reflecting WB).
   `_relaunchSpy`/`!relaunchCalled` remains and is still vacuous (grep confirms `_relaunchSpy?()` is
   never invoked anywhere), but it is now a documented secondary, not the sole proof. Acceptable —
   the structural reason (WorkspaceRuntime has no AppDelegate ref) is honest.
2. **shape-B no hit-test** → inv2b added (verified above) AND the `canvasState.tiles` gap is flagged
   as NEEDS-HUMAN in both the check comment (`ContinuumApp.swift:~4360`) and build.md deviation #3.
   No longer "silently shipped."
3. **departing viewport not persisted** → fixed + proven RED. (`WorkspaceRuntime.swift:397-402`.)

## Scope / hygiene — clean
- Only the 3 in-scope files changed (`WorkspaceRuntime.swift` +143, `ContinuumApp.swift`, `run-matrix.sh` +1).
- Do-NOT-touch list respected: no edits to the 4 NSEvent monitors, CanvasEngine transforms, or leader nav.
- Workspace-switch `relaunchApplication` path fully removed; create/switch/delete all route through
  `workspaceRuntime?.switchWorkspace`. The one surviving `relaunchApplication` is the **project**-switch
  path (`ContinuumApp.swift:3020`, project-root change) — exactly what the spec said to keep.
- `git diff --check` clean. No commit yet → no co-author-footer concern.

---

## RISKS (named; the dominant one is near-blocking)

1. **[HIGH — production integration is non-functional] The live `WorkspaceRuntime` is wired with a
   THROWING registry factory.** `applicationDidFinishLaunching` builds the runtime via the `boot:`
   convenience init with `bootRegistry` whose `makeController` throws
   *"unexpected acquire on boot registry — T08 wires this"* (`ContinuumApp.swift:1146-1157`). `registry`
   is a `private let` — there is no seam to swap in a working factory after launch. So in the real app,
   `switchWorkspace` reaches `registry.acquire(arrivingProject)` → **throws** → caught by
   `switchWorkspaceAndRelaunch`'s do/catch → logged to stderr → **the switch silently does nothing**.
   T09 *removed* the working relaunch fallback and replaced it with an in-process call that cannot
   complete against this stub, so ⌘K → switch workspace is a no-op (regression vs. the prior relaunch
   behavior). The headless check passes only because it injects a fully-wired registry + real `docA`.
   This is pre-existing branch debt (T06 introduced the stub; T08's comment claimed it would wire it but
   did not — `addProjectZone` hits the same throw), and rewiring the boot registry is arguably outside
   T09's "Exact scope." But T09 is the task that makes it user-visible. The morning visual gate (live
   switch) WILL fail until the boot registry has a real factory.
2. **[MED] Budget-pressure ref-count leak.** `departing`/`arriving` are diffed over the FULL target
   project set, but the acquire loop and `newlyAcquired` are tier-filtered to `.live`
   (`WorkspaceRuntime.swift:434-445`). A target project whose zone is budget-demoted to non-live, and
   which was previously acquired, is in neither `departing` (it's in the target set) nor `newlyAcquired`
   (filtered out) → it drops from `acquiredProjectIds` while its ref-count stays > 0 → never released by
   a later switch. Not exercised (check uses default high budget; all zones live). Pairs with D4 demotion
   (inv5) being punted to T10.
3. **[LOW] inv2 disjunction `tileInPb || .canvas` is looser than the hand-derived value (`tileInPb`).**
   A focus-restore regression that fell through to `.canvas` would not be caught. inv3 still rejects the
   stale-A-tile case, so not a bypass — just under-tight.
4. **[LOW] inv5 reframed.** Spec inv5 was "demoted-shared-P is Snapshot tier (D4)"; the check instead
   asserts shared-P `===` identity — which is exactly what the review rubric demanded ("identity by
   instance"). The D4 *tier* assertion the spec text named is absent; acceptable only because T10 owns
   viewport-driven tier transitions (per the spec's Out-of-scope).
5. **[LOW] App-support dir divergence under smoke-test only.** `createWorkspaceAndRelaunch` saves the
   empty doc via `WorkspaceStore.defaultApplicationSupportDirectory()` (canonical or `CONTINUUM_APP_SUPPORT`),
   while `switchWorkspace` loads from `registryStore.registryFile.deletingLastPathComponent()`. They agree
   in normal launch and under the env override, but `resolveAppSupportDir(smokeTest:true)` uses a random
   temp dir → mismatch. Not the production switch path.
6. **[LOW] Misnamed functions.** `switchWorkspaceAndRelaunch` / `createWorkspaceAndRelaunch` /
   `deleteWorkspaceAndRelaunch` no longer relaunch. Builder kept names per surgical-changes rule —
   acceptable, but misleading for future readers.

## Unverified
- Pure `WorkspaceSwitchPlan` Core table: none extracted (diff/release logic is inline). Spec said
  "if you extracted one" — optional, not a defect.
- The departing-viewport save in production writes under the boot runtime's SYNTHETIC `workspaceId`
  (a random UUID from the `boot:` init), not a real workspace — but this is moot while Risk 1 makes the
  whole switch throw before/around it. Not independently exercisable without fixing the factory.

## Needs human (Dylan)
- **Risk 1 is the decision point:** is the throwing boot registry acceptable to land alongside T09 (i.e.,
  a follow-up task will give `WorkspaceRuntime` a real per-project factory before the live switch is
  expected to work), or must the boot registry be wired NOW so ⌘K → switch actually functions? As-is,
  the commit lands green checks but the feature is inert in the running app.
- **Morning visual gate** (from build.md): live ⌘K switch — flicker, z-paint after `setZones`, cursor
  rects, old-tile focus-border clearing. NOTE: cannot be exercised until Risk 1 is resolved.
- **shape-B model decision:** accept descriptor-only active-zone tiles (`canvasState.tiles` not populated;
  ~71 read-sites blind to switched-in tiles) as the interim model, or reconcile to live `canvasState.tiles`
  before this lands? Currently flagged needs-human in-code.
