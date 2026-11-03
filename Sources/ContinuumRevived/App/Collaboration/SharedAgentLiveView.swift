import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import ContinuumRevivedCollaborationProtocol

/// A teammate's live view of the selected published agent, with full access:
/// the host's projection above, and the same composer a local agent has below.
/// It owns no runner. A prompt travels as an `AgentPromptRequest` and runs on
/// the owner's Mac, under the owner's CLI login; approvals stay with the owner.
/// It reads one agent at a time, so a hidden or unselected agent costs no
/// subscription.
@MainActor
final class SharedAgentLiveView: NSView {
    typealias Projection = Collaboration.AgentProjection
    typealias Reader = @MainActor (SharedArea.ID<SharedArea.Object>, Projection.Cursor?) async throws -> Projection.Read
    typealias TranscriptReader = @MainActor (SharedArea.ID<SharedArea.Object>, Collaboration.AgentTranscript.ReadRequest) async throws
        -> Collaboration.AgentTranscript.Read

    static let pollInterval: Duration = .seconds(1)
    /// How long the transcript lane holds a read open, and how soon a view on
    /// the rows fallback asks again whether the host now publishes the lane.
    static let transcriptWaitMilliseconds = 20_000
    static let transcriptRetryInterval: Duration = .seconds(10)
    let controller: SharedAreaController
    private let read: Reader
    private let readTranscript: TranscriptReader
    /// The owner's whole transcript, drawn by the host tile's renderer. Shown
    /// once the host publishes the lane; until then the projection rows stand in.
    let transcriptView = SharedAgentTranscriptView()
    private var transcriptTask: Task<Void, Never>?
    private(set) var transcriptLive = false
    /// The poll generation, for a check that drives `pollTranscript` itself.
    var qaTicket: UUID { generation }
    private var transcriptObject: SharedArea.ID<SharedArea.Object>?
    private(set) var object: SharedArea.ID<SharedArea.Object>?
    private(set) var replica = Projection.Replica()
    /// The shared agent's helpers as its host publishes them on the transcript
    /// lane: the chips' status, message senders and the lead's rollup.
    let helpers = SharedAgentHelperRoster()
    /// A helper's own transcript (`childStream`), opened from its chip, drawn
    /// by the same renderer. The host opens the helper's tile; here, its stream.
    let helperView = SharedAgentTranscriptView()
    private let helperBack = ChromeIconButton(symbolName: "chevron.left", accessibilityLabel: "Back to the shared agent")
    private let helperTitle = NSTextField(labelWithString: "")
    private(set) var openedHelper: UUID?
    private var helperTask: Task<Void, Never>?
    static let helperHeaderHeight: CGFloat = 28
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
    /// Mode A: sharing stopped. The status says so instead of the last phase.
    var ended: String? { didSet { if ended != oldValue { render() } } }
    /// Sends this view's prompts. Nil means no route to a host from here, and
    /// then no composer is offered.
    var prompter: SharedAgentHandoffController? { didSet { render() } }
    /// A participant's display name, for "Sam sent the last prompt", "Sam: …"
    /// and "Waiting for Dylan to approve": the label their presence carries,
    /// else the name the area records for them (a prompt outlives presence).
    lazy var personName: (SharedArea.ID<SharedArea.Person>) -> String? = { [weak controller] person in
        controller?.presence.first { $0.identity.person == person }?.label ?? controller?.memberNames[person]
    }

    var statusText: String { status.stringValue }
    var controlsText: String { controls.stringValue }
    var transcriptText: String { transcript.string }
    var lastPromptText: String { lastPrompt.stringValue }
    var statusColor: NSColor? { status.textColor }
    var isPolling: Bool { task != nil }
    var offersComposer: Bool { composer.superview === self && !composer.isHidden }
    let composer = AgentComposerView(frame: .zero, variant: .compactFreeform)

    private let status = NSTextField(labelWithString: "")
    private let controls = NSTextField(wrappingLabelWithString: "")
    private let transcript = NSTextView()
    private let scroll = NSScrollView()
    private let lastPrompt = NSTextField(labelWithString: "")
    private let send = ComposerActionButton(presentation: CollaborationHubView.action("Send", symbol: "arrow.up"))
    private var source: SharedArea.Source?
    private var sending = false
    /// What became of this view's own last prompt, said under the composer.
    private var delivery: String?
    override var isFlipped: Bool { true }

    init(controller: SharedAreaController, read: Reader? = nil, readTranscript: TranscriptReader? = nil) {
        self.controller = controller
        self.read = read ?? { [weak controller] object, cursor in
            guard let controller else { throw CancellationError() }
            return try await controller.readAgentProjection(object: object, cursor: cursor)
        }
        self.readTranscript = readTranscript ?? { [weak controller] object, request in
            guard let controller else { throw CancellationError() }
            return try await controller.readAgentTranscript(object: object, request: request)
        }
        super.init(frame: .zero)
        isHidden = true
        status.font = .token(.label); status.lineBreakMode = .byTruncatingTail
        controls.font = .token(.label); controls.maximumNumberOfLines = 2
        transcript.isEditable = false; transcript.isSelectable = true; transcript.isRichText = false
        transcript.textContainerInset = .init(width: 4, height: 6)
        transcript.autoresizingMask = [.width]
        scroll.documentView = transcript; scroll.hasVerticalScroller = true; scroll.drawsBackground = true
        lastPrompt.font = .token(.label); lastPrompt.lineBreakMode = .byTruncatingTail
        composer.onSubmitPrompt = { [weak self] text in self?.submit(text) }
        composer.setAccessibilityLabel("Prompt the shared agent")
        send.target = self; send.action = #selector(sendPressed)
        // The composer joins the view the first time it is offered, so a view
        // with no route to its host carries no composer subtree at all.
        for view in [status, controls, scroll, lastPrompt] { addSubview(view) }
        transcriptView.isHidden = true
        transcriptView.onOpenWebLink = { url, _ in NSWorkspace.shared.open(url) }
        addSubview(transcriptView)
        for view in [transcriptView, helperView] {
            view.agentStatus = helpers.statusSource
            view.agentMessageSenders = helpers.senderSource
            view.agentCharacters = helpers.characterSource
            view.onRevealAgent = { [weak self] agent, _ in self?.openHelper(agent) }
        }
        helperView.onOpenWebLink = { url, _ in NSWorkspace.shared.open(url) }
        helperTitle.font = .token(.label); helperTitle.lineBreakMode = .byTruncatingTail
        helperBack.target = self; helperBack.action = #selector(closeHelper)
        for view in [helperView, helperBack, helperTitle] as [NSView] { view.isHidden = true; addSubview(view) }
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
        // Transcript above, then the composer row: who sent the last prompt,
        // the editor, and Send, the way a local agent tile stacks them.
        var bottom = bounds.height
        if offersComposer {
            let sendSize = send.intrinsicContentSize
            let width = max(1, bounds.width - sendSize.width - CGFloat(Space.s))
            // One assignment, and only on change: a projection delta must not
            // resize the composer.
            if composer.frame.width != width { composer.setFrameSize(.init(width: width, height: max(composer.frame.height, 44))); composer.layoutSubtreeIfNeeded() }
            let height = max(composer.intrinsicContentSize.height, 36)
            let frame = NSRect(x: 0, y: bottom - height, width: width, height: height)
            if composer.frame != frame { composer.frame = frame }
            let sendFrame = NSRect(x: bounds.width - sendSize.width, y: (bottom - height / 2 - sendSize.height / 2).rounded(),
                                   width: sendSize.width, height: sendSize.height)
            if send.frame != sendFrame { send.frame = sendFrame }
            bottom -= height + CGFloat(Space.xs)
        }
        if !lastPrompt.isHidden {
            lastPrompt.frame = .init(x: 0, y: bottom - 18, width: bounds.width, height: 18)
            bottom -= 18 + CGFloat(Space.xs)
        }
        scroll.frame = .init(x: 0, y: 60, width: bounds.width, height: max(0, bottom - 60))
        transcript.frame.size.width = scroll.contentSize.width
        if transcriptView.frame != scroll.frame { transcriptView.frame = scroll.frame }
        if openedHelper != nil {
            let area = scroll.frame, header = Self.helperHeaderHeight
            let backSize = NSSize(width: ChromeIconButton.side, height: ChromeIconButton.side)
            helperBack.frame = .init(x: area.minX, y: area.minY + ((header - backSize.height) / 2).rounded(),
                                     width: backSize.width, height: backSize.height)
            let titleX = helperBack.frame.maxX + CGFloat(Space.s)
            helperTitle.frame = .init(x: titleX, y: area.minY + ((header - 18) / 2).rounded(), width: max(0, area.maxX - titleX), height: 18)
            let body = NSRect(x: area.minX, y: area.minY + header, width: area.width, height: max(0, area.height - header))
            if helperView.frame != body { helperView.frame = body }
        }
    }

    /// Called whenever the scene's selection or document changes.
    func show(object selected: SharedArea.ID<SharedArea.Object>?, in document: SharedArea.Document?) {
        let visible = selected != nil && document?.items.contains(where: { $0.id == selected && $0.kind == .agentObservation }) == true
        if isHidden == visible { isHidden = !visible; superview?.needsLayout = true }
        source = selected.flatMap { id in document?.items.first(where: { $0.id == id })?.source }
        guard visible, let selected else { stop(); return }
        guard selected != object || task == nil else { return }
        stop()
        object = selected; replica = .init(); confirmed = false; unavailable = false; delivery = nil
        if object != transcriptObject { transcriptView.reset(); helpers.update(nil); setTranscriptLive(false); transcriptObject = object }
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
        transcriptTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let outcome = await self?.pollTranscript(selected, ticket: ticket), self?.generation == ticket else { return }
                if outcome { continue }
                do { try await Task.sleep(for: Self.transcriptRetryInterval) } catch { return }
            }
        }
    }

    /// One long-polled read of the transcript lane. Returns false when the
    /// lane is not there (an older host or relay): the rows view stays, and the
    /// lane is asked again after `transcriptRetryInterval`.
    @discardableResult
    func pollTranscript(_ selected: SharedArea.ID<SharedArea.Object>, ticket: UUID, waitMilliseconds: Int? = nil) async -> Bool {
        let request = Collaboration.AgentTranscript.ReadRequest(stream: Collaboration.AgentTranscript.mainStream,
                                                                cursor: transcriptView.cursor,
                                                                waitMilliseconds: waitMilliseconds ?? Self.transcriptWaitMilliseconds)
        do {
            let value = try await readTranscript(selected, request)
            guard generation == ticket else { return false }
            transcriptView.receive(value)
            helpers.update(transcriptView.mirror.helpers)
            setTranscriptLive(true)
            return true
        } catch {
            guard generation == ticket else { return false }
            // Keep what was drawn; a relay restart answers "unavailable" until
            // the host's next checkpoint.
            if transcriptView.mirror.document.entries.isEmpty { setTranscriptLive(false) }
            return false
        }
    }

    private func setTranscriptLive(_ live: Bool) {
        guard transcriptLive != live else { return }
        transcriptLive = live
        transcriptView.isHidden = !live || openedHelper != nil
        scroll.isHidden = live
        needsLayout = true
    }

    func stop() {
        generation = UUID()
        task?.cancel(); task = nil
        transcriptTask?.cancel(); transcriptTask = nil
        closeHelper()
        object = nil
    }

    // MARK: - Helpers

    /// A chip's reveal: this agent's helper opens its own stream in place.
    /// Any other agent is not shared from here and does nothing.
    func openHelper(_ id: UUID) {
        guard let helper = helpers.helper(id), let object = transcriptObject else { return }
        closeHelper()
        openedHelper = id
        helperTitle.stringValue = helper.name
        helperView.reset()
        for view in [helperView, helperBack, helperTitle] as [NSView] { view.isHidden = false }
        transcriptView.isHidden = true; scroll.isHidden = true
        needsLayout = true
        let ticket = generation
        helperTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let live = await self?.pollHelper(object, id, ticket: ticket), self?.openedHelper == id else { return }
                if live { continue }
                do { try await Task.sleep(for: Self.transcriptRetryInterval) } catch { return }
            }
        }
    }

    /// One long-polled read of the opened helper's stream.
    @discardableResult
    func pollHelper(_ selected: SharedArea.ID<SharedArea.Object>, _ id: UUID, ticket: UUID, waitMilliseconds: Int? = nil) async -> Bool {
        let request = Collaboration.AgentTranscript.ReadRequest(stream: Collaboration.AgentTranscript.childStream(id),
                                                                cursor: helperView.cursor,
                                                                waitMilliseconds: waitMilliseconds ?? Self.transcriptWaitMilliseconds)
        do {
            let value = try await readTranscript(selected, request)
            guard generation == ticket, openedHelper == id else { return false }
            helperView.receive(value)
            return true
        } catch {
            return false
        }
    }

    /// Back to the shared agent's own transcript.
    @objc func closeHelper() {
        helperTask?.cancel(); helperTask = nil
        guard openedHelper != nil else { return }
        openedHelper = nil
        helperView.reset()
        for view in [helperView, helperBack, helperTitle] as [NSView] { view.isHidden = true }
        transcriptView.isHidden = !transcriptLive; scroll.isHidden = transcriptLive
        needsLayout = true
    }
    func qaCancelHelperPolling() { helperTask?.cancel(); helperTask = nil }
    /// The Back control, pressed. Checks drive the real control.
    func qaPressHelperBack() { helperBack.sendAction(helperBack.action, to: helperBack.target) }
    var helperTitleText: String { helperTitle.stringValue }

    /// One read. Returns true when the host has more retained frames ready.
    @discardableResult
    func poll(_ selected: SharedArea.ID<SharedArea.Object>, ticket: UUID) async -> Bool {
        let cursor = replica.cursor
        var more = false
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
            if case .frames(_, _, true) = value { more = true }
        } catch {
            guard generation == ticket else { return false }
            unavailable = true
        }
        // The receipt is read before anything is drawn, so one render is one
        // moment: "Waiting for Dylan to approve" never sits beside a "Queued"
        // the host has already moved past.
        await followDelivery()
        guard generation == ticket else { return false }
        render()
        return more
    }

    // MARK: - Full access

    @objc private func sendPressed() { composer.composerRequestedSend(composer.textView) }
    /// The Send button, pressed. Checks drive the real control.
    func qaPressSend() { send.sendAction(send.action, to: send.target) }

    /// Fire-and-forget from the composer; only a service-queued prompt clears
    /// the draft. Anything else leaves it to send again.
    private func submit(_ text: String) {
        guard !sending, let prompter, let object else { return }
        sending = true; delivery = "Sending…"; render()
        Task { @MainActor [weak self] in
            let outcome = await prompter.prompt(object: object, text: text)
            guard let self else { return }
            sending = false
            switch outcome {
            case .queued: composer.acceptCurrentSendIntent(); delivery = Self.deliveryText(prompter.receipt?.phase)
            case .refused: delivery = prompter.message.hasPrefix("Refused") ? prompter.message : "Refused. " + prompter.message
            case .unresolved: delivery = "Not confirmed yet. " + prompter.message
            }
            render()
        }
    }

    /// A queued prompt is followed to its outcome on the projection's beat.
    /// Updates what the controls line will say; the poll draws it.
    private func followDelivery() async {
        guard let prompter, !sending, delivery != nil else { return }
        if prompter.pending != nil { await prompter.checkDelivery() }
        await prompter.refreshReceipt()
        let next = prompter.message.hasPrefix("Refused") && prompter.receipt?.phase == .refused
            ? prompter.message : Self.deliveryText(prompter.receipt?.phase)
        delivery = next
    }

    static func deliveryText(_ phase: Collaboration.AgentDispatchPhase?) -> String? {
        switch phase {
        case .queued?, .claimed?: return "Queued. It runs on its host after the prompts ahead of it."
        case .dispatching?: return "Starting on its host."
        case .accepted?: return nil
        case .refused?: return "Refused by its host. Nothing was sent to the agent."
        case .uncertain?: return "Its host lost track of this prompt. Array will not resend it."
        case nil: return nil
        }
    }

    private func name(_ person: SharedArea.ID<SharedArea.Person>) -> String? {
        personName(person)
    }

    private func setText(_ field: NSTextField, _ value: String) { if field.stringValue != value { field.stringValue = value } }
    private func render() {
        let role = controller.scope?.role ?? .viewer
        guard let state = replica.state else {
            // Assigned only on change: a poll that learns nothing new must not
            // repaint (the zone draws these views under a transparent canvas).
            setText(status, unavailable ? "Live view unavailable" : "Connecting to the agent's host…")
            setText(controls, "Nothing from this agent is shown until its host publishes it.")
            if transcript.string != "" { transcript.string = "" }
            setComposer(offered: false)
            if !lastPrompt.isHidden { lastPrompt.isHidden = true; needsLayout = true }
            return
        }
        let offline = hostOnline == false
        let owner = source.map { name($0.owner) ?? "its owner" } ?? "its owner"
        let phase = state.phase == .needsAction ? "Waiting for \(owner) to approve" : Self.phase(state.phase)
        setText(status, ended ?? (phase + (offline ? " · host offline, last confirmed"
            : unavailable ? " · last confirmed" : confirmed ? " · live" : "")))
        let controls = Collaboration.AgentProjection.RemoteControls(host: state.capabilities, role: role)
        setText(self.controls, delivery ?? (offline ? "Its host is offline. A prompt sent now waits, and runs once when it returns."
            : Self.controlsText(state.capabilities, role: role)))
        let author = state.lastPrompt.map { last in
            SharedPromptAuthorship.label(mine: last.person == controller.identity.person, name: name(last.person), at: last.at)
        }
        if let author, lastPrompt.stringValue != author { lastPrompt.stringValue = author }
        if lastPrompt.isHidden != (author == nil) { lastPrompt.isHidden = author == nil; needsLayout = true }
        // Full access: anyone who may prompt gets the composer, busy or not. A
        // prompt sent mid-turn, or while the host is offline, waits on the
        // relay, in order, and runs once on the host; it is never dropped and
        // never runs anywhere else.
        setComposer(offered: prompter != nil && controls.queue, sending: sending)
        let text = Self.transcriptText(state, viewer: controller.identity.person, name: name)
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

    /// What a prompt from here does. Execution and approvals never move.
    static func controlsText(_ host: Projection.Capabilities, role: Collaboration.Role) -> String {
        guard host.locallyManaged else { return "Watched session. No controls are available from a shared view." }
        guard role.allows(.promptAgent) else { return "View only. Its owner and editors can prompt it." }
        return "Prompts run on its owner's Mac, in the order they arrive. Approvals stay with its owner."
    }

    private func setComposer(offered: Bool, sending: Bool = false) {
        if offered, composer.superview == nil { addSubview(composer); addSubview(send); composer.isHidden = true; send.isHidden = true }
        if composer.superview != nil, composer.isHidden == offered {
            composer.isHidden = !offered; send.isHidden = !offered
            needsLayout = true
        }
        // Only on change: a projection delta must not lay the button out again.
        let presentation = CollaborationHubView.action("Send", symbol: "arrow.up", enabled: !sending, loading: sending)
        if send.presentation != presentation { send.presentation = presentation }
    }

    /// Prompts read "You: …" for the viewer's own and "<Name>: …" for anyone
    /// else's, the owner's included.
    static func transcriptText(_ state: Projection.Snapshot, viewer: SharedArea.ID<SharedArea.Person>,
                               name: (SharedArea.ID<SharedArea.Person>) -> String?) -> String {
        var lines: [String] = []
        if state.omittedRows > 0 { lines.append("\(state.omittedRows) earlier entries are not shown.") }
        if state.history == .excluded && state.rows.isEmpty { lines.append("History from before it was shared is not included.") }
        for row in state.rows {
            switch row.kind {
            case .assistant: lines.append(row.text + (row.truncated ? " …" : ""))
            case .tool(let kind): lines.append("• \(tool(kind)) · \(row.status.map(status) ?? "running")")
            case .prompt(let person):
                let sender = person == viewer ? "You" : name(person) ?? "A teammate"
                lines.append("\(sender): " + row.text + (row.truncated ? " …" : ""))
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
        lastPrompt.textColor = TextToken.textSecondary.color.nsColor(in: self)
        helperTitle.textColor = TextToken.textPrimary.color.nsColor(in: self)
    }
}
