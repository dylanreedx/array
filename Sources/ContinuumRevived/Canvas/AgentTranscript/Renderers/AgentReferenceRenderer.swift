import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedAgentUI

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
              case let .agentReference(payload) = block.payload else { return }
        view.setAccessibilityLabel("Subagent, \(payload.displayNameAtSpawn), open agent")
    }
}

@MainActor
final class AgentReferenceChipView: NSButton {
    static let height = CGFloat(38)
    private var blockID: AgentNodeID?
    private var payload: AgentReferencePayload?
    private var renderContext = AgentRenderContext(actions: .disabled, tokens: .transcript, appearance: .dark)

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

    func apply(blockID: AgentNodeID, payload: AgentReferencePayload, context: AgentRenderContext) {
        self.blockID = blockID
        self.payload = payload
        renderContext = context
        title = Self.safeName(payload.displayNameAtSpawn)
        toolTip = "Open subagent \(title)"
        identifier = NSUserInterfaceItemIdentifier("agent.reference.\(payload.agentID.uuidString)")
        setAccessibilityLabel("Subagent, \(title), open agent")
        applyTokens()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    private func applyTokens() {
        let theme = effectiveTokenTheme
        layer?.backgroundColor = renderContext.tokens.artifactSurface.color.cgColor(for: theme)
        contentTintColor = renderContext.tokens.secondaryText.color.nsColor(for: theme)
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
