import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Foundation

/// A stack view with top-left origin so a transcript inside an NSScrollView
/// starts at the top and grows downward (AppKit document coords are otherwise
/// bottom-left, which parks a short transcript at the bottom of the clip view).
@MainActor
final class FlippedStackView: NSStackView {
    override var isFlipped: Bool { true }
    private(set) var qaLayoutPassCount = 0

    override func layout() {
        qaLayoutPassCount += 1
        super.layout()
    }
}

/// View-side intent adapter: the supervisor remains the sole execution owner,
/// while the tile adds the accepted local prompt to its one transcript projection.
/// The adapter is cancelled on detach and never owns a runner.
@MainActor
private final class ManagedAgentTileActionAdapter: AgentTileActionSink {
    weak var tile: ManagedAgentTileNSView?
    weak var supervisor: AgentSupervisor?

    init(tile: ManagedAgentTileNSView, supervisor: AgentSupervisor) {
        self.tile = tile
        self.supervisor = supervisor
    }

    func accept(_ intent: AgentComposerIntent, for agentID: AgentID) async -> IntentAcceptance {
        guard let supervisor else { return .refused(.unknownAgent) }
        let result = await supervisor.accept(intent, for: agentID)
        if result == .accepted, case let .send(prompt) = intent {
            tile?.appendUserPrompt(prompt)
        }
        return result
    }
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
    /// P5.1: the replacement header is constructed independently but installed
    /// only under the v2 fixture flag. The compatibility shell and its baselines
    /// remain untouched until final live migration.
    private let agentHeader = AgentTileHeaderView()
    private var headerAgentName: String?
    private var branchContext: AgentRowContext?
    private let glyphLabel = NSTextField(labelWithString: "")
    private let nameLabel = NSTextField(labelWithString: "")
    private let phaseLabel = NSTextField(labelWithString: "")
    private let elapsedLabel = NSTextField(labelWithString: "0s")
    /// P2C.4: which checkout this agent is about to touch. Hidden until something
    /// tells the tile (`applyBranchContext`), so a tile that knows nothing shows
    /// nothing rather than implying a shared checkout.
    private let branchChip: BranchChipNSView = {
        let chip = BranchChipNSView()
        chip.isHidden = true
        return chip
    }()
    private let cardStack = FlippedStackView()
    /// P5.4 keeps exactly one reversible construction seam. Production remains on
    /// the compatibility shell unless the internal launch flag is supplied; QA and
    /// Component Lab pass `useV2: true` at construction.
    static let v2LaunchArgument = "--agent-tile-v2"
    static let v2EnvironmentKey = "CONTINUUM_AGENT_TILE_V2"
    static var isV2LaunchEnabled: Bool {
        CommandLine.arguments.contains(v2LaunchArgument)
            || ProcessInfo.processInfo.environment[v2EnvironmentKey] == "1"
    }

    private let usesV2: Bool
    private let transcriptCollectionFixture: AgentTranscriptListView?
    private let v2Composer: AgentComposerView?
    private let v2ActionButton: ComposerActionButton?
    private var v2ActionAdapter: ManagedAgentTileActionAdapter?
    private var v2DraftStore: AgentComposerDraftStore?
    private var v2PromptHistory: AgentPromptHistory?
    private var v2CompletionRegistry: AgentCompletionProviderRegistry?
    private var v2TurnSnapshot: AgentTileTurnSnapshot?
    private var v2RenderedDocument = AgentDocument()
    private var v2RenderError: Error?
    private var isProbingV2HeaderActions = false
    private let approvalDock = ApprovalDockView()
    private let composeField = NSTextField()
    private let runButton = NSButton()
    /// P4.8: custom model and effort controls for THIS agent's next turn. The
    /// footer owns their presentation and emits partial writes; this tile remains
    /// the production composition root and the supervisor remains state owner.
    private let providerFooter = AgentComposerFooterView()
    /// What the two custom controls are currently showing. Seeded from the global default
    /// (`AgentModelConfig`) for a tile with no agent, and replaced by the RECORD's
    /// values the moment one attaches — after that the global default is never
    /// consulted again for this agent, which is the whole meaning of "per-agent".
    private var providerSettings = AgentModelConfig.resolvedFromDefaults()
    /// P6.0: one entry view per card, and WHICH view is the card's kind — prose or
    /// record. `makeTranscriptEntryView(for:)` owns that decision.
    private var cardViewsById: [String: TranscriptEntryView] = [:]
    private var inputCardViewsByRequestId: [String: UserInputCardView] = [:]
    private var pendingApprovals: [String: ApprovalDockRequest] = [:]
    private var pendingUserInputs: [String: AgentUserInputRequest] = [:]
    private var model: ManagedAgentTranscriptModel
    private var descriptor: AgentDescriptor
    private var startedAt: Date?
    private var promptInFlight = false
    private let threadId: String
    /// P2A.4: the agent this tile is a VIEW OF, and the subscription that feeds it.
    /// The tile owns neither the agent nor its runner — `AgentSupervisor` does — so
    /// these are the whole of the tile's side of the relationship.
    private(set) var attachedAgentID: AgentID?
    private var eventSubscription: Task<Void, Never>?
    /// Whoever owns the agent's RECORD: the tile asks it for the branch state
    /// (P2C.4) and for the agent's model/thinking, and tells it when the user picks
    /// new ones (P6.1). WEAK — the tile is a view of an agent the supervisor owns,
    /// and a view must never keep it alive.
    private weak var agentSource: AgentSupervisor?
    /// Whose events the transcript on screen actually holds. Distinct from
    /// `attachedAgentID`, which `detach()` clears: a detached tile still SHOWS the
    /// agent it was following, so attaching a different one after a detach must
    /// still clear that transcript.
    private var projectedAgentID: AgentID?
    var onApprovalDecision: ((String, ApprovalDecision) -> Void)?
    var onUserInputSubmit: ((String, UserInputAnswers) -> Void)?
    /// Explicit provider response transport for v2 request blocks. Production
    /// binds nothing today because no compiled `AgentAdapter` response conformer
    /// exists (Queue 90 owns that capability); an unbound seam means a choice
    /// press resolves NOTHING — the request stays truthfully pending until a
    /// real `requestResolved`/`userInputResolved` runtime event arrives. This
    /// tile never fabricates a resolution locally.
    var onProviderResponse: ((_ requestID: String, _ value: String) -> Bool)?
    /// Fired after this tile ingests an event, so the app can mirror the stream
    /// onto the syncable activity timeline (88.4c) without owning the subscription.
    var onIngestedEvent: ((AgentRuntimeEvent) -> Void)?
    /// Fired when the user submits a prompt from the tile's compose row.
    /// The app wires this to a PiAgentRunner (ticket 88.4b). Minimal now; the
    /// framework ComposeBox component supersedes it later.
    var onSubmitPrompt: ((String) -> Void)?
    /// P6.1: fired after the user picks a model or a thinking level. The write to the
    /// agent's record has already happened by then (through the supervisor the tile
    /// attached to); this is for a host that wants to know, and for a tile with no
    /// agent behind it.
    var onProviderSettingsChange: ((AgentModelConfig.Resolution) -> Void)?

    init(
        tile: Tile,
        threadId: String = "thread-main",
        descriptor: AgentDescriptor? = nil,
        useV2: Bool? = nil
    ) {
        self.threadId = threadId
        self.model = ManagedAgentTranscriptModel(threadId: threadId)
        let resolvedV2 = useV2
            ?? (Self.isV2LaunchEnabled || AgentTileHeaderView.isFixtureEnabled
                || AgentTranscriptListView.isFixtureEnabled)
        self.usesV2 = resolvedV2
        self.transcriptCollectionFixture = resolvedV2 ? AgentTranscriptListView() : nil
        self.v2Composer = resolvedV2 ? AgentComposerView(frame: .zero, variant: .fullTurn) : nil
        self.v2ActionButton = resolvedV2 ? ComposerActionButton(
            presentation: .resolve(
                state: .ready,
                capabilities: .init(canSend: false, canStop: false, canSteer: false, canQueue: false),
                hasDraft: false
            )
        ) : nil
        self.descriptor = descriptor ?? AgentDescriptor(
            agentKind: .managed,
            worktreePath: "",
            status: .configuring,
            statusUpdatedAt: Date()
        )
        super.init(tile: tile)
        // TileNSView establishes its compatibility border after its polymorphic
        // token call; re-apply once subclass initialization is complete so the
        // fixture shell's quiet perimeter wins deterministically.
        applyTokens()
        if usesV2 {
            setTileActionLabels(
                close: AgentTileHeaderView.detachActionTitle,
                stop: AgentTileHeaderView.stopActionTitle
            )
            // The compiled host seam stops the whole running agent process, not
            // only its current turn. Keep the action and its label equally broad.
            agentHeader.onStopAgentRun = { [weak self] in
                guard let self else { return }
                if self.isProbingV2HeaderActions { self.onStopRun?() }
                else { self.requestV2Stop() }
            }
            agentHeader.onDetachView = { [weak self] in self?.onClose?() }
            v2Composer?.onDraftChange = { [weak self] _ in self?.updateV2ComposerPresentation() }
            v2Composer?.onSubmitPrompt = { [weak self] prompt in self?.onSubmitPrompt?(prompt) }
            v2ActionButton?.target = self
            v2ActionButton?.action = #selector(performV2PrimaryAction)
        }
        setContentView(makeContentView())
        applyHeader(status: self.descriptor.status)
        applyComposeAvailability()
        synchronizeV2Transcript()
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

    /// The raw events this tile has ingested, in order — its local projection of the
    /// agent's stream. Read by `--agent-supervisor-check`; the transcript itself is
    /// `cards`, which folds deltas together and so cannot count events.
    var ingestedEvents: [AgentRuntimeEvent] { model.events }

    // MARK: - Subscriber (P2A.4)

    /// App-lifetime, host-local composer state. Prompt bodies stay out of the
    /// supervisor record and every sync payload; binding happens again by AgentID
    /// on each attach.
    func bindV2ComposerState(
        draftStore: AgentComposerDraftStore,
        promptHistory: AgentPromptHistory,
        completionRegistry: AgentCompletionProviderRegistry? = nil
    ) {
        guard usesV2 else { return }
        v2DraftStore = draftStore
        v2PromptHistory = promptHistory
        v2CompletionRegistry = completionRegistry
        if let completionRegistry { v2Composer?.bindCompletionRegistry(completionRegistry) }
    }

    /// Become a view of `agentID`'s stream: replay the history the supervisor holds,
    /// then follow the tail. `AgentSupervisor.events(for:)` yields the snapshot
    /// before it registers the subscriber, so the boundary is exact — the tile can
    /// neither miss an event that lands during attach nor see the tail ahead of the
    /// history.
    ///
    /// Idempotent for the agent already attached (re-wiring a live tile is a no-op
    /// rather than a second replay into a model that already holds it). Any OTHER
    /// attach onto a tile that already holds a projection resets it first, because
    /// the replay is the agent's whole conversation and the cards on screen are
    /// already part of it — whether they came from the same agent (detach, then
    /// attach again) or a different one (two agents rendered as one).
    func attach(agentID: AgentID, supervisor: AgentSupervisor) {
        if attachedAgentID == agentID, eventSubscription != nil { return }
        let replayingIntoAProjection = projectedAgentID != nil
        detach()
        if replayingIntoAProjection { resetProjection() }
        attachedAgentID = agentID
        projectedAgentID = agentID
        // The stream is created HERE, not inside the task: the snapshot is taken
        // when `events(for:)` is called, so deferring it to the task's first
        // suspension would widen the window in which events land in neither the
        // snapshot nor the tail.
        // P2C.4: the supervisor holds the record, so attaching is the moment the
        // tile can learn which checkout this agent works in — before its first
        // event, and without the tile ever reading a repository itself.
        agentSource = supervisor
        headerAgentName = supervisor.records[agentID]?.displayName
        applyBranchContext(supervisor.branchContext(for: agentID))
        // P6.1: and which model and thinking level it runs with. From the RECORD,
        // for the same reason the branch is: the agent has its own values (a role
        // may have chosen them at spawn, or the user may have picked them in a
        // previous launch), and the global default is only what a record was seeded
        // FROM. An agent this supervisor does not know keeps the default on screen.
        if let settings = supervisor.providerSettings(for: agentID) {
            applyProviderSettings(settings)
        }
        if usesV2, let composer = v2Composer,
           let snapshot = supervisor.turnSnapshot(for: agentID) {
            v2TurnSnapshot = snapshot
            let adapter = ManagedAgentTileActionAdapter(tile: self, supervisor: supervisor)
            v2ActionAdapter = adapter
            composer.bindActionSink(adapter, agentID: agentID, snapshot: snapshot)
            if let v2DraftStore { composer.bindDraftStore(v2DraftStore, agentID: agentID) }
            if let v2PromptHistory { composer.bindPromptHistory(v2PromptHistory, agentID: agentID) }
            if let v2CompletionRegistry { composer.bindCompletionRegistry(v2CompletionRegistry) }
            updateV2ComposerPresentation()
        }
        let stream = supervisor.events(for: agentID)
        eventSubscription = Task { @MainActor [weak self] in
            for await event in stream {
                guard let self else { break }
                // The transcript model filters on THIS tile's thread id, so events
                // carrying the agent's thread are rebound on the way in — the same
                // rebinding the app did at this boundary before the tile owned it.
                let bound = event.withThreadId(self.threadId)
                self.ingest(bound)
                self.onIngestedEvent?(bound)
            }
        }
    }

    /// Stop following the agent. Cancels the subscription and nothing else: the
    /// agent, its runner and its record are the supervisor's, and closing a view of
    /// an agent must not kill it (locked decision). The transcript already on screen
    /// is left alone, so a detached tile still SHOWS the agent it was following;
    /// `attach` is what clears it, on the next replay.
    func detach() {
        eventSubscription?.cancel()
        eventSubscription = nil
        if let agentID = attachedAgentID, let v2DraftStore {
            Task { await v2DraftStore.flush(agentID: agentID) }
        }
        v2Composer?.unbindActionSink()
        v2ActionAdapter = nil
        v2TurnSnapshot = nil
        attachedAgentID = nil
        agentSource = nil
        updateV2ComposerPresentation()
    }

    /// P2C.4: show which branch this agent's writes land on.
    ///
    /// Takes the whole `AgentRowContext` rather than two strings so that a caller
    /// which already holds a joined row (`AgentContextIndex`, Phase 3's inbox)
    /// passes it straight through, and so the mismatch rule has exactly one
    /// definition — the context's. `nil` hides the chip.
    func applyBranchContext(_ context: AgentRowContext?) {
        branchContext = context
        branchChip.apply(BranchChipNSView.display(for: context))
        applyAgentHeader(status: descriptor.status)
    }

    /// Re-read the agent's branch state and repaint. Drops the cached read first:
    /// the TTL is short but a fast turn can finish inside it, and the whole point of
    /// refreshing at a turn boundary is to see what that turn did.
    private func refreshBranchContext() {
        guard let agentSource, let agentID = projectedAgentID else { return }
        agentSource.invalidateCheckedOutBranches()
        applyBranchContext(agentSource.branchContext(for: agentID))
    }

    /// Drop the local projection so a replay renders exactly the agent it came from.
    private func resetProjection() {
        model = ManagedAgentTranscriptModel(threadId: threadId)
        for view in cardStack.arrangedSubviews {
            cardStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        cardViewsById.removeAll()
        inputCardViewsByRequestId.removeAll()
        pendingApprovals.removeAll()
        pendingUserInputs.removeAll()
        approvalDock.pendingRequest = nil
        startedAt = nil
        promptInFlight = false
        descriptor.status = model.currentStatus
        agentStatus = model.currentStatus
        applyHeader(status: model.currentStatus)
        applyComposeAvailability()
        synchronizeV2Transcript()
    }

    /// P2A.7: says that this agent came back from a previous launch.
    ///
    /// The record survived, and so did the Pi conversation (`--session-id` is derived
    /// from the agent id), but the desktop transcript lives only in this view — which
    /// was just constructed. Without the notice a restored agent renders as a blank
    /// tile indistinguishable from a fresh one. Re-deriving the real transcript from
    /// Pi's session JSONL is a bigger feature and a ticket of its own; this is the
    /// packet's option (b).
    static let previousSessionNoticeText = "Previous session — send a prompt to continue."

    func showPreviousSessionNotice() {
        model.appendNotice(
            id: "notice-previous-session",
            title: "previous session",
            text: Self.previousSessionNoticeText
        )
        // A restored agent is IDLE, not `configuring` — it exists, it is not running,
        // and it is waiting for a prompt. A fresh tile starts at `configuring`
        // (nothing has happened yet), which for a relaunched agent reads as "still
        // starting up" and contradicts the packet's "idle/stopped until the user
        // sends a prompt". Set directly, the way `resetProjection` does, rather than
        // by ingesting a synthetic `.sessionStateChanged`: that would put an event no
        // provider produced onto the tile's stream and from there onto the syncable
        // activity timeline. The first real event re-derives the status from the
        // model as usual.
        descriptor.status = .idle
        descriptor.statusUpdatedAt = Date()
        agentStatus = .idle
        applyHeader(status: .idle)
        applyComposeAvailability()
        if usesV2 {
            synchronizeV2Transcript()
        } else {
            reconcileCards()
            scrollTranscriptToBottom()
        }
    }

    /// Shows the prompt the user just submitted as its own "you" entry.
    func appendUserPrompt(_ text: String) {
        model.appendUserPrompt(text)
        if usesV2 {
            synchronizeV2Transcript()
        } else {
            reconcileCards()
            scrollTranscriptToBottom()
        }
    }

    func ingest(_ event: AgentRuntimeEvent) {
        // Turn-local, not session-local: each new turn resets the semantic timer.
        // AgentTileHeaderView owns the one-second repaint and never touches the
        // transcript layout beneath it.
        if case .turnStarted = event { startedAt = Date() }
        // A prompt is done once the agent settles or a turn ends. Clearing the
        // in-flight latch here re-enables the compose row (see submitPrompt).
        switch event {
        case .turnCompleted, .runtimeError,
             .sessionStateChanged(.ready), .sessionStateChanged(.stopped), .sessionStateChanged(.error):
            promptInFlight = false
        default:
            break
        }
        // P2C.4: a turn is the only thing that can move this agent's checkout — it
        // is when the agent runs commands. Refreshing HERE and nowhere else is what
        // keeps the chip from going stale for the rest of the session, at one git
        // read per turn rather than one per streamed token (which is why the
        // per-render path stays on the cache).
        switch event {
        case .turnCompleted, .runtimeError, .sessionStateChanged(.stopped), .sessionStateChanged(.error):
            refreshBranchContext()
        default:
            break
        }
        model.ingest(event)
        if usesV2 {
            if let agentID = attachedAgentID,
               let snapshot = agentSource?.turnSnapshot(for: agentID) {
                v2TurnSnapshot = snapshot
                v2Composer?.updateTurnSnapshot(snapshot)
            }
        } else {
            updatePendingApproval(from: event)
            updatePendingUserInput(from: event)
        }
        descriptor.status = model.currentStatus
        descriptor.statusUpdatedAt = Date()
        agentStatus = model.currentStatus
        applyHeader(status: model.currentStatus)
        applyComposeAvailability()
        if !usesV2 {
            approvalDock.pendingRequest = pendingApprovals.values.sorted { $0.requestId < $1.requestId }.first
        }
        if usesV2 {
            synchronizeV2Transcript()
            updateV2ComposerPresentation()
        } else {
            reconcileCards()
            scrollTranscriptToBottom()
        }
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
        if usesV2 {
            // Idle v2 agent tiles do not claim a state-bearing perimeter edge.
            // Keyboard focus and needs-attention remain the canvas-owned strong
            // overlays; the surface ladder supplies the quiet containment.
            layer?.borderWidth = 0
            layer?.borderColor = AgentLineRole.decorativeHairline.color.cgColor(for: theme)
            agentHeader.applyTokens()
            v2Composer?.applyTokens()
            // In the live tile this is an interactive text boundary, not a
            // decorative card edge; retain the approved focus ring when focused
            // and a 3:1 control boundary while idle.
            if v2Composer?.isEditorFocused == false {
                v2Composer?.layer?.borderColor = AgentLineRole.controlBoundary.color.cgColor(for: theme)
            }
            v2ActionButton?.applyTokens()
            do {
                try transcriptCollectionFixture?.updateRenderContext(v2RenderContext)
            } catch {
                v2RenderError = error
            }
        }
        // The chip is `TokenThemed` and re-applies on its own flip too; driving it
        // from here as well costs one idempotent assignment and means the header's
        // colours cannot fall behind if AppKit skips a hidden subview.
        branchChip.applyTokens()
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
        if usesV2 { return makeV2ContentView() }
        let root = contentBackdrop

        let installedHeader: NSView
        if usesV2 {
            installedHeader = agentHeader
        } else {
            configureHeader()
            installedHeader = header
        }

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

        let layout = NSStackView(views: [installedHeader, scrollView, approvalDock, composeRow])
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
            installedHeader.heightAnchor.constraint(equalToConstant: usesV2
                ? AgentTileHeaderView.preferredHeight
                : Metrics.rowHeight(for: .title, lines: 2)),
            approvalDock.heightAnchor.constraint(equalToConstant: ApprovalDockView.preferredHeight),
            // P6.1: the prompt row's derived height PLUS the pickers' own. Two
            // popups do not fit the single-body-line height this was, and a popup
            // spilling its parent is what the geometry gate would have caught.
            composeRow.heightAnchor.constraint(
                equalToConstant: Metrics.rowHeight(for: .body, insets: Inset.card)
                    + ManagedAgentTileNSView.providerControlHeight
            ),
            // A vertical NSStackView centers rows at their FITTING width unless
            // pinned, so the transcript column was sizing itself to the longest
            // message's single-line width and floating in the middle of the
            // tile (with the scroller stranded mid-tile). Pin every row to the
            // stack's width.
            installedHeader.widthAnchor.constraint(equalTo: layout.widthAnchor),
            scrollView.widthAnchor.constraint(equalTo: layout.widthAnchor),
            approvalDock.widthAnchor.constraint(equalTo: layout.widthAnchor),
            composeRow.widthAnchor.constraint(equalTo: layout.widthAnchor)
        ])
        return root
    }

    private func makeV2ContentView() -> NSView {
        let root = contentBackdrop
        guard let transcript = transcriptCollectionFixture,
              let composer = v2Composer,
              let actionButton = v2ActionButton else { return root }

        transcript.translatesAutoresizingMaskIntoConstraints = false
        composer.translatesAutoresizingMaskIntoConstraints = false
        providerFooter.translatesAutoresizingMaskIntoConstraints = false
        actionButton.translatesAutoresizingMaskIntoConstraints = false
        providerFooter.onSettingsWrite = { [weak self] model, thinking in
            self?.writeProviderSettings(model: model, thinking: thinking) ?? false
        }
        applyProviderSettings(providerSettings)

        // Stack the footer and primary action vertically. At the 320pt tile floor
        // the approved two provider controls need the full lane; squeezing a third
        // control beside them collapses their labels to zero width.
        let composeColumn = NSStackView(views: [composer, providerFooter, actionButton])
        composeColumn.orientation = .vertical
        composeColumn.alignment = .leading
        composeColumn.spacing = CGFloat(Space.m)
        composeColumn.edgeInsets = NSEdgeInsets(Inset.row)
        composeColumn.translatesAutoresizingMaskIntoConstraints = false
        composeBackdrop.addSubview(composeColumn)

        let layout = NSStackView(views: [agentHeader, transcript, composeBackdrop])
        layout.orientation = .vertical
        layout.spacing = 0
        layout.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(layout)
        NSLayoutConstraint.activate([
            layout.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            layout.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            layout.topAnchor.constraint(equalTo: root.topAnchor),
            layout.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            agentHeader.heightAnchor.constraint(equalToConstant: AgentTileHeaderView.preferredHeight),
            agentHeader.widthAnchor.constraint(equalTo: layout.widthAnchor),
            transcript.widthAnchor.constraint(equalTo: layout.widthAnchor),
            composeBackdrop.widthAnchor.constraint(equalTo: layout.widthAnchor),
            composeColumn.leadingAnchor.constraint(equalTo: composeBackdrop.leadingAnchor),
            composeColumn.trailingAnchor.constraint(equalTo: composeBackdrop.trailingAnchor),
            composeColumn.topAnchor.constraint(equalTo: composeBackdrop.topAnchor),
            composeColumn.bottomAnchor.constraint(equalTo: composeBackdrop.bottomAnchor),
            composer.widthAnchor.constraint(equalTo: composeColumn.widthAnchor, constant: -Inset.row.horizontal),
            providerFooter.widthAnchor.constraint(equalTo: composeColumn.widthAnchor, constant: -Inset.row.horizontal),
            providerFooter.heightAnchor.constraint(equalToConstant: AgentComposerFooterView.height),
            actionButton.heightAnchor.constraint(equalToConstant: ComposerActionButton.controlHeight),
        ])
        composeBackdrop.setContentHuggingPriority(.required, for: .vertical)
        composeBackdrop.setContentCompressionResistancePriority(.required, for: .vertical)
        composer.layer?.borderColor = AgentLineRole.controlBoundary.color.cgColor(for: effectiveTokenTheme)
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
            if !usesV2 { insertUserInputCard(for: request) }
        case .userInputResolved(let threadId, let requestId) where threadId == self.threadId:
            pendingUserInputs.removeValue(forKey: requestId)
            inputCardViewsByRequestId[requestId]?.dismissAnimated()
            inputCardViewsByRequestId.removeValue(forKey: requestId)
        default:
            break
        }
    }

    private var v2RenderContext: AgentRenderContext {
        AgentRenderContext(
            actions: AgentRenderActions { [weak self] action in
                self?.performV2RenderAction(action)
            },
            tokens: .transcript,
            appearance: effectiveTokenTheme
        )
    }

    private func synchronizeV2Transcript() {
        guard usesV2, let transcript = transcriptCollectionFixture else { return }
        // The content reducer owns the semantic document (locked rule 6): request
        // blocks arrive from AgentTranscriptProjection like every other event, so
        // the tile composes and never maintains a parallel request model. The
        // list consumes view-generation versions (reducer versions advance once
        // per mutation, the list contract requires exactly-once steps), and a
        // projection reset converges the same way: the emptied document diffs
        // against the last rendered snapshot and removes every stale row.
        let entries = model.document.entries
        guard entries != v2RenderedDocument.entries else { return }
        let next = AgentDocument(version: v2RenderedDocument.version &+ 1, entries: entries)
        let oldRows = v2RenderedDocument.entries.flatMap { entry in
            entry.blocks.map { ($0.id, entry.role, $0) }
        }
        let newRows = next.entries.flatMap { entry in
            entry.blocks.map { ($0.id, entry.role, $0) }
        }
        let oldByID = Dictionary(uniqueKeysWithValues: oldRows.map { ($0.0, ($0.1, $0.2)) })
        let newByID = Dictionary(uniqueKeysWithValues: newRows.map { ($0.0, ($0.1, $0.2)) })
        let oldIDs = oldRows.map(\.0)
        let newIDs = newRows.map(\.0)
        let inserted = newIDs.filter { oldByID[$0] == nil }
        let removed = oldIDs.filter { newByID[$0] == nil }
        let updated = newIDs.filter { id in
            guard let old = oldByID[id], let new = newByID[id] else { return false }
            return old.0 != new.0 || old.1 != new.1
        }
        let oldIndex = Dictionary(uniqueKeysWithValues: oldIDs.enumerated().map { ($0.element, $0.offset) })
        let moved = newIDs.enumerated().compactMap { index, id in
            oldIndex[id].map { $0 != index ? id : nil } ?? nil
        }.filter { !inserted.contains($0) }
        do {
            let patch = try AgentDocumentPatch(
                fromVersion: v2RenderedDocument.version,
                toVersion: next.version,
                inserted: inserted,
                updated: updated,
                removed: removed,
                moved: moved
            )
            try transcript.apply(document: next, patch: patch)
            v2RenderedDocument = next
            v2RenderError = nil
            if case .needsAction = v2TurnSnapshot?.state {
                transcript.jumpToLatest()
            }
        } catch {
            v2RenderError = error
        }
    }

    private func performV2RenderAction(_ action: AgentRenderAction) {
        guard case let .submitResponse(requestID, value) = action else { return }
        // Only a real supplied choice on a still-pending projected request may
        // reach the transport seam; anything else is a stale or fabricated action.
        guard let payload = v2RequestPayload(requestID),
              [.pending, .inProgress].contains(payload.status),
              payload.choices.contains(value) else { return }
        // With no compiled response transport (Queue 90), the seam is unbound:
        // nothing resolves, the block stays pending, and only a runtime
        // resolution event may complete it. A bound seam reporting false is a
        // refusal and equally resolves nothing.
        _ = onProviderResponse?(requestID, value)
    }

    /// The projected payload for one explicit provider request, read from the
    /// reducer-owned document — the tile keeps no request state of its own.
    private func v2RequestPayload(_ requestID: String) -> AgentRequestPayload? {
        for entry in model.document.entries {
            for block in entry.blocks {
                switch block.payload {
                case .approval(let payload), .question(let payload):
                    if payload.requestID == requestID { return payload }
                default:
                    continue
                }
            }
        }
        return nil
    }

    @objc private func performV2PrimaryAction() {
        guard let composer = v2Composer, let presentation = v2ActionButton?.presentation else { return }
        switch presentation.primaryAction {
        case .send: composer.composerRequestedSend(composer.textView)
        case .stop: composer.requestStop()
        case .unavailable: break
        }
    }

    private func requestV2Stop() {
        if usesV2 { v2Composer?.requestStop() } else { onStopRun?() }
    }

    private func updateV2ComposerPresentation() {
        guard usesV2, let button = v2ActionButton else { return }
        let snapshot = v2TurnSnapshot
        let capabilities = snapshot?.capabilities ?? .init()
        let isWorking = snapshot?.executionState == .working
            || descriptor.status == .working || descriptor.status == .needsAttention
        button.presentation = .resolve(
            state: isWorking ? .working : .ready,
            capabilities: .init(
                canSend: capabilities.canSend,
                canStop: capabilities.canStop,
                canSteer: capabilities.canSteer,
                canQueue: capabilities.canQueue
            ),
            hasDraft: !(v2Composer?.draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        )
        providerFooter.controlsEnabled = !isWorking
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
        branchChip.isHidden = true
        header.addArrangedSubview(glyphLabel)
        header.addArrangedSubview(textStack)
        header.addArrangedSubview(NSView())
        header.addArrangedSubview(branchChip)
        header.addArrangedSubview(elapsedLabel)
    }

    // MARK: - Model and effort (P4.8)

    static let providerNoticeText = "Next turn"

    /// The footer control plus the same vertical row padding used elsewhere in the
    /// compose strip. Unlike the removed popup probe, this measures the production
    /// custom control that is actually installed below.
    static var providerControlHeight: Double {
        (Inset.row.vertical + Double(AgentComposerFooterView.height)).rounded(.up)
    }

    /// Show these values. Called at construction with the global default and again
    /// on `attach` with the agent's own. Off-catalog values remain visible.
    func applyProviderSettings(_ settings: AgentModelConfig.Resolution) {
        providerSettings = settings
        providerFooter.apply(settings)
    }

    /// The footer deliberately emits only the field that moved. This keeps an older
    /// off-catalog value in the other field from making a valid change impossible.
    private func writeProviderSettings(model: String?, thinking: String?) -> Bool {
        let next = AgentModelConfig.Resolution(
            model: model ?? providerSettings.model,
            thinking: thinking ?? providerSettings.thinking
        )
        guard next != providerSettings else { return true }
        if let agentID = attachedAgentID, let agentSource,
           !agentSource.setProviderSettings(agentID: agentID, model: model, thinking: thinking) {
            if let actual = agentSource.providerSettings(for: agentID) { applyProviderSettings(actual) }
            return false
        }
        providerSettings = next
        onProviderSettingsChange?(next)
        return true
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

        providerFooter.onSettingsWrite = { [weak self] model, thinking in
            self?.writeProviderSettings(model: model, thinking: thinking) ?? false
        }
        applyProviderSettings(providerSettings)
        let footerRow = NSView()
        providerFooter.translatesAutoresizingMaskIntoConstraints = false
        footerRow.addSubview(providerFooter)
        NSLayoutConstraint.activate([
            providerFooter.leadingAnchor.constraint(equalTo: footerRow.leadingAnchor, constant: Inset.row.left),
            providerFooter.trailingAnchor.constraint(equalTo: footerRow.trailingAnchor, constant: -Inset.row.right),
            providerFooter.centerYAnchor.constraint(equalTo: footerRow.centerYAnchor),
            providerFooter.heightAnchor.constraint(equalToConstant: AgentComposerFooterView.height),
        ])

        let column = NSStackView(views: [stack, footerRow])
        column.orientation = .vertical
        column.spacing = 0
        column.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            column.topAnchor.constraint(equalTo: row.topAnchor),
            column.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: column.widthAnchor),
            footerRow.widthAnchor.constraint(equalTo: column.widthAnchor),
            // The same two terms the compose row's own height is the sum of, so the
            // prompt row keeps exactly the room P1.10 derived for it and the pickers
            // take their own on top rather than out of it.
            stack.heightAnchor.constraint(equalToConstant: Metrics.rowHeight(for: .body, insets: Inset.card)),
            footerRow.heightAnchor.constraint(equalToConstant: Self.providerControlHeight)
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
        // Next-turn settings move with compose availability; a choice cannot mutate
        // the already-running provider process.
        providerFooter.controlsEnabled = !composeIsBusy
    }

    private func applyHeader(status: AgentStatus) {
        applyAgentHeader(status: status)
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

    private func applyAgentHeader(status: AgentStatus) {
        guard usesV2 else { return }
        if let snapshot = v2TurnSnapshot {
            agentHeader.apply(AgentTileStatePresenter.present(
                name: headerAgentName ?? tile.title,
                snapshot: snapshot,
                branchContext: branchContext,
                startedAt: startedAt
            ))
        } else {
            agentHeader.apply(AgentTileStatePresenter.present(
                name: headerAgentName ?? tile.title,
                status: status,
                branchContext: branchContext,
                startedAt: startedAt
            ))
        }
    }

    override func sync(tile: Tile) {
        super.sync(tile: tile)
        applyHeader(status: descriptor.status)
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
                let view = makeTranscriptEntryView(for: card)
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

    var qaApprovalDockVisible: Bool { !usesV2 && !approvalDock.isHidden }
    var qaApprovalDockDetailText: String { approvalDock.qaDetailText }
    var qaApprovalDockButtonTitles: [String] { approvalDock.qaButtonTitles }
    func qaClickApproval(_ decision: ApprovalDecision) { approvalDock.qaClick(decision) }
    var qaPendingUserInputCount: Int { pendingUserInputs.values.filter { $0.status == .pending }.count }
    var qaUserInputCardCount: Int { usesV2 ? 0 : inputCardViewsByRequestId.count }
    func qaUserInputQuestion(requestId: String) -> String? {
        inputCardViewsByRequestId[requestId]?.qaQuestionText
    }
    func qaSubmitUserInput(requestId: String, answer: String) {
        inputCardViewsByRequestId[requestId]?.qaSubmit(answer)
    }

    /// The cards actually in the view hierarchy, so a reset can be asserted against
    /// the stack and not only against the model behind it.
    var qaRenderedCardCount: Int {
        usesV2 ? (transcriptCollectionFixture?.qaSemanticRowCount ?? 0) : cardStack.arrangedSubviews.count
    }
    var qaTranscriptCollectionFixture: AgentTranscriptListView? { transcriptCollectionFixture }
    var qaComposeEnabled: Bool {
        usesV2 ? !composeIsBusy : composeField.isEnabled
    }
    var qaUsesV2Tile: Bool { usesV2 }
    var qaUsesFullTurnComposer: Bool {
        guard let composer = v2Composer, composer.superview != nil else { return false }
        if case .fullTurn = composer.variant { return true }
        return false
    }
    var qaHasLegacyComposeField: Bool { composeField.superview != nil }
    var qaHasPermanentApprovalDock: Bool { approvalDock.superview != nil }
    var qaV2RenderError: String? { v2RenderError.map(String.init(describing:)) }
    var qaV2RequestIDs: [String] {
        model.document.entries.flatMap { entry in
            entry.blocks.compactMap { block -> String? in
                switch block.payload {
                case .approval(let payload), .question(let payload): return payload.requestID
                default: return nil
                }
            }
        }
    }
    func qaV2RequestStatus(_ requestID: String) -> AgentItemStatus? { v2RequestPayload(requestID)?.status }
    func qaV2RequestChoices(_ requestID: String) -> [String]? { v2RequestPayload(requestID)?.choices }
    var qaV2HasCompactRequestEditor: Bool { false }
    var qaV2CanSend: Bool { v2TurnSnapshot?.capabilities.canSend == true }
    @discardableResult
    func qaClickV2RequestChoice(requestID: String, value: String) -> Bool {
        guard let transcriptCollectionFixture else { return false }
        transcriptCollectionFixture.layoutSubtreeIfNeeded()
        transcriptCollectionFixture.collectionView.layoutSubtreeIfNeeded()
        func find(in view: NSView) -> AgentRequestChoiceButton? {
            if let button = view as? AgentRequestChoiceButton,
               button.title == safeSingleLine(value, fallback: "Respond"),
               (button.superview as? AgentRequestView)?.requestID == requestID {
                return button
            }
            return view.subviews.lazy.compactMap(find).first
        }
        if let button = find(in: transcriptCollectionFixture) {
            button.performClick(nil)
            return true
        }
        // A headless collection may not materialize an off-window item. Exercise
        // the same renderer action only when the semantic payload proves this is a
        // real supplied choice; empty/fabricated values remain a negative result.
        guard v2RequestPayload(requestID)?.choices.contains(value) == true else { return false }
        performV2RenderAction(.submitResponse(requestID: requestID, value: value))
        return true
    }
    /// Read from the installed production footer rather than the tile's cached pair.
    var qaProviderSettings: AgentModelConfig.Resolution { providerFooter.qaSettings }
    var qaModelOptionTitles: [String] { providerFooter.modelButton.items.map(\.id) }
    var qaThinkingOptionTitles: [String] { providerFooter.effortButton.items.map(\.id) }
    var qaProviderControlsEnabled: Bool { providerFooter.controlsEnabled }
    /// Kept for the existing supervisor contract, but derived from the installed
    /// footer: next-turn context must be one passive label and never a choice item.
    var qaProviderNoticeIsPickable: Bool {
        let hasNoticeItem = (providerFooter.modelButton.items + providerFooter.effortButton.items)
            .contains { $0.title == Self.providerNoticeText }
        return providerFooter.qaContextText != Self.providerNoticeText
            || providerFooter.qaContextIsActionable
            || hasNoticeItem
    }
    var qaUsesCustomProviderControls: Bool {
        providerFooter.modelButton.accessibilityRole() == .popUpButton
            && providerFooter.effortButton.accessibilityRole() == .popUpButton
            && !providerFooter.subviews.contains(where: { $0 is NSPopUpButton })
    }
    @discardableResult
    func qaPickModel(_ model: String) -> Bool { providerFooter.qaPickModel(model) }
    @discardableResult
    func qaPickThinking(_ thinking: String) -> Bool { providerFooter.qaPickThinking(thinking) }
    /// nil when the chip is hidden, so "no branch is shown" and "an empty branch is
    /// shown" cannot be confused.
    var qaBranchChipText: String? {
        if usesV2 {
            // `--agent-supervisor-check` enables the v2 fixture and consumes this
            // accessor for unbound, isolated, shared, and moved-checkout tiles.
            // Return the INSTALLED header's chip so the existing deterministic
            // branch assertions exercise this shell rather than its hidden legacy
            // sibling. A shell/action regression becomes an explicit check failure.
            guard qaV2HeaderContractHolds() else { return qaV2HeaderFailure }
            return agentHeader.qaBranch
        }
        return branchChip.isHidden ? nil : branchChip.qaText
    }
    var qaBranchChipIsWarning: Bool {
        usesV2
            ? agentHeader.qaBranchIsWarning
            : (!branchChip.isHidden && branchChip.qaIsWarning)
    }
    var qaBranchChipTooltip: String? {
        usesV2 ? agentHeader.qaBranchTooltip : (branchChip.isHidden ? nil : branchChip.toolTip)
    }
    private var qaV2ContractDetail = "not exercised"
    private func qaV2HeaderContractHolds() -> Bool {
        guard qaUsesV2HeaderShell,
              !agentHeader.qaName.isEmpty,
              !agentHeader.qaState.isEmpty,
              agentHeader.qaUsesCustomOverflow,
              agentHeader.qaActionTitles == [AgentTileHeaderView.stopActionTitle, AgentTileHeaderView.detachActionTitle],
              layer?.borderWidth == 0 else { return false }
        let titleActions = titleBarContextMenuForQA().items.map(\.title)
        guard titleActions.contains(AgentTileHeaderView.stopActionTitle),
              titleActions.contains(AgentTileHeaderView.detachActionTitle),
              !titleActions.contains("Stop current turn"),
              !titleActions.contains("Stop run"),
              !titleActions.contains("Close tile") else { return false }

        // Exercise the installed header's production callback path, rather than
        // accepting action labels as proof that either action is connected.
        let savedStop = onStopRun
        let savedClose = onClose
        var stopCount = 0
        var detachCount = 0
        onStopRun = { stopCount += 1 }
        onClose = { detachCount += 1 }
        isProbingV2HeaderActions = true
        agentHeader.qaInvokeStopAction()
        agentHeader.qaInvokeDetachAction()
        isProbingV2HeaderActions = false
        onStopRun = savedStop
        onClose = savedClose
        guard stopCount == 1, detachCount == 1 else { return false }

        // Drive the exact timer update used by the one-second Timer. A tick must
        // update only the fixed-width header label, never invalidate transcript
        // layout. Settling idle must tear the timer down and hide elapsed time.
        let start = Date(timeIntervalSince1970: 100)
        agentHeader.apply(AgentTileStatePresenter.present(
            name: headerAgentName ?? tile.title,
            status: .working,
            branchContext: branchContext,
            startedAt: start,
            now: Date(timeIntervalSince1970: 165)
        ))
        // Applying a wholly new presentation may legitimately lay out the
        // shell. Settle it, then count actual transcript layout passes while an
        // isolated timer tick and its resulting layout are processed.
        contentView?.layoutSubtreeIfNeeded()
        let transcriptLayoutsBeforeTick = cardStack.qaLayoutPassCount
        agentHeader.qaTick(now: Date(timeIntervalSince1970: 165))
        contentView?.layoutSubtreeIfNeeded()
        let timerActive = agentHeader.qaTimerIsActive
        let elapsedText = agentHeader.qaElapsed
        let transcriptLayoutDelta = cardStack.qaLayoutPassCount - transcriptLayoutsBeforeTick
        let workingTimerHolds = timerActive
            && elapsedText == "· 1m 5s"
            && transcriptLayoutDelta == 0
        agentHeader.apply(AgentTileStatePresenter.present(
            name: headerAgentName ?? tile.title,
            status: .idle,
            branchContext: branchContext,
            startedAt: start,
            now: Date(timeIntervalSince1970: 165)
        ))
        let idleTimerHolds = !agentHeader.qaTimerIsActive && agentHeader.qaElapsed == nil
        applyAgentHeader(status: descriptor.status)
        qaV2ContractDetail = "callbacks=\(stopCount)/\(detachCount) timerActive=\(timerActive) "
            + "elapsed=\(elapsedText ?? "nil") transcriptLayouts=\(transcriptLayoutDelta) idleTimer=\(idleTimerHolds)"
        return workingTimerHolds && idleTimerHolds
    }
    private var qaV2HeaderFailure: String {
        "__invalid-v2-agent-header-shell__ "
            + "installed=\(qaUsesV2HeaderShell) name=\(agentHeader.qaName) state=\(agentHeader.qaState) "
            + "custom=\(agentHeader.qaUsesCustomOverflow) actions=\(agentHeader.qaActionTitles) "
            + "elapsed=\(agentHeader.qaElapsed ?? "nil") timer=\(agentHeader.qaTimerIsActive) "
            + "detail=\(qaV2ContractDetail) border=\(layer?.borderWidth ?? -1) "
            + "titleActions=\(titleBarContextMenuForQA().items.map(\.title))"
    }
    var qaUsesV2HeaderShell: Bool { usesV2 && agentHeader.superview != nil }
    func qaSubmitPrompt(_ prompt: String) {
        if let composer = v2Composer {
            composer.apply(AgentComposerDraft(
                text: prompt,
                selection: NSRange(location: (prompt as NSString).length, length: 0),
                revision: composer.draft.revision &+ 1
            ))
            composer.composerRequestedSend(composer.textView)
        } else {
            composeField.stringValue = prompt
            submitPrompt()
        }
    }
    var qaTranscriptText: String {
        model.cards.map { "[\($0.title)] \($0.body)" }.joined(separator: "\n")
    }
    var qaLastAssistantCardBody: String? {
        model.cards.last { $0.title == "assistant" }?.body
    }
}
