# P2A.6 — Tile-less (headless) agents
Phase: 2A · Depends on: P2A.5 · Tag: autonomous · Execution-mode: medium

## Goal
Let an agent exist and run with no canvas tile at all. This is what unblocks (a) more than four
concurrent agents (the zone hydration budget caps *live zones*, so tile-bound agents beyond it
freeze) and (b) the orchestrator, which must spawn workers without doing canvas layout.

## Files
- `Sources/ContinuumRevived/App/AgentSupervisor.swift`
- `Sources/ContinuumRevived/App/ContinuumApp.swift` (`spawnManagedAgentFromPalette` ~:7385)
- `Sources/ContinuumRevivedCore/CanvasCommand.swift` (add a headless spawn command)

## Approach
`supervisor.spawn(...)` already returns an `AgentID` without needing a tile (P2A.3). Add a command
`agent.newHeadless` to `CommandRegistry` so it is reachable from ⌘K, and make the existing
`agent.newManaged` path = spawn + attach a tile. A headless agent is exactly a record with
`tileId == nil`.

Do not build the inbox here (Phase 3) — headless agents will simply be invisible until then except
via the palette/logs. Note that in the commit body so it is not mistaken for a bug.

## Done when
⌘K can spawn a running agent with no tile; it persists, runs, and appears in `supervisor.records`.

## Verify
`--agent-supervisor-check`: spawn headless with a stub runner; assert no tile exists in
`CanvasState`, the record has `tileId == nil`, the runner is alive, and events flow. Then attach a
tile and assert it replays history (P2A.4 path).

## Watch out
- Spawn admission: `TerminalSpawnAdmission` caps *terminals* (default 32) — headless agents are not
  terminals, but consider whether an agent cap is wanted. Do not invent one silently; if you think
  one is needed, note it for the owner rather than adding it.
- A headless agent with no UI must still be stoppable, or it leaks a process across the session.
