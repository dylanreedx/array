import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Foundation

/// A stack view with top-left origin so a transcript inside an NSScrollView
/// starts at the top and grows downward (AppKit document coords are otherwise
/// bottom-left, which parks a short transcript at the bottom of the clip view).
@MainActor
final class FlippedStackView: NSStackView {
    override var isFlipped: Bool { true }
}

@MainActor
final class ManagedAgentTileNSView: TileNSView {
    /// P1.9: the three views this tile paints layer fills on are stored so
    /// `applyTokens()` can re-assign them on an appearance change. `wantsLayer` is
    /// set here, at construction, so `applyTokens()` is order-independent — it runs
    /// once from `TileNSView.init`, before these are placed in the tree.
    private let contentBackdrop: NSView = {
        let view = NSView()
        view.wantsLayer = true
        return view
    }()
    private let composeBackdrop: NSView = {
        let view = NSView()
        view.wantsLayer = true
        return view
    }()
    private let header: NSStackView = {
        let stack = NSStackView()
        stack.wantsLayer = true
        return stack
    }()
    private let glyphLabel = NSTextField(labelWithString: "")
    private let nameLabel = NSTextField(labelWithString: "")
    private let phaseLabel = NSTextField(labelWithString: "")
    private let elapsedLabel = NSTextField(labelWithString: "0s")
    private let cardStack = FlippedStackView()
    private let approvalDock = ApprovalDockView()
    private let composeField = NSTextField()
    private let runButton = NSButton()
    private var cardViewsById: [String: TranscriptCardView] = [:]
    private var inputCardViewsByRequestId: [String: UserInputCardView] = [:]
    private var pendingApprovals: [String: ApprovalDockRequest] = [:]
    private var pendingUserInputs: [String: AgentUserInputRequest] = [:]
    private var model: ManagedAgentTranscriptModel
    private var descriptor: AgentDescriptor
    private var startedAt: Date?
    private var promptInFlight = false
    private let threadId: String
    var onApprovalDecision: ((String, ApprovalDecision) -> Void)?
    var onUserInputSubmit: ((String, UserInputAnswers) -> Void)?
    /// Fired when the user submits a prompt from the tile's compose row.
    /// The app wires this to a PiAgentRunner (ticket 88.4b). Minimal now; the
    /// framework ComposeBox component supersedes it later.
    var onSubmitPrompt: ((String) -> Void)?

    init(tile: Tile, threadId: String = "thread-main", descriptor: AgentDescriptor? = nil) {
        self.threadId = threadId
        self.model = ManagedAgentTranscriptModel(threadId: threadId)
        self.descriptor = descriptor ?? AgentDescriptor(
            agentKind: .managed,
            worktreePath: "",
            status: .configuring,
            statusUpdatedAt: Date()
        )
        super.init(tile: tile)
        setContentView(makeContentView())
        applyHeader(status: self.descriptor.status)
        applyComposeAvailability()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The thread this tile's transcript filters on. The app rebinds incoming
    /// provider events to this before ingest (ticket 88.4b).
    var wiringThreadId: String { threadId }
    var transcriptCardCount: Int { model.cards.count }
    var activeToolCount: Int { model.activeToolCount }
    var currentAgentStatus: AgentStatus { descriptor.status }

    /// Shows the prompt the user just submitted as its own "you" card.
    func appendUserPrompt(_ text: String) {
        model.appendUserPrompt(text)
        reconcileCards()
        scrollTranscriptToBottom()
    }

    func ingest(_ event: AgentRuntimeEvent) {
        if startedAt == nil {
            if case .turnStarted = event { startedAt = Date() }
        }
        // A prompt is done once the agent settles or a turn ends. Clearing the
        // in-flight latch here re-enables the compose row (see submitPrompt).
        switch event {
        case .turnCompleted, .runtimeError,
             .sessionStateChanged(.ready), .sessionStateChanged(.stopped), .sessionStateChanged(.error):
            promptInFlight = false
        default:
            break
        }
        model.ingest(event)
        updatePendingApproval(from: event)
        updatePendingUserInput(from: event)
        descriptor.status = model.currentStatus
        descriptor.statusUpdatedAt = Date()
        agentStatus = model.currentStatus
        applyHeader(status: model.currentStatus)
        applyComposeAvailability()
        approvalDock.pendingRequest = pendingApprovals.values.sorted { $0.requestId < $1.requestId }.first
        reconcileCards()
        scrollTranscriptToBottom()
    }

    /// This tile's own layer fills, on top of the base tile's (P1.9). Values are
    /// still the shipped dark literals — P1.10 swaps them for `DesignTokens`.
    override func applyTokens() {
        super.applyTokens()
        contentBackdrop.layer?.backgroundColor = NSColor(red: 0.08, green: 0.10, blue: 0.13, alpha: 1).cgColor
        header.layer?.backgroundColor = NSColor(red: 0.11, green: 0.13, blue: 0.16, alpha: 1).cgColor
        composeBackdrop.layer?.backgroundColor = NSColor(red: 0.11, green: 0.13, blue: 0.16, alpha: 1).cgColor
    }

    private func makeContentView() -> NSView {
        let root = contentBackdrop

        configureHeader()

        cardStack.orientation = .vertical
        cardStack.alignment = .leading
        cardStack.spacing = 8
        cardStack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        cardStack.translatesAutoresizingMaskIntoConstraints = false
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.documentView = cardStack
        // Pin the document stack to the clip view: full width, top-anchored,
        // free to grow downward (vertical scroll). Without this the stack has
        // no resolved size and its cards never lay out — the transcript renders
        // blank even though the model has cards.
        NSLayoutConstraint.activate([
            cardStack.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            cardStack.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            cardStack.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            cardStack.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor)
        ])

        approvalDock.setContentCompressionResistancePriority(.required, for: .vertical)
        approvalDock.onDecision = { [weak self] decision in
            guard let self, let request = self.approvalDock.pendingRequest else { return }
            self.onApprovalDecision?(request.requestId, decision)
            self.ingest(.requestResolved(threadId: self.threadId, requestId: request.requestId, decision: decision.rawValue))
        }

        let composeRow = makeComposeRow()

        let layout = NSStackView(views: [header, scrollView, approvalDock, composeRow])
        layout.orientation = .vertical
        layout.spacing = 0
        layout.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(layout)
        NSLayoutConstraint.activate([
            layout.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            layout.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            layout.topAnchor.constraint(equalTo: root.topAnchor),
            layout.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            header.heightAnchor.constraint(equalToConstant: 52),
            approvalDock.heightAnchor.constraint(equalToConstant: 92),
            composeRow.heightAnchor.constraint(equalToConstant: 44),
            // A vertical NSStackView centers rows at their FITTING width unless
            // pinned, so the transcript column was sizing itself to the longest
            // message's single-line width and floating in the middle of the
            // tile (with the scroller stranded mid-tile). Pin every row to the
            // stack's width.
            header.widthAnchor.constraint(equalTo: layout.widthAnchor),
            scrollView.widthAnchor.constraint(equalTo: layout.widthAnchor),
            approvalDock.widthAnchor.constraint(equalTo: layout.widthAnchor),
            composeRow.widthAnchor.constraint(equalTo: layout.widthAnchor)
        ])
        return root
    }

    private func updatePendingApproval(from event: AgentRuntimeEvent) {
        switch event {
        case .requestOpened(let threadId, let requestId, let kind) where threadId == self.threadId:
            pendingApprovals[requestId] = ApprovalDockRequest(requestId: requestId, kind: kind, detail: nil)
        case .requestResolved(let threadId, let requestId, _) where threadId == self.threadId:
            pendingApprovals.removeValue(forKey: requestId)
        default:
            break
        }
    }

    private func updatePendingUserInput(from event: AgentRuntimeEvent) {
        switch event {
        case .userInputRequested(let threadId, let requestId, let questions) where threadId == self.threadId:
            let question = questions.first?.prompt ?? "What should I answer?"
            let request = AgentUserInputRequest(requestId: requestId, tileId: tile.id, question: question)
            pendingUserInputs[requestId] = request
            insertUserInputCard(for: request)
        case .userInputResolved(let threadId, let requestId) where threadId == self.threadId:
            pendingUserInputs.removeValue(forKey: requestId)
            inputCardViewsByRequestId[requestId]?.dismissAnimated()
            inputCardViewsByRequestId.removeValue(forKey: requestId)
        default:
            break
        }
    }

    private func configureHeader() {
        glyphLabel.font = .systemFont(ofSize: 18, weight: .bold)
        glyphLabel.alignment = .center
        glyphLabel.widthAnchor.constraint(equalToConstant: 28).isActive = true
        nameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingTail
        phaseLabel.font = .systemFont(ofSize: 12, weight: .medium)
        phaseLabel.textColor = .secondaryLabelColor
        elapsedLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        elapsedLabel.textColor = .secondaryLabelColor  // tertiary = 2.26:1, fails AA

        let textStack = NSStackView(views: [nameLabel, phaseLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 10
        header.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        header.addArrangedSubview(glyphLabel)
        header.addArrangedSubview(textStack)
        header.addArrangedSubview(NSView())
        header.addArrangedSubview(elapsedLabel)
    }

    private func makeComposeRow() -> NSView {
        let row = composeBackdrop

        composeField.placeholderString = "Send a prompt to the agent…"
        composeField.font = .systemFont(ofSize: 12)
        composeField.bezelStyle = .roundedBezel
        composeField.target = self
        composeField.action = #selector(submitPrompt)
        composeField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        runButton.title = "Run"
        runButton.bezelStyle = .rounded
        runButton.keyEquivalent = "\r"
        runButton.target = self
        runButton.action = #selector(submitPrompt)

        let stack = NSStackView(views: [composeField, runButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ])
        return row
    }

    @objc private func submitPrompt() {
        let prompt = composeField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !composeIsBusy else { return }
        // Latch immediately: status may not read .working until the first event
        // streams back, and without this a fast second Enter/click would submit
        // a duplicate prompt in that window. Cleared when the turn settles.
        promptInFlight = true
        composeField.stringValue = ""
        applyComposeAvailability()
        onSubmitPrompt?(prompt)
    }

    private var composeIsBusy: Bool { promptInFlight || descriptor.status == .working }

    private func applyComposeAvailability() {
        composeField.isEnabled = !composeIsBusy
        runButton.isEnabled = !composeIsBusy
    }

    private func applyHeader(status: AgentStatus) {
        nameLabel.stringValue = tile.title
        let display = StatusChipPresenter.display(for: status)
        glyphLabel.stringValue = display.glyph
        // The bare glyph shape, so the accent — and `.dark` because this header
        // paints its own dark-only literal fill (allowlisted, owner P1.10; when
        // that adopts `SurfaceToken.tileChrome` the theme comes with it).
        glyphLabel.textColor = StatusChipNSView.nsColor(display.accent.resolved(for: .dark))
        phaseLabel.stringValue = display.label
        if let startedAt, status == .working || status == .needsAttention {
            elapsedLabel.stringValue = "\(max(0, Int(Date().timeIntervalSince(startedAt))))s"
        }
    }

    /// Keeps the newest output visible. Without this the clip view stays pinned
    /// at the top and the reply to the prompt you just sent lands off-screen.
    private func scrollTranscriptToBottom() {
        guard let scrollView = cardStack.enclosingScrollView else { return }
        cardStack.layoutSubtreeIfNeeded()
        let maxY = max(0, cardStack.bounds.height - scrollView.contentView.bounds.height)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: maxY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func reconcileCards() {
        for card in model.cards {
            if let view = cardViewsById[card.id] {
                view.apply(card)
            } else {
                let view = TranscriptCardView(card: card)
                cardViewsById[card.id] = view
                cardStack.addArrangedSubview(view)
                view.translatesAutoresizingMaskIntoConstraints = false
                view.widthAnchor.constraint(equalTo: cardStack.widthAnchor, constant: -24).isActive = true
            }
        }
    }

    private func insertUserInputCard(for request: AgentUserInputRequest) {
        if let existing = inputCardViewsByRequestId[request.requestId] {
            existing.configure(question: request.question)
            return
        }
        let card = UserInputCardView()
        card.configure(question: request.question)
        card.onSubmit = { [weak self, requestId = request.requestId] answer in
            self?.respondToUserInput(requestId: requestId, answer: answer)
        }
        inputCardViewsByRequestId[request.requestId] = card
        cardStack.addArrangedSubview(card)
        card.translatesAutoresizingMaskIntoConstraints = false
        card.widthAnchor.constraint(equalTo: cardStack.widthAnchor, constant: -24).isActive = true
    }

    func respondToUserInput(requestId: String, answer: String) {
        guard var request = pendingUserInputs[requestId] else { return }
        request.status = .resolved
        request.answer = answer
        pendingUserInputs[requestId] = request
        onUserInputSubmit?(requestId, UserInputAnswers(answers: ["response": answer]))
        ingest(.userInputResolved(threadId: threadId, requestId: requestId))
    }

    // P1.8 deleted this view's private glyph/phase/colour maps. They were one of
    // the three disagreeing glyph sets (`◌` here meant *configuring*, in the
    // sidebar it meant *stale*) and they had drifted from the board's hues.
    // Everything now comes from `StatusChipPresenter`.

    func setPendingApprovalForQA(kind: ApprovalKind, requestId: String, detail: String) {
        let request = ApprovalDockRequest(requestId: requestId, kind: kind, detail: detail)
        pendingApprovals[requestId] = request
        approvalDock.pendingRequest = request
        agentStatus = .needsAttention
        applyHeader(status: .needsAttention)
    }

    var qaApprovalDockVisible: Bool { !approvalDock.isHidden }
    var qaApprovalDockDetailText: String { approvalDock.qaDetailText }
    var qaApprovalDockButtonTitles: [String] { approvalDock.qaButtonTitles }
    func qaClickApproval(_ decision: ApprovalDecision) { approvalDock.qaClick(decision) }
    var qaPendingUserInputCount: Int { pendingUserInputs.values.filter { $0.status == .pending }.count }
    var qaUserInputCardCount: Int { inputCardViewsByRequestId.count }
    func qaUserInputQuestion(requestId: String) -> String? {
        inputCardViewsByRequestId[requestId]?.qaQuestionText
    }
    func qaSubmitUserInput(requestId: String, answer: String) {
        inputCardViewsByRequestId[requestId]?.qaSubmit(answer)
    }

    var qaComposeEnabled: Bool { composeField.isEnabled }
    func qaSubmitPrompt(_ prompt: String) {
        composeField.stringValue = prompt
        submitPrompt()
    }
    var qaTranscriptText: String {
        model.cards.map { "[\($0.title)] \($0.body)" }.joined(separator: "\n")
    }
    var qaLastAssistantCardBody: String? {
        model.cards.last { $0.title == "assistant" }?.body
    }
}
