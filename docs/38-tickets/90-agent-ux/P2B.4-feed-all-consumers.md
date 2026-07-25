# P2B.4 — Feed sidebar, badge, dock and companion from one value
Phase: 2B · Depends on: P2B.3 · Tag: autonomous · Execution-mode: high

## Goal
Collapse four independent derivations of "agent status" into one, so they cannot disagree. Today:
sidebar builds its own (`buildWorkspaceSidebarTree` ~:5608), canvas badges another
(`applyObserverStatuses` ~:4545), the dock/attention surface a third
(`refreshAgentAttentionSurface` ~:4461 via `currentAgentTileIds` ~:4437), and the companion a fourth.

## Files
- `Sources/ContinuumRevived/App/ContinuumApp.swift` (the four sites above)
- `Sources/ContinuumRevived/App/AgentSupervisor.swift`

## Approach
Hold one `ActivityLogSnapshot` on the app delegate, rebuilt from `AgentInventory` when anything
changes (agent event, observer status, canvas edit, workspace switch). Derive all four consumers from
it:
1. sidebar → `agentStatusesByTileId` for `SidebarTreeBuilder`
2. canvas badge → per-tile status
3. dock/attention → `AgentsBoardProjection.attentionCount`
4. companion → the existing `activitySnapshot` closure returns it directly

## Done when
All four read the same snapshot; no consumer computes status independently.

## Verify
`--agent-inventory-wiring-check`: set up one managed + one terminal agent, flip a status, assert the
sidebar tree, the tile badge, the attention count and the companion snapshot all reflect it from a
single rebuild. Regression witness: a status visible in the companion payload but absent from the
sidebar must FAIL.

## Watch out
- Rebuild cost: do not rebuild per streamed token. Debounce like `scheduleCompanionSyncPublish` does.
- Do not break the existing companion behaviour — `DesktopCompanionSyncPublisherTests` must stay green.
