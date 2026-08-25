import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedAgentUI

/// C10: `AgentReferencePayload` deliberately carries no status — a status tick
/// must never rewrite the semantic document. This is the render-time seam a
/// chip uses instead, entirely outside the document: `current` resolves the
/// agent's status right now, and `subscribe`/`unsubscribe` let exactly the
/// chips currently on screen hear about a change. At 16 fanned-out children an
/// unconditional subscription per chip would be a leak the transcript's own
/// virtualization (6 live hosts for 10,000 rows) exists to avoid, so a chip
/// subscribes only while it is actually representing an agent and tears the
/// subscription down the moment it stops (reused for a different block, or
/// deallocated).
struct AgentReferenceStatusSource: @unchecked Sendable {
    let current: (UUID) -> InboxState?
    let subscribe: (UUID, @escaping (InboxState?) -> Void) -> UUID?
    let unsubscribe: (UUID) -> Void

    static let unavailable = AgentReferenceStatusSource(
        current: { _ in nil },
        subscribe: { _, _ in nil },
        unsubscribe: { _ in }
    )
}

/// A transcript milestone for one real child agent. The block owns only stable
/// identity; the host resolves current status and tile placement when activated.
@MainActor
final class AgentReferenceRenderer: AgentBlockRendering {
    let kind: AgentBlockKind = .agentReference

    func makeView() -> NSView { AgentReferenceChipView(frame: .zero) }

    func update(view: NSView, block: AgentBlock, context: AgentRenderContext) {
        guard let view = view as? AgentReferenceChipView,
              case let .agentReference(payload) = block.payload else { return }
        view.apply(blockID: block.id, payload: payload, context: context)
    }

    func measure(block: AgentBlock, width: CGFloat, context: AgentRenderContext) -> CGFloat {
        AgentReferenceChipView.height
    }

    func updateAccessibility(view: NSView, block: AgentBlock, context: AgentRenderContext) {
        guard let view = view as? AgentReferenceChipView,
              case .agentReference = block.payload else { return }
        view.refreshAccessibilityLabel()
    }
}

@MainActor
final class AgentReferenceChipView: NSButton {
    static let height = CGFloat(38)
    private var blockID: AgentNodeID?
    private var payload: AgentReferencePayload?
    private var renderContext = AgentRenderContext(actions: .disabled, tokens: .transcript, appearance: .dark)
    private var statusSource: AgentReferenceStatusSource = .unavailable
    private var statusSubscriptionToken: UUID?
    /// Never read from `AgentReferencePayload` — resolved and refreshed purely
    /// through `statusSource`, so a status tick can never touch the document.
    private var currentInboxState: InboxState?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        bezelStyle = .inline
        setButtonType(.momentaryChange)
        target = self
        action = #selector(activate(_:))
        image = CanvasSymbolImage.image(named: "person.crop.circle.badge.arrow.forward")
        imagePosition = .imageLeading
        alignment = .left
        font = NSFont.token(.label)
        focusRingType = .exterior
        wantsLayer = true
        layer?.cornerRadius = CGFloat(AgentTileRadius.artifact)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let statusSubscriptionToken {
            statusSource.unsubscribe(statusSubscriptionToken)
        }
    }

    func apply(blockID: AgentNodeID, payload: AgentReferencePayload, context: AgentRenderContext) {
        let agentChanged = self.payload?.agentID != payload.agentID
        self.blockID = blockID
        self.payload = payload
        renderContext = context
        title = Self.safeName(payload.displayNameAtSpawn)
        toolTip = "Open subagent \(title)"
        identifier = NSUserInterfaceItemIdentifier("agent.reference.\(payload.agentID.uuidString)")
        // A reused host (virtualization) or a rebuilt context both mean the
        // OLD subscription may be watching the wrong agent or calling back
        // through a stale closure; re-subscribing on either is what keeps
        // "6 live hosts for 10,000 rows" from also being 10,000 live
        // subscriptions.
        if agentChanged || statusSubscriptionToken == nil {
            subscribeStatus(agentID: payload.agentID, source: context.agentStatus)
        } else {
            statusSource = context.agentStatus
        }
        currentInboxState = statusSource.current(payload.agentID)
        applyTokens()
        refreshAccessibilityLabel()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    private func subscribeStatus(agentID: UUID, source: AgentReferenceStatusSource) {
        if let statusSubscriptionToken {
            statusSource.unsubscribe(statusSubscriptionToken)
        }
        statusSource = source
        statusSubscriptionToken = source.subscribe(agentID) { [weak self] state in
            guard let self, self.payload?.agentID == agentID else { return }
            self.currentInboxState = state
            self.applyTokens()
            self.refreshAccessibilityLabel()
        }
    }

    private func applyTokens() {
        let theme = effectiveTokenTheme
        layer?.backgroundColor = renderContext.tokens.artifactSurface.color.cgColor(for: theme)
        if let accent = currentInboxState?.accent {
            contentTintColor = accent.color.nsColor(for: theme)
        } else {
            contentTintColor = renderContext.tokens.secondaryText.color.nsColor(for: theme)
        }
    }

    func refreshAccessibilityLabel() {
        guard let payload else { return }
        let name = Self.safeName(payload.displayNameAtSpawn)
        if let label = currentInboxState?.label {
            setAccessibilityLabel("Subagent, \(name), \(label), open agent")
        } else {
            setAccessibilityLabel("Subagent, \(name), open agent")
        }
    }

    @objc private func activate(_ sender: Any?) {
        guard let blockID, let payload else { return }
        renderContext.actions.perform(.revealAgent(
            blockID: blockID,
            agentID: payload.agentID,
            parentAgentID: payload.parentAgentID
        ))
    }

    private static func safeName(_ value: String) -> String {
        let line = value.split(whereSeparator: { $0.isNewline }).first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return line.isEmpty ? "Subagent" : String(line.prefix(80))
    }
}
