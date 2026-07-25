import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Foundation

@MainActor
final class TranscriptCardView: NSView, TokenThemed {
    private let titleLabel = NSTextField(labelWithString: "")
    private let bodyLabel = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    /// P1.9: the fill is keyed on the kind, so re-applying it on an appearance
    /// change needs the kind kept, not just consumed in `init`.
    private var cardKind: ManagedTranscriptCardKind

    init(card: ManagedTranscriptCard) {
        self.cardKind = card.kind
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Radius.card
        // 1pt is a hairline stroke, not a spacing value: neither `Space` nor
        // `Radius` covers border width, so there is no token to adopt here.
        layer?.borderWidth = 1
        applyTokens()

        titleLabel.font = .token(.title)
        titleLabel.textColor = StatusChipNSView.dynamicNSColor(TextToken.textPrimary.color)
        titleLabel.lineBreakMode = .byTruncatingTail
        // The body IS the content of the tile — it gets primary text, not the
        // secondary grey it had. Metadata sits one step down on the HOUSE
        // `textSecondary`, never a tertiary equivalent (2.25:1 on every card
        // fill, fails AA outright).
        bodyLabel.font = .token(.body)
        bodyLabel.textColor = StatusChipNSView.dynamicNSColor(TextToken.textPrimary.color)
        bodyLabel.isSelectable = true
        statusLabel.font = .token(.captionMono)
        statusLabel.textColor = StatusChipNSView.dynamicNSColor(TextToken.textSecondary.color)

        let header = NSStackView(views: [titleLabel, NSView(), statusLabel])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = Space.m

        let stack = NSStackView(views: [header, bodyLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        // `Space.s`, not the old 6 and not `Space.m`: a card's title and its body
        // are one unit, so the gap INSIDE a card has to stay smaller than the
        // `Space.m` gap the card stack puts BETWEEN cards — otherwise the
        // grouping reads inverted, which is the same rule as the radius nesting.
        stack.spacing = Space.s
        stack.edgeInsets = NSEdgeInsets(Inset.card)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        apply(card)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func applyTokens() {
        // `LineToken.border`, whose floor is 3:1 on every surface. The shipped
        // white@0.14 measured ~1.1:1 on these fills — invisible.
        layer?.borderColor = LineToken.border.color.cgColor(in: self)
        layer?.backgroundColor = Self.surface(for: cardKind).color.cgColor(in: self)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    func apply(_ card: ManagedTranscriptCard) {
        cardKind = card.kind
        applyTokens()
        titleLabel.stringValue = Self.title(for: card)
        bodyLabel.stringValue = card.body.isEmpty ? Self.bodyFallback(for: card) : card.body
        statusLabel.stringValue = Self.statusText(for: card)
        identifier = NSUserInterfaceItemIdentifier("managedAgent.card.\(card.id)")
    }

    private static func title(for card: ManagedTranscriptCard) -> String {
        switch card.kind {
        case .message, .userMessage: return card.title
        case .toolCall: return "tool · \(card.title)"
        case .plan: return "plan · \(card.title)"
        case .diff: return "diff · \(card.title)"
        case .error: return "error · \(card.title)"
        }
    }

    private static func bodyFallback(for card: ManagedTranscriptCard) -> String {
        switch card.kind {
        case .message, .userMessage: return ""
        case .toolCall: return card.itemKind?.rawValue ?? "tool call"
        case .plan: return "Plan is updating"
        case .diff: return "File changes pending"
        case .error: return "Runtime error"
        }
    }

    private static func statusText(for card: ManagedTranscriptCard) -> String {
        guard let status = card.status else { return "" }
        switch status {
        case .inProgress: return "running"
        case .completed: return "done"
        case .failed: return "failed"
        case .declined: return "declined"
        }
    }

    /// One card kind, one surface token. `SurfaceToken`'s six `cards` cases exist
    /// for exactly this switch, and they carry a light leaf as well as a dark one —
    /// the old literals were dark-only, which is the black-on-dark-under-Aqua bug.
    private static func surface(for kind: ManagedTranscriptCardKind) -> SurfaceToken {
        switch kind {
        case .message: return .cardMessage
        case .userMessage: return .cardUserMessage
        case .toolCall: return .cardTool
        case .plan: return .cardPlan
        case .diff: return .cardDiff
        case .error: return .cardError
        }
    }
}
