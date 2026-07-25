# P2A.1 — AgentID + AgentRecord: the agent becomes an entity
Phase: 2A · Depends on: P1.12 · Tag: autonomous · Execution-mode: medium

## Goal
Today an agent's identity **is** its `tileId`, which produces three failures already in the code:
a *canvas layout* budget (`ZoneHydrationBudgetConfig`, max 4 live zones) silently freezes agents
beyond it; `ZoneRuntimeBudgetConfig.closeOnZero` tears down observers for non-current workspaces;
and relaunch rebuilds an empty tile because the tile is the agent's only home. This ticket
introduces the entity. **Locked decision: the agent is the entity; a tile is one view of it.**

## Files
- `Sources/ContinuumRevivedCore/Agents/AgentRecord.swift` (new)
- `Sources/ContinuumRevivedCoreChecks/AgentRecordChecks.swift` (new)

## Approach
```swift
public struct AgentID: Hashable, Codable, Sendable { public let rawValue: UUID }
public struct AgentRecord: Codable, Equatable, Sendable {
    public let schemaVersion: Int          // start at 1; decode-forward like TerminalSessionDescriptor
    public let id: AgentID
    public var displayName: String
    public var role: String?               // matches a .pi/agents/<role>.md id
    public var model: String               // fully-qualified (see P0.10 AgentModelConfig)
    public var thinking: String
    public var cwd: String                 // may be a worktree path (P2C)
    public var worktreeBranch: String?
    public var projectId: UUID?
    public var parentAgentID: AgentID?     // set by the orchestrator (P2D)
    public var createdAt: Date
    public var lastActivityAt: Date
    public var tileId: UUID?               // VIEW BINDING, not identity — nil means headless
}
```
Model `schemaVersion` + `decodeIfPresent` forward-compat on `TerminalSessionDescriptor`
(`Sources/ContinuumRevivedCore/TerminalSessionDescriptor.swift`, where `scrollback` is the
precedent). **I5 note:** this record is host-bound and MUST NOT cross the sync boundary — `cwd` and
`worktreeBranch` are host paths. It is the sibling of `ManagedAgentSessionRecord`, which the I5
comment in `AgentActivityEvent.swift:72-75` names as the correct home for host-bound fields.

## Done when
The type exists, round-trips, and `tileId` is documented and typed as an optional view binding.

## Verify
`AgentRecordChecks`: Codable round-trip exact (incl. `Date` — follow `AgentActivityEvent`'s
`timeIntervalSinceReferenceDate` precedent, NOT `timeIntervalSince1970`, which is lossy); decoding
a payload missing newer optional fields succeeds; a record with `tileId == nil` is valid.
Add an I5 witness: encoding an `AgentRecord` and running the Core taint scanner
(`SyncPayloadTaintScanner`) SHOULD flag it — proving it is host-bound and must never be published.

## Watch out
- Do not delete or migrate `ManagedAgentSessionRecord` here. Coexistence first; P2A.7 handles restore.
- Do not put lifecycle (settle/snooze) on this record — that is Phase 4's `settledOverride`.
- `displayName` is user-facing and renameable; `role` is an id. Do not conflate them.
