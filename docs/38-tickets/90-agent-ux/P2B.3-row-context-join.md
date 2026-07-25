# P2B.3 — Join workspace/zone/project/title onto each agent row
Phase: 2B · Depends on: P2B.2 · Tag: autonomous · Execution-mode: medium

## Goal
`AgentsBoardRow` carries only an id, a status, a summary and a timestamp — nothing to show a human
*which* agent this is. The inbox needs project, title, and (when it has a view) zone/workspace.

## Files
- `Sources/ContinuumRevivedCore/AgentsBoardProjection.swift`
- `Sources/ContinuumRevivedCore/Agents/AgentContextIndex.swift` (new)
- `Sources/ContinuumRevivedCoreChecks/AgentContextIndexChecks.swift` (new)

## Approach
Build a pure `AgentContextIndex`: `agentId → (workspaceName?, zoneName?, projectName?, tileTitle?,
agentKind, model, role?)`. `SidebarTreeBuilder` already resolves workspace/zone/tile names
(`Sources/ContinuumRevivedCore/SidebarTree.swift` ~:212-292) — derive from the same inputs rather than
re-implementing the geometry-membership logic. Headless agents legitimately have no zone/workspace;
model that as `nil`, not as an empty string.

Extend `AgentsBoardRow` with an optional `context` field so existing consumers (iOS) keep compiling.

## Done when
Rows carry enough to render "project · title · model" without a second lookup.

## Verify
Checks: a tiled agent resolves workspace+zone+title; a headless agent resolves project (from
`AgentRecord.projectId`) with nil zone/workspace; a tile in a project zone resolves via the same
geometric membership `SidebarTreeBuilder` uses (assert agreement with `SidebarTreeBuilder` output on a
shared fixture).

## Watch out
- Do not send context to the phone unless it is I5-safe: names are fine, **paths are not**.
- Keep `AgentsBoardRow` decodable by an older iOS build (optional field).
