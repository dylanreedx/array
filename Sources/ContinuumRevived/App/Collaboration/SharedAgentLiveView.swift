import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import ContinuumRevivedCollaborationProtocol

/// A teammate's read-only live view of the selected published agent. It only
/// reads the host's projection: it owns no runner, sends nothing and reads one
/// agent at a time, so a hidden or unselected agent costs no subscription.
@MainActor
final class SharedAgentLiveView: NSView {
    typealias Projection = Collaboration.AgentProjection
    typealias Reader = @MainActor (SharedArea.ID<SharedArea.Object>, Projection.Cursor?) async throws -> Projection.Read

    static let pollInterval: Duration = .seconds(1)
    let controller: SharedAreaController
    private let read: Reader
    private(set) var object: SharedArea.ID<SharedArea.Object>?
    private(set) var replica = Projection.Replica()
    private(set) var reads = 0
    private(set) var resnapshots = 0
    private var task: Task<Void, Never>?
    private var generation = UUID()
    /// Last time the host's projection answered, for "last confirmed" wording.
    private var confirmed = false
    private var unavailable = false
    /// The host's liveness as the area reports it (COL-06). nil = not known;
    /// false = its host is gone, so the view is history and nothing is offered.
    var hostOnline: Bool? { didSet { if hostOnline != oldValue { render() } } }

    var statusText: String { status.stringValue }
    var controlsText: String { controls.stringValue }
    var transcriptText: String { transcript.string }
    var statusColor: NSColor? { status.textColor }
    var isPolling: Bool { task != nil }

    private let status = NSTextField(labelWithString: "")
    private let controls = NSTextField(wrappingLabelWithString: "")
    private let transcript = NSTextView()
    private let scroll = NSScrollView()
    override var isFlipped: Bool { true }

    init(controller: SharedAreaController, read: Reader? = nil) {
        self.controller = controller
        self.read = read ?? { [weak controller] object, cursor in
            guard let controller else { throw CancellationError() }
            return try await controller.readAgentProjection(object: object, cursor: cursor)
        }
        super.init(frame: .zero)
        isHidden = true
        status.font = .token(.label); status.lineBreakMode = .byTruncatingTail
        controls.font = .token(.label); controls.maximumNumberOfLines = 2
        transcript.isEditable = false; transcript.isSelectable = true; transcript.isRichText = false
        transcript.textContainerInset = .init(width: 4, height: 6)
        transcript.autoresizingMask = [.width]
        scroll.documentView = transcript; scroll.hasVerticalScroller = true; scroll.drawsBackground = true
        for view in [status, controls, scroll] { addSubview(view) }
        setAccessibilityRole(.group)
        setAccessibilityLabel("Live agent view")
        applyAppearance()
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        status.frame = .init(x: 0, y: 0, width: bounds.width, height: 18)
        controls.frame = .init(x: 0, y: 22, width: bounds.width, height: 34)
        scroll.frame = .init(x: 0, y: 60, width: bounds.width, height: max(0, bounds.height - 60))
        transcript.frame.size.width = scroll.contentSize.width
    }

    /// Called whenever the scene's selection or document changes.
    func show(object selected: SharedArea.ID<SharedArea.Object>?, in document: SharedArea.Document?) {
        let visible = selected != nil && document?.items.contains(where: { $0.id == selected && $0.kind == .agentObservation }) == true
        if isHidden == visible { isHidden = !visible; superview?.needsLayout = true }
        guard visible, let selected else { stop(); return }
        guard selected != object || task == nil else { return }
        stop()
        object = selected; replica = .init(); confirmed = false; unavailable = false
        render()
        let ticket = UUID(); generation = ticket
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                // Holds the view only for the read itself, never across the wait.
                guard let more = await self?.poll(selected, ticket: ticket), self?.generation == ticket else { return }
                if more { continue }
                do { try await Task.sleep(for: Self.pollInterval) } catch { return }
            }
        }
    }

    func stop() {
        generation = UUID()
        task?.cancel(); task = nil
        object = nil
    }

    /// One read. Returns true when the host has more retained frames ready.
    @discardableResult
    func poll(_ selected: SharedArea.ID<SharedArea.Object>, ticket: UUID) async -> Bool {
        let cursor = replica.cursor
        do {
            let value = try await read(selected, cursor)
            guard generation == ticket else { return false }
            reads += 1
            if case .resnapshot = value { resnapshots += 1 }
            switch replica.receive(value) {
            case .needsResnapshot:
                // Never guess across a gap: drop the cursor and ask for state.
                replica = .init()
                render(); return true
            case .applied:
                confirmed = true; unavailable = false
            }
            render()
            if case .frames(_, _, true) = value { return true }
        } catch {
            guard generation == ticket else { return false }
            unavailable = true
            render()
        }
        return false
    }

    private func render() {
        guard let state = replica.state else {
            status.stringValue = unavailable ? "Live view unavailable" : "Connecting to the agent's host…"
            controls.stringValue = "Nothing from this agent is shown until its host publishes it."
            if transcript.string != "" { transcript.string = "" }
            return
        }
        let offline = hostOnline == false
        status.stringValue = Self.phase(state.phase) + (offline ? " · host offline, last confirmed"
            : unavailable ? " · last confirmed" : confirmed ? " · live" : "")
        controls.stringValue = offline ? "Its host is offline. Nothing can reach this agent until it returns."
            : Self.controlsText(state.capabilities)
        let text = Self.transcriptText(state)
        if transcript.string != text {
            let pinned = scroll.verticalScroller.map { $0.floatValue >= 0.99 } ?? true
            transcript.string = text
            if pinned { transcript.scrollToEndOfDocument(nil) }
        }
    }

    static func phase(_ phase: Projection.Phase) -> String {
        switch phase {
        case .ready: return "Idle"
        case .starting: return "Starting"
        case .working: return "Working"
        case .needsAction: return "Waiting on its owner"
        case .failed: return "Last turn failed"
        case .stopped: return "Stopped"
        }
    }

    /// Host facts, then what this view can do with them: nothing directly.
    static func controlsText(_ host: Projection.Capabilities) -> String {
        guard host.locallyManaged else { return "Watched session. No controls are available from a shared view." }
        let facts = [(host.canSend, "send"), (host.canQueue, "queue"), (host.canSteer, "steer"), (host.canInterrupt, "interrupt")]
            .filter(\.0).map(\.1)
        let now = facts.isEmpty ? "Its host accepts no input right now." : "Its host can " + facts.joined(separator: ", ") + " now."
        return now + " Steer, interrupt and approvals stay with its owner; prompts go through a handoff."
    }

    static func transcriptText(_ state: Projection.Snapshot) -> String {
        var lines: [String] = []
        if state.omittedRows > 0 { lines.append("\(state.omittedRows) earlier entries are not shown.") }
        if state.history == .excluded && state.rows.isEmpty { lines.append("History from before it was shared is not included.") }
        for row in state.rows {
            switch row.kind {
            case .assistant: lines.append(row.text + (row.truncated ? " …" : ""))
            case .tool(let kind): lines.append("• \(tool(kind)) · \(row.status.map(status) ?? "running")")
            }
        }
        return lines.joined(separator: "\n\n")
    }

    private static func tool(_ kind: Projection.ToolKind) -> String {
        switch kind {
        case .command: return "Command"
        case .fileChange: return "File change"
        case .mcpTool: return "Tool"
        case .webSearch: return "Web search"
        case .plan: return "Plan"
        case .subagent: return "Subagent"
        case .other: return "Step"
        }
    }
    private static func status(_ value: Projection.ToolStatus) -> String {
        switch value { case .running: return "running"; case .completed: return "done"; case .failed: return "failed"; case .declined: return "declined" }
    }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); applyAppearance() }
    private func applyAppearance() {
        status.textColor = TextToken.textPrimary.color.nsColor(in: self)
        controls.textColor = TextToken.textSecondary.color.nsColor(in: self)
        transcript.font = .token(.body)
        transcript.textColor = TextToken.textPrimary.color.nsColor(in: self)
        transcript.backgroundColor = SurfaceToken.tileBody.color.nsColor(in: self)
        scroll.backgroundColor = SurfaceToken.tileBody.color.nsColor(in: self)
    }
}
