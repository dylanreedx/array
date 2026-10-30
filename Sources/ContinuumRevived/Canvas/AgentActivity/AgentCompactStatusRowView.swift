import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

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
    func hideLocationActions() { actionButton.isHidden = true }

    private let activityIcon = NSImageView()
    private let activityLabel = HonestWidthLabel(labelWithString: "")
    private let elapsedLabel = NSTextField(labelWithString: "")
    private let contextMeter = AgentRadialContextMeterView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
    private let contextLabel = NSTextField(labelWithString: "")
    private let compactContextButton: NSButton = {
        let button = NSButton(title: "Compact", target: nil, action: nil)
        button.bezelStyle = .inline
        button.isBordered = false
        button.setButtonType(.momentaryPushIn)
        button.toolTip = "Compact the context window"
        button.setAccessibilityLabel("Compact context")
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }()
    /// Absorbs the row's leftover width.
    ///
    /// Without it `locationGroup` was the only low-hugging view, so it swallowed
    /// every spare point — 721pt of a 1200pt row for a 61pt name — and the
    /// activity label was left 44.0pt for a 45.0pt word. One point short is all
    /// it takes: AppKit drew "Waiti…" on a row with 600pt of empty space. Slack
    /// belongs in a view that does not render.
    private let flexibleSpacer = NSView()
    /// ST-01 — one reusable pill per account-scoped element, plus cost. Created
    /// once and reused; an element the user disabled is hidden, never rebuilt,
    /// so toggling one costs no view churn.
    private var quotaPills: [AgentStatusElement: AgentStatusPillView] = [:]
    private let quotaGroup: NSStackView
    /// .plans/101 — hovering the account group opens `accountCard`, the only
    /// place the row's account (plan, email) is drawn.
    private var accountCard: AgentAccountUsageCardView?
    /// The sidebar row card's fade and pop, in and out.
    private let accountCardMotion = HoverCardMotion()
    /// Reduce Motion, read the way the sidebar reads it; a check overrides it.
    var prefersReducedMotion: () -> Bool = {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
    private var accountCardDwell: DispatchWorkItem?
    private var accountHoverArea: NSTrackingArea?
    /// Called when the card opens, so the host can ask for a fresh reading.
    var onAccountCardShown: (() -> Void)?
    /// The whole-row tooltip text: everything the row can drop, minus the
    /// account windows, which the card carries. Served per point by
    /// `view(_:stringForToolTip:point:userData:)` so it never opens over the
    /// pills on top of the card.
    private var rowDetailText = ""
    /// 0.7.30 — what the agent left running. Clickable: it opens the menu that
    /// lists each job with its ports and a Stop.
    private let processesPill = AgentStatusPillView()
    private var backgroundJobs: (value: String, detail: String, spoken: String)?
    var onBackgroundJobsMenuRequested: ((NSView) -> Void)?
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
    /// Routed by the tile to the session owner when the user requests an early
    /// context compaction from a warning/critical reading.
    var onCompactContextRequested: (() -> Void)?

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
        // The context ring is NOT a pill. It is already a shape carrying its own
        // reading, and wrapping a circle in a capsule reads as two nested
        // containers for one number. The pills exist to group a label with a
        // value; the ring has no label to group.
        contextGroup = NSStackView(views: [contextMeter, contextLabel, compactContextButton])
        quotaGroup = NSStackView(views: [])
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
        configureLabel(contextLabel, role: .captionMono)
        configureLabel(elapsedLabel, role: .captionMono)

        locationLabel.lineBreakMode = .byTruncatingMiddle
        // Hugs its content rather than stretching. It is still the compression
        // SINK (resistance 1 below), which is what makes a long path truncate
        // first; being greedy about spare width was a separate and unhelpful
        // behaviour that starved the phase label by a rounding point.
        locationLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
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

        // The spacer is the greedy view now, so every rendering view gets its
        // fitting width and the rounding error lands in empty space.
        flexibleSpacer.translatesAutoresizingMaskIntoConstraints = false
        flexibleSpacer.setContentHuggingPriority(
            NSLayoutConstraint.Priority(1), for: .horizontal)
        flexibleSpacer.setContentCompressionResistancePriority(
            NSLayoutConstraint.Priority(1), for: .horizontal)
        flexibleSpacer.widthAnchor.constraint(greaterThanOrEqualToConstant: 0).isActive = true

        locationGroup.orientation = .horizontal
        locationGroup.alignment = .centerY
        locationGroup.spacing = CGFloat(pageZoom.scaled(Space.xs))
        locationGroup.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        locationGroup.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(10), for: .horizontal)
        actionButton.target = self
        actionButton.action = #selector(showActions(_:))
        compactContextButton.target = self
        compactContextButton.action = #selector(compactContext(_:))
        compactContextButton.isHidden = true

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

        // The account/cost chips. `detachesHiddenViews` is what makes hiding one
        // actually reclaim its width instead of leaving a gap the reader reads
        // as a missing value.
        quotaGroup.orientation = .horizontal
        quotaGroup.alignment = .centerY
        // Space.m between pills, not xs: the capsules are what separate the
        // readings now, and crowding them undoes the grouping they exist for.
        quotaGroup.spacing = CGFloat(pageZoom.scaled(Space.m))
        quotaGroup.detachesHiddenViews = true
        quotaGroup.setContentHuggingPriority(.required, for: .horizontal)
        quotaGroup.setContentCompressionResistancePriority(.required, for: .horizontal)
        let hover = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self, userInfo: nil)
        quotaGroup.addTrackingArea(hover)
        accountHoverArea = hover
        for element in AgentStatusElement.presentationOrder
        where element.isAccountScoped || element == .cost {
            let pill = AgentStatusPillView()
            pill.isHidden = true
            quotaPills[element] = pill
            quotaGroup.addArrangedSubview(pill)
        }

        rootStack.orientation = .horizontal
        rootStack.alignment = .centerY
        rootStack.spacing = CGFloat(pageZoom.scaled(Space.m))
        rootStack.edgeInsets = Self.rootInsets(zoom: pageZoom)
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        rootStack.addArrangedSubview(locationGroup)
        rootStack.addArrangedSubview(activityGroup)
        rootStack.addArrangedSubview(flexibleSpacer)
        processesPill.isHidden = true
        processesPill.setAccessibilityElement(true)
        processesPill.setAccessibilityRole(.button)
        processesPill.setAccessibilityIdentifier("agentTile.backgroundProcesses")
        processesPill.addGestureRecognizer(NSClickGestureRecognizer(
            target: self, action: #selector(backgroundJobsClicked(_:))))
        rootStack.addArrangedSubview(processesPill)
        rootStack.addArrangedSubview(contextGroup)
        rootStack.addArrangedSubview(quotaGroup)
        // The metrics read as a cluster on the right: the spacer above holds
        // them apart from identity and phase, and a minimum gap survives even
        // when the spacer has collapsed to nothing in a narrow tile.
        rootStack.setCustomSpacing(CGFloat(pageZoom.scaled(Space.l)), after: flexibleSpacer)
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
            context: AgentRadialContextMeterPresenter.present(nil),
            // The row's own placeholder, before any caller has applied a real
            // presentation: nothing is enabled beyond the three original
            // elements and there is no reading of any kind yet.
            quotas: [],
            cost: nil,
            account: nil,
            enabledElements: [.location, .activity, .contextMeter]))
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
        // The empty ring stands alone: hidden, not an empty string holding a
        // slot and its spacing in the stack.
        let hidesContextLabel = next.context.state == .empty
        if contextLabel.isHidden != hidesContextLabel {
            contextLabel.isHidden = hidesContextLabel
            invalidateIntrinsicContentSize()
            rootStack.needsLayout = true
            needsLayout = true
        }
        contextLabel.stringValue = next.context.label
        contextLabel.toolTip = next.context.detailText
        contextLabel.setAccessibilityLabel(next.context.accessibilityLabel)
        applyQuotaElements(next)
        actionButton.toolTip = next.location.detailText + "\nLocation actions"
        if let account = next.account {
            accountCard?.apply(account.card)
        } else {
            dismissAccountCard()
        }
        // A silent activity contributes nothing to speech either — VoiceOver must
        // not announce a phase the row is deliberately not showing.
        let spokenActivity = next.activity.isSilent ? "" : " \(next.activity.accessibilityLabel)"
        // Account-scoped phrases are spoken in full even when their chip was
        // dropped: losing width is a display constraint, not a reason to stop
        // reporting a number to a screen reader.
        let spokenContext = next.enabledElements.contains(.contextMeter)
            ? " \(next.context.accessibilityLabel)" : ""
        let spokenQuotas = next.quotas.map { " \($0.accessibilityLabel)" }.joined()
        let spokenCost = next.cost.map { " \($0.accessibilityLabel)" } ?? ""
        let spokenJobs = backgroundJobs.map { " \($0.spoken)" } ?? ""
        // Which account, before its windows: the card says it to the eye.
        let spokenAccount = next.account.map { " \($0.accessibilityLabel)" } ?? ""
        setAccessibilityLabel(
            "Agent compact status. \(next.location.accessibilityLabel)\(spokenActivity)\(spokenJobs)\(spokenContext)\(spokenAccount)\(spokenQuotas)\(spokenCost)")
        setAccessibilityHelp(rowDetailText)
        // Parent owns the combined Home/Where/What/activity/context announcement;
        // only actionable controls are separately reachable.
        updateActionAccessibilityChildren()
        updateThinkingLifecycle()
        applyTokens()
    }

    /// Fills the account/cost chips, hides the ones the user disabled, then runs
    /// the width pass.
    ///
    /// A DISABLED element and a DROPPED element look identical on screen and are
    /// not the same thing: disabled means the user turned it off and it stays
    /// out of the tooltip's promise; dropped means it did not fit right now and
    /// its value is still in the tooltip and the accessibility label. Only the
    /// latter comes back when the tile widens.
    private func applyQuotaElements(_ next: AgentCompactStatusPresentation) {
        let enabled = Set(next.enabledElements)
        for (element, pill) in quotaPills {
            guard enabled.contains(element) else {
                pill.isHidden = true
                continue
            }
            if element == .cost {
                if let cost = next.cost {
                    pill.apply(cost: cost)
                    pill.isHidden = false
                } else {
                    // Enabled but nothing reported yet. Silence rather than a
                    // "$0.00" that would claim a free session.
                    pill.isHidden = true
                }
                continue
            }
            guard let quota = next.quotas.first(where: { $0.element == element }) else {
                pill.isHidden = true
                continue
            }
            pill.apply(quota)
            pill.isHidden = false
        }
        if enabled.contains(.processes), let backgroundJobs {
            processesPill.apply(symbolName: AgentProcessUI.symbolName, value: backgroundJobs.value, detail: backgroundJobs.detail)
            processesPill.setAccessibilityLabel(backgroundJobs.spoken)
            processesPill.isHidden = false
        } else {
            processesPill.isHidden = true
        }
        // Whole groups follow their own toggles.
        locationGroup.isHidden = !enabled.contains(.location)
        contextGroup.isHidden = !enabled.contains(.contextMeter)
        compactContextButton.isHidden = !enabled.contains(.contextMeter)
            || !Self.contextCanBeCompacted(next.context.state)
        if !enabled.contains(.activity) { activityGroup.isHidden = true }
        droppedElements = []
        applyOverflow()
        updateActionAccessibilityChildren()
        // An empty group must leave the layout entirely, not sit in it at 0x0.
        // A zero-size visible view is what `--ui-geometry-check` flags, and it is
        // right to: a stack view with no visible arranged subview still claims a
        // slot and its spacing, so the row gains a phantom gap at exactly the
        // narrow widths where every chip has been dropped.
        quotaGroup.isHidden = quotaPills.values.allSatisfy(\.isHidden)
        // Everything the row can drop under width pressure survives here, so a
        // dropped element is never unreachable — only unshown. An account
        // window still ON screen is the exception: the account card that opens
        // over its pill carries it (.plans/101).
        rowDetailText = ([next.location.detailText, next.activity.detailText, next.context.detailText]
            + next.quotas.filter { quotaPills[$0.element]?.isHidden ?? true }.map(\.detailText)
            + [next.cost?.detailText, backgroundJobs?.detail].compactMap { $0 })
            .joined(separator: "\n\n")
        installRowToolTip()
        invalidateIntrinsicContentSize()
        rootStack.needsLayout = true
        needsLayout = true
    }

    /// Only controls on screen are separately reachable. Re-run after every
    /// width pass, because that pass can drop the ring and its action with it.
    private func updateActionAccessibilityChildren() {
        var accessibilityActions: [NSView] = [actionButton]
        if !processesPill.isHidden { accessibilityActions.append(processesPill) }
        if !compactContextButton.isHidden { accessibilityActions.append(compactContextButton) }
        setAccessibilityChildren(accessibilityActions)
    }

    /// The Compact action's two shapes: titled when the row has room, the
    /// symbol alone when the titled ring would not fit. The accessibility label
    /// and tooltip are the same in both.
    private func setCompactContextButtonIconOnly(_ iconOnly: Bool) {
        if iconOnly {
            compactContextButton.image = CanvasSymbolImage.image(
                named: "arrow.down.right.and.arrow.up.left",
                pointSize: CGFloat(pageZoom.scaled(11)), weight: .semibold)
            compactContextButton.imagePosition = .imageOnly
        } else {
            compactContextButton.image = nil
            compactContextButton.imagePosition = .noImage
        }
    }

    private var compactContextButtonIsIconOnly: Bool {
        compactContextButton.imagePosition == .imageOnly
    }

    private static func contextCanBeCompacted(_ state: AgentRadialContextMeterState) -> Bool {
        state == .warning || state == .critical
    }

    /// What the agent left running, or nil when nothing is. Kept apart from the
    /// presentation: it changes on the process tracker's tick, not on a turn.
    func applyBackgroundJobs(value: String?, detail: String, spoken: String) {
        backgroundJobs = value.map { ($0, detail, spoken) }
        guard let presentation else { return }
        apply(presentation)
    }

    @objc private func backgroundJobsClicked(_ recognizer: NSClickGestureRecognizer) {
        guard backgroundJobs != nil else { return }
        onBackgroundJobsMenuRequested?(processesPill)
    }

    @objc private func compactContext(_ sender: NSButton) {
        guard let presentation, Self.contextCanBeCompacted(presentation.context.state) else { return }
        onCompactContextRequested?()
    }

    /// Hides the elements that do not fit, lowest priority first.
    ///
    /// Bounded and O(elements) — seven chips, each already sized by AppKit, with
    /// no text measurement of its own. This is deliberately not done inside
    /// `layout()`: measurement in a layout pass is how the Markdown tile froze
    /// the app (`docs/internals/performance.md`), and there is no reason to
    /// recompute on every pass when the inputs only change on `apply` and on a
    /// width change.
    private func applyOverflow() {
        guard let presentation else { return }
        setCompactContextButtonIconOnly(false)
        // The policy charges one `spacing` between survivors. The row also
        // carries `flexibleSpacer`, an arranged view of its own: one more gap
        // into it and `Space.l` (not `spacing`) out of it. Uncharged, the
        // budget was 12pt short at 100% and a 275pt warning row laid out
        // 276.5pt (`--managed-agent-page-zoom-check`). `Space.l` is at least
        // `spacing`, so charging it covers the spacer whether or not anything
        // follows it.
        let available = bounds.width - Self.rootInsets(zoom: pageZoom).left
            - Self.rootInsets(zoom: pageZoom).right
            - rootStack.customSpacing(after: flexibleSpacer)
        guard available > 0 else { return }

        var widths: [AgentStatusElement: CGFloat] = [:]
        for element in presentation.enabledElements {
            switch element {
            case .location:
                widths[element] = locationGroup.fittingSize.width
            case .activity:
                widths[element] = presentation.activity.isSilent ? 0 : activityGroup.fittingSize.width
            case .contextMeter:
                widths[element] = contextGroup.fittingSize.width
            case .processes:
                widths[element] = processesPill.isHidden ? 0 : processesPill.fittingSize.width
            case .quotaFiveHour, .quotaSevenDay, .quotaSpendLimit, .cost:
                let pill = quotaPills[element]
                widths[element] = (pill?.isHidden ?? true) ? 0 : (pill?.fittingSize.width ?? 0)
            }
        }

        func fitting() -> [AgentStatusElement] {
            AgentStatusOverflowPolicy.fitting(
                presentation.enabledElements,
                widths: widths,
                available: available,
                spacing: rootStack.spacing,
                locationFloor: CGFloat(pageZoom.scaled(48)))
        }
        var kept = fitting()
        // The Compact action gives way before the ring does: its title goes
        // first, and only a ring that still cannot fit as meter + reading +
        // symbol is dropped — taking its action with it.
        if !kept.contains(.contextMeter), !compactContextButton.isHidden,
           presentation.enabledElements.contains(.contextMeter) {
            setCompactContextButtonIconOnly(true)
            widths[.contextMeter] = contextGroup.fittingSize.width
            kept = fitting()
        }
        let dropped = Set(presentation.enabledElements).subtracting(kept)
        droppedElements = dropped

        for element in dropped {
            switch element {
            case .activity: activityGroup.isHidden = true
            case .contextMeter:
                contextGroup.isHidden = true
                compactContextButton.isHidden = true
            case .processes: processesPill.isHidden = true
            case .location: break  // never dropped; it truncates instead
            default: quotaPills[element]?.isHidden = true
            }
        }
    }

    // MARK: - .plans/101 account card

    /// One tooltip rect over the whole row, answered per point: the pills get
    /// the card instead of text.
    private func installRowToolTip() {
        removeAllToolTips()
        toolTip = nil
        addToolTip(bounds, owner: self, userData: nil)
    }

    override func mouseEntered(with event: NSEvent) {
        guard event.trackingArea === accountHoverArea else { return super.mouseEntered(with: event) }
        accountPillsPointerEntered(dwell: 0.15)
    }

    override func mouseExited(with event: NSEvent) {
        guard event.trackingArea === accountHoverArea else { return super.mouseExited(with: event) }
        accountCardDwell?.cancel()
        accountCardDwell = nil
        dismissAccountCard()
    }

    private func accountPillsPointerEntered(dwell: TimeInterval) {
        accountCardDwell?.cancel()
        guard presentation?.account != nil else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.presentAccountCard() }
        }
        accountCardDwell = work
        if dwell <= 0 {
            work.perform()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + dwell, execute: work)
        }
    }

    /// Hosted in the window's content view, above the pills, for the reasons
    /// `InboxHoverCardView` gives: inside the tile it would be clipped by the
    /// tile and scaled by the canvas.
    private func presentAccountCard() {
        accountCardDwell = nil
        guard let account = presentation?.account, !quotaGroup.isHidden,
              let contentView = window?.contentView else { return }
        let card = accountCard ?? AgentAccountUsageCardView(frame: .zero)
        accountCard = card
        card.apply(account.card)
        card.layoutSubtreeIfNeeded()
        let size = card.intrinsicContentSize
        let anchor = quotaGroup.convert(quotaGroup.bounds, to: contentView)
        let gap = CGFloat(Space.m)
        var origin = NSPoint(x: anchor.midX - size.width / 2, y: 0)
        origin.x = max(gap, min(origin.x, contentView.bounds.maxX - size.width - gap))
        if contentView.isFlipped {
            origin.y = anchor.minY - gap - size.height
            if origin.y < gap { origin.y = anchor.maxY + gap }
        } else {
            origin.y = anchor.maxY + gap
            if origin.y + size.height > contentView.bounds.maxY - gap { origin.y = anchor.minY - gap - size.height }
        }
        card.frame = NSRect(origin: origin, size: size)
        accountCardMotion.present(card, in: contentView, reducedMotion: prefersReducedMotion())
        onAccountCardShown?()
    }

    func dismissAccountCard() {
        accountCardDwell?.cancel()
        accountCardDwell = nil
        guard let card = accountCard else { return }
        accountCardMotion.dismiss(card, reducedMotion: prefersReducedMotion())
    }

    /// The pointer path a hover takes, minus the dwell: a witness drives the
    /// same handler the tracking area calls.
    func qaHoverAccountPills() { accountPillsPointerEntered(dwell: 0) }
    /// Open and not on its way out.
    var qaAccountCard: AgentAccountUsageCardView? {
        accountCard?.superview == nil || accountCardMotion.isDismissing ? nil : accountCard
    }
    /// Still on screen, fading out.
    var qaAccountCardFading: AgentAccountUsageCardView? {
        accountCard?.superview != nil && accountCardMotion.isDismissing ? accountCard : nil
    }
    var qaAccountPresentation: AgentAccountUsagePresentation? { presentation?.account }
    var qaAccountPillsFrame: NSRect? { quotaGroup.isHidden ? nil : frame(of: quotaGroup) }
    /// What the row's tooltip says at a point in row coordinates.
    func qaToolTip(at point: NSPoint) -> String {
        view(self, stringForToolTip: 0, point: point, userData: nil)
    }

    /// The chip's value as drawn, or nil when it is not on screen.
    /// Where the processes panel opens from: the chip.
    var backgroundJobsAnchor: NSView { processesPill }
    var qaBackgroundJobsValue: String? { processesPill.isHidden ? nil : processesPill.qaValueText }

    /// Elements the width pass removed on the current bounds. Distinct from the
    /// disabled set, and reported to QA so a witness can assert the drop ORDER
    /// rather than merely that something vanished.
    private(set) var droppedElements: Set<AgentStatusElement> = []

    override func setFrameSize(_ newSize: NSSize) {
        let changedWidth = abs(newSize.width - frame.width) > 0.5
        let changedSize = newSize != frame.size
        super.setFrameSize(newSize)
        if changedSize { installRowToolTip() }
        guard changedWidth, let presentation else { return }
        // Re-apply from the presentation so an element the last, narrower pass
        // dropped can come back when the tile widens.
        applyQuotaElements(presentation)
        applyTokens()
    }

    func applyTokens() {
        layer?.cornerRadius = CGFloat(pageZoom.scaled(Radius.card))
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
        contextMeter.applyTokens()
        // Each pill owns its own fill and value tint; the row only has to ask.
        contextLabel.textColor = contextLabelColor(for: presentation?.context.state ?? .unknown, theme: theme)
        for pill in quotaPills.values { pill.applyTokens() }
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
        for pill in quotaPills.values { pill.applyPageZoom(pageZoom) }
        quotaGroup.spacing = CGFloat(pageZoom.scaled(Space.m))
        locationGroup.spacing = CGFloat(pageZoom.scaled(Space.xs))
        activityGroup.spacing = CGFloat(pageZoom.scaled(Space.xs))
        contextGroup.spacing = CGFloat(pageZoom.scaled(Space.xs))
        rootStack.spacing = CGFloat(pageZoom.scaled(Space.m))
        rootStack.setCustomSpacing(CGFloat(pageZoom.scaled(Space.l)), after: flexibleSpacer)
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
            // Every width the last pass measured was at the old rung. A rung
            // change at an unchanged width never reaches `setFrameSize`, so
            // re-run the pass here: at 150% a 300pt row otherwise kept a ring
            // sized at 100% and laid out 372pt of content.
            applyQuotaElements(presentation)
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
        if newWindow !== window { dismissAccountCard() }
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
        dismissAccountCard()
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


    /// Account chips reuse the context meter's colour ladder so one row does not
    /// teach two colour languages. `expired` is deliberately the same subdued
    /// treatment as `unknown` — both mean "no number you can trust right now" —
    /// while the tooltip keeps them distinct in words.
    private func contextLabelColor(for state: AgentRadialContextMeterState, theme: TokenTheme) -> NSColor {
        switch state {
        case .known:
            return TextToken.textPrimary.color.nsColor(for: theme)
        case .warning:
            return AccentToken.accentApproval.color.nsColor(for: theme)
        case .critical:
            return AccentToken.accentFailed.color.nsColor(for: theme)
        case .unknown, .stale, .empty:
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
    var qaContextLabelHidden: Bool { contextLabel.isHidden }
    var qaContextOverlayMarker: String? { contextMeter.qaOverlayMarker }
    var qaContextTrackIsDashed: Bool { contextMeter.qaTrackIsDashed }
    /// ST-01 QA surface: what each account/cost chip is currently drawing, the
    /// elements the width pass dropped, and which elements are enabled at all.
    func qaQuotaText(_ element: AgentStatusElement) -> String {
        guard let pill = quotaPills[element], !pill.isHidden else { return "" }
        let label = pill.qaLabelText
        let value = pill.qaValueText
        return label.isEmpty ? value : "\(label) \(value)"
    }
    /// The pill itself, for the geometry witness: a chip that lost its fill, its
    /// glyph or its capsule radius is a chip that stopped grouping anything.
    func qaQuotaPill(_ element: AgentStatusElement) -> AgentStatusPillView? {
        quotaPills[element].flatMap { $0.isHidden ? nil : $0 }
    }
    func qaQuotaState(_ element: AgentStatusElement) -> AgentQuotaElementState? {
        presentation?.quotas.first(where: { $0.element == element })?.state
    }
    func qaQuotaFrame(_ element: AgentStatusElement) -> NSRect? {
        quotaPills[element].flatMap { $0.isHidden ? nil : frame(of: $0) }
    }
    var qaDroppedElements: Set<AgentStatusElement> { droppedElements }
    var qaEnabledElements: [AgentStatusElement] { presentation?.enabledElements ?? [] }
    var qaToolTip: String { rowDetailText }
    var qaContextState: AgentRadialContextMeterState { contextMeter.qaState }
    var qaContextFraction: Double? { contextMeter.qaFraction }
    var qaContextDetail: String { contextMeter.qaDetail }
    var qaContextThresholdFraction: Double? { contextMeter.qaThresholdFraction }
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
    /// What the phase label NEEDS, against what the row gave it. The gap
    /// between those two numbers was one point, and one point is a visible
    /// ellipsis.
    var qaActivityLabelFittingWidth: CGFloat { activityLabel.fittingSize.width }
    var qaLocationIconFrame: NSRect? { frame(of: locationIcon) }
    var qaActivityIconFrame: NSRect? { frame(of: activityIcon) }
    var qaContextMeterFrame: NSRect? { frame(of: contextMeter) }
    var qaLocationIconHasImage: Bool { locationIcon.image != nil }
    var qaActivityIconHasImage: Bool { activityIcon.image != nil }
    var qaContextMeterSide: CGFloat { contextMeter.qaIntrinsicSide }
    var qaCompactContextButtonVisible: Bool { !compactContextButton.isHidden }
    var qaCompactContextButtonEnabled: Bool { compactContextButton.isEnabled }
    func qaPerformCompactContextAction() { compactContextButton.performClick(nil) }
    var qaCompactContextButtonFrame: NSRect? { frame(of: compactContextButton) }
    var qaCompactContextButtonIsIconOnly: Bool { compactContextButtonIsIconOnly }
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
        return context.width > 0 && bounds.contains(context)
            && (contextLabel.isHidden || !contextLabel.stringValue.isEmpty)
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
              let contextMeter = qaContextMeterFrame else { return false }
        // A deliberately hidden reading (the empty ring) has no glyphs to protect.
        let contextLabelProtected = contextLabel.isHidden
            || (qaContextLabelFrame?.width ?? 0) >= minimumTextWidth
        let locationAndContext = locationIcon.width >= minimumIconWidth
            && contextMeter.width >= 18
            && contextLabelProtected
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

/// An `NSTextField` that reports the width its own text actually needs.
///
/// `NSTextField.intrinsicContentSize` under-reports by the cell's inset and by
/// sub-point rounding, so a stack solves the label a hair narrower than its
/// string and AppKit ellipsizes it. On the compact status row that was 44.5pt
/// granted for 45.0pt of text on a 1200pt row: "Waiti…" beside 600pt of empty
/// space. Rounding the reported width up costs at most a point of layout and
/// removes a whole class of truncation-with-room-to-spare.
/// Witness: `--ui-geometry-check`.
final class HonestWidthLabel: NSTextField {
    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.width = ceil(max(size.width, cell?.cellSize(forBounds:
            NSRect(x: 0, y: 0, width: .greatestFiniteMagnitude, height: bounds.height)).width ?? size.width))
        return size
    }
}


extension AgentCompactStatusRowView: NSViewToolTipOwner {
    func view(
        _ view: NSView,
        stringForToolTip tag: NSView.ToolTipTag,
        point: NSPoint,
        userData data: UnsafeMutableRawPointer?
    ) -> String {
        if !quotaGroup.isHidden, presentation?.account != nil,
           quotaGroup.convert(quotaGroup.bounds, to: self).contains(point) {
            return ""
        }
        return rowDetailText
    }
}
