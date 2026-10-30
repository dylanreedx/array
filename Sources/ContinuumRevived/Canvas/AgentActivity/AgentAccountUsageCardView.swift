import AppKit
import ContinuumRevivedAgentUI

/// The account card that opens over a tile's usage pills (.plans/101,
/// Option 2). It replaced a plain-text tooltip that listed both windows as
/// paragraphs of `Account 5-hour usage: 84% used` beside source and scope
/// lines, and named no account at all.
///
/// What it says, in order: whose login this is (`Claude · Max`, the email),
/// then the 5-hour and weekly windows with the SAME layout — name, `% left`, a
/// bar, the reset — because Dylan reads both. One left edge for all of it: the
/// title and email line up with the window names below them.
///
/// Same surface as `InboxHoverCardView`: popover material, container radius,
/// control-boundary hairline, a shadow so it reads as above the canvas. It is
/// hosted in the window's content view for the same reasons that card is.
@MainActor
final class AgentAccountUsageCardView: NSView, TokenThemed {
    static let width: CGFloat = 300

    private let effect = NSVisualEffectView()
    private let contentStack = NSStackView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let windowsStack = NSStackView()
    private var windowRows: [(title: NSTextField, value: NSTextField, bar: AgentUsageBarView,
                              reset: NSTextField, state: AgentQuotaElementState)] = []
    private(set) var presentation: AgentAccountUsageCardPresentation?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.borderWidth = LineWidth.hairline
        effect.material = .popover
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.masksToBounds = true
        effect.autoresizingMask = [.width, .height]
        effect.frame = bounds
        addSubview(effect)
        layer?.shadowOpacity = 0.28
        layer?.shadowRadius = 16
        layer?.shadowOffset = NSSize(width: 0, height: -2)
        layer?.masksToBounds = false

        titleLabel.font = .token(.label)
        subtitleLabel.font = .token(.caption)
        for label in [titleLabel, subtitleLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        let header = NSStackView(views: [titleLabel, subtitleLabel])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 1
        header.detachesHiddenViews = true

        windowsStack.orientation = .vertical
        windowsStack.alignment = .leading
        windowsStack.spacing = CGFloat(Space.l)

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = CGFloat(Space.l)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.detachesHiddenViews = true
        for view in [header, windowsStack] { contentStack.addArrangedSubview(view) }
        addSubview(contentStack)
        let innerWidth = Self.width - CGFloat(Inset.card.left + Inset.card.right)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: CGFloat(Inset.card.left)),
            contentStack.topAnchor.constraint(equalTo: topAnchor, constant: CGFloat(Inset.card.top)),
            contentStack.widthAnchor.constraint(equalToConstant: innerWidth),
            header.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            windowsStack.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        applyTokens()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    func apply(_ next: AgentAccountUsageCardPresentation) {
        presentation = next
        titleLabel.stringValue = next.title
        subtitleLabel.stringValue = next.subtitle ?? ""
        subtitleLabel.isHidden = next.subtitle == nil
        windowsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        windowRows.removeAll()
        for window in next.windows {
            let title = NSTextField(labelWithString: window.title)
            title.font = .token(.label)
            let value = NSTextField(labelWithString: window.valueText)
            value.font = .token(.label)
            value.alignment = .right
            value.setContentHuggingPriority(.required, for: .horizontal)
            let spacer = NSView()
            spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
            let line = NSStackView(views: [title, spacer, value])
            line.orientation = .horizontal
            line.alignment = .firstBaseline
            let bar = AgentUsageBarView(preferredSize: NSSize(width: 0, height: 4))
            bar.translatesAutoresizingMaskIntoConstraints = false
            bar.remaining = window.remainingFraction
            bar.state = window.state
            let reset = NSTextField(labelWithString: window.resetText)
            reset.font = .token(.caption)
            reset.lineBreakMode = .byTruncatingTail
            let block = NSStackView(views: [line, bar, reset])
            block.orientation = .vertical
            block.alignment = .leading
            block.spacing = CGFloat(Space.s)
            windowsStack.addArrangedSubview(block)
            NSLayoutConstraint.activate([
                block.widthAnchor.constraint(equalTo: windowsStack.widthAnchor),
                line.widthAnchor.constraint(equalTo: block.widthAnchor),
                bar.widthAnchor.constraint(equalTo: block.widthAnchor),
                bar.heightAnchor.constraint(equalToConstant: 4),
            ])
            windowRows.append((title, value, bar, reset, window.state))
        }
        windowsStack.isHidden = next.windows.isEmpty
        setAccessibilityLabel(([next.title, next.subtitle].compactMap { $0 }
            + next.windows.map { "\($0.title) \($0.valueText), \($0.resetText)" }).joined(separator: ". "))
        applyTokens()
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    func applyTokens() {
        layer?.cornerRadius = CGFloat(Radius.container)
        effect.layer?.cornerRadius = CGFloat(Radius.container)
        layer?.borderColor = AgentLineRole.controlBoundary.color.cgColor(in: self)
        layer?.shadowColor = NSColor.black.cgColor
        let primary = TextToken.textPrimary.color.nsColor(in: self)
        let secondary = TextToken.textSecondary.color.nsColor(in: self)
        titleLabel.textColor = primary
        subtitleLabel.textColor = secondary
        for row in windowRows {
            row.title.textColor = primary
            row.value.textColor = Self.valueColor(row.state, in: self)
            row.reset.textColor = secondary
            row.bar.needsDisplay = true
        }
    }

    /// Same rule as the row's pills: only warning and critical carry a hue.
    private static func valueColor(_ state: AgentQuotaElementState, in view: NSView) -> NSColor {
        switch state {
        case .known: return TextToken.textPrimary.color.nsColor(in: view)
        case .warning: return AccentToken.accentApproval.color.nsColor(in: view)
        case .critical: return AccentToken.accentFailed.color.nsColor(in: view)
        case .unknown, .expired: return TextToken.textSecondary.color.nsColor(in: view)
        }
    }

    override var intrinsicContentSize: NSSize {
        let fitting = contentStack.fittingSize
        return NSSize(width: Self.width, height: fitting.height + CGFloat(Inset.card.top + Inset.card.bottom))
    }

    /// What the card says, in order, for a witness that must read the card
    /// rather than merely see that one appeared.
    var qaLines: [String] {
        [titleLabel.stringValue]
            + (subtitleLabel.isHidden ? [] : [subtitleLabel.stringValue])
            + windowRows.flatMap { [$0.title.stringValue, $0.value.stringValue, $0.reset.stringValue] }
    }
    /// Leading x of the title, the email and each window name, in card
    /// coordinates: the header must share the rows' left edge.
    var qaTitleLeadingX: CGFloat { convert(titleLabel.bounds, from: titleLabel).minX }
    var qaSubtitleLeadingX: CGFloat? {
        subtitleLabel.isHidden ? nil : convert(subtitleLabel.bounds, from: subtitleLabel).minX
    }
    var qaWindowTitleLeadingX: [CGFloat] { windowRows.map { convert($0.title.bounds, from: $0.title).minX } }
    var qaBarRemaining: [Double?] { windowRows.map(\.bar.remaining) }
    var qaValueColors: [NSColor?] { windowRows.map(\.value.textColor) }
}
