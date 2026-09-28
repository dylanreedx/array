# Record vs. Tile investigation (hazard 9/10 context)

## 1. Record model + store

- `AgentRecord` (`Sources/ContinuumRevivedCore/Agents/AgentRecord.swift:246`): schemaVersion,
  id, displayName, role, `harness: AgentHarness?`, `model`, `thinking`, legacy `cwd`,
  `projectRoot: String?`, `checkoutRoot`, `homeRelativePath: String?`,
  `lastObservedWhere`, `worktreeId`/`worktreeBranch`, `projectId: UUID?`,
  `parentAgentID`, `tileId: UUID?` (AgentRecord.swift:356 — the ONLY tile
  linkage, held on the record, not the tile), `capabilities`, ordinals,
  `workspaceToolsEnabled`, timestamps.
- Store: `AgentStore` (`Sources/ContinuumRevivedCore/Agents/AgentStore.swift`), one
  JSON file per record under `~/Library/Application Support/Array/agents/<agentId>.json`
  (`AgentStoreLayout`, :27-58) — i.e. **channel-split app-support**, exactly as CLAUDE.md
  hazard 10 says. `loadAll()` (:180) enumerates the dir, skips unreadable files
  (warns on stderr), sorted by createdAt then id.
- Boot load: `AgentSupervisor.restore()` (`Sources/ContinuumRevived/App/AgentSupervisor.swift:1869`)
  calls `store.loadAll()` synchronously and adopts every stored record into the
  in-memory `records` dict, **starting no provider process** ("NO PROVIDER PROCESS
  IS STARTED... idle until user sends a prompt" — restore() doc comment, :1863).
  A record whose `cwd` no longer exists is marked stale but kept (not deleted).
  `restore()` is called from many places (`AgentSupervisor.swift:8520`, `:9594`,
  etc.) — did not find a single canonical "AppDelegate boot" call site in this
  pass, but every one of them runs synchronously before use. There is no
  evidence it is gated on canvas/zone mount completing — it's a supervisor-level
  call independent of `WorkspaceRuntime.setZones`/canvas mount timing.

## 2. Tile↔record linkage and missing-record behaviour

- **No linkage lives on the tile.** `TileMetadata` (`Sources/ContinuumRevivedCore/CanvasState.swift:274`)
  has no `agentId`/`agentID` field at all — confirmed by listing every field.
  The link is entirely the record's `tileId` (AgentRecord.swift:356), looked up
  reverse-index style: `AgentSupervisor.agent(forTile:)` (`AgentSupervisor.swift:5047`)
  does `records.values.first(where: { $0.tileId == tileId })?.id` — an O(n) scan
  of in-memory records, not a stored map.
- **Missing-record path.** In `makeHydratedTileView`'s `.managedAgent` case
  (`Sources/ContinuumRevived/App/ContinuumApp.swift:16448-16460`) the view is built
  UNWIRED — comment: "wire ONLY an agent that already exists... Hydrating an
  unbound tile would therefore mint an agent in the wrong project on every
  switch — hazard 10's duplicate-agent minting, in-process." Then in
  `hydrateRuntimeBackedTiles` (:16473) the wiring loop explicitly SKIPS any
  `.managedAgent` tile for which `agentSupervisor.agent(forTile: tile.id) == nil`
  (:16476-16478) — it never calls `wireManagedAgentTile` for it. **This produces
  exactly Dylan's symptom: a tile that renders (blank, unwired ManagedAgentTileNSView)
  but has no compose/home/status wiring until something calls `wireManagedAgentTile`
  again** (e.g. submitting a prompt, which does spawn a fresh agent — see below).
- **The actual "mints a duplicate" path lives in `AgentStore.swift:150-158`**
  (comment on `delete`): "an `AgentRecord` is DERIVED state: a `managedAgent`
  tile is persisted in its project's canvas, and the app mints a new agent for
  any such tile it finds no record for." This is the second-install collision
  hazard 10 documents (two channel-split app-support stores, one shared
  `.array/canvas.json`) — NOT the same code path as the in-process hydration
  skip above, but the same structural cause: canvas (tile) and AgentStore
  (record) are two independently-loaded stores with no cross-check other than
  `tileId` matching at runtime.
- **`retireOrphanedRuntimes(forTile:controller:)`** (`ContinuumApp.swift:16558`)
  is unrelated to agent records — it only terminates/detaches leftover
  `GhosttyTerminalRuntime`/browser runtime objects for **terminal/browser**
  tiles before Phase B restarts them (comment: "so one tile can never own two
  runtimes"). It is never called for `.managedAgent` tiles; managed-agent
  wiring has its own reuse guard (`agent(forTile:)` check) instead.

## 3. Creation order (new agent tile in a zone)

Order for `spawnManagedAgentFromPalette` (`ContinuumApp.swift:13295`) →
`TileSpawner.spawnManagedAgentForSelectedModel` (`TileSpawner.swift:1662`):

1. `resolvedCreationScope()` resolves precedence: armed zone (must have
   `projectId != nil`) → focused agent's project → `lastExplicitCreationScope`
   → explicit override (`ContinuumApp.swift:15758-15806`, `CreationScopeResolver`).
2. `spawnerForFilesystemCreation()` (:15898) resolves to
   `workspaceRuntime?.controller(for: projectId)?.tileSpawner` for that
   project **and returns nil if there is no controller for it** — refuses
   rather than falling back to the active project (comment explicitly calls
   out the old bug of installing into one project while persisting into
   another's canvas/session store).
3. `TileSpawner.spawnManagedAgent(...)` creates and installs the **TILE**
   first (`installProjectTile` + `saveCanvas`/`persistProjectCanvas`), and only
   then calls the `wire:` closure.
4. `wire` → `wireManagedAgentTile(tileId, ...)` (`ContinuumApp.swift:13452`)
   creates the **RECORD** via `spawnSupervisedAgentAtHome`/`spawnSupervisedAgent`
   (which reads `managedAgentCreationScope(tileId:)` memoized on the spawner —
   this carries the project home: `projectRoot`/`checkoutRoot`/`homeRelativePath`),
   then calls `supervisor.attach(agentID:to:)` to set `record.tileId = tileId`.
5. The provider **runner/process** is not started at all here — per
   `restore()`'s doc, a managed agent stays idle (no process) until the first
   prompt is sent (`supervisor.send`).

So: **Tile → Record → attach (tileId) → runner-on-first-prompt.** The
**record** (via `checkoutRoot`/`homeRelativePath`/`projectId`) is the sole
holder of "project home" — the tile carries none of it.

## 4. Project-less / group zone behaviour

- `resolvedCreationScope()`'s `zoneScope` explicitly requires
  `zone.projectId != nil` (`ContinuumApp.swift:15784`: `guard let projectId =
  zone.projectId, ... else { return nil }`) — a project-less "group zone" never
  supplies a zone-sourced creation scope.
- If no other rung resolves (no focused agent, no recent explicit scope), the
  palette path (`spawnManagedAgentFromPalette`, :13295) sees
  `resolvedCreationScope() == nil` and calls `requestCreationScope` (the
  project-home picker) instead of spawning — so a *bare* project-less zone with
  no prior context cannot silently mint a mis-homed agent; it prompts.
- **But** `recentScope`/`focusedScope` can supply a **stale/foreign** projectId
  (from a different, previously-used project) while the **armed/target zone**
  for placement is still the project-less group zone (armed zone selects
  *where the tile is framed/installed*, independent of which project supplies
  the creation scope precedence rung). I did not find a guard tying "tile's
  target zoneId" to "creation scope's projectId" for this specific combination
  within this pass's time budget — this is the most concrete lead toward
  Dylan's "tile comes up with blank project home and inert home selector"
  symptom and should be top of the follow-up list. `CreationScope` from
  `recentScope`/`focusedScope` carries no `zoneId` (only the `.zone` source
  rung sets `zoneId:`), so the tile's placement zone and the record's home
  project can diverge whenever a group zone is the on-screen target but a
  stale creation-scope rung answers "which project."
- **Is it possible to create an agent tile inside a group zone at all?** Yes,
  by picking a project via the picker (`presentCreationScopePicker`,
  :15855-15895) — and that path **arms the picked project's own zone**, not
  the group zone (`workspaceRuntime?.setActiveZone(zoneId, ...)`, :15887-15890),
  so a deliberate pick relocates "current zone" to the project's zone rather
  than leaving the tile framed inside the group zone. Whether the resulting
  tile still gets visually placed inside the original group zone (via
  `installProjectTile`'s target zone) vs. redirected elsewhere was not fully
  traced in this pass.

## 5. Liveness reconciliation plan (`.plans/57-agent-liveness-reconciliation.md`)

- **Untracked** — `git log --follow` on this path returns nothing; `.plans/`
  is not gitignored but this specific file (along with 55/56/59/62-65) is
  listed `??` in `git status`, i.e. **never committed**. There is no shipped
  code tied to this plan's slices (A–D) as commits; the doc's own header says
  "Status: investigation complete; implementation not started."
- **Scope is unrelated to record/tile Home linkage.** The whole plan is about
  *liveness/working-status* staleness (subagent rows staying "Working" after
  they ended) across Pi/Claude/Codex event translation and terminal observers —
  F1–F4 and the surface defects are all about `TurnFacts`/`AgentStatusEngine`/
  runner-generation callback races. **It does not describe any reconciliation
  step that clears a record's `projectRoot`/`checkoutRoot`/`homeRelativePath`,
  nor one that detaches a tile from its record.** It is not a plausible
  mechanism for the blank-home-after-sleep symptom; rule it out as a suspect.

## 6. Witness inventory (spawn-into-zone / record-tile linkage / orphan retirement)

Enumerated via `grep -oE '\-\-[a-z0-9-]+-check' Sources/ContinuumRevived/App/ContinuumApp.swift`:

- `--agent-restore-check` → `runAgentRestoreChecks()` (`AgentSupervisor.swift:12010`):
  builds a scratch `AgentStore`, seeds a previous-launch record with a live cwd
  and one with a missing cwd, asserts restore adopts the live one and marks
  the missing one stale (not deleted). Covers store/boot restore semantics,
  not tile linkage.
- `--agent-inventory-wiring-check` → `AppDelegate.runAgentInventoryWiringChecks()`.
  Covers cross-project agent inventory wiring.
- `--cross-project-agents-check` → `AppDelegate.runCrossProjectAgentDiscoveryChecks()`.
  Covers listing agents across projects (the `AgentInventory` walk), not
  tile-hydration linkage.
- `--zone-tile-hydration-check` → `ZoneTileHydrationChecks.run()`. Most likely
  candidate for exercising the Phase B hydration path tiles go through
  (`hydrateRuntimeBackedTiles`/`makeHydratedTileView`) but did not confirm it
  specifically drives the `.managedAgent` "no record → skip wiring" branch.
- `--zone-runtime-duplication-check` → `ZoneRuntimeDuplicationChecks.run()`.
  Almost certainly the witness for `retireOrphanedRuntimes` (terminal/browser
  runtime dedup on hydration) — named directly after the defect class it
  guards ("one tile can never own two runtimes").
- `--zone-unacquired-project-check` → `ZoneUnacquiredProjectChecks.run()`. Likely
  covers the `spawnerForFilesystemCreation()` refusal when
  `controller(for: projectId)` is nil (an unacquired project's zone).
- `--zone-tile-detach-sweep-check` → `ZoneTileDetachSweepChecks.run()`. Likely
  tile-detach/orphan sweep coverage, not agent-specific.
- `--managed-agent-model-spawn-check` → `TileSpawner.runManagedAgentModelSpawnSelfCheck()`.
  Drives `spawnManagedAgentForSelectedModel` with a departed model id, asserts
  no tile + no agent + refusal spoken (the function's own doc comment names
  this exact witness and a regression it caught: a reviewer swapped the
  refusal for a silent default and the check stayed green until fixed).
- `--zone-project-session-naming-check` → `ZoneRuntimeController.runProjectSessionNamingSelfCheck()`.
  Session-naming, not linkage.
- `--zone-spawner-coverage-check` → `ZoneRuntimeDuplicationChecks`-adjacent (line
  3503) — likely asserts every zone kind has spawner coverage, not specifically
  managed-agent record linkage.

**Notably absent:** I found no `--*-check` that specifically drives "spawn a
managed-agent tile inside a **project-less/group zone**" or "restart the app
with a tile present but its record missing from AgentStore and assert the tile
renders inert-but-does-not-duplicate." Those two are the most direct witnesses
for Dylan's reported symptom and, on this pass, do not appear to exist yet.

## Ranked suspects (for the sleep/blank-home/inert-selector symptom)

1. **Group-zone / stale creation-scope mismatch (§4).** A group zone (project-less)
   as the armed/placement zone, combined with a `recentScope`/`focusedScope`
   creation-scope rung naming a different project, is the most concrete
   mechanism found for a tile that ends up on-screen with a record whose
   Home doesn't match where the tile visually lives — consistent with "blank
   project home and inert home selector." Needs a repro trace through
   `installProjectTile`'s target-zone resolution to confirm definitively.
2. **Hydration skip for tiles with no record yet (§2, `ContinuumApp.swift:16473-16480`).**
   If a record write raced/failed or hadn't been flushed before a restart (or a
   second install wrote a duplicate under a different id — hazard 10), the tile
   silently stays unwired until a prompt is submitted. This matches "comes up
   blank... until he restarts the app" only partially — restarting doesn't fix
   an unwired tile by itself unless restore() also repopulates
   `agent(forTile:)`, which it should if the record exists on disk; if it does
   NOT fix it, that argues the record itself is the thing being lost/mismatched
   (points back to suspect 1 or 3).
3. **Second-install duplicate-record minting (hazard 10, `AgentStore.swift:150-158`).**
   Classic two-app-one-root collision. Less likely to be Dylan's day-to-day
   trigger (he runs one Applications-channel install per CLAUDE.md), but worth
   ruling out if any dev-channel build ever touched the same root.
4. **`.plans/57` liveness reconciliation** — ruled out; wrong problem domain and
   unshipped/uncommitted anyway.
