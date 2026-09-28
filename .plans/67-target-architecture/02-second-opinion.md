# Array stability architecture — independent second opinion

Reviewed against `array/integration`, HEAD `1451c030e3ca0987b31de5b524b7411e9cc61cf8`. All code citations below are repository-relative `path:line` at that HEAD. The relevant `Sources` files and `scripts/run-matrix.sh` had no working-tree differences from HEAD.

**I would not implement the five ARCs as written.** They identify several genuine defects, but the proposed architecture still lets a zone's creation default determine its existing tiles' storage owner, mistakes a complete view tree for a complete model, and lacks a truthful, recoverable commit boundary. Those omissions can reproduce the same complaints after the named bugs are fixed. Keep the single-owner direction; change the model and split the rollout.

This is a static review, not a behavioral reproduction. **Verified** means the quoted source establishes the mechanism; **inferred** means the stated outcome follows under a described sequence that we did not execute. No app, build, test, check flag, or tmux command was run. We did not inspect the protected production app or stores. The first pass's production-file audit and numerical symptom probabilities are not independently verified here. Read-only source findings are sufficient to justify witnesses, not to claim those witnesses passed.

## 1. Verdict on the diagnosis

### 1. “The workspace document has no owner … controllers … read disk back into memory.” — Confirmed in substance; the enumeration needs correction

The wrong-workspace writer is real. In `Sources/ContinuumRevived/App/WorkspaceRuntime.swift:422`, the saver is created only under `if armingSaveController == nil`; line 425 binds it to `WorkspaceStore(workspaceId: workspaceId, ...)`, and line 427 schedules the current `document`. The switch assigns `workspaceId = targetWorkspaceId` and `document = targetDocument` at `WorkspaceRuntime.swift:1616`, without replacing that saver. A saver first bound in A can consequently receive B's document and write it to A.

The stale-snapshot mechanism is also real: `Sources/ContinuumRevived/App/WorkspaceDocumentSaveController.swift:41` says `pendingDocument = document`, while ordinary immediate saves construct a fresh `WorkspaceDocumentSaveController` at `WorkspaceRuntime.swift:1439`. The latter cannot supersede the former's pending value. A clean departure can repair some same-workspace stale writes by saving live state again; this does **not** make the race harmless, because a crash or a disk-to-memory reload can preserve the stale version.

The clearest reload is `Sources/ContinuumRevived/App/ContinuumApp.swift:14677`: `var document = try store.load()`, followed by `workspaceRuntime?.replaceDocument(document, for: workspaceId)` at line 14742. Explicit creation-scope persistence repeats this at lines 14961–14966. Four other listed zone-writer disk branches are fallbacks used when the runtime is absent; calling all six ordinary mounted writers overstates their reach. Two unconditional mounted reloads are already enough.

**Agreement with ARC-1:** one authoritative mounted model and a common write coordinator are warranted by these exact failures. **Disagreement:** a single document saver is not a transaction across the registry, workspace document, project canvases, and agent records. Nor is “read the live document when the timer fires” sufficient identity protection: the timer must belong to a fixed session and store, not whatever workspace happens to be current then.

### 2. “Zone headers … stale third copy … agent tick.” — Confirmed

The runtime builder supplies only `placement` and `displayName` at `Sources/ContinuumRevived/App/WorkspaceRuntime.swift:745`; the switch builder does the same at line 1580. They omit the Home label produced by the separate AppDelegate builder at `Sources/ContinuumRevived/App/ContinuumApp.swift:17351`.

The copy-back is explicit: `ContinuumApp.swift:8319` maps `canvasView.zoneRenderModels`, changes only the rollup, then calls `updateZoneRenderModels(updatedModels)` at line 8324. That method replaces both the array and display dictionary at `Sources/ContinuumRevived/Canvas/CanvasNSView.swift:5160`: `zoneRenderModels = models` and `zoneDisplayByZoneId = Dictionary(...)`. Meanwhile scope changes update the display entry at `CanvasNSView.swift:1034` without updating the array. A stale presentation snapshot can overwrite current text.

**ARC-3 survives with little conceptual change.** Persist the user's name and scope; derive their displayed strings. A cached immutable render value is fine. An independently writable render value is not. Include explicit provisional, unresolved-project, and unavailable-project states in the projection; three happy-path inputs alone are insufficient.

### 3. “A zone can be half real: chrome without a layer.” — Confirmed defect; proposed invariant is too concrete

`Sources/ContinuumRevived/App/WorkspaceRuntime.swift:688` skips layer creation with `guard plan.tier(for: zone.zoneId) == .live else { continue }`. `Sources/ContinuumRevived/Canvas/CanvasNSView.swift:6269` builds the live zone/chrome set from `documentZones`, including zones absent from the layer list. Later hydration reconciliation acquires controllers and calls `setTier` at `WorkspaceRuntime.swift:1788`–1813; it does not construct the missing layers.

That is a complete geometric zone with an incomplete tile model, which is unsound for collision resolution and persistence. But **a zone without an NSView is not inherently a defect**. The necessary invariant is complete scene data independent of rendering and runtime residency. Requiring a view for every persisted tile forever is one implementation choice, with unmeasured cost; “six zones” says nothing about their tile count.

### 4. “There are still two tile models … flat fallback … invisible to wiring.” — Confirmed; larger than the board's spawn list

`Sources/ContinuumRevived/Canvas/CanvasNSView.swift:6806` resolves a layer or falls through to `install(tileView: tileView, for: tile)` at line 6809 and returns `.flatCanvasState` at line 6819. But `tileView(for:)` searches flat views only under `if flatCompatibilitySceneActive` at line 2224. Persisted-workspace boot retires that scene before installing workspace layers at `Sources/ContinuumRevived/App/ContinuumApp.swift:16207`. Agent wiring then silently returns at line 13453 when that lookup fails.

The persistence branch remains `try projectStore.saveCanvas(canvasView.canvasState)` at `Sources/ContinuumRevived/App/TileSpawner.swift:2421`. This is a source-verified route from a missing layer to a visible-but-undiscoverable tile and a wrong-model save. It strongly explains the blank Home/dead control symptom; it does not establish how often this caused Dylan's morning failures.

Delete the competing live scene eventually. First make its use impossible after retirement, then migrate **all** readers and writers. The board understates how many remain (§2).

### 5. “‘Install’ always means ‘spawn’ … snapshots/restores move tiles … no invariants.” — Partly confirmed; “always” and the frame-space assurance are wrong

The common install tail unconditionally invokes `growZoneOnSpawn(...)` and `arrangeAutoLayoutAfterSpawn(...)` at `Sources/ContinuumRevived/Canvas/CanvasNSView.swift:6848`. The latter expands and settles at lines 839–841, then commits at lines 843–844. Nine of the seventeen TileSpawner callers replace or restore an existing view. This conflation is real.

However, the arrange function returns when hydration suppression or auto-layout disablement applies (`CanvasNSView.swift:830`–831). Thus not every restore currently moves geometry. The dangerous unsuppressed paths include browser tier changes and budget enforcement; the latter runs after the Phase B suppression block at `Sources/ContinuumRevived/App/ContinuumApp.swift:16525`.

Membership repair accepts an already-owned stamp without inspecting geometry (`Sources/ContinuumRevivedCore/ZoneMembershipRepair.swift:67`–69), and otherwise uses `let destination = containing?.zoneId ?? home` at line 90. There is no final whole-scene containment/non-overlap barrier on this path.

**The claim elsewhere in ARC-4 that frame round trips hold is refuted by the note-conversion writer in §2.1.** The main conversion functions can be correct while another writer bypasses them.

Complaint 1 remains a separate delivery issue. HEAD constructs a titled window with `styleMask: [.titled, .closable, .miniaturizable, .resizable]` at `Sources/ContinuumRevived/App/ContinuumApp.swift:4800`, plus a separate 38-point content bar at line 10104. Read-only `git merge-base --is-ancestor 61416361 HEAD` returned 1. The titlebar commit is not an ancestor; this review did not verify its current mergeability or manual UI quality.

## 2. What the first pass missed

The following mechanisms are absent from the board's actionable diagnosis. Some related risks appeared in scout prose but were lost in consolidation; that distinction matters more than claiming discovery credit.

### 2.1 A note-conversion branch writes LOCAL frames to a WORLD file and erases other zones

**Verified chain:** converting a note to an already-open file removes the note and calls `persistCanvasForCurrentModel` at `Sources/ContinuumRevived/App/TileSpawner.swift:2142`–2145. That helper contains:

```swift
// TileSpawner.swift:2226,2230-2231
if let zoneId, let tiles = canvasView.tiles(inZone: zoneId) {
    // ...
    state.tiles = tiles
    try projectStore.saveCanvas(state)
}
```

`Sources/ContinuumRevived/Canvas/CanvasNSView.swift:6472` returns the layer's `tiles` directly. Those frames were converted to zone-local at `Sources/ContinuumRevived/App/WorkspaceRuntime.swift:1571`: `adopted.frame = CanvasEngine.worldToZoneLocal(...)`.

**Inferred reproducible result:** in a zone at nonzero origin, reuse an existing file while converting a note. The saved survivors have local coordinates where WORLD is required, and tiles in the project's other zones disappear from that file. A later broad save might mask the damage; crash/remount before it does not. Serialization alone would faithfully serialize the wrong snapshot.

**Required fix/witness:** use the canonical project projection and preserve unaffected records. Seed two zones in one project, both at nonzero origins; exercise the reuse-existing conversion route, remount without a corrective departure flush, and assert every surviving tile's identity, owner and world frame. This deserves an early bounded fix, not burial in flat-scene deletion.

### 2.2 Zone Home is a creation default and a storage partition key at the same time

The contradiction is in the source contract itself:

> `Sources/ContinuumRevived/Canvas/CanvasNSView.swift:1014`: “Atomically updates the zone's creation default. Existing member tiles are intentionally untouched: membership is layout, never filesystem identity.”

Yet the implementation changes `layer.placement.projectId = projectId` at line 1029. Persistence then selects **all** layer tiles by `.filter { $0.placement.projectId == projectId }` at line 6603. It does not select each tile by a stable storage owner. The existing metadata explicitly says visual membership never rewrites filesystem identity (`Sources/ContinuumRevivedCore/CanvasState.swift:289`–293).

The picker permits a project in the same workspace, calls `setZoneScope`, and tells the user “Future filesystem tiles will start in …” (`Sources/ContinuumRevived/App/ContinuumApp.swift:14931`–14937).

**Inferred result from verified selectors:** rebind a populated A zone to B, then save B. B's projection contains the old A tiles. A's persistence coverage no longer includes that layer, so the merge can retain A's original copies (`Sources/ContinuumRevivedCore/CanvasPersistenceMerge.swift:52`–55). On remount, membership is loaded by the zone's current project (`Sources/ContinuumRevived/App/WorkspaceRuntime.swift:507`–523), which can duplicate, hide or relocate those records. The exact visible result depends on which stores are subsequently saved.

**Architectural consequence:** `Zone.creationScope`, `Tile.membership`, `Tile.storageOwner`, and filesystem Home must be distinct concepts. Neither ARC-1 nor “whole layers” fixes this. Inferring storage ownership from a mutable zone header must stop. Existing `filesystemProjectId` is useful evidence but is optional and not a universal owner for every tile kind; migration needs a complete owner field, normally inferred from the source store, with conflicts preserved for review.

### 2.3 “Saved” can mean “the write failed”; quit may not drain queued work

`Sources/ContinuumRevived/App/ZoneRuntimeController.swift:694`–699 captures a snapshot, clears dirty state, then queues:

```swift
isCanvasDirty = false
Self.canvasSaveQueue.async { [weak self] in
    try? store.saveCanvas(snapshot)
    Task { @MainActor [weak self] in self?.onCanvasStatePersisted?() }
}
```

Synchronous flush also uses `try? projectStore.saveCanvas(snapshot)`, clears dirty state and invokes the persisted callback (`ZoneRuntimeController.swift:743`–746). These are **verified false-success paths**. The higher-level throwing close flush calls nonthrowing `flushAll()` and then emits `.closeFlushCompleted` (`Sources/ContinuumRevived/App/WorkspaceRuntime.swift:805`–808).

Additionally, `flushCanvasSave` returns at `ZoneRuntimeController.swift:738` when not dirty, before its queue barrier. Once the async path clears dirty, departure is not guaranteed to wait for that pending write. `close()` ultimately releases the project lock at line 206. **Inferred schedule:** a queued store write can outlive the controller/lock that authorized it; process exit can also interrupt unacknowledged work. Merely sending every caller to the queue does not repair dirty/queued/acknowledged accounting.

**Needed:** submitted and durable generations, retained error/pending state, a barrier through the last submitted generation even when nothing is dirty, and no lock release until that barrier resolves. Failure must reach switch/quit. A fake failing store must never trigger a success acknowledgment.

### 2.4 Direct project writers extend beyond the board's three paths

Additional production `saveCanvas` sites include:

| Writer | HEAD location | Problem to carry into the migration |
|---|---|---|
| Browser inspector reveal/refresh | `Sources/ContinuumRevived/App/TileSpawner.swift:1174`, `:1264` | `saveCanvas(canvasView.canvasState)` can use the retired flat state. |
| Note reuse/conversion | `Sources/ContinuumRevived/App/TileSpawner.swift:2231`, `:2233` | One-zone replacement/local frames, or flat save. |
| Browser-profile deletion | `Sources/ContinuumRevived/App/ContinuumApp.swift:14126` | Saves an edited flat snapshot through the current project store. |
| Mount membership repair | `Sources/ContinuumRevived/App/WorkspaceRuntime.swift:541` | Direct write during scene preparation; errors suppressed. |
| Departing focus | `Sources/ContinuumRevived/App/WorkspaceRuntime.swift:1882` | Read/modify/write outside the controller queue. |
| Legacy boot and note-ID mint | `Sources/ContinuumRevived/App/ContinuumApp.swift:16278`; `Sources/ContinuumRevived/App/TileSpawner.swift:2098` | Import side effects need an explicit boundary. |
| Run artifacts and diff review | `Sources/ContinuumRevived/App/TileSpawner.swift:2477`; `Sources/ContinuumRevived/App/ContinuumApp.swift:16643` | Already identified as stale spawns; they are also direct writers. |

Together with controller async/sync writes, spawn projection, layout writes and rollback, this is the production canvas write surface identified by the source search. Check fixtures and corpus seeders also write files but are not mounted production writers. The sub-A report inventories workspace writers/controller construction and mounted read paths separately.

For example, the inspector code literally calls `try? projectStore.saveCanvas(canvasView.canvasState)` (`TileSpawner.swift:1174`). Correcting only `.flatCanvasState` in `persistProjectCanvas` leaves this bypass intact. Make the low-level writer inaccessible to mounted feature code; a convention asking new callers to remember a queue is too weak.

### 2.5 A layout “transaction” can acknowledge only part of its requested effects

`Sources/ContinuumRevived/App/ContinuumApp.swift:14705`–14707 says:

```swift
guard let entry = registry.projects.first(where: { $0.id == projectId }) else { continue }
// ...
guard let original = try projectStore.tryLoadCanvas() else { continue }
```

Missing zone IDs are ignored at line 14679; missing tile IDs are skipped at line 14719. After these skips, the function returns `true` at line 14746. The UI uses that boolean to decide whether to revert the installed geometry (`Sources/ContinuumRevived/Canvas/CanvasNSView.swift:2780`–2782).

Some skipping is legitimate while searching multiple stores. The defect is **no final accounting that each requested identity resolved exactly once**. A missing project canvas can leave a moved zone durably updated while its members were not. A duplicate tile ID in two files can match twice. One queue, correct coordinates, and a provenance label cannot establish completeness.

**Needed:** resolve every affected record and owner before writing; verify expected revisions; reject missing/ambiguous identities. Test an unavailable member store and a duplicated tile ID. Failure must leave the committed scene unchanged or enter an explicit recoverable pending state.

### 2.6 Atomic file replacement is not an atomic user action

Creating a zone saves registry ownership before saving the zone document (`Sources/ContinuumRevived/App/WorkspaceRuntime.swift:128`–135: `assignProject`, `registryStore.save`, append, `persistWorkspaceDocument`). The picker repeats that order (`Sources/ContinuumRevived/App/ContinuumApp.swift:14905`–14924). A later failure can leave ownership assigned with no durable zone.

Layout persistence writes each project canvas and then the workspace document (`ContinuumApp.swift:14728`–14734). Its rollback explicitly admits failure: `catch { fputs("persistLayoutTransaction rollback failed: ...", stderr) }` at line 14738. A crash between writes never runs that catch at all. Each store's AtomicWriter protects an individual file, not this aggregate operation.

Even a single-file mutation has ambiguous failure semantics: `document.zones[index] = placement` precedes a throwing save (`WorkspaceRuntime.swift:112`–113). If the caller reports failure, later unrelated flushes can still persist the changed memory. Choose one contract: rollback the candidate, or keep it visibly unsaved/retryable. Do not call both “commit.”

**Needed:** an explicit recoverable protocol for multi-store operations and honest durable receipts. This is a boundary ARC-1 must name; its “about 200 lines” estimate is not credible for its full proposed scope.

### 2.7 Failed workspace preparation can leak controllers and project locks

`Sources/ContinuumRevived/App/WorkspaceRuntime.swift:1528` calls `try registry.acquire(projectId:)` in a loop. A later acquisition or the registry save at line 1591 can throw. The method has no cleanup for earlier successful acquisitions; `acquiredProjectIds = newlyAcquired` happens only at line 1618.

`Sources/ContinuumRevived/App/ZoneRuntimeRegistry.swift:37` increments an existing reference count and line 42 records a new controller at reference count 1. Normal teardown releases only IDs tracked by the runtime (`WorkspaceRuntime.swift:819`–820).

**Inferred failure case:** acquisition 1 succeeds, acquisition 2 throws; the old scene remains, but the new controller is retained outside the runtime's tracked set. Retrying can increment that reference again. The first pass's s11 discussed a rollback guard in the old branch, but the consolidated ARCs lost that independent issue when declining to merge it.

**Needed:** a prepared-session resource lease that releases all acquired resources on every unsuccessful preparation. Witness failure at each acquisition index and at the last registry write; resource ownership and old scene must exactly match the starting state.

### 2.8 A per-zone plan writes a per-project runtime tier

`Sources/ContinuumRevived/App/WorkspaceRuntime.swift:1788` iterates zones, looks up `registry.controller(for: projectId)` and calls `controller.setTier(plannedTier)` at line 1813. The controller holds one `hydrationTier`; its setter assigns it at `Sources/ContinuumRevived/App/ZoneRuntimeController.swift:567`. Hydration then selects all browser tiles for that project (`ZoneRuntimeController.swift:597`–605).

Multiple zones for one project are explicitly supported (`Sources/ContinuumRevived/Canvas/CanvasNSView.swift:6580`). **Inferred result:** two such zones with different planned tiers issue contradictory requests to one controller; outcomes depend on iteration order and hydration guards rather than a coherent residency policy. All-zone layer creation can magnify this by making more browser tiles eligible.

**Needed:** model project storage/locking separately from tile runtime residency. In an interim project-wide policy, reduce the zone demands once per project—e.g. strongest required residency—then apply a separate actual-runtime budget. Longer term, budget runtime instances per tile. Do not promise “four live zones means four zones' worth of processes” before defining this relationship.

### 2.9 Unzoned tiles need somewhere to exist

`Sources/ContinuumRevivedCore/WorkspaceDocument.swift:23` explicitly permits “formerly-zoned ambient tiles with `zoneId == nil`.” Yet `makeAmbientZoneLayer` selects only `document.tiles(forZone: zone.zoneId)` (`Sources/ContinuumRevived/App/WorkspaceRuntime.swift:941`); mount builds these layers by walking zones.

The keep-tiles close path calls `setTileZone(id, zoneId: nil)` (`Sources/ContinuumRevived/Canvas/CanvasNSView.swift:2107`). That supposed membership sink only updates the cache and `canvasState.tiles` (`CanvasNSView.swift:317`–325); it does not change the layer's tile record or reparent it. Close then removes live chrome while a nonempty layer can remain (`CanvasNSView.swift:2109`–2116).

**Verified missing representation; inferred close/remount loss:** “every zone has a layer” still has nowhere to mount a bare ambient tile, and a kept project tile can retain a stale layer stamp. A scene graph needs a workspace root for unzoned tiles, with world-frame-preserving reparenting. Membership cannot be represented simultaneously by the layer array, a cache, and an unrelated flat record.

### 2.10 Failed reads must not be interpreted as authoritative emptiness

Membership load currently uses `((try? controller.projectStore.tryLoadCanvas()) ?? nil) ?? CanvasState(... tiles: [] ...)` (`Sources/ContinuumRevived/App/WorkspaceRuntime.swift:507`–509). Spawn persistence similarly defaults a failed read to an empty canvas (`Sources/ContinuumRevived/App/TileSpawner.swift:2424`–2429).

The proposal's “one layer for every zone” would increase the consequences of treating a failed load as a successfully loaded empty layer. The merge deletes absent tiles in covered zones at `Sources/ContinuumRevivedCore/CanvasPersistenceMerge.swift:52`–53. **Inferred hazard:** failure-derived emptiness can become deletion authority on a subsequent save. The existing merge was designed around coverage, so coverage must certify a complete successful load, not merely the existence of a layer/view.

Use explicit `unloaded / loaded(revision) / unavailable(error) / conflicting` data states. An unavailable zone can have chrome and a clear error without having authority to erase, restamp, or push unknown members. Its geometry-changing operations must wait or fail explicitly.

### 2.11 Session identity must fence delayed actions, not just files

Picker confirmation captures a placement but reads the **current** `workspaceRuntime?.workspaceId` when confirmed (`Sources/ContinuumRevived/App/ContinuumApp.swift:14874`–14876); later it commits the captured `placement.zoneId` at line 14925 or 14932 and persists recent scope at line 14939.

**Unverified interaction schedule:** if a picker survives a workspace switch, confirmation can assign ownership in the new workspace before discovering the old zone is absent. This is not established as an actual AppKit reproduction. It is a concrete missing guard: capture `(workspaceId, mountEpoch)` at presentation and reject stale completion before any registry write. Use the same rule for async runtime callbacks and persistence acknowledgments. A UUID inside JSON cannot fence an old in-memory callback.

## 3. Target architecture

**A transactional workspace scene, with separate content ownership and runtime residency.** This is a coherent destination without rewriting AppKit or replacing the jelly solver wholesale.

### Owners and boundaries

| Owner | Sole authority | Explicitly outside its authority |
|---|---|---|
| `WorkspaceSession` on the main actor | Workspace identity, mount epoch, committed scene revision; executes scoped commands; prepares/commits switching | Views cannot directly mutate its persisted facts. |
| `WorkspaceScene` value/model | All zone nodes, all tile placements, root/unzoned membership, stacking, creation defaults | Hydration does not add/remove logical records. |
| Project content repository | A project's tile backing data, notes, documents and session references; storage identity/lock | A zone Home change does not transfer existing content. |
| Commit coordinator | Ordered generation-stamped snapshots, durable receipts, multi-file recovery, dirty/error state | Neither a rendered view nor a timer decides which store owns a tile. |
| View renderer | Derives chrome/tile views from scene plus status; transient gesture previews | It has no `ProjectStore.saveCanvas` access. |
| Runtime supervisor | Runtime identity/generation, attachment lifecycle and actual resource budget | Rehydration/materialization cannot mutate scene geometry. |
| Registry | Project identity/root resolution and one canonical workspace ownership relation | Reverse indexes and presentation labels are derived. |

These can begin as smaller types inside the current runtime. “One owner” does not require one enormous new class. The key is enforceable APIs and dependencies: feature code submits a command with stable IDs, not a partly edited document or a save callback.

### What a zone and a tile are

A **zone** is a workspace-owned named spatial group: stable ID, one canonical world rect, z-order, layout policy, and an optional creation scope. Its header project/Home means where future filesystem-backed tiles start. It is not the storage owner of its members and is not a process container.

A **tile** is a durable record with stable identity, explicit content/storage owner, kind, backing reference, one world frame, stacking and optional zone membership. An agent binding has an explicit `bound / unbound / unavailable` state; a missing channel-specific agent record is not permission to silently mint a replacement. The view and provider process are replaceable resources attached to that record. Unzoned tiles belong to the scene root, whether their backing content is project-owned or workspace-owned.

For duplicate imported IDs, either establish global uniqueness through a verified migration or use a qualified content key internally. Do not silently choose the first dictionary/layer occurrence. Preserve ambiguous legacy records for recovery.

### Frame spaces

Use **WORLD as canonical scene and durable placement space**, matching today's file convention. Use explicit `WorldRect`, `ZoneLocalRect(zoneId)` and view/screen transform boundaries. Zone-local coordinates should be a derived rendering adapter, not another independently editable tile record. AppKit coordinates and camera zoom never enter persistence.

A zone translation computes the affected members' world translations once. Origin changes caused by growth preserve unaffected world frames. Undo records the exact accepted geometry, not an unvetted request. Keep the existing exact-rebase safeguards during migration; do not remove them merely because the new ownership diagram is simpler. `CanvasNSView.swift:2770` documents why installed versus requested geometry already mattered to undo.

### Persistence and commit semantics

**Near term:** retain existing JSON formats, embed workspace identity, and centralize all writes. Each session/store has submitted and durable revisions; flush waits through the requested revision, succeeds only after persistence, and never releases a project lease early. A queued immutable snapshot is safe when identity/revision ordering is enforced and newer commits supersede older work. Snapshots themselves are not the defect.

For a command, resolve identities and revisions; build a candidate scene; solve and validate its entire affected closure; persist through the coordinator; then publish the committed revision/receipt. Interactive previews can precede durability but must remain explicitly provisional. User intent and dirty state survive a failed save; choose rollback or visible retry semantics per command and test them.

While geometry spans several files, use a small durable intent record containing the transaction ID, identities, expected revisions and candidate payloads. Define a commit point and idempotent recovery before mounting. Prevent independent writers from modifying participants during completion/recovery. A serial queue plus best-effort rollback is insufficient for crash consistency. This needs its own design review and fault witnesses; it is not a trivial wrapper.

**Long-term preferred storage boundary:** the workspace owns **all placement/membership/layout data** in one durable aggregate; project `.array` stores own backing project content and sessions. Project canvas placement becomes a versioned import/export compatibility format rather than a second live layout authority. One zone push then updates one layout aggregate, regardless of its members' projects. This also makes channel-specific workspace layouts explicit rather than partially shared through `.array`.

That long-term migration changes portability and old-version interoperability, so do it only after Dylan decides the sharing contract (§6). Until then the multi-file recovery protocol remains necessary. No new database or event-sourced system is required for the initial fixes.

### Geometry and presentation contracts

`createTile` creates a record and resolves one explicit target, scope and owner; `replaceTileView` only materializes an existing record. Note-to-document conversion is a **content mutation plus view replacement**, not merely a materialization: its kind/metadata changes still need a durable command even though geometry does not.

A layout command carries `cause`, workspace epoch, baseline revision, affected IDs and accepted before/after geometry. Effects include the full deterministic growth/push closure. **Dylan's decided policy stands: growth pushes neighboring zones like a drag and never overlaps them.** A user spawn or resize authorizes its resulting push chain. Agent-authorized creation needs a specified grant scope for that same effect; lifecycle restoration authorizes no geometry change.

Containment is a membership constraint, not identity: a geometrically overlapping bare tile need not automatically become a member. Define containment against the zone's content bounds and commit-time membership rules, not the inconsistent combination “full rect contained” and “centre exited.” The existing solver has a bounded loop (`Sources/ContinuumRevivedCore/CanvasAutoLayoutEngine.swift:922`); validate its result and reject/restore on nonconvergence. An attempt to push is not proof that no overlaps remain.

Derive presentation from canonical scene data, registry resolution, provisional/unavailable state and rollups. A status tick can change status-dependent display only. Materialization, mounting a valid scene, panning, browser eviction and process restart must leave canonical geometry unchanged.

### Which ARCs survive?

| ARC | Decision |
|---|---|
| ARC-1 | **Keep, split and strengthen.** Single model/writer, identity checks and ownership normalization are right. Add truthful acknowledgments, lifecycle barriers, complete write coverage and recoverable multi-store actions. Prefer a derived quarantine classification over a second independently durable zone array. |
| ARC-2 | **Change the invariant.** Complete scene nodes, including a root for bare tiles; views/runtimes are caches. Cheap always-present layers may be an interim bridge, but cold data loading and explicit failure/coverage states come first. Remove the flat live model incrementally. |
| ARC-3 | **Keep and move earlier.** Pure presentation plus rollup-only updates is a bounded independent win. No need to wait for full ARC-2. |
| ARC-4 | **Keep materialize/spawn separation and final validation; replace provenance/refusal and automatic repair rules.** Cause plus authorized effect closure is stronger than `.user` labels. A system materialization moves nothing, including its own tile. Do not silently grow/push damaged layouts during mount. |
| ARC-5 | **Keep as a test program, not one magical random check.** Directed schedules, failure injection, migration/recovery and real-entry-point checks are foundational; random action sequences extend them. Wholeness concerns model records, not permanent NSViews. |

The consolidated prose recommends growth clipping; the later board and Dylan's prompt explicitly decide growth pushes. I use the latter throughout. ARC-4's proposed silent production grow-to-contain also contradicts its ban on system zone moves and the owner's stability requirement. That part is wrong as written.

## 4. Better ideas

| Alternative | Cost and blast radius | Judgment |
|---|---|---|
| Patch saver identity/supersession; reject retired-flat writes; correct note writer | Small-to-medium, known entry points | Ship these protections first with directed witnesses. They reduce damage while the model boundary changes. |
| Main-actor command model plus serial persistence worker | Medium; replaces scattered mutation/save access | Best default. AppKit already needs main-actor access. Immutable identity-stamped candidates cross to storage; acknowledgments return with epoch/revision. |
| A Swift actor for everything | Medium-to-high; introduces suspension/reentrancy at UI, switch and quit seams | Useful for the storage service, not a substitute for transaction design. An actor can serialize two logically stale writes perfectly. |
| Full append-only event log and replay | High; event versioning, snapshots, compaction, migration and external side-effect replay | Not justified for the first stability work. A limited multi-file recovery journal is substantially narrower and addresses a proven failure boundary. |
| Expand existing LWW/CRDT registers | High; must define atomic group geometry, ownership and deletion conflict semantics | Wrong immediate tool. Existing field-scoped membership writes protect sibling fields (`WorkspaceDocument.swift:140`–178); they do not make multi-record pushes or file writes atomic. Concurrent last-writer-wins rects can still violate containment. Keep future sync behind the same validated command boundary. |
| Always instantiate every descriptor view | Medium, with unmeasured AppKit/view-tree cost | Plausible temporary bridge for small scenes. Not the architecture invariant. Scene completeness should not depend on an unbounded number of views or live project controllers. |
| Keep independent stores plus a recovery journal | Medium-to-high, but preserves current formats | Practical interim if cross-file layout durability is required. Must include lock/revision checks and recovery at every crash prefix. |
| Move layout into one workspace aggregate | High migration cost; lower ongoing consistency complexity | Preferred destination if project portability/channel policy allows it. Can retain JSON initially; SQLite is an optional implementation choice, not the architectural answer. |
| One persistent `quarantinedZones` bag | Medium migration/UI cost; adds another location for the same identity | Prefer one preserved raw record set plus derived classifications: valid, foreign-owned, unresolved, conflicting. A registry error is not proof of the correct repair destination. |

Do not silently “fix” legacy corrupted geometry in production while merely rejecting it in QA. That tests different behavior from what ships. Preserve originals and produce a deterministic repair proposal. Run the same repair policy in tests and production once explicitly chosen.

## 5. Sequencing and risk

No fixes were made here. The following are shippable slices, not a commitment to a line count or a release number. Each behavioral change carries a directed outcome witness in the actual matrix summary; no source-string assertions count.

| Order | Shippable change | Witness that guards it |
|---|---|---|
| 1 | Add directed fixtures and fix workspace saver identity/supersession; remove the two mounted document reloads | Mount A, arm A, switch B, arm B, drain; A bytes unchanged. Arm then rename/create before debounce; durable latest revision survives an abrupt remount. Fail save and assert truthful pending/error state. |
| 2 | Correct note reuse and ancillary flat writers; route every project save through one coordinator with real acknowledgment and a lifetime barrier | Two zones/nonzero origins; note reuse preserves sibling IDs/WORLD frames. Inspector/profile actions cannot import another project's tiles. Hold writer, enqueue old/new saves, flush/close: newest durable generation wins; injected failure never reports saved; lock outlives pending write. |
| 3 | Separate view replacement from creation; centralize lifecycle teardown | Hand-spaced scene survives browser snapshot/restart, budget eviction, terminal restart and file-tree view swaps with identical frames/membership/z-order. Old view subscriptions/focus registrations retire once; content conversion still persists kind/metadata. |
| 4 | Derive headers and make binding failures explicit | Mount, create, rename, change Home, rollup tick, switch/remount: real chrome text matches canonical inputs. A missing agent record renders actionable unbound state and creates no duplicate agent. |
| 5 | Fence unavailable/layerless creation and failed switch preparation; use one mounted eligibility boundary everywhere | Real palette spawn into far/budget-excluded zone either completes correctly or gives a typed visible failure with no partial tile/record write. Fail each target acquisition and final registry save; old scene, refcounts and locks remain unchanged. Foreign preserved zones never acquire on camera reconcile. |
| 6 | Introduce scene nodes, root tiles and stable tile owners behind adapters; decouple project data access from runtime acquisition | Populated zone Home A→B leaves old members in A's store and existing Homes unchanged; future tile belongs to B. Close/keep reparents to root without moving, remount preserves it. Missing store is unavailable, never empty/deletion authority. Two zones of one project have deterministic residency. |
| 7 | Establish complete recoverable commits and candidate validation | Every requested identity resolves once. Fail/interrupt after each participating write; remount recovers wholly before or wholly after, never mixed. Include rollback failure, duplicate IDs, missing canvas and registry/document ownership interruption. |
| 8 | Route every growth, resize, spawn, tidy, drag and undo through one causal layout transaction; enforce growth-push policy | Long push chain including far zones carries all members by exact deltas; final containment and zone non-overlap hold. Bounded solver failure refuses the whole candidate. Undo/redo restores the entire push closure. Lifecycle materialization changes zero geometry. |
| 9 | Remove the flat live scene and legacy write paths once adapter coverage is complete; then migrate durable layout boundary if approved | Fresh empty boot, legacy import, all tile kinds, populated/bare/group zones and abrupt remount use the same scene path. Migration is lossless/idempotent, preserves originals, rejects wrong identity/future unsupported data, and has explicit old-version compatibility behavior. |

Titlebar delivery and interrupted rename handling can ship independently with their own real UI outcome checks. They should not block data-protection patches or be treated as proof of architectural stability. Reusing the old titlebar branch still requires actual fullscreen/window-drag validation; I did not perform it.

### The gate needs a model of durability, not just random actions

The suggested harness asserts disk == memory == chrome after every action while also intentionally debouncing some writes. Those requirements conflict. Maintain an independent oracle for **accepted scene revision**, **pending intent**, and **durable revision**. Before a flush, disk must equal the last acknowledged durable state; after a successful barrier it must equal the requested revision. A crash may lose explicitly unacknowledged work, but never a reported durable transaction or half a reported aggregate operation.

Use directed scenarios first, then seeded state-machine sequences. Random action order does not generate a blocked I/O queue, a save failure, a lost project lock, or the exact crash point between two renames. Inject a deterministic scheduler, storage faults and acquisition failures. Record action seed **and** fault index, initial fixture hash, actual action trace, session epochs and durable receipts. Shrink failures to a short replayable trace.

Required outcome invariants:

1. Identity/isolation: correct workspace/store/epoch; no mutation in another workspace or project; no stale callback after switch.
2. Conservation: every durable tile survives exactly once unless an acknowledged delete/transfer removes it; content owner, backing reference and agent binding stay attached to the same identity.
3. Completeness: loaded model contains all known records at every tier, including root tiles; failed loads cannot certify coverage; every transaction target resolves exactly once.
4. Durability: acknowledgments describe successful durable generations; flush drains submitted work; failure/recovery produces one coherent revision across participants.
5. Geometry: canonical WORLD frames are stable under lifecycle operations; only the authorized effect closure moves; membership implies containment at committed rest; zones never overlap after accepted growth/drag.
6. Projection: actual chrome and accessible Home actions reflect canonical fields and availability; status updates cannot alter identity or geometry.
7. Lifecycle: one owned runtime/binding per tile where appropriate, correct lease/refcounts, no observer leftovers, and residency independent of model existence.
8. Repair/migration: originals preserved, classifications deterministic, second mount/import idempotent, explicit repair survives remount without inventing ownership.

Read actual rendered/world bounds as well as model snapshots so a model-only oracle cannot approve a misplaced view. Add negative controls for a stale success receipt, missing/duplicated tile, wrong owner, header rollback and 1-point frame change—not just the proposed ghost/foreign-zone mutations. Include nonzero and fractional origins, multiple zones per project, empty workspaces, group/bare tiles, unavailable stores, >4 zones, cold/armed zones, and pending editors.

Register and report every required scenario; do not call a harness green because future failing cases are silently disabled. The current `--workspace-switch-polish-check` dispatch exists at `Sources/ContinuumRevived/App/ContinuumApp.swift:2224`, but a read-only search found no registration in `scripts/run-matrix.sh`; neither contains the titlebar witness on HEAD. Old reported green binaries and unowned reds are not current validation. We ran none of them.

## 6. Questions for the owner

These are product/storage decisions, not requests to repeat implementation permission. The decided growth-push policy is not being reopened.

1. **Should workspace layout travel with a project's `.array`, or belong to the workspace/channel?** I recommend workspace-owned layout with explicit project import/export. This determines whether the strongest simplification—one durable layout aggregate—is acceptable and what old app versions may share.
2. **Should a zone remain a visual group whose Home affects future tiles only?** The current code/UI promise that behavior. I recommend honoring it, including existing tiles with other project owners. If you instead want project-pure zones, changing a populated zone's project must become an explicit transfer or refusal, never the present silent reinterpretation.
3. **What should happen to already-damaged layouts?** I recommend preserve and show a repair preview, with explicit acceptance of any growth/push/reparent. A global “automatically repair on open” policy would permit movement without a new gesture and needs your deliberate choice.
4. **May an agent with permission to create a tile trigger the normal growth/push chain?** I recommend that grant explicitly include the deterministic resulting push, with undo and visible cause. Otherwise the operation should return a spatial-capacity refusal, not label the movement `.user`.

The initial saver, wrong-writer, materialization, presentation and failure-reporting fixes do not need to wait for these decisions.

## 7. What the children ran

Exactly three subagents were started and worked concurrently. No child delegated further.

| Child | Configuration actually established | Coverage / artifact |
|---|---|---|
| Sub-A `write_path` | **Delegation error:** I passed `model=gpt-6-sol`, `reasoning_effort=medium` with `fork_turns=all`. The documented tool contract says full-history forks inherit the parent model/effort. The tool accepted the call but exposes no actual runtime metadata. Thus this child ran an inherited configuration; I cannot honestly certify Sol/medium or name its precise inherited effort. | Workspace/canvas writer inventory, save/read paths, ownership, durability, alternatives. [sub-a-write-path.md](sub-a-write-path.md) |
| Sub-B `scene` | `model=gpt-6-sol`, `reasoning_effort=medium`, `fork_turns=none`; accepted by the tool with no reported override. No independent model-introspection API is exposed. | Layers/chrome, all 17 installers, flat reach, hydration, membership, scene graph. [sub-b-scene.md](sub-b-scene.md) |
| Sub-C `boundaries` | `model=gpt-6-sol`, `reasoning_effort=medium`, `fork_turns=none`; accepted by the tool with no reported override. No independent model-introspection API is exposed. | Boot/switch/quit, stores/channels, presentation, gate and failure boundaries. [sub-c-boundaries.md](sub-c-boundaries.md) |

I did **not** meet the requested model/effort configuration for all three with certainty; the Sub-A spawn was my mistake. I did not create a fourth/replacement child, which would have broken the exact-three constraint. The finding synthesis above rests on quoted source, including my independent verification of the central additional mechanisms.

We read the required orientation, consolidated proposal, board and reports before source review. Large aggregate report reads produced truncation; the parent re-read the omitted report portions in smaller slices. Children also re-read relevant report/code ranges; their audit notes describe those limits.

Commands were read-only file inventory/search/read tools (`cat`, `rg`, `wc`, `sed`, `nl`, plus child inventory `pwd`/`ls`/`find`) and read-only Git inspection (`rev-parse`, branch inspection, `diff`, and the titlebar `merge-base --is-ancestor`). The parent verified full HEAD and no tracked source/matrix differences. The non-ancestor query returned 1 as expected. A parent read attempted nonexistent `Sources/ContinuumRevived/Canvas/CanvasLayoutTransaction.swift`; child audits note two analogous path misses. Source discovery corrected those paths. In particular, the actual solver is `Sources/ContinuumRevivedCore/CanvasAutoLayoutEngine.swift`, not the Canvas-target path used in the brief/board.

Only these Markdown reports were written, in the authorized current directory. **No repo/worktree edits, Git mutations, builds, checks, tests, app launches, production-store inspection or tmux access occurred.** Behavioral outcomes, performance of all-view materialization, UI fullscreen/drag behavior, exact wake causality, prod corruption provenance, and the proposed recovery protocol remain unexecuted/unverified.
