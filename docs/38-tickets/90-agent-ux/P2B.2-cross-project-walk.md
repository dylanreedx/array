# P2B.2 — Cross-project, cross-workspace agent discovery
Phase: 2B · Depends on: P2B.1 · Tag: autonomous · Execution-mode: medium

## Goal
An inbox must list agents from every project, not just the active one. Today only
`activeController.managedSessionStore` is reachable, and `ManagedAgentSessionRecord`s live per-project
on disk, so agents elsewhere are invisible.

## Files
- `Sources/ContinuumRevived/App/ContinuumApp.swift` (`currentManagedAgentActivities` ~:3730)
- `Sources/ContinuumRevivedCore/Agents/AgentInventory.swift`

## Approach
`AgentStore` (P2A.2) is already app-level, so new agents need no walk. For **legacy**
`ManagedAgentSessionRecord`s, iterate `registry.projects` roots and read each project's managed
session directory via `ProjectStoreLayout`. Skip roots that no longer exist (do not crash). Cache per
wake — this is disk I/O and the inbox refreshes often.

## Done when
Agents from a non-active project appear in the inventory.

## Verify
Check with two temp project roots, one agent record in each: inventory returns both. A third root that
does not exist on disk is skipped without throwing.

## Watch out
- Do not acquire a `ZoneRuntimeController` per project to read records — that would boot runtimes just
  to list agents. Read the persisted files directly.
- Respect the observer-independence rule (P2B.8): no live controller required.
