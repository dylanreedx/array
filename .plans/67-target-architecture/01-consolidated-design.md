# Array stability: the consolidated shape

Written 2026-09-27 against integration HEAD 1451c030, after the fifteen-agent read-only investigation. The twelve board tickets described where the app breaks. This document describes the shape that makes those breaks impossible, and folds the twelve tickets into five architecture changes plus three small ones.

## What is actually wrong, in five sentences

1. The workspace document has no owner: eight code paths mutate and save it with their own controllers, one of which stays bound to a workspace the app has left, and several read disk back into memory while mounted.
2. Zone headers are built by five builders from stored strings, and a stale third copy of the models is written back over the display on every agent tick.
3. A zone can be half real: chrome without a layer. Every downstream path (spawn, jelly, membership, persistence) has a branch for that state or gets it silently wrong.
4. There are still two tile models, and the retired one is reachable: a spawn into a half-real zone lands in it and becomes invisible to the code that wires it.
5. "Install a tile" always means "spawn": grow the zone and re-settle everything. Snapshot, restart and restore all go through it, so panning, budget eviction and crashes move the user's tiles; and there is no invariant anywhere that says a member sits inside its zone or that zones do not overlap.

The prod data already shows the damage. The `personal` workspace file holds two `harmony` zones owned by `work`, and an orphan workspace file (`7A40C21D`, not in the registry) holds byte-identical copies of `personal`'s zones with the same zone ids. That is the cross-workspace write, in the wild.

## The five changes

### ARC-1. One owner for the workspace truth
**Invariant:** while a workspace is mounted, exactly one object holds its document, every change is a `commit(mutation)` on that object, and disk is written only by that object's one save pipeline. Disk is read at mount and switch and never in between.

- `WorkspaceModel` (inside `WorkspaceRuntime`) owns `document`, `generation`, and one `WorkspaceDocumentSaveController` created at mount and drained and dropped before `workspaceId` changes. Urgency (`.flush` for deliberate acts, `.debounce` for ambient arming) is a property of the mutation, not a second controller. The debounced write reads the live document when it fires; it never holds a copy.
- `WorkspaceMutation` covers every write that exists today: `arm(zoneId, reason)`, `createZone`, `closeZone(deletingTiles:)`, `placeZone` (move/resize), `renameZone`, `setZoneScope` (project + home atomically), `setZoneAutoLayout`, `bringToFront`, `commitLayoutTransaction` (zones and ambient tile frames from one gesture), `setAmbientTiles`, `setLinks`, `setViewport`, `setCanvasBackground`, `setLastExplicitCreationScope`. The eight `AppDelegate` writers that do `store.load()` → mutate → `replaceDocument` (`ContinuumApp.swift:14562, 14603, 14644, 14677, 14779, 14961`) become calls to `commit`. `replaceDocument` is deleted.
- **Identity.** `WorkspaceDocument` v10 carries `workspaceId`. `WorkspaceStore.save` refuses a document whose id is not the store's. The pipeline refuses to flush after the runtime has moved to another workspace.
- **Ownership recorded once.** The registry records project ownership twice today (`project.workspaceId` and `workspace.projectIds`); in the prod registry they already disagree for four of seven projects. One field, one writer, and `exclusiveWorkspaceOwner` reads it.
- **Quarantine, not deletion.** On load, zones whose project belongs to another workspace move to `quarantinedZones`: never mounted, never dropped, listed in the sidebar with a one-click "move to its workspace" or "delete" that the user performs. This is the ARR-12 audit done once, inside the model, on every load, forever.
- `canvas.json` gets the same treatment: one serial pipeline (`canvasSaveQueue`) that every writer enqueues on; synchronous callers wait on it. The flat-fallback writer disappears with ARC-2.

Absorbs ARR-2, ARR-6, ARR-12 and the persistence half of ARR-10.

### ARC-2. A zone is whole or absent
**Invariant:** a zone in the mounted document has exactly one `ZoneLayer` from mount to unmount, holding a view for every persisted tile. The hydration tier decides which layers hold *runtimes*, never whether a layer exists.

- Today the tier machinery already only swaps browser runtimes (`ZoneRuntimeController.dehydrate`/`hydrateToLive`, :570-612); it never had a reason to withhold layers. Descriptor views are an `NSView` and a label (`DescriptorTileNSView.swift`, 74 lines). Dylan's largest workspace has six zones. The budget of four live zones stays, and means what its comment says: a count of zones with live processes.
- `install(into:)`, `switchWorkspace` and `addProjectZone` build layers for every mounted zone; `reconcileHydration` and `setActiveZone` can no longer produce chrome without tiles; `ensureLayerInstalled` is unnecessary because the state it repairs cannot exist.
- **The flat scene is deleted.** `installProjectTile`'s flat fallback becomes `throw SpawnError.zoneNotMounted`; `persistProjectCanvas(.flatCanvasState)` goes; `spawnRunArtifacts`, `spawnDiffReviewFromPalette` and the `installInitial*` boot walk migrate to `installProjectTile` + `makeProjectTilePlacement`; `retireFlatCompatibilityScene`, `flatCompatibilitySceneActive` and the WORLD-frame flat `canvasState.tiles` model go with them. The boot walk's side jobs (minting missing note ids, writing the canvas) move into a one-time `LegacyCanvasImport` that runs before mount and never during render. Hazard 9's dual model ends; the boundary conversions collapse to one place (`memberTiles` in, `tilesInWorldFrames` out).
- **Refusals are typed.** `spawn` returns a `Result` whose failure names the guard; the caller beeps and logs. `wireManagedAgentTile`'s silent `guard … else { return }` becomes impossible because the tile it looks up is always in a layer. A tile with no agent renders an explicit "Not connected" state, never the constructor default.

Absorbs ARR-4, ARR-7 and the ghost-zone half of ARR-5.

### ARC-3. Presentation is derived, never stored
**Invariant:** a zone's header is a pure function of `(placement, registry entry, rollup)`. Nothing stores a label string.

- One builder, `ZonePresentation.make(placement:project:rollup:)`, replaces the five (`ContinuumApp.swift:17351`, `WorkspaceRuntime.swift:745, 1579, 636, 901, 952`). It takes an already-loaded registry entry; no disk I/O per zone, so the boot builder's `QARunManifestReader.latest` read stays out of the switch path.
- `ZoneRenderModel.scopeLabel` and the independent `zoneRenderModels` array go. Rollups live in `[UUID: AgentStatusRollup]` and patch in place; `applyAgentStatusesToCanvas` (`ContinuumApp.swift:8319-8324`) can no longer overwrite a name or a home.
- The chrome asks for its presentation on demand and caches by a hash of its inputs. UI baselines will move once headers show the home label after mount; regenerate them deliberately and review the diff.

Absorbs ARR-3.

### ARC-4. Geometry has provenance, and invariants are checked where geometry is committed
**Invariant:** a tile or zone frame changes only in a layout transaction that names its source, and every committed scene satisfies containment (member inside its zone) and the overlap policy.

- **Materialize is not spawn.** Of the seventeen `installProjectTile` callers, eight are spawns (`spawnTerminal`, `spawnBrowser`, `spawnBrowserForNewWindow`, `spawnBrowserInspector`, `spawnManagedAgent`, `spawnNote`, `spawnBoard`, `spawnFileImpl`) and nine are swaps of the view for an existing tile (`restartTerminalTile`, `installBrowserSnapshotTile`, `restartBrowserTile`, `installBrowserInspectorTile`, `switchBrowserTileProfile`, `convertNoteToDocument`, `restoreNoteView`, `installFileTreeView`, `installFileTreeErrorView`). The nine get `materialize(tileId:view:)`: frame untouched, no grow, no settle, no commit. Hydration Phase B's `withAutoLayoutSuppressed` becomes unnecessary because nothing it wraps can arrange.
- **Provenance.** `CanvasLayoutTransaction.source` is `.user(gesture)`, `.agent(grant)` or `.system(reason)`. The model refuses a `.system` transaction that moves anything other than the tile it is about, and refuses a `.system` zone move outright. This is the sentence "my layout does not change without my doing" written as a check.
- **Invariants at commit.** `SceneInvariants.validate(scene)` runs on every `commitLayoutTransaction` and on mount: every member's world frame inside its zone rect (or the zone grows to contain it in the same transaction); no two zones overlap under the chosen policy; membership equals containment (a tile whose centre leaves its zone is re-homed or broken out; `resolveZoneMembership` never stamps without geometry). QA refuses a violation; prod self-heals by grow-to-contain and logs it.
- **Ghost zones** no longer exist (ARC-2), so a push always carries tiles; the jelly scene is complete by construction.
- **Policy question for Dylan:** may non-drag zone growth push a neighbour? Recommended: no. Growth clips and reports; only a user drag pushes. Pushing a zone you never touched is itself a change without your doing.

Absorbs the rest of ARR-5.

### ARC-5. A gate that does not have to predict the bug
**Invariant:** the release gate replays real user sequences against the real mount and asserts the four invariants above, so a future regression of this class is caught without anyone writing a leg for it first.

- `--workspace-invariants-check`: mount two seeded workspaces through `mountWorkspaceSceneAtBoot`; apply a seeded random sequence of real entry-point actions (arm by click, focus and camera; rename; scope; create zone; zone drag that pushes; tile drag; browser tier change; budget eviction; switch A→B→A; clean quit-remount; crash-style remount with no departing flush). After every step assert: identity (name and scope on disk equal memory equal chrome), isolation (each file holds only its own zones; the other file's bytes are unchanged), stability (no frame moved without a `.user` transaction in the log), containment, overlap policy, wholeness (every mounted zone has a layer and every persisted tile a view). The seed goes in the manifest so a red run replays.
- Positive controls: an injected 1pt shift, an injected foreign zone and an injected ghost layer must each go RED.
- The three per-bug legs on the old tickets become named scenarios inside this harness. `--window-chrome-check` and `--workspace-switch-polish-check` get registered; hazard 9's stale sentence about `install(into:)` is corrected.

Absorbs ARR-8 and ARR-11.

### Kept as small tickets
- **ARR-1** land the titlebar branch (process, not architecture).
- **ARR-9** triage the nine unowned red legs.
- **ARR-10** a rename in progress survives a reserved hotkey (input handling; the persistence half moved to ARC-1).

## Order, and why

1. **ARC-1** first. It stops new data damage, is about 200 lines, and everything after it commits through it. Ships alone as 0.7.22.
2. **ARC-2** second. It deletes a model rather than adding one, so it removes code; and ARC-4's invariants need a complete scene to check.
3. **ARC-3** third; small, visual, depends on nothing but is easier once the builders are already down to the install/switch pair.
4. **ARC-4** fourth; the only change with real design risk (jelly semantics), so it lands on a scene that is already whole and owned.
5. **ARC-5** grows alongside: each ARC adds its assertions to the harness as it lands, and the harness is the gate for the next.

## What we will not do
- Rewrite the canvas or the jelly engine. The invariants in hazard 9 are right; the writers and builders around them are wrong.
- Keep the flat scene "for safety". It is the second model, and a retired-but-reachable model is worse than none.
- Pin every zone live. Tiers keep governing processes; they stop governing existence.
- Auto-repair prod files. Quarantine on load, repair on the user's click.
- Merge the stale `workspace-foreign-zone-fix` branch. Its `mountedZoneIds` boundary is superseded by "only owned zones are ever in the mounted document".
- `CONTINUUM_UPDATE_BASELINES=1`, ever.

## Dogfood
Preview app on `~/array-scratch` (never the prod root). Before each ARC ships: the harness green in a real matrix summary, then the three hand scripts in the preview with before/after screenshots on the board: rename + switch + relaunch; spawn into an off-screen zone right after launch; drag that pushes zones, then quit within a second and relaunch. Only then take the update in `/Applications/Array.app`.

---

# Reconciliation with the second opinion (GPT-6 Astra, 2026-09-28)

Astra's full report is `second-opinion/second-opinion.md`. It confirmed all five root-cause sentences (the fifth only partly: not every restore moves geometry today, because hydration suppression covers some paths) and would not implement the five ARCs as written. The orchestrator verified each new mechanism in source before accepting it. What changes:

## New mechanisms, all verified at HEAD
1. **A note-conversion writer stores zone-local frames in a WORLD file and drops every other zone's tiles.** `TileSpawner.persistCanvasForCurrentModel` (:2226-2233) takes `canvasView.tiles(inZone:)` (the layer's zone-local tiles) and assigns `state.tiles = tiles`. Refutes ARC-4's claim that frames round-trip exactly.
2. **A zone's Home is also the storage partition key for its existing tiles.** `setZoneScope` writes `layer.placement.projectId` (CanvasNSView.swift:1029) and `tilesInWorldFrames(forProjectId:)` selects tiles by `placement.projectId` (:6603), contradicting its own doc comment ("membership is layout, never filesystem identity"). Rebinding a populated zone moves its tiles into the other project's file. `Tile.storageOwner`, `Tile.membership` and `Zone.creationScope` must be three distinct facts.
3. **"Saved" can mean the write failed.** Both canvas flush paths use `try? store.saveCanvas` and clear `isCanvasDirty` regardless (ZoneRuntimeController.swift:694-699, 743-746); `flushCanvasSave` returns early when not dirty before its queue barrier, so a queued async write can outlive the lock that authorized it.
4. **The direct `saveCanvas` write surface is far wider than three paths:** inspector reveal/refresh (TileSpawner :1174, :1264), note reuse (:2231/:2233), profile deletion (ContinuumApp :14126), mount membership repair (WorkspaceRuntime :541), departing focus (:1882), boot note-id mint (:2098, ContinuumApp :16278), run artifacts and diff review. A convention cannot fix this; the low-level writer must be unreachable from feature code.
5. **A layout transaction acknowledges partial effect.** `persistLayoutTransaction` skips missing projects, canvases, zone ids and tile ids (ContinuumApp :14679, :14705-14719) and still returns true, which the canvas uses to decide not to revert.
6. **Multi-store operations have no recovery protocol.** Zone creation saves the registry before the document (WorkspaceRuntime :128-135); layout persistence writes N canvases then the document with a best-effort rollback that a crash never runs.
7. **A failed switch leaks acquisitions.** `switchWorkspace` acquires controllers in a loop (:1528) before a registry save that can throw (:1591); `acquiredProjectIds` is only assigned at :1618.
8. **A per-zone hydration plan is applied to a per-project controller** (:1788-1813); two zones of one project issue contradictory tier requests.
9. **Unzoned tiles have nowhere to live.** `setTileZone(_, nil)` on close-keep-tiles updates only the membership cache and the flat `canvasState` (CanvasNSView :317-325); the layer record is untouched.
10. **A failed read is treated as an empty canvas** (WorkspaceRuntime :507-509, TileSpawner :2424-2429), and the persistence merge deletes absent tiles in covered zones, so failure-derived emptiness can become deletion authority.
11. **Stale callbacks are not fenced by session identity.** The picker reads the current `workspaceId` at confirm time (ContinuumApp :14874-14876), not the one captured at presentation.

## Decisions taken from the review
- **ARC-0 (new, ships first):** bounded data-protection patches with directed witnesses before any model work: saver identity and supersession, remove the two mounted reloads, fix the note-conversion writer, make retired-flat writes impossible, truthful save receipts with a lifetime barrier.
- **ARC-1** keeps its direction and gains: truthful acknowledgments (submitted vs durable generations), a recoverable protocol for multi-store commits (intent record, commit point, idempotent recovery), complete-resolution accounting for layout transactions, a prepared-session lease that releases on failed switch, session-epoch fencing for delayed callbacks. Quarantine becomes a derived classification over preserved raw records, not a second durable array. The "about 200 lines" estimate is withdrawn.
- **ARC-2's invariant is restated:** complete scene *data* independent of rendering and residency, with a workspace root for unzoned tiles and explicit `unloaded / loaded(revision) / unavailable(error)` states that never certify coverage. Views and runtimes are caches. Residency is budgeted per project (reduced from zone demands) now and per tile later. Always-present descriptor layers are an interim bridge, not the invariant. Tile storage owner is a field, never inferred from the zone header.
- **ARC-3** moves earlier (bounded, independent) and its projection includes provisional, unresolved-project and unavailable-project states.
- **ARC-4** keeps materialize/spawn and final validation; replaces `.user/.system` labels with *cause plus authorized effect closure*; drops silent production grow-to-contain (it contradicts the stability requirement); a system materialization moves nothing, including its own tile; solver non-convergence refuses the whole candidate; undo restores the whole closure. Note-to-document conversion is a content mutation plus view replacement.
- **ARC-5** becomes a test program: directed schedules and fault injection (blocked I/O, failed save, lost lock, crash between two writes) first, seeded sequences second; an oracle of accepted / pending / durable revisions instead of "disk == memory after every action"; negative controls for a stale success receipt, a missing or duplicated tile, a wrong owner and a header rollback.
- **Long-term storage boundary (needs Dylan):** the workspace owns all placement, membership and layout in one durable aggregate; project `.array` stores own content and sessions; project canvas placement becomes an import/export format. Deferred until the sharing contract is decided.

## Order after reconciliation
ARC-0 → ARC-3 → ARC-4a (materialize ≠ spawn, lifecycle teardown) → ARC-2 (fencing, scene nodes, root, owners, residency) → ARC-1 (coordinator, recoverable commits) → ARC-4b (causal layout transactions, growth pushes) → delete the flat scene → decide the layout aggregate. The harness grows with every step.
