import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedAgentUI

/// The chips a settled turn's question offers, sitting above the editor.
///
/// This is a COMPOSER affordance, not a provider request. The distinction is the
/// whole design: `AgentRequestView` renders a request a harness opened and is
/// holding, and pressing one of its buttons dispatches a response to that
/// request. Pressing a chip here only writes text into the editor — the user
/// still sends it, exactly as if they had typed "the first one". Nothing is
/// resolved, nothing is answered on their behalf, and if the detector is wrong
/// the cost is a word in a text field they can delete.
///
/// Shape follows `ComposerFileReferenceRailView`: one scrolling row, chips paint
/// token surfaces, the rail itself leaves its resting background unpainted (nil,
/// never `.clear`) so the appearance census owns no literal here.
@MainActor
final class ComposerReplyOptionRailView: NSView, TokenThemed, AgentPageZoomScalable {
    static let railHeight: CGFloat = 34

    /// The rail's reserved height at `zoom`. The un-parameterised `railHeight`
    /// stays for callers that reserve space at 100%.
    static func railHeight(zoom: AgentPageZoom) -> CGFloat {
        CGFloat(zoom.scaled(34))
    }

    /// The plan popover's rail: shorter chips, every answer equal. The
    /// composer's own rail leaves this off.
    static func compactRailHeight(zoom: AgentPageZoom) -> CGFloat { CGFloat(zoom.scaled(30)) }
    var compact = false {
        didSet { if compact != oldValue { rebuild(); invalidateIntrinsicContentSize() } }
    }

    private(set) var pageZoom: AgentPageZoom = .default

    /// This rail's reserved height at its own zoom.
    var railHeight: CGFloat { compact ? Self.compactRailHeight(zoom: pageZoom) : Self.railHeight(zoom: pageZoom) }

    private let scrollView = NSScrollView(frame: .zero)
    private var scrollConstraints: [NSLayoutConstraint] = []
    private let stack = NSStackView(frame: .zero)
    private var options: [AgentReplyOption] = []
    /// A compaction offer: "Context is long · Compact now · Dismiss". It is a
    /// composer notice in the same rail, not a reply, and never writes text.
    private var noticeShown = false
    static let noticeCompactTitle = "Compact now"
    static let noticeDismissTitle = "Dismiss"
    static let noticeMessage = "Context is long"
    private let noticeLabel = NSTextField(labelWithString: ComposerReplyOptionRailView.noticeMessage)

    var onSelect: ((String) -> Void)?
    var onCompactNotice: (() -> Void)?
    var onDismissNotice: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureViews()
        applyTokens()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: options.isEmpty && !noticeShown ? 0 : railHeight)
    }

    func setOptions(_ newOptions: [AgentReplyOption]) {
        guard newOptions != options else { return }
        options = newOptions
        rebuild()
    }

    func setNotice(_ shown: Bool) {
        guard shown != noticeShown else { return }
        noticeShown = shown
        rebuild()
    }

    private func rebuild() {
        let newOptions = options
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let theme = effectiveTokenTheme
        if noticeShown {
            noticeLabel.font = NSFont.token(.caption, zoom: pageZoom)
            noticeLabel.textColor = TextToken.textSecondary.color.nsColor(for: theme)
            stack.addArrangedSubview(noticeLabel)
            for title in [Self.noticeCompactTitle, Self.noticeDismissTitle] {
                let chip = ComposerReplyOptionChipButton(option: AgentReplyOption(label: title), zoom: pageZoom)
                chip.target = self
                chip.action = #selector(chipPressed(_:))
                chip.applyTokens(theme: theme)
                chip.toolTip = title == Self.noticeCompactTitle
                    ? "Summarise this conversation to make room. Array asks before it ever compacts on its own."
                    : "Hide this until the context grows again"
                chip.setAccessibilityLabel(title == Self.noticeCompactTitle ? "Compact context now" : "Dismiss the compact suggestion")
                chip.identifier = NSUserInterfaceItemIdentifier("agent.composer.compactOffer")
                stack.addArrangedSubview(chip)
            }
        }
        for (i, option) in newOptions.enumerated() {
            // A chip minted after a zoom apply is born scaled: the rail's own
            // rung is handed to the initializer.
            let chip = ComposerReplyOptionChipButton(option: option, zoom: pageZoom, style: compact ? .compact : .standard)
            chip.target = self
            chip.action = #selector(chipPressed(_:))
            chip.applyTokens(theme: theme)
            stack.addArrangedSubview(chip)
        }
        isHidden = newOptions.isEmpty && !noticeShown
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    func applyTokens() {
        // Resting background is deliberately unpainted — a painted transparent
        // would register as an unadopted literal in the appearance census.
        layer?.backgroundColor = nil
        let theme = effectiveTokenTheme
        for case let chip as ComposerReplyOptionChipButton in stack.arrangedSubviews {
            chip.applyTokens(theme: theme)
        }
    }

    func applyPageZoom(_ zoom: AgentPageZoom) {
        pageZoom = zoom
        applyStackMetrics()
        for case let chip as ComposerReplyOptionChipButton in stack.arrangedSubviews {
            chip.applyPageZoom(zoom)
        }
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    private func applyStackMetrics() {
        stack.spacing = CGFloat(pageZoom.scaled(Space.s))
        stack.edgeInsets = NSEdgeInsets(
            top: CGFloat(pageZoom.scaled(Space.xs)), left: 0,
            bottom: CGFloat(pageZoom.scaled(Space.xs)), right: 0
        )
    }

    override var isHidden: Bool {
        didSet { if oldValue != isHidden { mountScrollView(!isHidden) } }
    }

    private func configureViews() {
        wantsLayer = true
        isHidden = true
        setAccessibilityRole(.group)
        setAccessibilityLabel("Suggested replies")
        setAccessibilityHelp(
            "Choices the agent's last message offered. Selecting one writes it into the composer; "
            + "it is not sent until you send it."
        )

        stack.orientation = .horizontal
        stack.alignment = .centerY
        applyStackMetrics()
        stack.translatesAutoresizingMaskIntoConstraints = false

        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = stack
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollConstraints = [
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentView.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
        ]
        mountScrollView(!isHidden)
    }

    /// An empty rail is hidden, but a hidden view's constraints are still solved,
    /// so its scroll view was re-framed and re-tiled on every camera step. It
    /// joins the hierarchy only while the rail has content.
    private func mountScrollView(_ mounted: Bool) {
        if mounted {
            guard scrollView.superview == nil else { return }
            addSubview(scrollView)
            NSLayoutConstraint.activate(scrollConstraints)
        } else {
            NSLayoutConstraint.deactivate(scrollConstraints)
            scrollView.removeFromSuperview()
        }
    }

    @objc private func chipPressed(_ sender: NSButton) {
        if noticeShown, let chip = sender as? ComposerReplyOptionChipButton,
           chip.identifier?.rawValue == "agent.composer.compactOffer" {
            if chip.optionValue == Self.noticeCompactTitle { onCompactNotice?() } else { onDismissNotice?() }
            return
        }
        guard let chip = sender as? ComposerReplyOptionChipButton,
              options.contains(where: { $0.label == chip.optionValue }) else { return }
        onSelect?(chip.optionValue)
    }

    // MARK: - QA seams

    var qaOptions: [String] { options.map(\.label) }
    var qaNoticeShown: Bool { noticeShown }
    @discardableResult
    func qaPressNotice(_ title: String) -> Bool {
        guard noticeShown, let chip = stack.arrangedSubviews
            .compactMap({ $0 as? ComposerReplyOptionChipButton })
            .first(where: { $0.optionValue == title && $0.identifier?.rawValue == "agent.composer.compactOffer" }) else { return false }
        chip.performClick(nil)
        return true
    }
    var qaChipTitles: [String] {
        stack.arrangedSubviews.compactMap { ($0 as? ComposerReplyOptionChipButton)?.title }
    }
    var qaChipAccessibilityLabels: [String] {
        stack.arrangedSubviews.compactMap {
            ($0 as? ComposerReplyOptionChipButton)?.accessibilityLabel()
        }
    }
    /// Non-empty AND every chip focusable: an empty rail must not read as
    /// "accessible" by vacuous truth.
    var qaChipsAcceptFocus: Bool {
        let chips = stack.arrangedSubviews.compactMap { $0 as? ComposerReplyOptionChipButton }
        return !chips.isEmpty && chips.allSatisfy(\.acceptsFirstResponder)
    }

    @discardableResult
    func qaPressChip(titled title: String) -> Bool {
        guard let chip = stack.arrangedSubviews
            .compactMap({ $0 as? ComposerReplyOptionChipButton })
            .first(where: { $0.optionValue == title }) else { return false }
        chip.performClick(nil)
        return true
    }
}

@MainActor
final class ComposerReplyOptionChipButton: NSButton {
    let optionValue: String
    private var hovered = false
    private var theme: TokenTheme = .dark
    private var tracking: NSTrackingArea?
    private(set) var pageZoom: AgentPageZoom
    enum Style { case standard, compact }
    let style: Style

    init(option: AgentReplyOption, zoom: AgentPageZoom = .default, style: Style = .standard) {
        self.style = style
        optionValue = option.label
        pageZoom = zoom
        super.init(frame: .zero)
        self.title = option.label
        isBordered = false
        bezelStyle = .inline
        focusRingType = .exterior
        font = NSFont.token(.caption, zoom: zoom)
        wantsLayer = true
        layer?.applyCorner(.card, zoom: zoom)
        // Keep the AppKit exterior keyboard focus ring outside the rounded fill.
        layer?.masksToBounds = false
        setButtonType(.momentaryChange)
        setAccessibilityRole(.button)
        // The reasoning the reply gave for this option, carried onto the control
        // rather than dropped. When the question is "which approach", the
        // tradeoff is the half you decide on, and the label alone has lost it.
        if let detail = option.detail {
            setAccessibilityLabel("Reply \"\(option.label)\" — \(detail)")
            toolTip = "\(detail)\n\nWrites \"\(option.label)\" into the composer"
        } else {
            setAccessibilityLabel("Reply \"\(option.label)\"")
            toolTip = "Write \"\(option.label)\" into the composer"
        }
        identifier = NSUserInterfaceItemIdentifier("agent.composer.replyOption")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.width += CGFloat(pageZoom.scaled(Space.m)) * 2
        size.height = CGFloat(pageZoom.scaled(style == .standard ? 26 : 22))
        return size
    }

    func applyPageZoom(_ zoom: AgentPageZoom) {
        pageZoom = zoom
        font = NSFont.token(.caption, zoom: zoom)
        layer?.applyCorner(.card, zoom: zoom)
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let next = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(next)
        tracking = next
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        applyFill()
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        applyFill()
    }

    func applyTokens(theme: TokenTheme) {
        layer?.applyCorner(.card, zoom: pageZoom)
        self.theme = theme
        contentTintColor = TextToken.textSecondary.color.nsColor(for: theme)
        applyFill()
    }

    private func applyFill() {
        // Option order is the reply's own order, not recommendation semantics:
        // every idle chip is equally emphasized and hover alone lifts the fill.
        if style == .compact {
            attributedTitle = NSAttributedString(string: optionValue, attributes: [
                .font: font ?? NSFont.token(.caption, zoom: pageZoom), .foregroundColor: TextToken.textPrimary.color.nsColor(for: theme)])
        }
        let surface = hovered ? AgentSurfaceRole.rowSelected.color : SurfaceToken.overlay.color
        layer?.backgroundColor = surface.cgColor(for: theme)
    }
}
