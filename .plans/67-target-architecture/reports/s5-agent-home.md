# Agent tile project-home selector — blank "—" on fresh boot/wake

## UI trace (file:line)

- Placeholder render (compact status row, "unknown" state):
  `Sources/ContinuumRevived/Canvas/ManagedAgentTileNSView.swift:1762-1780`
  (`applyUnknownCompactStatus`) — sets `text: "—"`,
  `accessibilityLabel: "Home and Where: unknown."` at
  `ManagedAgentTileNSView.swift:1767-1769`. Fired whenever
  `projectedAgentID.flatMap { agentSource?.locationSnapshot(for: $0, at: now) }`
  is nil (`ManagedAgentTileNSView.swift:1744-1759`, the `else` branch at 1757-1759).
- Second placeholder site, once a snapshot IS available but resolves to an
  empty string: `compactLocationPresentation`,
  `ManagedAgentTileNSView.swift:1863-1892`, the `"—"` fallback at line 1888.
  (Not the live-bug path here — this only fires with a snapshot in hand.)
- Enablement / click route for the Home control: `compactStatusRow.onActionMenuRequested`
  closure, `ManagedAgentTileNSView.swift:353-356`:
  `guard let self, let agentID = self.projectedAgentID else { return }` — a nil
  `projectedAgentID` makes clicking the Home chip a **complete no-op**, no menu,
  no beep, nothing observable.
- App-side menu builder: `showLocationActionMenu`,
  `Sources/ContinuumRevived/App/ContinuumApp.swift:13658-13673`. Guard at
  **13659**: `guard let snapshot = agentSupervisor.locationSnapshot(for: agentID) else { return }`
  — same silent no-op if the agent has no record yet.
- The actual "Change Home" pick handler: `reassignHome`,
  `ContinuumApp.swift:13747-13761`.

## Data source

The Home/Where text is not read from a project registry list at render time —
it is a live projection off the agent's own persisted record via
`AgentSupervisor.locationSnapshot(for:)`
(`Sources/ContinuumRevived/App/AgentSupervisor.swift:1623-1627`):

```swift
func locationSnapshot(for id: AgentID, at now: Date = Date()) -> AgentLocationSnapshot? {
    guard let record = records[id] else { return nil }
    ensureLocationProjector(for: record)
    return locationProjectors[id]?.snapshot(at: now)
}
```

The ONLY way this returns nil is `records[id] == nil` — i.e. the agent tile
exists (view is installed, canvas persisted) but the supervisor never has a
record bound to it. The list of *candidate* homes offered by the picker
(`ProjectHomePickerController`, `Sources/ContinuumRevived/App/ProjectHomePickerController.swift`)
and by the native "Change Home"/"New Agent Here" submenu
(`projectActionSubmenu`, `ContinuumApp.swift:13695-13726`) both come from the
on-disk `registry.json` (`registryStore?.loadOrEmpty()`), filtered by
`!$0.missing` — a separate, later concern from the actual bug (that data is
fine; it's the *record* that's missing).

## Selection handler guards table

| Guard | Condition | File:line | Nil/false on fresh boot? |
|---|---|---|---|
| Home chip click routing | `self.projectedAgentID` must be non-nil | `ManagedAgentTileNSView.swift:354` | **Yes** — nil whenever `wireManagedAgentTile` bailed before calling `view.attach(agentID:...)` |
| Menu builder | `agentSupervisor.locationSnapshot(for: agentID)` must be non-nil | `ContinuumApp.swift:13659` | Yes — nil whenever `records[agentID]` is nil |
| `reassignHome` | `usableAgentHomeDirectory(cwd)` must resolve (path exists, is a dir) | `ContinuumApp.swift:13748` | Only if picked folder vanished; not the boot case |
| `reassignHome` | `agentSupervisor.reassignProvisionalHome(...)` must return true | `ContinuumApp.swift:13749-13752` → `AgentSupervisor.swift:1805-1829` | Inside it: `guard var record = records[id] else { return false }` (1806) — **Yes**, same root cause; and `guard !hasUserWorkOrSessionHistory(id) else { return false }` (1807) — false only after real activity, not the boot case |
| `spawnManagedAgentFromPalette` (the real "add agent" entry point) | `resolvedCreationScope() != nil` | `ContinuumApp.swift:13296` | Can be nil transiently — see Initial-home resolution below; when nil the app is supposed to prompt (`requestCreationScope`), not spawn blank |
| `wireManagedAgentTile` else-branch | `spawned` (the return of `spawnSupervisedAgentAtHome`/`spawnSupervisedAgent`) must be non-nil | `ContinuumApp.swift:13515`: `guard let spawnedAgentID = spawned else { return }` | **Yes** — the whole wire-up silently aborts, leaving a tile with a view but zero record, permanently (nothing retries it) |
| `spawnSupervisedAgent` | `ManagedAgentSpawnHomeResolver.resolve(selectedAgent:, activeProject:)` must succeed AND `usableAgentHomeDirectory` must resolve | `ContinuumApp.swift:13384-13391` | **Yes on fresh boot/wake** if `activeProject` is nil/stale and no tile is focused with an existing agent — exactly the state right after launch or a wake-triggered project re-scan |
| `spawnSupervisedAgentAtHome` | `launchSelection ?? AgentModelConfig.launchSelection()` must resolve | `ContinuumApp.swift:13417-13421` | Possible if the model catalogue's live probe (`AgentModelCatalog`, glossary #5) hasn't completed yet at boot |

## Initial-home resolution (fresh spawn into a zone)

Two *independent* resolutions of "what zone/project is this?" happen for one
spawn, and they can disagree:

1. **Spawn-time gate**: `spawnManagedAgentFromPalette` (`ContinuumApp.swift:13295-13324`)
   checks `resolvedCreationScope() != nil` (line 13296) before calling
   `spawner.spawnManagedAgentForSelectedModel`.
2. **Spawn-time scope actually used**: inside `TileSpawner.spawnManagedAgent`
   (`Sources/ContinuumRevived/App/TileSpawner.swift:1513-1602`), line **1525**
   re-calls `creationScopeProvider?()` — a **second, independent** call to
   `resolvedCreationScope()` (wired at `ContinuumApp.swift:16572`). The memo is
   only stored if non-nil: `TileSpawner.swift:1601`
   `if let creationScope { managedAgentCreationScopes[tileId] = creationScope }`.
3. **Wire-time scope read-back**: `wireManagedAgentTile`'s else-branch
   (`ContinuumApp.swift:13497-13498`) does a **third** independent lookup:
   `workspaceRuntime?.managedAgentCreationScope(tileId:) ?? tileSpawner?.managedAgentCreationScope(tileId:)`,
   which reads the memo written in step 2 (`WorkspaceRuntime.swift:442-450`).

`resolvedCreationScope()` itself (`ContinuumApp.swift:15758-15809`) depends on:
- `registryStore?.loadOrEmpty()` (disk read, line 15759) — feeds `root(for:)`
  used by every rung.
- `workspaceRuntime.document.lastActiveZoneId` / `canvasView?.activeProjectZonePlacement`
  / `canvasView?.activeZone` (lines 15777-15784) — the *armed zone*, which per
  hazard 9 has exactly one writer, `WorkspaceRuntime.setActiveZone`, and is
  reset by "clicking, focusing, creating a zone and panning."
- `focusedTileIdForPaletteContext()` + an *existing* agent record on that tile
  (15789-15801) — cannot rescue a fresh boot with no other agents yet.

**Where this resolves to nil on a fresh boot but not later:** three real
timing seams line up with "morning" and "wake from sleep":
- Registry/document load is asynchronous at app start; a spawn issued in the
  first moments after launch (or immediately after a wake-driven project
  re-verification, e.g. `Registry.markProjectMissingStatus`,
  `Sources/ContinuumRevivedCore/Registry.swift:70-80`) can see a project
  transiently `missing` or `root(for:)` return nil, dropping `zoneScope` to nil
  even though the zone visually has a project.
- The two-and-three-way re-resolution above (steps 1-3) is a TOCTOU window:
  the armed zone or the registry snapshot can change between the palette's own
  check (step 1) and the actual spawn/wire calls (steps 2-3) — a click,
  focus change, or camera settle firing `setActiveZone` in between (exactly
  the events hazard 9 names as re-pointing the armed zone) silently drops the
  scope for THIS spawn only.
- Once nil at every rung, `wireManagedAgentTile`'s else-branch falls to
  `spawnSupervisedAgent(tileId:, launchSelection:)`
  (`ContinuumApp.swift:13513`), which requires `activeProject` (also freshly
  loaded/possibly nil at boot) or a focused-tile's existing agent (none exist
  yet on a fresh boot) — `ManagedAgentSpawnHomeResolver.resolve` then fails,
  beeps, returns nil, and `wireManagedAgentTile` aborts at its final guard
  (`ContinuumApp.swift:13515`) with the tile view already on screen. Nothing
  ever retries this tile: a restart re-runs the whole boot sequence with a
  now-fully-loaded registry/document/catalogue, so the race window is gone and
  the next agent tile wires normally — matching the reported "restart the app
  ... it picks the proper home."

## Relationship to the agent RECORD store vs the shared canvas TILE

Per hazard 10: the canvas/tile (`<project>/.array/`) is shared across
channels, but the agent RECORD store is channel-split. A tile with no record
renders exactly the blank state described here
(`ManagedAgentTileNSView.swift:1762-1780`) — **this is the same failure mode
hazard 10 describes for the two-install case, but it also occurs single-install** whenever `wireManagedAgentTile` aborts before `spawn()`/`view.attach()` ever run, which is the mechanism above. Related but distinct:
`hydrateRuntimeBackedTiles` (`ContinuumApp.swift:16474-16485`), the Phase B
hydration path for zones below the live tier, has its own permanent skip:
```
for tile in layer.tiles where tile.kind == .managedAgent {
    guard agentSupervisor.agent(forTile: tile.id) != nil else { continue }   // 16483
    wireManagedAgentTile(tile.id)
}
```
If a *persisted* (not brand-new) managed-agent tile's record hasn't been
restored yet when its zone lazily hydrates (e.g. a wake-triggered re-hydration
racing agent-record restore), this silently and permanently leaves that tile
unwired too — same visible symptom, different trigger (restore race, not
fresh-spawn race), worth ruling in/out with a timestamped log if the fresh-spawn
theory doesn't reproduce. `retireOrphanedRuntimes` (`ContinuumApp.swift:16558`)
and the duplicate-mint path it guards against are downstream of a *different*
bug (two installs on one root) and don't appear to be involved here.

## Ranked suspects

1. **TOCTOU on `resolvedCreationScope()`** across the palette gate
   (`ContinuumApp.swift:13296`), the spawn-time memo write
   (`TileSpawner.swift:1525,1601`), and the wire-time read-back
   (`ContinuumApp.swift:13497-13498` / `WorkspaceRuntime.swift:442-450`) — an
   armed-zone or registry change between the three calls drops the scope for
   one spawn, cascading into the `spawnSupervisedAgent` fallback failing
   silently (`ContinuumApp.swift:13384-13391`) and `wireManagedAgentTile`
   aborting (`ContinuumApp.swift:13515`) with the tile already on screen.
2. **Registry/`activeProject` not yet loaded** at the moment of a fresh-boot
   or wake-triggered spawn, so both `zoneScope` (via `root(for:)`,
   `ContinuumApp.swift:15761,15786`) and the `activeProjectHome` fallback
   (`ContinuumApp.swift:13377-13380`) are nil simultaneously — nothing in this
   path retries or defers the spawn until the registry is ready.
3. **`AgentModelCatalog` live probe not finished at boot** (glossary #5)
   making `AgentModelConfig.launchSelection()` return nil
   (`ContinuumApp.swift:13417-13421`), same silent-abort outcome. Less likely
   given the palette's own model-selection guard would normally have already
   resolved a selection before this call, but the two calls are not
   guaranteed to see the same catalogue state.
4. **`hydrateRuntimeBackedTiles`'s permanent skip** (`ContinuumApp.swift:16482-16485`)
   for zones hydrating late relative to agent-record restore — same visible
   bug, applies to persisted tiles rather than brand-new ones; worth excluding
   before chasing suspect 1.

None of these were disproved; effort was capped at tracing the guard chain
from render back to spawn, not reproducing live. The fastest discriminating
test: log `resolvedCreationScope()`'s three call sites (13296, `TileSpawner`
1525, and the `wireManagedAgentTile` read-back) with timestamps and compare
against `activeProject`/registry-load completion timestamps on a cold boot.

## Existing witnesses

- `--managed-agent-model-spawn-check` drives `spawnManagedAgentForSelectedModel`
  end to end (`ContinuumApp.swift:13301-13306` comment) but exercises the
  refusal path, not the creation-scope TOCTOU.
- `--agent-restore-check` (`ContinuumApp.swift:13450` comment, via
  `paletteAgentSpawnBranch`) pins `wireManagedAgentTile`'s signature but is
  about tile/agent re-binding after restore, not a fresh-boot spawn race.
- No witness found that spawns a managed agent immediately after a cold boot
  (before registry/document/catalogue are guaranteed loaded) or immediately
  after a simulated wake. This looks like the actual gap: the bug is
  specifically about a timing window this repo's checks don't drive.
