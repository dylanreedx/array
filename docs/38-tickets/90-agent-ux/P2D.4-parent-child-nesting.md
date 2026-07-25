# P2D.4 — Parent/child nesting in the inbox
Phase: 2D · Depends on: P2D.3, P3.6 · Tag: autonomous · Execution-mode: medium

## Goal
Delegated work has to read as a tree, or an orchestrator with four workers looks like five unrelated
agents.

## Files
- `Sources/ContinuumRevivedAgentUI/AgentInboxRow.swift` (from P3.1)
- `Sources/ContinuumRevived/App/` inbox list view (from P3.6)
- `Sources/ContinuumRevivedCore/AgentsBoardProjection.swift`

## Approach
`AgentRecord.parentAgentID` already exists (P2A.1). Add a pure grouping to the projection:
`rows(from:) -> [AgentInboxRow]` where children follow their parent with a `depth` of 1, parents keep
their frozen creation-order position (P3.4), and children sort by their own creation order **within**
the parent. Render children indented and collapsible; collapsed state is local UI state, not synced.

An orphaned child (parent archived) promotes to depth 0 rather than disappearing.

## Done when
An orchestrator and its children render as one collapsible group in creation order.

## Verify
Pure checks: a parent with 3 children yields 4 rows in parent→children order with correct depths;
frozen order holds (child activity does not move the parent); an orphan promotes to depth 0; a
2-deep chain is capped per P2D.2's depth cap.

## Watch out
- Do not let nesting break the frozen-order invariant from P3.4 — the check must cover both together.
- Keep grouping pure (in Core/AgentUI) so iOS can reuse it later without duplicating logic.
