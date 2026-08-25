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
    /// The transcript's action-first row height, shared with every tool row.
    /// A subagent milestone is one line about work that happened elsewhere, so
    /// it sits in the same rhythm rather than in a taller card of its own.
    static let height = CGFloat(28)
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
        toolTip = "Open subagent \(Self.safeName(payload.displayNameAtSpawn))"
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
        // NO FILL. This was a filled `artifactSurface` slab spanning the whole row
        // — the one card left in a transcript that had already moved to unfilled
        // action-first rows, which is exactly why it read as a grey banner with an
        // id in it. The row is now the same shape as every tool row: a glyph, what
        // happened, and the state at the end.
        layer?.backgroundColor = nil
        let accent = currentInboxState?.accent
        contentTintColor = (accent?.color ?? renderContext.tokens.secondaryText.color)
            .nsColor(for: theme)
        attributedTitle = composedTitle(theme: theme)
    }

    /// `Name · Working` — the name in primary text, the live state trailing it in
    /// secondary. Status is COMPOSED here rather than stored, so it still never
    /// touches the document; and it is rendered as TEXT rather than only as a
    /// tint, because a colour alone told the reader nothing about what the child
    /// was doing.
    private func composedTitle(theme: TokenTheme) -> NSAttributedString {
        let name = Self.safeName(payload?.displayNameAtSpawn ?? "")
        let composed = NSMutableAttributedString(
            string: name,
            attributes: [
                .font: NSFont.token(.label),
                .foregroundColor: renderContext.tokens.primaryText.color.nsColor(for: theme)
            ])
        guard let label = currentInboxState?.label, !label.isEmpty else { return composed }
        composed.append(NSAttributedString(
            string: "  ·  \(label)",
            attributes: [
                .font: NSFont.token(.label),
                .foregroundColor: renderContext.tokens.secondaryText.color.nsColor(for: theme)
            ]))
        return composed
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
