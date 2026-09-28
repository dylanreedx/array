# O4: making Array trustworthy for power use (cross-cutting assessment and plan)

Base read: `array/integration` @ `1451c030` (0.7.21 build 72, published). Everything below comes from reading the source. I ran no check legs and launched no app.
Line numbers are against that commit. Where I say a thing is *reachable*, I traced the call chain.
Where I say *hypothesis*, I did not.

---

## 1. Structural diagnosis

### 1.0 The short answer

Complaints 2, 3 and 4 share a root, and it is not one bug. **The same facts have more than one owner, and the owners drift apart whenever the hydration tier, a debounce timer or a workspace switch separates them.**
The dual canvas model is part of it. By itself it is not the root. There are three families of multi-owner facts:

| Fact | Owners today | Complaints |
|---|---|---|
| WorkspaceDocument (zone name, Home binding, geometry, armed zone) | `WorkspaceRuntime.document` in memory, plus **four independent disk writers** with separate save controllers, two of which load from disk and push the result back into memory | 2, 4 |
| A zone's *placement* on the canvas | `liveZones`, `ZoneLayer.placement`, `zoneRenderModels`, `zoneDisplayByZoneId`, each written by a different subset of mutators, and read with **opposite precedence** in the same file | 2, 4 |
| A zone's *display projection* (name, Home label) | **four builders** with four different fallback rules. Only one of them computes the Home label | 2 |
| Whether a zone has a tile model at all | Layers are installed **only** at mount, at switch and in `_addProjectZone`. A zone that becomes live or armed later gets a controller but never a layer, so its tiles take the retired flat path | 3, 4 |
| A project's `canvas.json` | debounced async writer (controller queue), plus **two synchronous main-thread writers that skip that queue**, plus the flat-fallback writer that saves the *whole flat scene* into whichever project spawned | 4 |

The binding (`lastActiveZoneId` / `setActiveZone` / `activeController`) is mostly sound since `.plans/47`. It matters here because it **arms zones that have no layer** (hazard 9's "tier ≠ controller" fix acquires a controller and stops there). That is the trigger for complaint 3.

### 1.1 Complaint 3 (agent born with "—" Home and an inert selector) has a deterministic, reachable cause

This is the strongest finding.

1. **Boot with a persisted workspace retires the flat scene.** `mountWorkspaceSceneAtBoot` calls `canvasView.retireFlatCompatibilityScene()` and then `runtime.install(into:)` (`ContinuumApp.swift:16209-16210`).
   So `flatCompatibilitySceneActive = false` from the first frame, on every normal launch.
   (Hazard 9 in CLAUDE.md still says `install(into:)` "stays a checks-only entry point". That is stale: production boot calls it.)
2. **`install(into:)` builds layers only for zones planned `.live`** (`WorkspaceRuntime.swift:664-690`). The plan uses `maxLiveZones` (default **4**, `ZoneHydrationBudgetConfig.swift:9`) and the canvas bounds, which fall back to 1280×720 if the view has no size yet (`:666-667`).
   A workspace with more than 4 zones, or zones spread beyond the first viewport, **has layer-less zones by default**.
3. **Nothing installs a layer later.** `reconcileHydration` (`WorkspaceRuntime.swift:1758-1840`) acquires controllers and calls `setTier`, but never builds a `ZoneLayer`.
   `setActiveZone` (`:363-429`) acquires a controller and calls `canvasView.setActiveProjectZone`, which **silently no-ops to nil without a layer** (`CanvasNSView.swift:6484-6494`).
   In production, `upsertZoneLayer` is called only from `_addProjectZone` (`WorkspaceRuntime.swift:908`).
4. **A spawn into that zone takes the flat fallback.** `resolvedCreationScope` resolves the armed zone from the document (`ContinuumApp.swift:15777-15782`). `spawnerForFilesystemCreation` returns that project's spawner (`:15899-15914`).
   `TileSpawner.spawnManagedAgent` frames with `installedZonePlacement` (nil), so the frame is world. `installProjectTile` finds no layer and falls through to `install(tileView:for:)` (`CanvasNSView.swift:6805-6819`), which appends to the flat `canvasState.tiles` and `tileViews` (`:2161-2190`).
5. **`tileView(for:)` hides flat views once the flat scene is retired.** It reads `tileViews` only `if flatCompatibilitySceneActive` (`CanvasNSView.swift:2223-2229`).
   So `wireManagedAgentTile`'s first guard, `guard let view = canvasView?.tileView(for: tileId) as? ManagedAgentTileNSView else { return }` (`ContinuumApp.swift:13453`), returns silently.
   No agent is spawned, `supervisor.attach` never runs, and `onLocationActionMenuRequested` is never bound. The tile renders `applyUnknownCompactStatus()` → `"—"` (`ManagedAgentTileNSView.swift:1762-1780`), and its Home chip's handler bails on `projectedAgentID == nil` (`:354`).
6. **Why a restart, or recreating the zone, clears it.** After a restart the armed zone is `focusedTileZone` in the plan, so it is pinned live and gets a layer. Recreating the zone goes through `_addProjectZone`, which does `upsertZoneLayer`.
   Both give the zone the layer it lacked. The already-broken tile is not healed: `hydrateRuntimeBackedTiles` skips a tile with no record (`ContinuumApp.swift:16482-16485`).
7. **Wake (hypothesis).** There is no sleep/wake observer anywhere in `Sources/ContinuumRevived`. The likeliest route: a display reconfiguration after wake changes bounds or viewport, `canvasDidChange` → `reconcileHydration` → `cameraArmedZone` arms a different, layer-less zone, and the next spawn reproduces step 4. Mark this unverified.

**There is a second, independent way to reach the same "—" symptom.** Suppose a layer exists and the tile is found. `guard let spawnedAgentID = spawned else { return }` (`:13515`) still silently aborts when the creation-scope memo is not found *and* `activeProject` is nil. `activeController` returns nil for an armed zone whose controller failed to acquire (`WorkspaceRuntime.swift:69-90`).
The scope is re-resolved three separate times on the way: at palette entry (`ContinuumApp.swift:13296`), in `TileSpawner.spawnManagedAgent` (`TileSpawner.swift:1525`), and at wire time from the memo (`ContinuumApp.swift:13497-13500`). Three resolutions give three chances to disagree.

**Collateral damage from the same path (complaint 4).** The flat fallback returns `.flatCanvasState`. `TileSpawner.persistProjectCanvas` then does `projectStore.saveCanvas(canvasView.canvasState)` (`TileSpawner.swift:2419-2421`).
After retirement, `canvasView.canvasState` is still **the boot project's flat scene** (retire clears views and indexes but keeps the model: `CanvasNSView.swift:6305-6328`). So spawning into project B's layer-less zone **overwrites B's `canvas.json` with project A's tiles plus the new tile**.
On the next mount, `membership(forProject:)` finds A's tiles in B's file stamped with A's zone. `resolveZoneMembership` then rescues or defers them. The result is duplicated tiles, tiles in the wrong zone, and tiles outside a zone's rect while still members.
This is hazard 10's "last writer wins" inside a single process.

### 1.2 Complaint 2 (names and Home bindings "revert") has two halves

**Half A: display projection. This one is deterministic.** Four builders make the zone chrome's model, each with its own rules:

| Builder | Name fallback when `zone.name` is empty | Home `scopeLabel` |
|---|---|---|
| `AppDelegate.zoneRenderModels` (`ContinuumApp.swift:17344-17367`), compat boot only | registry project name | **computed** (`"Proj / sub"`, `"Needs Project"`) |
| `WorkspaceRuntime.install` (`WorkspaceRuntime.swift:725-744`), every persisted launch | registry name, then controller name | **nil** |
| `WorkspaceRuntime.switchWorkspace` (`:1579-1580`) | `controller.project.name` | **nil** |
| `WorkspaceRuntime.zoneRenderModels` for non-live zones (`:628-641`) | the literal `"Zone"` | **nil** |

`scopeLabel` is set live only by `commitProvisionalZone` and `setZoneScope` (`CanvasNSView.swift:990, 1036`). After **any** relaunch or switch, every zone's Home label is therefore gone from the header and from the zone context menu (`:5719`), even though the document still has `projectId`/`homeRelativePath`. To the user, the binding has reverted.
An unnamed zone below the live tier is renamed "Zone" by the switch.

**Half B: storage. Several writers, and one of them pushes disk back into memory.**

- (a) `WorkspaceRuntime.saveWorkspaceDocument` (`WorkspaceRuntime.swift:1433-1446`) builds a **fresh** `WorkspaceDocumentSaveController` for every synchronous save.
- (b) `setActiveZone` persists `.focus/.click/.camera` arming through a long-lived `armingSaveController` (`:346, 420-427`). `scheduleZoneLayoutSave` stores `pendingDocument` **as a struct snapshot** and writes it 200 ms later (`WorkspaceDocumentSaveController.swift:39-70`; `AutosaveConfig.defaultDebounceMs = 200`). Nothing cancels or refreshes that snapshot when (a) writes. A sync write that lands inside the window (rename, create, Change Home, close) is overwritten on disk by the older snapshot.
- (c) `persistLayoutTransaction` (`ContinuumApp.swift:14663-14750`), which runs on **every committed drag/resize/tidy**, calls `store.load()` from **disk**, applies the transaction, saves through a third controller, and then calls `workspaceRuntime?.replaceDocument(document, …)` (`:14742`). Disk state is pushed over the runtime's in-memory truth. The comment on `commitZonePlacement` forbids exactly this: "No reload is permitted here… re-reading disk would race other live zone mutations" (`WorkspaceRuntime.swift:105-108`).
- (d) `persistLastExplicitCreationScope` (`ContinuumApp.swift:14952-14971`) runs on every Home pick and does the same load → save → `replaceDocument`.
- (e) The fallback branches of `persistClosedZone`, `persistCreatedGroupZone`, `persistMovedZone` and `persistRenamedZone` (`:14539-14790`) also load from disk with fresh controllers. `workspaceRuntime` is non-nil after boot, so they should be dead, but nothing asserts that.

How these compose into a revert: (b) leaves stale content on disk, then (c) or (d) loads it back into memory. The terminate flush (`flushMountedWorkspaceState`, `WorkspaceRuntime.swift:798-808`, called at `ContinuumApp.swift:16713`) then faithfully persists the reverted memory.
The window for (b) is 200 ms, so this half is narrow per event. It is frequent in aggregate, though: camera arming fires on every pan settle. **It is a design defect regardless of how often it bites**, and it is the one Half A would otherwise mask.

**Half C: placement precedence.** `persistDepartingWorkspaceState` (`WorkspaceRuntime.swift:1861-1866`), which runs on every switch and every quit, overwrites `document.zones` from `canvasView.workspaceZonePlacementsForPersistence()`. That is `allZonePlacements()`, and it is **layer-first** (`CanvasNSView.swift:2570-2584`).
The zone header menu reads **liveZones-first** (`:5714-5716`). Any mutator that writes one copy and not the other decides which value survives a switch. See 1.3.

### 1.3 Complaint 4 (tiles shift, zones overlap, members outside the rect) comes from the same families

1. **`growZoneToFitMembers` writes `liveZones` only** (`CanvasNSView.swift:1954-1979`, write at `:1977`), then emits `onZoneMoved` with the grown rect, so the document gets the grown rect.
   The layer keeps the old placement. At the next switch or quit, `persistDepartingWorkspaceState` takes the **layer's** stale rect (layer-first) and writes it over the grown one.
   The zone shrinks back and the tiles that caused the growth now sit outside it while still members. `growZone` (`:1888-1941`) does write both copies. The two siblings disagree.
2. **Dragging or resizing a layer-less zone moves chrome, not members.** The non-layer drag branch translates `canvasState.tiles` where `tileZoneMembership == zoneId` (`CanvasNSView.swift:6013-6025`). After retirement that is the boot project's stale flat scene, and `tileZoneMembership` holds only layer tiles (rebuilt in `setZones`, `:6275-6277`).
   The zone's real tiles stay at their old world frames in `canvas.json`. On the next mount they draw outside the moved zone while still stamped members.
3. **Flat fallback cross-project write** (1.1 above). Foreign tiles get rescued into zones by geometry.
4. **Two unserialized `canvas.json` writers.** `ZoneRuntimeController.flushCanvasSaveOffMain` snapshots on main and writes asynchronously on `canvasSaveQueue` (`ZoneRuntimeController.swift:690-701`). `persistLayoutTransaction` (`ContinuumApp.swift:14718-14722`) and `TileSpawner.persistProjectCanvas` (`TileSpawner.swift:2415-2443`) write **synchronously on main, bypassing that queue**.
   A debounced snapshot taken before a drag commit can land after it and put pre-drag frames back. The window is small, but every pan schedules a canvas save, so over time it hits.
5. **Growth has no neighbour policy.** `growZone`/`growZoneOnSpawn` expand into siblings unconditionally, and `appendProjectZone` parks new zones at `maxX + gap` (`.plans/47` "Left open"). Overlap is never checked or persisted-against. This is a product decision, not just a bug (see T6c).
6. **Foreign zones get acquired.** `reconcileHydration` iterates raw `document.zones` (`WorkspaceRuntime.swift:1788`), not `mountableZones`. It can acquire controllers and `.array/lock`s for projects owned by another workspace (the persistence scout's finding in `.plans/65`).
   Once acquired, those project ids sit in `acquiredProjectIds`. A later switch *to* the owning workspace then throws `projectAppearsInBothWorkspaces` (`:1501-1503`). That is an "unstable" symptom with no complaint number yet.

### 1.4 Seams where two owners write the same fact (index)

| # | Fact | Writer 1 | Writer 2 | Effect |
|---|---|---|---|---|
| S1 | workspace doc on disk | `saveWorkspaceDocument` fresh controller (`WorkspaceRuntime.swift:1433`) | `armingSaveController` snapshot (`:420-427`) | stale snapshot overwrites newer write |
| S2 | workspace doc in memory | runtime mutators | `replaceDocument` from a disk load (`ContinuumApp.swift:14742`, `:14971`, fallbacks `14572/14612/14653/14788`) | disk → memory while mounted |
| S3 | zone placement | `liveZones` writers (`CanvasNSView.swift:985-986, 1977, 6021`) | `layer.placement` writers (`:241, 264, 1922`) | layer-first persistence resurrects stale rect |
| S4 | zone display | 4 render-model builders (1.2 table) | none agree | name and Home label change across mount paths |
| S5 | where a tile lives | ZoneLayer (zone-local) | flat `canvasState.tiles` after retirement (`installProjectTile` fallback `:6805-6819`) | invisible to `tileView(for:)`, unwired agent |
| S6 | project `canvas.json` | async debounced queue (`ZoneRuntimeController.swift:697`) | sync main writers (`ContinuumApp.swift:14720`, `TileSpawner.swift:2421, 2435`) | out-of-order last-writer-wins |
| S7 | `canvas.json` of project B | B's layer tiles | boot project's flat scene via `.flatCanvasState` (`TileSpawner.swift:2421`) | cross-project contamination |
| S8 | "which zone for this spawn" | scope at palette (`:13296`) | scope in spawner (`TileSpawner.swift:1525`), memo at wire (`:13497`) | three resolutions, silent abort on disagreement |
| S9 | frame space on spawn | framing falls back to `activeProjectZonePlacement` (`TileSpawner.swift:7893-7894`) | install targets `targetZoneId` (flat if no layer) | zone-local frame stored as world when an explicit target (CX-01 API parent zone) has no layer |

---

## 2. Verification gap

**Why 181–235 green legs missed a daily user's experience.** Hazard 9's lesson was: "checks calling `install(into:)` were green while production never mounted". That lesson was learned for *entry points*. It has recurred one layer down, as *fixture shape* and *assertion horizon*.

1. **Every zone fixture is all-live.** `--zone-arming-check` uses 2 zones on a 2000×1200 canvas (`ZoneArmingChecks.swift:151`). No check source sets `maxLiveZones` (only `WorkspaceRuntime` reads it) or places a zone outside the first viewport.
   The layer-less state behind complaint 3 is **unreachable in the matrix and the default for a power user** with 5+ zones or a spread canvas.
2. **Checks still install layers that production would not.** `ZoneArmingChecks.swift:413` calls `canvas.upsertZoneLayer(...)` for zone B before spawning. This is exactly the `install(into:)` pattern hazard 9 retracted: the check supplies the state the bug removes.
3. **The creation memo is seeded, not produced.** `ZoneArmingChecks.swift:388` calls `qaRememberManagedAgentCreationScope` and asserts the memo is *found*. No leg asserts `agentSupervisor.agent(forTile:)` is non-nil and bound after a real palette spawn into a zone. That outcome is the one the user sees.
4. **Assertions stop at one hop.** "The arming write is durable" (`ZoneArmingChecks.swift:455-462`) flushes immediately after one click, with no intervening sync write, so the two-controller overwrite (S1) cannot occur.
   No leg does mount → mutate → switch → switch back → cold remount → compare. The repo has no round-trip suite at all.
5. **Nothing asserts the header.** No check reads the zone chrome's `scopeLabel`. `qaZoneDisplayName` exists (`CanvasNSView.swift:355`), but I found no use of it after a switch or remount. Half A of complaint 2 is invisible to every leg.
6. **Timing is flushed away.** Legs call `flushPendingArmingSave`/`flushPendingHydrationReconcile` synchronously, which removes the debounce interleavings (S1, S6) that real use produces.
7. **The gate can't see unlanded work, and it carries noise.** The titlebar witnesses (`--window-chrome-check`, `--workspace-top-bar-check`, logs in `.worktrees/topbar-merge/qa-runs/0721-topbar/`) passed on a branch the matrix never runs.
   Nine unowned reds sit outside `MATRIX_KNOWN_RED`. `.plans/66` says `--workspace-switch-polish-check` was registered, but it is **not** in `scripts/run-matrix.sh` at `1451c030` (the flag exists at `ContinuumApp.swift:2224`). A gate with unowned reds and unregistered legs trains everyone to read "mostly green" as green.
8. **Source-text pins still exist** near these paths (e.g. `ContinuumApp.swift:33541-33543` asserts the installer *contains* `wireManagedAgentTile(tile.id)`). Non-negotiable #2 names this pattern as failed.

**Which complaints have zero production-driven witnesses of the failure mode:**

| Complaint | Status |
|---|---|
| 1 Titlebar | **Zero on integration.** Witnesses exist only on the unmerged branch, and nothing checks "the shipped build contains feature X" against the ledger. |
| 2 Name/Home revert | **Zero.** The live rename and boot-persistence legs exist, but none covers switch/remount projection or interleaved writers. |
| 3 Blank Home | **Zero.** No fixture ever has a layer-less armed zone, and the one check that gets close installs the layer itself. |
| 4 Shift/overlap | **Partial.** Ambient frame-space, persistence-model and grow-origin compensation are witnessed. Nothing covers `growZoneToFitMembers`→switch, layer-less zone drag, the writer race or overlap. |

---

## 3. Ticket sequence

The order follows three rules: land the measuring instrument first; land the single-writer change before anything that adds writes; and finish each fix with its case added to the round-trip leg, so every earlier witness keeps running through the later tickets.
One bench per ticket under `.worktrees/<slug>`. Each ticket runs RED on current base, then GREEN, then a full matrix run whose summary prints its leg.

### 3.1 Table

| # | Title | Invariant | Witness leg | Depends | Risk | Release |
|---|---|---|---|---|---|---|
| T0 | `chore(window-chrome): land or drop the titlebar merge branch` | What Dylan believes shipped matches the ledger | `--window-chrome-check`, `--workspace-top-bar-check` registered on integration, plus real fullscreen/drag QA | none | low–med (ContinuumApp conflict with 0721 wsdelete top-bar work) | 0.7.22 |
| T1 | `test(workspace): add the mount-switch-remount round-trip leg` | Harness only: a scene serialized after mount→mutate→switch→back→cold remount equals the pre-switch scene | `--workspace-roundtrip-check` (new) | none | low (checks only) | 0.7.22 |
| T2 | `refactor(workspace-document): route every document write through one owner` | While mounted, `WorkspaceRuntime.document` is the only truth. Memory → disk through ONE controller. Never disk → memory except at mount and switch | `--workspace-document-single-writer-check` (new) + T1 cases | T1 | med–high (all zone persistence), but mechanical | 0.7.22 |
| T3 | `fix(zone-chrome): derive zone name and Home label from one projection` | One builder for every zone render model; project zones always carry a Home label | T1 cases `projection.*` | T1 (T2 recommended) | low | 0.7.22 |
| T4 | `fix(zone-hydration): install a layer whenever a zone goes live or is armed` | An armed or live project zone always has a ZoneLayer. After retirement no spawn takes the flat fallback. Reconcile touches mountable zones only | `--zone-late-hydration-spawn-check` (new) + T1 case | T2 | med–high (perf, hydration) | 0.7.22 |
| T5 | `fix(canvas): give each zone placement a single writer` | `liveZones` and `layer.placement` never diverge; one mutator emits one `onZoneMoved` | `--zone-placement-single-owner-check` (new) + T1 case | T2, T4 | med | 0.7.23 |
| T6a | `fix(canvas-persistence): serialize all canvas.json writes per project` | No `canvas.json` write can land out of generation order; the flat-scene writer is gone | `--canvas-write-order-check` (new) | T4 | med | 0.7.23 |
| T6b | `fix(zone): move a layer-less zone's members with the zone` | Zone move or resize carries members at every hydration tier | T1 case `offscreen-zone-move` | T4, T5 | med | 0.7.23 |
| T6c | `feat(zone-layout): decide and enforce the zone overlap policy` | *Needs Dylan's decision.* Either persisted zones never overlap, or overlap is allowed but never created by growth | leg decided with the policy | T5 | med (touches jelly/auto-layout feel) | 0.7.24 |
| T7 | `fix(agent-tile): refuse loudly when a managed tile cannot bind` | A managed-agent tile either binds an agent or shows a named refusal with a working "Choose Home" action; never a silent "—" | `--managed-agent-bind-or-refuse-check` (new) | T4 | low | 0.7.22 |
| T8 | `chore(matrix): triage the nine unowned pre-existing reds` | Every red leg is fixed, or documented in `MATRIX_KNOWN_RED` with an owner and a reason | matrix summary shows 0 unowned failures | none (parallel) | low | 0.7.22 |
| T9 | `test(matrix): make the round-trip suite a release gate` | Power-use shapes (budget overflow, far zones, seeded random op sequences) round-trip identically; release blocked otherwise | `--workspace-roundtrip-check --stress` | all above | low | 0.7.23 |
| T10 | `docs(claude-md): record the one-writer rules and retire stale hazard text` | CLAUDE.md matches the code | n/a | T2, T4 | none | with T4 |

### 3.2 Per-ticket detail

#### T0 — `chore(window-chrome): land or drop the titlebar merge branch`
- **Facts:** `61416361` on `array/topbar-merge`, based on `2cec73ff`. Integration has moved 24 commits since, including the 0.7.21 workspace-delete fix, which touched the top bar's Delete button and `reloadWorkspaceTopBar`.
  The branch diff is `ContinuumApp.swift +292`, `WorkspaceTopBarView.swift +35`, `run-matrix.sh +4`. Sol APPROVE and focused checks exist. The fullscreen witness invokes callbacks, not real fullscreen, and nobody has proved a window drag works.
- **Invariant:** the ledger and what Dylan sees agree. The feature is either on integration with its legs in the matrix, or explicitly dropped with a note in `docs/VERSIONING.md`.
- **Work:** rebase onto current integration in its existing bench (preserve the original owner's commit). Resolve the top-bar conflicts against the 0.7.21 atomic-delete logic.
  Update the matrix inventory (legs are recorded by literal invocation). Run the preview app for real fullscreen enter/exit and window drag by the merged bar.
- **Witness:** existing legs, registered. Add one outcome assertion to `--window-chrome-check`: after the merge, the window's titlebar accessory contains the workspace bar view *and* the standalone bar view is not in the hierarchy. That is the "still visible" complaint as a check.
  Positive control: the pre-merge base fails that assertion.
- **Files:** `ContinuumApp.swift`, `WorkspaceTopBarView.swift`, `scripts/run-matrix.sh`, matrix inventory.
- **Why first:** it is the largest ContinuumApp diff in flight. Landing it before T2/T4 avoids rebasing both across it. If QA finds fullscreen or drag broken, drop it rather than hold the stability train.

#### T1 — `test(workspace): add the mount-switch-remount round-trip leg` (stability gate spine)
- **Invariant, as a harness:** `Canon(scene)` is the zone ids, names, projectId/homeRelativePath, world rects from `renderedZonesInZOrder`, displayed name and scopeLabel from chrome models, each tile's id, zoneId and *world* frame (from `allTilesInWorldFrames`), agent binding per managed tile, and the bytes of each project's tile id set in `canvas.json`.
  The leg asserts `Canon(after mutate)` == `Canon(after switch A→B→A)` == `Canon(after cold remount from disk)`.
- **Production-driven:** each phase constructs a fresh `AppDelegate` and drives `mountWorkspaceSceneAtBoot` (never `install(into:)` or `upsertZoneLayer`). Mutations go through real routes: `onZoneRenamed`, `presentProjectHomePicker`'s confirm via its QA seam, `qaPerformPaletteAction`, `commitGeometryEdit`, and `setViewport` → `canvasDidChange` for camera.
  Switches go through the production switch entry, and quit goes through `flushMountedWorkspaceState`. The debounce is not flushed by hand: the leg spins the runloop past `AutosaveConfig.debounceInterval` so real interleavings happen.
- **Lands green:** only today's green cases (all-live fixture, rename in a live zone, tile drag in a live zone). The RED cases are written but disabled by a case table with the ticket that enables each one. This is not a KNOWN-RED; the leg itself is green.
- **Positive control, required:** a comparator self-test. Between phases, the leg shifts one tile in `canvas.json` by 1pt and blanks one zone name on disk, then asserts the comparator reports exactly those two diffs. If it doesn't, the leg fails. This is what gives the leg teeth.
- **Isolation:** `CONTINUUM_APP_SUPPORT` temp dir, temp project roots under `/tmp`, suite-named defaults, `orderFrontOffscreenForChecks()`, and no tmux.
- **Files:** new `WorkspaceRoundTripChecks.swift`, a flag in `ContinuumApp.main()` cascade, `run-matrix.sh` (append; don't touch the pinned lines), inventory.

#### T2 — `refactor(workspace-document): route every document write through one owner`
- **Invariant:** while a workspace is mounted, `WorkspaceRuntime.document` is the only source of truth. Every mutation is *mutate in memory → `docSaver.schedule(document)` or `docSaver.flush()`*, and `docSaver` is **one** `WorkspaceDocumentSaveController` owned by the runtime for the mounted workspace.
  A synchronous flush writes the *current* document and supersedes any pending snapshot. Disk is read only in `install` and in `switchWorkspace` for the target.
- **Work:**
  - Replace the per-save controller in `saveWorkspaceDocument` and the separate `armingSaveController` with one controller. Ambient arming = `schedule(document)`, deliberate = `flush()`.
    `scheduleZoneLayoutSave` should retain a *reference to the runtime's current document at fire time*, not a snapshot: re-read `document` in the timer, or pass a closure.
  - Rewrite `persistLayoutTransaction` to mutate `workspaceRuntime.document` via new runtime methods (`commitLayoutTransaction`) and keep its project-canvas rollback.
    Rewrite `persistLastExplicitCreationScope` as `runtime.setLastExplicitCreationScope`.
    Delete the disk-loading fallback branches of the `persist*Zone` functions. Replace them with an `assertionFailure` plus a stderr line if `workspaceRuntime` is nil after boot.
  - Remove `replaceDocument` except for its single legitimate caller (mount/switch). Keep the name out of new code.
- **Witness `--workspace-document-single-writer-check`:**
  1. Arm zone B by `.click` (debounced). Within the window, rename zone A through `applyZoneRename`. Spin past the debounce. Reload disk: A's new name is present.
  2. Change A's Home via the picker seam, then commit a tile drag (drives `onLayoutCommitted`), then flush. Both memory and disk carry the new Home, and `document.lastActiveZoneId` is unchanged by the drag.
  3. A `WorkspaceStoring` spy injected through `_workspaceDocumentSaver` asserts every save's document equals `runtime.document` at the moment of the write, and that save generations are monotonic.
  - Positive control: the same sequence with no interleaving passes on the old code too. The leg records both, so a revert shows as case 1 RED with "stale arming snapshot overwrote rename".
- **Files:** `WorkspaceRuntime.swift`, `WorkspaceDocumentSaveController.swift`, `ContinuumApp.swift` (14539–14975 region).
- **Blast radius:** every zone create/move/rename/close/Home path. Mechanical, but broad. Must land before T3–T6 so their new writes go through one owner.

#### T3 — `fix(zone-chrome): derive zone name and Home label from one projection`
- **Invariant:** one pure function (e.g. `ZoneProjection.renderModel(placement:, registry:)` in App, or Core if registry types allow) is the **only** builder of `ZoneRenderModel`.
  It is used by `AppDelegate.zoneRenderModels`, `install`, `switchWorkspace`, the non-live `zoneRenderModels`, `commitProvisionalZone` and `setZoneScope`. A project zone always has a scopeLabel. The name fallback is one rule, the registry name.
- **Witness:** T1 cases `projection.live`, `projection.nonlive`, `projection.after-switch`, `projection.after-remount`. For a named zone, an unnamed zone, a zone with a subfolder Home and a zone whose project is missing, displayName and scopeLabel are identical across all four phases.
  Positive control: the missing-project zone shows "Needs Project" in every phase (proves the label is read, not defaulted).
- **Files:** `WorkspaceRuntime.swift:621-641, 725-744, 1579`; `ContinuumApp.swift:17344-17367`; `CanvasNSView.swift` (commit/setZoneScope label source). Low risk. It is the fastest visible win for complaint 2.

#### T4 — `fix(zone-hydration): install a layer whenever a zone goes live or is armed`
- **Invariant:** for every mountable project zone that is armed or planned `.live`, `canvasView.installedZoneIds` contains it. After `retireFlatCompatibilityScene`, `installProjectTile` never takes the flat branch: it refuses with a typed failure instead.
  `TileSpawner.persistProjectCanvas(.flatCanvasState)` is legal only while the flat scene is active. `reconcileHydration` and `setActiveZone` act on `mountableZones` only.
- **Work:**
  - Extract the per-zone layer build from `install` and `switchWorkspace` (they duplicate it) into one `makeProjectZoneLayer(zone:controller:membershipCache:)`, using the same world→local conversion.
  - Add `ensureLayer(for zoneId:)`: build, `upsertZoneLayer`, then Phase A/B hydration for that layer only. It must go through `retireOrphanedRuntimes`, suppress auto-layout (`withAutoLayoutSuppressed`), and must not repeat the `installInitial*` walk (hazard 9 "new tile kind owes").
    Call it from `setActiveZone` after acquisition and from `reconcileHydration` for zones promoted to live. Dehydration can keep the layer; this ticket does not uninstall layers.
  - Gate `tileView(for:)` behaviour: no change needed once the fallback is unreachable, but add a debug assertion.
- **Witness `--zone-late-hydration-spawn-check`:** workspace with zones A (at the origin, armed) and B at (20000, 0). Mount through `mountWorkspaceSceneAtBoot`. Assert B has no layer (the precondition is part of the check, so the fixture can't drift all-live).
  Pan via `setViewport` → `canvasDidChange` → the viewport-delta gate → `onViewportChanged` → reconcile. Assert B is armed *and* layered.
  Spawn through `qaPerformPaletteAction(.newManagedAgent)`. Assert that the tile resolves via `tileView(for:)`, that `agentSupervisor.agent(forTile:)` is non-nil, that the record's `projectId` is Pb and its cwd is Pb's root, and that the tile's world frame lies inside B's rendered world rect.
  Assert that Pb's `canvas.json` tile ids are {Pb's tiles + new tile} (no Pa id) and that Pa's `canvas.json` is byte-identical to before.
  Second case: same, but arming by `.click` without panning. Third case: a 6-zone budget overflow.
  - Positive control: the identical spawn into A passes before and after the fix. Teeth: disabling `ensureLayer` yields "tile not found by tileView(for:) / no agent bound / Pa tiles in Pb canvas.json".
- **Files:** `WorkspaceRuntime.swift` (install, switch, setActiveZone, reconcileHydration), `CanvasNSView.swift` (`installProjectTile`), `TileSpawner.swift` (`persistProjectCanvas`), `ContinuumApp.swift` (`hydrateZoneLayerTiles` single-layer entry).
- **Perf:** layer build happens once per zone promotion, O(tiles in that zone), and never per frame. It rides the existing reconcile debounce. Run the `docs/internals/performance.md` checklist; do not add a timer (the post-0.5.1 erosion lesson).
- **Blast radius:** hydration lifecycle, browser runtime budget (a newly layered zone can add browsers, so `enforceBrowserRuntimeBudget` must run after), and focus-broker registration.

#### T5 — `fix(canvas): give each zone placement a single writer`
- **Invariant:** every placement change goes through one `CanvasNSView.applyZonePlacement(_:emit:)`. It updates `liveZones`, the layer, `zoneRenderModels`, `zoneDisplayByZoneId` and chrome, compensates layer-local frames when the origin moves (already done in `growZone`), and emits `onZoneMoved` once.
  `allZonePlacements` and the header menu read one precedence. Hazard 9 already assigns geometry to Model B; this ticket makes the code obey it.
- **Work:** route `growZoneToFitMembers` (`:1977`), `commitProvisionalZone` (`:985`), `setZoneScope`, `setZoneAutoLayoutMode`, `applyZoneRename`, `mutateZonePlacement` and the drag/resize paths through it. Do **not** remove `ZoneLayer.placement` or `liveZones`. That is the tempting larger refactor; see §4.
- **Witness `--zone-placement-single-owner-check`:** in a layered zone, resize a tile past the edge (drives `growZoneToFitMembers`), switch away and back, then cold remount. The zone rect equals the grown rect, every member's world frame is inside it, and `liveZones` equals `layer.placement` at each step.
  Positive control: a move that must not grow leaves the rect untouched. Add a T1 case for it.
- **Files:** `CanvasNSView.swift`. Medium risk: many readers, one file.

#### T6a — `fix(canvas-persistence): serialize all canvas.json writes per project`
- **Invariant:** every `ProjectStore.saveCanvas` for a project runs on that controller's `canvasSaveQueue` with a generation number, and a write with a lower generation than the last completed one is dropped. After T4 the `.flatCanvasState` whole-scene write no longer exists post-retirement; T6a deletes the path outright for persisted workspaces.
- **Witness `--canvas-write-order-check`:** hold `canvasSaveQueue` with a semaphore-gated injected store. Schedule a debounced save (snapshot S0), commit a tile drag (a sync write, S1), then release the queue. Disk holds S1's frames.
  Positive control: without the hold, both orders converge to S1.
- **Files:** `ZoneRuntimeController.swift`, `ContinuumApp.swift` (`persistLayoutTransaction` project writes), `TileSpawner.swift` (`persistProjectCanvas`).

#### T6b — `fix(zone): move a layer-less zone's members with the zone`
- **Invariant:** moving or resizing a zone translates its members' persisted world frames even when no layer is installed. After T4 that means off-screen zones in the budget-overflow case.
  Route the members through the same `CanvasLayoutTransaction` → `persistLayoutTransaction` → project canvas write, with rollback.
- **Witness:** T1 case `offscreen-zone-move`. Drag zone C (live but over budget, so not layered) by (+300, +200) via `commitGeometryEdit`. Cold remount: every C member's world frame moved by exactly the delta, and all are inside C's rect.
  Positive control: a layered zone moved the same way gives the same result.
- **Files:** `CanvasNSView.swift:6013-6025` region, `ContinuumApp.swift` persistence.

#### T6c — `feat(zone-layout): decide and enforce the zone overlap policy`
- **Needs a decision from Dylan first:** "zones may never overlap on disk" (push neighbours via the jelly solver) or "overlap allowed, never created by growth" (growth clamps at a neighbour).
  The jelly rules ("zones push tiles, never inverse") make this a feel question, not a bug fix.
- **Witness:** a spawn at the shared edge of two adjacent zones, then a cold remount. The policy's predicate holds, e.g. `CanvasEngine` pairwise intersection area == 0.

#### T7 — `fix(agent-tile): refuse loudly when a managed tile cannot bind`
- **Invariant:** `wireManagedAgentTile` never returns silently. Both early exits (`:13453` view not found, `:13515` spawn refused) end in either a bound agent or a tile-level refusal notice ("Couldn't start an agent here: <reason>") with a working "Choose Home…" action.
  The three scope resolutions collapse into one: the spawn resolves once and passes `CreationScope` into `wire` explicitly instead of via a memo lookup.
  `hydrateRuntimeBackedTiles` offers the refusal state for record-less tiles instead of skipping them.
- **Witness `--managed-agent-bind-or-refuse-check`:** force each failure (unusable Home directory; controller acquisition failure via a throwing `makeController`). The tile shows the notice, and the Home action opens the picker seam.
  Positive control: the happy path binds. This is defence in depth: T4 removes the main cause, and T7 makes any future cause visible instead of looking like "—".
- **Files:** `ContinuumApp.swift` (wire, spawn), `TileSpawner.swift` (pass scope through), `ManagedAgentTileNSView.swift` (notice plus action; no new `TokenThemed` view, or else hazard 8 applies).

#### T8 — `chore(matrix): triage the nine unowned pre-existing reds`
The list is from `.plans/66` (gate 2026-09-22, reproduced at `2cec73ff`):

| Leg | Symptom | First triage step |
|---|---|---|
| `--agent-supervisor-check` | exit 139 SIGSEGV | symbolicate crash report; likely related to `.plans/57` runner-generation work |
| `--note-click-focus-check` | `keyDown should edit note text; got ""` | focus/first-responder regression vs frontmost fixture |
| `--agent-tile-click-focus-check` | `padding click alone should focus the editor` | same family as above; fix together |
| `--workspace-api-open-check` | `capabilities from the preset grant` | CX-01 grant preset drift |
| `--file-tile-zoom-check` | title compositor drift 2.4397… (identical digits) | deterministic; compare against zoom-unify changes |
| `--session-resume-check` | `A12 FAIL: browser URL must be the specific persisted URL` | browser hydration after layer install (re-check after T4) |
| `--terminal-tmux-observer-check` | `ld: tapi error`, SDK `libSystem.B.tbd` unknown `arm64e.x1-macos` | host toolchain: document as KNOWN-RED(host) with the SDK version, or pin toolchain |
| `--terminal-tmux-observer-wiring-check` | same linker failure | same |
| `npm test --prefix Tools/TaskEditor` | `ERR_MODULE_NOT_FOUND: jsdom` | add devDependency or install step in matrix |

Also: register `--workspace-switch-polish-check`, which `.plans/66` claims but `run-matrix.sh` lacks. The outcome is a matrix summary with zero unowned failures, so every new red means something again.
Owner: one person per row. This can run in parallel with T1–T4.

#### T9 — `test(matrix): make the round-trip suite a release gate`
- Add `--stress` fixtures: 7 zones over 3 projects and 2 workspaces, two zones beyond 20k pt, `maxLiveZones` overflow achieved by geometry (not by writing defaults; hazard 3), and 200-step seeded random sequences of {rename, change Home, create zone, spawn agent, drag tile, resize tile, move zone, pan, click-arm, switch, quit/remount}.
  Canon must round-trip and no agent tile may be unbound. The seed is printed on failure for replay.
- `RELEASE.md` step: the matrix summary must list `--workspace-roundtrip-check` PASS.

#### T10 — `docs(claude-md): record the one-writer rules and retire stale hazard text`
- Hazard 9 still calls `install(into:)` checks-only; production boot calls it (`ContinuumApp.swift:16210`). Add the three rules T2, T4 and T5 establish: document single writer, armed ⇒ layered, placement single writer.
  Add "fixtures must include a layer-less zone" to "What a scene witness owes".

**Suggested release shape.**
- **0.7.22 "stability patch"**: T0, T1, T2, T3, T4, T7, T8. This fixes complaint 1, both halves of complaint 2, complaint 3, and the cross-project `canvas.json` write behind much of complaint 4.
- **0.7.23**: T5, T6a, T6b, T9.
- **0.7.24**: T6c after the policy decision.
- Agent liveness (`.plans/57`) is a separate instability source ("Working" with no runner). Schedule it after 0.7.22, not in the same train.

---

## 4. What not to do

- **Don't merge the two canvas models now.** Deleting the flat scene or `ZoneLayer`, or making layers compute placement from `liveZones` wholesale, would rewrite a 13k-line view that dozens of checks construct directly. T4 plus T5 give one owner per fact without moving the model boundary.
- **Don't hide complaint 3 by pinning every zone live or raising `maxLiveZones`.** That reintroduces O(zones) residency, the post-0.5.1 perf erosion.
- **Don't answer drift by re-reading disk more often.** Disk → memory while mounted *is* the S2 defect.
- **Don't re-rank `CreationScopeResolver`.** Its precedence is deliberately locked (`.plans/47` T3).
- **Don't add retry or "re-wire later" loops to `wireManagedAgentTile`.** Fix the missing layer (T4) and make failure loud (T7).
- **Don't add a speculative sleep/wake observer.** Get T4's witness green first, then reproduce wake in the preview before touching it.
- **Don't resume `~/array-worktrees/workspace-foreign-zone-fix` blindly.** It is 108 commits behind and dirty. Port only the "mountable zones in reconcile" idea into T4, with the owner's agreement (`.plans/65`).
- **Don't fold T0 and T2 into one bench or commit.** Both are large ContinuumApp diffs. Serialize them.
- **Don't bless baselines, add a KNOWN-RED to get green, or write source-grep witnesses.** Every leg above asserts outcomes and carries a positive control.
- **Don't hand-roll a new persistence layer** (database, event log). The existing atomic stores are fine; the problem is who calls them.

---

## 5. Dogfood protocol

**Topology (hazard 10 and non-negotiable #1).**
- `/Applications/Array.app` (prod, 0.7.21) stays on `~/Documents/personal`. Nobody rebuilds or quits it. Dylan keeps doing real work there until the checklist below passes.
- `~/Desktop/Array Dev.app` (DEV channel, "Array Dev" store, `.dev` defaults) is pinned to `~/array-scratch` by `scripts/dev-app.sh`. Only Dylan or the single integration owner runs that script; workers never do (it kills the preview even with `--no-launch`).
- Never run `~/array-scratch/apps/Array 0721 Preview.app` at the same time. Both are DEV channel and share the dev store.
- One root per install. Never point the preview at `~/Documents/personal` or any path prod has open.

**Seed a power-use scratch workspace once:**
- Under `~/array-scratch/projects/`: three small throwaway git repos (alpha, beta, gamma). They are only projects, not benches.
- Workspace W1: 6 zones (alpha×2, beta×2, gamma, one group zone), two of them far off-screen, one with a subfolder Home.
- Workspace W2: one gamma-free project zone.
- Before each session, snapshot: `cp -R ~/array-scratch/.array /tmp/array-dogfood-<ts>` and the dev app-support workspace dir. After it, diff `canvas.json`/workspace JSON against the snapshot, read-only.

**Reproduce first, fix second.** On the current integration build, capture each complaint RED in the preview (screenshot plus the JSON diff). Then install the ticket's build and capture GREEN with the identical script.

**Screenshots per ticket:**

| Ticket | Script | Evidence |
|---|---|---|
| T0 | open window, enter/exit fullscreen, drag window by merged bar | 3 shots: windowed, fullscreen, mid-drag; plus a shot proving the old standalone bar is gone |
| T2 | rename a zone, change its Home, immediately pan and click another zone, drag a tile, ⌘Q, relaunch | header before quit and after relaunch; the zone's `name`/`homeRelativePath` from the workspace JSON |
| T3 | same zones after switch W1→W2→W1 and after relaunch | 3 header shots per zone (live and off-screen); the zone context menu showing the Home line |
| T4 | fresh launch, pan to a far zone, click it, ⌘K new agent; repeat after sleep/wake | agent tile with Home chip showing the project, chip menu open; `canvas.json` of both projects (no foreign ids) |
| T7 | point a zone's Home at a folder, delete the folder, spawn | tile showing the named refusal plus a working Choose Home |
| T5/T6b | resize a tile to grow a zone; drag an off-screen zone; switch and relaunch | same camera via ⌘K "Jump to zone" before and after; tiles inside rects |
| T6a | drag tiles repeatedly while panning for 2 min, relaunch | before/after overlay of the same zone |

**Criteria for Dylan to return to prod on the next release:** in the preview, one 20-minute session of the seed script with zero "—" tiles, zero header changes across three switches and two relaunches, and zero tiles outside their zone. Plus a matrix summary showing `--workspace-roundtrip-check` PASS and 0 unowned failures.
