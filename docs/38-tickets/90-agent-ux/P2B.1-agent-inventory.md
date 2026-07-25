# P2B.1 — AgentInventory: one value describing every agent
Phase: 2B · Depends on: P2A.8 · Tag: autonomous · Execution-mode: high

## Goal
The union of terminal agents and managed agents exists today in exactly **one** place, momentarily,
inside the companion-sync closure: `DegradedDesktopActivitySnapshotSource.snapshot(descriptors:
liveStatuses:managedAgents:...)` (`Sources/ContinuumRevivedSync/DesktopCompanionSyncService.swift`
~:137-188). Promote it to an app-lifetime value the desktop reads too, so sidebar, badges, dock and
phone stop being four independent derivations.

## Files
- `Sources/ContinuumRevivedCore/Agents/AgentInventory.swift` (new)
- `Sources/ContinuumRevivedCoreChecks/AgentInventoryChecks.swift` (new)

## Approach
```swift
public struct AgentInventory: Sendable {
    public static func snapshot(
        terminalDescriptors: [TerminalSessionDescriptor],
        liveStatuses: [UUID: AgentStatus],
        agents: [AgentRecord],                    // from AgentStore (P2A.2)
        activityByAgent: [AgentID: [AgentActivityEventDraft]],
        replicaId: UUID, now: Date
    ) -> ActivityLogSnapshot
}
```
Reuse the existing fold `apply(_:_:)` from `AgentActivityEvent.swift` — do not write a second fold.
Keep `DegradedDesktopActivitySnapshotSource` as a thin caller so the companion path is unchanged in
behaviour; this is a promotion, not a rewrite.

## Done when
One function produces the snapshot the companion already publishes, and it also accepts headless
agents (no tile).

## Verify
`AgentInventoryChecks`: a fixture with 2 terminal + 2 managed (one headless) yields 4 entries;
deterministic sequence assignment (same input → byte-identical encode); the existing
`DesktopCompanionSyncPublisherTests` still pass unchanged (proof the companion path did not regress).

## Watch out
- Sequence numbers must stay monotonic per snapshot; the existing source assigns them positionally —
  keep that determinism or the phone's fold order changes.
- **I5:** the snapshot crosses to the phone. Do not leak `AgentRecord.cwd`/`worktreeBranch` into it.
