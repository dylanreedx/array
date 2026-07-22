import AppKit
import ContinuumRevivedCore

// Ticket: docs/38-tickets/87-agent-ui-component-framework.md
//
// Thin macOS renderer for a StatusChipDisplay. Deliberately dumb: every
// decision (label, glyph, colours, contrast) lives in the shared, tested
// StatusChipPresenter. This view only paints. The iOS counterpart
// (StatusChipView, SwiftUI) paints the same display model.
final class StatusChipNSView: NSView {
    private let glyphLabel = NSTextField(labelWithString: "")
    private let textLabel = NSTextField(labelWithString: "")

    init(status: AgentStatus) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.masksToBounds = true

        glyphLabel.font = .systemFont(ofSize: 11, weight: .bold)
        textLabel.font = .systemFont(ofSize: 11, weight: .semibold)

        let stack = NSStackView(views: [glyphLabel, textLabel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 8, bottom: 3, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        apply(status)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has no storyboard use") }

    func apply(_ status: AgentStatus) {
        let display = StatusChipPresenter.display(for: status)
        glyphLabel.stringValue = display.glyph
        textLabel.stringValue = display.label
        let foreground = Self.nsColor(display.foreground)
        glyphLabel.textColor = foreground
        textLabel.textColor = foreground
        layer?.backgroundColor = Self.nsColor(display.background).cgColor
        toolTip = display.label
    }

    private static func nsColor(_ color: ChipColor) -> NSColor {
        NSColor(srgbRed: color.r, green: color.g, blue: color.b, alpha: 1)
    }
}
