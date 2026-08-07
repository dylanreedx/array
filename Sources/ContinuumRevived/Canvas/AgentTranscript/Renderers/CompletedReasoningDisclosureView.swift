import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedAgentUI

/// AppKit disclosure component for one completed reasoning entry. Production
/// routing is intentionally absent in this foundation ticket; the coordinator can
/// later mount this at the entry row seam when `AgentEntry.role == .reasoning`.
@MainActor
final class CompletedReasoningDisclosureView: NSView {
    static let headerHeight = CGFloat(Space.xxl + Space.m)
    static let horizontalInset = CGFloat(Space.l)
    static let titleSpacing = CGFloat(Space.s)
    static let bodyTopSpacing = CGFloat(Space.xs)
    static let bodyBottomInset = CGFloat(Space.m)
    static let bodyBlockSpacing = CGFloat(Space.m)

    private(set) var disclosureButton = AgentDisclosureButton(frame: .zero)
    private(set) var titleLabel = NSTextField(labelWithString: CompletedReasoningDisclosurePresenter.baseTitle)
    private(set) var bodyContainer = NSView(frame: .zero)
    private(set) var bodyHosts: [AgentBlockHostView] = []
    private(set) var presentation: CompletedReasoningDisclosurePresentation?
    private(set) var isExpanded = false

    var onNeedsRemeasure: (() -> Void)?

    private var context = AgentRenderContext(actions: .disabled, tokens: .transcript, appearance: .dark)
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
        onNeedsRemeasure: (() -> Void)? = nil
    ) {
        self.context = context
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

    override func layout() {
        super.layout()
        let inset = Self.horizontalInset
        let buttonSide = CGFloat(Space.xxl)
        disclosureButton.frame = NSRect(
            x: inset,
            y: (Self.headerHeight - buttonSide) / 2,
            width: buttonSide,
            height: buttonSide
        )
        let titleX = disclosureButton.frame.maxX + Self.titleSpacing
        titleLabel.frame = NSRect(
            x: titleX,
            y: (Self.headerHeight - titleLabel.intrinsicContentSize.height) / 2,
            width: max(1, bounds.maxX - inset - titleX),
            height: titleLabel.intrinsicContentSize.height
        )

        let bodyY = Self.headerHeight + Self.bodyTopSpacing
        let bodyWidth = max(1, bounds.width - inset * 2)
        var y: CGFloat = 0
        for (index, host) in bodyHosts.enumerated() {
            guard let block = presentation?.bodyBlocks[index] else { continue }
            let height = Self.measuredBlockHeight(for: block, host: host, width: bodyWidth, context: context)
            host.frame = NSRect(x: 0, y: y, width: bodyWidth, height: height)
            host.layoutSubtreeIfNeeded()
            y += height
            if index + 1 < bodyHosts.count { y += Self.bodyBlockSpacing }
        }
        bodyContainer.frame = NSRect(
            x: inset,
            y: bodyY,
            width: bodyWidth,
            height: max(0, bounds.height - bodyY - Self.bodyBottomInset)
        )
        bodyContainer.isHidden = !isExpanded
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
        context: AgentRenderContext
    ) -> CGFloat {
        guard let presentation = CompletedReasoningDisclosurePresenter.presentation(
            for: entry,
            authoritativeDuration: authoritativeDuration,
            actions: context.actions
        ) else { return 0 }
        guard presentation.isExpanded else { return headerHeight }
        let bodyWidth = max(1, width - horizontalInset * 2)
        let measurementHost = AgentBlockHostView()
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
                ?? AgentBlockHostView(measurementCache: measurementCache)
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

        for host in orderedHosts {
            if host.superview === bodyContainer {
                host.removeFromSuperviewWithoutNeedingDisplay()
            }
            bodyContainer.addSubview(host)
        }

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
