import AppKit
import ContinuumRevivedAgentUI

typealias AgentThinkingIndicatorFactory = () -> (NSView & AgentThinkingIndicatorAnimating)?

/// Reusable compact bottom row for managed-agent status chrome.
///
/// The row is intentionally not wired into production composition yet. It owns
/// only presentation and layout: caller supplies a pure presentation and, if
/// desired, an already-chosen thinking indicator view.
@MainActor
final class AgentCompactStatusRowView: NSView, TokenThemed {
    static let preferredHeight: CGFloat = 28

    private let locationIcon = NSTextField(labelWithString: "")
    private let locationLabel = NSTextField(labelWithString: "")
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

    init(
        frame frameRect: NSRect = .zero,
        thinkingIndicatorFactory: AgentThinkingIndicatorFactory? = nil
    ) {
        self.thinkingIndicator = thinkingIndicatorFactory?()
        locationGroup = NSStackView(views: [locationIcon, locationLabel])
        activityGroup = NSStackView(views: [])
        contextGroup = NSStackView(views: [contextMeter, contextLabel])
        rootStack = NSStackView(views: [])
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.cornerRadius = CGFloat(Radius.card)

        configureLabel(locationIcon, role: .label)
        configureLabel(locationLabel, role: .label)
        configureLabel(activityLabel, role: .label)
        configureLabel(elapsedLabel, role: .captionMono)
        configureLabel(contextLabel, role: .captionMono)

        locationIcon.alignment = .center
        locationIcon.setContentHuggingPriority(.required, for: .horizontal)
        locationIcon.setContentCompressionResistancePriority(.required, for: .horizontal)
        locationIcon.setAccessibilityElement(false)

        locationLabel.lineBreakMode = .byTruncatingMiddle
        locationLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        locationLabel.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(10), for: .horizontal)

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
            thinkingSlot.addSubview(thinkingIndicator)
            NSLayoutConstraint.activate([
                thinkingIndicator.centerXAnchor.constraint(equalTo: thinkingSlot.centerXAnchor),
                thinkingIndicator.centerYAnchor.constraint(equalTo: thinkingSlot.centerYAnchor),
                thinkingIndicator.widthAnchor.constraint(lessThanOrEqualTo: thinkingSlot.widthAnchor),
                thinkingIndicator.heightAnchor.constraint(lessThanOrEqualTo: thinkingSlot.heightAnchor),
            ])
            thinkingIndicator.setSnapshotPhase(0.35)
        }

        locationGroup.orientation = .horizontal
        locationGroup.alignment = .centerY
        locationGroup.spacing = CGFloat(Space.xs)
        locationGroup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        locationGroup.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(20), for: .horizontal)

        activityGroup.orientation = .horizontal
        activityGroup.alignment = .centerY
        activityGroup.spacing = CGFloat(Space.xs)
        activityGroup.addArrangedSubview(thinkingSlot)
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
            location: .init(icon: "⌂", text: ".", accessibilityLabel: "Location: project root.", detailText: "Location unavailable", isExternal: false),
            activity: .init(status: .idle, text: "Idle", elapsedText: nil, accessibilityLabel: "Activity: idle.", detailText: "Lifecycle: idle", showsThinkingIndicator: false),
            context: AgentRadialContextMeterPresenter.present(nil)))
        applyTokens()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Self.preferredHeight)
    }

    func apply(_ next: AgentCompactStatusPresentation) {
        presentation = next
        locationIcon.stringValue = next.location.icon
        locationLabel.stringValue = next.location.text
        locationLabel.toolTip = next.location.detailText
        locationLabel.setAccessibilityLabel(next.location.accessibilityLabel)
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
        setAccessibilityChildren([locationLabel, activityLabel, elapsedLabel, contextMeter, contextLabel].filter { !$0.isHidden })
        applyTokens()
    }

    func applyTokens() {
        let theme = effectiveTokenTheme
        layer?.backgroundColor = SurfaceToken.tileChrome.color.cgColor(for: theme)
        locationIcon.textColor = presentation?.location.isExternal == true
            ? AccentToken.accentApproval.color.nsColor(for: theme)
            : TextToken.textSecondary.color.nsColor(for: theme)
        locationLabel.textColor = TextToken.textSecondary.color.nsColor(for: theme)
        let display = presentation.map { StatusChipPresenter.display(for: $0.activity.status) }
        activityLabel.textColor = display?.accent.nsColor(for: theme) ?? TextToken.textPrimary.color.nsColor(for: theme)
        elapsedLabel.textColor = TextToken.textSecondary.color.nsColor(for: theme)
        contextLabel.textColor = contextLabelColor(for: presentation?.context.state ?? .unknown, theme: theme)
        contextMeter.applyTokens()
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
    var qaActivityText: String { activityLabel.stringValue }
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
    var qaContextMeterSide: CGFloat { contextMeter.qaIntrinsicSide }
    var qaAccessibilityLabel: String { accessibilityLabel() ?? "" }
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
}
