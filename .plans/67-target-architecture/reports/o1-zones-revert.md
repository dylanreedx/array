# O1: zone names and project-home labels revert

Investigated at `1451c030` on `array/integration`. I only read code and ran two existing headless legs. Nothing was edited, built, stashed or committed. I did not read or touch prod state.

## Summary

The complaint is really three defects. Each one is proven from the code, and the existing witnesses cannot see any of them.

1. **H1 (top, about 70%): the ambient-arming save controller stays bound to the first workspace that armed.** `WorkspaceRuntime.armingSaveController` is created lazily, once, with the `workspaceId` that was current at that moment. `switchWorkspace` never resets it. After a switch, every ambient arming (`.click`, `.focus`, `.camera`) writes the *current* workspace's whole `WorkspaceDocument` into the *first* workspace's `workspaces/<id>/canvas.json`. That happens on clicking a tile in another zone, clicking a zone, or panning onto a zone. Foreign project zones are filtered out of the mount but kept in the document (`mountableZones`), so the contamination is invisible where it happens. It only shows when you switch into, or relaunch into, the victim workspace:
   - On the first pass, the victim's zones disappear.
   - After a ping-pong (each workspace's file now holds a stale copy of the other's zones), the victim's zones come back **with old names, old Homes, and without any zone created since the copy was taken**.

   That matches "names revert … Home reverts … new zone no longer present after switch or relaunch". The orchestrator's 200 ms stale-snapshot lead uses the same controller and is folded in as H4.
2. **H2 (about 90% for the "project home visual" half): the install and switch paths never compute `scopeLabel`.** Only the boot-only flat builder `ContinuumApp.zoneRenderModels(from:registry:)` does. Every persisted-workspace boot retires that scene and remounts through `WorkspaceRuntime.install` → `setZones`, whose render models omit `scopeLabel`. So a Home label drawn by the picker (`commitProvisionalZone` / `setZoneScope`) disappears on **every** switch and relaunch, although `homeRelativePath` is persisted correctly. This one is deterministic, 100% repro.
3. **H3: the `zoneRenderModels` array is a stale third copy that the agent-rollup refresh copies back onto the display.** `applyAgentStatusesToCanvas` → `updateZoneRenderModels(zoneRenderModels.map…)` replaces `zoneDisplayByZoneId` wholesale. `setZoneScope`, `beginProvisionalZone` and `commitProvisionalZone` never write that array. So within a session, a re-bound Home label reverts to the old one on the next agent status tick. A newly created zone also loses its display entry, which means a later rename persists but never repaints its header.

The smallest correct fix is to give each store one owner:

- **Document saves:** one runtime-owned save controller, keyed to the current workspace and shared by sync and debounced writes.
- **Zone labels:** the zone chrome derives the label from `placement.scope` rather than a stored string.
- **Agent rollups:** the refresh patches rollups only, never whole models.

## Lifecycle trace

### Stores

| Store | Owner / writer | Holds |
|---|---|---|
| `workspaces/<wsId>/canvas.json` (`WorkspaceStore`, `WorkspaceStore.swift:13-21`) | `WorkspaceRuntime.saveWorkspaceDocument` (fresh controller per call, `WorkspaceRuntime.swift:1433-1446`); `armingSaveController` (long-lived, `:347`, `:419-428`); app-level `persist*` fallbacks and `persistLayoutTransaction`/`persistLastExplicitCreationScope` (disk-load → mutate → save → `replaceDocument`, `ContinuumApp.swift:14664-14745`, `:14951-14967`) | zones (name, projectId, homeRelativePath, geometry), `ambientTiles`, viewport, `lastActiveZoneId`. **No workspaceId inside the document**, so nothing detects a cross-write. |
| `WorkspaceRuntime.document` (in memory) | `commitZonePlacement` / `commitCreatedZone` / `commitClosedZone` (`WorkspaceRuntime.swift:108-157`), `setActiveZone`, `replaceDocument` (`:100`), `persistDepartingWorkspaceState` (`:1861-1885`), `switchWorkspace` (`:1617`) | the working truth |
| `registry.json` | picker `assignProject` (`ContinuumApp.swift:14905-14908`), `commitCreatedZone` (`WorkspaceRuntime.swift:117-131`) | project ownership (`exclusiveWorkspaceOwner`, `Registry.swift:145-172`), which decides mountability |
| `<root>/.array/canvas.json` | per-project controller saves, `persistLayoutTransaction` | project tiles (WORLD frames). Carries no zone names or Homes. |
| `CanvasNSView.liveZones` (Model B) | `setZones` (`CanvasNSView.swift:6270`), `upsertZoneLayer`, rename (`:4901`), scope (`:1024`), gestures | geometry, and the fallback placement |
| `ZoneLayer.placement` | `setZones`/`_installLayer`, rename (`:4904`), scope (`:1029`), `setZonePlacement`, undo (`:241`, `:264`) | **wins** in `allZonePlacements()` (`:2570-2584`), and so in `workspaceZonePlacementsForPersistence` |
| `zoneRenderModels` array | `setZones`, `upsertZoneLayer`, rename, `mutateZonePlacement`, layout transaction. **Not** `setZoneScope`, `beginProvisionalZone` or `commitProvisionalZone`. | display models, `navZoneRenderModels` |
| `zoneDisplayByZoneId` + `ZoneChromeNSView.model` | all of the above, plus `updateZoneRenderModels` (`:5159-5165`), which rebuilds it from the array | the visible name and **scope label** |
| `ambientTiles` | workspace document | group-zone tiles |

### Walkthrough

1. **Create (marquee).** `mouseUp .creating` → `beginProvisionalZone` (`CanvasNSView.swift:910-973`) appends to `liveZones` and `zoneDisplayByZoneId` (scopeLabel "Choose a project to finish"), but **not** to `zoneRenderModels`. Then the picker opens (`ContinuumApp.swift:14832`), or auto-bind runs through `agreedFilesystemScope`. On confirm: ownership check and `assignProject` → `commitProvisionalZone` (`:977-1000`) sets the label, fires `onZoneCreated` → `persistCreatedGroupZone` → `runtime.commitCreatedZone` → sync save → `persistLastExplicitCreationScope` (disk load → save → `replaceDocument`).
2. **Rename.** `applyZoneRename` (`:4897-4921`) writes `liveZones`, the layer, the `zoneRenderModels` entry *if present*, and the display entry *if present* → `onZoneRenamed` → `persistRenamedZone` (`ContinuumApp.swift:14755-14765`) → `commitZonePlacement(canvas placement)`. A sync save, correct on disk. A failure (`zoneNotFound`) goes only to stderr.
3. **Re-bind Home.** `setZoneScope` (`:1016-1041`) writes `liveZones`, the layer and the display entry, and sets the label. It skips `zoneRenderModels`. `onZoneMoved` → `persistMovedZone` → `commitZonePlacement`, a sync save.
4. **Ambient arming (click, focus, camera).** `setActiveZone` (`WorkspaceRuntime.swift:363-430`) writes `document.lastActiveZoneId` and then `armingSaveController.scheduleZoneLayoutSave(document)`. That is a **200 ms snapshot of the whole document into the store bound at first creation**.
5. **Switch away.** `switchWorkspace` (`:1466`) loads the target from disk *first*. Then `flushMountedWorkspaceState` (`:798-808`) drains the arming controller (into its bound store) and runs `persistDepartingWorkspaceState`: canvas placements are mapped over `document.zones` (only ids already in the document) and saved synchronously to the departing file. Then `setZones(layers, documentZones: zoneRenderModels(for: targetZones, layers:))`, and the render models **have no scopeLabel** (`:1579-1580`, `:628-641`). Then `workspaceId = target` and `document = target` (`:1616-1617`). **`armingSaveController` is untouched.**
6. **Switch back.** The same path runs, reading the target's disk file. Mounted zones are `mountableZones` (`:1677-1686`): zones whose project the workspace does not own are dropped from the scene but kept in `document`, so they are re-saved forever.
7. **Quit.** `applicationShouldTerminate` → `flushMountedWorkspaceState` (drain arming, then save the current doc) → `windowWillClose` → `closeAll` (`setZones([])`).
8. **Relaunch.** `applicationDidFinishLaunching` builds the flat canvas with `ContinuumApp.zoneRenderModels(from:)`, the only builder that computes `scopeLabel` (`ContinuumApp.swift:17344-17368`). `mountWorkspaceSceneAtBoot` then does `retireFlatCompatibilityScene()` + `runtime.install(into:)` (`ContinuumApp.swift:16204-16217`), and `install` builds render models without `scopeLabel` (`WorkspaceRuntime.swift:731-751`, `:767-769`).

### Where one store is rebuilt from another

- disk → `document`: switch, and boot.
- `document` → `liveZones` / `zoneRenderModels` / display: `setZones`.
- canvas `allZonePlacements` → `document`: departing save, and `persistLayoutTransaction`.
- disk → `document` via `replaceDocument` (six app call sites: `ContinuumApp.swift:14572, 14612, 14653, 14742, 14788, 14966`).
- `zoneRenderModels` → `zoneDisplayByZoneId`: `updateZoneRenderModels`, on every agent-status push.

## Ranked hypotheses

### H1: the arming save controller outlives its workspace and writes it cross-workspace (about 70% as the cause of name/Home/new-zone reverts; the defect itself is certain)

Evidence (`WorkspaceRuntime.swift`):

```swift
347    private var armingSaveController: WorkspaceDocumentSaveController?
419        if reason.persistsImmediately {
420            try? persistWorkspaceDocument()
421        } else {
422            if armingSaveController == nil {
423                let appSupport = registryStore.registryFile.deletingLastPathComponent()
424                armingSaveController = WorkspaceDocumentSaveController(
425                    store: WorkspaceStore(workspaceId: workspaceId, applicationSupportDirectory: appSupport))
426            }
427            armingSaveController?.scheduleZoneLayoutSave(document)
```

- `grep armingSaveController` finds only `:347, :422, :424, :427, :474, :478, :483`, with **no reset** anywhere, including `switchWorkspace` (`:1616 workspaceId = targetWorkspaceId`).
- `.focus`, `.click` and `.camera` all take this branch (`:339-343`).
- Production callers:
  - `onZoneActivated` → `.click` on every mouseDown in a zone (`ContinuumApp.swift:16115-16117`)
  - `armZoneForFocusedTile` → `.focus` on a user tile click (`:5821-5824`)
  - `reconcileHydration` → `.camera` on pan settle (`WorkspaceRuntime.swift:1830-1836`)
- `WorkspaceDocumentSaveController.flushPendingSave` writes `pendingDocument` to its captured `store` (`WorkspaceDocumentSaveController.swift:53-70`).

Consequence: bind to workspace A, switch to B, click a tile in another zone of B, and 200 ms later B's document lands in `workspaces/A/canvas.json`. `switchWorkspace` and quit both call `flushPendingArmingSave()` *before* saving the current doc, so a pending B snapshot is also forced into A's file at every departure.

Why it reads as "revert" rather than as total loss: `mountableZones` hides foreign-owned zones but `persistDepartingWorkspaceState` keeps them (`document.zones.map { visibleById[$0.zoneId] ?? $0 }`). Each workspace file therefore silently accumulates a frozen copy of the other workspace's zones. When a later session binds to the other workspace, that frozen copy is written back over the live file. The victim then remounts its own zones from the old copy, with old names and old Homes, and zones created after the copy are missing. Which workspace is the victim changes per session (whichever ambient-arms first), so the effect looks intermittent ("often").

The existing witnesses are blind to it:
- `--workspace-switch-check` inv8 never arms in the second workspace.
- `--workspace-restart-fault-check` switches wa→wb→wa and only arms in wa after returning (`ContinuumApp.swift:26054-26081`), so the controller is always bound to the right workspace.
- Both legs pass at HEAD (see Commands run).

### H2: install and switch never produce a scope label, so the Home visual disappears after every switch or relaunch (about 90% for the Home half; deterministic)

Evidence:
- The only builder that computes a label is the boot flat one: `ContinuumApp.swift:17351-17362` (`scopeLabel = zone.homeRelativePath.map { "\(projectEntry.name) / \($0)" } ?? "\(projectEntry.name) / Project Root"`).
- Every runtime builder omits it:
  - `WorkspaceRuntime.swift:745-748` (`install`): `CanvasNSView.ZoneRenderModel(placement: zone, displayName: displayName)`
  - `:1579-1580` (`switchWorkspace`), same form
  - `:636-640` (`zoneRenderModels(for:layers:)` fallback for non-live zones)
  - `:901` (`_addProjectZone`)
  - `:952-953` (ambient)
- `ZoneRenderModel.scopeLabel` defaults to `nil` (`CanvasNSView.swift:61`). The chrome draws the scope only `if let scope = model.scopeLabel` (`:12963`), and the context menu likewise (`:5719`).
- Production persisted-workspace boot retires the flat scene and uses `install` (`ContinuumApp.swift:16204-16207`).

Result: the picker sets the label in memory (`:990`, `:1036`), so "I create a new one fine". The next switch or relaunch rebuilds the models without it. `homeRelativePath` is still on disk, which is why this is a *visual* revert.

### H3: stale `zoneRenderModels` copied back by the agent rollup refresh (in-session revert; certain defect, moderate contribution)

Evidence:
- `ContinuumApp.swift:8319-8324`: `let updatedModels = canvasView.zoneRenderModels.map { … agentStatusRollup … }; canvasView.updateZoneRenderModels(updatedModels)`
- `CanvasNSView.swift:5159-5164`: `zoneRenderModels = models; zoneDisplayByZoneId = Dictionary(models.map …)`
- This runs from `pushAgentSurfaces`/`applyAgentSignalVisual`, which fire on every agent status change and on app activation.
- `setZoneScope` (`:1016-1041`) and `commitProvisionalZone` (`:977-1000`) write the display entry but never the array. `beginProvisionalZone` (`:942-950`) never appends to the array.

Effects:
- After a Home change, the next tick restores the old `scopeLabel` and placement on the chrome.
- A new zone's display entry is dropped. `applyZoneRename` then skips the chrome update (`if var model = zoneDisplayByZoneId[zoneId]`), so the header keeps the old name while the new name is persisted.
- The zone's scope line also vanishes from its context menu, and `navZoneRenderModels` omits the new zone.

### H4 (orchestrator lead, confirmed but narrow, about 10-15%): the 200 ms stale snapshot overwrites a sync save

Confirmed mechanism: `scheduleZoneLayoutSave` stores a struct snapshot (`WorkspaceDocumentSaveController.swift:39-51`). Every sync save uses a fresh controller (`WorkspaceRuntime.swift:1439-1444`; `ContinuumApp.swift` `persist*`), so nothing supersedes the pending arming snapshot. An arming followed within 200 ms by a rename, create, bind or move means the timer later writes S0 over S1 on disk.

Correction to the lead's "then S0 wins on switch or relaunch": both switch and quit re-save the **in-memory** document after draining (`persistDepartingWorkspaceState`, `WorkspaceRuntime.swift:1861-1885`), and canvas placements overwrite document zones there. So a stale disk name is repaired on a clean switch or quit. S0 survives only if:
- (a) the app is killed or crashes before the next departing save, or
- (b) a disk-reading writer runs in between. `persistLayoutTransaction` loads disk (`ContinuumApp.swift:14677`) and ends with `replaceDocument` (`:14742`), which pulls S0 into memory. A zone created in the window is then missing from `document`, and the departing map (`visibleById[$0.zoneId] ?? $0` over document ids only) never re-adds it, so it vanishes.

Realistic windows are short: clicking a header and committing a typed rename takes well over 200 ms. That is why this ranks low, but the H1 fix removes it too.

### H5: swallowed persistence failures leave a canvas-only zone (low to medium)

`commitCreatedZone` throws on ownership (`WorkspaceRuntime.swift:117-128`), and `exclusiveWorkspaceOwner` also throws `unknownProject`/`ownerMismatch`/`duplicateMembership` (`Registry.swift:145-172`). `persistCreatedGroupZone` only logs (`ContinuumApp.swift:14580-14587`). The auto-bind path (`CanvasNSView.swift:960-970`) skips the picker's pre-check. When the commit fails:
- the zone stays on canvas but is absent from `document`;
- a rename throws `zoneNotFound`, which is logged;
- the departing save only maps existing ids, so the zone disappears on switch or quit.

### H6: amplifier: disk-reading writers call `replaceDocument` (low as a root cause, high as an amplifier)

`persistLayoutTransaction` and `persistLastExplicitCreationScope` load from disk and `replaceDocument`, contrary to `commitZonePlacement`'s own contract ("No reload is permitted here", `WorkspaceRuntime.swift:105-107`). Any H1 or H4 disk corruption is thereby promoted into the live runtime document.

### H7: concrete-occurrence undo restores whole placements (low)

`registerConcreteUndo` / `cancelCanonicalLayerGesture` restore a full `ZonePlacement` (name and scope included) captured at gesture start into the layer (`CanvasNSView.swift:184-195`, `:257-268`), and the layer wins in `allZonePlacements`. This only applies to duplicate-zone-ID layers (`gestureRoutingMode`).

## Repro recipe

### H1 (top), headless and deterministic

Fixture: a temp app-support directory (`CONTINUUM_APP_SUPPORT`) with registry workspaces WA and WB.

| Project | Owner | Zones | Names | Home |
|---|---|---|---|---|
| PA | WA | ZA1, ZA2 | "Alpha", "Beta" | ZA1 = "src" |
| PB | WB | ZB1, ZB2 | "Gamma", "Delta" | none |

Set `lastActiveWorkspaceId = WA`, WA `lastActiveZoneId = ZA1`, WB `lastActiveZoneId = ZB1`.

Steps:

1. Boot through `AppDelegate.mountWorkspaceSceneAtBoot(…, installsGlobalEventMonitors: false)`.
2. `canvas.onZoneActivated?(ZA2)` (the production closure wired at `ContinuumApp.swift:16115`), then `runtime.flushPendingArmingSave()`. The controller is now bound to WA.
3. `try runtime.switchWorkspace(to: WB)`. Snapshot the bytes of `workspaces/WA/canvas.json` as `A0`.
4. `canvas.onZoneActivated?(ZB2)`, then `runtime.flushPendingArmingSave()`.
   - Expected: WA's file bytes equal `A0`, and WB's file has `lastActiveZoneId == ZB2`.
   - Actual at HEAD: WA's file decodes to WB's document (zones ZB1/ZB2, no ZA*).
5. `try runtime.switchWorkspace(to: WA)`.
   - Expected: ZA1/ZA2 installed, chrome shows "Alpha"/"Beta".
   - Actual: `installedZoneLayerIds` contains neither, because PB zones are filtered as foreign and WA looks empty.
6. Revert flavour (ping-pong). Seed WB's file with a stale foreign copy of ZA1 named "Old" with Home `nil`, which is exactly what one earlier H1 pass leaves behind. Then repeat steps 2-5.
   - Actual: WA remounts ZA1 as "Old" with no Home, and ZA2, created after the copy, is gone.
7. Relaunch variant: after step 4, run `applicationShouldTerminate`. Then use a fresh `AppDelegate` on the same app support with `lastActiveWorkspaceId = WA` and `mountWorkspaceSceneAtBoot`. The same actual as step 5.

Manual, in the preview app on `~/array-scratch` with two workspaces of two or more zones each:
1. Click a tile in zone 2 of workspace A.
2. Switch to B and click a tile in B's other zone.
3. Switch back to A.

A's zones are gone or reverted.

### H2

Boot-mount WA with ZA1 at Home "src".
- Expected: `canvas.zoneChromeSnapshot(for: ZA1)?.scopeLabel == "PA / src"`.
- Actual: `nil`, after boot, after any switch round trip, and after `setZoneScope` followed by a round trip.

### H3

After mount, run `canvas.setZoneScope(ZA1, projectId: PA, home: "docs", scopeLabel: "PA / docs")`, then drive the production rollup refresh (`applyAgentStatusesToCanvas` via a QA seam on the delegate).
- Expected: the chrome label is "PA / docs".
- Actual: it reverts to "PA / src".

For a new zone: `beginProvisionalZone` → `commitProvisionalZone` → rollup refresh → rename via the canvas QA rename path.
- Expected: `zoneChromeSnapshot.displayName == new`.
- Actual: the old name.

## Witness spec: `--zone-identity-roundtrip-check`

**What it drives, all production entry points:**
- `AppDelegate.mountWorkspaceSceneAtBoot`. Never `install(into:)` directly.
- `canvas.onZoneActivated` (the mount-wired closure) and `qaAcceptTileFocus(_, .userClick)` for ambient arming.
- `canvas.beginProvisionalZone` plus the picker's confirm body. Add an `AppDelegate` QA seam that runs the same `onConfirm` closure body headlessly, so the ownership check, `assignProject`, `commitProvisionalZone` and `persistLastExplicitCreationScope` all run.
- The canvas QA rename path (`applyZoneRename` → `onZoneRenamed` → `persistRenamedZone`).
- `canvas.setZoneScope` → `persistMovedZone`.
- `runtime.switchWorkspace`.
- `applicationShouldTerminate` followed by a fresh delegate on the same app support, re-mounted with `mountWorkspaceSceneAtBoot`, to simulate relaunch.
- The rollup refresh through its delegate method.

**Assertions**, all outcomes and never source strings. After each phase (create, rename, re-bind, ambient-arm in the other workspace + drain, switch away, switch back, relaunch), for every zone:

1. **Disk:** `WorkspaceStore(own wsId).load()` zone `(name, projectId, homeRelativePath)` equals the expected tuple.
2. **Memory:** `runtime.document` agrees with disk.
3. **Screen:** `zoneChromeSnapshot(for:)` has `displayName == expected name` and `scopeLabel == "<project> / <home or Project Root>"`.
4. **Isolation:** the non-current workspace's `canvas.json` bytes are unchanged across any ambient arming and any drain in the current workspace.
5. **No contamination:** no workspace file contains a zone whose project's `exclusiveWorkspaceOwner` differs from that workspace, unless the fixture seeded it.
6. **Supersede (H4):** arm, then immediately (before the timer) run the sync rename. Then run the arming controller's timer body (drain). The disk name equals the new name.

**Positive controls (teeth):**
- (a) Run the leg at HEAD before the fix. It must go RED at assertion 4 (H1), assertion 3 (H2) and the H3 rollup step, and each failure message must name the phase.
- (b) A control phase where the first ambient arming happens *after* the switch, in WB, stays GREEN at HEAD for WB's own file. This proves the witness does not just fail on any arming.
- (c) Before the switch, assert that the flat boot builder's label for ZA1 is "PA / src". This proves the label string can be produced and that assertion 3 reads real chrome.
- (d) Record in the manifest that at least one arming was pending: `qaArmingScheduledGeneration > qaArmingAcknowledgedGeneration` before the drain.

Headless only: use `orderFrontOffscreenForChecks()` and no global monitors. Register it in `scripts/run-matrix.sh` and confirm the end-of-run summary prints the leg.

## Fix plan

### 1. H1 + H4: one document save controller per mounted workspace (single writer)

In `WorkspaceRuntime.swift`:
- Replace `armingSaveController` and the per-call controller in `saveWorkspaceDocument` with one `documentSaveController`, created for the current `workspaceId`.
- Sync saves become `schedule(document)` + `flush(through:)` on that same controller. This supersedes any pending ambient snapshot, because `pendingDocument` is replaced and the timer invalidated.
- In `switchWorkspace`, after `flushMountedWorkspaceState()` (which drains it) and before `workspaceId = targetWorkspaceId`, drain and nil it. Do the same anywhere else `workspaceId` changes.
- Defensive guard: the controller carries its `workspaceId` and refuses to flush if it no longer equals `runtime.workspaceId`.

About 20 lines. The QA generation seams (`qaArming*`, `qaLastScheduledWorkspaceGeneration`) and the `_workspaceDocumentSaver` override must keep working.

Follow-up for H6, same principle: route `persistLayoutTransaction` / `persistLastExplicitCreationScope` through runtime commit methods that mutate `runtime.document`, not disk load → `replaceDocument`.

### 2. H2: one render-model builder, or better, no stored label

Preferred: `ZoneChromeNSView` / `CanvasNSView` derive the label at render time from `placement.scope` through the existing `scopeLabelForZoneScope` hook (`CanvasNSView.swift:392`, wired at `ContinuumApp.swift:4659`). `ZoneRenderModel.scopeLabel` then stays only as the provisional override ("Choose a project to finish").

Minimal alternative: extract the label computation from `ContinuumApp.zoneRenderModels(from:registry:)` into a shared static and call it from `install`, `switchWorkspace`, the `zoneRenderModels(for:layers:)` fallback, `_addProjectZone` and `makeAmbientZoneLayer`. Do not carry `QARunManifestReader.latest` (disk I/O per zone) into the switch path. That would be a performance regression; see `docs/internals/performance.md`.

### 3. H3: rollups patch rollups only

- Add `CanvasNSView.updateZoneAgentRollups(_ byZone: [UUID: AgentStatusRollup])`, which mutates `zoneDisplayByZoneId[id].agentStatusRollup` in place and updates chrome.
- Switch `ContinuumApp.swift:8319-8324` to it.
- Also make `beginProvisionalZone`, `commitProvisionalZone` and `setZoneScope` keep `zoneRenderModels` in sync. Longer term, remove the array as an independent store and derive it from `liveZones` plus the display dictionary.

### Files

- `Sources/ContinuumRevived/App/WorkspaceRuntime.swift`
- `Sources/ContinuumRevived/Canvas/CanvasNSView.swift`
- `Sources/ContinuumRevived/App/ContinuumApp.swift` (rollup call site, the H2 builder extraction, a QA seam for the picker confirm)
- possibly `WorkspaceDocumentSaveController.swift` (the workspace-id guard)

### Risks

- **Save controller:** generation accounting is asserted by `--workspace-restart-fault-check` (`qaArmingScheduledGeneration`/`Acknowledged`) and by `saveGenerationAcknowledged` lifecycle observers. Sharing the controller changes the numbers those checks read.
- **Labels:** the header now draws a label after mount, so the UI-baseline legs and `ui-probe` rasters may shift. Do not update baselines blindly. Any check that compares whole `ZoneRenderModel`s after install will change.
- **Existing contaminated data:** the fix stops new cross-writes but does not repair files that already hold frozen foreign copies. Dylan's real workspace files may already carry stale foreign zones. Offer a read-only audit (zones whose project owner differs from the workspace) and an explicit repair. Never auto-delete.

### Existing witnesses to extend or adjust

- `--workspace-switch-check` (inv8): add ambient arming in WB, then a WA byte-equality check.
- `--workspace-restart-fault-check`: arm in wa before the first switch, and in wb.
- `--workspace-boot-persistence-check`: add chrome `scopeLabel`.
- `--zone-arming-check`
- `--zone-rename-inline-check`: canvas-only today; add a persisted round trip or leave that to the new leg.

## Commands run

All from `/Users/dylan/Documents/personal/Array`. `timeout` is not installed on this host, so `perl -e 'alarm 180; exec @ARGV'` served as the 180 s guard. Both flags were verified against `grep -oE '\-\-[a-z0-9-]+-check' Sources/ContinuumRevived/App/ContinuumApp.swift | sort -u`.

```sh
AS=$(mktemp -d /private/tmp/claude-501/as.XXXX); PR=$(mktemp -d /private/tmp/claude-501/pr.XXXX)
CONTINUUM_APP_SUPPORT=$AS CONTINUUM_PROJECT_ROOT=$PR perl -e 'alarm 180; exec @ARGV' \
  .build/release/Array --workspace-boot-persistence-check    # exit 0
# "ContinuumRevivedWorkspaceBootPersistenceChecks passed: qa-runs/2026-09-28T020614Z/workspace-boot-persistence/manifest.json"

CONTINUUM_APP_SUPPORT=$AS2 CONTINUUM_PROJECT_ROOT=$PR2 perl -e 'alarm 180; exec @ARGV' \
  .build/release/Array --workspace-switch-check              # exit 0
# "ContinuumRevivedWorkspaceSwitchChecks passed"
```

Both are green at HEAD while H1, H2 and H3 exist, which confirms the witness gap. Logs are under `scratchpad/legs/`. Note: the binary's mtime (Sep 23 15:49) is six minutes before HEAD's commit time (15:55). I took the caller's word that it matches HEAD and did not rebuild.

I also did a read-only scan of the **dev** store (`~/Library/Application Support/Array Dev/workspaces/*/canvas.json` against `registry.json`) for foreign zones. It was inconclusive: the store is lightly used, and one zone's project has no declared owner. The prod store was not read.
