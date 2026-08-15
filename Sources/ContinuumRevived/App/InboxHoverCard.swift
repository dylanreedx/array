import AppKit
import ContinuumRevivedAgentUI

// Ticket: docs/38-tickets/96-agent-sidebar-product-redesign/_DESIGN.md
//
// THE TOOLTIP §4.3 ALREADY DEPENDS ON.
//
// The measured-fit sacrifice order lets a narrowing row drop its placement, its
// model text and its branch detail, on one stated condition: that "exact
// placement, branch, harness, provider, model ID, outcome, and timestamp remain
// in tooltip and accessibility detail". No tooltip has ever existed, so every one
// of those drops has been a plain loss — P0.1 measured three long-title flows
// rendering no project at all at the default width.
//
// So this is not a decoration on top of the row. It is the half of the density
// contract that was never built, and it is what makes the pitch ruling honest:
// the row can afford to say less precisely because something says the rest.
//
// Three of its lines are facts the sidebar has NEVER rendered — zone, harness,
// and a branch mismatch — and all three already existed upstream in
// `AgentRowContext` and were discarded by the row builder. `zoneName` had zero
// consumers in the entire app.

/// One labelled fact in the card. A row with nothing to say is not built.
struct InboxHoverCardLine {
    /// An SF Symbol name, or nil when `mark` carries the image instead.
    let symbol: String?
    /// A provider brand mark, for the model line.
    let mark: NSImage?
    let text: String
    /// Painted in the attention accent — the branch mismatch, and nothing else so
    /// far. A card where several lines shout is a card with no emphasis.
    let isWarning: Bool

    init(symbol: String? = nil, mark: NSImage? = nil, text: String, isWarning: Bool = false) {
        self.symbol = symbol
        self.mark = mark
        self.text = text
        self.isWarning = isWarning
    }
}

/// The floating identity card shown beside a hovered sidebar row.
///
/// It lives in the WINDOW's content view, not in the sidebar. Two reasons, both
/// learned the expensive way by other surfaces in this app:
///
///   * a subview of the sidebar that overhangs its trailing edge is drawn UNDER
///     the canvas pane, because the pane is added to the split view after the
///     sidebar — so the overhang is invisible rather than clipped, which is
///     harder to diagnose;
///   * it must not be added to the `NSSplitView` itself, which adopts an added
///     subview as a PANE and overwrites its frame on the next layout pass. That
///     is how the command palette once rendered as a full-height sidebar, and
///     the reason the window's content view is a plain container today.
@MainActor
final class InboxHoverCardView: NSView, TokenThemed {
    static let maximumWidth: CGFloat = 320
    /// Matches `ChoiceButton`'s glyph weight — these are labels for text, not
    /// pictures in their own right.
    private static let iconSide: CGFloat = 12

    private let titleLabel = NSTextField(labelWithString: "")
    private let stack = NSStackView()
    private var lineRows: [(icon: NSImageView, label: NSTextField, isWarning: Bool)] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = CGFloat(Radius.container)
        layer?.borderWidth = LineWidth.hairline
        // A floating surface casts a shadow so it reads as ABOVE the canvas rather
        // than as a hole punched in it.
        shadow = NSShadow()
        layer?.shadowOpacity = 0.28
        layer?.shadowRadius = 12
        layer?.shadowOffset = NSSize(width: 0, height: -2)
        layer?.masksToBounds = false

        titleLabel.font = .token(.label)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 2
        titleLabel.preferredMaxLayoutWidth = Self.maximumWidth - CGFloat(Inset.card.left * 2)

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = CGFloat(Space.s)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        stack.addArrangedSubview(titleLabel)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: CGFloat(Inset.card.left)),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -CGFloat(Inset.card.right)),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: CGFloat(Inset.card.top)),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -CGFloat(Inset.card.bottom)),
        ])
        applyTokens()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Decoration. The pointer belongs to the row underneath — a card that
    /// accepted the mouse would move hover off the very row it is describing, and
    /// then dismiss itself.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    func apply(title: String, lines: [InboxHoverCardLine]) {
        titleLabel.stringValue = title
        for row in lineRows {
            row.icon.removeFromSuperview()
            row.label.removeFromSuperview()
            row.icon.superview?.removeFromSuperview()
        }
        lineRows.removeAll()

        for line in lines {
            let icon = NSImageView(frame: .zero)
            icon.imageScaling = .scaleProportionallyDown
            if let mark = line.mark {
                icon.image = mark
            } else if let symbol = line.symbol {
                icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            }
            icon.setAccessibilityElement(false)
            let label = NSTextField(labelWithString: line.text)
            label.font = .token(.caption)
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            let row = NSStackView(views: [icon, label])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = CGFloat(Space.m)
            NSLayoutConstraint.activate([
                icon.widthAnchor.constraint(equalToConstant: Self.iconSide),
                icon.heightAnchor.constraint(equalToConstant: Self.iconSide),
            ])
            stack.addArrangedSubview(row)
            lineRows.append((icon, label, line.isWarning))
        }
        applyTokens()
        needsLayout = true
    }

    func applyTokens() {
        layer?.backgroundColor = SurfaceToken.overlay.color.cgColor(in: self)
        layer?.borderColor = AgentLineRole.controlBoundary.color.cgColor(in: self)
        layer?.shadowColor = NSColor.black.cgColor
        titleLabel.textColor = TextToken.textPrimary.color.nsColor(in: self)
        let secondary = TextToken.textSecondary.color.nsColor(in: self)
        let warning = AccentToken.accentApproval.color.nsColor(in: self)
        for row in lineRows {
            let colour = row.isWarning ? warning : secondary
            row.label.textColor = colour
            row.icon.contentTintColor = colour
        }
    }

    override var intrinsicContentSize: NSSize {
        let fitting = stack.fittingSize
        return NSSize(
            width: min(Self.maximumWidth, fitting.width + CGFloat(Inset.card.left + Inset.card.right)),
            height: fitting.height + CGFloat(Inset.card.top + Inset.card.bottom))
    }

    /// What the card is saying, in order, for a gate that must assert the card
    /// carries a fact rather than merely that a card appeared.
    var qaLinesForQA: [String] { [titleLabel.stringValue] + lineRows.map(\.label.stringValue) }
}
