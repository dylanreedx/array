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

    // The model trigger presents the provider>model picker (t3code-style two
    // pane surface); items/selection/QA seams are plain ChoiceButton.
    let modelButton: ChoiceButton = ProviderModelButton(title: "Model")
    let effortButton = ChoiceButton(title: "Effort")
    private var settings = AgentModelConfig.resolvedFromDefaults()
    private var usesCompactLabels = false
    private var contrastObservations: [NSKeyValueObservation] = []

    var onSettingsWrite: SettingsWriter?

    static let height = ChoiceButton.controlHeight

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        modelButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        modelButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
        effortButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        effortButton.setContentHuggingPriority(.required, for: .horizontal)
        modelButton.setAccessibilityLabel("Model, next turn")
        modelButton.setAccessibilityHelp("Choose the model for this agent's next turn")
        effortButton.setAccessibilityLabel("Reasoning effort, next turn")
        effortButton.setAccessibilityHelp("Choose the reasoning effort for this agent's next turn")
        modelButton.toolTip = "Model for the next turn"
        effortButton.toolTip = "Reasoning effort for the next turn"

        modelButton.onSelection = { [weak self] item in self?.pick(model: item.id) }
        effortButton.onSelection = { [weak self] item in self?.pick(thinking: item.id) }

        // A bare spacer absorbs the row's surplus (the header-row convention), so
        // the buttons hold their intrinsic width instead of stretching — and so
        // free space can never mask an under-measured title again (P5.5 defect 4).
        // The old required `model ≥ 1.45 × effort` ratio is gone with it: it was a
        // magic number that could force the effort button BELOW its intrinsic
        // width; the buttons' natural title widths already order them.
        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let stack = NSStackView(views: [modelButton, effortButton, spacer])
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
        guard bounds.width > 0 else { return }
        // Measured fit, not a guessed threshold: abbreviate exactly when the full
        // titles do not fit the width this row actually has (P5.5 defect 4 — the
        // old hard-coded 390 was compact where full fits and full where it
        // clipped, depending entirely on the catalogue's string lengths).
        let compact = requiredWidth(usingCompactLabels: false) > bounds.width
        if compact != usesCompactLabels {
            usesCompactLabels = compact
            rebuildChoices()
        }
    }

    /// One resolution for what a model id is CALLED on this row: compact mode
    /// keeps the short id tail (it exists to fit), full mode prefers the human
    /// name from pi's synced catalog ("Claude Fable 5") and falls back to the
    /// id. QA has no display names unless a check injects them, so pinned
    /// titles are unchanged there.
    static func displayTitle(forModel model: String, compact: Bool) -> String {
        compact
            ? abbreviatedModel(model)
            : (AgentModelCatalog.shared.displayName(for: model) ?? model)
    }

    /// The row's fitting width for the CURRENT selection's titles: the same
    /// per-button expression `ChoiceButton` measures itself with, so this cannot
    /// drift from what the buttons actually need.
    private func requiredWidth(usingCompactLabels compact: Bool) -> CGFloat {
        let modelTitle = Self.displayTitle(forModel: settings.model, compact: compact)
        let effortTitle = compact ? Self.abbreviatedEffort(settings.thinking) : settings.thinking.capitalized
        return ChoiceButton.fittingWidth(forTitle: modelTitle)
            + CGFloat(Space.m) + ChoiceButton.fittingWidth(forTitle: effortTitle)
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
            ChoiceItem(id: $0, title: Self.displayTitle(forModel: $0, compact: usesCompactLabels))
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

    // Deterministic probes read the installed controls and use the same selection
    // path after the popover chooses. The context seams remain for the tile's older
    // QA wrapper, but the footer no longer installs a visible Next turn label.
    var qaSettings: AgentModelConfig.Resolution { settings }
    var qaContextText: String { "" }
    var qaContextIsActionable: Bool { false }
    var qaHasVisibleContextLabel: Bool {
        func containsVisibleContext(_ view: NSView) -> Bool {
            if let label = view as? NSTextField,
               !label.isHidden,
               label.stringValue == "Next turn" { return true }
            return view.subviews.contains(where: containsVisibleContext)
        }
        return containsVisibleContext(self)
    }
    var qaModelTitles: [String] { modelButton.items.map(\.title) }
    var qaEffortTitles: [String] { effortButton.items.map(\.title) }
    /// The row's own measured-fit verdict for what is currently installed: when
    /// true, both buttons must sit at (or above) their intrinsic width and render
    /// their selected titles without ellipsis — the truncation gate's precondition.
    var qaFitsCurrentTitles: Bool {
        let needed = modelButton.intrinsicContentSize.width + CGFloat(Space.m)
            + effortButton.intrinsicContentSize.width
        return bounds.width > 0 && needed <= bounds.width + 0.5
    }
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
