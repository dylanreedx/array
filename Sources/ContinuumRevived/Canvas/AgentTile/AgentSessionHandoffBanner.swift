import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Foundation

// Session handoff (`.plans/79-session-handoff`), phase 2. What an agent tile
// says, in place of its composer, while another app holds its session
// (`mocks/3-moving-sessions.png`): watching it, waiting to move it here, or
// paused because it was opened elsewhere.

/// The four states a tile can be in while its session is elsewhere.
enum AgentSessionHandoffState: Equatable {
    /// Read-only, following the session as `app` writes it.
    case watching(app: String, canCopy: Bool, canMove: Bool)
    /// The watched session closed in `app` (edge case 7).
    case ended(app: String)
    /// Move here, waiting for `app` to let go (edge case 8). The Claude and
    /// Codex apps close a session from their own window, not with `/exit`.
    case waitingToMove(app: String, closesInApp: Bool, canCopy: Bool)
    /// One of Array's own sessions was opened in `app` (edge case 1).
    case paused(app: String)

    var app: String {
        switch self {
        case let .watching(app, _, _), let .ended(app), let .waitingToMove(app, _, _), let .paused(app): return app
        }
    }
}

/// A banner button's meaning, handed to the host.
enum AgentSessionHandoffAction: String, Equatable {
    case moveHere
    case copyHere
    case continueHere
    case copyInstead
    case cancel
    case showApp
}

/// The banner. Paints in `draw(_:)` from tokens, like the band and the flip
/// banner beside it, so it adds no layer colour for the ui-probe census.
@MainActor
final class AgentSessionHandoffBanner: NSView {
    let titleLabel = NSTextField(labelWithString: "")
    let detailLabel = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private let buttonRow = NSStackView()
    private(set) var state: AgentSessionHandoffState?
    private(set) var buttons: [(AgentSessionHandoffAction, NSButton)] = []
    var onAction: ((AgentSessionHandoffAction) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = NSUserInterfaceItemIdentifier("agentTile.sessionHandoffBanner")
        icon.setAccessibilityElement(false)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        detailLabel.font = NSFont.systemFont(ofSize: 12)
        for label in [titleLabel, detailLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        let text = NSStackView(views: [titleLabel, detailLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        buttonRow.orientation = .horizontal
        buttonRow.spacing = CGFloat(Space.s)
        buttonRow.setContentHuggingPriority(.required, for: .horizontal)
        buttonRow.setContentCompressionResistancePriority(.required, for: .horizontal)
        let row = NSStackView(views: [icon, text, NSView(), buttonRow])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = CGFloat(Space.m)
        row.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 10)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: CGFloat(Space.m)),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -CGFloat(Space.m)),
            row.topAnchor.constraint(equalTo: topAnchor, constant: CGFloat(Space.m)),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -CGFloat(Space.m)),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func apply(_ next: AgentSessionHandoffState) {
        guard next != state else { return }
        state = next
        let symbol: String
        let actions: [(AgentSessionHandoffAction, String)]
        switch next {
        case let .watching(app, canCopy, canMove):
            symbol = "eye"
            titleLabel.stringValue = "Watching \u{00B7} running in \(app)"
            detailLabel.stringValue = "Read-only. The session stays in \(app)."
            actions = (canMove ? [(.moveHere, "Move here")] : []) + (canCopy ? [(.copyHere, "Copy here")] : [])
        case let .ended(app):
            symbol = "stop.circle"
            titleLabel.stringValue = "Ended in \(app)"
            detailLabel.stringValue = "Nothing holds the session now. Continue it here."
            actions = [(.continueHere, "Continue here")]
        case let .waitingToMove(app, closesInApp, canCopy):
            symbol = "arrow.down.right.square"
            titleLabel.stringValue = "Still open in \(app)"
            detailLabel.stringValue = closesInApp
                ? "Close it in the \(app.replacingOccurrences(of: " app", with: "")) app and it continues here."
                : "Type /exit there and it continues here."
            actions = (canCopy ? [(.copyInstead, "Copy instead")] : []) + [(.cancel, "Cancel")]
        case let .paused(app):
            symbol = "pause.circle"
            titleLabel.stringValue = "Paused \u{00B7} also open in \(app)"
            detailLabel.stringValue = "So the two don't overwrite each other. Continues here when it closes."
            actions = [(.showApp, "Show \(app)")]
        }
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        buttonRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        buttons = actions.map { action, title in
            let button = NSButton(title: title, target: self, action: #selector(pressed(_:)))
            button.bezelStyle = .rounded
            button.controlSize = .regular
            button.identifier = NSUserInterfaceItemIdentifier("agentTile.sessionHandoff.\(action.rawValue)")
            buttonRow.addArrangedSubview(button)
            return (action, button)
        }
        setAccessibilityLabel("\(titleLabel.stringValue). \(detailLabel.stringValue)")
        needsDisplay = true
    }

    @objc private func pressed(_ sender: NSButton) {
        guard let action = buttons.first(where: { $0.1 === sender })?.0 else { return }
        onAction?(action)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let theme = effectiveTokenTheme
        let paused: Bool
        if case .paused = state { paused = true } else { paused = false }
        titleLabel.textColor = TextToken.textPrimary.color.nsColor(for: theme)
        detailLabel.textColor = TextToken.textSecondary.color.nsColor(for: theme)
        icon.contentTintColor = paused
            ? AccentToken.accentApproval.color.nsColor(for: theme)
            : TextToken.textSecondary.color.nsColor(for: theme)
        let card = bounds.insetBy(dx: CGFloat(Space.m) + 0.5, dy: CGFloat(Space.m) + 0.5)
        let radius = CGFloat(Radius.card)
        let path = NSBezierPath(roundedRect: card, xRadius: radius, yRadius: radius)
        SurfaceToken.cardMessage.color.nsColor(for: theme).setFill()
        path.fill()
        (paused ? AccentToken.accentApproval.color : LineToken.separator.color).nsColor(for: theme).setStroke()
        path.lineWidth = paused ? 1.5 : 1
        path.stroke()
    }
}
