import AppKit
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

    private(set) var pageZoom: AgentPageZoom = .default

    /// This rail's reserved height at its own zoom.
    var railHeight: CGFloat { Self.railHeight(zoom: pageZoom) }

    private let scrollView = NSScrollView(frame: .zero)
    private let stack = NSStackView(frame: .zero)
    private var options: [String] = []

    var onSelect: ((String) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureViews()
        applyTokens()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: options.isEmpty ? 0 : railHeight)
    }

    func setOptions(_ newOptions: [String]) {
        guard newOptions != options else { return }
        options = newOptions
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let theme = effectiveTokenTheme
        for option in newOptions {
            // A chip minted after a zoom apply is born scaled: the rail's own
            // rung is handed to the initializer.
            let chip = ComposerReplyOptionChipButton(title: option, zoom: pageZoom)
            chip.target = self
            chip.action = #selector(chipPressed(_:))
            chip.applyTokens(theme: theme)
            stack.addArrangedSubview(chip)
        }
        isHidden = newOptions.isEmpty
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
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentView.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
        ])
    }

    @objc private func chipPressed(_ sender: NSButton) {
        guard let chip = sender as? ComposerReplyOptionChipButton,
              options.contains(chip.optionValue) else { return }
        onSelect?(chip.optionValue)
    }

    // MARK: - QA seams

    var qaOptions: [String] { options }
    var qaChipTitles: [String] {
        stack.arrangedSubviews.compactMap { ($0 as? ComposerReplyOptionChipButton)?.title }
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

    init(title: String, zoom: AgentPageZoom = .default) {
        optionValue = title
        pageZoom = zoom
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        bezelStyle = .inline
        focusRingType = .exterior
        font = NSFont.token(.caption, zoom: zoom)
        wantsLayer = true
        layer?.cornerRadius = CGFloat(zoom.scaled(Radius.card))
        // Keep the AppKit exterior keyboard focus ring outside the rounded fill.
        layer?.masksToBounds = false
        setButtonType(.momentaryChange)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Reply \"\(title)\"")
        toolTip = "Write \"\(title)\" into the composer"
        identifier = NSUserInterfaceItemIdentifier("agent.composer.replyOption")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.width += CGFloat(pageZoom.scaled(Space.m)) * 2
        size.height = CGFloat(pageZoom.scaled(26))
        return size
    }

    func applyPageZoom(_ zoom: AgentPageZoom) {
        pageZoom = zoom
        font = NSFont.token(.caption, zoom: zoom)
        layer?.cornerRadius = CGFloat(zoom.scaled(Radius.card))
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
        self.theme = theme
        contentTintColor = TextToken.textSecondary.color.nsColor(for: theme)
        applyFill()
    }

    private func applyFill() {
        // Option order is the reply's own order, not recommendation semantics:
        // every idle chip is equally emphasized and hover alone lifts the fill.
        let surface = hovered ? AgentSurfaceRole.rowSelected.color : SurfaceToken.overlay.color
        layer?.backgroundColor = surface.cgColor(for: theme)
    }
}
