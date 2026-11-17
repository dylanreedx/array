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
    /// The Quiet inbox's head, from the core's per-render facts.
    func quietInboxHead(familyChips: [SidebarQuietInbox.FamilyChip]) -> [InboxListItem] {
        let blocking = SidebarQuietInbox.needsYou(sidebarIncidents)
        let clear = sidebarClearIDs.count
        guard clear > 0 || !blocking.isEmpty else { return [] }
        var items: [InboxListItem] = [.sectionLabel(SidebarSectionLabel(
            kind: .inbox, title: "Inbox", count: nil, clearCount: clear))]
        // A family's cause is said inside its own card, never stacked here.
        if !blocking.isEmpty { items.append(.quietNeedsYou(blocking)) }
        return items
    }

    /// Quiet inbox: each family's one cause line, placed right after its lead's
    /// own row so it draws inside that card. Any other layout, or a lead not in
    /// the list, adds nothing.
    func withFamilyCauseLines(_ items: [InboxListItem]) -> [InboxListItem] {
        guard sidebarLayout == .quietInbox, !sidebarFamilyChips.isEmpty else { return items }
        var byLead: [UUID: SidebarIncident] = [:]
        for chip in sidebarFamilyChips where Self.causeLineText(chip.incident) != nil {
            byLead[chip.familyId] = chip.incident
        }
        guard !byLead.isEmpty else { return items }
        var result: [InboxListItem] = []
        result.reserveCapacity(items.count + byLead.count)
        for item in items {
            result.append(item)
            if case .agent(let row) = item, row.depth == 0, let incident = byLead[row.id] {
                result.append(.familyCause(incident, leadId: row.id))
            }
        }
        return result
    }

    /// The cause line's words. The lead's count line is where "N failed" is
    /// said, so a failure's line keeps only its reason ("Codex was busy"); a
    /// failure with no reason has no line. A pause keeps "7 paused · usage".
    static func causeLineText(_ incident: SidebarIncident) -> String? {
        guard case .cause(let cause) = incident.kind else { return nil }
        switch cause {
        case .usageLimit, .interruptedByRestart:
            return incident.detail
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
        var onAction: (() -> Void)?
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
            setAccessibilityLabel("\(incident.title). \(incident.detail)")
            setAccessibilityIdentifier("ContinuumSidebarNeedsYou-\(incident.id)")
            icon.image = NSImage(systemSymbolName: incident.symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
            applyTokens()
            needsLayout = true
        }

        @objc private func actionPressed() { onAction?() }

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
            actionButton.frame = NSRect(x: bounds.maxX - inset - buttonWidth,
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
