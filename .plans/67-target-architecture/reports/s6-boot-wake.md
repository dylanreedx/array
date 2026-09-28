# S6 — Boot order & wake/activation audit

Repo: /Users/dylan/Documents/personal/Array. Read-only; nothing built/run/edited.

## 1. Boot order (all in-process, single call stack unless noted)

All of `applicationDidFinishLaunching` runs SYNCHRONOUSLY on the main thread
except the two `Task.detached` fire-and-forgets noted below, which touch
nothing the canvas/zone/agent-tile path reads. The whole scene-mount sequence
(`mountWorkspaceSceneAtBoot`) is also synchronous top to bottom — there is no
`DispatchQueue.main.async`/`asyncAfter`/`Task` inside it that defers zone or
tile installation.

| # | Step | File:line | Sync/Async |
|---|------|-----------|------------|
| 1 | `ContinuumApp.main()` → dispatches into AppKit | `ContinuumApp.swift:807` | sync |
| 2 | `applicationDidFinishLaunching` begins; appearance pinned, perf timers reset | `ContinuumApp.swift:4481-4531` | sync |
| 2a | Detached: pi-extension install, legacy transcript migration | `ContinuumApp.swift:4511-4527` | **async, Task.detached** — does not block/gate boot; touches `~/.pi`, not canvas |
| 3 | `RegistryStore` built, `registry = loadOrEmpty()` (registry.json read) | `ContinuumApp.swift:4533-4539` | sync, depends on registry.json |
| 4 | `ProjectRootResolver`-driven `resolveProjectRoot` — may show the grant `NSAlert`/`NSOpenPanel` (see §2) | `ContinuumApp.swift:4543`, `17005-17075` | sync, **blocking modal** |
| 5 | `presentLockContentionUXIfNeeded` → builds `bootController` (project store, `.array/lock`) | `ContinuumApp.swift:4544` | sync, depends on `.array/` |
| 6 | Re-record project in registry; reload registry as `updatedRegistry` | `ContinuumApp.swift:4549-4550` | sync, second registry.json read |
| 7 | `reconciledManagedSessionSource.reconcile(...)` — agent-liveness sweep (P3.1/P3.2, boot-time analogue of `.plans/57`) over EVERY registered root, before any agent status is read | `ContinuumApp.swift:4565-4572` | sync |
| 8 | `loadActiveWorkspaceDocument`, `zoneRenderModels`, `activeZone` computed from `updatedRegistry` | `ContinuumApp.swift:4574-4581` | sync, depends on the `WorkspaceStore` document |
| 9 | Ghostty/browser engine contexts created; `canvasState` loaded from the **project's** `canvas.json` (`tryLoadCanvasWithSanitizationResult`) or defaulted | `ContinuumApp.swift:4583-4601` | sync, depends on `<root>/.array/canvas.json` |
| 10 | Topology migration, `isolatedBootCanvasState` (drops foreign-workspace tiles from the flat snapshot) | `ContinuumApp.swift:4616-4629` | sync |
| 11 | `CanvasNSView` constructed with that `canvasState`/`activeZone`/`zoneRenderModels`; all canvas callbacks (`onZoneCreated`, `onZoneRenamed`, …) wired | `ContinuumApp.swift:4631-4667` | sync |
| 12 | `WorkspaceRuntime` constructed — **one of three initializers** depending on whether the selected workspace owns the boot project | `ContinuumApp.swift:4689-4723` | sync |
| 13 | `TileSpawner` built and wired to the app (note/browser/file-tree persistence handlers, terminal targets, board runtime provider) | `ContinuumApp.swift:4725-4790` | sync |
| 14 | `mountWorkspaceSceneAtBoot(...)` called — see breakdown below | `ContinuumApp.swift:4791-4795` | sync |
| 15 | `refreshAgentSurfaces(notify: false)`, window built/shown, `NSApp.activate` | `ContinuumApp.swift:4796-4816` | sync (comment at 4813 explicitly notes `activate` can fire `applicationDidBecomeActive` **synchronously, re-entrantly**, which is why it is ordered after runtimes are wired) |
| 16 | Onboarding gate, companion sync start | `ContinuumApp.swift:4852-4866` | sync (companion sync's own publish loop is debounced, see §4) |

### `mountWorkspaceSceneAtBoot` (`ContinuumApp.swift:16090-16279`) — order is commented "load-bearing, do not reshuffle"

1. `workspaceRuntime?.lifecycleObserver?(.processLaunched)` — 16097
2. Re-load registry to decide if this is a **persisted workspace** (`persistedWorkspaceRegistry`) — 16098-16104
3. `canvasView.activateUndoWorkspace`, zone-arm / camera / hover / layout-commit callbacks wired — 16105-16156
4. `configureCreationAndRuntimeRoutes`, `configureWorkspaceRuntimeHooks` (installs `hydrateZoneLayerTiles`, `documentAgentTileIdsProvider`), `installSettingsChangeObserver`, `configureActiveControllerRuntimeCallbacks` — 16157-16160
5. **`runtime.adoptCanvas(canvasView)`** — hands the runtime its canvas (`WorkspaceRuntime.swift:275`) — 16172. For the synthetic/compat boot document only, `ensureZoneForActiveProject` also runs here.
6. `activeController?.attachUI(...)` (only for the non-persisted/compat path) — 16178-16180
7. `installAcceptedTileFocusHook`; global event monitors (`installHotkeyMonitor`, `installTileFocusMonitor`, `installCanvasGestureMonitors`) — 16181-16190
8. **`agentSupervisor.restore()`** — restores every persisted `AgentRecord` from the agent store, **idle only, no process started** — 16198. This is unconditionally BEFORE either tile-install branch below.
9. Branch A — **persisted workspace** (this is the shape Dylan's real multi-project workspace takes): `canvasView.retireFlatCompatibilityScene()`, then **`runtime.install(into:appRegistry:)`** (`WorkspaceRuntime.swift:654`) — 16208-16219.
   - `install(into:)` computes the hydration plan (`ZoneHydrationOrchestrator.plan`), and for each **live-tier** zone with a `projectId` calls **`registry.acquire(projectId:)`** to get/create the `ZoneRuntimeController` — i.e. **project controllers are acquired BEFORE `canvasView.setZones(...)` is called** (`WorkspaceRuntime.swift:690-696` precedes `setZones` at `:767`). So the answer to the explicit question in the prompt is: **project controllers exist before zones are installed**, and no user interaction is possible before either (the window isn't even key/visible yet — step 15 above runs after `mountWorkspaceSceneAtBoot` returns).
   - `hydrateZoneLayerTiles(canvas, layers, .beforeInstall)` builds real (non-descriptor) views for tile kinds `makeHydratedTileView` can build **without a runtime** (note/file/runArtifacts/ticketQueue/conductorQueue/kanban/diffReview/managedAgent) — `ContinuumApp.swift:16384-16465`.
   - `canvasView.setZones(layers, documentZones:)` — `WorkspaceRuntime.swift:767`.
   - `hydrateZoneLayerTiles(canvas, layers, .afterInstall)` → `hydrateRuntimeBackedTiles` — spawns/restarts terminal, browser, file-tree runtimes (`retireOrphanedRuntimes` first, to avoid double ptys/WKWebViews), and **wires** (not spawns) any `managedAgent` tile whose `agentSupervisor.agent(forTile:)` is already non-nil — `ContinuumApp.swift:16474-16526`.
10. Branch B — **no persisted workspace / synthetic compat scene**: the flat `installInitial*` walk over `canvasState.tiles` (`ContinuumApp.swift:16227-16254`), then `repairBootMembership`, `refreshDocumentRelationships`, `projectStore.saveCanvas(...)`.

All of the above — steps 1-10 — run before `applicationDidFinishLaunching` creates/shows the `NSWindow` (step 15). **There is no async seam between "zones installed" and "user can interact"** in the normal cold-boot path: the window doesn't exist yet, so no click/spawn can race the install.

## Async seams (where a user COULD act before state is fully ready)

- **None inside boot itself** for zones/tiles — confirmed above; window is created and made key only after `mountWorkspaceSceneAtBoot` returns.
- **`agentComposerDraftStore.migrateLegacySessionDirectories()`** and **`PiExtensionInstaller.install()`** are `Task.detached` at `ContinuumApp.swift:4511` and `4521` — these run concurrently with the rest of boot but touch transcript/pi-extension files only, not zones/tiles/registry.
- **`managedAgentCreationScope(tileId:)` is an in-memory, per-session, per-`TileSpawner` cache** (`WorkspaceRuntime.swift:442-451`, `ZoneArmingChecks.swift`/hazard 9 doc). It is **never populated for a tile hydrated from disk** — only for a tile spawned in the CURRENT process. So on every fresh launch, any managed-agent tile that has no existing `AgentRecord` bound to it falls into `wireManagedAgentTile`'s `else` branch (`ContinuumApp.swift:13488-13514`) with `creationScope == nil` and mints its agent via the **plain active-project fallback** (`spawnSupervisedAgent`, not `spawnSupervisedAgentAtHome`) rather than the zone's own project/Home. This is a real, standing seam — not literally async, but it is a "boot-vs-session" state gap: the thing that would tell a fresh tile its Home doesn't exist yet on a cold boot. (Phase B only WIRES tiles whose agent already exists — `ContinuumApp.swift:16482-16485` — so a genuinely-new, unbound tile is deliberately left inert until the user submits a prompt; that inertness is intentional per the code comments, but it means any tile that *should* have picked up a Home at hydration and didn't will look exactly like "born with no project home, selector inert.")
- **`setActiveZone` non-deliberate reasons (`.focus`, `.click`, `.camera`) debounce their write** via `armingSaveController` (`WorkspaceRuntime.swift:419-428`) rather than writing immediately — see quit-flush verdict below for whether that's safe.
- **`reconcileHydration` / camera debounce** (`WorkspaceRuntime.swift:1734-1753`, `hydrationReconcileTimer`) reruns the hydration plan (which can acquire/release controllers and rebuild layers) off a **debounced timer after viewport changes**, not synchronously with the pan. A rapid succession of programmatic `setViewport` calls very early after boot (e.g. a restored camera position, or another feature moving the viewport) could in principle fire this after the user has already started interacting.

## 2. `ProjectRootResolver.resolve()` and the folder-grant modal

`ProjectRootResolver.resolve()` itself (`Sources/ContinuumRevivedCore/ProjectRootResolver.swift:64-104`) has **no notion of the grant modal** — it only decides which root wins (env var → workspace's own last-active project → global last-active project → `needsPicker`). The grant check is a **separate, later synchronous gate** in `ContinuumApp.swift`:

- `resolveProjectRoot(smokeTest:registry:)` (`ContinuumApp.swift:17005-17040`) calls `requiresExplicitProjectFolderGrant(url)` (`:17042-17047`, true for `~/Documents`, `~/Desktop`, `~/Downloads` and their children — this is exactly Dylan's root, `~/Documents/personal`).
- If required and not yet acknowledged, `requestProjectFolderAccessIfNeeded` (`:17049+`) presents a **blocking `NSAlert`** (and then an `NSOpenPanel`) via `alert.runModal()` (modal, main-thread-blocking).
- **This call happens at step 4 of the boot table above — before `RegistryStore`'s second load, before the canvas is loaded, before `CanvasNSView`/`WorkspaceRuntime`/`TileSpawner` exist.** Nothing about zones, tiles, or project controllers has been constructed yet when the modal is up.
- If the user cancels, `NSApp.terminate(nil)` is called and `resolveProjectRoot` throws `.userCancelled`, which propagates up and is caught by `presentFatalError(error)` at `applicationDidFinishLaunching`'s `catch` (`:4867-4869`) — the app never gets to build a window.

**Verdict for #2: no, zones/tiles cannot be installed while a grant is pending.** The modal is fully synchronous and gates everything downstream in the same function; there is no code path that starts building the canvas/runtime before the grant resolves. (The dev-app hazard noted in CLAUDE.md — the modal reappearing every relaunch because the ad-hoc signature changes — is a UX/DX nuisance, not a state-corruption path.)

## 3. Wake / sleep / activation handlers

**There is no `NSWorkspace.didWakeNotification`, `willSleepNotification`, `screensDidWakeNotification`, or `NSApplication.didChangeScreenParametersNotification` observer anywhere in the app target** (`grep -rn` over `Sources/ContinuumRevived*` found zero matches outside comments/other unrelated `NSWorkspace.shared.*` API calls like `.open`, `accessibilityDisplayShouldReduceMotion`, `.notificationCenter.addObserver` for `.accessibilityDisplayOptionsDidChangeNotification` in a couple of UI views). This is the single most important finding: **"wake" is not a distinguished code path in Array at all.**

What DOES exist:

| Handler | File:line | What it does |
|---|---|---|
| `applicationDidBecomeActive` | `ContinuumApp.swift:16722-16732` | Sets `applicationIsActiveForAwareness = true`, `ghostty_app_set_focus(app, true)`, `focusBroker.applicationDidBecomeActive()`, `refreshAgentSurfaces()`. No zone/canvas/registry re-read. |
| `applicationDidResignActive` | `ContinuumApp.swift:16734-16744` | Mirror: sets awareness false, unfocuses ghostty, `focusBroker.applicationDidResignActive()`, `refreshAgentSurfaces()`. |
| `FocusBroker.applicationDidBecomeActive/didResignActive` | `FocusBroker.swift:151,168` | Re-acquires/releases the remembered focused surface; does not touch zones or the document. |
| `windowOcclusionDidChange` (`NSWindow.didChangeOcclusionStateNotification`, per-window, re-registered in `viewDidMoveToWindow`) | `CanvasNSView.swift:4476-4507`, observer add/remove at `:4519,4532` | Toggles `windowOcclusionVisible`; starts/stops the 10 Hz `residencyTimer` (`startResidencyEvaluation`/`stopResidencyEvaluation`, `:4448-4460`) and tells every tile view `windowOcclusionChanged(visible:)`. Purely a rendering/animation-suspension mechanism (surfacing/demoting tile bodies) — it does **not** touch `zoneChromeViews`, `liveZones`, the workspace document, or any registry/canvas file. |
| `windowShouldClose` / `windowWillClose` | `ContinuumApp.swift:16746+` | Flush-on-close (see quit verdict) — not wake-related but adjacent. |

**Occlusion is the closest thing to a "wake" hook**, and macOS does mark a window occluded while the display is asleep/locked and un-occluded on wake — so a display sleep/wake cycle *will* fire `windowOcclusionDidChange`. But its blast radius is scoped to tile-body residency (parking/promoting rendered surfaces) and the residency heartbeat; nothing in that path re-derives zone geometry, re-arms a zone, reloads the registry, or reinstalls tiles. So **occlusion/wake cannot explain zone renames reverting, tiles moving, or agents losing their Home** by itself.

**Conclusion for §3/§6 ("only after fresh launch / wake"):** since there is no dedicated wake handling, a bug that "only shows after wake" is almost certainly **actually a fresh-launch bug**, and "after the Mac wakes from sleep" is describing one of: (a) the user's Array process actually being relaunched around the sleep/wake boundary (e.g. by a watchdog, a crash, or the user quitting before closing the lid and reopening after), which re-runs the full boot sequence in §1; or (b) something in the debounced-save-vs-quit-flush gap (§5) losing the last few seconds of edits before a sleep-adjacent quit, which then reads back as "reverted" on the next boot. I found no in-process "wake" trigger that re-executes `setZones`/`adoptCanvas`/tile hydration.

## 4. Periodic / debounced writers

| Writer | File:line | Interval | Rewrites |
|---|---|---|---|
| `WorkspaceDocumentSaveController` (debounced) | `WorkspaceDocumentSaveController.swift:45` | configurable, used by `armingSaveController` (ambient zone-arm), `saveController.scheduleZoneLayoutSave` (rename/move-transaction paths) | the workspace document (zones, `lastActiveZoneId`) |
| `armingSaveController` (ambient `setActiveZone` for `.focus`/`.click`/`.camera`) | `WorkspaceRuntime.swift:347,422-427` | debounced | `document.lastActiveZoneId` only |
| `ZoneRuntimeController` per-kind save timers: canvas (`saveTimer`), browser (`browserSaveTimer`), note (`noteSaveTimer`), file-tree (`fileTreeSaveTimer`) | `ZoneRuntimeController.swift:675,707,715,723` | 0.2s/0.2s/0.4s/0.3s, one-shot re-armed on each dirty | the project's `canvas.json` / browser state / note bodies / file-tree state |
| `hydrationReconcileTimer` (camera-debounced hydration re-plan) | `WorkspaceRuntime.swift:1729-1753` | one-shot, re-armed on viewport change | can acquire/release project controllers and rebuild `installedLayers` |
| Managed-session reconciliation ("agent-liveness", the boot-time analogue of `.plans/57`) | `ContinuumApp.swift:4565` (boot), `applicationWillTerminate` (`:16701-16707`, quit) | boot + quit only — **no periodic/background timer found for this in the app target**; the live tracking is via `AgentStoreWatcher` (debounced file-watch, `AgentStoreWatcher.swift:116`, 0.25s) driving `SessionObserver`, not a reconciliation rewrite loop | terminalizes stale liveness claims in persisted agent records |
| `CanvasNSView.residencyTimer` | `CanvasNSView.swift:4452` | `residencyTuning.evaluationInterval` (10 Hz), repeats, only while window is unoccluded | tile surface/body residency only — no persisted geometry |
| Companion sync publish | `scheduleCompanionSyncPublish(...)` calls at `ContinuumApp.swift:16291-16296` | debounce 1.0s | publishes to CloudKit sync layer, not local canvas/zone files (gated off in alpha per CLAUDE.md) |
| Misc UI debounces (file-tree search, editor autosave, undo toast, conductor-queue refresh) | `FileTreeTileNSView.swift:207`, `FileTileNSView.swift:575/1582/1865`, `AgentInboxView.swift:3494/3808/3851`, `ConductorQueueTileNSView.swift:28` | 0.2-1s / periodic 1s | scoped to their own tile's file/UI state, not zone/canvas geometry |

No timer was found that periodically re-derives or rewrites zone PLACEMENT/membership on a repeating cadence outside of user-driven layout commits (`onLayoutCommitted` → `persistLayoutTransaction`, `ContinuumApp.swift:14663`) and the camera-debounced `reconcileHydration`. The auto-layout/tidy pass (`arrangeAutoLayoutAfterSpawn`, `withAutoLayoutSuppressed`) only runs synchronously off a spawn or an explicit tidy gesture, not periodically.

## 5. Quit flush verdict

`applicationShouldTerminate` (`ContinuumApp.swift:16711-16720`) calls `workspaceRuntime?.flushMountedWorkspaceState()` **synchronously**, and only returns `.terminateNow` if it succeeds (returns `.terminateCancel` and logs on failure — the quit is refused rather than silently dropping data). `flushMountedWorkspaceState` (`WorkspaceRuntime.swift:798-809`) does, in order:

1. Captures editors' in-flight state (`FileTileNSView.captureForSceneTransition()` for open file tiles).
2. `flushAll()` — walks every acquired project controller and calls `flushPendingSaves()` (drains that controller's canvas/browser/note/file-tree one-shot timers, §4).
3. `flushPendingArmingSave()` — drains the ambient `armingSaveController` (so a zone armed only by `.focus`/`.click`/`.camera`, never persisted, is written before quit).
4. `persistDepartingWorkspaceState(focus:)` (`WorkspaceRuntime.swift:1861`) — the final document write.
5. `lifecycleObserver?(.closeFlushCompleted)`.

`applicationWillTerminate` (`:16695-16709`, called by AppKit AFTER `applicationShouldTerminate` approves) additionally: `agentSupervisor.stopAll()`, `editorLanguageServices.shutdown()`, a **quit-reason** `ManagedSessionReconciliation.reconcile(..., reason: .continuumQuit, ...)` (best-effort, comment explicitly says "a quit can be a kill we never see, which is why the launch sweep is the load-bearing one"), and `Task { await agentComposerDraftStore.flushAll() }` — this last one is **fire-and-forget inside a terminate handler**, i.e. not guaranteed to complete before the process actually exits.

**Verdict: for a graceful quit (Cmd-Q / menu Quit / window close), the flush IS synchronous and load-bearing for canvas/zone state** — a normal quit should not lose zone renames or tile moves that already went through `onZoneRenamed`/`onLayoutCommitted` (those write immediately or are drained here). The residual risks are:
- A **hard kill** (crash, `kill -9`, force-quit, power loss, and plausibly some sleep-related terminations) bypasses both `applicationShouldTerminate` and `applicationWillTerminate` entirely — nothing flushes, and only whatever the per-timer debounce (0.2-0.4s for canvas/notes, camera-debounced arming) had already landed on disk survives. This is the most concrete "loses the last N seconds" story and matches "reverts on next launch."
- The `agentComposerDraftStore.flushAll()` `Task` in `applicationWillTerminate` is not awaited by the termination reply — a draft in flight at quit could still be lost even on a clean quit, though this affects composer drafts, not zone/tile geometry.

## Suspects for "only after fresh launch / wake"

1. **Hard/ungraceful termination around sleep** (crash, watchdog, force-quit, or the user quitting Array before/while the Mac sleeps) skips both `applicationShouldTerminate` and `applicationWillTerminate`, so anything still sitting in a 0.2-0.4s per-controller save timer or the ambient `armingSaveController` debounce is lost — the next COLD BOOT then reads the older on-disk state and looks like a revert. This is the leading suspect for zone-name/project-binding "reverts" and "tiles/zones move" back to older positions, since there is no wake-time reconciliation to paper over it.
2. **`managedAgentCreationScope`'s in-memory-only cache** (§ Async seams) means any managed-agent tile that is hydrated fresh (no bound `AgentRecord` yet) on a cold boot has no way to recover its zone's project/Home — it falls back to `spawnSupervisedAgent`'s plain active-project path, or (per Phase B's guard) is left completely unwired/inert until a prompt is submitted. Both shapes match "agent tiles in zones are born with no project home and the selector is inert" and are **structural to every cold boot**, not wake-specific.
3. **No wake/sleep handling exists at all** — so any report of "clears after restarting the app" but "only after wake" is circumstantial evidence that the user's app process was itself restarted around the sleep boundary (crash/relaunch), which re-enters the exact same boot sequence audited in §1, rather than evidence of a distinct wake code path (there isn't one).
4. `hydrationReconcileTimer`'s camera-debounced re-plan (`reconcileHydration`) can acquire/release controllers and rebuild `installedLayers` on a timer fired after boot — worth instrumenting if the symptom correlates with an early programmatic viewport restore racing a user's first click.

