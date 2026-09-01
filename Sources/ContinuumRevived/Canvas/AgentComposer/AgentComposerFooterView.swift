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
final class AgentComposerFooterView: NSView, TokenThemed, AgentPageZoomScalable {
    typealias SettingsWriter = (_ model: String?, _ thinking: String?) -> Bool
    typealias LaunchSelectionWriter = (_ harness: AgentHarness, _ model: String, _ thinking: String) -> Bool

    // The model trigger presents the provider>model picker (t3code-style two
    // pane surface); items/selection/QA seams are plain ChoiceButton.
    let harnessButton = ChoiceButton(title: "Harness")
    let modelButton: ChoiceButton = ProviderModelButton(title: "Model")
    let effortButton = ChoiceButton(title: "Effort")
    private var settings = AgentModelConfig.resolvedFromDefaults()
    private var recordHarness = AgentHarnessConfig.resolved()
    private var selectedHarness = AgentHarnessConfig.resolved()
    private var usesCompactLabels = false
    private var usesCondensedModelTrigger = false
    private var hidesEffort = false
    private var contrastObservations: [NSKeyValueObservation] = []
    /// WS5: the tile's page-zoom rung, delivered by the subtree walk.
    private(set) var pageZoom: AgentPageZoom = .default
    private var buttonRow: NSStackView?
    private var buttonHeightConstraints: [NSLayoutConstraint] = []

    var onSettingsWrite: SettingsWriter?
    var onLaunchSelectionWrite: LaunchSelectionWriter?

    static let height = ChoiceButton.controlHeight

    /// `height` at a page-zoom rung. An exact identity with `height` at 100%.
    static func height(zoom: AgentPageZoom) -> CGFloat {
        ChoiceButton.controlHeight(zoom: zoom)
    }

    /// This footer's row height at the rung it is currently showing.
    var rowHeight: CGFloat { Self.height(zoom: pageZoom) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        harnessButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        harnessButton.setContentHuggingPriority(.required, for: .horizontal)
        modelButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        modelButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
        effortButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        effortButton.setContentHuggingPriority(.required, for: .horizontal)
        // The footer has no intrinsic width (it sizes to its host row), so when it
        // shares a row with the Send button it must actively want to FILL the
        // remainder — otherwise the enclosing stack sizes it to its collapsed
        // minimum and the model/effort buttons truncate while free space sits
        // before Send (the recurring effort-picker truncation). A near-zero
        // hugging priority makes the row hand it all the surplus.
        setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        harnessButton.setAccessibilityLabel("Agent harness, next turn")
        modelButton.setAccessibilityLabel("Model, next turn")
        modelButton.setAccessibilityHelp("Choose the model for this agent's next turn")
        effortButton.setAccessibilityLabel("Reasoning effort, next turn")
        effortButton.setAccessibilityHelp("Choose the reasoning effort for this agent's next turn")
        modelButton.toolTip = "Model for the next turn"
        effortButton.toolTip = "Reasoning effort for the next turn"

        harnessButton.onSelection = { [weak self] item in self?.pick(harness: AgentHarness(rawValue: item.id)) }
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
        let stack = NSStackView(views: [harnessButton, modelButton, effortButton, spacer])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = CGFloat(pageZoom.scaled(Space.m))
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        buttonRow = stack
        // Held so `applyPageZoom` can rescale them: a constant baked into an
        // activated anchor cannot be re-derived any other way.
        buttonHeightConstraints = [
            harnessButton.heightAnchor.constraint(equalToConstant: Self.height(zoom: pageZoom)),
            modelButton.heightAnchor.constraint(equalToConstant: Self.height(zoom: pageZoom)),
            effortButton.heightAnchor.constraint(equalToConstant: Self.height(zoom: pageZoom)),
        ]
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ] + buttonHeightConstraints)

        installContrastObservers()
        apply(settings)
        applyTokens()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: rowHeight)
    }

    func applyPageZoom(_ zoom: AgentPageZoom) {
        pageZoom = zoom
        buttonRow?.spacing = CGFloat(pageZoom.scaled(Space.m))
        for constraint in buttonHeightConstraints {
            constraint.constant = Self.height(zoom: pageZoom)
        }
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard bounds.width > 0 else { return }
        // Measured fit, not a guessed threshold: abbreviate exactly when the full
        // titles do not fit the width this row actually has (P5.5 defect 4 — the
        // old hard-coded 390 was compact where full fits and full where it
        // clipped, depending entirely on the catalogue's string lengths).
        let compact = requiredWidth(usingCompactLabels: false) > bounds.width
        // The provider/harness control must remain reachable at every supported
        // tile width. Hiding it made a Pi agent impossible to switch away from Pi.
        // At the 320pt tile floor the footer cannot physically hold three custom
        // popup controls (their chrome alone is wider than the available space),
        // so effort yields first. If provider + model still do not fit, shorten
        // only the CLOSED model trigger to "Model"; its popover rows and
        // accessibility value retain the exact selected model.
        let shouldHideEffort = requiredWidth(
            usingCompactLabels: true, condenseModelTrigger: false) > bounds.width
        let condensesModelTrigger = shouldHideEffort && requiredWidth(
            usingCompactLabels: true, condenseModelTrigger: false,
            includeEffort: false) > bounds.width
        if compact != usesCompactLabels
            || condensesModelTrigger != usesCondensedModelTrigger
            || shouldHideEffort != hidesEffort {
            usesCompactLabels = compact
            usesCondensedModelTrigger = condensesModelTrigger
            hidesEffort = shouldHideEffort
            effortButton.isHidden = shouldHideEffort
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
    private func requiredWidth(
        usingCompactLabels compact: Bool,
        condenseModelTrigger: Bool? = nil,
        includeEffort: Bool = true
    ) -> CGFloat {
        let condensed = condenseModelTrigger ?? usesCondensedModelTrigger
        let modelTitle = compact && condensed
            ? "Model"
            : (compact ? Self.abbreviatedModel(settings.model) : (AgentModelCatalog.shared.displayName(for: settings.model, harness: recordHarness) ?? settings.model))
        let effortTitle = compact ? Self.abbreviatedEffort(settings.thinking) : settings.thinking.capitalized
        let harnessTitle = compact ? Self.abbreviatedHarness(recordHarness) : recordHarness.rawValue
        let gap = CGFloat(pageZoom.scaled(Space.m))
        let providerAndModel = ChoiceButton.fittingWidth(forTitle: harnessTitle, zoom: pageZoom)
            + gap + ChoiceButton.fittingWidth(forTitle: modelTitle, zoom: pageZoom)
        return includeEffort
            ? providerAndModel + gap + ChoiceButton.fittingWidth(forTitle: effortTitle, zoom: pageZoom)
            : providerAndModel
    }

    var controlsEnabled: Bool {
        get { harnessButton.isEnabled && modelButton.isEnabled && effortButton.isEnabled }
        set {
            harnessButton.isEnabled = newValue
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

    func apply(_ selection: AgentLaunchSelection) {
        recordHarness = selection.harness
        selectedHarness = selection.harness
        settings = AgentModelConfig.Resolution(model: selection.model, thinking: selection.thinking)
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
        for button in [harnessButton, modelButton, effortButton] {
            contrastObservations.append(button.observe(\.alphaValue, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.preserveDisabledContrast() }
            })
        }
    }

    private func preserveDisabledContrast() {
        for button in [harnessButton, modelButton, effortButton]
        where !button.isEnabled && button.alphaValue != 1 {
            button.alphaValue = 1
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    private func rebuildChoices() {
        harnessButton.items = AgentHarness.allCases.map { harness in
            ChoiceItem(id: harness.rawValue, title: usesCompactLabels ? Self.abbreviatedHarness(harness) : harness.rawValue)
        }
        harnessButton.selectedID = selectedHarness.rawValue
        let snapshot = AgentModelCatalog.shared.snapshot(for: selectedHarness)
        var models = snapshot.models
        if selectedHarness == recordHarness, !models.contains(settings.model) { models.append(settings.model) }
        modelButton.items = models.map { model in
            ChoiceItem(id: model, title: usesCompactLabels ? Self.abbreviatedModel(model) : (snapshot.displayNames[model] ?? model))
        }
        modelButton.selectedTitleOverride = usesCondensedModelTrigger ? "Model" : nil
        var efforts = AgentModelConfig.thinkingOptions
        if !efforts.contains(settings.thinking) { efforts.append(settings.thinking) }
        effortButton.items = efforts.map { effort in ChoiceItem(id: effort, title: usesCompactLabels ? Self.abbreviatedEffort(effort) : effort.capitalized) }
        modelButton.selectedID = selectedHarness == recordHarness ? settings.model : nil
        effortButton.selectedID = settings.thinking
    }

    private func pick(harness: AgentHarness? = nil, model: String? = nil, thinking: String? = nil) {
        if let harness {
            guard harness != recordHarness else {
                selectedHarness = recordHarness
                rebuildChoices()
                return
            }

            // A harness choice is a complete next-turn choice, not the first half
            // of a hidden two-step transaction. In particular, Anthropic model IDs
            // can appear in both Pi and Claude Code. The old path changed only
            // `selectedHarness`, left the record on Pi, and kept showing the same
            // "Claude Opus" model title; Send then ran Pi even though the footer
            // visibly said Claude Code. Preserve the current model when the new
            // harness owns it, otherwise choose that harness's first runnable model,
            // and persist the pair atomically through the same writer as a model pick.
            let previousHarness = recordHarness
            let previousSettings = settings
            let snapshot = AgentModelCatalog.shared.snapshot(for: harness)
            let compatibleModels = snapshot.models.filter {
                AgentHarnessConfig.isProviderCompatible(model: $0, harness: harness)
            }
            guard let nextModel = compatibleModels.contains(settings.model)
                    ? settings.model
                    : compatibleModels.first else {
                selectedHarness = previousHarness
                rebuildChoices()
                return
            }
            let next = AgentModelConfig.Resolution(model: nextModel, thinking: settings.thinking)
            let accepted = onLaunchSelectionWrite?(harness, next.model, next.thinking) ?? true
            guard accepted else {
                recordHarness = previousHarness
                selectedHarness = previousHarness
                settings = previousSettings
                rebuildChoices()
                return
            }
            recordHarness = harness
            selectedHarness = harness
            settings = next
            rebuildChoices()
            return
        }
        let next = AgentModelConfig.Resolution(model: model ?? settings.model, thinking: thinking ?? settings.thinking)
        let priorHarness = recordHarness
        let previous = settings
        let accepted: Bool
        if selectedHarness != recordHarness {
            guard model != nil else { return }
            accepted = onLaunchSelectionWrite?(selectedHarness, next.model, next.thinking) ?? false
        } else if let writer = onSettingsWrite {
            // Same-harness picks carry only the field that moved. Re-submitting
            // the full launch selection would make an effort-only change fail
            // for a restored agent whose model has left the live catalogue.
            accepted = writer(model, thinking)
        } else if let writer = onLaunchSelectionWrite {
            accepted = writer(recordHarness, next.model, next.thinking)
        } else {
            accepted = true
        }
        guard accepted else {
            recordHarness = priorHarness
            selectedHarness = priorHarness
            settings = previous
            rebuildChoices()
            return
        }
        recordHarness = selectedHarness
        settings = next
        rebuildChoices()
    }

    static func abbreviatedHarness(_ harness: AgentHarness) -> String {
        switch harness {
        case .claudeCode: return "Claude"
        case .codex: return "Codex"
        case .pi: return "Pi"
        }
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
    var qaLaunchSelection: AgentLaunchSelection {
        AgentLaunchSelection(harness: recordHarness, model: settings.model, thinking: settings.thinking)
    }
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
        let gap = CGFloat(pageZoom.scaled(Space.m))
        let needed = harnessButton.intrinsicContentSize.width + gap
            + modelButton.intrinsicContentSize.width
            + (effortButton.isHidden ? 0 : gap + effortButton.intrinsicContentSize.width)
        return bounds.width > 0 && needed <= bounds.width + 0.5
    }
    @discardableResult func qaPickModel(_ value: String) -> Bool {
        guard modelButton.items.contains(where: { $0.id == value && $0.enabled }), controlsEnabled else { return false }
        let before = settings
        pick(model: value)
        return settings != before
    }
    @discardableResult func qaPickHarness(_ value: AgentHarness) -> Bool {
        guard harnessButton.items.contains(where: { $0.id == value.rawValue && $0.enabled }), controlsEnabled else { return false }
        let before = qaLaunchSelection
        pick(harness: value)
        return qaLaunchSelection != before
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
