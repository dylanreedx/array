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
        let branch: BranchChipNSView.Display?
        let startedAt: Date?
        let elapsedSeconds: Int?
    }

    @MainActor
    static func present(
        name: String,
        status: AgentStatus,
        branchContext: AgentRowContext?,
        startedAt: Date?,
        now: Date = Date()
    ) -> Presentation {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let display = StatusChipPresenter.display(for: status)
        let isTimed = status == .working || status == .needsAttention
        let effectiveStart = isTimed ? startedAt : nil
        let elapsed = effectiveStart.map { max(0, Int(now.timeIntervalSince($0))) }
        let accessibleState = elapsed.map { "\(display.label), \($0) seconds elapsed" } ?? display.label
        return Presentation(
            name: trimmedName.isEmpty ? "Agent" : trimmedName,
            status: status,
            stateLabel: display.label,
            stateAccessibilityLabel: accessibleState,
            branch: BranchChipNSView.display(for: branchContext),
            startedAt: effectiveStart,
            elapsedSeconds: elapsed
        )
    }
}
