# T06 Review — WorkspaceRuntime shell + AppDelegate proxy

Reviewer: adversarial / read-only. Branch `overnight/workspaces-zones`, working tree uncommitted.

## Verdict: PASS WITH RISKS

The check drives the REAL `WorkspaceRuntime` lifecycle and asserts observable state; it is
NOT bypassable. Full matrix green (not just `--fast`). Scope is respected (no
switchWorkspace/relaunch/budget/addZone/tier/monitor touches; Core untouched; zero residual
`zoneRuntimeController`). Two real but low-severity defects (weakened assertion-5, one dead
orphan var) and one unverified behavioral risk (windowWillClose flush-after-terminate
ordering) keep this out of clean-PASS.

## 1. BYPASS AUDIT (#1 gate) — NOT BYPASSABLE

The check (`WorkspaceRuntime.runWorkspaceRuntimeInstallSelfCheck`, WorkspaceRuntime.swift:251)
constructs a real `WorkspaceRuntime` with real on-disk `ProjectStore`/`RegistryStore`/
`WorkspaceStore`, a real `CanvasNSView`, real `FocusBroker`, real `ZoneRuntimeRegistry`, then
calls `runtime.install(...)` / `flushAll()` / `closeAll()`. No hand-assembled zone set, no
pure-planner-then-assert. I re-ran it (GREEN) and performed four revert-one-line RED
experiments to prove the assertions bind to the real path:

- `closeAll` skips `registry.release` loop → **RED** "assertion 9: refCount(Pa) should be 0".
- `install` only handles the active zone (stub) → **RED** "assertion 1: zoneB should be installed".
- `restoreFocus` never requests the tile → **RED** "assertion 6: activeSurface should be .tile(noteA); got .canvas".
- `flushAll` made a no-op → **RED** "assertion 8: Pa's canvas should have viewport.x == 99; got 0.0".

Would it pass if the feature were stubbed? **No.** A stub `install` that newed controllers
itself fails assertion 3 (`runtime.controller(for: Pa) === registry.controller(for: Pa)`,
identity via `===`). A stub `closeAll` fails assertion 9 (refCount 0 + `liveProjectIds.isEmpty`
+ broker `requestFocus` false). Focus assertions 6/7/9 bind to real broker registration:
`requestFocus` returns false unless `_installLayer` called `focusBroker.register(view)`
(CanvasNSView.swift:1098), and `unregister` clears `activeSurface` (FocusBroker.swift:34-40),
so the teardown probe is genuine.

## 2. RIGHT REASON — hand-derived assertion 2 + 8

- Assertion 2: document has 2 project zones with DISTINCT projectIds (Pa, Pb), both default
  hydrationPolicy `.automatic`, budget = `ZoneHydrationBudgetConfig.maxLiveZones()` (default,
  large). Plan keeps both `.live`; `install` acquires each once → `refCount(Pa)==1`,
  `refCount(Pb)==1`, `liveProjectIds=={Pa,Pb}`. Matches intent (one controller per distinct
  projectId, ref-counted via the T04 registry — not a dict peek; `refCount(for:)` reads
  `boxes[id].refCount`).
- Assertion 8: check sets `canvas.setViewport(99,0,1)`, calls `activeController.scheduleCanvasSave()`
  (sets Pa controller `isCanvasDirty=true`), sleeps 1.1s, then `runtime.flushAll()`. flushAll
  fans out `flushPendingSaves()` over `acquiredProjectIds` → Pa's `flushCanvasSave()` writes
  `canvasView.canvasState` (viewport.x=99) to Pa's store. Pb stays byte+mtime identical. I
  hand-confirmed Pa's expected value (99) and proved RED on no-op flushAll.

## 3. SCOPE

- `grep zoneRuntimeController Sources/ scripts/` → **0** (symbol fully retired).
- Out-of-scope paths PRESERVED + untouched in the diff: `switchWorkspaceAndRelaunch` (:2990),
  `relaunchApplication` (:3073), `createWorkspaceAndRelaunch` (:2938), `addProjectZone`,
  `browserRuntimeBudget`/`enforceBrowserRuntimeBudget`, the three monitor installers. No new
  `switchWorkspace(to:)`. `--workspace-switch-check`/`runWorkspaceSwitchSelfCheck` not touched
  in the diff. No `onViewportChanged`/`reconcileHydration`.
- Core (`Sources/ContinuumRevivedCore/`) untouched (spec said likely-not-needed; correct).
- Configurable-first: NO new tunable introduced (correct — spec said expect none). The budget
  carry-forward reuses the existing `ZoneHydrationBudgetConfig.maxLiveZones()`.
- The four self-check harness rewrites (:3682, :5711, :5807, :6484) are the prescribed
  one-spot `delegate.workspaceRuntime = WorkspaceRuntime(boot: <same controller>, …)` swaps
  plus a mechanical stub registry (the `ZoneRuntimeRegistry` factory param the API requires).
  Their assertions are unchanged; full matrix proves behavior-neutrality.
- No co-author footer concern: code changes are uncommitted (working tree). HEAD is a prior
  docs commit unrelated to this code.

### Findings (scope/cleanliness, low severity)
- **Dead orphan var** WorkspaceRuntime.swift:193 `let activeProjectId = active.project.id` is
  never used. Introduced by this change → CLAUDE.md §3 says remove orphans your change creates.
- **Assertion 5 is weaker than the spec.** Spec assertion 5 requires asserting the installed
  layer's `placement.projectId == Pa` and `placement.origin`/`size` equal the document's zoneA
  placement (and same for zoneB). The check (WorkspaceRuntime.swift:436-440) asserts only tile
  MEMBERSHIP (`tileIds(inZone: zoneA).contains(noteA)`, `…zoneB….contains(noteB)`). Membership
  indirectly proves projectId routing (noteA exists only in Pa's canvas) but does NOT assert
  the layer's origin (0,0)/(700,0) or size (640×480). A swapped/wrong placement origin would
  pass. Partially mitigated by the adaptive-chrome carry-forward (which derives zoneA's expected
  frame from `placementA`) — but that block is guarded by `if let chromeFrame` and silently
  skips if chrome is nil.

## 4. MATRIX

- `./scripts/run-matrix.sh --fast` → **green** ("Fast matrix passed").
- `./scripts/run-matrix.sh` (FULL — spec demanded, heaviest delegate touch) → **green**
  ("Matrix passed", including the app-bundle codesign/verify probe). The spec's named
  regression guards (focus-broker, zone-save-isolation, single-zone-compat, multi-zone-render,
  zindex-relaunch-hit-test, add-zone, workspace-switch) are in the matrix and all passed.
- `swift build` clean, no new warnings.

## 5. DOMAIN / EDGE-CASE PROBES

- Production boot path: `applicationDidFinishLaunching` (:1146-1158) wraps the boot controller
  via the `boot:` convenience init, which `registry.register(controller, for:)` at refCount 1
  (NOT a parallel instance — satisfies the spec's "boot controller must be registered, off-by-one"
  gotcha). `activeController` resolves to it; `attachUI` is still called once (:1204) —
  behavior-neutral with the old `zoneRuntimeController.attachUI`.
- The `boot:` init synthesizes a RANDOM `workspaceId` and a synthetic single-zone `document`.
  Verified: `workspaceRuntime.workspaceId` and `.document` are NEVER read in production
  (`ContinuumApp.swift` reads only `activeController`/`flushAll`/`closeAll`). Inert for the
  shell; T09 must populate these for real switching.
- `closeAll` internal order is correct (clears zone layers / unregisters adapters BEFORE
  releasing controllers) — assertion 9 confirms.
- Production `attachUI` is now `workspaceRuntime?.activeController?.attachUI(...)` (optional
  chain). If `activeController` were ever nil at boot, UI would silently not attach; the boot
  init guarantees non-nil, and the matrix passes, so safe today — but it is a silent-nil
  surface a future change could trip (risk).

## Risks (hoisted)

1. **windowWillClose flush-ordering change is a real behavioral delta and is NOT covered by any
   check.** OLD code ran `zoneRuntimeController?.close()` (which calls `flushPendingSaves()` +
   session-exit persistence + `projectLock.release()`) as the FIRST line of `windowWillClose`,
   BEFORE terminating browser/terminal runtimes. NEW code moves the controller teardown into
   `workspaceRuntime?.closeAll()` placed AFTER the browser+terminal `terminate(policy: .force)`
   loops (ContinuumApp.swift:3242-3245). Net effect: on quit, browser/note snapshot flush now
   happens AFTER the WKWebView/PTY runtimes are force-terminated. `flushBrowserSave` snapshots
   read `runtime.url`/`runtime.title` from the (now terminated) WKWebView (TileSpawner.swift:916,
   920) — a last-unsaved URL/title at quit could persist stale/empty. Live navigation snapshots
   (browserPersistenceHandler) and the 0.2s debounce mostly cover this, so the data-loss window
   is the final unsaved nav at quit. **No self-check exercises `windowWillClose`** (grep
   confirms zero callers), so the matrix cannot catch this. Builder's chosen fix is reasonable
   (the alternative — closeAll first — crashed `--palette-captures-keys-over-browser-check`
   because the `runtimes`/`browserRuntimes` getters proxy through `activeController` which
   release nils), but the quit-flush ordering change is unverified.
2. **Shape-B claim in build.md vs actual `install` code.** build.md carry-forward #3 claims
   "active zone tiles live in `canvasState.tiles`, non-active zones get DescriptorTileNSView in
   a ZoneLayer." The actual `install` (WorkspaceRuntime.swift:155-180) puts ALL zones' tiles —
   including the active zone — into ZoneLayers as `DescriptorTileNSView`, and the workspace
   canvas's own `canvasState.tiles` is empty. In PRODUCTION this is moot (boot path uses
   `boot:` init, never `install`), but when T09 starts calling `install` for real switching,
   the active zone will be descriptor-only tiles in a layer, not live `canvasState.tiles` — the
   "shape B" invariant the report asserts is NOT what `install` implements. Flag for T09.
3. **Assertion-5 weakening (see Findings)** — placement origin/size not directly asserted; a
   wrong-placement install could pass.
4. Production `attachUI` via optional chain on `activeController` is a silent-nil surface (see
   Domain probes).

## bypassAudit summary
Would the check still pass if the feature were stubbed/removed? NO. Verified by re-running
GREEN plus four independent revert-one-line RED experiments (closeAll-no-release → assertion 9;
single-zone install → assertion 1; broken restoreFocus → assertion 6; no-op flushAll →
assertion 8). The check binds to registry ref-count introspection (`===` identity, not dict
peek), real broker register/unregister, and real on-disk save isolation through flushAll.
</content>
</invoke>
