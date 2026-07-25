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
    ///
    /// P1.10: these three are plain `NSView` containers, so `UIProbeAppearance`'s
    /// owned-layer rule (a view never answers for a subview's layer) cannot see
    /// them — this tile is the view that paints them, so it hands them to the gate
    /// through `qaTokenPaintedLayers`.
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

    /// This tile's own layer fills, on top of the base tile's (P1.9), now on
    /// `DesignTokens` (P1.10): the content area is `tileBody` and the header and
    /// compose strip are `tileChrome`, which the palette defines as "one step off
    /// `tileBody`" — the three shipped literals were three unrelated dark values.
    ///
    /// The tile's own fill and outline are still `TileNSView`'s literals; those are
    /// P1.11's (`Sources/ContinuumRevived/Canvas/TileNSView.swift` is not in this
    /// ticket's file list).
    override func applyTokens() {
        super.applyTokens()
        let theme = effectiveTokenTheme
        contentBackdrop.layer?.backgroundColor = SurfaceToken.tileBody.color.cgColor(for: theme)
        header.layer?.backgroundColor = SurfaceToken.tileChrome.color.cgColor(for: theme)
        composeBackdrop.layer?.backgroundColor = SurfaceToken.tileChrome.color.cgColor(for: theme)
    }

    /// The layer colours this view paints on subviews it owns, for
    /// `UIProbeAppearance`'s sentinel sweep. Without this the three fills adopted
    /// above sit in a blind spot: the sweep deliberately never reads a subview's
    /// layer, and these subviews are plain `NSView`s that answer for nothing.
    var qaTokenPaintedLayers: [(label: String, layer: CALayer)] {
        [("contentBackdrop", contentBackdrop), ("header", header), ("composeBackdrop", composeBackdrop)]
            .compactMap { name, view in view.layer.map { (label: name, layer: $0) } }
    }

    private func makeContentView() -> NSView {
        let root = contentBackdrop

        configureHeader()

        cardStack.orientation = .vertical
        cardStack.alignment = .leading
        cardStack.spacing = Space.m
        cardStack.edgeInsets = NSEdgeInsets(Inset.card)
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
            // All three heights are now FUNCTIONS of the type they hold, not magic
            // numbers: two title lines for the name/phase stack, one body line for
            // the compose field, and the dock's own derivation (`Metrics`' mapping
            // table records the 52→54 / 44→41 moves this produces).
            header.heightAnchor.constraint(equalToConstant: Metrics.rowHeight(for: .title, lines: 2)),
            approvalDock.heightAnchor.constraint(equalToConstant: ApprovalDockView.preferredHeight),
            composeRow.heightAnchor.constraint(equalToConstant: Metrics.rowHeight(for: .body, insets: Inset.card)),
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
        glyphLabel.font = .token(.titleL)
        glyphLabel.alignment = .center
        // A square column: one rendered line of the role it holds. The old 28 was a
        // number with no rule behind it.
        glyphLabel.widthAnchor.constraint(equalToConstant: Metrics.lineHeight(for: .titleL)).isActive = true
        nameLabel.font = .token(.title)
        nameLabel.textColor = StatusChipNSView.dynamicNSColor(TextToken.textPrimary.color)
        nameLabel.lineBreakMode = .byTruncatingTail
        phaseLabel.font = .token(.label)
        phaseLabel.textColor = StatusChipNSView.dynamicNSColor(TextToken.textSecondary.color)
        elapsedLabel.font = .token(.captionMono)
        // The HOUSE muted colour. Apple's own secondary label is 3.95:1 on white
        // and its tertiary 2.26:1 — neither can clear AA by construction.
        elapsedLabel.textColor = StatusChipNSView.dynamicNSColor(TextToken.textSecondary.color)

        let textStack = NSStackView(views: [nameLabel, phaseLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = Space.xs
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = Space.l
        header.edgeInsets = NSEdgeInsets(Inset.row)
        header.addArrangedSubview(glyphLabel)
        header.addArrangedSubview(textStack)
        header.addArrangedSubview(NSView())
        header.addArrangedSubview(elapsedLabel)
    }

    private func makeComposeRow() -> NSView {
        let row = composeBackdrop

        composeField.placeholderString = "Send a prompt to the agent…"
        composeField.font = .token(.body)
        composeField.textColor = StatusChipNSView.dynamicNSColor(TextToken.textPrimary.color)
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
        stack.spacing = Space.m
        stack.edgeInsets = NSEdgeInsets(Inset.row)
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
        // The bare glyph shape, so the accent. `dynamicNSColor`, not the `.dark`
        // pin it had: the header now paints `SurfaceToken.tileChrome`, which
        // follows the appearance, so the glyph on it must too.
        glyphLabel.textColor = StatusChipNSView.dynamicNSColor(display.accent)
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
                view.widthAnchor.constraint(equalTo: cardStack.widthAnchor, constant: -Inset.card.horizontal).isActive = true
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
        card.widthAnchor.constraint(equalTo: cardStack.widthAnchor, constant: -Inset.card.horizontal).isActive = true
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
