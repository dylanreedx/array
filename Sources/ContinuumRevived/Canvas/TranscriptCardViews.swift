import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Foundation

/// P6.0: a transcript entry has two presentations, and the KIND is the key.
/// `.toolCall`/`.plan`/`.diff`/`.error` are structured records and keep the
/// bordered, titled `TranscriptCardView`; `.message`/`.userMessage` are prose and
/// get `TranscriptProseView`. The tile keeps one of these per card id and calls
/// `apply(_:)` on the next event, so both views answer the same two entry points.
@MainActor
protocol TranscriptEntryView: NSView, TokenThemed {
    func apply(_ card: ManagedTranscriptCard)
}

/// The kind→presentation decision, in one place. Both the tile's card stack and
/// the tour's per-kind gallery go through it, so the two cannot drift into
/// rendering the same kind differently.
@MainActor
func makeTranscriptEntryView(for card: ManagedTranscriptCard) -> TranscriptEntryView {
    switch card.kind {
    case .message, .userMessage: return TranscriptProseView(card: card)
    case .toolCall, .plan, .diff, .error: return TranscriptCardView(card: card)
    }
}

@MainActor
final class TranscriptCardView: NSView, TokenThemed, TranscriptEntryView {
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

/// P6.0: the prose half of the transcript. A conversation rendered as a uniform
/// stack of titled bordered records reads as a log viewer, so the two message
/// kinds lose all of it: no border, no title row, no status word.
///
/// A user turn is told apart from an assistant turn by a FILL and nothing else —
/// not a right-aligned bubble (the tile is resizable down to 320pt, where a
/// percentage-width bubble is indistinguishable from the full-width box this
/// replaces) and not a narrower column (the trailing edge belongs to the status
/// dot and `CornerOverlayView`).
@MainActor
final class TranscriptProseView: NSView, TokenThemed, TranscriptEntryView {
    private let bodyLabel = NSTextField(wrappingLabelWithString: "")
    /// Same reason `TranscriptCardView` keeps it: the fill is keyed on the kind, so
    /// re-applying it on an appearance change needs the kind kept.
    private var cardKind: ManagedTranscriptCardKind
    /// Held because the insets are keyed on the kind, the same way the fill is.
    private let stack = NSStackView()

    init(card: ManagedTranscriptCard) {
        self.cardKind = card.kind
        super.init(frame: .zero)
        wantsLayer = true
        applyTokens()

        bodyLabel.font = .token(.body)
        bodyLabel.textColor = StatusChipNSView.dynamicNSColor(TextToken.textPrimary.color)
        bodyLabel.isSelectable = true

        stack.addArrangedSubview(bodyLabel)
        stack.orientation = .vertical
        stack.alignment = .leading
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
        // No border on either kind, and no fill on `.message`: assistant prose sits
        // directly on the tile body, which is why `TextToken.textPrimary` on
        // `SurfaceToken.tileBody` is the pair that has to clear 4.5:1.
        layer?.backgroundColor = Self.fill(for: cardKind)?.color.cgColor(in: self)
    }

    /// Everything about the shape that is keyed on the kind, in one place.
    ///
    /// The radius belongs to the FILL: an assistant turn has no shape to round, so
    /// it gets none. The insets are `Inset.card` horizontally on both kinds — prose
    /// that touches the transcript's edge collides with the scroll view — and
    /// vertically only where there is a fill, whose text would otherwise sit on its
    /// own edge. An assistant turn keeps no vertical padding of its own, so the gap
    /// between two turns stays the card stack's `Space.m` and nothing here quietly
    /// invents a separator.
    private func applyShape() {
        let fill = Self.fill(for: cardKind)
        layer?.cornerRadius = fill == nil ? 0 : Radius.card
        stack.edgeInsets = NSEdgeInsets(
            top: fill == nil ? 0 : Inset.card.top,
            left: Inset.card.left,
            bottom: fill == nil ? 0 : Inset.card.bottom,
            right: Inset.card.right
        )
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    func apply(_ card: ManagedTranscriptCard) {
        cardKind = card.kind
        applyTokens()
        applyShape()
        // `bodyFallback` is "" for both prose kinds, so an empty prose card renders
        // as empty prose — not as an empty bordered box, which is what it did.
        bodyLabel.stringValue = card.body
        identifier = NSUserInterfaceItemIdentifier("managedAgent.card.\(card.id)")
    }

    /// The one permitted device. `nil` is the assistant's turn: the absence of a
    /// fill, not a fill that happens to match the backdrop.
    static func fill(for kind: ManagedTranscriptCardKind) -> SurfaceToken? {
        switch kind {
        case .userMessage: return .cardUserMessage
        case .message, .toolCall, .plan, .diff, .error: return nil
        }
    }

    /// What the QA probes assert about, so the presentation rule is readable from
    /// the view rather than restated in the gate.
    var qaCardKind: ManagedTranscriptCardKind { cardKind }
}
