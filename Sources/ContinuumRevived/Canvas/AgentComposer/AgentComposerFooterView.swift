import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

/// Compact next-turn settings for the custom composer. The footer owns presentation
/// and emits a partial write; the tile/supervisor remains the owner of agent state.
/// Keeping the write partial is load-bearing for records created by an older build:
/// changing effort must not resubmit (and therefore reject) an off-catalog model.
private final class FooterAlphaSamples: @unchecked Sendable {
    var values: [CGFloat] = []
}

@MainActor
final class AgentComposerFooterView: NSView, TokenThemed {
    typealias SettingsWriter = (_ model: String?, _ thinking: String?) -> Bool

    let modelButton = ChoiceButton(title: "Model")
    let effortButton = ChoiceButton(title: "Effort")
    private let contextLabel = NSTextField(labelWithString: "Next turn")
    private var settings = AgentModelConfig.resolvedFromDefaults()
    private var usesCompactLabels = false
    private var contrastObservations: [NSKeyValueObservation] = []

    var onSettingsWrite: SettingsWriter?

    static let height = ChoiceButton.controlHeight
    static let compactWidth: CGFloat = 390

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        contextLabel.font = .token(.caption)
        contextLabel.setContentHuggingPriority(.required, for: .horizontal)
        contextLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        for button in [modelButton, effortButton] {
            button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }
        modelButton.setAccessibilityLabel("Model, next turn")
        modelButton.setAccessibilityHelp("Choose the model for this agent's next turn")
        effortButton.setAccessibilityLabel("Reasoning effort, next turn")
        effortButton.setAccessibilityHelp("Choose the reasoning effort for this agent's next turn")
        modelButton.toolTip = "Model for the next turn"
        effortButton.toolTip = "Reasoning effort for the next turn"

        modelButton.onSelection = { [weak self] item in self?.pick(model: item.id) }
        effortButton.onSelection = { [weak self] item in self?.pick(thinking: item.id) }

        let stack = NSStackView(views: [contextLabel, modelButton, effortButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = CGFloat(Space.m)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            modelButton.heightAnchor.constraint(equalToConstant: ChoiceButton.controlHeight),
            effortButton.heightAnchor.constraint(equalToConstant: ChoiceButton.controlHeight),
            modelButton.widthAnchor.constraint(greaterThanOrEqualTo: effortButton.widthAnchor, multiplier: 1.45),
        ])

        installContrastObservers()
        apply(settings)
        applyTokens()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Self.height)
    }

    override func layout() {
        super.layout()
        let compact = bounds.width > 0 && bounds.width < Self.compactWidth
        if compact != usesCompactLabels {
            usesCompactLabels = compact
            rebuildChoices()
        }
    }

    var controlsEnabled: Bool {
        get { modelButton.isEnabled && effortButton.isEnabled }
        set {
            modelButton.isEnabled = newValue
            effortButton.isEnabled = newValue
            applyTokens()
        }
    }

    /// Shows the record's exact values. An old off-catalog value stays visible;
    /// silently replacing it would misdescribe what the next turn will run.
    func apply(_ settings: AgentModelConfig.Resolution) {
        self.settings = settings
        rebuildChoices()
    }

    func applyTokens() {
        let theme = effectiveTokenTheme
        contextLabel.textColor = TextToken.textSecondary.color.nsColor(for: theme)
        modelButton.applyTokens()
        effortButton.applyTokens()
        preserveDisabledContrast()
    }

    /// `ChoiceButton` normally fades a disabled control. In this footer the
    /// background is already very light under Aqua, so compositing the semantic
    /// line/text tokens at 58% drops them below their asserted floors. Keep the
    /// real token colors opaque; secondary text plus NSControl/accessibility state
    /// still communicates unavailability without inventing a new color role.
    private func installContrastObservers() {
        for button in [modelButton, effortButton] {
            contrastObservations.append(button.observe(\.alphaValue, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.preserveDisabledContrast() }
            })
        }
    }

    private func preserveDisabledContrast() {
        for button in [modelButton, effortButton]
        where !button.isEnabled && button.alphaValue != 1 {
            button.alphaValue = 1
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    private func rebuildChoices() {
        var models = AgentModelConfig.modelOptions
        if !models.contains(settings.model) { models.append(settings.model) }
        modelButton.items = models.map {
            ChoiceItem(id: $0, title: usesCompactLabels ? Self.abbreviatedModel($0) : $0)
        }
        var efforts = AgentModelConfig.thinkingOptions
        if !efforts.contains(settings.thinking) { efforts.append(settings.thinking) }
        effortButton.items = efforts.map {
            ChoiceItem(id: $0, title: usesCompactLabels ? Self.abbreviatedEffort($0) : $0.capitalized)
        }
        modelButton.selectedID = settings.model
        effortButton.selectedID = settings.thinking
    }

    private func pick(model: String? = nil, thinking: String? = nil) {
        let modelChanged = model.map { $0 != settings.model } ?? false
        let thinkingChanged = thinking.map { $0 != settings.thinking } ?? false
        guard modelChanged || thinkingChanged else { return }
        let previous = settings
        let next = AgentModelConfig.Resolution(
            model: model ?? settings.model,
            thinking: thinking ?? settings.thinking
        )

        // Required negative witness: recreates the old whole-pair write. With an
        // off-catalog model, an effort-only change is then refused by the supervisor.
        let wholePairWitness = ProcessInfo.processInfo.environment["CONTINUUM_P4_8_NEGATIVE_WITNESS"] == "1"
        let accepted = onSettingsWrite?(
            wholePairWitness ? next.model : model,
            wholePairWitness ? next.thinking : thinking
        ) ?? true
        guard accepted else {
            apply(previous)
            return
        }
        apply(next)
    }

    static func abbreviatedModel(_ model: String) -> String {
        model.split(separator: "/").last.map(String.init) ?? model
    }

    static func abbreviatedEffort(_ effort: String) -> String {
        switch effort {
        case "minimal": return "Min"
        case "medium": return "Med"
        case "xhigh": return "X-high"
        default: return effort.capitalized
        }
    }

    // Deterministic probes read the real label/control hierarchy and use the same
    // selection path after the popover chooses.
    var qaSettings: AgentModelConfig.Resolution { settings }
    var qaContextText: String { contextLabel.stringValue }
    var qaContextIsActionable: Bool {
        contextLabel.isEditable || contextLabel.isSelectable
            || contextLabel.action != nil || contextLabel.target != nil
    }
    var qaModelTitles: [String] { modelButton.items.map(\.title) }
    var qaEffortTitles: [String] { effortButton.items.map(\.title) }
    @discardableResult func qaPickModel(_ value: String) -> Bool {
        guard modelButton.items.contains(where: { $0.id == value && $0.enabled }), controlsEnabled else { return false }
        let before = settings
        pick(model: value)
        return settings != before
    }
    @discardableResult func qaPickThinking(_ value: String) -> Bool {
        guard effortButton.items.contains(where: { $0.id == value && $0.enabled }), controlsEnabled else { return false }
        let before = settings
        pick(thinking: value)
        return settings != before
    }

    /// Exercises the real mouse-down path and records its transient alpha changes.
    /// This makes the pressed paint state deterministic without adding a test-only
    /// state setter that could diverge from actual pointer behavior.
    func qaPressModel(with event: NSEvent) -> [CGFloat] {
        let samples = FooterAlphaSamples()
        let observation = modelButton.observe(\.alphaValue, options: [.new]) { _, change in
            if let value = change.newValue { samples.values.append(value) }
        }
        modelButton.mouseDown(with: event)
        withExtendedLifetime(observation) {}
        return samples.values
    }
}
