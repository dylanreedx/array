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
/// The row is intentionally not wired into production composition yet. It owns
/// only presentation and layout: caller supplies a pure presentation and, if
/// desired, an already-chosen thinking indicator view.
@MainActor
final class AgentCompactStatusRowView: NSView, TokenThemed {
    static let preferredHeight: CGFloat = 28

    private let locationIcon = NSImageView()
    private let locationLabel = NSTextField(labelWithString: "")
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

    init(
        frame frameRect: NSRect = .zero,
        configuration: AgentCompactStatusRowConfiguration = .production,
        thinkingIndicatorFactory: AgentThinkingIndicatorFactory? = nil
    ) {
        self.configuration = configuration
        self.thinkingIndicator = thinkingIndicatorFactory?()
        locationGroup = NSStackView(views: [locationIcon, locationLabel])
        activityGroup = NSStackView(views: [])
        contextGroup = NSStackView(views: [contextMeter, contextLabel])
        rootStack = NSStackView(views: [])
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.cornerRadius = CGFloat(Radius.card)

        configureIcon(locationIcon)
        configureIcon(activityIcon)
        configureLabel(locationLabel, role: .label)
        configureLabel(activityLabel, role: .label)
        configureLabel(elapsedLabel, role: .captionMono)
        configureLabel(contextLabel, role: .captionMono)

        locationLabel.lineBreakMode = .byTruncatingMiddle
        locationLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        locationLabel.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        activityLabel.lineBreakMode = .byClipping
        activityLabel.setContentHuggingPriority(.required, for: .horizontal)
        activityLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        elapsedLabel.lineBreakMode = .byClipping
        elapsedLabel.setContentHuggingPriority(.required, for: .horizontal)
        elapsedLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        contextLabel.lineBreakMode = .byClipping
        contextLabel.setContentHuggingPriority(.required, for: .horizontal)
        contextLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        thinkingSlot.translatesAutoresizingMaskIntoConstraints = false
        thinkingSlot.setContentHuggingPriority(.required, for: .horizontal)
        thinkingSlot.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            thinkingSlot.widthAnchor.constraint(equalToConstant: 20),
            thinkingSlot.heightAnchor.constraint(equalToConstant: 20),
        ])
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
        locationGroup.spacing = CGFloat(Space.xs)
        locationGroup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        locationGroup.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(10), for: .horizontal)

        activityGroup.orientation = .horizontal
        activityGroup.alignment = .centerY
        activityGroup.spacing = CGFloat(Space.xs)
        activityGroup.addArrangedSubview(thinkingSlot)
        activityGroup.addArrangedSubview(activityIcon)
        activityGroup.addArrangedSubview(activityLabel)
        activityGroup.addArrangedSubview(elapsedLabel)
        activityGroup.setContentHuggingPriority(.required, for: .horizontal)
        activityGroup.setContentCompressionResistancePriority(.required, for: .horizontal)

        contextGroup.orientation = .horizontal
        contextGroup.alignment = .centerY
        contextGroup.spacing = CGFloat(Space.xs)
        contextGroup.setContentHuggingPriority(.required, for: .horizontal)
        contextGroup.setContentCompressionResistancePriority(.required, for: .horizontal)

        rootStack.orientation = .horizontal
        rootStack.alignment = .centerY
        rootStack.spacing = CGFloat(Space.m)
        rootStack.edgeInsets = NSEdgeInsets(top: 4, left: CGFloat(Space.s), bottom: 4, right: CGFloat(Space.s))
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
            heightAnchor.constraint(greaterThanOrEqualToConstant: Self.preferredHeight),
        ])

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
        NSSize(width: NSView.noIntrinsicMetric, height: Self.preferredHeight)
    }

    override var isHidden: Bool {
        didSet { updateThinkingLifecycle() }
    }

    func applyConfiguration(_ next: AgentCompactStatusRowConfiguration) {
        configuration = next
        thinkingIndicator?.setReducedMotion(next.reducedMotion)
        updateThinkingLifecycle()
    }

    func apply(_ next: AgentCompactStatusPresentation) {
        presentation = next
        applySymbol(next.location.symbolName, to: locationIcon, description: next.location.accessibilityLabel)
        locationLabel.stringValue = next.location.text
        locationLabel.toolTip = next.location.detailText
        locationLabel.setAccessibilityLabel(next.location.accessibilityLabel)
        applySymbol(next.activity.symbolName, to: activityIcon, description: next.activity.accessibilityLabel)
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
        toolTip = [next.location.detailText, next.activity.detailText, next.context.detailText]
            .joined(separator: "\n\n")
        setAccessibilityLabel("Agent compact status. \(next.location.accessibilityLabel) \(next.activity.accessibilityLabel) \(next.context.accessibilityLabel)")
        setAccessibilityHelp(toolTip)
        // Parent owns the combined compact-row announcement. Exposing labelled
        // children as well duplicates Home/Where/What/activity/context facts.
        setAccessibilityChildren([])
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
        if superview == nil { stopThinkingIndicatorIfNeeded() }
        updateThinkingLifecycle()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    private func configureLabel(_ label: NSTextField, role: TextRole) {
        label.font = .token(role)
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
    }

    private func configureIcon(_ icon: NSImageView) {
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyDown
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.setContentCompressionResistancePriority(.required, for: .horizontal)
        icon.setAccessibilityElement(false)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 14),
            icon.heightAnchor.constraint(equalToConstant: 14),
        ])
    }

    private func applySymbol(_ symbolName: String, to icon: NSImageView, description: String) {
        icon.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: description)
            ?? NSImage(systemSymbolName: "circle", accessibilityDescription: description)
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
        guard window != nil else { return false }
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
    var qaContentFitsBounds: Bool {
        [locationGroup, activityGroup, contextGroup]
            .compactMap(frame(of:))
            .allSatisfy { bounds.insetBy(dx: -0.5, dy: -0.5).contains($0) }
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
              let activityIcon = qaActivityIconFrame,
              let activityLabel = qaActivityLabelFrame,
              let contextMeter = qaContextMeterFrame,
              let contextLabel = qaContextLabelFrame else { return false }
        return locationIcon.width >= minimumIconWidth
            && activityIcon.width >= minimumIconWidth
            && activityLabel.width >= minimumTextWidth
            && contextMeter.width >= 18
            && contextLabel.width >= minimumTextWidth
    }
}
