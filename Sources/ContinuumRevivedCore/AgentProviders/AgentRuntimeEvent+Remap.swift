import Foundation

// Ticket: docs/38-tickets/88-provider-adapter-pi-gpt.md (slice 88.4b)
//
// A managed agent tile is a single-session surface keyed by a stable tile
// threadId (`managed-<uuid>`), but a provider adapter synthesizes its own
// threadId from the runtime's session (Pi uses its live session id). The tile
// filters events by its own threadId, so the wiring boundary rebinds every
// incoming event to the tile's thread before ingest. Pure + total so it can
// be pinned in the matrix.
extension AgentRuntimeEvent {
    public func withThreadId(_ threadId: String) -> AgentRuntimeEvent {
        switch self {
        case .sessionStateChanged:
            // No thread association — session-level; passes through untouched.
            return self
        case let .turnStarted(_, turnId):
            return .turnStarted(threadId: threadId, turnId: turnId)
        case let .turnCompleted(_, turnId, outcome, errorMessage):
            return .turnCompleted(threadId: threadId, turnId: turnId, outcome: outcome, errorMessage: errorMessage)
        case let .itemStarted(_, itemId, kind, title):
            return .itemStarted(threadId: threadId, itemId: itemId, kind: kind, title: title)
        case let .itemCompleted(_, itemId, kind, status):
            return .itemCompleted(threadId: threadId, itemId: itemId, kind: kind, status: status)
        case let .contentDelta(_, turnId, streamKind, delta):
            return .contentDelta(threadId: threadId, turnId: turnId, streamKind: streamKind, delta: delta)
        case let .requestOpened(_, requestId, kind):
            return .requestOpened(threadId: threadId, requestId: requestId, kind: kind)
        case let .requestResolved(_, requestId, decision):
            return .requestResolved(threadId: threadId, requestId: requestId, decision: decision)
        case let .userInputRequested(_, requestId, questions):
            return .userInputRequested(threadId: threadId, requestId: requestId, questions: questions)
        case let .userInputResolved(_, requestId):
            return .userInputResolved(threadId: threadId, requestId: requestId)
        case let .semanticSignal(_, itemId, kind):
            return .semanticSignal(threadId: threadId, itemId: itemId, kind: kind)
        case let .tokenUsageUpdated(_, snapshot):
            return .tokenUsageUpdated(threadId: threadId, snapshot: snapshot)
        case let .contextWindowUpdated(_, snapshot):
            return .contextWindowUpdated(threadId: threadId, snapshot: snapshot)
        case let .compactionChanged(_, event):
            return .compactionChanged(threadId: threadId, event: event)
        case let .childAgentSpawned(_, childAgentID, parentAgentID, displayName, sourceItemID, provider, spawnedAt):
            return .childAgentSpawned(threadId: threadId, childAgentID: childAgentID, parentAgentID: parentAgentID, displayName: displayName, sourceItemID: sourceItemID, provider: provider, spawnedAt: spawnedAt)
        case let .runtimeError(_, message):
            return .runtimeError(threadId: threadId, message: message)
        }
    }

    /// Tags provider telemetry with the context generation that owned the
    /// operation. Providers do not report Array's epoch, so doing this at the
    /// runner callback boundary is what lets the supervisor reject a delayed
    /// pre-compaction meter update after the boundary has advanced.
    public func withContextEpochIfMissing(_ epoch: UInt64) -> AgentRuntimeEvent {
        guard case .contextWindowUpdated(let threadId, var snapshot) = self,
              snapshot.contextEpoch == nil else { return self }
        snapshot.contextEpoch = epoch
        return .contextWindowUpdated(threadId: threadId, snapshot: snapshot)
    }
}
