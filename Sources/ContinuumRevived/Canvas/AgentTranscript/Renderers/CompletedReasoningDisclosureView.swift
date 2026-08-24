import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedAgentUI

/// AppKit disclosure component for one completed reasoning entry. The transcript
/// list mounts this at the semantic entry row seam; its body remains a collection
/// of role-aware AgentBlockHostView instances rather than flattened presentation.
@MainActor
final class CompletedReasoningDisclosureView: NSView {
    static let headerHeight = CGFloat(Space.xl + Space.xs)
    static let horizontalInset = CGFloat(Space.l)
    static let titleSpacing = CGFloat(Space.s)
    static let bodyTopSpacing = CGFloat(Space.xs)
    static let bodyBottomInset = CGFloat(Space.m)
    static let bodyBlockSpacing = CGFloat(Space.m)

    private(set) var disclosureButton = AgentDisclosureButton(frame: .zero)
    /// Reasoning rows reserve the SAME icon column tool rows do, so every row's
    /// text starts on one x. Without it a thought sat 32pt left of the searches
    /// beside it, which is a large part of what read as "the spacing is weird".
    private(set) var iconView = NSImageView(frame: .zero)
    private(set) var titleLabel = NSTextField(labelWithString: CompletedReasoningDisclosurePresenter.baseTitle)
    private(set) var bodyContainer = NSView(frame: .zero)
    private(set) var bodyHosts: [AgentBlockHostView] = []
    private(set) var presentation: CompletedReasoningDisclosurePresentation?
    private(set) var isExpanded = false

    var onNeedsRemeasure: (() -> Void)?

    private var context = AgentRenderContext(actions: .disabled, tokens: .transcript, appearance: .dark)
    private var registry: AgentBlockRendererRegistry = .production
    private let measurementCache = AgentBlockMeasurementCache()
    private var bodyHostsByBlockID: [AgentNodeID: AgentBlockHostView] = [:]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        identifier = NSUserInterfaceItemIdentifier("agent.completedReasoning")

        disclosureButton.target = self
        disclosureButton.action = #selector(toggleDisclosure(_:))

        titleLabel.font = NSFont.token(.label)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setAccessibilityElement(false)

        bodyContainer.setAccessibilityElement(false)

        addSubview(disclosureButton)
        iconView.image = CanvasSymbolImage.image(named: "bubble.left")
        iconView.imageScaling = .scaleProportionallyDown
        iconView.setAccessibilityElement(false)
        addSubview(iconView)
        addSubview(titleLabel)
        addSubview(bodyContainer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { presentation != nil }

    func apply(
        entry: AgentEntry?,
        authoritativeDuration: TimeInterval?,
        context: AgentRenderContext,
        registry: AgentBlockRendererRegistry = .production,
        onNeedsRemeasure: (() -> Void)? = nil
    ) {
        self.context = context
        self.registry = registry
        self.onNeedsRemeasure = onNeedsRemeasure
        guard let presentation = CompletedReasoningDisclosurePresenter.presentation(
            for: entry,
            authoritativeDuration: authoritativeDuration,
            actions: context.actions
        ) else {
            clear()
            return
        }

        self.presentation = presentation
        isHidden = false
        isExpanded = presentation.isExpanded
        titleLabel.stringValue = presentation.title
        disclosureButton.apply(expanded: isExpanded, title: presentation.title)
        identifier = NSUserInterfaceItemIdentifier("agent.completedReasoning.\(presentation.entryID.rawValue)")
        if isExpanded || !bodyHosts.isEmpty {
            reconcileBody(for: presentation.bodyBlocks, context: context)
        }
        bodyContainer.isHidden = !isExpanded
        applyTokens()
        applyAccessibility()
        needsLayout = true
    }

    /// `.plans/45` — the body hosts are placed by CONSTRAINTS, not frames.
    ///
    /// `AgentBlockHostView` pins its renderer view to its own edges with
    /// constraints, which puts the host inside the layout engine. Positioning it
    /// by frame anyway meant the engine solved it back to 0x0 on the next pass
    /// (keeping the origin from the autoresizing mirror) — so an expanded
    /// thought measured tall, drew nothing, and rendered its 1pt-wide text as
    /// the vertical dashes Dylan photographed. Every other install of this view
    /// in the transcript uses constraints; this one now does too.
    private var bodyHeightConstraints: [NSLayoutConstraint] = []
    private var bodyStackConstraints: [NSLayoutConstraint] = []

    private(set) var qaLayoutPassCount = 0
    private(set) var qaLastBodyWidth: CGFloat = -1

    override func layout() {
        super.layout()
        qaLayoutPassCount += 1
        let inset = Self.horizontalInset
        let buttonSide = CGFloat(Space.xxl)
        disclosureButton.frame = NSRect(
            x: inset,
            y: (Self.headerHeight - buttonSide) / 2,
            width: buttonSide,
            height: buttonSide
        )
        iconView.frame = NSRect(
            x: inset + buttonSide + CGFloat(Space.s),
            y: (Self.headerHeight - buttonSide) / 2,
            width: buttonSide, height: buttonSide
        )
        let titleX = iconView.frame.maxX + CGFloat(Space.m)
        titleLabel.frame = NSRect(
            x: titleX,
            y: (Self.headerHeight - titleLabel.intrinsicContentSize.height) / 2,
            width: max(1, bounds.maxX - inset - titleX),
            height: titleLabel.intrinsicContentSize.height
        )

        let bodyY = Self.headerHeight + Self.bodyTopSpacing
        let bodyWidth = max(1, bounds.width - inset * 2)
        qaLastBodyWidth = bodyWidth
        bodyContainer.frame = NSRect(
            x: inset,
            y: bodyY,
            width: bodyWidth,
            height: max(0, bounds.height - bodyY - Self.bodyBottomInset)
        )
        // Heights come from the shared measurement cache (a hit in steady
        // state) and are written to the constraints only when they actually
        // change, so a settled row costs no engine work per pass.
        for (index, host) in bodyHosts.enumerated() {
            guard let block = presentation?.bodyBlocks[index],
                  bodyHeightConstraints.indices.contains(index) else { continue }
            let height = Self.measuredBlockHeight(for: block, host: host, width: bodyWidth, context: context)
            if abs(bodyHeightConstraints[index].constant - height) > 0.5 {
                bodyHeightConstraints[index].constant = height
            }
        }
        bodyContainer.layoutSubtreeIfNeeded()
        bodyContainer.isHidden = !isExpanded
    }

    /// How far the expanded body extends BEYOND this view's own bounds. Zero
    /// when the row was remeasured to fit its content; positive means the
    /// thinking text is drawing over whatever follows it.
    /// Diagnostic: the view's own width, the body container's, and each body
    /// host's — so a witness can say WHICH collapsed rather than "it looks wrong".
    var qaBodyGeometryForChecks: (viewWidth: CGFloat, containerWidth: CGFloat, hostWidths: [CGFloat]) {
        (bounds.width, bodyContainer.frame.width, bodyHosts.map(\.frame.width))
    }

    var qaBodyDiagnosticForChecks: String {
        "passes=\(qaLayoutPassCount) lastBodyWidth=\(qaLastBodyWidth) "
        + "frames=\(bodyHosts.map(\.frame)) inContainer=\(bodyHosts.map { $0.superview === bodyContainer }) "
        + "hosts=\(bodyHosts.count) presentation=\(presentation != nil) blocks=\(presentation?.bodyBlocks.count ?? -1) "
        + "expanded=\(isExpanded) needsLayout=\(needsLayout) containerHidden=\(bodyContainer.isHidden) "
        + "containerFrame=\(bodyContainer.frame)"
    }

    var qaBodyOverflowForChecks: CGFloat {
        guard isExpanded, !bodyHosts.isEmpty else { return 0 }
        let deepest = bodyHosts.map { bodyContainer.frame.minY + $0.frame.maxY }.max() ?? 0
        return max(0, deepest - bounds.maxY)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    override func keyDown(with event: NSEvent) {
        let key = event.charactersIgnoringModifiers ?? event.characters ?? ""
        if key == " " || key == "\r" || key == "\n" {
            toggleDisclosure(event)
        } else {
            super.keyDown(with: event)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        guard presentation != nil else { return false }
        toggleDisclosure(nil)
        return true
    }

    static func measuredHeight(
        for entry: AgentEntry?,
        authoritativeDuration: TimeInterval?,
        width: CGFloat,
        context: AgentRenderContext,
        registry: AgentBlockRendererRegistry = .production
    ) -> CGFloat {
        guard let presentation = CompletedReasoningDisclosurePresenter.presentation(
            for: entry,
            authoritativeDuration: authoritativeDuration,
            actions: context.actions
        ) else { return 0 }
        guard presentation.isExpanded else { return headerHeight }
        let bodyWidth = max(1, width - horizontalInset * 2)
        let measurementHost = AgentBlockHostView(registry: registry)
        let bodyHeight = presentation.bodyBlocks.enumerated().reduce(CGFloat.zero) { total, pair in
            total
                + measuredBlockHeight(for: pair.element, host: measurementHost, width: bodyWidth, context: context)
                + (pair.offset + 1 < presentation.bodyBlocks.count ? bodyBlockSpacing : 0)
        }
        return ceil(headerHeight + bodyTopSpacing + bodyHeight + bodyBottomInset)
    }

    @objc private func toggleDisclosure(_ sender: Any?) {
        guard let presentation else { return }
        isExpanded.toggle()
        if isExpanded, bodyHosts.isEmpty {
            reconcileBody(for: presentation.bodyBlocks, context: context)
        }
        context.actions.setExpanded(isExpanded, blockID: presentation.entryID)
        disclosureButton.apply(expanded: isExpanded, title: presentation.title)
        bodyContainer.isHidden = !isExpanded
        applyAccessibility()
        invalidateIntrinsicContentSize()
        needsLayout = true
        onNeedsRemeasure?()
    }

    private func reconcileBody(for blocks: [AgentBlock], context: AgentRenderContext) {
        var reusableHosts = bodyHostsByBlockID
        var orderedHosts: [AgentBlockHostView] = []
        orderedHosts.reserveCapacity(blocks.count)

        for block in blocks {
            let host = reusableHosts.removeValue(forKey: block.id)
                ?? AgentBlockHostView(registry: registry, measurementCache: measurementCache)
            do {
                try host.apply(block: block, entryRole: .reasoning, context: context)
            } catch {
                host.resetForReuse()
                host.removeFromSuperview()
                continue
            }
            orderedHosts.append(host)
        }

        for removedHost in reusableHosts.values {
            removedHost.resetForReuse()
            removedHost.removeFromSuperview()
        }

        NSLayoutConstraint.deactivate(bodyStackConstraints + bodyHeightConstraints)
        bodyStackConstraints = []
        bodyHeightConstraints = []
        var previous: AgentBlockHostView?
        for host in orderedHosts {
            if host.superview !== bodyContainer {
                host.removeFromSuperview()
                bodyContainer.addSubview(host)
            }
            host.translatesAutoresizingMaskIntoConstraints = false
            let height = host.heightAnchor.constraint(equalToConstant: 1)
            height.priority = .required
            bodyHeightConstraints.append(height)
            bodyStackConstraints.append(contentsOf: [
                host.leadingAnchor.constraint(equalTo: bodyContainer.leadingAnchor),
                host.trailingAnchor.constraint(equalTo: bodyContainer.trailingAnchor),
                previous.map {
                    host.topAnchor.constraint(
                        equalTo: $0.bottomAnchor, constant: Self.bodyBlockSpacing)
                } ?? host.topAnchor.constraint(equalTo: bodyContainer.topAnchor),
            ])
            previous = host
        }
        NSLayoutConstraint.activate(bodyStackConstraints + bodyHeightConstraints)

        bodyHosts = orderedHosts
        bodyHostsByBlockID = Dictionary(uniqueKeysWithValues: orderedHosts.compactMap { host in
            guard let id = host.representedID else { return nil }
            return (id, host)
        })
    }

    private func clear() {
        presentation = nil
        isExpanded = false
        isHidden = true
        titleLabel.stringValue = CompletedReasoningDisclosurePresenter.baseTitle
        disclosureButton.apply(expanded: false, title: CompletedReasoningDisclosurePresenter.baseTitle)
        NSLayoutConstraint.deactivate(bodyStackConstraints + bodyHeightConstraints)
        bodyStackConstraints = []
        bodyHeightConstraints = []
        bodyHosts.forEach { host in
            host.resetForReuse()
            host.removeFromSuperview()
        }
        bodyHosts = []
        bodyHostsByBlockID = [:]
        setAccessibilityLabel(nil)
        setAccessibilityValue(nil)
        setAccessibilityChildren([])
    }

    private func applyTokens() {
        let theme = context.appearance
        titleLabel.textColor = context.tokens.secondaryText.color.nsColor(for: theme)
        iconView.contentTintColor = context.tokens.secondaryText.color.nsColor(for: theme)
        disclosureButton.contentTintColor = context.tokens.secondaryText.color.nsColor(for: theme)
    }

    private func applyAccessibility() {
        guard let presentation else { return }
        setAccessibilityLabel(presentation.accessibilityLabel)
        setAccessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        setAccessibilityHelp("Completed reasoning disclosure")
        disclosureButton.apply(expanded: isExpanded, title: presentation.title)
        let children: [NSView] = isExpanded ? [disclosureButton] + bodyHosts.map { $0 as NSView } : [disclosureButton]
        setAccessibilityChildren(children)
    }

    private static func measuredBlockHeight(
        for block: AgentBlock,
        host: AgentBlockHostView,
        width: CGFloat,
        context: AgentRenderContext
    ) -> CGFloat {
        (try? host.measuredHeight(for: block, entryRole: .reasoning, width: width, context: context))
            ?? AgentUnknownBlockView.height
    }
}
