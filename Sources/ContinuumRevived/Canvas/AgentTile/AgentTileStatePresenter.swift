import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Foundation

/// Pure presentation for the v2 agent header. Runtime events remain owned by the
/// tile's projection; this type only turns already-derived agent state into the
/// small, semantic summary the header paints.
struct AgentTileStatePresenter {
    struct Presentation: Equatable {
        let name: String
        let status: AgentStatus
        let stateLabel: String
        let stateAccessibilityLabel: String
        /// The exact unresolved request the tile should reveal. nil for every
        /// state that has no provider request behind it.
        let revealRequestID: String?
        let availableActionDescription: String
        let branch: BranchChipNSView.Display?
        let startedAt: Date?
        let elapsedSeconds: Int?
    }

    @MainActor
    static func present(
        name: String,
        snapshot: AgentTileTurnSnapshot,
        branchContext: AgentRowContext?,
        startedAt: Date?,
        now: Date = Date()
    ) -> Presentation {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = presentationState(for: snapshot)
        let isTimed: Bool
        switch snapshot.state {
        case .starting, .working, .queued, .needsAction: isTimed = true
        case .ready, .failed, .restored: isTimed = false
        }
        // The snapshot is the supervisor-owned clock. A tile-local `startedAt`
        // can be restamped when a capped event replay reaches `.turnStarted`, or
        // when the view is rebuilt after a workspace round trip. It is therefore
        // only a compatibility fallback, never allowed to reset a live turn.
        // `.starting` has no provider turn yet, so anchor that spawn window on the
        // supervisor's submission stamp instead.
        let anchor: Date?
        if case .starting = snapshot.state {
            anchor = snapshot.submittedAt ?? startedAt
        } else {
            anchor = snapshot.turnStartedAt ?? startedAt
        }
        let effectiveStart = isTimed ? anchor : nil
        let elapsed = effectiveStart.map { max(0, Int(now.timeIntervalSince($0))) }
        let accessibleState = elapsed.map { "\(resolved.accessibility), \($0) seconds elapsed" }
            ?? resolved.accessibility
        return Presentation(
            name: trimmedName.isEmpty ? "Agent" : trimmedName,
            status: resolved.status,
            stateLabel: resolved.label,
            stateAccessibilityLabel: accessibleState,
            revealRequestID: resolved.requestID,
            availableActionDescription: resolved.action,
            branch: BranchChipNSView.display(for: branchContext),
            startedAt: effectiveStart,
            elapsedSeconds: elapsed
        )
    }

    /// Compatibility projection for the P5.1 shell call sites. P5.4 replaces
    /// these with supervisor snapshots; keeping the overload avoids inventing
    /// operational facts in the view during this ticket.
    @MainActor
    static func present(
        name: String,
        status: AgentStatus,
        branchContext: AgentRowContext?,
        startedAt: Date?,
        now: Date = Date()
    ) -> Presentation {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = AgentStatusVocabulary.label(for: status)
        let isTimed = status == .working || status == .needsAttention
        let effectiveStart = isTimed ? startedAt : nil
        let elapsed = effectiveStart.map { max(0, Int(now.timeIntervalSince($0))) }
        let accessibleState = elapsed.map { "\(label), \($0) seconds elapsed" } ?? label
        return Presentation(
            name: trimmedName.isEmpty ? "Agent" : trimmedName,
            status: status,
            stateLabel: label,
            stateAccessibilityLabel: accessibleState,
            revealRequestID: nil,
            availableActionDescription: "Operational actions unavailable on compatibility presentation",
            branch: BranchChipNSView.display(for: branchContext),
            startedAt: effectiveStart,
            elapsedSeconds: elapsed
        )
    }

    private static func presentationState(
        for snapshot: AgentTileTurnSnapshot
    ) -> (status: AgentStatus, label: String, accessibility: String, requestID: String?, action: String) {
        switch snapshot.state {
        case .ready:
            let action = snapshot.capabilities.canSend ? "Send a prompt" : "No turn action available"
            let label = AgentStatusVocabulary.label(for: .idle)
            return (.idle, label, "Agent is \(label.lowercased()). \(action)", nil, action)
        case .starting:
            let action = snapshot.capabilities.canStop ? "Stop starting turn" : "No turn action available"
            return (.working, AgentStatusVocabulary.starting,
                    "Agent is starting. \(action)", nil, action)
        case .working:
            let action = snapshot.capabilities.canStop ? "Stop current turn" : "No turn action available"
            let label = AgentStatusVocabulary.label(for: .working)
            return (.working, label, "Agent is working. \(action)", nil, action)
        case .queued:
            let label = AgentStatusVocabulary.label(for: .working)
            return (.working, label, "Prompt is queued. No immediate turn action available", nil, "No immediate turn action available")
        case .needsAction(let request):
            let choices: String
            switch request.responseMode {
            case .fixedChoice(let values):
                choices = values.isEmpty ? "No response choices are available" : "Choices: \(values.joined(separator: ", "))"
            case .freeform:
                choices = "A written response is available"
            case .optionalNote(let values):
                choices = "Choices: \(values.joined(separator: ", ")); an optional note is available"
            }
            let label = AgentStatusVocabulary.label(for: .needsAttention)
            return (.needsAttention, label, "Agent needs action. \(request.prompt). \(choices)", request.requestID, "Reveal provider request")
        case .failed(let message):
            let detail = message?.trimmingCharacters(in: .whitespacesAndNewlines)
            let accessibility = detail.flatMap { $0.isEmpty ? nil : $0 }.map { "Agent turn failed. \($0)" } ?? "Agent turn failed"
            let action = snapshot.capabilities.canSend ? "Retry with a new prompt" : "No retry action available"
            return (.idle, AgentStatusVocabulary.failed, "\(accessibility). \(action)", nil, action)
        case .restored:
            let action = snapshot.capabilities.canSend ? "Send a prompt to continue" : "No turn action available"
            let label = AgentStatusVocabulary.label(for: .idle)
            return (.idle, label, "Agent was restored from a previous session. \(action)", nil, action)
        }
    }
}
