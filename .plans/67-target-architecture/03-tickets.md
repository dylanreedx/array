# Array stability board — ticket export (2026-09-28, after the second opinion)

Board: https://claude.ai/artifact/M7LPdrVA8rgKiypzzVUP5i (source of truth for status and comments). This file is the text of every ticket at export time; the README in this folder is the source of truth for the architecture.

## Plan

Continuity pass plus an independent second opinion (GPT-6 Astra at high reasoning, three Sol subagents, 2026-09-28; full report on the Evidence tab). Astra confirmed all five root-cause sentences, found eleven mechanisms the first pass missed, and would not implement the five ARCs as written. Every new mechanism was verified in source before it went on this board. The result: a bounded data-protection ticket ships first, ARC-3 moves up, ARC-2 and ARC-1 are restated and reordered, ARC-4 loses its silent self-repair, and ARC-5 becomes a test program with fault injection and a durability oracle.

**Five sentences.**
1. The workspace document has no owner: eight code paths mutate and save it with their own controllers, one of which stays bound to a workspace the app has left, and several read disk back into memory while mounted.
2. Zone headers are built by five builders from stored strings, and a stale third copy of the models is written back over the display on every agent tick.
3. A zone can be half real: chrome without a layer. Every downstream path has a branch for that state or gets it silently wrong.
4. There are still two tile models, and the retired one is reachable: a spawn into a half-real zone lands in it and becomes invisible to the code that wires it.
5. 'Install a tile' always means 'spawn': grow the zone and re-settle everything. Snapshot, restart and restore all go through it; and nothing anywhere says a member sits inside its zone or that zones do not overlap.

**In the wild.** A read-only audit of the prod app-support directory on 2026-09-27: the `personal` workspace file holds two `harmony` zones owned by `work`; an orphan workspace file not in the registry holds byte-identical copies of `personal`'s zones with the same zone ids; the registry records project ownership in two places that disagree for four of seven projects.

**Complaint 1** is a process failure, not architecture: the titlebar merge exists, was reviewed and was never landed.

**What the second opinion added (all verified at HEAD).** A note-conversion writer stores zone-local frames into the WORLD file and drops the other zones' tiles. A zone's Home is also the storage partition key for its existing tiles. Canvas saves report success on failure and can outlive the lock that authorized them. The direct `saveCanvas` write surface is far wider than three paths. A layout transaction can acknowledge partial effect. Multi-store operations have no recovery protocol. A failed switch leaks acquisitions. The per-zone hydration plan is applied to a per-project controller. Unzoned tiles have no home in the model. A failed read is treated as an empty canvas, and the merge then deletes. Delayed callbacks are not fenced by session identity.

### ARC-0 · Stop the bleeding (0.7.22)

Tickets: ARC-0

Bounded patches at known entry points: saver identity and supersession, the two mounted reloads, the note-conversion writer, retired-flat writes, truthful save receipts. Each with a directed witness; no model decisions taken.

Gate: Four directed scenarios RED on base, GREEN on branch, printed in a real matrix summary.

### ARC-3 + ARC-5 skeleton · Derived headers, and the harness (0.7.22)

Tickets: ARC-3, ARC-5, ARR-10

One pure builder for a zone's name and home with provisional and unavailable states; rollups patch rollups. The harness skeleton lands with its fault injection and receipts oracle so every later phase adds scenarios to it.

Gate: Identity-on-screen scenario GREEN including a rollup tick and a relaunch; harness negative controls fire.

### ARC-2 · A zone is whole or absent (0.7.23)

Tickets: ARC-2

Materialize split from spawn and lifecycle teardown centralized first (the ARC-4 half that moves nothing). Then scene nodes behind adapters: tile storage owner as a field, a root for unzoned tiles, explicit load states, per-project residency, fenced creation into unavailable zones.

Gate: Wholeness, spawn-into-any-zone, rebind-keeps-owners, close-keep-reparents, unavailable-store scenarios GREEN; preview session with screenshots.

### ARC-1 · One owner, recoverable commits (0.7.23)

Tickets: ARC-1

The commit coordinator over a whole scene: receipts, recoverable multi-store commits, complete-resolution accounting, session lease and epoch fencing, identity-stamped files, ownership recorded once, derived quarantine with a repair preview.

Gate: Fail after each participating write and at each acquisition index; remount is wholly before or wholly after; audit of a copy of the prod files attached.

### ARC-4 · Geometry has provenance (0.7.24)

Tickets: ARC-4

Causal layout transactions with the full effect closure; growth pushes neighbours and never overlaps; containment defined once; non-convergence refuses; undo restores the closure; no silent self-repair.

Gate: Stability, containment and overlap scenarios GREEN including a long push chain and the crash-style remount.

### Close-out · Delete the flat scene, decide the layout aggregate, land the leftovers (0.7.24)

Tickets: ARR-1, ARR-9

Remove the flat live scene and legacy writers once adapter coverage is complete. Then, if you approve the storage boundary below, migrate layout into one workspace aggregate. Land the titlebar with its real fullscreen and drag QA; triage the reds to zero.

Gate: Fresh boot, legacy import, every tile kind and an abrupt remount all use one scene path; migration lossless and idempotent; full matrix with zero unowned reds.

### decisions

1. **Where does layout live?** Should a workspace's layout (placement, membership, zone rects) belong to the workspace, with project `.array` stores owning only content and sessions and the project canvas becoming an import/export format? Astra and I both recommend yes. It ends 'one push updates N files' and makes channel-specific layouts explicit, at the cost of a migration and of old-version interoperability. Decide before ARC-1's coordinator is finalized.
2. **What is a zone's Home?** The code and the picker promise it only affects future tiles. Honor that (existing tiles keep their owners even when a zone is rebound), or make rebinding a populated zone an explicit transfer or a refusal. Never today's silent reinterpretation. Recommend: honor the promise.
3. **Already-damaged layouts.** Preserve and show a repair preview you accept, or repair automatically on open (which moves things without a gesture)? Recommend: preview and accept.
4. **Agent-created tiles.** May an agent with permission to create a tile trigger the normal growth/push chain? Recommend: the grant includes the deterministic push, visible and undoable; otherwise the spawn returns a spatial-capacity refusal.
5. **Growth policy: decided.** Growth pushes neighbouring zones like a drag and never overlaps them.

### dogfood

- The preview app is the dev channel on `~/array-scratch`, never the prod root (hazard 10).
- Before each ARC ships: harness green in a real matrix summary, then three hand scripts in the preview with before/after screenshots on the ARC's ticket: (1) rename a zone, switch away and back, quit, relaunch; (2) right after launch, spawn an agent into a zone that was off-screen at boot, then Change Home; (3) drag a tile so it pushes zones, quit within a second, relaunch.
- Only after the preview passes all three do you take the Sparkle update in `/Applications/Array.app`.
- Add to the three scripts: convert a note to an existing file inside a zone that is not at the origin, then relaunch; and rebind a populated zone to another project, then relaunch and check both projects' files.

### notToDo

- Rewrite the canvas or the jelly engine. The invariants in hazard 9 are right; the writers and builders around them are wrong.
- Keep the flat scene 'for safety'. A retired-but-reachable second model is worse than none.
- Pin every zone live. Tiers keep governing processes; they stop governing existence.
- Auto-repair prod files. Quarantine on load, repair on your click.
- Merge the stale `workspace-foreign-zone-fix` branch; 'only owned zones are ever mounted' supersedes its boundary.
- `CONTINUUM_UPDATE_BASELINES=1`, ever.
- A Swift actor for everything, an append-only event log, or CRDT expansion as the first move: each serializes or replays two logically stale writes perfectly. A main-actor command model plus one serial persistence worker with a narrow recovery journal is the right size.
- 'Fix' legacy corrupted geometry silently in production while refusing it in QA: that tests different behaviour from what ships.

### reds

- {"leg": "--agent-supervisor-check", "symptom": "exit 139 (SIGSEGV), candidate and clean base", "touches": "Agent lifecycle; adjacent to complaint 3"} leg=--agent-supervisor-check; symptom=exit 139 (SIGSEGV), candidate and clean base; touches=Agent lifecycle; adjacent to complaint 3
- {"leg": "--file-tile-zoom-check", "symptom": "title compositor drift 2.4397 (threshold 2); fails before its world-frame assertion runs", "touches": "Complaint 4 directly"} leg=--file-tile-zoom-check; symptom=title compositor drift 2.4397 (threshold 2); fails before its world-frame assertion runs; touches=Complaint 4 directly
- {"leg": "--session-resume-check", "symptom": "A12: browser URL must be the specific persisted URL", "touches": "Persisted-state resume, same class as complaint 2"} leg=--session-resume-check; symptom=A12: browser URL must be the specific persisted URL; touches=Persisted-state resume, same class as complaint 2
- {"leg": "--workspace-api-open-check", "symptom": "capabilities from the preset grant", "touches": "Workspace API only"} leg=--workspace-api-open-check; symptom=capabilities from the preset grant; touches=Workspace API only
- {"leg": "--note-click-focus-check", "symptom": "keyDown should edit note text; got \"\"", "touches": "Focus fixture"} leg=--note-click-focus-check; symptom=keyDown should edit note text; got ""; touches=Focus fixture
- {"leg": "--agent-tile-click-focus-check", "symptom": "padding click alone should focus the editor", "touches": "Focus fixture"} leg=--agent-tile-click-focus-check; symptom=padding click alone should focus the editor; touches=Focus fixture
- {"leg": "--terminal-tmux-observer-check", "symptom": "ld: tapi error: malformed libSystem.B.tbd (macOS 27 SDK)", "touches": "Host toolchain"} leg=--terminal-tmux-observer-check; symptom=ld: tapi error: malformed libSystem.B.tbd (macOS 27 SDK); touches=Host toolchain
- {"leg": "--terminal-tmux-observer-wiring-check", "symptom": "same linker failure", "touches": "Host toolchain"} leg=--terminal-tmux-observer-wiring-check; symptom=same linker failure; touches=Host toolchain
- {"leg": "npm test --prefix Tools/TaskEditor", "symptom": "missing dev dependency jsdom", "touches": "Tooling"} leg=npm test --prefix Tools/TaskEditor; symptom=missing dev dependency jsdom; touches=Tooling

## Tickets

## ARC-0 · Data-protection patches first: saver identity, the note-conversion writer, retired-flat writes, truthful save receipts
status=Ready severity=critical complaint=0 area=persistence release=0.7.22 deps=[]

**Symptoms.** Every day you use the app, the cross-workspace write and the false-success saves can damage files. These bounded patches stop the bleeding while the model work (ARC-1, ARC-2) is designed properly.

**Summary.** Second opinion (GPT-6 Astra, verified in source by the orchestrator): ship the small, known-entry-point protections before any architecture change, each with a directed witness. (1) The arming save controller is rebound to the mounted workspace and superseded by every later save; the two mounted disk reloads (`persistLayoutTransaction`, `persistLastExplicitCreationScope`) are removed. (2) The note-conversion writer `persistCanvasForCurrentModel` stores the layer's ZONE-LOCAL tiles as the whole WORLD file, so it both misplaces the survivors by the zone origin and drops every other zone's tiles from the project; it must use the canonical project projection and preserve unaffected records. (3) Any write of the retired flat `canvasState` becomes impossible (inspector reveal/refresh, profile deletion, spawn fallback). (4) Canvas saves stop lying: both flush paths use `try?` and clear the dirty flag regardless, and the sync flush returns before its queue barrier when nothing is dirty, so a queued write can outlive the lock that authorized it. Receipts carry submitted vs durable generations; failure reaches switch and quit.

**Root cause.** - Saver: `WorkspaceRuntime.swift:347,422-427` (bound once), `:1616` (switch changes `workspaceId`), `WorkspaceDocumentSaveController.swift:41` (snapshot), `:1439` (fresh controller per sync save).
- Reloads: `ContinuumApp.swift:14677` → `replaceDocument` at `:14742`; `:14961-14966`.
- Note conversion: `TileSpawner.swift:2142-2145` calls `persistCanvasForCurrentModel`; `:2226-2233` does `state.tiles = canvasView.tiles(inZone:)` (layer tiles, zone-local per `CanvasNSView.swift:6472` and `WorkspaceRuntime.swift:1571`) then `saveCanvas`.
- Retired-flat writers: `TileSpawner.swift:1174, 1264` (`saveCanvas(canvasView.canvasState)`), `:2233`, `:2421`; `ContinuumApp.swift:14126`.
- False success: `ZoneRuntimeController.swift:694-699` (`isCanvasDirty = false` then `try? store.saveCanvas` on the queue), `:738-746` (early return when not dirty, `try?`, callback fires regardless); `WorkspaceRuntime.swift:805-808` (`flushAll()` is non-throwing, then `.closeFlushCompleted`); lock released at `ZoneRuntimeController.swift:206`.

**Risk.** Low-medium. Bounded, known entry points, directed witnesses. Ships first as 0.7.22.

**History.** Added after the second opinion; pass 1 had folded the saver fix into ARC-1 and had not found the note-conversion writer or the false-success receipts.

**Hypotheses.**
- All four are verified mechanisms, not hypotheses. They are patches by design: each closes a known route to disk damage without deciding the target model. confidence=high

**Evidence.**
- `if let zoneId, let tiles = canvasView.tiles(inZone: zoneId) { … state.tiles = tiles; try projectStore.saveCanvas(state) }`: zone-local frames into a WORLD file, one zone replacing the project. ref=Sources/ContinuumRevived/App/TileSpawner.swift:2226-2233
- `try? store.saveCanvas(snapshot)` with the dirty flag cleared before or regardless of the outcome; `onCanvasStatePersisted` fires on failure. ref=Sources/ContinuumRevived/App/ZoneRuntimeController.swift:694-699, 738-746
- Direct `saveCanvas(canvasView.canvasState)` bypasses that survive any fix to `persistProjectCanvas` alone. ref=Sources/ContinuumRevived/App/TileSpawner.swift:1174, 1264; ContinuumApp.swift:14126
- Arming controller never rebound on switch (from pass 1). ref=Sources/ContinuumRevived/App/WorkspaceRuntime.swift:347,422-427,1616

**Fix plan.**
- Rebind and supersede the saver; delete the two mounted reloads (route through `commitZonePlacement`-style runtime mutations).
- Rewrite `persistCanvasForCurrentModel` on the canonical projection; keep unaffected records.
- Make `saveCanvas(canvasView.canvasState)` unreachable once the flat scene is retired; convert the inspector, profile and spawn-fallback callers.
- Truthful receipts: submitted/durable generations, retained error state, a barrier through the last submitted generation even when not dirty, no lock release before it.

**Files.**
- Sources/ContinuumRevived/App/WorkspaceRuntime.swift
- Sources/ContinuumRevived/App/WorkspaceDocumentSaveController.swift
- Sources/ContinuumRevived/App/TileSpawner.swift
- Sources/ContinuumRevived/App/ZoneRuntimeController.swift
- Sources/ContinuumRevived/App/ContinuumApp.swift

**Witness.** `` drives: real mount; arm A, switch B, arm B, drain; arm then rename before the debounce; the note-to-existing-file conversion in a zone at a nonzero origin with a sibling zone; inspector reveal after the flat scene is retired; a store that fails every write.
- asserts: A's file bytes unchanged after arming in B and draining.
- asserts: Durable latest revision survives an abrupt remount after arm-then-rename inside the debounce window.
- asserts: After note reuse: every surviving tile keeps its identity, owner and WORLD frame; the sibling zone's tiles are still in the file.
- asserts: No production path can write the retired flat state (the writer is unreachable; the attempt throws).
- asserts: With a failing store: no success acknowledgment, dirty stays set, switch and quit report the failure, the project lock is held until the last submitted generation resolves.

## ARC-3 · Presentation is derived, never stored: one builder for a zone's name and home
status=Ready severity=high complaint=2 area=zone-chrome release=0.7.22 deps=['ARC-0']

**Symptoms.** You bind a zone to a project and the header shows the directory. After a switch or relaunch the directory is gone, and sometimes a changed home or a new zone's name flips back while you watch.

**Summary.** Absorbs ARR-3. **Invariant:** a zone's header is a pure function of `(placement, registry entry, rollup)`; nothing stores a label string. Today five builders make `ZoneRenderModel`s and only the boot-only flat builder computes the home label, so every relaunch and switch rebuilds headers without it even though `homeRelativePath` is on disk (deterministic, 100%). Separately, `zoneRenderModels` is an independent third copy that `applyAgentStatusesToCanvas` writes back over the display on every agent tick; the picker and zone creation never update that array, so a changed home reverts in-session and a new zone's rename persists while its header keeps the old name.

**Second opinion (GPT-6 Astra, verified in source by the orchestrator).** Keep, and move earlier: it is bounded and independent. The projection must include explicit provisional, unresolved-project and unavailable-project states, not only the happy path; a cached immutable render value is fine, an independently writable one is not.

**Root cause.** **Design**
- `ZonePresentation.make(placement:project:rollup:)` replaces the five builders. It takes an already-loaded registry entry, so the boot builder's `QARunManifestReader.latest` disk read stays out of the switch path.
- `ZoneRenderModel.scopeLabel` and the independent `zoneRenderModels` array go. Rollups live in `[UUID: AgentStatusRollup]` and patch in place.
- The chrome asks for its presentation on demand and caches by a hash of its inputs. `zoneScopeLabel` distinguishes 'unbound' from 'bound, registry miss' instead of 'Needs Project' for both.

**Risk.** Low-medium. Visual only; baselines move.

**History.** `--workspace-boot-persistence-check` and `--workspace-switch-check` are green at HEAD with both defects present because neither reads chrome.

**Hypotheses.**
- Missing builder after mount explains the visual half of complaint 2 exactly and deterministically. confidence=high
- Rollup copy-back explains the in-session flips. confidence=high

**Evidence.**
- The only builder that computes `scopeLabel`; it belongs to the flat scene that boot retires. ref=Sources/ContinuumRevived/App/ContinuumApp.swift:17351-17362
- install / switch / fallback / addProjectZone / ambient builders omit the label. ref=Sources/ContinuumRevived/App/WorkspaceRuntime.swift:745-748, 1579-1580, 636-640, 901, 952-953
- Rollup refresh replaces `zoneDisplayByZoneId` wholesale from the stale array. ref=Sources/ContinuumRevived/App/ContinuumApp.swift:8319-8324 → CanvasNSView.swift:5159-5164
- Provisional/commit/scope paths write the display entry, never the array. ref=Sources/ContinuumRevived/Canvas/CanvasNSView.swift:942-950, 977-1000, 1016-1041
- `zoneScopeLabel` renders 'Needs Project' on any registry miss. ref=Sources/ContinuumRevived/App/ContinuumApp.swift:14795-14803

**Fix plan.**
- Write `ZonePresentation.make`; call it from the install/switch/addZone/ambient sites.
- Delete `scopeLabel` storage and `zoneRenderModels`; add `updateZoneAgentRollups(_:)`.
- Regenerate UI baselines deliberately and review the diff (headers now show labels after mount).

**Files.**
- Sources/ContinuumRevived/Canvas/CanvasNSView.swift
- Sources/ContinuumRevived/App/WorkspaceRuntime.swift
- Sources/ContinuumRevived/App/ContinuumApp.swift

**Witness.** `` drives: mount, picker confirm through a QA seam, rename, scope change, rollup tick, switch, relaunch.
- asserts: After every step `zoneChromeSnapshot(for:)` shows `displayName == expected` and `scopeLabel == "<project> / <home or Project Root>"`.
- asserts: A rollup tick changes no header text.
- asserts: A new zone's rename repaints its header.

## ARC-5 · A gate that does not have to predict the bug: the workspace invariants harness
status=Ready severity=high complaint=0 area=matrix release=0.7.22 deps=[]

**Symptoms.** A 235-leg matrix stayed green while you hit all four complaints daily. The legs asserted plausible behaviour at checks-only entry points; nobody had written the leg for the bug you had.

**Summary.** Absorbs ARR-8 and ARR-11. **Invariant:** the release gate replays real user sequences against the real mount and asserts the four invariants above (ownership, wholeness, derived presentation, provenance), so a future regression of this class is caught without anyone predicting it. Why the matrix was green: the relevant legs call `install(into:)` instead of `mountWorkspaceSceneAtBoot`, arm only in the first workspace, never spawn into a layerless zone, never remount crash-style, and never read chrome or assert containment.

**Second opinion (GPT-6 Astra, verified in source by the orchestrator).** A test program, not one random check. Directed schedules and fault injection first (a blocked I/O queue, a failing save, a lost project lock, a crash between two writes), seeded state-machine sequences second. 'Disk == memory after every action' conflicts with deliberate debouncing; keep an oracle of accepted scene revision, pending intent and durable revision instead: before a flush, disk equals the last acknowledged durable state; after a barrier, the requested revision; a crash may lose unacknowledged work, never a reported durable transaction or half an aggregate. Record seed, fault index, fixture hash, action trace, epochs and receipts; shrink failures to a replayable trace. Read real rendered bounds as well as the model.

**Root cause.** **Design**
- `--workspace-invariants-check`: mount two seeded workspaces through `mountWorkspaceSceneAtBoot`; apply a seeded random sequence of real entry-point actions (arm by click, focus and camera; rename; scope; create zone; zone drag that pushes; tile drag; browser tier change; budget eviction; switch A→B→A; clean quit-remount; crash-style remount). After every step assert identity (disk == memory == chrome), isolation (each file holds only its own zones, the other file's bytes unchanged), stability (no frame moved without a `.user` transaction), containment, overlap policy, wholeness (every mounted zone has a layer, every tile a view). The seed goes in the manifest so a red run replays.
- Positive controls: an injected 1pt shift, an injected foreign zone and an injected ghost layer must each go RED.
- Each ARC adds its scenarios as it lands; the harness is the gate for the next.
- Also: register `--workspace-switch-polish-check` (claimed registered in `.plans/66`, absent from `run-matrix.sh`), register `--window-chrome-check` with ARR-1, correct hazard 9's stale sentence about `install(into:)`.

**Risk.** Low.

**History.** See `matrix-halts-hide-legs`: the matrix once reported 4 of 135 legs.

**Evidence.**
- 'A witness only counts if the gate reports it, and only if it watches behaviour.' ref=CLAUDE.md non-negotiable #2
- `--workspace-restart-fault-check` arms only in wa after returning. ref=Sources/ContinuumRevived/App/ContinuumApp.swift:26054-26081
- The fixture installs the layer production never would (hazard 9's own lesson, repeated). ref=Sources/ContinuumRevived/App/ZoneArmingChecks.swift:413
- `--workspace-switch-polish-check` not registered. ref=scripts/run-matrix.sh:653 vs .plans/66:41
- Production boot does call `runtime.install(into:)` after retiring the flat scene; hazard 9's text says it never does. ref=Sources/ContinuumRevived/App/ContinuumApp.swift:16207-16209

**Fix plan.**
- Harness skeleton: two-workspace fixture, deterministic scheduler, storage-fault and acquisition-failure injection, action log, receipts oracle.
- Directed scenarios land with ARC-0 (saver identity, note reuse, retired flat, durable receipt), then ARC-3, ARC-2, ARC-1, ARC-4 in that order.
- Seeded sequences once the directed set is green.
- Register `--workspace-switch-polish-check` (dispatch exists at ContinuumApp.swift:2224, no matrix registration) and `--window-chrome-check`; correct hazard 9.

**Files.**
- Sources/ContinuumRevived/App/WorkspaceInvariantsChecks.swift (new)
- scripts/run-matrix.sh
- docs/38-tickets/90-agent-ux/matrix-inventory.txt
- CLAUDE.md

**Witness.** `` drives: a real full matrix run on each ARC branch and its base.
- asserts: Identity/isolation: correct workspace, store and epoch; no mutation in another workspace or project; no stale callback after a switch.
- asserts: Conservation: every durable tile survives exactly once unless an acknowledged delete or transfer removed it; owner, backing reference and agent binding stay attached to the same identity.
- asserts: Completeness: the loaded model holds every known record at every tier, root tiles included; failed loads certify nothing; every transaction target resolves exactly once.
- asserts: Durability: acknowledgments describe successful durable generations; flush drains submitted work; failure and recovery yield one coherent revision.
- asserts: Geometry: WORLD frames stable under lifecycle operations; only the authorized effect closure moves; membership implies containment at rest; zones never overlap after accepted growth or drag.
- asserts: Projection: chrome and Home actions reflect canonical fields; status updates cannot alter identity or geometry.
- asserts: Lifecycle: one runtime/binding per tile, correct leases and refcounts, no observer leftovers.
- asserts: Repair/migration: originals preserved, classifications deterministic, second import idempotent.

## ARC-2 · A zone is whole or absent: complete scene data, a root for unzoned tiles, views and runtimes as caches
status=Ready severity=critical complaint=3 area=zone-hydration release=0.7.23 deps=['ARC-0', 'ARC-3']

**Symptoms.** On a fresh launch, an agent tile created in a zone shows `—` for its home and the Home chip does nothing until you restart or recreate the zone. Dragging near an off-screen zone moves the zone but leaves its tiles behind.

**Summary.** Absorbs ARR-4, ARR-7 and the ghost-zone half of ARR-5. **Invariant:** a zone in the mounted document has exactly one `ZoneLayer` from mount to unmount, holding a view for every persisted tile. The hydration tier decides which layers hold *runtimes*, never whether a layer exists. Today only zones inside the live budget (4, by viewport proximity at mount) get a layer; the rest are chrome-only ghosts. Clicking a ghost arms it and acquires its controller but never builds a layer, so a spawn falls into the flat model that boot already retired, where `tileView(for:)` cannot see it and `wireManagedAgentTile` returns silently: no record, `—`, dead chip. The same fallback saves the boot project's canvas over the armed project's `canvas.json`. The tier machinery itself only ever swaps browser runtimes (`dehydrate`/`hydrateToLive`), so it never needed to withhold layers. Descriptor views are an `NSView` and a label; the largest prod workspace has six zones.

**Second opinion (GPT-6 Astra, verified in source by the orchestrator).** The defect is confirmed; the invariant was too concrete. A zone without an NSView is not a defect; a complete geometric zone with an incomplete tile *model* is. Restated: the mounted scene holds complete data for every zone and tile independent of rendering and residency; views and provider processes are replaceable caches attached to records. Four things the first pass missed and this ticket now owns: (a) a tile's storage owner is a field on the tile, never inferred from the zone's Home (`setZoneScope` rewrites `layer.placement.projectId` and persistence partitions tiles by it, so rebinding a populated zone silently moves its tiles into the other project's file, against the code's own comment); (b) unzoned tiles need a scene root: close-keep-tiles only clears a cache and the flat state, the layer record is untouched; (c) a failed canvas read is not an empty canvas: `tryLoadCanvas` failures default to empty and the persistence merge then deletes absent tiles in covered zones; loads carry `unloaded / loaded(revision) / unavailable(error)` and only a successful load certifies coverage; (d) residency is per project, not per zone: the per-zone hydration plan is applied to a per-project controller, so two zones of one project issue contradictory tier requests. Always-present descriptor layers stay as an interim bridge for small scenes, not the invariant.

**Root cause.** **Design**
- `install(into:)`, `switchWorkspace` and `addProjectZone` build a layer for every mounted zone; `reconcileHydration` and `setActiveZone` can no longer produce chrome without tiles. The live budget keeps meaning what its comment says: a count of zones with live processes.
- The flat scene is deleted: `installProjectTile`'s flat fallback becomes `throw SpawnError.zoneNotMounted`; `persistProjectCanvas(.flatCanvasState)` goes; `spawnRunArtifacts`, `spawnDiffReviewFromPalette` and the `installInitial*` boot walk migrate to `installProjectTile` + `makeProjectTilePlacement`; `retireFlatCompatibilityScene`, `flatCompatibilitySceneActive` and the WORLD-frame flat `canvasState.tiles` model go with them. The boot walk's side jobs (minting missing note ids, writing the canvas) move into a one-time `LegacyCanvasImport` that runs before mount, never during render. Hazard 9's dual model ends; the frame conversions collapse to `memberTiles` in and `tilesInWorldFrames` out.
- Refusals are typed: `spawn` returns a `Result` whose failure names the guard; the caller beeps and logs (inert under QA env, hazard 6). A tile with no agent renders an explicit 'Not connected' state, never the constructor default.

**Risk.** Medium-high. Introduces the scene model behind adapters; the flat-scene deletion moves to the end of the program.

**History.** WS9 (`abd312d4`) made arming acquire a controller and treated that as enough. No prior commit or plan names the blank-home symptom; no `--*-check` flag contains 'home'.

**Hypotheses.**
- Half-real zones are the root of the blank agent home (about 85%, per the spawn trace) and of tiles left behind when a ghost is pushed (about 65%). confidence=high
- The retired-but-reachable flat scene is what turns a bad spawn into an invisible tile and a corrupted project file. confidence=high

**Evidence.**
- `guard plan.tier(for:) == .live else { continue }`; budget 4. Layers are installed only at :770, :904, :1599. ref=Sources/ContinuumRevived/App/WorkspaceRuntime.swift:688; ZoneHydrationBudgetConfig.swift:9
- Tier changes only swap browser runtimes via `installBrowserSnapshotTile` / `restartBrowserTile`; nothing about layers. ref=Sources/ContinuumRevived/App/ZoneRuntimeController.swift:570-612
- No layer → flat install with no signal; flat views invisible to `tileView(for:)` once the flat scene is retired (boot retires it at ContinuumApp.swift:16207-16209). ref=Sources/ContinuumRevived/Canvas/CanvasNSView.swift:6806-6819, 2223-2229
- Three silent guards: wiring returns with no view, the palette returns false, hydration skips a record-less tile forever. ref=Sources/ContinuumRevived/App/ContinuumApp.swift:13453, 13296-13299, 16482-16485
- `.flatCanvasState` branch saves the stale flat model into the armed project's `canvas.json`. ref=Sources/ContinuumRevived/App/TileSpawner.swift:2420-2421
- `resolveOuterCollisions` pushes every scene zone including ghosts; ghosts have no scene tiles to carry. ref=Sources/ContinuumRevived/Canvas/CanvasAutoLayoutEngine.swift:888-947
- 74 lines: an `NSView` container and one label. ref=Sources/ContinuumRevived/Canvas/DescriptorTileNSView.swift
- The size of the deletion. Most are boot walk, spawn fallback, persistence fallback or checks-only fixtures. ref=Sources/ContinuumRevived/Canvas/CanvasNSView.swift (117 `canvasState.tiles` sites, 20 `flatCompatibilitySceneActive` sites)
- `setZoneScope` doc: 'membership is layout, never filesystem identity'; body writes `layer.placement.projectId`; `tilesInWorldFrames(forProjectId:)` filters layers by it. ref=Sources/ContinuumRevived/Canvas/CanvasNSView.swift:1014-1041, 6603
- `setTileZone(_, nil)` updates the membership cache and flat `canvasState` only; close-keep-tiles then removes chrome while the layer keeps the tiles. ref=Sources/ContinuumRevived/Canvas/CanvasNSView.swift:317-325, 2104-2117
- Failed read → `CanvasState(tiles: [])`; merge deletes absent tiles in covered zones. ref=Sources/ContinuumRevived/App/WorkspaceRuntime.swift:507-509; TileSpawner.swift:2424-2429; CanvasPersistenceMerge.swift:52-55
- Per-zone plan, one `hydrationTier` per project controller. ref=Sources/ContinuumRevived/App/WorkspaceRuntime.swift:1788-1813; ZoneRuntimeController.swift:567

**Fix plan.**
- Scene nodes: zone, tile (with explicit `storageOwner`, membership, agent binding state `bound / unbound / unavailable`), and a workspace root for unzoned tiles; adapters over today's layers.
- Load states `unloaded / loaded(revision) / unavailable(error)`; coverage certified only by a successful load.
- Residency: reduce zone demands per project (strongest wins) now; budget per tile later.
- Layers for every mounted zone as the interim bridge (small scenes), then delete the flat scene once adapter coverage is complete (last step of the program).
- Typed spawn failures; 'Not connected' tile state.

**Files.**
- Sources/ContinuumRevived/App/WorkspaceRuntime.swift
- Sources/ContinuumRevived/Canvas/CanvasNSView.swift
- Sources/ContinuumRevived/App/TileSpawner.swift
- Sources/ContinuumRevived/App/ContinuumApp.swift
- Sources/ContinuumRevived/App/ZoneRuntimeController.swift
- CLAUDE.md

**Witness.** `` drives: `mountWorkspaceSceneAtBoot` with one zone in view and one at x≈20000; click the far zone; the real palette agent spawn including `wireManagedAgentTile`; a zone drag that pushes the far zone.
- asserts: Every mounted zone has exactly one layer and every persisted tile a view, after mount, after reconcile, after switch.
- asserts: The spawned tile is found by `tileView(for:)`, has a record with the far project's root, shows its name, and Change Home writes through.
- asserts: The far project's `canvas.json` holds the new tile and not the near project's tiles; the near file is unchanged.
- asserts: Pushing the far zone moves its members by exactly the zone delta.
- asserts: A spawn into an unmounted zone id throws `zoneNotMounted` and the QA sound/log hook records one beep and one line.
- asserts: Rebinding a populated zone's Home from A to B leaves existing members in A's store with their owners unchanged; a tile created afterwards belongs to B.
- asserts: Close-keep-tiles reparents members to the scene root without moving them; they survive remount.
- asserts: An unavailable project store mounts as unavailable with chrome and an error, never as empty, and no save deletes its tiles.
- asserts: Two zones of one project resolve to one deterministic residency.

## ARC-1 · One owner for the workspace truth: a commit coordinator with truthful receipts and recoverable multi-store commits
status=Ready severity=critical complaint=0 area=workspace-model release=0.7.23 deps=['ARC-0', 'ARC-2']

**Symptoms.** Zone names and homes revert, zones you created vanish, a workspace comes back holding another workspace's zones. Underneath every one of these, something you did was written to disk and something older, or something from a different workspace, was written on top.

**Summary.** Absorbs ARR-2, ARR-6, ARR-12 and the persistence half of ARR-10. **Invariant:** while a workspace is mounted, exactly one object holds its document, every change is a `commit(mutation)` on that object, and disk is written only by that object's single save pipeline. Disk is read at mount and switch, never in between. Today eight code paths mutate and save the document with their own controllers: the arming autosave stays bound to whichever workspace armed first and is never rebound on switch (so arming in B writes B's document into A's file), every sync save builds a fresh controller that never supersedes the arming snapshot, and six `AppDelegate` writers do disk load → partial mutate → save → `replaceDocument`. The prod data already shows the damage: the `personal` workspace file holds two `harmony` zones owned by `work`, and an orphan workspace file (`7A40C21D`, not in the registry) holds byte-identical copies of `personal`'s zones with the same zone ids. The registry also records project ownership twice (`project.workspaceId` and `workspace.projectIds`), and they already disagree for four of seven projects.

**Second opinion (GPT-6 Astra, verified in source by the orchestrator).** Direction kept, scope corrected. A single document saver is not a transaction across the registry, the workspace document, N project canvases and agent records. The coordinator must add: truthful acknowledgments (submitted vs durable generations); a recoverable protocol for multi-store operations (a small durable intent record with transaction id, identities, expected revisions and payloads; a commit point; idempotent recovery before mount); complete-resolution accounting in layout transactions (today missing projects, canvases, zone ids and tile ids are skipped and `true` is still returned, which the canvas trusts to not revert); a prepared-session lease that releases every acquisition when a switch fails; and session-epoch fencing so a picker or async callback that outlives a switch cannot write into the new workspace. Quarantine becomes a derived classification over preserved raw records (valid / foreign-owned / unresolved / conflicting), not a second durable array. The 'about 200 lines' estimate is withdrawn; this lands after ARC-2 so it commits a whole scene.

**Root cause.** **Design**
- `WorkspaceModel` inside `WorkspaceRuntime` owns `document`, `generation` and one `WorkspaceDocumentSaveController` created at mount and drained and dropped before `workspaceId` changes. Urgency (`.flush` for deliberate acts, `.debounce` for ambient arming) is a property of the mutation, not a second controller. The debounced write reads the live document when it fires; it never holds a copy.
- `WorkspaceMutation` covers every write that exists today: `arm`, `createZone`, `closeZone(deletingTiles:)`, `placeZone`, `renameZone`, `setZoneScope` (project + home atomically), `setZoneAutoLayout`, `bringToFront`, `commitLayoutTransaction` (zones and ambient tile frames from one gesture), `setAmbientTiles`, `setLinks`, `setViewport`, `setCanvasBackground`, `setLastExplicitCreationScope`. The `AppDelegate` writers become `commit` calls. `replaceDocument` is deleted.
- `WorkspaceDocument` v10 carries `workspaceId`; `WorkspaceStore.save` refuses a mismatch; the pipeline refuses to flush after the runtime has moved on.
- Ownership recorded once in the registry, one writer, and `exclusiveWorkspaceOwner` reads that field.
- Quarantine, not deletion: on load, zones whose project belongs to another workspace move to `quarantinedZones`, never mounted, never dropped, listed in the sidebar with 'move to its workspace' / 'delete' that the user clicks. This is the audit done once, in the model, on every load.
- `canvas.json`: one serial pipeline (`canvasSaveQueue`) every writer enqueues on; sync callers wait on it. The flat-fallback writer disappears with ARC-2.

**Risk.** Medium-high. This is the transaction design; it needs its own design review and fault witnesses. Lands after ARC-2.

**History.** The zone-revert family was declared fixed at least six times (0.5.10–0.5.20) with two in-repo retractions; none touched the save controllers. `--workspace-switch-check` and `--workspace-restart-fault-check` are green at HEAD because neither arms in the second workspace before switching back.

**Hypotheses.**
- Cross-workspace write through the never-rebound arming controller. Certain from the code and now observed in the prod files. confidence=high
- Disk-reading writers (`persistLayoutTransaction`, `persistMovedZone`, `persistRenamedZone`, `persistCreatedGroupZone`, `persistLastExplicitCreationScope`) pull stale or foreign disk state into the live runtime. confidence=high
- Stale 200ms whole-document snapshot overwrites a sync save made inside the window; wins after a crash or whenever a disk-reading writer runs next. confidence=medium

**Evidence.**
- Arming controller created once with the first `workspaceId`, never reset; `switchWorkspace` changes `workspaceId` at :1616. ref=Sources/ContinuumRevived/App/WorkspaceRuntime.swift:347,422-427,1616
- Holds `pendingDocument` as a value copy, writes it 200ms later (`AutosaveConfig.defaultDebounceMs`). ref=Sources/ContinuumRevived/App/WorkspaceDocumentSaveController.swift:39-70
- `saveWorkspaceDocument` builds a fresh controller per sync save; nothing supersedes the pending arming snapshot. ref=Sources/ContinuumRevived/App/WorkspaceRuntime.swift:1435-1444
- Six `store.load()` → mutate → `replaceDocument` writers, contrary to `commitZonePlacement`'s own contract at WorkspaceRuntime.swift:105-108. ref=Sources/ContinuumRevived/App/ContinuumApp.swift:14562,14603,14644,14677,14779,14961
- `save` has no identity check; `WorkspaceDocument` (schema v9) carries no `workspaceId`. ref=Sources/ContinuumRevivedCore/WorkspaceStore.swift:62-64
- `mountableZones` hides foreign zones at mount; `persistDepartingWorkspaceState` writes them back, so files never self-heal. ref=Sources/ContinuumRevived/App/WorkspaceRuntime.swift:1677-1686, 1861-1885
- `personal` (42B93EF0): 6 zones, two of them `harmony` zones owned by `work`. Orphan file 7A40C21D (not in registry): 4 zones, same zone ids as `personal`'s. `work`: 1 zone. Registry: 7 projects, 3 workspaces; `selectus`, `andable`, `work`, `Documents` have no owner while `personal.projectIds` lists two. ref=~/Library/Application Support/Array (read-only audit 2026-09-27)
- `canvas.json`: one async queue writer plus two sync main-thread writers that skip the queue. ref=Sources/ContinuumRevived/App/ZoneRuntimeController.swift:682-742; TileSpawner.swift:2415; ContinuumApp.swift:14695-14722
- Layout persistence skips missing zone ids, projects, canvases and tile ids and still returns true; `CanvasNSView.swift:2780-2782` uses that to keep the installed geometry. ref=Sources/ContinuumRevived/App/ContinuumApp.swift:14679, 14705-14719, 14746
- Registry ownership saved before the zone document; a later failure leaves ownership without a zone. ref=Sources/ContinuumRevived/App/WorkspaceRuntime.swift:128-135; ContinuumApp.swift:14905-14924
- N canvases then the document; rollback is best-effort and a crash between writes never runs it. ref=Sources/ContinuumRevived/App/ContinuumApp.swift:14728-14738
- Acquisitions before a throwing registry save; `acquiredProjectIds` assigned only on success; no cleanup. ref=Sources/ContinuumRevived/App/WorkspaceRuntime.swift:1528, 1591, 1618
- Picker confirm reads the current `workspaceId`, not the one captured at presentation. ref=Sources/ContinuumRevived/App/ContinuumApp.swift:14874-14876, 14925-14939

**Fix plan.**
- Introduce `WorkspaceMutation` and the coordinator; route every mounted writer through it; delete `replaceDocument`.
- Receipts: submitted vs durable generations per store; flush waits through the requested generation; failure surfaces at switch and quit.
- Recoverable multi-store commits: intent record, commit point, idempotent recovery before mount; fault witnesses at every crash prefix.
- Complete-resolution accounting for layout transactions.
- Prepared-session lease for `switchWorkspace`; session-epoch fencing for pickers and async callbacks.
- Schema v10 `workspaceId` + store identity check; registry ownership recorded once; derived quarantine classification with a repair preview the user accepts.

**Files.**
- Sources/ContinuumRevived/App/WorkspaceRuntime.swift
- Sources/ContinuumRevived/App/WorkspaceDocumentSaveController.swift
- Sources/ContinuumRevived/App/ContinuumApp.swift
- Sources/ContinuumRevivedCore/WorkspaceDocument.swift
- Sources/ContinuumRevivedCore/WorkspaceStore.swift
- Sources/ContinuumRevivedCore/Registry.swift
- Sources/ContinuumRevived/App/ZoneRuntimeController.swift

**Witness.** `` drives: `mountWorkspaceSceneAtBoot` with two seeded workspaces; real `onZoneActivated` and tile-focus arming; `switchWorkspace`; the drained debounce; a clean quit-remount and a crash-style remount.
- asserts: After arming in B and draining, A's file bytes are unchanged.
- asserts: No file holds a zone whose project's owner is another workspace, unless seeded; a seeded foreign zone appears in `quarantinedZones`, is not mounted, and is not dropped.
- asserts: Arm, then commit a sync rename inside the debounce window, then drain: disk equals memory.
- asserts: A committed layout transaction never reloads disk: `runtime.document` generation strictly increases and equals the persisted generation after flush.
- asserts: `WorkspaceStore.save` with a mismatched `workspaceId` throws.
- asserts: Every identity in a layout transaction resolves exactly once; a missing member store or a duplicated tile id refuses the whole transaction and leaves the committed scene unchanged.
- asserts: Fail after each participating write of a multi-store commit, remount: the scene is wholly before or wholly after, never mixed.
- asserts: Fail acquisition at each index and at the final registry save during a switch: old scene, refcounts and locks unchanged.
- asserts: A picker confirmed after a switch is rejected before any registry write.

## ARC-4 · Geometry has provenance: materialize is not spawn, and containment and overlap are checked where geometry is committed
status=Ready severity=critical complaint=4 area=canvas-layout release=0.7.24 deps=['ARC-1', 'ARC-2']

**Symptoms.** Tiles shift inside zones after a switch or after a while. You come back to overlapping zones, and to tiles outside a zone that still count as inside it.

**Summary.** Absorbs the rest of ARR-5. **Invariant:** a tile or zone frame changes only in a layout transaction that names its source, and every committed scene satisfies containment and the overlap policy. Frame round-trips hold for the main conversions but not for every writer (ARC-0's note-conversion path proves it); the other movers are below. `installProjectTile` always means spawn (grow the zone, re-settle every member, commit), and nine of its seventeen callers are not spawns but swaps of the view for an existing tile: browser snapshot and restart, terminal restart, inspector install, profile switch, note convert and restore, file-tree install and error view. Panning, budget eviction (including right after a switch, outside the suppressed block), WebContent crashes and popups therefore move the user's tiles. Zone growth never resolves peers; only a dragged zone does (policy decided: growth pushes, never overlaps). Nothing enforces containment or non-overlap; `resolveZoneMembership` stamps membership without geometry, so a member outside its zone persists silently.

**Second opinion (GPT-6 Astra, verified in source by the orchestrator).** Keep materialize/spawn and final validation. Replace `.user/.system` labels with *cause plus authorized effect closure*: a user spawn or resize authorizes its deterministic push chain; an agent grant must include the push explicitly or get a spatial-capacity refusal; lifecycle restoration authorizes no geometry change, including its own tile. Drop the silent production grow-to-contain (it moves things without a gesture and contradicts the stability requirement): preserve damaged layouts and offer a repair preview. Containment is a membership constraint against the zone's content bounds, defined once (not 'full rect' in one place and 'centre exited' in another). The solver's bounded loop can fail to converge; validate the result and refuse the whole candidate. Undo restores the entire push closure. Note-to-document conversion is a content mutation plus a view replacement, so it still needs a durable command.

**Root cause.** **Design**
- Split `installProjectTile` into `spawn(placement:)` (choose placement, grow, arrange, commit) and `materialize(tileId:view:)` (swap the view, frame untouched, no grow, no settle, no commit). The nine swap callers use `materialize`. Hydration Phase B's `withAutoLayoutSuppressed` becomes unnecessary.
- `CanvasLayoutTransaction.source` is `.user(gesture)`, `.agent(grant)` or `.system(reason)`. The model refuses a `.system` transaction that moves anything other than the tile it is about, and refuses a `.system` zone move outright.
- `SceneInvariants.validate(scene)` runs on every `commitLayoutTransaction` and on mount: every member's world frame inside its zone rect (or the zone grows to contain it in the same transaction); no two zones overlap under the chosen policy; membership equals containment (a tile whose centre leaves its zone is re-homed or broken out; the rescue never stamps without geometry). QA refuses a violation; prod self-heals by grow-to-contain and logs it.
- `growZoneToFitMembers` writes through `mutateZonePlacement` so the layer and the chrome never disagree.
- **Growth policy (decided by Dylan 2026-09-28):** zone growth is user-caused (a spawn or a resize you made), so it pushes neighbouring zones exactly as a drag does, and never overlaps them. `resolveOuterCollisions` runs after every growth (resize-pressure, `expandZoneToContainMembers`, `growZone`, grow-on-spawn, tidy) with the grown zone as the active zone. The push is part of the same `.user` transaction, so it carries provenance and the pushed zones carry their tiles (ARC-2).

**Risk.** Medium-high: the only change with real design risk (jelly semantics). Lands last, on a scene that is already whole and owned. `--jelly-auto-layout-check`, `--zone-breakout-check`, `--zone-tile-hydration-check` and browser-budget legs will move.

**History.** 0.7.13 shipped a rounding-drift hotfix without a full matrix. WS2 persistence went through corrective iterations F→I→K→M→O before `e9dc7143`; that fixed defect is covered by `--ambient-tile-frame-space-check` and stays green.

**Hypotheses.**
- Spawn-shaped reinstalls are the main in-zone drift (about 70%). confidence=high
- Reverted pushes (ARC-1) plus peer-blind growth produce the overlaps (about 60%). confidence=medium
- Ghost pushes (ARC-2) plus stamp-without-geometry rescue produce members outside their zone (about 65%). confidence=medium

**Evidence.**
- The eight true spawns. ref=Sources/ContinuumRevived/App/TileSpawner.swift:325,950,1034,1216,1586,2021,2071,2382
- The nine view swaps that today go through spawn semantics. ref=Sources/ContinuumRevived/App/TileSpawner.swift:646,1071,1123,1253,1481,2167,2191,6250,6263
- `arrangeAutoLayoutAfterSpawn`: expand + settle whole zone, commit, persist. ref=Sources/ContinuumRevived/Canvas/CanvasNSView.swift:829-845, 6800-6850
- `enforceBrowserRuntimeBudget()` runs outside the suppression block after Phase B. ref=Sources/ContinuumRevived/App/ContinuumApp.swift:16525 vs 16496
- `resolveOuterCollisions` runs only with an active dragged zone; resize-pressure growth returns before it. ref=Sources/ContinuumRevived/Canvas/CanvasAutoLayoutEngine.swift:895, 128-160
- Rescue stamps without containment; layer tiles never re-evaluate membership; `growZoneToFitMembers` updates `liveZones` but the layer rect is what persists. ref=Sources/ContinuumRevivedCore/ZoneMembershipRepair.swift:83-96; CanvasNSView.swift:1986-1987, 1977, 2577-2583
- Three WS1 defects reviewed, confirmed and left open: `updateTile` non-atomic rejection, noncanonical-peer over-constraint, silent `growZoneToFitMembers` no-op. ref=.plans/54-run-ledger.md

**Fix plan.**
- Split materialize from spawn; convert the nine swap callers; centralize view teardown (subscriptions, focus registrations retire once).
- Layout command = cause + workspace epoch + baseline revision + affected ids + accepted before/after geometry + full effect closure.
- `SceneInvariants.validate` on every commit and on mount: containment (one definition), non-overlap after accepted growth or drag; non-convergence refuses.
- Growth pushes neighbours through `resolveOuterCollisions` with the grown zone active, inside the same transaction.
- Membership in the layer world; rescue never stamps without geometry; no automatic repair of damaged layouts, a preview instead.
- `growZoneToFitMembers` through `mutateZonePlacement`.

**Files.**
- Sources/ContinuumRevived/Canvas/CanvasNSView.swift
- Sources/ContinuumRevived/Canvas/CanvasAutoLayoutEngine.swift
- Sources/ContinuumRevived/App/TileSpawner.swift
- Sources/ContinuumRevived/App/ZoneRuntimeController.swift
- Sources/ContinuumRevivedCore/ZoneMembershipRepair.swift
- Sources/ContinuumRevived/App/WorkspaceRuntime.swift

**Witness.** `` drives: mount two workspaces with hand-spaced (non gap-contact) members and a browser tile; pan away and back; run the browser budget; switch A→B→A; one user zone drag that pushes a neighbour; a crash-style remount; a clean remount.
- asserts: No frame moved without a `.user` transaction in the action log (tolerance 0).
- asserts: Every member tile's world frame is inside its zone rect after every step.
- asserts: No two zones overlap under the chosen policy.
- asserts: A `.system` transaction that would move another tile is refused.

## ARR-1 · Land the merged titlebar that was built on 9/13 but never shipped
status=Ready severity=medium complaint=1 area=window-chrome release=0.7.22 deps=[]

**Symptoms.** The macOS titlebar is still drawn above the workspace bar. You remember a build where they were merged.

**Summary.** No agent lied, but nobody landed it either. Commit `61416361` (feat(window-chrome): merge the workspace bar into the titlebar, 2026-09-13) implements the merge with a `--window-chrome-check` witness and sits alone on `array/topbar-merge` in `.worktrees/topbar-merge`. It was reviewed APPROVE during the 0.7.21 crunch and then deliberately held back: `.plans/65` marks it "Not landed; no real fullscreen/window-drag/taste QA. Preserve original ownership." No preview app was ever built from it (the 0721 Preview binary lacks the `--window-chrome-check` string). Integration HEAD `1451c030` still has the old style mask and a fixed 38pt bar.

**Risk.** Low. UI-only, one witness, one merge conflict.

**History.** Written and witnessed 2026-09-13. Coordinated but withheld during 0.7.21 (`.plans/65`). Never in `docs/VERSIONING.md`.

**Hypotheses.**
- Process hold, not a defect: the branch merges onto integration with one trivial conflict in `scripts/run-matrix.sh` (both sides inserted a `run_app_check` line in the same spot). `ContinuumApp.swift` and `WorkspaceTopBarView.swift` auto-merge clean. confidence=high

**Evidence.**
- Integration still builds the window with `[.titled, .closable, .miniaturizable, .resizable]`, no `.fullSizeContentView`. ref=Sources/ContinuumRevived/App/ContinuumApp.swift:4800
- `WorkspaceTopBarView` is a fixed 38pt row inside the content pane; the canvas anchors to its bottom. ref=Sources/ContinuumRevived/App/ContinuumApp.swift:10082-10104
- `applyMergedTitlebarChrome` sets `titlebarAppearsTransparent`, `titleVisibility = .hidden`, `.fullSizeContentView`; bar hoisted beside the split view; `trafficLightInset` 76 (0 in fullscreen); `mouseDownCanMoveWindow` true. ref=array/topbar-merge @ 61416361
- "Existing topbar … Not landed; no real fullscreen/window-drag/taste QA." ref=.plans/65-release-0.7.21-coordination.md

**Fix plan.**
- Merge `array/topbar-merge` onto `array/integration`; keep both `run_app_check` lines in the matrix conflict.
- Manual QA the reviewer flagged: real fullscreen enter/exit and real drag-to-move on a Tahoe titlebar height (the 28 vs 32pt branch was only measured at runtime, never eyeballed).
- Rebuild the preview app from the merged branch and confirm the chrome in a screenshot on this ticket.
- Full matrix; confirm `--window-chrome-check` and `--workspace-top-bar-check` both print in the summary.

**Files.**
- Sources/ContinuumRevived/App/ContinuumApp.swift
- Sources/ContinuumRevived/App/WorkspaceTopBarView.swift
- scripts/run-matrix.sh

**Witness.** `` drives: the real window construction in `AppDelegate`, then simulated fullscreen enter/exit delegate callbacks.
- asserts: Content spans the full frame; no separate titlebar strip.
- asserts: Title hidden but non-empty; titlebar transparent.
- asserts: The bar is a direct subview of the content container at x=0 touching the top; the split view begins exactly where the bar ends.
- asserts: Workspace-name label clears the traffic lights by at least 12pt.
- asserts: Fullscreen enter drops the traffic-light inset to 0; exit restores 76.

## ARR-9 · Triage the nine unowned red matrix legs
status=Triage severity=medium complaint=0 area=matrix release=0.7.22 deps=[]

**Symptoms.** The gate that is supposed to catch these regressions has nine failures nobody owns, so a green run does not mean what it should.

**Summary.** The 0.7.21 gate ran 235 legs; nine failed outside `MATRIX_KNOWN_RED` and reproduced byte-for-byte on the clean base `2cec73ff`. Each needs an owner and a decision: fix, or document in `MATRIX_KNOWN_RED` with a reason. Two are relevant to this program: `--file-tile-zoom-check` (title-compositor drift 2.4397, the 'shift over time' family) and `--agent-supervisor-check` (SIGSEGV in agent lifecycle). `--session-resume-check` is a persisted-state resume mismatch of the same class as ARR-3.

**Risk.** Low.

**History.** Recorded in `.plans/66` and the 0.7.21 ledger row as unowned.

**Evidence.**
- exit 139, SIGSEGV, on candidate and clean base. ref=--agent-supervisor-check
- `title compositor drift; difference 2.439717294900222` (`CanvasZoomInvalidationProbeChecks.swift:231`, threshold 2). ref=--file-tile-zoom-check
- `A12 FAIL: browser URL must be the specific persisted URL`. ref=--session-resume-check
- `capabilities from the preset grant`. ref=--workspace-api-open-check
- focus fixtures: `keyDown should edit note text; got ""`, `padding click alone should focus the editor`. ref=--note-click-focus-check / --agent-tile-click-focus-check
- host toolchain: `ld: tapi error: malformed file` in the macOS 27 SDK `libSystem.B.tbd`. ref=--terminal-tmux-observer-check / -wiring-check
- missing dev dependency `jsdom`. ref=npm test --prefix Tools/TaskEditor

**Fix plan.**
- Assign each leg; fix the cheap ones (jsdom, focus fixtures).
- Bisect the supervisor segfault on a bench.
- Document the SDK linker failure as KNOWN-RED with the SDK version until the host toolchain is fixed.

**Files.**
- scripts/run-matrix.sh
- .plans/66-release-0.7.21-nightly.md

**Witness.** `` drives: a real full matrix run.
- asserts: Zero legs fail outside `MATRIX_KNOWN_RED`.
- asserts: Every KNOWN-RED entry has a written reason.

## ARR-10 · A zone rename in progress survives hotkeys and quit
status=Ready severity=medium complaint=2 area=zone-chrome release=0.7.23 deps=['ARC-1']

**Symptoms.** You rename a zone, do something else quickly, and the old name is back.

**Summary.** The committed rename path is sound: `applyZoneRename` → `commitZonePlacement` saves synchronously and switch/quit flush first. What is not covered is the field editor while it is open. `installHotkeyMonitor`'s local keyDown monitor swallows reserved shortcuts (workspace switch, possibly Cmd+Q) before the rename `NSTextField` sees them, and the shortcut gate only protects the agent-inbox text field, not `renamingZoneId`. A hotkey mid-rename never reaches the Enter/Esc/blur commit, so the edit is discarded and the pre-rename name is what persists. The persistence half (the stale-snapshot overwrite and `persistRenamedZone`'s fallback) moved to ARC-1; this ticket is only the input-handling seam.

**Risk.** Low.

**Hypotheses.**
- Hotkey monitor swallows the commit keystroke while a rename field is open (`ContinuumApp.swift:7536`, gate `isTextEditorFocusedForGlobalShortcutGate`). confidence=medium

**Evidence.**
- Local `.keyDown` monitor consumes reserved shortcuts first. ref=Sources/ContinuumRevived/App/ContinuumApp.swift:7536
- `persistRenamedZone`: runtime branch returns on error with only a stderr line. ref=Sources/ContinuumRevived/App/ContinuumApp.swift:14753-14775
- Covers mouse-driven commit paths; never simulates a hotkey or quit while the field is open. ref=--zone-rename-inline-check

**Fix plan.**
- Gate the hotkey monitor on any active field editor (`renamingZoneId` included), or commit the rename before dispatching the shortcut.
- Make `persistRenamedZone` fall through to the disk branch on `zoneNotFound`.

**Files.**
- Sources/ContinuumRevived/App/ContinuumApp.swift
- Sources/ContinuumRevived/Canvas/CanvasNSView.swift

**Witness.** `` drives: the real rename field, then a reserved hotkey (workspace switch) and a quit-equivalent flush while the field is open.
- asserts: The typed name is committed (or explicitly cancelled) before the shortcut acts; it is never silently dropped.
- asserts: Disk document name equals the in-memory name after the flush.
