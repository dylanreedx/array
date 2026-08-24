import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedAgentUI

/// `.plans/45` S4.3 — the one-line summary a settled tool run folds to, and
/// the "N earlier steps" line above a live run. Modeled on
/// `AgentTranscriptTailItem`: the collection item hosts a list-owned view so
/// the summary text can be re-driven directly (durations arrive after the
/// fold) without a snapshot reload.
final class AgentToolClusterHeaderItem: NSCollectionViewItem {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("AgentToolClusterHeaderItem")

    private(set) var headerView: AgentToolClusterHeaderView?

    override func loadView() {
        view = NSView(frame: .zero)
    }

    func install() -> AgentToolClusterHeaderView {
        if let headerView, headerView.superview === view { return headerView }
        headerView?.removeFromSuperview()
        let header = AgentToolClusterHeaderView(frame: view.bounds)
        header.autoresizingMask = [.width, .height]
        view.addSubview(header)
        headerView = header
        return header
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        headerView?.removeFromSuperview()
        headerView = nil
    }
}

/// No fill and no painted layer colour: like the tail status label, this view
/// stays off the TokenThemed census by never owning a background — it is a
/// text line on the tile body, not an artifact (T6 rules stand).
@MainActor
final class AgentToolClusterHeaderView: NSView {
    static let fixedHeight = ToolCallView.rowHeight

    private(set) var disclosureButton = AgentDisclosureButton(frame: .zero)
    private(set) var iconView = NSImageView(frame: .zero)
    private(set) var summaryLabel = NSTextField(labelWithString: "")
    var onToggle: (() -> Void)?
    private(set) var clusterID: AgentNodeID?
    private(set) var isExpanded = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        disclosureButton.target = self
        disclosureButton.action = #selector(toggle(_:))
        iconView.image = CanvasSymbolImage.image(named: "checklist")
        iconView.imageScaling = .scaleProportionallyDown
        summaryLabel.font = NSFont.token(.body)
        summaryLabel.lineBreakMode = .byTruncatingTail
        addSubview(disclosureButton)
        addSubview(iconView)
        addSubview(summaryLabel)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    func apply(clusterID: AgentNodeID, summary: String, expanded: Bool, theme: TokenTheme, tokens: AgentRenderTokens) {
        self.clusterID = clusterID
        isExpanded = expanded
        setSummaryText(summary)
        disclosureButton.apply(expanded: expanded, title: summary)
        disclosureButton.contentTintColor = tokens.secondaryText.color.nsColor(for: theme)
        iconView.contentTintColor = tokens.secondaryText.color.nsColor(for: theme)
        summaryLabel.textColor = tokens.secondaryText.color.nsColor(for: theme)
        alphaValue = Opacity.receded
        identifier = NSUserInterfaceItemIdentifier("agent.toolCluster.\(clusterID.rawValue)")
        needsLayout = true
    }

    /// Direct text re-drive (the `setThinkingStatusText` move): a member
    /// completing updates the visible header without a snapshot reload.
    func setSummaryText(_ text: String) {
        guard summaryLabel.stringValue != text else { return }
        summaryLabel.stringValue = text
        setAccessibilityLabel("\(text), \(isExpanded ? "expanded" : "collapsed")")
    }

    @objc private func toggle(_ sender: Any?) {
        onToggle?()
    }

    override func mouseUp(with event: NSEvent) {
        // The whole line is the affordance, not just the chevron.
        let point = convert(event.locationInWindow, from: nil)
        if bounds.contains(point) {
            onToggle?()
        } else {
            super.mouseUp(with: event)
        }
    }

    override func layout() {
        super.layout()
        let inset = ToolCallView.horizontalInset
        let side = CGFloat(Space.xxl)
        disclosureButton.frame = NSRect(
            x: inset, y: (Self.fixedHeight - side) / 2, width: side, height: side)
        iconView.frame = NSRect(
            x: disclosureButton.frame.maxX + CGFloat(Space.s),
            y: (Self.fixedHeight - side) / 2, width: side, height: side)
        let labelHeight = summaryLabel.intrinsicContentSize.height
        let labelX = iconView.frame.maxX + CGFloat(Space.m)
        summaryLabel.frame = NSRect(
            x: labelX, y: (Self.fixedHeight - labelHeight) / 2,
            width: max(1, bounds.width - labelX - inset), height: labelHeight)
    }
}
