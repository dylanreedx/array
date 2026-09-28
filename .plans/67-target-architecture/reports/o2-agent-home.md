# O2: agent tile shows "—" and its Home selector does nothing

Investigated at HEAD `1451c030`. No files in any checkout were changed. Only the release binary built at HEAD was run.

## Summary

**Top hypothesis (about 85% confidence):** the agent tile is created in a zone that has **no installed `ZoneLayer`**. That happens when the zone was below the live hydration tier when the scene was mounted at boot. The spawn is still allowed, because WS9 (`abd312d4`) made arming such a zone acquire its controller and spawner. But `CanvasNSView.installProjectTile` finds no layer, so it quietly falls back to the **flat** install. At boot, `mountWorkspaceSceneAtBoot` already retired the flat scene (`flatCompatibilitySceneActive = false`), so the canvas's own lookup `tileView(for:)` no longer searches the flat `tileViews`.

The result: the view is on screen, but `wireManagedAgentTile` does not find it at its very first guard and returns without a sound. No agent record is ever created and nothing is attached to the tile. So:

- the location row keeps its constructor default, `"—"`
- the Home button closure exits early on `projectedAgentID == nil`
- `onSubmitPrompt` is nil, so prompts do nothing too.

Nothing ever gives an already-mounted zone a layer afterwards. `reconcileHydration` and `setActiveZone` acquire controllers but never build layers. Only three things install a layer: a relaunch that mounts the zone as live, a workspace switch, or `addProjectZone`, which runs when you recreate the zone. That matches Dylan's report exactly: "only after restarting (and sometimes having to recreate the zone)".

The existing witness for this scenario (`--zone-unacquired-project-check`) is green. It stops at "the spawner is the right project" and never spawns a tile. The comment in that check even quotes the original report: "creating an agent tile in the other 'did not know about the home project directory'".

**Second finding: probable data corruption on the same path (needs a witness).** The flat fallback returns `.flatCanvasState`, and `persistProjectCanvas` then runs `projectStore.saveCanvas(canvasView.canvasState)`. After the flat scene is retired, that `canvasState` is still the **boot project's** stale flat model. So the armed project's `canvas.json` is overwritten with the boot project's boot-time tiles plus the new tile. This is a credible contributor to the companion complaint ("zones lose their project binding / tiles move after relaunch"), but I have not verified it.

## Spawn trace

1. **Gesture.** Every production "new agent" entry point (⌘K `agent.newManaged`, the model step, zone/menu routes at `ContinuumApp.swift:7304, 8948, 9133, 14161`) goes to `spawnManagedAgentFromPalette` (`ContinuumApp.swift:13295`).
2. **Scope.** `resolvedCreationScope()` (`ContinuumApp.swift:15757`). The zone rung checks these in order: `canvasView.activeProjectZonePlacement` (needs an installed layer), then **`armedFromDocument`** (`document.lastActiveZoneId`, deliberately independent of hydration, T1 `.plans/47`), then the boot `activeZone`. For an armed zone with no layer, the answer is `armedFromDocument`: correct project, correct `zoneId`.
3. **Spawner.** `spawnerForFilesystemCreation()` (`ContinuumApp.swift:15896`) returns `workspaceRuntime.controller(for: projectId)?.tileSpawner`. Because of WS9, arming acquires the controller (`WorkspaceRuntime.swift:391-400`) and `attachActiveControllerUI` builds its spawner (`:415-417`). So this is non-nil and the spawn goes ahead.
4. **Arming in the canvas.** `setActiveZone` calls `canvasView.setActiveProjectZone(zoneId)` (`WorkspaceRuntime.swift:410`). That call **sets `activeProjectZoneId = nil` when no layer exists** (`CanvasNSView.swift:6484-6492`), and nothing reports it.
5. **Tile spawn.** `TileSpawner.spawnManagedAgentForSelectedModel` leads to `spawnManagedAgent` (`TileSpawner.swift:1513`):
   - `creationScope = creationScopeProvider?()`, `targetZoneId = scope.zoneId` (`:1525, :1534`).
   - `makeProjectTilePlacement`: `installedZonePlacement(for:)` is nil and `activeProjectZonePlacement` is nil, so the tile is placed with flat automatic world placement around the viewport, against the stale flat `canvasState.tiles` (`TileSpawner.swift:7893-7911`). The tile appears where the user is looking.
   - The `Tile` is stamped with `zoneId`, `filesystemProjectId`, and the checkout root from the scope (`:1552-1569`).
   - **`canvasView.installProjectTile(tileView:for:targetZoneId:)` (`:1586`) finds no layer for `zoneId`, goes to `install(tileView:for:)`, which is the flat model (`CanvasNSView.swift:6806-6819`), and grows the zone to include the tile.** The view is added to `worldPlane`, which is why it is visible. It is registered only in the flat `tileViews` dictionary.
   - The managed session record is upserted. Then `persistProjectCanvas(after: .flatCanvasState)` runs `projectStore.saveCanvas(canvasView.canvasState)` (`TileSpawner.swift:2420-2421`). This is the second finding above.
   - The creation-scope memo is recorded (`:1607`).
6. **Wiring.** `wireManagedAgentTile(tileId, initialLaunchSelection:)` (`ContinuumApp.swift:13452`):
   - **`guard let view = canvasView?.tileView(for: tileId) as? ManagedAgentTileNSView else { return }` (`:13453`)**
   - `tileView(for:)` (`CanvasNSView.swift:2223-2229`) searches flat `tileViews` **only if `flatCompatibilitySceneActive`**, and otherwise searches only `zoneLayers`. The persisted-workspace boot path calls `retireFlatCompatibilityScene()` before `runtime.install(into:)` (`ContinuumApp.swift:16207-16209`; `CanvasNSView.swift:6305-6307`). **So the lookup returns nil and wiring stops here.** No `agentSupervisor.spawn`, no record, no `attach`, no `onLocationActionMenuRequested`, no `onSubmitPrompt`.
   - The palette caller then reads `agentSupervisor.agent(forTile:)`, which is nil, and returns `false`. No beep, no stderr line.
7. **Home selector data source (on the healthy path).** `ManagedAgentTileNSView.attach` (`ManagedAgentTileNSView.swift:510`) leads to `refreshLocationStatus` (`:3020`), which reads `supervisor.locationSnapshot(for:)`. That call is non-nil whenever the record exists (`AgentSupervisor.swift:1623-1627`). The menu itself is built by `showLocationActionMenu` (`ContinuumApp.swift:13658`) from the registry (`projectActionSubmenu`).

## Selector guards

These are all the points between a click on the Home/Where control and a change to the record, and whether each one fails silently.

| # | Guard | Location | Silent? | Reached in this bug? |
|---|---|---|---|---|
| G1 | `wireManagedAgentTile` view lookup: `tileView(for:)` nil means return | `ContinuumApp.swift:13453` | **yes** | **yes, the root cause** |
| G2 | `compactStatusRow.onActionMenuRequested`: `guard let agentID = self.projectedAgentID else { return }` | `ManagedAgentTileNSView.swift:352-355` | **yes** | **yes**, since there is no attach |
| G3 | `onLocationActionMenuRequested` is nil (only bound in wire, `:13557`) | `ContinuumApp.swift:13557` | yes (optional call) | yes |
| G4 | `showLocationActionMenu`: `guard let snapshot = locationSnapshot(for:) else { return }` | `ContinuumApp.swift:13659` | yes | no (non-nil whenever a record exists) |
| G5 | The primary item is **"Change Home" only when `!hasUserWorkOrSessionHistory`**. Otherwise it is "New Agent Here", which spawns a new tile through the **active** `tileSpawner` with no scope (`:13763-13779`) and is subject to the same flat fallback | `ContinuumApp.swift:13675-13693` | not silent, but surprising | not in the fresh-tile case |
| G6 | `projectActionSubmenu` filters out `missing` projects and projects whose root fails `usableAgentHomeDirectory`, leaving a disabled "No registered projects" item | `ContinuumApp.swift:13702-13716` | visible but disabled | possible (H3) |
| G7 | `reassignHome`: `usableAgentHomeDirectory(cwd)` or `reassignProvisionalHome` returns false, followed by `NSSound.beep()` | `ContinuumApp.swift:13747-13761`; `AgentSupervisor.swift:1805-1829` (refuses after any work; refuses on a persist failure) | beeps | no |
| G8 | Re-attach after reassign: needs `records[id].tileId` and `tileView(for:)`, the same lookup as G1 | `ContinuumApp.swift:13756-13760` | yes | would also fail for a flat-installed tile |
| G9 | Wiring fallbacks: `usableAgentHomeDirectory(scope home)` nil leads to `spawnSupervisedAgent`, whose resolver returning nil leads to a beep and a stderr refusal | `ContinuumApp.swift:13504-13519, 13355-13397` | beeps | H2 only |

Also: the `"—"` is the constructor default (`applyUnknownCompactStatus()` at `ManagedAgentTileNSView.swift:379`, text at `:1769`). A tile that has never been attached cannot show anything else.

## Ranked hypotheses

### H1: armed zone has no installed layer, so the spawn goes flat into a retired scene and wiring cannot find the tile. Confidence: about 85%.
Evidence:
- `WorkspaceRuntime.install(into:)` builds a layer **only** for zones planned `.live` (`WorkspaceRuntime.swift:688`, `guard plan.tier(for:) == .live else { continue }`). The budget is `maxLiveZones = 4` (`ZoneHydrationBudgetConfig.swift:9`), and viewport proximity is measured against `canvasView.bounds`, with a 1280×720 fallback if the canvas has not been laid out yet (`:667`).
- Layers are installed in only three places: `install(into:)` (`:767`), `addProjectZone` (`:908`), and `switchWorkspace` (`:1598`). `reconcileHydration` (`:1757-1830`) and `setActiveZone` (`:391-417`) acquire controllers and spawners but **never build a layer**. The WS9 comments show that acquiring was treated as enough.
- `setZones` draws chrome for the **whole** document zone set (CLAUDE.md hazard 9, "One owner for zones"). So a zone without a layer looks normal and can be clicked.
- `installProjectTile` falls back to flat without any signal (`CanvasNSView.swift:6806-6819`). `tileView(for:)` hides flat views once the flat scene is retired (`:2224`). The retirement happens on every persisted-workspace boot (`ContinuumApp.swift:16209`).
- The signature matches:
  - *Fresh launch:* the plan is fixed at mount, and any zone not live then stays layerless for the whole session.
  - *Restart fixes it:* the next mount usually has that zone live, because the saved `document.viewport` and `lastActiveZoneId` now centre it.
  - *Sometimes the zone has to be recreated:* when the zone is still outside the live tier on relaunch (far away, or more than 4 zones visible), only `addProjectZone` (`:908`) installs a layer unconditionally.
  - *Morning / after wake:* nothing in the app observes wake (no `didWakeNotification` anywhere). The likely link is that the morning is a fresh mount after a Sparkle update, crash, or quit, plus the first use of a zone that was off-screen at mount. This is inferred, not proven.
- Why the existing witnesses miss it: `--zone-unacquired-project-check` (`ZoneUnacquiredProjectChecks.swift:207-235`) asserts `qaCreationSpawnerProjectId` and never spawns. `--zone-arming-check` spawns only into a zone just created by add-zone, which always has a layer.

### H2: the Home directory is unusable at wiring time (folder grant or TCC pending, root temporarily missing). Confidence: about 8%.
- If `usableAgentHomeDirectory` (`fileExists` + isDirectory, `ContinuumApp.swift:13737-13744`) fails for the scope's home, wiring falls back to `spawnSupervisedAgent`. If the active-project home also fails, that path **beeps** and refuses (`:13389-13393`), producing the same `"—"` and a dead selector. It could happen at boot while `requiresExplicitProjectFolderGrant` is pending for `~/Documents/...` roots, which is where Dylan's projects live. It would be audible, though, and Dylan does not mention a beep. The G6 empty submenu can occur for the same reason.

### H3: the project cannot be acquired (the `.array/lock` is held, hazard 10). Confidence: about 4%.
- `setActiveZone` arms anyway. `activeController` is then nil, and `spawnerForFilesystemCreation` returns nil, so `spawnManagedAgentFromPalette` returns false **with no tile at all** (`ContinuumApp.swift:13299`). That produces no tile, not a blank one, so it does not match. It only matters if another install or a crashed prior process still holds the lock for a moment after boot.

### H4: the tile was bound to a nil controller or spawner and never re-bound. Confidence: about 3%.
- The tile holds no controller. The memo lookups go through `workspaceRuntime.managedAgentCreationScope(tileId:)` across all spawners, and `adoptManagedAgentMemos` (`TileSpawner.swift:1645`) carries them forward. Nothing re-binds after G1 fails, but that is a consequence of H1, not a separate cause.

### Rejected
- **"Selector writes but view never re-renders."** `reassignHome` re-attaches, and the fast path assigns `projectName` and refreshes (`ManagedAgentTileNSView.swift:515-523`). That was fixed earlier.
- **"Zone treated as a group zone, so activeController is nil and the record is minted without a project."** `setActiveZone` refuses to arm a project-less zone (`WorkspaceRuntime.swift:375-378`), and the scope's zone rung requires a `projectId`. Losing the zone binding (the companion complaint) would produce the picker or a refusal, not a blank tile.

## Repro recipe

Deterministic and headless, modelled on `ZoneUnacquiredProjectChecks.runScenario`:

1. Set up a temp app-support directory and two project roots, Near and Far, both registered, with one workspace that owns both. The document has zoneNear inside the viewport and zoneFar at x≈20000 (off-screen, so it is planned `.snapshot`). Set `document.lastActiveZoneId = zoneNear`.
2. Build a `CanvasNSView` from Near's canvas (1 seed tile), sized 2000×1200. Build an `AppDelegate`, and call `qaPrepareForBootMountCheck(...)` and then `mountWorkspaceSceneAtBoot(...)` with `installsGlobalEventMonitors: false`.
3. Positive controls: `canvas.qaZoneLayerPlacement(for: zoneFar) == nil`, `canvas.isFlatCompatibilitySceneActive == false`, `runtime.controller(for: Far) == nil`.
4. `delegate.qaActivateZoneByClick(zoneFar)`. The zone is armed and Far's spawner exists (WS9 holds).
5. Drive the **real** managed-agent route (`spawnManagedAgentFromPalette`, through a QA seam, or `TileSpawner.spawnManagedAgentForSelectedModel` with the production `wire:` closure). Use a frozen catalogue model and `CONTINUUM_*` QA gates so no provider process starts.
6. Observe at HEAD:
   - a new `ManagedAgentTileNSView` is a subview of the world plane
   - `canvas.tileView(for: tileId) == nil`
   - `agentSupervisor.agent(forTile: tileId) == nil`
   - `view.qaLocationText == "—"`
   - a simulated click on `qaCompactStatusRow`'s action button does not invoke `onLocationActionMenuRequested`
   - Far's `canvas.json` now contains Near's seed tile (second finding).

## Witness spec

**Proposed flag: `--agent-spawn-unhydrated-zone-check`.** Register it in `run-matrix.sh` after `--zone-unacquired-project-check`, and confirm the leg appears in a real matrix summary.

- **Drives:** `mountWorkspaceSceneAtBoot`, then `qaActivateZoneByClick` (the real `onZoneActivated`), then the real palette managed-agent spawn including `wireManagedAgentTile`. Never `install(into:)`.
- **Controls (checked before acting; fail means the fixture proves nothing):** zoneFar has no layer; the flat scene is retired; Far has no controller.
- **Outcome assertions:**
  1. `canvas.tileView(for: tileId)` is a `ManagedAgentTileNSView`, and it is identical to the view actually on screen (walk `worldPlane` subviews).
  2. `agentSupervisor.agent(forTile:)` is non-nil. The record's `projectId == Far`, `checkoutRoot == Far.root`, and `cwd` equals the zone Home.
  3. `view.qaLocationText` is Far's project name, not `"—"`.
  4. The location action fires. Through a QA presenter seam, not an `NSMenu`, the "Change Home" item lists both projects. Selecting "Use Near" makes `locationSnapshot(for:).home.checkoutRoot == Near.root` and the tile text becomes "Near".
  5. The tile's **world frame lies inside zoneFar's world rect**, per hazard 9: assert geometry, not the zone stamp.
  6. Persistence: after a flush, Far's `canvas.json` contains the new tile in WORLD frames and **does not contain Near's seed tile**. Near's `canvas.json` is unchanged.
  7. Relaunch leg: re-mount from disk. The tile rehydrates in zoneFar and re-wires to the **same** agent id (no duplicate record).
- **Teeth:** against HEAD, assertions 1–4 and 6 must be RED. Temporarily reverting the fix (for example, restoring the flat fallback) must turn them RED again.

## Fix plan

The smallest correct change, ordered so that each step can be witnessed.

1. **Give an armed zone a layer before creating into it.** Add `WorkspaceRuntime.ensureLayerInstalled(forZone:)`. It reuses the existing layer builder from `install(into:)`: `membership(forProject:...)`, the world-to-zone-local conversion, `DescriptorTileNSView`s, and the hydrator's `.beforeInstall`/`.afterInstall` phases, through `canvasView.upsertZoneLayer` (the same path `addProjectZone` uses at `:900-915`). Call it from `setActiveZone` right after the controller is acquired (`:391-400`), and re-run `setActiveProjectZone`. This makes layer and controller acquisition one step, which is what WS9 should have done. The alternative, calling it lazily from `spawnerForFilesystemCreation`, is an option, but arming is the single writer and the better seam.
   - *Risk:* a zone left live forever defeats the hydration budget. Mitigate by letting `reconcileHydration` keep owning the tier: a layer without runtimes is cheap, and descriptor views are headless-safe. Check against `docs/internals/performance.md` (no O(tiles) work per camera settle; this runs only on arming a layerless zone). Hazard 9's rules apply: Phase B through `retireOrphanedRuntimes`, and `withAutoLayoutSuppressed` so the zone is not re-tidied.
2. **Make the flat fallback impossible after retirement.** In `CanvasNSView.installProjectTile`, when `!flatCompatibilitySceneActive` and no layer exists, return a failure outcome (for example `.unavailable`) instead of installing a view that `tileView(for:)` cannot see. `spawnManagedAgent` and the other spawns then return `.failure` and the caller reports it. Also make `persistProjectCanvas`'s `.flatCanvasState` branch refuse when the flat scene is retired, which closes the data-corruption path.
3. **Stop failing silently.** In `wireManagedAgentTile`, a missing view should call `fputs` plus `NSSound.beep()`, and the palette caller's `false` should speak. Optional: a tile that has no agent could show "Not connected" instead of "—".
4. **Extend the witnesses.** Add a spawn plus a `tileView(for:)` assertion to `--zone-unacquired-project-check`, or add the new leg above. Update that check's doc comment claim ("the spawner's project … decides where the tile actually lands"), which is false.

**Existing witnesses that will change or need attention:** `--zone-unacquired-project-check` (becomes stronger), `--zone-arming-check` (unchanged), `--zone-tile-hydration-check`, `--zone-tier-transition-check`, `--zone-hydration-lifecycle-check`, and `--zone-registry-refcount-check`. The last four assert layer and tier counts after reconcile and may count one more installed layer after an arm. Also check `--zone-save-isolation-check` and `--zone-runtime-duplication-check` against step 2's persistence refusal.

**Out of scope, but related:** the same flat fallback affects every spawn that goes through `installProjectTile` (terminal, note, browser, file tree) into a layerless zone. Those tiles do not need wiring, so they "work", but they are persisted through the stale flat `canvasState`, which is the second finding.

## Commands run

Flags verified with `grep -oE '\-\-[a-z0-9-]+-check' Sources/ContinuumRevived/App/ContinuumApp.swift | sort -u` (241 flags; both flags below are present). `timeout` is not installed on this host, so `perl -e 'alarm 180; exec @ARGV'` was used as the 180s limit. Each run used fresh temp directories, and `TMUX`/`TMUX_PANE` were unset with a private `TMUX_TMPDIR`.

```
B=/private/tmp/claude-501/o2legs
env -u TMUX -u TMUX_PANE TMUX_TMPDIR=$(mktemp -d /tmp/o2tmux.XXXX) \
  CONTINUUM_APP_SUPPORT=$(mktemp -d $B/sup.XXXX) CONTINUUM_PROJECT_ROOT=$(mktemp -d $B/proj.XXXX) \
  perl -e 'alarm 180; exec @ARGV' /Users/dylan/Documents/personal/Array/.build/release/Array --zone-unacquired-project-check
# exit 0 — "ContinuumRevivedZoneUnacquiredProjectChecks passed" (green, and it never spawns a tile)

(same env) ... Array --zone-arming-check
# exit 0 — "ContinuumRevivedZoneArmingChecks passed" (its spawn targets an add-zone zone, which always has a layer)
```

The first attempt with `timeout 180` exited 127 (`env: timeout: No such file or directory`), so no leg ran on that attempt. No GUI launch, no rebuild, no default tmux socket, and no prod state were touched.
