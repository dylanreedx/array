import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

// Sidebar round (array/sidebar-next), the "Quiet inbox" layout (variants/A).
//
// The head: "Inbox" with Clear N, then a "Needs you" box that is in the list
// only while something blocks you (never an empty-state row), then one cause
// chip and one action per family (drawn by the shared incident row). The
// History shelf keeps a one-line footnote under it. Everything here reads the
// shared core (SidebarLedgerCore / SidebarQuietInbox); nothing is re-counted.

extension AgentInboxView {
    /// The cause line's words. The lead's count line is where "N failed" is
    /// said, so a failure's line keeps only its reason ("Codex was busy"); a
    /// failure with no reason has no line. A pause keeps "7 paused · usage".
    nonisolated static func causeLineText(_ incident: SidebarIncident) -> String? {
        guard case .cause(let cause) = incident.kind else { return nil }
        switch cause {
        case .usageLimit:
            return incident.detail
        case .interruptedByRestart:
            // The number is the count line's ("5 interrupted"); here, why.
            return "Interrupted by restart"
        case .providerBusy, .signInExpired, .couldNotStart, .taskError:
            guard let range = incident.detail.range(of: " · ") else { return nil }
            let reason = String(incident.detail[range.upperBound...])
            return reason.isEmpty ? nil : reason.prefix(1).uppercased() + reason.dropFirst()
        }
    }

    /// The History footnote: what Clear does, said where the cleared go.
    static let quietHistoryNote = "Clear keeps your agents and conversations."
}

/// The "Needs you" box: one rounded card on the lead cards' own fill, one line
/// per blocking incident, each with its one action. Built only when there is
/// at least one line.
@MainActor
final class SidebarQuietNeedsYouView: NSTableCellView {
    static let titleHeight: CGFloat = 30
    static let lineHeight: CGFloat = 40
    static let bottomPad: CGFloat = 6
    static func height(lines: Int) -> CGFloat { titleHeight + CGFloat(lines) * lineHeight + bottomPad }

    /// One line: icon, what happened, where, and its one action.
    final class Line: NSView {
        let icon = NSImageView()
        let titleLabel = NSTextField(labelWithString: "")
        let detailLabel = NSTextField(labelWithString: "")
        let actionButton = InboxSettleNudgeButton(frame: .zero)
        /// Every Needs-you item can be dismissed until something new happens.
        let dismissButton = InboxSettleNudgeButton(frame: .zero)
        var onAction: (() -> Void)?
        var onDismiss: (() -> Void)?
        private(set) var incident: SidebarIncident?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            titleLabel.font = .systemFont(ofSize: Typography.style(for: .body).size, weight: .regular)
            titleLabel.lineBreakMode = .byTruncatingTail
            detailLabel.font = .token(.label)
            detailLabel.lineBreakMode = .byTruncatingTail
            icon.imageScaling = .scaleProportionallyDown
            for view in [icon, titleLabel, detailLabel] { addSubview(view) }
            actionButton.font = .systemFont(ofSize: Typography.style(for: .label).size, weight: .medium)
            actionButton.imagePosition = .noImage
            actionButton.isPlain = true
            actionButton.target = self
            actionButton.action = #selector(actionPressed)
            addSubview(actionButton)
            dismissButton.isPlain = true
            dismissButton.title = ""
            dismissButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Dismiss")?
                .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
            dismissButton.imagePosition = .imageOnly
            dismissButton.toolTip = "Dismiss"
            dismissButton.setAccessibilityLabel("Dismiss")
            dismissButton.target = self
            dismissButton.action = #selector(dismissPressed)
            addSubview(dismissButton)
            setAccessibilityElement(true)
            setAccessibilityRole(.group)
        }

        required init?(coder: NSCoder) { return nil }
        override var isFlipped: Bool { true }

        func apply(_ incident: SidebarIncident, actionEnabled: Bool) {
            self.incident = incident
            titleLabel.stringValue = incident.title
            detailLabel.stringValue = incident.detail
            actionButton.title = incident.actionTitle
            actionButton.isEnabled = actionEnabled
            actionButton.toolTip = actionEnabled ? nil : "Not available yet"
            actionButton.setAccessibilityLabel(incident.actionTitle)
            actionButton.setAccessibilityIdentifier("ContinuumSidebarNeedsYouAction-\(incident.id)")
            dismissButton.setAccessibilityIdentifier("ContinuumSidebarNeedsYouDismiss-\(incident.id)")
            setAccessibilityLabel("\(incident.title). \(incident.detail)")
            setAccessibilityIdentifier("ContinuumSidebarNeedsYou-\(incident.id)")
            icon.image = NSImage(systemSymbolName: incident.symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
            applyTokens()
            needsLayout = true
        }

        @objc private func actionPressed() { onAction?() }
        @objc private func dismissPressed() { onDismiss?() }

        /// Red for a setup or sign-in blocker, the approval accent for a raised
        /// hand, quiet for a usage pause: the symbol carries the only hue.
        func applyTokens() {
            guard let incident else { return }
            titleLabel.textColor = TextToken.textPrimary.color.nsColor(in: self)
            detailLabel.textColor = TextToken.textSecondary.color.nsColor(in: self)
            switch incident.kind {
            case .needsYou: icon.contentTintColor = AccentToken.accentApproval.color.nsColor(in: self)
            case .cause(.signInExpired), .cause(.couldNotStart), .cause(.taskError):
                icon.contentTintColor = AccentToken.accentFailed.color.nsColor(in: self)
            case .cause:
                icon.contentTintColor = TextToken.textSecondary.color.nsColor(in: self)
            }
            actionButton.applyTokens()
            dismissButton.applyTokens()
            actionButton.alphaValue = actionButton.isEnabled ? 1 : Opacity.receded * 0.6
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            applyTokens()
        }

        override func layout() {
            super.layout()
            let inset = SidebarQuietNeedsYouView.contentInset
            let size = actionButton.intrinsicContentSize
            let buttonWidth = ceil(size.width), buttonHeight = InboxSettleNudgeButton.height
            let dismissWidth: CGFloat = 18
            dismissButton.frame = NSRect(x: bounds.maxX - inset - dismissWidth + 4,
                                         y: floor((bounds.height - buttonHeight) / 2),
                                         width: dismissWidth, height: buttonHeight)
            actionButton.frame = NSRect(x: dismissButton.frame.minX - 2 - buttonWidth,
                                        y: floor((bounds.height - buttonHeight) / 2),
                                        width: buttonWidth, height: buttonHeight)
            let iconSize: CGFloat = 16
            let textX = inset + iconSize + 8
            let textRight = actionButton.frame.minX - 8
            let titleHeight = ceil(titleLabel.intrinsicContentSize.height)
            let detailHeight = ceil(detailLabel.intrinsicContentSize.height)
            let top = floor((bounds.height - titleHeight - detailHeight) / 2)
            titleLabel.frame = NSRect(x: textX, y: top, width: max(0, textRight - textX), height: titleHeight)
            detailLabel.frame = NSRect(x: textX, y: top + titleHeight,
                                       width: max(0, textRight - textX), height: detailHeight)
            icon.frame = NSRect(x: inset, y: titleLabel.frame.midY - iconSize / 2, width: iconSize, height: iconSize)
        }
    }

    /// The card's gutter matches a lead card's; its content sits a card pad in.
    static var gutter: CGFloat { CGFloat(AgentInbox96CellView.outerGutter) }
    static var contentInset: CGFloat { InboxOwnershipChrome.pad }

    private let card = InboxGroupBackgroundView()
    private let titleLabel = NSTextField(labelWithString: "Needs you")
    private(set) var lines: [Line] = []
    var onAction: ((SidebarIncident) -> Void)?
    var onDismiss: ((SidebarIncident) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(card)
        titleLabel.font = .systemFont(ofSize: Typography.style(for: .body).size, weight: .semibold)
        addSubview(titleLabel)
        identifier = NSUserInterfaceItemIdentifier("sidebar-quiet-needs-you")
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("ContinuumSidebarNeedsYou")
    }

    required init?(coder: NSCoder) { return nil }
    override var isFlipped: Bool { true }

    func apply(_ incidents: [SidebarIncident], actionEnabled: Bool) {
        while lines.count < incidents.count {
            let line = Line()
            addSubview(line)
            lines.append(line)
        }
        while lines.count > incidents.count { lines.removeLast().removeFromSuperview() }
        for (line, incident) in zip(lines, incidents) {
            line.apply(incident, actionEnabled: actionEnabled && incident.kind == .cause(.usageLimit))
            line.onAction = { [weak self] in self?.onAction?(incident) }
            line.onDismiss = { [weak self] in self?.onDismiss?(incident) }
        }
        setAccessibilityLabel("Needs you, \(incidents.count)")
        applyTokens()
        needsLayout = true
    }

    var titleForQA: String { titleLabel.stringValue }

    private func applyTokens() {
        titleLabel.textColor = TextToken.textPrimary.color.nsColor(in: self)
        lines.forEach { $0.applyTokens() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    override func layout() {
        super.layout()
        let gutter = Self.gutter
        let cardRect = NSRect(x: gutter, y: 0, width: max(0, bounds.width - gutter * 2),
                              height: max(0, bounds.height - 2))
        card.frame = bounds
        // The lead cards' own solid fill and radius, one whole card.
        card.ownershipStrip = (cardRect, true, true)
        let inset = gutter + Self.contentInset
        let titleHeight = ceil(titleLabel.intrinsicContentSize.height)
        titleLabel.frame = NSRect(x: inset, y: floor((Self.titleHeight - titleHeight) / 2) + 2,
                                  width: max(0, bounds.width - inset * 2), height: titleHeight)
        for (index, line) in lines.enumerated() {
            line.frame = NSRect(x: gutter, y: Self.titleHeight + CGFloat(index) * Self.lineHeight,
                                width: cardRect.width, height: Self.lineHeight)
        }
    }
}

/// Quiet inbox, variants/A: one History item. A card with a clock, the title,
/// then "4 helpers · Nov 10". Helpers stay with their lead, so a family is one
/// item; clicking it opens the lead like any row.
@MainActor
final class SidebarQuietHistoryEntryView: NSTableCellView, AgentInboxRenameCell {
    /// A's history card (about 54pt) plus the gap to the next one.
    static let height: CGFloat = 60
    static let cardBottomGap: CGFloat = 4

    private let card = InboxGroupBackgroundView()
    private let selectionChrome = AgentInboxCardView()
    private let icon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")

    /// "4 helpers · Nov 10", "1 helper · Nov 10", or just the date.
    static func detail(helpers: Int, endedAt: Date?, now: Date, calendar: Calendar = .current) -> String {
        var parts: [String] = []
        if helpers > 0 { parts.append(helpers == 1 ? "1 helper" : "\(helpers) helpers") }
        if let endedAt {
            let formatter = DateFormatter()
            formatter.locale = Locale.current
            formatter.setLocalizedDateFormatFromTemplate(
                calendar.isDate(endedAt, equalTo: now, toGranularity: .year) ? "MMMd" : "MMMdyyyy")
            parts.append(formatter.string(from: endedAt))
        }
        return parts.joined(separator: " · ")
    }

    /// When the row's work ended, as History sorts it.
    static func endedAt(_ row: AgentInboxRow) -> Date? {
        row.terminalEvent?.endedAt ?? row.lifecycle.endedAt ?? row.lastActiveAt ?? row.createdAt
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(card)
        addSubview(selectionChrome)
        icon.image = NSImage(systemSymbolName: "clock", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
        icon.imageScaling = .scaleProportionallyDown
        titleLabel.font = .systemFont(ofSize: Typography.style(for: .body).size, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        detailLabel.font = .token(.label)
        detailLabel.lineBreakMode = .byTruncatingTail
        for view in [icon, titleLabel, detailLabel] { addSubview(view) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { return nil }
    override var isFlipped: Bool { true }

    var titleFrame: NSRect { titleLabel.frame }
    func acceptsRenameDoubleClick(at point: NSPoint) -> Bool { bounds.contains(point) }

    func apply(_ row: AgentInboxRow, helpers: Int, endedAt: Date?, now: Date) {
        titleLabel.stringValue = row.displayTitle
        shownDate = endedAt ?? Self.endedAt(row)
        detailLabel.stringValue = Self.detail(helpers: helpers, endedAt: shownDate, now: now)
        detailLabel.isHidden = detailLabel.stringValue.isEmpty
        setAccessibilityLabel([row.displayTitle, detailLabel.stringValue].filter { !$0.isEmpty }.joined(separator: ", "))
        setAccessibilityIdentifier(AgentInboxView.accessibilityIdentifier(for: row))
        applyTokens()
        needsLayout = true
    }

    func applySelection(isSelected: Bool, hasKeyboardFocus: Bool, increasedContrast: Bool) {
        selectionChrome.usesIncreasedContrast = increasedContrast
        selectionChrome.isSelected = isSelected
        selectionChrome.hasKeyboardFocus = hasKeyboardFocus
        setAccessibilitySelected(isSelected)
    }

    /// The family's last activity this card was given (the date it shows).
    private(set) var shownDate: Date?
    var titleForQA: String { titleLabel.stringValue }
    var detailForQA: String { detailLabel.isHidden ? "" : detailLabel.stringValue }
    var titleFrameForQA: NSRect { titleFrame }
    var detailFrameForQA: NSRect { detailLabel.frame }
    var cardFrameForQA: NSRect { cardRect }

    private func applyTokens() {
        titleLabel.textColor = TextToken.textPrimary.color.nsColor(in: self)
        detailLabel.textColor = TextToken.textSecondary.color.nsColor(in: self)
        icon.contentTintColor = TextToken.textSecondary.color.nsColor(in: self)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    private var cardRect: NSRect {
        let gutter = SidebarQuietNeedsYouView.gutter
        return NSRect(x: gutter, y: 0, width: max(0, bounds.width - gutter * 2),
                      height: max(0, bounds.height - Self.cardBottomGap))
    }

    override func layout() {
        super.layout()
        let rect = cardRect
        card.frame = bounds
        card.ownershipStrip = (rect, true, true)
        selectionChrome.frame = rect
        selectionChrome.underlayAlpha = card.alphaUnderCard
        let pad = SidebarQuietNeedsYouView.contentInset
        let iconSize: CGFloat = 13
        let textX = rect.minX + pad + iconSize + 7
        let width = max(0, rect.maxX - pad - textX)
        let titleHeight = ceil(titleLabel.intrinsicContentSize.height)
        let detailHeight = detailLabel.isHidden ? 0 : ceil(detailLabel.intrinsicContentSize.height)
        let gap: CGFloat = detailLabel.isHidden ? 0 : 3
        let top = rect.minY + floor((rect.height - titleHeight - gap - detailHeight) / 2)
        titleLabel.frame = NSRect(x: textX, y: top, width: width, height: titleHeight)
        detailLabel.frame = NSRect(x: textX, y: top + titleHeight + gap, width: width, height: detailHeight)
        icon.frame = NSRect(x: rect.minX + pad, y: titleLabel.frame.midY - iconSize / 2, width: iconSize, height: iconSize)
    }
}
