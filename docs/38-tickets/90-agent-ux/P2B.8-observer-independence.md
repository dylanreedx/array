# P2B.8 — The inventory must not depend on live observers
Phase: 2B · Depends on: P2B.2 · Tag: autonomous · Execution-mode: medium

## Goal
`ZoneRuntimeBudgetConfig.closeOnZero` defaults true: releasing a project's last zone reference tears
down its `ZoneRuntimeController` and therefore its `SessionObserver`. So agents in non-current
workspaces stop being observed — an inbox that spans workspaces cannot rely on live observers, or it
will show stale/empty state for everything you are not currently looking at.

## Files
- `Sources/ContinuumRevivedCore/Agents/AgentInventory.swift`
- `Sources/ContinuumRevived/App/ContinuumApp.swift`

## Approach
Treat persisted state as the base truth and live observer status as an **overlay** for the agents that
happen to be observed — the shape `buildWorkspaceSidebarTree` already uses (persisted descriptors, then
`observedAgentStatuses` on top). Mark rows whose newest information is older than a threshold so the UI
can distinguish "idle" from "we have not heard from this in a while" (Phase 3/9 render it; here just
carry the fact).

## Done when
With no live controller for a project, its agents still appear with their last persisted status and a
staleness indication.

## Verify
Check: build the inventory with `liveStatuses` empty and only persisted records present — assert every
agent still appears with its persisted status and a staleness flag set. Then supply a live status and
assert the overlay wins.

## Watch out
- Do not conflate the existing `AgentStatus.stale` (a derived agent state, 300s timeout in
  `AgentStatusEngine`) with "we have no observer" — they are different facts. Name the new one
  distinctly (e.g. `isUnobserved`).
- Do not start controllers to freshen data. That is the trap this ticket exists to avoid.
