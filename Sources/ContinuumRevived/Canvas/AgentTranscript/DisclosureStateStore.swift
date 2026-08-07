import ContinuumRevivedAgentContent
import ContinuumRevivedCore

/// Disclosure is a view preference, not transcript content. Agent identity is
/// part of the key because provider block identifiers need only be stable inside
/// one agent's document.
struct ToolDisclosureKey: Hashable, Sendable {
    let agentID: AgentID
    let blockID: AgentNodeID
}

/// Retains explicit disclosure choices independently of reusable renderer views.
/// Absence is significant: it lets a block continue following the presenter's
/// status-based default until the user makes a choice.
@MainActor
final class DisclosureStateStore {
    static let shared = DisclosureStateStore()

    private var explicitStates: [ToolDisclosureKey: Bool] = [:]
    private var revisions: [ToolDisclosureKey: UInt64] = [:]

    func isExpanded(for key: ToolDisclosureKey, default defaultValue: @autoclosure () -> Bool) -> Bool {
        explicitStates[key] ?? defaultValue()
    }

    func explicitState(for key: ToolDisclosureKey) -> Bool? {
        explicitStates[key]
    }

    func setExpanded(_ expanded: Bool, for key: ToolDisclosureKey) {
        guard explicitStates[key] != expanded else { return }
        explicitStates[key] = expanded
        revisions[key, default: 0] &+= 1
    }

    /// Removes one bounded disclosure subtree. The caller owns the semantic
    /// tree, so it supplies the descendant IDs; the store remains a keyed
    /// preference store and never needs to retain a second ownership graph.
    func removeSubtree(
        for agentID: AgentID,
        rootID: AgentNodeID,
        descendantIDs: Set<AgentNodeID> = []
    ) {
        let blockIDs = descendantIDs.union([rootID])
        let keys = Set(blockIDs.map { ToolDisclosureKey(agentID: agentID, blockID: $0) })
        explicitStates = explicitStates.filter { !keys.contains($0.key) }
        // Revision entries are lifecycle state too. Do not leave tombstones
        // behind for IDs that can be reused in a later transcript session.
        revisions = revisions.filter { !keys.contains($0.key) }
    }

    func removeState(for key: ToolDisclosureKey) {
        explicitStates.removeValue(forKey: key)
        revisions.removeValue(forKey: key)
    }

    func removeAll(for agentID: AgentID) {
        explicitStates = explicitStates.filter { $0.key.agentID != agentID }
        revisions = revisions.filter { $0.key.agentID != agentID }
    }

    func presentationRevision(for key: ToolDisclosureKey) -> UInt64 {
        revisions[key, default: 0]
    }

    /// Binds agent identity at the transcript owner boundary without exposing it
    /// through AgentRenderContext. Renderers receive only block-scoped
    /// capabilities and cannot inspect or forge the owning session identity.
    func renderActions(
        for agentID: AgentID,
        perform: @escaping (AgentRenderAction) -> Void = { _ in },
        invalidatePresentation: @escaping (AgentNodeID) -> Void = { _ in }
    ) -> AgentRenderActions {
        AgentRenderActions(
            perform: perform,
            disclosureState: { [weak self] blockID, defaultValue in
                guard let self else { return defaultValue }
                return self.isExpanded(
                    for: ToolDisclosureKey(agentID: agentID, blockID: blockID),
                    default: defaultValue
                )
            },
            setDisclosureState: { [weak self] blockID, expanded in
                self?.setExpanded(
                    expanded,
                    for: ToolDisclosureKey(agentID: agentID, blockID: blockID)
                )
            },
            presentationRevision: { [weak self] blockID in
                self?.presentationRevision(
                    for: ToolDisclosureKey(agentID: agentID, blockID: blockID)
                ) ?? 0
            },
            invalidatePresentation: invalidatePresentation
        )
    }
}

extension AgentItemStatus {
    /// Active and exceptional work asks for attention. Routine completed work
    /// recedes unless the user explicitly opens it.
    var agentToolDefaultExpanded: Bool {
        switch self {
        case .inProgress, .failed:
            return true
        case .pending, .completed, .cancelled, .interrupted:
            return false
        }
    }

    var agentToolStatusPresentation: (glyph: String, label: String) {
        switch self {
        case .pending: return ("○", "Pending")
        case .inProgress: return ("◐", "In progress")
        case .completed: return ("✓", "Completed")
        case .failed: return ("!", "Failed")
        case .cancelled: return ("–", "Cancelled")
        case .interrupted: return ("!", "Interrupted")
        }
    }
}
