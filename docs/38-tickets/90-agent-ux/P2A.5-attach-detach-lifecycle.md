# P2A.5 — Closing a tile must not kill the agent
Phase: 2A · Depends on: P2A.4 · Tag: autonomous · Execution-mode: medium

## Goal
The user-visible payoff of decoupling: closing a tile is closing a window, not ending the work.
Today deleting a managed-agent tile calls `managedSessionStore.delete(tileId:)`
(`ContinuumApp.swift` ~:3678) and the agent is gone.

## Files
- `Sources/ContinuumRevived/App/ContinuumApp.swift` (tile-close/delete path ~:3678, `sessionObserverTileDidClose`)
- `Sources/ContinuumRevived/App/AgentSupervisor.swift`

## Approach
Split the two concepts:
- **Close/detach the view** → `tile.detach()`, clear `AgentRecord.tileId`, agent keeps running.
- **Stop the agent** → an explicit action (`supervisor.stop`), reached from the inbox context menu
  (Phase 3) or an explicit "Stop agent" affordance — never as a side effect of closing a tile.

Add `supervisor.attach(agentID:to:)`/`detachView(agentID:)` so "Open in tile" (Phase 3) can rebind
later. When a tile closes, do NOT delete the agent record.

## Done when
Closing an agent tile leaves the agent running and listed; stopping is a separate deliberate action.

## Verify
Extend `--agent-supervisor-check`: attach a tile, close it, assert (a) the stub runner is still
running, (b) the record persists with `tileId == nil`, (c) events still flow to the supervisor.
Then `stop` and assert the runner terminated.

## Watch out
- The idle reaper keys on `ManagedAgentSessionRecord.lastSeenAt`
  (`ZoneRuntimeController.swift` ~:335-360) — make sure a detached, still-running agent is not
  reaped as idle. If the reaper would kill it, exclude supervisor-owned agents and note it.
- Canvas persistence removes the tile from `CanvasState`; that is correct and unrelated to the agent.
