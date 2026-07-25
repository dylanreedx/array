# P2B.5 — Drop the `kind == .terminal` filters
Phase: 2B · Depends on: P2B.4 · Tag: autonomous · Execution-mode: medium

## Goal
Make managed agents exist to the rest of the app. Two filters currently erase them:
`workspaceSidebarAgentStatuses` (`ContinuumApp.swift` ~:5652) filters `tile.kind == .terminal`, which
is literally why the sidebar prints "no agent" beside a live agent tile; and `currentAgentTileIds`
(~:4437) is terminal-only, so the dock badge, the needs-attention notification and the ⌥ agent-cycle
keys all skip managed agents.

## Files
- `Sources/ContinuumRevived/App/ContinuumApp.swift` (~:5652, ~:4437-4439)

## Approach
Source both from the P2B.4 snapshot instead of filtering tiles by kind. `currentAgentTileIds` becomes
"tiles that have an agent," derived from the inventory. Keep terminal agents working exactly as before
— this is additive.

## Done when
A managed-agent tile shows its status in the sidebar; ⌥ agent-cycle and the dock badge include managed
agents.

## Verify
Extend `--workspace-sidebar-live-status-check` (it already exists) with a managed-agent tile and assert
its row shows a real status rather than "no agent". Regression witness: the literal string `"no agent"`
must NOT appear for a tile that has an agent.

## Watch out
- `SidebarAgentStatusKind` collapses `configuring`/`idle` into `.unknown` → a managed agent in
  `configuring` may render as unknown-grey. Note it; fix belongs to P1.8/P3.2, not here.
- Do not remove the terminal path; both kinds must appear.
