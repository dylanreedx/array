# P2D.6 — Fan-out: N items → N agents
Phase: 2D · Depends on: P2D.5 · Tag: autonomous · Execution-mode: medium

## Goal
The highest-leverage multi-agent gesture, and the one Nyx demonstrated well: select N work items and
get one agent per item, each isolated, with the source item checked off when its agent finishes.

## Files
- `Sources/ContinuumRevived/App/AgentSupervisor.swift`
- `Sources/ContinuumRevived/Canvas/TicketQueueTileNSView.swift` and/or `ConductorQueueTileNSView.swift`
  (existing queue tiles are the natural source of items)
- `Sources/ContinuumRevivedCore/CanvasCommand.swift` (a `agent.fanOut` command)

## Approach
`supervisor.fanOut(items:role:isolated:) -> [AgentID]`: one agent per item, each with the item's text as
its prompt, all sharing a `parentAgentID` of nil (they are siblings, not children) **or** of the
orchestrator when invoked by one. Reuse the existing queue tiles' row selection rather than building a
new picker. On a child's `turnCompleted(.completed)`, mark the source item done via the queue tile's
existing update path.

Respect a concurrency cap: do not launch 30 agents because someone selected 30 rows. Cap, and report
what was deferred (never silently truncate).

## Done when
Selecting N rows spawns N isolated agents, and completing one checks off its row.

## Verify
`--agent-fanout-check` with stub runners: 3 items → 3 agents with distinct worktrees and prompts;
completing agent 2 marks item 2 done and leaves 1 and 3 untouched; selecting more than the cap spawns
the cap and reports the deferred count.

## Watch out
- Worktree cost: N agents = N worktrees. P2C.3 cleanup must handle a fan-out batch.
- **Never silently truncate** a fan-out — surface the cap, per the no-silent-caps rule.
- Item→agent mapping must survive a relaunch (store the source item id on the record) or completion
  will fail to check anything off.
