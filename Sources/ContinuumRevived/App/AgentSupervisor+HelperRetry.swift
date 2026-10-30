import ContinuumRevivedCore

extension AgentSupervisor {
    /// Current activity wins over an older terminal failure. Native mirrored
    /// children cannot be independently retried through the managed spawn path.
    func mayRetry(_ childId: AgentID, from parentId: AgentID) -> Bool {
        guard let child = records[childId], child.parentAgentID == parentId,
              child.capabilities != .observedReadOnly, !isRunning(childId) else { return false }
        // Stop closes presence synchronously; some CLIs never emit a closing
        // turn event after being killed. Prefer that current fact to an older
        // successful/failed turn, falling back to the durable event on restore.
        if let phase = turnPresence(for: childId)?.phase {
            switch phase {
            case .failed, .settled(.stoppedByUser), .settled(.interrupted), .settled(.processLost): return true
            case .idle: break
            default: return false
            }
        }
        guard let terminal = child.latestTerminalEvent else { return false }
        switch terminal.outcome {
        case .failed, .interrupted, .cancelled, .runtimeError: return true
        case .succeeded: return false
        }
    }
}
