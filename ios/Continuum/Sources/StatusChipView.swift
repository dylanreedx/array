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

    var body: some View {
        let display = StatusChipPresenter.display(for: status)
        HStack(spacing: 4) {
            Text(display.glyph)
            Text(display.label)
        }
        .font(.system(size: 12, weight: .semibold))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .foregroundColor(Color(chip: display.foreground))
        .background(Color(chip: display.background))
        .clipShape(Capsule())
        .accessibilityLabel(display.label)
    }
}

// Internal rather than private since P1.8: the agents board and the canvas
// mirror paint a `StatusChipDisplay.accent` too, and a second copy of this
// conversion is a second place for the sRGB bridge to drift.
extension Color {
    init(chip: ChipColor) {
        self.init(.sRGB, red: chip.r, green: chip.g, blue: chip.b, opacity: 1)
    }
}
