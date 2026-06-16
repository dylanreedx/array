# T06 — `WorkspaceRuntime` shell + AppDelegate proxy (docs/23 S4)

Status: todo
Tag: overnight [appkit-checkable]
Depends on: T03, T04, T05 · Blocks: T07, T08, T09, T10

⚠ This is the heaviest `AppDelegate` touch (docs/23 Risk: "S4 is the heaviest
AppDelegate touch; keep the proxy mechanical"). The mitigation is that this task is
**behavior-neutral**: it introduces `WorkspaceRuntime` as a holder for the *current*
workspace's live zone set and reroutes AppDelegate's zone operations through it, **without
adding the cross-workspace switch** (that's T09). Build it so the swap heart (T09) and the
budget/add-zone/tier tasks (T07/T08/T10) have one object to extend.

## Goal
Give the app a single object — `WorkspaceRuntime` — that owns a workspace's live zone set
(its `WorkspaceDocument`, its per-project `ZoneRuntimeController`s via the registry, and its
installed canvas `ZoneLayer`s), composing T03's hydration planner + T04's ref-counted
registry + T05's mutable canvas. `AppDelegate` stops doing zone install/teardown inline and
**proxies** to `WorkspaceRuntime`. This is the seam every later keystone step plugs into:
T07 hangs the budget off it, T08 spins controllers through it, T09 adds `switchWorkspace`,
T10 adds viewport-driven tier transitions. **Shell only** — install + teardown of the
*current* workspace; switching between workspaces is T09.

## ⚠ ORCHESTRATOR CARRY-FORWARD (added mid-sprint from T03/T05/T11 reviews — IN SCOPE for T06)
Three integration gaps surfaced by the reviewers of the tasks T06 builds on. T06 is where they go live; address all three and the reviewer WILL verify each:

1. **Wire the hydration budget into the planner.** T03 shipped `ZoneHydrationOrchestrator.plan(maxLiveZones:)` + `ZoneHydrationBudgetConfig.maxLiveZones(defaults:)`, but nothing feeds the resolver into `plan()`. Wherever `WorkspaceRuntime` calls the planner, pass `ZoneHydrationBudgetConfig.maxLiveZones(defaults:)` as `maxLiveZones` — otherwise the configurable budget is decorative. Add a check assertion that the budget actually gates the live set.

2. **Make the installed `ZoneLayer` chrome adaptive.** T11 made `CanvasEngine.zoneBounds` drive ONLY the legacy active-zone chrome; T05's `ZoneLayer` chrome (`setZonePlacement`/`_installLayer`) still uses the STORED `zoneWorldFrame`. Since T06 installs live `ZoneLayer`s, their chrome MUST use `CanvasEngine.zoneBounds` over the member frames (ideally route both paths through one shared chrome-layout helper). Add a real-path assertion: an installed `ZoneLayer`'s drawn chrome frame == the adaptive bounds of its members (T05's check asserts only tile frames, so this gap is otherwise invisible to CI).

3. **Confirm storage-shape B across the read-sites.** Group-zone tiles live in `WorkspaceDocument.groupZoneTiles` (T02); the canvas keeps `ZoneLayer`s additively over single-zone storage (T05, "shape B"). As you reroute AppDelegate through `WorkspaceRuntime`, ensure the active zone still drives the ~71 `canvasState.tiles` read-sites and group-zone tiles come from the workspace store. If a uniform per-layer store is genuinely required, STOP and flag needs-human rather than silently refactoring all 71 sites.

If any one truly cannot be done within T06's scope, implement the other two, add a pending/failing guard + a clear needs-human note for the deferred one in build.md, and say so — do not silently skip.

## Exact scope — files & symbols
- **`Sources/ContinuumRevived/App/WorkspaceRuntime.swift`** (NEW, `@MainActor final class`):
  - Owns: `private(set) var document: WorkspaceDocument`, the `ZoneRuntimeRegistry` (T04),
    the `ZoneHydrationOrchestrator` (T03), a `weak var canvasView: CanvasNSView?`, the
    shared `FocusBroker`, `RegistryStore`, the active `workspaceId`, and the shared
    engines (`GhosttyRuntimeContext`/`BrowserEngineContext`) handed in at construction.
  - API (shell subset of docs/23's WorkspaceRuntime API):
    - `init(...)` taking the collaborators (see Data/API below).
    - `func install(document:registry:into canvasView:) throws` — hydrate the CURRENT
      workspace: for each `ZonePlacement` with a non-nil `projectId`, `registry.acquire`
      its `ZoneRuntimeController` (T04), build the canvas `ZoneLayer` (T05), install the
      layers (`canvasView.setZones(...)`), and re-establish focus scope.
    - `func flushAll()` — flush every live controller's pending saves (delegates to each
      `ZoneRuntimeController.flushPendingSaves()`).
    - `func closeAll()` / teardown — release every acquired controller via
      `registry.release(projectId:)` (ref-count → close-at-zero), unregister each layer's
      focus adapters from the broker, clear the canvas zone set.
    - `var activeController: ZoneRuntimeController?` — the controller for the active
      zone's project, the **proxy seam** AppDelegate's existing `runtimes` / `projectStore`
      / `activeProject` computed properties read through (see below).
  - `static func runWorkspaceRuntimeInstallSelfCheck() throws -> URL` — the guarding check
    (below). Lives here (not on AppDelegate) because it constructs a `WorkspaceRuntime`
    directly and asserts on its observable state; it must still reach AppDelegate-private
    pieces only via public/internal seams, so if it needs AppDelegate-private wiring put a
    thin `static func` on `AppDelegate` that calls into it (mirror `runAddZoneSelfCheck`).
- **`Sources/ContinuumRevived/App/ContinuumApp.swift`** — replace the single
  `private var zoneRuntimeController: ZoneRuntimeController?` field (`:995`) with
  `private var workspaceRuntime: WorkspaceRuntime?`, and repoint the existing proxy
  accessors so the diff is mechanical:
  - `runtimes` / `browserRuntimes` / `noteViews` / `fileTreeViews` computed props
    (`:974`–`:989`) → read/write through `workspaceRuntime?.activeController?.…` instead of
    `zoneRuntimeController?.…`.
  - `projectStore` (`:996`), `activeProject` (`:997`) → `workspaceRuntime?.activeController?.…`.
  - `applicationDidFinishLaunching` (`:1045`+): the inline "acquire controller → build
    canvasView → attachUI → install tiles" block stays, but the controller it builds is
    handed to `workspaceRuntime` to own (registry-acquired), and the post-build zone-layer
    install routes through `workspaceRuntime.install(...)`. Keep the change surgical:
    construct `WorkspaceRuntime`, give it the controller + canvas + collaborators, and have
    AppDelegate read the active controller back through `workspaceRuntime.activeController`.
  - Every other `zoneRuntimeController?.…` **production** call site (`flushPendingSaves`,
    `attachUI`, `onBrowserRuntimeHydrated`, `close`/`= nil` on quit, the `schedule*Save`/
    `flush*Save` group `:3215`–`:3243`, `paletteRows` `:2571`, `:1727`/`:2563`/`:2579`/
    `:3249`, the relaunch-path `flushPendingSaves` calls `:2904`/`:2932`/`:2953`/`:2993`/
    `:3017`, etc.) → route through `workspaceRuntime` (its `flushAll()` / `closeAll()` /
    `activeController`). Grep `zoneRuntimeController` and repoint EVERY hit.
  - **The four self-check harness assignments are NOT exempt and need a precise rewrite, not
    a repoint.** `delegate.zoneRuntimeController = ZoneRuntimeController(...)` /
    `navApp.zoneRuntimeController = …` appear at `:3635` (`runAgentStatusBadgeSelfCheck`),
    `:5652` (`runPaletteBrowserSpawnSelfCheck`), `:5737` (`runSpawnFocusPolicySelfCheck`),
    `:6403` (the nav-mode self-check harness). After the field rename these stop compiling
    (the `zoneRuntimeController` field is gone). Each must become
    `delegate.workspaceRuntime = WorkspaceRuntime(boot: <that same controller>, …)` (the
    single-controller convenience init below — same wrap the production boot path does at
    `:1055`–`:1056`). Do **NOT** restructure those checks' setup beyond this one-line swap,
    and do **NOT** change what they assert — they are other tasks' checks (`--agent-status-check`,
    `--palette-browser-spawn-check`, `--spawn-focus-policy-check`, the nav-mode check) and
    their behavior-neutrality is part of T06's "matrix stays green" gate. After the rewrite,
    `grep zoneRuntimeController` returns ZERO (the symbol no longer exists anywhere).
- **`Sources/ContinuumRevivedCore/`** — if a pure install/teardown plan helps (which
  projectIds to acquire/release for the current document), put it in a small pure helper
  with its own Core table. Likely NOT needed for the shell (the document IS the plan); add
  one only if the install order/dedupe logic is non-trivial. Keep AppKit out of Core.

### Do NOT touch / out of scope
- **`switchWorkspace` / cross-workspace swap** = T09. Do NOT add `switchWorkspace(to:)`,
  do NOT remove `switchWorkspaceAndRelaunch` (`:2942`) / `relaunchApplication` (`:3025`) /
  `createWorkspaceAndRelaunch` (`:2890`) here — T09 retires those. They keep calling their
  current relaunch path; T06 only changes who owns the *current* live zone set.
- **`BrowserRuntimeBudget` move into WorkspaceRuntime** = T07 (S5). The
  `browserRuntimeBudget` field + `enforceBrowserRuntimeBudget` stay on AppDelegate for now.
- **`addZone` spinning a real controller for added/group zones** = T08 (S6). `addProjectZone`
  (`:2961`) keeps its current persist-only behavior; T08 makes it spin a controller through
  WorkspaceRuntime. Do NOT make group zones (`projectId == nil`) acquire anything here.
- **Viewport-driven tier transitions** = T10 (S8). No `onViewportChanged`/`reconcileHydration`
  here.
- **The window-scoped NSEvent monitors stay on AppDelegate** (ADR-0024) —
  `installHotkeyMonitor` (`:1746`), `installTileFocusMonitor` (`:1790`),
  `installCanvasGestureMonitors` (`:1835`) and the `hotkeyMonitor`/`flagsMonitor`/
  `tileFocusMonitor`/`canvasScrollMonitor`/`canvasMagnifyMonitor` fields. Do NOT move them
  into `WorkspaceRuntime`.
- Do NOT over-refactor `AppDelegate`: proxy the zone ops only. No reformatting, no
  renaming of unrelated members, no touching the leader/snap/palette/settings paths.
- `CanvasEngine` transforms; the leader nav.

## Data / API changes
New file `WorkspaceRuntime.swift`. The collaborator shapes for T03/T04/T05 are **defined by
those tasks**; this spec uses their docs/23-planned names. If a name/signature differs when
T03–T05 land, adapt the proxy — the *observable assertions* below are the contract, not the
internal symbol names.

```swift
@MainActor
final class WorkspaceRuntime {
    private(set) var workspaceId: UUID
    private(set) var document: WorkspaceDocument
    private let registry: ZoneRuntimeRegistry          // T04
    private let orchestrator: ZoneHydrationOrchestrator // T03
    private let focusBroker: FocusBroker
    private let registryStore: RegistryStore
    private weak var canvasView: CanvasNSView?
    // shared engines injected so acquired controllers can hydrate
    private let ghostty: GhosttyRuntimeContext?
    private let browserEngine: BrowserEngineContext

    /// The controller whose project owns the active zone (document.lastActiveZoneId →
    /// its projectId). nil when the active zone is a group zone or none is active.
    /// The proxy seam AppDelegate reads runtimes/projectStore/activeProject through.
    var activeController: ZoneRuntimeController? { ... }

    init(
        workspaceId: UUID,
        document: WorkspaceDocument,
        registry: ZoneRuntimeRegistry,
        orchestrator: ZoneHydrationOrchestrator,
        focusBroker: FocusBroker,
        registryStore: RegistryStore,
        ghostty: GhosttyRuntimeContext?,
        browserEngine: BrowserEngineContext
    )

    /// Install the CURRENT workspace's zone set into the canvas: acquire one
    /// controller per distinct projectId via the registry (ref-counted), build a
    /// ZoneLayer per placement (T05), setZones on the canvas, re-establish focus.
    func install(into canvasView: CanvasNSView, registry: Registry) throws

    func flushAll()
    func closeAll()

    /// Convenience wrap for an ALREADY-BUILT boot controller (the production
    /// `applicationDidFinishLaunching` path at ContinuumApp.swift:1055–1056, and the four
    /// existing self-check harnesses that today set `delegate.zoneRuntimeController`
    /// directly). Registers `controller` in the registry so its ref-count is consistent
    /// (NOT a parallel instance — see the boot-controller gotcha), sets `activeController`
    /// to it, and adopts a minimal single-project `document`. Distinct from `install(...)`,
    /// which hydrates an N-zone document from disk. This is the seam that keeps the rename
    /// mechanical for both the boot path and the harnesses without restructuring them.
    convenience init(
        boot controller: ZoneRuntimeController,
        registry: ZoneRuntimeRegistry,
        focusBroker: FocusBroker,
        registryStore: RegistryStore,
        ghostty: GhosttyRuntimeContext?,
        browserEngine: BrowserEngineContext
    )
}
```

On `AppDelegate` (`ContinuumApp.swift`): `private var zoneRuntimeController:
ZoneRuntimeController?` → `private var workspaceRuntime: WorkspaceRuntime?`. The four
computed proxy props (`runtimes`/`browserRuntimes`/`noteViews`/`fileTreeViews`) and
`projectStore`/`activeProject` re-source from `workspaceRuntime?.activeController`. No new
public Core types expected.

**Configurable-first:** T06 is a SHELL and introduces **no new binding/threshold/default**.
The runtime budget (`BrowserRuntimeBudget.resolveMaxLive`, already
`UserDefaults`-configurable) stays where it is until T07; the group-zone ambient cwd default
arrives with T08; tier thresholds with T10. If implementation surfaces a genuinely new
tunable (e.g. a teardown-grace flag), it MUST ship its persisted `UserDefaults` default +
`SettingsSchema` entry + conflict-guard in this task — but the expectation is **none**, and
the spec flags introducing one as scope creep to reject.

## The check, written FIRST (the spec-as-test) — `--workspace-runtime-install-check`
**Distinct from `--workspace-switch-check`** (that name + `runWorkspaceSwitchSelfCheck`
already exist at `ContinuumApp.swift:75` / `:3946` and are OWNED by T09 — do NOT reuse or
overwrite them). Register the NEW check:
- in `scripts/run-matrix.sh` (add a `run_app_check .build/debug/continuum-revived
  --workspace-runtime-install-check` line near the other zone checks ~`:106`–`:108`).
- in the `CommandLine.arguments.contains(...)` dispatch in `ContinuumApp.swift` (~`:75`+,
  next to the `--workspace-switch-check` block), calling
  `WorkspaceRuntime.runWorkspaceRuntimeInstallSelfCheck()` (or an AppDelegate thin wrapper
  if it needs AppDelegate-private wiring, mirroring `runAddZoneSelfCheck`).

Model the body on `ZoneRuntimeController.runSaveIsolationSelfCheck` (real lifecycle, real
stores on disk, observable assertions). It must drive the **real `WorkspaceRuntime`
lifecycle** — construct one and call `install(...)` / `flushAll()` / `closeAll()`; it must
NOT hand-assemble the zone set or call a pure planner and assert on that.

**Setup (deterministic, fixed UUIDs, temp dirs):**
- A temp app-support dir + two project roots `Pa` and `Pb` on disk (each a real
  `ProjectStore` with a saved `Project` + a seeded `CanvasState` containing one note tile,
  so a controller has something to own — note tiles need no live PTY/WebView, keeping the
  check headless and fast; mirror `seedProject` in `runSaveIsolationSelfCheck`).
- A `Registry` (saved via `RegistryStore`) with one workspace `W` whose `projectIds ==
  [Pa, Pb]`, `lastActiveWorkspaceId == W`, `lastActiveProjectId == Pa`.
- A `WorkspaceDocument` for `W` (saved via `WorkspaceStore`) with **two project zones**:
  `zoneA → Pa` and `zoneB → Pb` (distinct `projectId`s, exercises N>1 zones),
  `zoneZOrder == [zoneA, zoneB]`, `lastActiveZoneId == zoneA`, a non-origin
  `viewport == (x:50, y:60, zoom:1)`.
- A real `CanvasNSView`, a real `FocusBroker`, a real `BrowserEngineContext`
  (`defer { browserEngine.shutdown() }`), `ghostty: nil` (note tiles don't need it),
  a `ZoneRuntimeRegistry` (T04) and `ZoneHydrationOrchestrator` (T03).
- Construct the `WorkspaceRuntime(workspaceId: W, document:, registry:, orchestrator:,
  focusBroker:, registryStore:, ghostty: nil, browserEngine:)`.

**Act:** call the REAL `runtime.install(into: canvas, registry:)`.

**Assertions (every one hand-derivable):**
1. **Live zone set matches the document.** `canvas`'s installed zone-layer set (the T05
   accessor, e.g. `canvas.zoneLayerIds` / `canvas.installedZoneIds`) ==
   `[zoneA, zoneB]` (document order), no extra, none missing.
2. **One controller per distinct projectId, acquired via the registry.**
   `registry.refCount(for: Pa) == 1` and `registry.refCount(for: Pb) == 1` (T04
   introspection); the registry holds exactly two controller boxes
   (`registry.liveProjectIds == Set([Pa, Pb])`).
3. **Acquired controllers are the registry's instances, not freshly built.**
   `runtime.controller(for: Pa) === registry.controller(for: Pa)` (identity, `===`) — the
   runtime did NOT new up its own controller bypassing the registry.
4. **`activeController` resolves through `lastActiveZoneId`.**
   `runtime.activeController === registry.controller(for: Pa)` (active zone is `zoneA`,
   whose project is `Pa`), and `runtime.activeController?.project.id == Pa`.
5. **Canvas layers carry the right placements.** The layer for `zoneA` has
   `placement.projectId == Pa` and `placement.origin`/`size` equal to the document's
   `zoneA` placement; same for `zoneB`/`Pb` (proves the document drove layer construction,
   T05 frames are zone-local→world via CanvasEngine — assert placement, not screen px).
6. **Focus scope is sane.** After install, `focusBroker.activeSurface` is one of:
   `.tile(<a tile in the active zone>)` (if the active project's canvas has a
   last-active/first tile) or `.canvas` — and is **not** `nil` and **not** a `.modal`.
   Concretely: seed `Pa`'s `CanvasState.lastActiveTileId = <noteA tileId>`, then assert
   `focusBroker.activeSurface == .tile(noteA)` (the active zone's stored focus is restored).
7. **Active-zone tile adapters are registered with the broker.** Probe through the real
   broker: `focusBroker.requestFocus(.tile(noteA), reason: .userClick) == true`
   (registered → focusable). A tile id NOT installed (a random UUID) returns `false`.
8. **Save isolation holds across the live set.** Capture `Pb`'s on-disk canvas bytes +
   mtime before; mutate `Pa`'s canvas + `runtime.flushAll()`; assert `Pa`'s canvas was
   rewritten (its change persisted) AND `Pb`'s canvas bytes + mtime are **unchanged**
   (per-controller dirty tracking survives multi-zone — the `--zone-save-isolation-check`
   invariant, re-proven through `WorkspaceRuntime.flushAll`). Sleep `>1s` between the
   baseline read and the flush so mtime granularity can't hide a spurious rewrite (mirror
   `Thread.sleep(forTimeInterval: 1.1)` in `runSaveIsolationSelfCheck`).
9. **Teardown releases every controller and unregisters its adapters.** Call
   `runtime.closeAll()`; assert `registry.refCount(for: Pa) == 0` and `... Pb == 0`
   (ref-count → released), `registry.liveProjectIds.isEmpty`, the canvas zone-layer set is
   empty, and the broker no longer focuses `noteA`
   (`focusBroker.requestFocus(.tile(noteA), reason: .userClick) == false` — adapter
   unregistered). This proves the shell leaves no residue, the precondition T09's swap
   relies on.
10. **No relaunch.** A relaunch spy seam (inject a closure / flag for any relaunch hook the
    shell might touch) is **never called** during install/flush/teardown — T06 is fully
    in-process. (If the shell genuinely touches no relaunch path, assert this by
    construction in a comment and via the absence of `relaunchApplication` in the
    WorkspaceRuntime file; prefer the spy if any seam exists.)

Write the manifest JSON to `qa-runs/<ts>/workspace-runtime-install/manifest.json` (mirror
the other checks) recording each asserted value.

**RED:** with `WorkspaceRuntime` absent (and T03/T04/T05 collaborators present from their
tasks), the check fails to compile (missing `WorkspaceRuntime`) — acceptable model-RED. The
**behavioral** RED is assertions 2/3/9 (ref-count + identity + teardown) and 8 (isolation
through `flushAll`): they fail until `install`/`closeAll` actually route through the
registry and `flushAll` fans out per-controller. Implement to GREEN.

## Implementation steps
1. **Confirm deps Done:** T03 (`ZoneHydrationOrchestrator`), T04 (`ZoneRuntimeRegistry`
   with `acquire`/`release`/`refCount`/`controller(for:)`/`liveProjectIds` introspection),
   T05 (mutable `CanvasNSView`: `setZones`/`upsertZoneLayer`/`removeZoneLayer` + a
   `ZoneLayer`/installed-zone-id accessor). If any introspection the check needs is absent
   on the T04 registry or T05 canvas, **stop and flag** (those are upstream task APIs, not
   ours to invent) — see Out of scope NEEDS-HUMAN.
2. Write `--workspace-runtime-install-check` with all 10 assertions; register it in
   `run-matrix.sh` + the `ContinuumApp.swift` dispatch. Run → RED.
3. Create `WorkspaceRuntime.swift` with the API above. `install`: dedupe the document's
   project zones by `projectId`, `registry.acquire` each, build a `ZoneLayer` per placement
   via T05, `canvas.setZones(layers)`, then restore focus to the active zone's stored
   last-active tile (`focusBroker.enterScope(.tile(id), reason:)`) or `.canvas`.
   `flushAll`: fan out `flushPendingSaves()` to every live controller. `closeAll`:
   `registry.release` each acquired projectId, clear the canvas zone set (which unregisters
   adapters via T05's `removeZoneLayer`/`detachFocusBroker` path), drop references.
4. In `ContinuumApp.swift`: rename the field to `workspaceRuntime`; build the runtime in
   `applicationDidFinishLaunching` from the already-acquired startup controller + canvas +
   collaborators; repoint the four computed proxies + `projectStore`/`activeProject` +
   every other `zoneRuntimeController?.…` call site through `workspaceRuntime`. Grep to
   confirm ZERO `zoneRuntimeController` references remain.
5. `swift build` → run the single check → GREEN.
6. Run the **full** matrix (NOT just `--fast` — this is the heaviest delegate touch):
   `./scripts/run-matrix.sh`. Specifically confirm `--focus-broker-activation-check`,
   `--zone-save-isolation-check`, `--single-zone-compat-check`, `--multi-zone-render-check`,
   `--zindex-relaunch-hit-test-check`, `--add-zone-check`, and the existing
   `--workspace-switch-check` (T09's, untouched) all stay green.
7. Self-review against Acceptance + Review rubric. Commit (plain message, no footer):
   `refactor(runtime): WorkspaceRuntime shell — AppDelegate proxies zone ops (S4)`.

## Acceptance criteria
- [ ] `WorkspaceRuntime.swift` created; owns the current workspace's document + registry +
      orchestrator + canvas; exposes `install`/`flushAll`/`closeAll`/`activeController`.
- [ ] `AppDelegate.zoneRuntimeController` field replaced by `workspaceRuntime`; all proxy
      accessors + every call site repointed; zero `zoneRuntimeController` references remain.
- [ ] `--workspace-runtime-install-check` registered in `run-matrix.sh` AND the
      `ContinuumApp.swift` arg dispatch; all 10 assertions pass through the REAL
      `WorkspaceRuntime` lifecycle (no hand-assembled zone set, no pure-planner bypass).
- [ ] Ref-count correctness asserted by registry introspection (refCount 1 after install,
      0 after teardown) AND controller identity (`===` the registry's instance).
- [ ] Save isolation re-proven through `flushAll` (Pa rewritten, Pb byte+mtime unchanged).
- [ ] Focus scope restored to the active zone's tile (broker `requestFocus` probe), adapters
      unregistered after `closeAll`.
- [ ] No `switchWorkspace`, no budget move, no addZone-spins-controller, no tier transitions
      (those are T07/T08/T09/T10); relaunch paths left intact; monitors stay on AppDelegate.
- [ ] No new tunable introduced (or, if unavoidable, it ships default+Settings+conflict-guard).
- [ ] Full matrix green; existing `--workspace-switch-check` untouched and green.

## Verification commands
```sh
swift build
P=$(mktemp -d); A=$(mktemp -d); CONTINUUM_PROJECT_ROOT=$P CONTINUUM_APP_SUPPORT=$A \
  .build/debug/continuum-revived --workspace-runtime-install-check; rm -rf "$P" "$A"
# regression-sensitive neighbours (the brief's named guards):
P=$(mktemp -d); A=$(mktemp -d); CONTINUUM_PROJECT_ROOT=$P CONTINUUM_APP_SUPPORT=$A \
  .build/debug/continuum-revived --focus-broker-activation-check; rm -rf "$P" "$A"
P=$(mktemp -d); A=$(mktemp -d); CONTINUUM_PROJECT_ROOT=$P CONTINUUM_APP_SUPPORT=$A \
  .build/debug/continuum-revived --zone-save-isolation-check; rm -rf "$P" "$A"
./scripts/run-matrix.sh          # full matrix (NOT --fast): heaviest delegate touch
```

## Review rubric (adversarial)
- **Bypass audit (critical):** does the check construct a `WorkspaceRuntime` and call its
  REAL `install`/`flushAll`/`closeAll`, or does it hand-build the zone-layer set / call the
  T03 planner or T04 registry directly and assert on that? A green check that never calls
  `WorkspaceRuntime.install` proves nothing — REWORK. Trace each assertion back to a
  WorkspaceRuntime method.
- **Ref-count by introspection, not a dict peek:** assertion 2/9 must read the T04
  registry's ref-count (`refCount(for:)` → 1 then 0), and assertion 3 must compare
  controller **instances** (`===`). "Removed from a dictionary" is not "released".
- **Save isolation is the regression magnet:** assertion 8 must capture Pb's bytes **and**
  mtime before, sleep >1s, then flush Pa and confirm Pb is byte-identical with an unchanged
  mtime — re-prove `--zone-save-isolation-check`'s invariant *through* `flushAll`, not by
  calling a single controller. If it only flushes Pa's controller directly, it doesn't test
  the fan-out.
- **Focus probe, not a stored field:** assertion 6/7 must probe the broker
  (`requestFocus` returns true for a live active-zone tile, false for an uninstalled id and
  false after teardown) — reading `activeSurface` alone can pass even if adapters were never
  registered. Teardown (assertion 9) must show the adapter is gone.
- **Diff vs scope:** every `zoneRuntimeController` reference repointed (grep returns zero);
  no `switchWorkspace`/relaunch removed; no budget/addZone/tier behavior added; monitors
  untouched; no reformatting of adjacent code; no co-author footer.
- **Behavior-neutral:** does the existing matrix still pass unchanged? The single-zone
  compat / multi-zone-render / focus-broker / save-isolation checks are the neutrality
  proof — any of them flipping means the proxy changed behavior, not just ownership.
- Would the check go RED if `install` skipped the registry (newed controllers itself) or
  `closeAll` forgot to release? Mentally revert one line of each and confirm a failing
  assertion.

## Out of scope / gotchas
- **NEEDS-HUMAN (dependency-API seam):** `WorkspaceRuntime` composes types **defined by
  T03/T04/T05, which are not yet in `Sources/` at spec-authoring time** (Wave 1/2 land
  before this Wave-3 task). This spec uses docs/23's planned names —
  `ZoneRuntimeRegistry.acquire/release(projectId:)`, a ref-count/identity introspection
  (`refCount(for:)`/`controller(for:)`/`liveProjectIds`), `ZoneHydrationOrchestrator`, and
  `CanvasNSView.setZones`/`upsertZoneLayer`/`removeZoneLayer` + a `ZoneLayer`/installed-zone
  accessor. **The executing agent must, before implementing, confirm T03/T04/T05 shipped
  these exact seams** (especially the T04 registry introspection assertions 2/3/9 read and
  the T05 installed-zone-id accessor assertion 1 reads). If a needed introspection is
  missing, that is an upstream-task gap — do NOT invent it on `WorkspaceRuntime`; flag to the
  orchestrator so T04/T05 expose it (or this check's assertion is renegotiated). The
  *observable contract* (assertions 1–10) is fixed; the internal symbol names may adapt.
- Today `CanvasNSView` has **immutable** `let activeZone` / `let zoneRenderModels`
  (`CanvasNSView.swift:67-68`); T05 makes the zone set mutable. T06 cannot install N zones
  until T05 lands — confirm it has.
- `--workspace-switch-check` (`ContinuumApp.swift:75`, `runWorkspaceSwitchSelfCheck` `:3946`)
  already exists and is **T09's**, exercising the picker/registry/render-model derivation —
  do NOT touch or repurpose it; T06's check is the new, distinct
  `--workspace-runtime-install-check`.
- The startup controller in `applicationDidFinishLaunching` is built before the
  registry/runtime exist today (`presentLockContentionUXIfNeeded` → `ZoneRuntimeController`
  at `:1055`). Keep that acquisition; just hand the controller to `WorkspaceRuntime` so the
  registry ref-counts it (so a later `addZone`/`switchWorkspace` sees a consistent count).
  This is the subtle bit: the boot controller must be **registered in the registry**, not a
  parallel instance — otherwise assertion 2's count is off-by-one in production. The check
  exercises the registry path directly; the production wiring must match it.
- Coordinate trap: assert zone **placements** (world `origin`/`size`, zone-local), NOT
  screen-px frames — T05 frames scale by zoom via `CanvasEngine.worldFrame(tile:in:)`.
- Stale SourceKit "cannot find WorkspaceRuntime / setZones in scope" diagnostics are noise
  until `swift build`; the build is authoritative.
- `[overnight]` task: commit when its check + full matrix are green. No `[morning]` visual
  gate is strictly required for the shell (it's behavior-neutral), but if the proxy rename
  touches the live focus path, a quick rebuilt-bundle smoke (open app, click a tile, confirm
  focus border) is a cheap sanity check before T09 builds on it.
