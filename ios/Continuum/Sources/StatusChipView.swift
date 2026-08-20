import SwiftUI
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

// Ticket: docs/38-tickets/87-agent-ui-component-framework.md
//
// Thin iOS renderer for a StatusChipDisplay — the SwiftUI counterpart of the
// macOS StatusChipNSView. Both paint the same shared, tested
// StatusChipPresenter output; neither holds any logic.
struct StatusChipView: View {
    let status: AgentStatus
    var terminalOutcome: AgentTerminalOutcome? = nil

    var body: some View {
        let display = StatusChipPresenter.display(for: status)
        let terminal = terminalDisplay
        HStack(spacing: 4) {
            Text(terminal?.glyph ?? display.glyph)
            Text(terminal?.label ?? display.label)
        }
        // P1.12: a ROLE, not a size. `.label` is `.caption` on iOS — 12pt at the
        // default Dynamic Type size, which is the size this pill already shipped,
        // and it now scales with the reader's setting instead of ignoring it.
        //
        // The WEIGHT does move, and deliberately: `.label` is `medium`, where this
        // pill hardcoded `semibold`. Adopting a role means adopting the role's
        // weight — the alternative (role for size, hand-picked weight) is the
        // half-adoption that lets the two platforms drift apart again, and it is
        // the same collapse the desktop already made (Typography's own mapping
        // table records `UserInputCardView.headerLabel 11 semibold -> label`).
        // Visible change, noted for the owner; not a layout change.
        .font(Font(role: .label))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .foregroundColor(terminal?.color ?? Color(chip: display.foreground))
        .background(Color(chip: display.background))
        .clipShape(Capsule())
        .accessibilityLabel(terminal?.label ?? display.label)
    }

    private var terminalDisplay: (glyph: String, label: String, color: Color)? {
        guard status != .working, status != .needsAttention, let terminalOutcome else { return nil }
        switch terminalOutcome {
        case .succeeded: return ("✓", "Done", .green)
        case .failed, .runtimeError: return ("△", "Failed", .red)
        case .interrupted: return ("◉", "Stopped", .secondary)
        case .cancelled: return ("×", "Cancelled", .secondary)
        }
    }
}
