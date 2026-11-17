import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

// Sidebar round (array/sidebar-next): the two non-agent rows the shared core
// adds to the list. Both rest on the panel with no fill (rows never paint a
// resting fill), use the sidebar's own type and tokens, and take their one
// action through the same capsule control as "All set?" (InboxSettleNudgeButton).
// Neither is TokenThemed: colours are resolved on appearance change, the
// pattern AgentInboxRemainderView uses.

/// A heading inside the list: "For you", "Other updates", "Standing".
struct SidebarSectionLabel: Equatable {
    enum Kind: String, Equatable { case forYou, otherUpdates, standing, inbox, historyNote }
    let kind: Kind
    let title: String
    let count: Int?
    /// "Clear N" on the right; 0 hides it.
    let clearCount: Int

    var identity: String { "section:\(kind.rawValue):\(title):\(count ?? -1):\(clearCount)" }
}

@MainActor
final class SidebarSectionLabelView: NSTableCellView {
    static let height: CGFloat = 28
    private let label = NSTextField(labelWithString: "")
    let clearButton = InboxSettleNudgeButton(frame: .zero)
    var onClear: (() -> Void)?
    private var model: SidebarSectionLabel?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.font = .token(.label)
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        let metaSize = Typography.style(for: .label).size
        clearButton.font = .systemFont(ofSize: metaSize, weight: .medium)
        clearButton.isPlain = true
        clearButton.image = NSImage(systemSymbolName: Self.clearSymbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: metaSize - 2, weight: .semibold))
        clearButton.image?.isTemplate = true
        clearButton.imagePosition = .imageLeading
        clearButton.target = self
        clearButton.action = #selector(clearPressed)
        clearButton.toolTip = "Clear acknowledges these updates. New activity brings them back."
        clearButton.setAccessibilityIdentifier("ContinuumSidebarClear")
        addSubview(clearButton)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { return nil }

    func apply(_ section: SidebarSectionLabel) {
        model = section
        identifier = NSUserInterfaceItemIdentifier("sidebar-section-\(section.kind.rawValue)")
        clearButton.isHidden = section.clearCount == 0
        clearButton.title = "Clear \(section.clearCount)"
        clearButton.setAccessibilityLabel("Clear \(section.clearCount) \(section.clearCount == 1 ? "update" : "updates")")
        applyTokens()
        needsLayout = true
    }

    var titleForQA: String { label.stringValue }
    /// Clear's glyph: a plain checkmark.
    static let clearSymbol = "checkmark"

    @objc private func clearPressed() { onClear?() }

    private func applyTokens() {
        guard let model else { return }
        let secondary = TextToken.textSecondary.color.nsColor(in: self)
        let text = NSMutableAttributedString(
            string: model.title, attributes: [.font: NSFont.token(.label), .foregroundColor: secondary])
        if let count = model.count {
            text.append(NSAttributedString(string: "  \(count)", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: Typography.style(for: .label).size, weight: .regular),
                .foregroundColor: secondary]))
        }
        label.textColor = secondary
        label.attributedStringValue = text
        label.setAccessibilityLabel(model.count.map { "\(model.title), \($0)" } ?? model.title)
        clearButton.applyTokens()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    override func layout() {
        super.layout()
        let inset = AgentInboxView.ledgerHorizontalInset
        var right = bounds.maxX - inset
        if !clearButton.isHidden {
            let size = clearButton.intrinsicContentSize
            let width = ceil(size.width), height = InboxSettleNudgeButton.height
            clearButton.frame = NSRect(x: right - width, y: floor((bounds.height - height) / 2),
                                       width: width, height: height)
            right = clearButton.frame.minX - 8
        }
        let labelHeight = ceil(label.intrinsicContentSize.height)
        label.frame = NSRect(x: inset, y: floor((bounds.height - labelHeight) / 2),
                             width: max(0, right - inset), height: labelHeight)
    }
}

/// One incident: icon, what happened, where, and its one action.
@MainActor
final class SidebarIncidentCellView: NSTableCellView {
    static let height: CGFloat = 44
    private let icon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    let actionButton = InboxSettleNudgeButton(frame: .zero)
    var onAction: (() -> Void)?
    private(set) var incident: SidebarIncident?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        titleLabel.font = .systemFont(ofSize: Typography.style(for: .body).size, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        detailLabel.font = .token(.label)
        detailLabel.lineBreakMode = .byTruncatingTail
        icon.imageScaling = .scaleProportionallyDown
        for view in [icon, titleLabel, detailLabel] { addSubview(view) }
        let metaSize = Typography.style(for: .label).size
        actionButton.font = .systemFont(ofSize: metaSize, weight: .medium)
        actionButton.imagePosition = .noImage
        actionButton.isPlain = true
        actionButton.target = self
        actionButton.action = #selector(actionPressed)
        addSubview(actionButton)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { return nil }

    func apply(_ incident: SidebarIncident, actionEnabled: Bool) {
        self.incident = incident
        identifier = NSUserInterfaceItemIdentifier("sidebar-incident-\(incident.id)")
        titleLabel.stringValue = incident.title
        detailLabel.stringValue = incident.detail
        actionButton.title = incident.actionTitle
        actionButton.isEnabled = actionEnabled
        actionButton.toolTip = actionEnabled ? nil : "Not available yet"
        actionButton.setAccessibilityLabel(incident.actionTitle)
        actionButton.setAccessibilityIdentifier("ContinuumSidebarIncidentAction-\(incident.id)")
        setAccessibilityLabel("\(incident.title). \(incident.detail)")
        icon.image = NSImage(systemSymbolName: incident.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        applyTokens()
        needsLayout = true
    }

    var titleForQA: String { titleLabel.stringValue }
    var detailForQA: String { detailLabel.stringValue }

    @objc private func actionPressed() { onAction?() }

    /// The symbol carries the only hue: red for a blocking failure, the
    /// approval accent for a raised hand, quiet for a pause or an update.
    private func applyTokens() {
        guard let incident else { return }
        titleLabel.textColor = TextToken.textPrimary.color.nsColor(in: self)
        detailLabel.textColor = TextToken.textSecondary.color.nsColor(in: self)
        let tint: NSColor
        switch incident.kind {
        case .needsYou: tint = AccentToken.accentApproval.color.nsColor(in: self)
        case .cause(let cause):
            switch cause {
            case .signInExpired, .couldNotStart, .taskError: tint = AccentToken.accentFailed.color.nsColor(in: self)
            case .usageLimit, .providerBusy, .interruptedByRestart: tint = TextToken.textSecondary.color.nsColor(in: self)
            }
        }
        icon.contentTintColor = tint
        actionButton.applyTokens()
        actionButton.alphaValue = actionButton.isEnabled ? 1 : Opacity.receded * 0.6
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    override func layout() {
        super.layout()
        let inset = AgentInboxView.ledgerHorizontalInset
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
        let block = titleHeight + detailHeight
        let top = floor((bounds.height + block) / 2)
        // Flipped = false: y grows upward.
        titleLabel.frame = NSRect(x: textX, y: top - titleHeight, width: max(0, textRight - textX), height: titleHeight)
        detailLabel.frame = NSRect(x: textX, y: top - block, width: max(0, textRight - textX), height: detailHeight)
        icon.frame = NSRect(x: inset, y: titleLabel.frame.midY - iconSize / 2, width: iconSize, height: iconSize)
    }
}
