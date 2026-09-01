import AppKit
import ContinuumRevivedAgentUI

typealias AgentThinkingIndicatorFactory = () -> (NSView & AgentThinkingIndicatorAnimating)?

struct AgentCompactStatusRowConfiguration: Equatable {
    var reducedMotion: Bool
    /// Explicit QA-only snapshot phase. nil in production so the injected
    /// indicator is driven by lifecycle instead of being pinned for snapshots.
    var deterministicSnapshotPhase: CGFloat?

    static let production = AgentCompactStatusRowConfiguration(reducedMotion: false, deterministicSnapshotPhase: nil)
}

/// Reusable compact bottom row for managed-agent status chrome.
///
/// The row owns the single live Home/Where/What status surface for the managed
/// tile. Caller supplies a pure presentation and, if desired, an already-chosen
/// thinking indicator view; the host supplies the location action route.
@MainActor
final class AgentCompactStatusRowView: NSView, TokenThemed, AgentPageZoomScalable {
    static let preferredHeight: CGFloat = 28

    /// The same row height at one rung of the tile's page zoom. Exact identity
    /// with `preferredHeight` at 100%.
    static func preferredHeight(zoom: AgentPageZoom) -> CGFloat { CGFloat(zoom.scaled(28)) }

    /// This row's rung of the tile's page zoom, delivered by the tile's subtree
    /// walk. Every derivation below is an exact identity at 100%.
    private(set) var pageZoom: AgentPageZoom = .default

    private let locationIcon = NSImageView()
    private let locationLabel = NSTextField(labelWithString: "")
    private let actionButton: NSButton = {
        let button = NSButton(title: "⋯", target: nil, action: nil)
        button.bezelStyle = .inline
        button.isBordered = false
        button.setButtonType(.momentaryPushIn)
        button.toolTip = "Location actions"
        button.setAccessibilityLabel("Location actions")
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        // NSButton's borderless inline cell can report a zero intrinsic width in
        // offscreen narrow Component Lab layouts. The host adds the conditional
        // width constraint after initialization, when QA configuration is known.
        return button
    }()
    private let activityIcon = NSImageView()
    private let activityLabel = NSTextField(labelWithString: "")
    private let elapsedLabel = NSTextField(labelWithString: "")
    private let contextMeter = AgentRadialContextMeterView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
    private let contextLabel = NSTextField(labelWithString: "")
    private let thinkingIndicator: (NSView & AgentThinkingIndicatorAnimating)?
    private let thinkingSlot = NSView()
    private let locationGroup: NSStackView
    private let activityGroup: NSStackView
    private let contextGroup: NSStackView
    private let rootStack: NSStackView
    private var presentation: AgentCompactStatusPresentation?
    private var configuration: AgentCompactStatusRowConfiguration
    private var thinkingIndicatorIsAnimating = false
    var onActionMenuRequested: ((NSButton) -> Void)?

    // Every constant that follows the page zoom is held rather than baked into an
    // activated anchor a later rung could not reach.
    private var actionButtonWidth: NSLayoutConstraint?
    private var locationLabelMinimumWidth: NSLayoutConstraint?
    private var contextMeterSize: [NSLayoutConstraint] = []
    private var thinkingSlotSize: [NSLayoutConstraint] = []
    private var iconSize: [NSLayoutConstraint] = []
    private var rowHeight: NSLayoutConstraint?

    init(
        frame frameRect: NSRect = .zero,
        configuration: AgentCompactStatusRowConfiguration = .production,
        thinkingIndicatorFactory: AgentThinkingIndicatorFactory? = nil
    ) {
        self.configuration = configuration
        self.thinkingIndicator = thinkingIndicatorFactory?()
        locationGroup = NSStackView(views: [locationIcon, locationLabel, actionButton])
        activityGroup = NSStackView(views: [])
        contextGroup = NSStackView(views: [contextMeter, contextLabel])
        rootStack = NSStackView(views: [])
        super.init(frame: frameRect)

        if configuration.deterministicSnapshotPhase == nil {
            let actionWidth = actionButton.widthAnchor.constraint(
                equalToConstant: CGFloat(pageZoom.scaled(18)))
            actionWidth.priority = .defaultLow
            actionWidth.isActive = true
            actionButtonWidth = actionWidth
        }

        wantsLayer = true
        layer?.cornerRadius = CGFloat(pageZoom.scaled(Radius.card))

        configureIcon(locationIcon)
        configureIcon(activityIcon)
        configureLabel(locationLabel, role: .label)
        configureLabel(activityLabel, role: .label)
        configureLabel(elapsedLabel, role: .captionMono)
        configureLabel(contextLabel, role: .captionMono)

        locationLabel.lineBreakMode = .byTruncatingMiddle
        locationLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        locationLabel.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        // Preserve a drawable sliver for the location label in the production
        // tile (including the 320pt Component Lab card); deterministic geometry
        // probes intentionally let it yield completely before protected groups.
        if configuration.deterministicSnapshotPhase == nil {
            let minimumWidth = locationLabel.widthAnchor.constraint(
                greaterThanOrEqualToConstant: CGFloat(pageZoom.scaled(6)))
            minimumWidth.isActive = true
            locationLabelMinimumWidth = minimumWidth
        }

        // The phase label is the only variable-length text left in the row, so it
        // is the one that must give. With `.byClipping` + `.required` it could do
        // neither, and a narrow row crushed the context reading beside it to a
        // few points — glyph-free. Truncating and yielding below the context
        // label's required resistance puts the loss where it reads correctly.
        activityLabel.lineBreakMode = .byTruncatingTail
        activityLabel.setContentHuggingPriority(.required, for: .horizontal)
        activityLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        elapsedLabel.lineBreakMode = .byClipping
        elapsedLabel.setContentHuggingPriority(.required, for: .horizontal)
        elapsedLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        contextLabel.lineBreakMode = .byClipping
        contextLabel.setContentHuggingPriority(.required, for: .horizontal)
        contextLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        // The meter is a fixed-size glyph, so pin it rather than leaving its
        // width to intrinsic size and priority arbitration. Once the activity
        // group can be hidden, a long location label claims the freed width and
        // squeezed the meter to 0pt in a narrow tile.
        contextMeter.translatesAutoresizingMaskIntoConstraints = false
        contextMeter.setContentHuggingPriority(.required, for: .horizontal)
        contextMeter.setContentCompressionResistancePriority(.required, for: .horizontal)
        contextMeterSize = [
            contextMeter.widthAnchor.constraint(
                equalToConstant: AgentRadialContextMeterView.side(zoom: pageZoom)),
            contextMeter.heightAnchor.constraint(
                equalToConstant: AgentRadialContextMeterView.side(zoom: pageZoom)),
        ]
        NSLayoutConstraint.activate(contextMeterSize)

        thinkingSlot.translatesAutoresizingMaskIntoConstraints = false
        thinkingSlot.setContentHuggingPriority(.required, for: .horizontal)
        thinkingSlot.setContentCompressionResistancePriority(.required, for: .horizontal)
        thinkingSlotSize = [
            thinkingSlot.widthAnchor.constraint(equalToConstant: CGFloat(pageZoom.scaled(20))),
            thinkingSlot.heightAnchor.constraint(equalToConstant: CGFloat(pageZoom.scaled(20))),
        ]
        NSLayoutConstraint.activate(thinkingSlotSize)
        if let thinkingIndicator {
            thinkingIndicator.translatesAutoresizingMaskIntoConstraints = false
            thinkingIndicator.setReducedMotion(configuration.reducedMotion)
            if let phase = configuration.deterministicSnapshotPhase {
                thinkingIndicator.setSnapshotPhase(phase)
            }
            thinkingSlot.addSubview(thinkingIndicator)
            NSLayoutConstraint.activate([
                thinkingIndicator.centerXAnchor.constraint(equalTo: thinkingSlot.centerXAnchor),
                thinkingIndicator.centerYAnchor.constraint(equalTo: thinkingSlot.centerYAnchor),
                thinkingIndicator.widthAnchor.constraint(lessThanOrEqualTo: thinkingSlot.widthAnchor),
                thinkingIndicator.heightAnchor.constraint(lessThanOrEqualTo: thinkingSlot.heightAnchor),
            ])
        }

        locationGroup.orientation = .horizontal
        locationGroup.alignment = .centerY
        locationGroup.spacing = CGFloat(pageZoom.scaled(Space.xs))
        locationGroup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        locationGroup.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(10), for: .horizontal)
        actionButton.target = self
        actionButton.action = #selector(showActions(_:))

        activityGroup.orientation = .horizontal
        activityGroup.alignment = .centerY
        activityGroup.spacing = CGFloat(pageZoom.scaled(Space.xs))
        activityGroup.addArrangedSubview(thinkingSlot)
        activityGroup.addArrangedSubview(activityIcon)
        activityGroup.addArrangedSubview(activityLabel)
        activityGroup.addArrangedSubview(elapsedLabel)
        activityGroup.setContentHuggingPriority(.required, for: .horizontal)
        activityGroup.setContentCompressionResistancePriority(.required, for: .horizontal)

        contextGroup.orientation = .horizontal
        contextGroup.alignment = .centerY
        contextGroup.spacing = CGFloat(pageZoom.scaled(Space.xs))
        contextGroup.setContentHuggingPriority(.required, for: .horizontal)
        contextGroup.setContentCompressionResistancePriority(.required, for: .horizontal)

        rootStack.orientation = .horizontal
        rootStack.alignment = .centerY
        rootStack.spacing = CGFloat(pageZoom.scaled(Space.m))
        rootStack.edgeInsets = Self.rootInsets(zoom: pageZoom)
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        rootStack.addArrangedSubview(locationGroup)
        rootStack.addArrangedSubview(activityGroup)
        rootStack.addArrangedSubview(contextGroup)
        addSubview(rootStack)

        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            rootStack.topAnchor.constraint(equalTo: topAnchor),
            rootStack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        let rowHeight = heightAnchor.constraint(
            greaterThanOrEqualToConstant: Self.preferredHeight(zoom: pageZoom))
        rowHeight.isActive = true
        self.rowHeight = rowHeight

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        apply(AgentCompactStatusPresentation(
            location: .init(symbolName: "house", text: "—", accessibilityLabel: "Home and Where: unknown.", detailText: "Location unavailable", isExternal: false),
            activity: .init(phase: .ready, symbolName: "checkmark.circle", text: "Ready", elapsedText: nil, accessibilityLabel: "Activity: ready.", detailText: "Activity phase: ready.", showsThinkingIndicator: false),
            context: AgentRadialContextMeterPresenter.present(nil)))
        applyTokens()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Self.preferredHeight(zoom: pageZoom))
    }

    /// The row's own padding. Held apart so `applyPageZoom` re-derives exactly
    /// what the initializer assigned.
    private static func rootInsets(zoom: AgentPageZoom) -> NSEdgeInsets {
        NSEdgeInsets(
            top: CGFloat(zoom.scaled(4)),
            left: CGFloat(zoom.scaled(Space.s)),
            bottom: CGFloat(zoom.scaled(4)),
            right: CGFloat(zoom.scaled(Space.s)))
    }

    override var isHidden: Bool {
        didSet { updateThinkingLifecycle() }
    }

    func applyConfiguration(_ next: AgentCompactStatusRowConfiguration) {
        let changesSnapshotMode = configuration.deterministicSnapshotPhase != next.deterministicSnapshotPhase
        if changesSnapshotMode {
            // Candidate `setSnapshotPhase` implementations stop their animations.
            // Reset our mirrored state as well so leaving QA snapshot mode starts
            // live motion again instead of believing the stopped layers are active.
            stopThinkingIndicatorIfNeeded()
            thinkingIndicatorIsAnimating = false
        }
        configuration = next
        thinkingIndicator?.setReducedMotion(next.reducedMotion)
        updateThinkingLifecycle()
    }

    func apply(_ next: AgentCompactStatusPresentation) {
        presentation = next
        applySymbol(next.location.symbolName, to: locationIcon)
        locationLabel.stringValue = next.location.text
        locationLabel.toolTip = next.location.detailText
        locationLabel.setAccessibilityLabel(next.location.accessibilityLabel)
        // Toggling an arranged subview's visibility changes what the stack has to
        // distribute, but AppKit does not re-lay the row out on its own. Without
        // this the frames computed for the previous configuration survive — in a
        // narrow tile the context label stayed 4pt wide and rendered no glyphs.
        if activityGroup.isHidden != next.activity.isSilent {
            activityGroup.isHidden = next.activity.isSilent
            invalidateIntrinsicContentSize()
            rootStack.needsLayout = true
            needsLayout = true
            needsDisplay = true
        }
        applySymbol(next.activity.symbolName, to: activityIcon)
        activityLabel.stringValue = next.activity.text
        activityLabel.toolTip = next.activity.detailText
        activityLabel.setAccessibilityLabel(next.activity.accessibilityLabel)
        if let elapsed = next.activity.elapsedText {
            elapsedLabel.stringValue = elapsed
            elapsedLabel.isHidden = false
        } else {
            elapsedLabel.stringValue = ""
            elapsedLabel.isHidden = true
        }
        thinkingSlot.isHidden = !next.activity.showsThinkingIndicator || thinkingIndicator == nil
        contextMeter.apply(next.context)
        contextLabel.stringValue = next.context.label
        contextLabel.toolTip = next.context.detailText
        contextLabel.setAccessibilityLabel(next.context.accessibilityLabel)
        actionButton.toolTip = next.location.detailText + "\nLocation actions"
        toolTip = [next.location.detailText, next.activity.detailText, next.context.detailText]
            .joined(separator: "\n\n")
        // A silent activity contributes nothing to speech either — VoiceOver must
        // not announce a phase the row is deliberately not showing.
        let spokenActivity = next.activity.isSilent ? "" : " \(next.activity.accessibilityLabel)"
        setAccessibilityLabel("Agent compact status. \(next.location.accessibilityLabel)\(spokenActivity) \(next.context.accessibilityLabel)")
        setAccessibilityHelp(toolTip)
        // Parent owns the combined Home/Where/What/activity/context announcement;
        // only the single location-action control is separately reachable.
        setAccessibilityChildren([actionButton])
        updateThinkingLifecycle()
        applyTokens()
    }

    func applyTokens() {
        let theme = effectiveTokenTheme
        layer?.backgroundColor = SurfaceToken.tileChrome.color.cgColor(for: theme)
        let locationColor = presentation?.location.isExternal == true
            ? AccentToken.accentApproval.color.nsColor(for: theme)
            : TextToken.textSecondary.color.nsColor(for: theme)
        locationIcon.contentTintColor = locationColor
        locationLabel.textColor = TextToken.textSecondary.color.nsColor(for: theme)
        let activityColor = activityLabelColor(for: presentation?.activity.phase ?? .ready, theme: theme)
        activityIcon.contentTintColor = activityColor
        activityLabel.textColor = activityColor
        elapsedLabel.textColor = TextToken.textSecondary.color.nsColor(for: theme)
        contextLabel.textColor = contextLabelColor(for: presentation?.context.state ?? .unknown, theme: theme)
        contextMeter.applyTokens()
    }

    /// Re-derives every metric this row owns from `zoom`. Same contract as
    /// `applyTokens()`: idempotent, and safe on a row already showing a
    /// presentation — it touches no string, no visibility and no indicator
    /// lifecycle. The context meter is `AgentPageZoomScalable` itself and is
    /// reached by the tile's subtree walk, so this only re-pins the box it sits in.
    func applyPageZoom(_ zoom: AgentPageZoom) {
        pageZoom = zoom
        layer?.cornerRadius = CGFloat(pageZoom.scaled(Radius.card))
        locationLabel.font = .token(.label, zoom: pageZoom)
        activityLabel.font = .token(.label, zoom: pageZoom)
        elapsedLabel.font = .token(.captionMono, zoom: pageZoom)
        contextLabel.font = .token(.captionMono, zoom: pageZoom)
        locationGroup.spacing = CGFloat(pageZoom.scaled(Space.xs))
        activityGroup.spacing = CGFloat(pageZoom.scaled(Space.xs))
        contextGroup.spacing = CGFloat(pageZoom.scaled(Space.xs))
        rootStack.spacing = CGFloat(pageZoom.scaled(Space.m))
        rootStack.edgeInsets = Self.rootInsets(zoom: pageZoom)
        actionButtonWidth?.constant = CGFloat(pageZoom.scaled(18))
        locationLabelMinimumWidth?.constant = CGFloat(pageZoom.scaled(6))
        for constraint in contextMeterSize {
            constraint.constant = AgentRadialContextMeterView.side(zoom: pageZoom)
        }
        for constraint in thinkingSlotSize {
            constraint.constant = CGFloat(pageZoom.scaled(20))
        }
        for constraint in iconSize {
            constraint.constant = CGFloat(pageZoom.scaled(14))
        }
        rowHeight?.constant = Self.preferredHeight(zoom: pageZoom)
        // The glyphs are rasterized at a point size, so they have to be re-made
        // rather than merely re-pinned.
        if let presentation {
            applySymbol(presentation.location.symbolName, to: locationIcon)
            applySymbol(presentation.activity.symbolName, to: activityIcon)
        }
        invalidateIntrinsicContentSize()
        rootStack.needsLayout = true
        needsLayout = true
    }

    @objc private func showActions(_ sender: NSButton) {
        onActionMenuRequested?(sender)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let onActionMenuRequested else { return super.menu(for: event) }
        onActionMenuRequested(actionButton)
        return nil
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { stopThinkingIndicatorIfNeeded() }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateThinkingLifecycle()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        guard superview != nil else {
            stopThinkingIndicatorIfNeeded()
            return
        }
        updateThinkingLifecycle()
    }

    override func viewDidHide() {
        super.viewDidHide()
        stopThinkingIndicatorIfNeeded()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        updateThinkingLifecycle()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    private func configureLabel(_ label: NSTextField, role: TextRole) {
        label.font = .token(role, zoom: pageZoom)
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
    }

    private func configureIcon(_ icon: NSImageView) {
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyDown
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.setContentCompressionResistancePriority(.required, for: .horizontal)
        icon.setAccessibilityElement(false)
        let size = [
            icon.widthAnchor.constraint(equalToConstant: CGFloat(pageZoom.scaled(14))),
            icon.heightAnchor.constraint(equalToConstant: CGFloat(pageZoom.scaled(14))),
        ]
        iconSize.append(contentsOf: size)
        NSLayoutConstraint.activate(size)
    }

    private func applySymbol(_ symbolName: String, to icon: NSImageView) {
        let pointSize = CGFloat(pageZoom.scaled(11))
        icon.image = CanvasSymbolImage.image(named: symbolName, pointSize: pointSize, weight: .semibold)
            ?? CanvasSymbolImage.image(named: "circle", pointSize: pointSize, weight: .semibold)
    }

    private func updateThinkingLifecycle() {
        guard let thinkingIndicator else { return }
        thinkingIndicator.setReducedMotion(configuration.reducedMotion)
        if let phase = configuration.deterministicSnapshotPhase {
            if presentation?.activity.showsThinkingIndicator == true, isVisibleInWindowTree {
                thinkingIndicator.setSnapshotPhase(phase)
            } else {
                stopThinkingIndicatorIfNeeded()
            }
            return
        }
        if presentation?.activity.showsThinkingIndicator == true, isVisibleInWindowTree {
            if !thinkingIndicatorIsAnimating {
                thinkingIndicator.startAnimating()
                thinkingIndicatorIsAnimating = true
            }
        } else {
            stopThinkingIndicatorIfNeeded()
        }
    }

    private func stopThinkingIndicatorIfNeeded() {
        guard thinkingIndicatorIsAnimating else { return }
        thinkingIndicator?.stopAnimating()
        thinkingIndicatorIsAnimating = false
    }

    private var isVisibleInWindowTree: Bool {
        guard window != nil, superview != nil else { return false }
        var view: NSView? = self
        while let current = view {
            if current.isHidden { return false }
            view = current.superview
        }
        return true
    }

    private func activityLabelColor(for phase: AgentCompactActivityPhase, theme: TokenTheme) -> NSColor {
        switch phase {
        case .starting, .thinking, .responding, .reading, .searching, .editing, .running:
            return AccentToken.accentWorking.color.nsColor(for: theme)
        case .waiting:
            return AccentToken.accentApproval.color.nsColor(for: theme)
        case .ready:
            return TextToken.textPrimary.color.nsColor(for: theme)
        case .failed:
            return AccentToken.accentFailed.color.nsColor(for: theme)
        case .interrupted:
            return TextToken.textSecondary.color.nsColor(for: theme)
        }
    }

    private func contextLabelColor(for state: AgentRadialContextMeterState, theme: TokenTheme) -> NSColor {
        switch state {
        case .known:
            return TextToken.textPrimary.color.nsColor(for: theme)
        case .warning:
            return AccentToken.accentApproval.color.nsColor(for: theme)
        case .critical:
            return AccentToken.accentFailed.color.nsColor(for: theme)
        case .unknown, .stale:
            return TextToken.textSecondary.color.nsColor(for: theme)
        }
    }

    private func frame(of view: NSView) -> NSRect? {
        view.superview.map { $0.convert(view.frame, to: self) }
    }

    var qaLocationText: String { locationLabel.stringValue }
    var qaLocationSymbolName: String { presentation?.location.symbolName ?? "" }
    var qaActivityText: String { activityLabel.stringValue }
    var qaActivityPhase: AgentCompactActivityPhase { presentation?.activity.phase ?? .ready }
    var qaActivitySymbolName: String { presentation?.activity.symbolName ?? "" }
    var qaElapsedText: String? { elapsedLabel.isHidden ? nil : elapsedLabel.stringValue }
    var qaContextText: String { contextLabel.stringValue }
    var qaContextState: AgentRadialContextMeterState { contextMeter.qaState }
    var qaContextFraction: Double? { contextMeter.qaFraction }
    var qaContextDetail: String { contextMeter.qaDetail }
    var qaThinkingSlotVisible: Bool { !thinkingSlot.isHidden }
    var qaHasVisiblePrefixes: Bool {
        [locationLabel.stringValue, activityLabel.stringValue, contextLabel.stringValue].contains { text in
            text.hasPrefix("Home") || text.hasPrefix("Where") || text.hasPrefix("What")
        }
    }
    var qaLocationCompressionPriority: Float { locationLabel.contentCompressionResistancePriority(for: .horizontal).rawValue }
    var qaActivityCompressionPriority: Float { activityGroup.contentCompressionResistancePriority(for: .horizontal).rawValue }
    var qaContextCompressionPriority: Float { contextGroup.contentCompressionResistancePriority(for: .horizontal).rawValue }
    var qaActivityFrame: NSRect? { frame(of: activityGroup) }
    var qaContextFrame: NSRect? { frame(of: contextGroup) }
    var qaLocationFrame: NSRect? { frame(of: locationGroup) }
    var qaLocationLabelFrame: NSRect? { frame(of: locationLabel) }
    var qaActivityLabelFrame: NSRect? { frame(of: activityLabel) }
    var qaContextLabelFrame: NSRect? { frame(of: contextLabel) }
    var qaLocationIconFrame: NSRect? { frame(of: locationIcon) }
    var qaActivityIconFrame: NSRect? { frame(of: activityIcon) }
    var qaContextMeterFrame: NSRect? { frame(of: contextMeter) }
    var qaLocationIconHasImage: Bool { locationIcon.image != nil }
    var qaActivityIconHasImage: Bool { activityIcon.image != nil }
    var qaContextMeterSide: CGFloat { contextMeter.qaIntrinsicSide }
    var qaAccessibilityLabel: String { accessibilityLabel() ?? "" }
    var qaAccessibilityChildrenCount: Int { accessibilityChildren()?.count ?? 0 }
    var qaLocationActionButtonAccessibilityLabel: String { actionButton.accessibilityLabel() ?? "" }
    var qaLocationActionButtonEnabled: Bool { actionButton.isEnabled }
    var qaContentFitsBounds: Bool {
        [locationGroup, activityGroup, contextGroup]
            .compactMap(frame(of:))
            .allSatisfy { bounds.insetBy(dx: -0.5, dy: -0.5).contains($0) }
    }
    /// True when the row is deliberately saying nothing about activity (idle or
    /// no authoritative fact). Distinct from "an activity exists but is clipped".
    var qaActivityIsSilent: Bool {
        (presentation?.activity.isSilent ?? false) && activityGroup.isHidden
    }
    /// Silence must cost the activity chunk and nothing else — the context meter
    /// is ambient and stays put.
    var qaContextVisibleWhileActivitySilent: Bool {
        guard let context = qaContextFrame else { return false }
        return context.width > 0 && bounds.contains(context) && !contextLabel.stringValue.isEmpty
    }
    var qaActivityAndContextVisible: Bool {
        guard let activity = qaActivityFrame, let context = qaContextFrame else { return false }
        return activity.width > 0 && context.width > 0 && bounds.contains(activity) && bounds.contains(context)
            && !activityLabel.stringValue.isEmpty && !contextLabel.stringValue.isEmpty
    }
    var qaProtectedDrawableWidths: Bool {
        let minimumTextWidth: CGFloat = 6
        let minimumIconWidth: CGFloat = 8
        guard let locationIcon = qaLocationIconFrame,
              let contextMeter = qaContextMeterFrame,
              let contextLabel = qaContextLabelFrame else { return false }
        let locationAndContext = locationIcon.width >= minimumIconWidth
            && contextMeter.width >= 18
            && contextLabel.width >= minimumTextWidth
        // A silent row has no activity glyph or label to protect; the rule holds
        // for everything it is still drawing.
        if qaActivityIsSilent { return locationAndContext }
        guard let activityIcon = qaActivityIconFrame,
              let activityLabel = qaActivityLabelFrame else { return false }
        return locationAndContext
            && activityIcon.width >= minimumIconWidth
            && activityLabel.width >= minimumTextWidth
    }
}
