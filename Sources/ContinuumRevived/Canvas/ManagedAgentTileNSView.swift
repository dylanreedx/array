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

/// View-side intent adapter: the supervisor remains the sole execution owner.
/// The adapter is cancelled on detach and never owns a runner.
///
/// It no longer holds the tile. Echoing the accepted prompt was its only reason to,
/// and that moved to the composer's synchronous submission seam.
@MainActor
private final class ManagedAgentTileActionAdapter: AgentTileActionSink {
    weak var supervisor: AgentSupervisor?

    init(supervisor: AgentSupervisor) {
        self.supervisor = supervisor
    }

    func accept(_ intent: AgentComposerIntent, for agentID: AgentID) async -> IntentAcceptance {
        guard let supervisor else { return .refused(.unknownAgent) }
        // The prompt echo used to happen HERE, after this await returned. That put
        // the user's own words behind an actor hop, a draft-journal read and write,
        // a cross-process flock and (for pi) a role-directory scan — so the first
        // visible response to a keystroke was gated on local IO. The composer now
        // paints it synchronously in the submit frame via `onSubmissionStarted` and
        // resolves it with `onSubmissionFinished`.
        return await supervisor.accept(intent, for: agentID)
    }
}

enum AgentStatusRowPlacement: String, CaseIterable, Sendable {
    case aboveComposer
    case belowComposer
}

@MainActor
final class ManagedAgentTileNSView: TileNSView {
    private let awarenessBadge = AgentSignalBadgeView()
    private let awarenessBorder = AgentSignalBorderView()
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
    /// The compact row is the sole live Home/Where/What and activity surface;
    /// its action button remains the host's native location route. The former
    /// location view stays hidden in the hierarchy only for its existing theme
    /// census; it owns no production layout or accessibility content.
    private let locationStatus = AgentLocationStatusView()
    private let compactStatusRow = AgentCompactStatusRowView()
    private var lastLocationPresentation: AgentLocationStatusPresentation?
    private var headerAgentName: String?
    private var branchContext: AgentRowContext?
    private var locationProjectName: String?
    private var locationStaleTimer: Timer?
    /// Advances the compact row's elapsed reading while a phase is live.
    /// `AgentRuntimeEvent`s are the only other thing that repaints the row, so
    /// without this the reading freezes at whatever the last event produced and
    /// then jumps — the "delayed and wrong" status. Runs ONLY while a live phase
    /// is on screen; idle/silent states tear it down.
    private var compactStatusTickTimer: Timer?
    private var streamingMarkupParseTimer: Timer?
    private var streamingMarkupParseTimerScheduledDelay: TimeInterval?
    private var streamingMarkupParseTimerGeneration: UInt64 = 0

    private let transcriptCollectionFixture: AgentTranscriptListView?
    private let v2Composer: AgentComposerView?
    private let v2ActionButton: ComposerActionButton?
    private let projectionMonotonicNow: @Sendable () -> TimeInterval
    private var v2ActionAdapter: ManagedAgentTileActionAdapter?
    private var v2DraftStore: AgentComposerDraftStore?
    private var v2AttachmentStore: AgentComposerAttachmentStore?
    private var v2PromptHistory: AgentPromptHistory?
    private var v2CompletionRegistry: AgentCompletionProviderRegistry?
    private let v2DefaultCompletionRegistry: AgentCompletionProviderRegistry
    private var v2TurnSnapshot: AgentTileTurnSnapshot?
    // The compact row consumes only facts observed on this tile's managed-agent
    // stream. In particular, no receipt-time Date is promoted to a phase anchor;
    // the supervisor's stamped turn start is the only turn anchor available here.
    private var compactStatusPhaseAdapter = AgentCompactStatusPhaseAdapter()
    private var compactStatusSession: AgentCompactStatusPhaseFacts.Session?
    private var compactStatusTurn: AgentCompactStatusPhaseFacts.Turn?
    private var compactStatusInteraction: AgentCompactStatusPhaseFacts.Interaction?
    private var compactContextWindow: AgentContextWindowSnapshot?
    private var compactStatusResolution = AgentCompactStatusPhaseResolution.unknown
    /// Subscription to the supervisor's turn-capability seam. The runner slot
    /// frees strictly after the last runtime event a tile ingests, so without
    /// this the composer's last repaint shows `canSend == false` forever
    /// (P5.5 live finding, `plan-P5.5-review-corrections.md` defect 1).
    private var capabilityObserverToken: UUID?
    private var runtimeObservationObserverToken: UUID?
    private var displayNameObserverToken: UUID?
    private let toolDetailStore = AgentToolDetailStore()
    private let managedImageThumbnailPipeline = ComposerImageIOThumbnailPipeline()
    private var managedImageMetadata: [AgentImageAttachmentID: AgentImageAttachmentMetadata] = [:]
    private var managedImageRevisions: [AgentImageAttachmentID: UInt64] = [:]
    private var managedImageAvailable: Set<AgentImageAttachmentID> = []
    private var managedImageHydrating: Set<AgentImageAttachmentID> = []
    private var managedImageBindingGeneration: UInt64 = 0
    private let imagePreviewController = AgentImageQuickPreviewController()
    private let statusRowPlacement: AgentStatusRowPlacement
    private var v2RenderedDocument = AgentDocument()
    private var v2RenderError: Error?
    /// Version of the reducer document this tile has already forwarded. The
    /// reducer advances it exactly once per accepted mutation, so it is an O(1)
    /// stand-in for "has the semantic document changed" — see
    /// `synchronizeV2Transcript`. `nil` after a projection reset, which restarts
    /// the reducer's numbering and must always resynchronize.
    private var lastForwardedDocumentVersion: UInt64?
    private var isProbingV2HeaderActions = false
    /// P4.8: custom model and effort controls for THIS agent's next turn. The
    /// footer owns their presentation and emits partial writes; this tile remains
    /// the production composition root and the supervisor remains state owner.
    private let providerFooter = AgentComposerFooterView()
    /// The provider/model/effort controls and the primary action, kept so C5 can
    /// take them off screen for an agent Array only mirrors.
    private weak var v2FooterRow: NSStackView?
    private var v2ComposeColumn: NSStackView?
    /// What the two custom controls are currently showing. Seeded from the global default
    /// (`AgentModelConfig`) for a tile with no agent, and replaced by the RECORD's
    /// values the moment one attaches — after that the global default is never
    /// consulted again for this agent, which is the whole meaning of "per-agent".
    private var providerSettings = AgentModelConfig.resolvedFromDefaults()
    private var model: ManagedAgentTranscriptModel
    private var descriptor: AgentDescriptor
    private var startedAt: Date?
    private var promptInFlight = false
    /// Guards `renderRehydratedPreviousSession` so a re-wire cannot stack the
    /// restored history. Reset by `resetProjection` (which clears the model), so
    /// a re-attach after a detach re-renders the seeded transcript.
    private var hasRenderedRehydratedSession = false
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
    /// Transcript attachment ownership survives a live detach. It is cleared only
    /// when the semantic projection resets/rebinds, never merely because the view
    /// stops following the running agent.
    private var transcriptAttachmentOwnerAgentID: AgentID?
    /// Non-nil between the optimistic paint and its resolution. Guards against a
    /// second echo and against resolving an echo this tile never painted.
    private var pendingOptimisticSubmissionID: AgentNodeID?
    /// `.plans/45` S6 — the live tool verb for the tail ("Searching \u{201C}...\u{201D}"),
    /// from the latest `.toolDetail` observation. Store-sourced, never the
    /// document. Cleared when that item ends or the turn moves on.
    private var liveToolVerb: (itemID: String, text: String)?
    /// The last settled turn's "Worked for Ns", measured submit -> completion
    /// (the user-message anchor; entry timestamps alone undercount).
    private var settledTurnStatusText: String?
    /// See `TurnLiveness`. Written only from the event switch, so it moves with
    /// the same stream that produces the transcript's rows.
    private(set) var turnLiveness: TurnLiveness = .unknown
    var onUserInputSubmit: ((String, UserInputAnswers) -> Void)?
    /// Explicit provider response transport for v2 request blocks. Production
    /// binds nothing today because no compiled `AgentAdapter` response conformer
    /// exists (Queue 90 owns that capability); an unbound seam means a choice
    /// press resolves NOTHING — the request stays truthfully pending until a
    /// real `requestResolved`/`userInputResolved` runtime event arrives. This
    /// tile never fabricates a resolution locally.
    var onProviderResponse: ((_ requestID: String, _ value: String) -> Bool)?

    /// App-owned sink for a local-file link this agent authored. It receives the
    /// unresolved destination exactly as written; `AppDelegate.wireManagedAgentTile`
    /// binds it with this tile's id and agent id so resolution happens against the
    /// responding agent's own checkout.
    var onOpenLocalFile: ((String) -> Void)?
    /// App-owned destination for an authorized transcript URL. The tile carries
    /// the user's Array-vs-system intent but never chooses placement itself.
    var onOpenWebLink: ((URL, AgentLinkOpenTarget) -> Void)?
    /// Resolves a durable transcript agent reference through the app-owned reveal
    /// path. A tile never creates another agent; it asks the app to reveal or
    /// attach the existing identity.
    var onRevealAgent: ((_ agentID: AgentID, _ parentAgentID: AgentID) -> Void)?
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
    /// Native Home/Where action route. The app builds the menu because it owns
    /// project registry, NSOpenPanel, Finder/Terminal, and spawn infrastructure.
    var onLocationActionMenuRequested: ((_ agentID: AgentID, _ anchor: NSButton) -> Void)?

    init(
        tile: Tile,
        threadId: String = "thread-main",
        descriptor: AgentDescriptor? = nil,
        providerSettings: AgentModelConfig.Resolution? = nil,
        statusRowPlacement: AgentStatusRowPlacement = .aboveComposer,
        monotonicNow: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        let fileIndex = AgentFileIndex()
        self.v2DefaultCompletionRegistry = AgentCompletionProviderRegistry(
            providers: AgentCompletionFixtures.providers().filter {
                $0.providerID != "fixture.files" && $0.providerID != "fixture.commands"
            }
                + [AgentCommandCompletionProvider()]
                + [AgentFileCompletionProvider(index: fileIndex)]
        )
        self.threadId = threadId
        self.statusRowPlacement = statusRowPlacement
        self.projectionMonotonicNow = monotonicNow
        self.model = ManagedAgentTranscriptModel(threadId: threadId, monotonicNow: monotonicNow)
        self.providerSettings = providerSettings ?? AgentModelConfig.resolvedFromDefaults()
        // P5.5 acceptance: v2 IS the tile. The reversible construction seam and
        // the legacy view-only card path were removed at this supervised gate.
        self.transcriptCollectionFixture = AgentTranscriptListView(toolDetailStore: toolDetailStore)
        self.v2Composer = AgentComposerView(frame: .zero, variant: .fullTurn)
        self.v2ActionButton = ComposerActionButton(
            presentation: .resolve(
                state: .ready,
                capabilities: .init(canSend: false, canStop: false, canSteer: false, canQueue: false),
                hasDraft: false
            )
        )
        self.descriptor = descriptor ?? AgentDescriptor(
            agentKind: .managed,
            worktreePath: "",
            status: .configuring,
            statusUpdatedAt: Date()
        )
        super.init(tile: tile)
        addSubview(awarenessBorder, positioned: .above, relativeTo: nil)
        addSubview(awarenessBadge, positioned: .above, relativeTo: awarenessBorder)
        refreshTitleBarIdentity()
        // TileNSView establishes its compatibility border after its polymorphic
        // token call; re-apply once subclass initialization is complete so the
        // fixture shell's quiet perimeter wins deterministically.
        applyTokens()
        setTileActionLabels(
            close: AgentTileHeaderView.detachActionTitle,
            stop: AgentTileHeaderView.stopActionTitle
        )
        // The compiled host seam stops the whole running agent process, not
        // only its current turn. Keep the action and its label equally broad.
        compactStatusRow.onActionMenuRequested = { [weak self] anchor in
            guard let self, let agentID = self.projectedAgentID else { return }
            self.onLocationActionMenuRequested?(agentID, anchor)
        }
        agentHeader.onStopAgentRun = { [weak self] in
            guard let self else { return }
            if self.isProbingV2HeaderActions { self.onStopRun?() }
            else { self.requestV2Stop() }
        }
        agentHeader.onDetachView = { [weak self] in self?.onClose?() }
        v2Composer?.onDraftChange = { [weak self] _ in self?.updateV2ComposerPresentation() }
        v2Composer?.onSubmitPrompt = { [weak self] prompt in self?.onSubmitPrompt?(prompt) }
        v2Composer?.onSubmissionStarted = { [weak self] prompt in
            self?.beginOptimisticSubmission(prompt)
        }
        v2Composer?.onSubmissionFinished = { [weak self] accepted in
            self?.finishOptimisticSubmission(accepted: accepted)
        }
        v2ActionButton?.target = self
        v2ActionButton?.action = #selector(performV2PrimaryAction)
        setContentView(makeV2ContentView())
        applyHeader(status: self.descriptor.status)
        applyUnknownCompactStatus()
        refreshTranscriptThinkingIndicator()
        synchronizeV2Transcript(final: true)
    }

    func acceptCurrentSendIntent() {
        v2Composer?.acceptCurrentSendIntent()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    isolated deinit {
        prepareStreamingMarkupForTeardown(final: true)
        locationStaleTimer?.invalidate()
        compactStatusTickTimer?.invalidate()
    }

    /// The thread this tile's transcript filters on. The app rebinds incoming
    /// provider events to this before ingest (ticket 88.4b).
    var wiringThreadId: String { threadId }
    var qaCompletionContext: AgentCompletionContext? { v2Composer?.qaCompletionContext }
    var transcriptCardCount: Int { model.cards.count }
    var activeToolCount: Int { model.activeToolCount }
    var currentAgentStatus: AgentStatus { descriptor.status }
    var qaStatusRowPlacement: AgentStatusRowPlacement { statusRowPlacement }

    // MARK: - Surface residency (.plans/36)

    /// The agent tile is the first — and in slice 1 the only — family that opts
    /// into surface residency, because it is the one the cost was measured on: at
    /// 50 of these, a camera step costs 140 ms native and 0.19 ms surfaced.
    ///
    /// `contentBackdrop` and not `contentView`: once surfaced, `contentView` IS the
    /// surface host, and returning that would let a tile bake a picture of a
    /// picture.
    override var surfaceableBody: NSView? { contentBackdrop }

    /// **A fingerprint of everything this body renders, not just its transcript.**
    ///
    /// `model.document.version` alone is not enough, and the gap is visible: a
    /// `.turnStarted` or `.turnCompleted` moves the compact status row from "Done" to
    /// "Working" and back, and starts or stops the elapsed tick, without necessarily
    /// adding a card. A surface keyed on the document alone stays "fresh" through
    /// that, so a quiet tile would sit there showing a status it no longer has.
    ///
    /// So the document version is mixed with a counter over every ingested event.
    /// Over-counting is free here: an ingested event also makes the tile LIVE, which
    /// means native, which means the extra invalidation costs one bake at the next
    /// quiet transition and nothing during the burst.
    /// The transcript's clip origin. The composer does not scroll independently of
    /// its own height changes (which move `surfaceContentRevision`), so the
    /// transcript is the one scroll owner a bake can disagree with.
    override var surfaceScrollOffsets: [CGPoint] {
        guard let clip = transcriptCollectionFixture?.scrollView.contentView else { return [] }
        return [clip.bounds.origin]
    }

    /// Scroll the transcript from a witness without reaching into its privates.
    func qaScrollTranscript(toY y: CGFloat) {
        guard let scrollView = transcriptCollectionFixture?.scrollView else { return }
        scrollView.contentView.scroll(to: CGPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    override var surfaceContentRevision: UInt64? {
        var mixed = model.document.version &* 0x9E37_79B9_7F4A_7C15
        mixed ^= surfaceVisualEpoch &* 0xC2B2_AE3D_27D4_EB4F
        return mixed
    }

    /// Bumped by every ingested runtime event. See `surfaceContentRevision`.
    private var surfaceVisualEpoch: UInt64 = 0

    /// The tile is repainting itself once a second while a live phase shows an
    /// elapsed reading, and `compactStatusTickTimer` is exactly that condition —
    /// the same signal `qaCompactStatusTickScheduled` reports. Surfacing such a tile
    /// would freeze a counter the user can see counting.
    override var surfaceIsAnimating: Bool { compactStatusTickTimer?.isValid == true }

    /// An agent body always paints: a status line, a composer with its border and
    /// its model row, and usually a transcript. A uniform bake of one is the blank
    /// tile body users reported, never a faithful picture.
    override var surfaceBakeExpectsContent: Bool { true }
    var qaCompositionIdentifiers: [String] {
        v2ComposeColumn?.arrangedSubviews.compactMap { $0.identifier?.rawValue } ?? []
    }

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
        attachmentStore: AgentComposerAttachmentStore? = nil,
        completionRegistry: AgentCompletionProviderRegistry? = nil
    ) {
        v2DraftStore = draftStore
        v2AttachmentStore = attachmentStore
        v2PromptHistory = promptHistory
        v2CompletionRegistry = completionRegistry ?? v2DefaultCompletionRegistry
        if let agentID = attachedAgentID {
            if let attachmentStore { v2Composer?.bindAttachmentStore(attachmentStore, agentID: agentID) }
            v2Composer?.bindDraftStore(draftStore, agentID: agentID)
            v2Composer?.bindPromptHistory(promptHistory, agentID: agentID)
        }
        if let v2CompletionRegistry { v2Composer?.bindCompletionRegistry(v2CompletionRegistry) }
        hydrateManagedImagesFromDocument()
        try? transcriptCollectionFixture?.updateRenderContext(v2RenderContext)
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
    func attach(
        agentID: AgentID,
        supervisor: AgentSupervisor,
        projectName: String? = nil
    ) {
        if attachedAgentID == agentID, eventSubscription != nil {
            // Assign unconditionally (including nil), matching the full-attach
            // path below: re-attaching after a Change Home to a custom FOLDER
            // passes projectName == nil, and keeping the stale prior project
            // name here left the header showing the old Home even though the
            // cwd moved ("selected a new Home did nothing").
            locationProjectName = projectName
            v2Composer?.bindCompletionContext(supervisor.completionContext(for: agentID))
            refreshLocationStatus()
            return
        }
        let replayingIntoAProjection = projectedAgentID != nil
        detach()
        if replayingIntoAProjection { resetProjection() }
        attachedAgentID = agentID
        projectedAgentID = agentID
        transcriptAttachmentOwnerAgentID = agentID
        transcriptCollectionFixture?.bindToolDetailAgent(agentID)
        // The stream is created HERE, not inside the task: the snapshot is taken
        // when `events(for:)` is called, so deferring it to the task's first
        // suspension would widen the window in which events land in neither the
        // snapshot nor the tail.
        // P2C.4: the supervisor holds the record, so attaching is the moment the
        // tile can learn which checkout this agent works in — before its first
        // event, and without the tile ever reading a repository itself.
        agentSource = supervisor
        v2Composer?.bindCompletionContext(supervisor.completionContext(for: agentID))
        headerAgentName = supervisor.records[agentID]?.humanDisplayName
        displayNameObserverToken = supervisor.addDisplayNameObserver(for: agentID) { [weak self] name in
            guard let self, self.headerAgentName != name else { return }
            self.headerAgentName = name
            self.refreshTitleBarIdentity()
            self.applyAgentHeader(status: self.descriptor.status)
        }
        locationProjectName = projectName
        applyBranchContext(supervisor.branchContext(for: agentID))
        refreshLocationStatus()
        // Seed the compact row from the supervisor's current truth instead of
        // waiting for the replay to happen to contain the right events: the
        // capped replay buffer evicts rare lifecycle/telemetry events behind a
        // streaming turn, and a fresh spawn has no events yet at all. Replayed
        // and live events overwrite these seeds through the normal ingest path.
        seedCompactStatus(from: supervisor, agentID: agentID)
        // P6.1: and which model and thinking level it runs with. From the RECORD,
        // for the same reason the branch is: the agent has its own values (a role
        // may have chosen them at spawn, or the user may have picked them in a
        // previous launch), and the global default is only what a record was seeded
        // FROM. An agent this supervisor does not know keeps the default on screen.
        if let selection = supervisor.launchSelection(for: agentID) {
            applyLaunchSelection(selection)
        }
        if let composer = v2Composer,
           let snapshot = supervisor.turnSnapshot(for: agentID) {
            v2TurnSnapshot = snapshot
            let adapter = ManagedAgentTileActionAdapter(supervisor: supervisor)
            v2ActionAdapter = adapter
            composer.bindActionSink(adapter, agentID: agentID, snapshot: snapshot)
            composer.onCompletionAction = { [weak adapter] payload in
                guard case let .command(invocation) = payload else { return false }
                guard invocation.surface != .cli else { return false }
                Task { @MainActor [weak adapter] in
                    _ = await adapter?.accept(.providerCommand(invocation), for: agentID)
                }
                return true
            }
            // B4: direct manipulation of Array's own queue. Neither touches the
            // turn in flight — the primary composer control keeps one meaning.
            composer.onCancelQueuedMessage = { [weak supervisor] messageID in
                supervisor?.cancelQueuedMessage(messageID, for: agentID)
            }
            composer.onClearQueuedMessages = { [weak supervisor] in
                supervisor?.clearQueuedMessages(for: agentID)
            }
            composer.updateQueuedMessages(
                supervisor.queuedMessages(for: agentID),
                paused: supervisor.isQueuePaused(for: agentID)
            )
            if let v2AttachmentStore { composer.bindAttachmentStore(v2AttachmentStore, agentID: agentID) }
            if let v2DraftStore { composer.bindDraftStore(v2DraftStore, agentID: agentID) }
            if let v2PromptHistory { composer.bindPromptHistory(v2PromptHistory, agentID: agentID) }
            if let v2CompletionRegistry { composer.bindCompletionRegistry(v2CompletionRegistry) }
            // The runner slot being taken or freed carries no runtime event, so the
            // event subscription below cannot repaint it; the seam can.
            capabilityObserverToken = supervisor.addTurnCapabilitiesObserver { [weak self] changed in
                guard let self, changed == self.attachedAgentID else { return }
                self.refreshV2TurnSnapshot()
            }
            updateV2ComposerPresentation()
        }
        runtimeObservationObserverToken = supervisor.addRuntimeObservationObserver(for: agentID) { [weak self] observation in
            self?.transcriptCollectionFixture?.captureRuntimeObservation(observation)
            self?.updateLiveToolVerb(for: observation)
        }
        hydrateManagedImagesFromDocument()
        let stream = supervisor.events(for: agentID)
        eventSubscription = Task { @MainActor [weak self] in
            for await event in stream {
                guard let self else { break }
                // The transcript model filters on THIS tile's thread id, so events
                // carrying the agent's thread are rebound on the way in — the same
                // rebinding the app did at this boundary before the tile owned it.
                let bound = event.withThreadId(self.threadId)
                // Capture the provider event before host-local transcript remapping;
                // the original runtime thread is immutable tool identity, not a
                // display-routing convenience.
                self.ingest(bound, originalEvent: event)
                self.onIngestedEvent?(bound)
            }
        }
        // A restored agent may have a prior transcript the supervisor already
        // read from its session file. Render it directly (display-only, see
        // renderRehydratedPreviousSession) so any tile attaching to the agent —
        // including a re-attach after a detach — shows the restored history.
        if let rehydrated = supervisor.rehydratedTranscript(for: agentID) {
            renderRehydratedPreviousSession(rehydrated)
        }
        refreshTranscriptThinkingIndicator()
    }

    override func layout() {
        super.layout()
        awarenessBorder.frame = bounds.insetBy(dx: 2, dy: 2)
        let width = min(150, max(94, awarenessBadge.fittingSize.width + 20))
        awarenessBadge.frame = NSRect(
            x: max(8, bounds.width - width - 10),
            y: chromeBarHeight + 8,
            width: width,
            height: 22)
    }

    func applyAwarenessSignal(_ signal: AgentSignal?) {
        awarenessBadge.apply(signal)
        awarenessBorder.apply(signal)
        needsLayout = true
    }

    var qaAwarenessSignal: AgentSignal? { awarenessBadge.signal }

    override func makeAdditionalTitleBarMenuItems() -> [NSMenuItem] {
        let root = NSMenuItem(title: "Sounds", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Sounds")
        for kind in AgentSignalKind.allCases.sorted(by: { $0.priority > $1.priority }) {
            let item = NSMenuItem(title: kind.displayName, action: nil, keyEquivalent: "")
            let choices = NSMenu(title: kind.displayName)
            choices.addItem(soundOverrideItem(title: "Inherit global", kind: kind, value: "inherit"))
            choices.addItem(soundOverrideItem(title: "Mute", kind: kind, value: "mute"))
            choices.addItem(.separator())
            for sound in AgentSoundLibrary.shared.allEntries {
                choices.addItem(soundOverrideItem(title: sound.name, kind: kind, value: "sound:\(sound.id.rawValue)"))
            }
            if case .sound(let reference) = tile.metadata.agentSoundOverrides?.values[kind],
               !AgentSoundLibrary.shared.availableReferences.contains(reference) {
                choices.addItem(.separator())
                let warning = NSMenuItem(
                    title: "Missing sound — using global",
                    action: nil,
                    keyEquivalent: "")
                warning.isEnabled = false
                choices.addItem(warning)
            }
            item.submenu = choices
            menu.addItem(item)
        }
        root.submenu = menu
        return [root]
    }

    private func soundOverrideItem(title: String, kind: AgentSignalKind, value: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(selectSoundOverride(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = "\(kind.rawValue)|\(value)"
        let current = tile.metadata.agentSoundOverrides?.values[kind] ?? .inherit
        switch (current, value) {
        case (.inherit, "inherit"), (.mute, "mute"):
            item.state = .on
        case (.sound(let reference), let raw) where raw == "sound:\(reference.rawValue)":
            item.state = .on
        default:
            break
        }
        return item
    }

    @objc private func selectSoundOverride(_ sender: NSMenuItem) {
        guard let descriptor = sender.representedObject as? String,
              let divider = descriptor.firstIndex(of: "|"),
              let kind = AgentSignalKind(rawValue: String(descriptor[..<divider])) else { return }
        let raw = String(descriptor[descriptor.index(after: divider)...])
        let value: AgentSoundOverride
        if raw == "inherit" { value = .inherit }
        else if raw == "mute" { value = .mute }
        else if raw.hasPrefix("sound:") {
            value = .sound(AgentSoundReference(rawValue: String(raw.dropFirst("sound:".count))))
        } else { return }
        var next = tile
        var overrides = next.metadata.agentSoundOverrides ?? AgentSoundOverrides()
        overrides.values[kind] = value
        next.metadata.agentSoundOverrides = overrides
        tile = next
        canvas?.updateTile(next)
    }

    /// Stop following the agent. Cancels the subscription and nothing else: the
    /// agent, its runner and its record are the supervisor's, and closing a view of
    /// an agent must not kill it (locked decision). The transcript already on screen
    /// is left alone, so a detached tile still SHOWS the agent it was following;
    /// `attach` is what clears it, on the next replay.
    /// M1.4: a workspace switch is a removal, and a removal must detach. See
    /// `TileNSView.prepareForRemovalFromScene`.
    override func prepareForRemovalFromScene() {
        detach()
    }

    func detach() {
        prepareStreamingMarkupForTeardown(final: true)
        // Detach is an immediate visual/lifecycle boundary: a retained transcript
        // may remain visible, but its live Gyro tail must stop and leave the list
        // document before any later reuse.
        transcriptCollectionFixture?.setThinkingIndicatorVisible(false)
        // Clear lifecycle facts before the detached-location demotion so the
        // final compact projection keeps recent What without retaining a live
        // phase claim.
        resetCompactStatusProjection()
        settleLocationForDetach()
        locationStaleTimer?.invalidate()
        locationStaleTimer = nil
        eventSubscription?.cancel()
        eventSubscription = nil
        if let capabilityObserverToken {
            agentSource?.removeTurnCapabilitiesObserver(capabilityObserverToken)
            self.capabilityObserverToken = nil
        }
        if let runtimeObservationObserverToken, let agentID = attachedAgentID {
            agentSource?.removeRuntimeObservationObserver(runtimeObservationObserverToken, for: agentID)
            self.runtimeObservationObserverToken = nil
        }
        if let displayNameObserverToken, let agentID = attachedAgentID {
            agentSource?.removeDisplayNameObserver(displayNameObserverToken, for: agentID)
            self.displayNameObserverToken = nil
        }
        if let agentID = attachedAgentID, let v2DraftStore {
            Task { await v2DraftStore.flush(agentID: agentID) }
        }
        v2Composer?.unbindActionSink()
        v2Composer?.bindCompletionContext(nil)
        managedImageBindingGeneration &+= 1
        // Keep transcript-owned image metadata/capabilities alive while the
        // transcript remains on screen; resetProjection owns their purge.
        transcriptCollectionFixture?.bindToolDetailAgent(nil)
        v2ActionAdapter = nil
        v2TurnSnapshot = nil
        attachedAgentID = nil
        agentSource = nil
        updateV2ComposerPresentation()
    }

    /// Mirror of `NoteTileNSView.runNoteClickFocusSelfCheck` for the v2 agent
    /// tile (P5.5 correction gate, defect 5): the real canvas/broker/click-router
    /// path, which the composer-focus assertions inside `--agent-supervisor-check`
    /// bypass by installing the composer as a bare window contentView. Asserts the
    /// three ways focus reaches the editor: the broker steal (`acquireFocus`), a
    /// click on the editor glyphs, and — the shipped bug — a click on the
    /// composer's padding ring, which previously fell through to the canvas's
    /// deselect-and-steal path.
    static func runAgentComposerClickFocusSelfCheck() throws -> URL {
        enum CheckError: Error, CustomStringConvertible {
            case failed(String)
            var description: String {
                switch self {
                case let .failed(message): return message
                }
            }
        }
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw CheckError.failed(message) }
        }
        func makeMouse(_ type: NSEvent.EventType, at windowPoint: NSPoint, in window: NSWindow) throws -> NSEvent {
            guard let event = NSEvent.mouseEvent(
                with: type,
                location: windowPoint,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: type == .leftMouseUp ? 0 : 1
            ) else {
                throw CheckError.failed("could not create mouse event \(type)")
            }
            return event
        }
        func dispatchClick(at windowPoint: NSPoint, in window: NSWindow) throws {
            let down = try makeMouse(.leftMouseDown, at: windowPoint, in: window)
            let up = try makeMouse(.leftMouseUp, at: windowPoint, in: window)
            // NSTextView may enter AppKit mouse tracking during mouseDown and
            // wait for the matching mouseUp. Queue the mouseUp before sending
            // mouseDown so the production event path is exercised without a
            // self-check deadlock.
            NSApplication.shared.postEvent(up, atStart: false)
            window.sendEvent(down)
        }
        func dispatchKey(_ characters: String, in window: NSWindow) throws {
            guard let event = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: 0
            ) else {
                throw CheckError.failed("could not create key event")
            }
            window.sendEvent(event)
        }

        let tileId = UUID(uuidString: "00000000-0000-0000-0000-000000000551")!
        let tile = Tile(
            id: tileId,
            kind: .managedAgent,
            title: "AGENT_CLICK_FOCUS",
            frame: TileFrame(x: 80, y: 80, width: 420, height: 320),
            zPosition: .fromLegacyRank(1),
            runtimeRef: nil,
            metadata: TileMetadata(launchProfileId: "managed")
        )
        let canvas = CanvasNSView(canvasState: CanvasState(viewport: CanvasViewport(x: 0, y: 0, zoom: 1), tiles: [tile], groups: [], lastActiveTileId: nil))
        let focusBroker = FocusBroker()
        canvas.focusBroker = focusBroker
        canvas.frame = NSRect(x: 0, y: 0, width: 640, height: 480)

        let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = canvas
        window.orderFrontRegardless()

        let tileView = ManagedAgentTileNSView(tile: tile)
        canvas.install(tileView: tileView, for: tile)
        guard let composer = tileView.v2Composer else {
            throw CheckError.failed("v2 tile did not install its composer")
        }

        window.contentView?.layoutSubtreeIfNeeded()
        canvas.layoutSubtreeIfNeeded()
        tileView.layoutSubtreeIfNeeded()
        composer.layoutSubtreeIfNeeded()

        // 1 · the broker steal — spawn / app activation / router non-descendant
        // branch all land here. The previous base implementation targeted a plain
        // NSView and quietly focused the WINDOW.
        _ = tileView.acquireFocus(reason: .userClick)
        try expect(window.firstResponder === composer.textView,
                   "acquireFocus should land in the composer editor; firstResponder=\(String(describing: window.firstResponder))")

        // 2 · a click on the editor glyphs.
        window.makeFirstResponder(nil)
        let textLocalPoint = NSPoint(x: max(4, composer.textView.bounds.midX), y: max(4, composer.textView.bounds.midY))
        let textWindowPoint = composer.textView.convert(textLocalPoint, to: nil)
        try dispatchClick(at: textWindowPoint, in: window)
        AppDelegate.routeTileClickFocus(at: textWindowPoint, in: canvas, focusBroker: focusBroker)
        try expect(focusBroker.activeSurface == .tile(tileId),
                   "editor click should keep the tile the active surface; activeSurface=\(String(describing: focusBroker.activeSurface))")
        try expect(window.firstResponder === composer.textView,
                   "editor click should focus the editor; firstResponder=\(String(describing: window.firstResponder))")

        // 3 · the shipped bug: a click on the composer's padding ring. The click
        // ALONE must claim the editor — deliberately no router pass here, because
        // the router's steal branch (assertion 1's path) would repair it and mask
        // a shell that lets the click escape to the canvas's deselect path.
        window.makeFirstResponder(nil)
        let paddingWindowPoint = composer.convert(NSPoint(x: 6, y: composer.bounds.midY), to: nil)
        try dispatchClick(at: paddingWindowPoint, in: window)
        try expect(window.firstResponder === composer.textView,
                   "padding click alone should focus the editor; firstResponder=\(String(describing: window.firstResponder))")

        // 4 · the focus is real: a keystroke edits the draft.
        let sentinel = "x"
        try dispatchKey(sentinel, in: window)
        try expect(composer.textView.string.contains(sentinel),
                   "keyDown should edit the composer draft; got \(composer.textView.string.debugDescription)")

        let manifest: [String: Any] = [
            "check": "agent-composer-click-focus",
            "tileId": tileId.uuidString,
            "brokerActiveSurface": String(describing: focusBroker.activeSurface),
            "textWindowPoint": ["x": textWindowPoint.x, "y": textWindowPoint.y],
            "paddingWindowPoint": ["x": paddingWindowPoint.x, "y": paddingWindowPoint.y],
            "firstResponder": String(describing: window.firstResponder),
            "draft": composer.textView.string
        ]
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("qa-runs", isDirectory: true)
            .appendingPathComponent(timestamp, isDirectory: true)
            .appendingPathComponent("agent-composer-click-focus", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let artifact = directory.appendingPathComponent("manifest.json")
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: artifact, options: .atomic)
        return artifact
    }

    static func runLocationActionSurfaceSelfCheck() throws -> URL {
        enum CheckError: Error, CustomStringConvertible {
            case failed(String)
            var description: String {
                switch self {
                case let .failed(message): return message
                }
            }
        }
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw CheckError.failed(message) }
        }
        let tile = Tile(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000912")!,
            kind: .managedAgent,
            title: "LOCATION_ACTIONS",
            frame: TileFrame(x: 0, y: 0, width: 520, height: 320),
            zPosition: .fromLegacyRank(1),
            runtimeRef: nil,
            metadata: TileMetadata(launchProfileId: "managed")
        )
        let view = ManagedAgentTileNSView(tile: tile)
        view.frame = NSRect(x: 0, y: 0, width: 520, height: 320)
        let home = AgentHome(
            projectId: UUID(uuidString: "91000000-0000-4000-8000-000000000912")!,
            projectRoot: URL(fileURLWithPath: "/tmp/location-actions/project", isDirectory: true),
            checkoutRoot: URL(fileURLWithPath: "/tmp/location-actions/project", isDirectory: true)
        )
        view.applyLocationPresentationForComponentLab(AgentLocationStatusPresenter.present(
            AgentLocationSnapshot(
                home: home,
                whereDirectory: URL(fileURLWithPath: "/tmp/location-actions/other", isDirectory: true)),
            projectName: "Location Actions"
        ))
        view.layoutSubtreeIfNeeded()
        var invoked = false
        view.onLocationActionMenuRequested = { _, _ in invoked = true }
        // This fixture has no attached agent, so the app route is intentionally not
        // invoked; the status surface itself is still a keyboard-reachable button.
        try expect(view.qaLocationActionButtonAccessibilityLabel == "Location actions", "missing Location actions AX label")
        try expect(view.qaLocationActionButtonEnabled, "location actions button should be enabled")
        try expect(!view.qaLocationDetail.isEmpty, "disclosure detail should retain full Home/Where text")
        try expect(view.qaWhereOutboundMarkerVisible, "external Where marker should remain visible with actions installed")
        let manifest: [String: Any] = [
            "check": "location-action-surface",
            "actionButtonAX": view.qaLocationActionButtonAccessibilityLabel,
            "actionButtonEnabled": view.qaLocationActionButtonEnabled,
            "location": view.qaLocationText,
            "detailContainsHome": view.qaLocationDetail.contains("Home"),
            "invokedWithoutAgent": invoked
        ]
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("qa-runs", isDirectory: true)
            .appendingPathComponent(timestamp, isDirectory: true)
            .appendingPathComponent("location-action-surface", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let artifact = directory.appendingPathComponent("manifest.json")
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: artifact, options: .atomic)
        return artifact
    }

    /// The one focus override every other editable tile already has (P5.5 live
    /// finding, `plan-P5.5-review-corrections.md` defect 5): the base
    /// implementation targets `contentView` — a plain NSView that refuses first
    /// responder — so tile spawn, app activation, and the click router all left
    /// the WINDOW focused and the composer dead until the tile was selected once.
    override func acquireFocus(reason: FocusRequest) -> Bool {
        canvas?.bringToFront(tileId: tile.id)
        // Before the composer is targeted, not after: while surfaced, that text view
        // is inside the parked body, and AppKit would focus it there.
        promoteForIncomingFocus()
        if let composer = v2Composer {
            window?.makeFirstResponder(composer.textView)
            return true
        }
        return super.acquireFocus(reason: reason)
    }

    /// P2C.4: show which branch this agent's writes land on.
    ///
    /// Takes the whole `AgentRowContext` rather than two strings so that a caller
    /// which already holds a joined row (`AgentContextIndex`, Phase 3's inbox)
    /// passes it straight through, and so the mismatch rule has exactly one
    /// definition — the context's. `nil` hides the chip.
    func applyBranchContext(_ context: AgentRowContext?) {
        branchContext = context
        applyAgentHeader(status: descriptor.status)
        refreshLocationStatus()
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
        prepareStreamingMarkupForTeardown(final: true)
        model = ManagedAgentTranscriptModel(threadId: threadId, monotonicNow: projectionMonotonicNow)
        startedAt = nil
        promptInFlight = false
        descriptor.status = model.currentStatus
        agentStatus = model.currentStatus
        locationProjectName = nil
        locationStaleTimer?.invalidate()
        locationStaleTimer = nil
        lastLocationPresentation = nil
        resetCompactStatusProjection()
        transcriptAttachmentOwnerAgentID = nil
        managedImageBindingGeneration &+= 1
        managedImageMetadata.removeAll()
        managedImageRevisions.removeAll()
        managedImageAvailable.removeAll()
        managedImageHydrating.removeAll()
        applyHeader(status: model.currentStatus)
        refreshTranscriptThinkingIndicator()
        // A reset restarts the reducer's version numbering, so the forwarded
        // version can no longer be compared against it.
        lastForwardedDocumentVersion = nil
        hasRenderedRehydratedSession = false
        synchronizeV2Transcript(final: true)
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

    /// Says why a prompt was not sent, in the transcript where the user is already
    /// looking. The id carries the reason so the same refusal twice is one notice
    /// (the projection rejects a duplicate id) while a CHANGED reason — "still
    /// starting up" giving way to "logged out" — appends and is seen.
    func showSendRefusedNotice(_ text: String) {
        model.appendNotice(
            id: "notice-send-refused-\(text.hashValue)",
            title: "not sent",
            text: text
        )
        synchronizeV2Transcript(final: true)
    }

    /// The same notice seam, for a tile ACTION that failed — a chip click that
    /// opened nothing must not read as an unsent message.
    func showActionFailedNotice(_ text: String) {
        model.appendNotice(
            id: "notice-action-failed-\(text.hashValue)",
            title: "not opened",
            text: text
        )
        synchronizeV2Transcript(final: true)
    }

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
        refreshTranscriptThinkingIndicator()
        synchronizeV2Transcript(final: true)
    }

    /// Rebuilds the prior conversation from a session file the supervisor read
    /// (`.plans/03-transcript-rehydration.md`), leading with a clear "Previous
    /// session" boundary card so the restored history is legible and separated
    /// from the live turns that append below it.
    ///
    /// DISPLAY-ONLY (I5): the steps are ingested straight into THIS tile's model,
    /// never through the supervisor's event stream, so `onIngestedEvent` — which
    /// mirrors every ingested event onto the syncable activity timeline (88.4c) —
    /// does not fire for them. Same reason `showPreviousSessionNotice` appends a
    /// notice rather than ingesting a synthetic event: restored bodies must not
    /// re-cross the companion sync boundary. Idempotent so a re-wire cannot stack
    /// the history.
    func renderRehydratedPreviousSession(_ transcript: RehydratedTranscript) {
        guard !hasRenderedRehydratedSession else { return }
        hasRenderedRehydratedSession = true
        cancelStreamingMarkupParseTimer()
        model.appendNotice(
            id: "notice-previous-session",
            title: "previous session",
            text: transcript.boundaryNoticeText)
        for step in transcript.steps {
            switch step {
            case .userPrompt(let text):
                model.appendUserPrompt(text)
            case .event(let event):
                // The model filters on this tile's thread id; rebind exactly as
                // the live subscription does, but ingest DIRECTLY (never via the
                // event stream) so activity mirroring stays untriggered.
                model.ingest(event.withThreadId(threadId))
            }
        }
        // A restored agent is idle until prompted — set directly, the way
        // showPreviousSessionNotice does, not by ingesting a synthetic session
        // event (which would reach the syncable activity timeline).
        descriptor.status = .idle
        descriptor.statusUpdatedAt = Date()
        agentStatus = .idle
        applyHeader(status: .idle)
        refreshTranscriptThinkingIndicator()
        synchronizeV2Transcript(final: true)
    }

    /// Paints the submitted prompt in the SAME frame as the keystroke, before the
    /// composer performs any await.
    ///
    /// This is the first half of the dead-air fix: acknowledgement is a function of
    /// the user's action, not of how long the local draft journal, the agent-store
    /// flock and the provider handshake take. If the submission is later refused,
    /// `finishOptimisticSubmission(accepted: false)` says so explicitly rather than
    /// leaving a prompt on screen that never ran.
    private func beginOptimisticSubmission(_ prompt: AgentPrompt) {
        guard pendingOptimisticSubmissionID == nil,
              let id = AgentNodeID(rawValue: "local-prompt-\(UUID().uuidString)") else { return }
        pendingOptimisticSubmissionID = id
        cancelStreamingMarkupParseTimer()
        model.appendUserPrompt(id: id, prompt: prompt)
        // final: true — the user's own words must not wait on the 30Hz streaming gate.
        synchronizeV2Transcript(final: true)
        transcriptCollectionFixture?.setTurnInFlight(true)
        transcriptCollectionFixture?.setThinkingStatusText("Sending")
        transcriptCollectionFixture?.setThinkingIndicatorVisible(true)
    }

    private func finishOptimisticSubmission(accepted: Bool) {
        guard pendingOptimisticSubmissionID != nil else { return }
        pendingOptimisticSubmissionID = nil
        guard accepted else {
            transcriptCollectionFixture?.setTurnInFlight(false)
            transcriptCollectionFixture?.setThinkingIndicatorVisible(false)
            showSendRefusedNotice("Message was not sent. Your draft was restored; retry when ready.")
            return
        }
        // One word with the header and the sidebar, not a third vocabulary.
        transcriptCollectionFixture?.setThinkingStatusText(AgentStatusVocabulary.starting)
        transcriptCollectionFixture?.setThinkingIndicatorVisible(true)
    }

    /// Shows the prompt the user just submitted as its own "you" entry.
    ///
    /// No longer on the production submit path — `beginOptimisticSubmission` owns
    /// that. Retained for ComponentLab, the UI tour and the app's own seeding.
    func appendUserPrompt(_ text: String) {
        appendUserPrompt(AgentPrompt(text))
    }

    func appendUserPrompt(_ prompt: AgentPrompt) {
        cancelStreamingMarkupParseTimer()
        guard let id = AgentNodeID(rawValue: "local-prompt-\(UUID().uuidString)") else { return }
        model.appendUserPrompt(id: id, prompt: prompt)
        // The user's own prompt is a direct response to their keystroke; echo it
        // without waiting on the streaming gate.
        synchronizeV2Transcript(final: true)
        scheduleStreamingMarkupParseTimerIfNeeded()
    }

    func ingest(_ event: AgentRuntimeEvent, originalEvent: AgentRuntimeEvent? = nil) {
        switch event {
        case let .turnCompleted(_, _, outcome, _):
            if outcome == .completed {
                v2Composer?.confirmPromptSubmissionCompleted()
            } else {
                v2Composer?.restorePromptSubmission()
            }
        case .runtimeError, .sessionStateChanged(.stopped), .sessionStateChanged(.error):
            v2Composer?.restorePromptSubmission()
        default:
            break
        }
        // Turn-local, not session-local: each new turn resets the semantic timer.
        // AgentTileHeaderView owns the one-second repaint and never touches the
        // transcript layout beneath it.
        surfaceVisualEpoch &+= 1
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
        let captureEvent = originalEvent ?? event
        let priorEntryIDs = Set(model.document.entries.map(\.id))
        let capturedIdentity = transcriptCollectionFixture?.captureRuntimeEvent(captureEvent)
        model.ingest(event)
        if let identity = capturedIdentity,
           case let .itemStarted(_, itemID, _, _) = captureEvent {
            // Bind only the entry created by this exact item event. A historical
            // same-ID row is not a valid fallback; if the reducer did not create
            // one unambiguously, the host-local detail remains fail-closed.
            let candidates = model.document.entries.filter { entry in
                guard !priorEntryIDs.contains(entry.id),
                      case let .providerItem(provider, providerItemID) = entry.provenance else { return false }
                return provider == identity.scope.provider && providerItemID == itemID
            }
            if candidates.count == 1 {
                _ = transcriptCollectionFixture?.bindToolDetailIdentity(identity, to: candidates[0].id)
            }
        }
        refreshV2TurnSnapshot()
        updateCompactStatusFacts(for: event)
        refreshLocationStatus()
        refreshTranscriptThinkingIndicator()
        // Streamed chunks ride the 30Hz visual gate. A turn boundary or an opened
        // request is the last frame of that stream and the moment the reader acts
        // on, so it presents immediately rather than waiting out the interval.
        let settles: Bool
        switch event {
        case .turnCompleted, .runtimeError,
             .sessionStateChanged(.ready), .sessionStateChanged(.stopped), .sessionStateChanged(.error),
             .requestOpened, .requestResolved, .userInputRequested, .userInputResolved:
            settles = true
        default:
            settles = false
        }
        if settles { cancelStreamingMarkupParseTimer() }
        synchronizeV2Transcript(final: settles)
        if !settles { scheduleStreamingMarkupParseTimerIfNeeded() }
    }

    /// Seed the compact row's phase facts and context meter from the
    /// supervisor's current truth at attach time. The turn snapshot is the
    /// same authority the composer binds to; the context snapshot is demoted
    /// to `.stale` because a seeded read is not a live provider report — the
    /// next `.contextWindowUpdated` restores a live reading.
    private func seedCompactStatus(from supervisor: AgentSupervisor, agentID: AgentID) {
        if let snapshot = supervisor.turnSnapshot(for: agentID) {
            switch snapshot.state {
            case .working:
                compactStatusSession = .init(state: .running)
                compactStatusTurn = .active(
                    startedAt: snapshot.turnStartedAt, stream: nil, streamStartedAt: nil)
            case .starting:
                // The compact row already had a word for this window; the tile just
                // had no state that could reach it.
                compactStatusSession = .init(state: .starting)
                compactStatusTurn = .active(
                    startedAt: snapshot.submittedAt, stream: nil, streamStartedAt: nil)
            case .queued:
                compactStatusSession = .init(state: .starting)
            case .needsAction:
                compactStatusSession = .init(state: .running)
                compactStatusInteraction = .pending(startedAt: nil)
            case .failed:
                compactStatusSession = .init(state: .error)
                compactStatusTurn = .completed(outcome: .failed, phaseStartedAt: nil)
            case .ready, .restored:
                compactStatusSession = .init(state: .ready)
            }
        }
        if compactContextWindow == nil,
           var contextSeed = supervisor.contextWindowSnapshot(for: agentID) {
            if case .live = contextSeed.freshness { contextSeed.freshness = .stale }
            compactContextWindow = withDerivedOccupancy(contextSeed)
        }
        if compactContextWindow == nil,
           let record = supervisor.records[agentID],
           record.latestPromptAt == nil, record.latestTurnAt == nil {
            // Zero prior turns and no telemetry: the window is empty for any
            // size — seed an authoritative 0% instead of "unknown". The first
            // real provider report overwrites this through the event path.
            compactContextWindow = AgentContextWindowSnapshot(
                usedTokens: 0,
                observedAt: record.createdAt,
                source: .unknown("fresh-session"),
                freshness: .live)
        }
        refreshCompactStatus()
    }

    /// Update the compact-row facts from the same managed-agent event stream as
    /// the transcript. Events do not carry provider timestamps, so only the
    /// supervisor's stamped turn start is used as an elapsed anchor; interaction
    /// and session receipt times remain nil rather than becoming fake precision.
    private func updateCompactStatusFacts(for event: AgentRuntimeEvent) {
        switch event {
        case let .sessionStateChanged(state):
            compactStatusSession = AgentCompactStatusPhaseFacts.Session(state: state)
            // A session lifecycle event does not carry a turn/stream fact;
            // never retain a completed or prior-turn phase across it.
            compactStatusTurn = nil
            if state == .ready || state == .stopped || state == .error {
                compactStatusInteraction = nil
            }
            // A session that stopped or errored ended whatever it was doing. This
            // is the second way out of `.inFlight`, and it exists because a runner
            // that dies mid-turn never sends `.turnCompleted`.
            if state == .stopped || state == .error {
                turnLiveness = .completed
            }
        case .turnStarted:
            turnLiveness = .inFlight
            settledTurnStatusText = nil
            transcriptCollectionFixture?.setTurnInFlight(true)
            compactStatusSession = .init(state: .running, startedAt: nil)
            let start = v2TurnSnapshot?.turnStartedAt
            compactStatusTurn = .active(startedAt: start, stream: nil, streamStartedAt: nil)
        case let .contentDelta(_, _, streamKind, _):
            let start: Date?
            if case let .active(turnStart, _, _) = compactStatusTurn {
                start = turnStart
            } else {
                start = v2TurnSnapshot?.turnStartedAt
            }
            compactStatusSession = .init(state: .running, startedAt: nil)
            compactStatusTurn = .active(startedAt: start, stream: streamKind, streamStartedAt: start)
        case let .turnCompleted(_, _, outcome, _):
            // `.plans/45` S6 — "Worked for Ns" / "You stopped after Ns" (t3's
            // wording for interruptions). Anchored at submit when known —
            // provider events alone undercount the duration.
            turnLiveness = .completed
            liveToolVerb = nil
            transcriptCollectionFixture?.setTurnInFlight(false)
            let anchor = v2TurnSnapshot?.submittedAt ?? v2TurnSnapshot?.turnStartedAt
            if let anchor {
                let duration = Self.settledDurationText(Date().timeIntervalSince(anchor))
                switch outcome {
                case .completed:
                    settledTurnStatusText = "Worked for \(duration)"
                case .interrupted, .cancelled:
                    settledTurnStatusText = "You stopped after \(duration)"
                case .failed:
                    settledTurnStatusText = nil
                }
            } else {
                settledTurnStatusText = nil
            }
            compactStatusTurn = .completed(outcome: outcome, phaseStartedAt: nil)
            compactStatusSession = .init(state: .ready, startedAt: nil)
            compactStatusInteraction = .clear
        case .requestOpened, .userInputRequested:
            compactStatusInteraction = .pending(startedAt: nil)
        case .requestResolved, .userInputResolved:
            compactStatusInteraction = .clear
        case .runtimeError:
            // The third way out of `.inFlight`: a runner that throws mid-turn
            // delivers this, and without it the gyro spins forever over the
            // error row (D2, 2026-08-26).
            turnLiveness = .completed
            transcriptCollectionFixture?.setTurnInFlight(false)
            compactStatusTurn = .completed(outcome: .failed, phaseStartedAt: nil)
            compactStatusSession = .init(state: .error, startedAt: nil)
            compactStatusInteraction = .clear
        case .itemStarted, .itemCompleted, .tokenUsageUpdated, .childAgentSpawned, .semanticSignal:
            break
        case let .contextWindowUpdated(_, snapshot):
            compactContextWindow = withDerivedOccupancy(snapshot)
        }
    }

    private func refreshCompactStatus(at now: Date = Date(), location: AgentLocationSnapshot? = nil) {
        guard let snapshot = location ?? projectedAgentID.flatMap({
            agentSource?.locationSnapshot(for: $0, at: now)
        }) else {
            applyUnknownCompactStatus()
            return
        }
        let facts = AgentCompactStatusPhaseFacts(
            session: compactStatusSession,
            turn: compactStatusTurn,
            location: snapshot,
            interaction: compactStatusInteraction)
        let locationPresentation = AgentLocationStatusPresenter.present(
            snapshot,
            projectName: locationProjectName ?? branchContext?.projectName)
        lastLocationPresentation = locationPresentation
        let resolution = compactStatusPhaseAdapter.update(facts, now: now)
        compactStatusResolution = resolution
        let activity: AgentCompactStatusPresentation.Activity
        if let input = resolution.activityInput {
            let presented = AgentCompactStatusPresentation.present(
                location: snapshot,
                projectName: locationProjectName ?? branchContext?.projectName,
                activity: input,
                now: now,
                contextWindow: compactContextWindow)
            compactStatusRow.apply(presentationWithoutThinkingIndicator(presented))
            transcriptCollectionFixture?.setThinkingStatusText(Self.tailStatusText(for: presented.activity, liveToolVerb: liveToolVerb?.text))
            syncCompactStatusTick(for: presented.activity)
            return
        }
        activity = unknownCompactActivity()
        compactStatusRow.apply(presentationWithoutThinkingIndicator(AgentCompactStatusPresentation(
            location: compactLocationPresentation(snapshot, detail: locationPresentation),
            activity: activity,
            context: AgentRadialContextMeterPresenter.present(compactContextWindow))))
        transcriptCollectionFixture?.setThinkingStatusText(Self.tailStatusText(for: activity, liveToolVerb: liveToolVerb?.text))
        syncCompactStatusTick(for: activity)
    }

    /// Runs the elapsed tick exactly while the row is showing a live, elapsed-
    /// bearing phase. Silence, a missing anchor, and a detached/offscreen tile
    /// all stop it, so an idle canvas schedules nothing.
    private func syncCompactStatusTick(for activity: AgentCompactStatusPresentation.Activity) {
        let wantsTick = !activity.isSilent
            && activity.elapsedText != nil
            && window != nil
        guard wantsTick else {
            cancelCompactStatusTick()
            return
        }
        guard compactStatusTickTimer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.window != nil else {
                    // The tile went away or left the window between ticks; a
                    // repeating timer that outlives its view is a leak.
                    self?.cancelCompactStatusTick()
                    return
                }
                self.refreshCompactStatus()
            }
        }
        timer.tolerance = 0.25
        RunLoop.main.add(timer, forMode: .common)
        compactStatusTickTimer = timer
    }

    private func cancelCompactStatusTick() {
        compactStatusTickTimer?.invalidate()
        compactStatusTickTimer = nil
    }

    private func resetCompactStatusProjection(at now: Date = Date()) {
        cancelCompactStatusTick()
        compactStatusPhaseAdapter.reset()
        compactStatusResolution = .unknown
        compactStatusSession = nil
        compactStatusTurn = nil
        compactStatusInteraction = nil
        compactContextWindow = nil
        let snapshot = projectedAgentID.flatMap { agentSource?.locationSnapshot(for: $0, at: now) }
        if let snapshot {
            let detail = AgentLocationStatusPresenter.present(
                snapshot,
                projectName: locationProjectName ?? branchContext?.projectName)
            lastLocationPresentation = detail
            compactStatusRow.apply(presentationWithoutThinkingIndicator(AgentCompactStatusPresentation(
                location: compactLocationPresentation(snapshot, detail: detail),
                activity: unknownCompactActivity(),
                context: AgentRadialContextMeterPresenter.present(nil))))
        } else {
            applyUnknownCompactStatus()
        }
    }

    private func applyUnknownCompactStatus() {
        lastLocationPresentation = nil
        compactStatusResolution = .unknown
        compactStatusRow.apply(presentationWithoutThinkingIndicator(AgentCompactStatusPresentation(
            location: .init(
                symbolName: "house",
                text: "—",
                accessibilityLabel: "Home and Where: unknown.",
                detailText: "Location unavailable",
                isExternal: false),
            activity: unknownCompactActivity(),
            context: AgentRadialContextMeterPresenter.present(nil))))
    }

    /// Splits the activity by KIND between the tile's two status surfaces.
    ///
    /// Live work (thinking/reading/running/…) belongs on the gyro at the
    /// transcript tail: the spinning element and the words describing it are one
    /// object, sitting where the next output will appear. The footer keeps only
    /// what must not be missed while the gyro is absent — failure, interruption,
    /// and a pending approval — and is silent otherwise. The thinking indicator
    /// never renders in the row; the gyro is the single animated element.
    private func presentationWithoutThinkingIndicator(
        _ presentation: AgentCompactStatusPresentation
    ) -> AgentCompactStatusPresentation {
        let activity = presentation.activity
        guard !activity.isSilent, Self.footerRetainsPhase(activity.phase) else {
            return AgentCompactStatusPresentation(
                location: presentation.location,
                activity: .silent(detailText: activity.detailText),
                context: presentation.context)
        }
        return AgentCompactStatusPresentation(
            location: presentation.location,
            activity: .init(
                phase: activity.phase,
                symbolName: activity.symbolName,
                text: activity.text,
                elapsedText: activity.elapsedText,
                accessibilityLabel: activity.accessibilityLabel,
                detailText: activity.detailText,
                showsThinkingIndicator: false),
            context: presentation.context)
    }

    /// Attention states only. These occur precisely when the gyro is NOT shown
    /// (the agent is not running), so without them a failure would be invisible.
    private static func footerRetainsPhase(_ phase: AgentCompactActivityPhase) -> Bool {
        switch phase {
        case .failed, .interrupted, .waiting:
            return true
        case .starting, .thinking, .responding, .reading, .searching, .editing, .running, .ready:
            return false
        }
    }

    /// The words that ride the gyro: the live phase and its elapsed reading.
    /// Attention and idle states return nil — those are the footer's, or nobody's.
    private static func tailStatusText(
        for activity: AgentCompactStatusPresentation.Activity,
        liveToolVerb: String? = nil
    ) -> String? {
        guard !activity.isSilent, !footerRetainsPhase(activity.phase), !activity.text.isEmpty else {
            return nil
        }
        // `.plans/45` S6 — the verb carries the detail when the store knows it:
        // "Searching \u{201C}NBA finals\u{201D} · 31s", never just "searching".
        let text: String
        switch activity.phase {
        case .reading, .searching, .editing, .running:
            text = liveToolVerb ?? activity.text
        default:
            text = activity.text
        }
        guard let elapsed = activity.elapsedText, !elapsed.isEmpty else { return text }
        return "\(text) · \(elapsed)"
    }

    /// No authoritative fact means the row says nothing. A visible "Unknown" chip
    /// is the boot-time stale claim: before the first event of a session there is
    /// no live phase, and the previous session's residue must not read as one.
    private func unknownCompactActivity() -> AgentCompactStatusPresentation.Activity {
        .silent(
            detailText: "Activity phase: unknown. No authoritative session, turn, interaction, or current-tool phase fact.")
    }

    private func compactLocationPresentation(
        _ snapshot: AgentLocationSnapshot,
        detail: AgentLocationStatusPresentation
    ) -> AgentCompactStatusPresentation.Location {
        let text: String
        switch snapshot.workingLocation.relationToHome {
        case .root:
            text = snapshot.home.projectRoot?.lastPathComponent
                ?? snapshot.home.checkoutRoot.lastPathComponent
        case .inside:
            text = snapshot.workingLocation.relativePath
                ?? snapshot.workingLocation.directory.lastPathComponent
        case .outside:
            text = snapshot.workingLocation.directory.lastPathComponent.isEmpty
                ? snapshot.workingLocation.directory.path
                : snapshot.workingLocation.directory.lastPathComponent
        }
        let symbol: String
        switch snapshot.workingLocation.relationToHome {
        case .root: symbol = "house"
        case .inside: symbol = "folder"
        case .outside: symbol = "arrow.up.forward.square"
        }
        return .init(
            symbolName: symbol,
            text: text.isEmpty ? "—" : text,
            accessibilityLabel: detail.locationAccessibilityValue,
            detailText: detail.detailText,
            isExternal: snapshot.workingLocation.relationToHome == .outside)
    }

    /// QA uses the same tile composition seam to feed deterministic facts. This
    /// is intentionally a view probe, not an adapter-only assertion: the call
    /// resolves the adapter and paints the installed row in the real hierarchy.
    func qaApplyCompactStatusFacts(
        _ facts: AgentCompactStatusPhaseFacts,
        location: AgentLocationSnapshot,
        contextWindow: AgentContextWindowSnapshot? = nil,
        now: Date
    ) {
        compactStatusSession = facts.session
        compactStatusTurn = facts.turn
        compactStatusInteraction = facts.interaction
        compactContextWindow = contextWindow
        let resolution = compactStatusPhaseAdapter.update(facts, now: now)
        compactStatusResolution = resolution
        if let input = resolution.activityInput {
            lastLocationPresentation = AgentLocationStatusPresenter.present(
                location,
                projectName: locationProjectName ?? branchContext?.projectName)
            let presented = AgentCompactStatusPresentation.present(
                location: location,
                projectName: locationProjectName ?? branchContext?.projectName,
                activity: input,
                now: now,
                contextWindow: contextWindow)
            // Same split as production: footer filter, then the gyro's words.
            // A probe that skipped either would witness a surface no user sees.
            compactStatusRow.apply(presentationWithoutThinkingIndicator(presented))
            transcriptCollectionFixture?.setThinkingStatusText(Self.tailStatusText(for: presented.activity, liveToolVerb: liveToolVerb?.text))
            syncCompactStatusTick(for: presented.activity)
        } else {
            let detail = AgentLocationStatusPresenter.present(
                location,
                projectName: locationProjectName ?? branchContext?.projectName)
            lastLocationPresentation = detail
            let activity = unknownCompactActivity()
            compactStatusRow.apply(presentationWithoutThinkingIndicator(AgentCompactStatusPresentation(
                location: compactLocationPresentation(location, detail: detail),
                activity: activity,
                context: AgentRadialContextMeterPresenter.present(contextWindow))))
            transcriptCollectionFixture?.setThinkingStatusText(Self.tailStatusText(for: activity, liveToolVerb: liveToolVerb?.text))
            syncCompactStatusTick(for: activity)
        }
    }

    /// The words currently riding the gyro, for witnesses.
    var qaTailStatusText: String { transcriptCollectionFixture?.qaTailStatusText ?? "" }

    /// Fills a per-turn usage snapshot with an occupancy reading so the radial
    /// meter can show a real percentage: the prompt tokens the provider reported
    /// for the turn, over THIS agent's model's published context window. No
    /// window on file (pi's models-store absent, or a model it does not list)
    /// leaves the snapshot untouched and the ring empty.
    private func withDerivedOccupancy(
        _ snapshot: AgentContextWindowSnapshot
    ) -> AgentContextWindowSnapshot {
        AgentContextOccupancy.withDerivedOccupancy(
            snapshot,
            contextWindow: contextWindowForCurrentModel())
    }

    private func contextWindowForCurrentModel() -> Int? {
        AgentModelCatalog.shared.contextWindow(for: providerSettings.model)
    }

    /// Whether the live elapsed tick is currently scheduled. A live phase must
    /// have one (or its reading freezes); idle/silent must not (or an idle canvas
    /// wakes the run loop forever).
    var qaCompactStatusTickScheduled: Bool { compactStatusTickTimer?.isValid == true }

    func qaResetCompactStatusComposition() {
        resetCompactStatusProjection()
    }

    /// Re-read the supervisor's turn truth and repaint everything derived from it:
    /// the cached snapshot, the composer's intent state, the tile status, both
    /// headers, and the action button. One path for `ingest` and the capability
    /// seam, so the two can never disagree.
    ///
    /// Status ownership (`plan-P5.5-review-corrections.md` defect 2): when a
    /// snapshot exists, the legacy `AgentStatus` derives from the SAME presenter
    /// the v2 header paints — not from `model.currentStatus`, whose status engine
    /// counts session `.running` as working and so still says `.working` at
    /// `turn_end`. That stale value was what the activity fold stamped onto the
    /// last draft and the debounced sweep wrote over every surface. The projection
    /// derivation remains the compatibility path's, untouched.
    private func refreshV2TurnSnapshot() {
        if let agentID = attachedAgentID,
           let snapshot = agentSource?.turnSnapshot(for: agentID) {
            v2TurnSnapshot = snapshot
            v2Composer?.updateTurnSnapshot(snapshot)
            // B4: the queue mutates on the same seam (enqueue, drain, cancel,
            // clear all route through `notifyTurnCapabilitiesChanged`), so the
            // chips stay in lockstep with the primary control's own repaint.
            if let supervisor = agentSource {
                v2Composer?.updateQueuedMessages(
                    supervisor.queuedMessages(for: agentID),
                    paused: supervisor.isQueuePaused(for: agentID)
                )
            }
        }
        let status: AgentStatus
        if let snapshot = v2TurnSnapshot {
            status = AgentTileStatePresenter.present(
                name: headerAgentName ?? tile.title,
                snapshot: snapshot,
                branchContext: branchContext,
                startedAt: startedAt
            ).status
        } else {
            status = model.currentStatus
        }
        descriptor.status = status
        descriptor.statusUpdatedAt = Date()
        agentStatus = status
        applyHeader(status: status)
        updateV2ComposerPresentation()
        refreshTranscriptThinkingIndicator()
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
        locationStatus.applyTokens()
        compactStatusRow.applyTokens()
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

    /// The layer colours this view paints on subviews it owns, for
    /// `UIProbeAppearance`'s sentinel sweep. Without this the three fills adopted
    /// above sit in a blind spot: the sweep deliberately never reads a subview's
    /// layer, and these subviews are plain `NSView`s that answer for nothing.
    var qaTokenPaintedLayers: [(label: String, layer: CALayer)] {
        [("contentBackdrop", contentBackdrop), ("header", header), ("composeBackdrop", composeBackdrop)]
            .compactMap { name, view in view.layer.map { (label: name, layer: $0) } }
    }

    private func makeV2ContentView() -> NSView {
        let root = contentBackdrop
        guard let transcript = transcriptCollectionFixture,
              let composer = v2Composer,
              let actionButton = v2ActionButton else { return root }

        transcript.translatesAutoresizingMaskIntoConstraints = false
        composer.translatesAutoresizingMaskIntoConstraints = false
        providerFooter.translatesAutoresizingMaskIntoConstraints = false
        compactStatusRow.translatesAutoresizingMaskIntoConstraints = false
        actionButton.translatesAutoresizingMaskIntoConstraints = false
        providerFooter.onSettingsWrite = { [weak self] model, thinking in
            self?.writeProviderSettings(model: model, thinking: thinking) ?? false
        }
        providerFooter.onLaunchSelectionWrite = { [weak self] harness, model, thinking in
            self?.writeLaunchSelection(harness: harness, model: model, thinking: thinking) ?? false
        }
        applyProviderSettings(providerSettings)

        // The P4.10-reviewed arrangement: footer and primary action share one
        // row — the action right-aligned at its intrinsic width, the footer
        // absorbing the remainder and choosing its label variants by measured
        // fit. The shipped third-row stack predated measured fit (its comment
        // feared zero-width labels at the 320 pt floor) and was never what the
        // owner reviewed (P5.5 defect 4).
        let footerRow = NSStackView(views: [providerFooter, actionButton])
        v2FooterRow = footerRow
        footerRow.orientation = .horizontal
        footerRow.alignment = .centerY
        footerRow.spacing = CGFloat(Space.m)
        footerRow.translatesAutoresizingMaskIntoConstraints = false
        actionButton.setContentHuggingPriority(.required, for: .horizontal)
        actionButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        // Status placement is an injected composition choice. The default keeps
        // transcript → status → composer → provider controls; the alternate puts
        // status below the composer and inserts deliberate breathing room before
        // provider/model/effort/send controls.
        let statusSpacer = NSView()
        statusSpacer.identifier = NSUserInterfaceItemIdentifier("agentTile.statusProviderSpacing")
        statusSpacer.translatesAutoresizingMaskIntoConstraints = false
        let composeViews: [NSView]
        switch statusRowPlacement {
        case .aboveComposer:
            composeViews = [compactStatusRow, composer, footerRow]
        case .belowComposer:
            composeViews = [composer, compactStatusRow, statusSpacer, footerRow]
            statusSpacer.heightAnchor.constraint(equalToConstant: CGFloat(Space.l)).isActive = true
        }
        let composeColumn = NSStackView(views: composeViews)
        composeColumn.identifier = NSUserInterfaceItemIdentifier("agentTile.composeColumn")
        v2ComposeColumn = composeColumn
        composeColumn.orientation = .vertical
        composeColumn.alignment = .leading
        composeColumn.spacing = CGFloat(Space.m)
        composeColumn.edgeInsets = NSEdgeInsets(Inset.row)
        composeColumn.translatesAutoresizingMaskIntoConstraints = false
        compactStatusRow.identifier = NSUserInterfaceItemIdentifier("agentTile.statusRow")
        composer.identifier = NSUserInterfaceItemIdentifier("agentTile.composer")
        footerRow.identifier = NSUserInterfaceItemIdentifier("agentTile.providerControls")
        composeBackdrop.addSubview(composeColumn)

        locationStatus.isHidden = true
        let layout = NSStackView(views: [agentHeader, locationStatus, transcript, composeBackdrop])
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
            locationStatus.widthAnchor.constraint(equalTo: layout.widthAnchor),
            transcript.widthAnchor.constraint(equalTo: layout.widthAnchor),
            composeBackdrop.widthAnchor.constraint(equalTo: layout.widthAnchor),
            composeColumn.leadingAnchor.constraint(equalTo: composeBackdrop.leadingAnchor),
            composeColumn.trailingAnchor.constraint(equalTo: composeBackdrop.trailingAnchor),
            composeColumn.topAnchor.constraint(equalTo: composeBackdrop.topAnchor),
            composeColumn.bottomAnchor.constraint(equalTo: composeBackdrop.bottomAnchor),
            composer.widthAnchor.constraint(equalTo: composeColumn.widthAnchor, constant: -Inset.row.horizontal),
            footerRow.widthAnchor.constraint(equalTo: composeColumn.widthAnchor, constant: -Inset.row.horizontal),
            compactStatusRow.widthAnchor.constraint(equalTo: composeColumn.widthAnchor, constant: -Inset.row.horizontal),
            compactStatusRow.heightAnchor.constraint(equalToConstant: AgentCompactStatusRowView.preferredHeight),
            providerFooter.heightAnchor.constraint(equalToConstant: AgentComposerFooterView.height),
            actionButton.heightAnchor.constraint(equalToConstant: ComposerActionButton.controlHeight),
        ])
        composeBackdrop.setContentHuggingPriority(.required, for: .vertical)
        composeBackdrop.setContentCompressionResistancePriority(.required, for: .vertical)
        composer.layer?.borderColor = AgentLineRole.controlBoundary.color.cgColor(for: effectiveTokenTheme)
        return root
    }

    /// Whether the transcript tail carries the gyro and its words.
    ///
    /// The tail does NOT yield to streaming text. It used to: this returned
    /// `statusIsActive && !latestStreamIsVisible`, where `latestStreamIsVisible`
    /// meant "the last entry is an OPEN assistant or reasoning entry" — which is
    /// the entire duration of the answer. So the gyro, the ONLY animated element
    /// in the transcript, switched off on the first delta and nothing replaced
    /// it: the compact row is deliberately silent for exactly the live phases
    /// (`presentationWithoutThinkingIndicator`, `footerRetainsPhase`) BECAUSE the
    /// gyro was supposed to carry them, so both surfaces went quiet for the
    /// longest and most-watched part of a turn. Dylan: "the response looks
    /// dead... there is no indicator that the response is streaming in."
    ///
    /// Growing glyphs are not a liveness signal — a partial paragraph is
    /// pixel-identical to a finished one, and a pause between sentences is
    /// indistinguishable from a stall. So a tool call running MID-answer keeps
    /// the tail up, where the old predicate suppressed it whether or not work was
    /// happening, because it keyed on the open entry rather than on the work.
    ///
    /// But the status is NOT the whole authority, and briefly making it so was a
    /// regression. The removed term had been an accidental safety net: a turn that
    /// ended without `descriptor.status` flipping still had an open assistant
    /// entry, so the tail went quiet. Without it the same stall spins forever.
    /// `TurnLiveness` is the deliberate replacement — an authority that moves with
    /// the event stream the rows themselves come from, and that has two ways out
    /// of "running" rather than none.
    ///
    /// `document` is taken, and deliberately unread, so that the witness for this
    /// rule can hand it a real streaming document and so that reintroducing the
    /// old term has somewhere to go wrong. Extracted from the body only because
    /// `statusIsActive` needs a live supervisor and this rule does not: a witness
    /// can drive the real decision without standing one up.
    /// Where a turn actually stands, according to the event stream that carries
    /// the content — as opposed to `descriptor.status`, which is republished
    /// asynchronously by the supervisor and can still say `.working` well after a
    /// turn has ended (and, on a stalled runner, forever).
    enum TurnLiveness {
        /// No turn boundary has been seen on this attachment yet — a tile that
        /// attached mid-turn, or one replaying restored history. The status is the
        /// only authority available, so it is deferred to.
        case unknown
        case inFlight
        case completed
    }

    static func showsWorkingTail(
        statusIsActive: Bool, document: AgentDocument, turnLiveness: TurnLiveness
    ) -> Bool {
        _ = document
        guard statusIsActive else { return false }
        // A completed turn takes the tail down even while the status still says
        // otherwise. `descriptor.status` is republished asynchronously and lags a
        // turn's own completion event; on a runner that stalls it never flips at
        // all. Deferring to it alone is what let the gyro spin after the agent was
        // done — "the agent is done but i still see it".
        return turnLiveness != .completed
    }

    private func refreshTranscriptThinkingIndicator() {
        guard let transcriptCollectionFixture else { return }
        // `.plans/45` S6 (C4) — the optimistic window. `beginOptimisticSubmission`
        // turns the indicator on the instant the user sends; the next transcript
        // synchronize used to re-derive visibility from `descriptor.status ==
        // .working`, which has not flipped yet, and stomp it off — the "blank
        // for a while after sending" Dylan rejected. While a submission is
        // pending acknowledgement, the optimistic answer stands.
        if pendingOptimisticSubmissionID != nil {
            transcriptCollectionFixture.setThinkingIndicatorVisible(true)
            return
        }
        let statusIsActive: Bool
        if let agentID = attachedAgentID,
           let agentSource,
           eventSubscription != nil,
           descriptor.status == .working {
            statusIsActive = agentSource.isRunning(agentID)
        } else {
            statusIsActive = false
        }
        let showsWorkingTail = Self.showsWorkingTail(
            statusIsActive: statusIsActive, document: model.document,
            turnLiveness: turnLiveness)
        if !statusIsActive, let settledTurnStatusText {
            transcriptCollectionFixture.setSettledTailStatus(settledTurnStatusText)
            return
        }
        transcriptCollectionFixture.setThinkingIndicatorVisible(showsWorkingTail)
    }

    /// `.plans/45` S6 — the live tool verb, derived from whitelisted detail
    /// fields only (query/url/pattern/basename/description); a command body can
    /// never reach the tail because it never enters an observation.
    private func updateLiveToolVerb(for observation: AgentRuntimeObservation) {
        guard case let .toolDetail(itemID, detail) = observation else { return }
        switch detail.phase {
        case .started:
            guard let verb = Self.liveToolVerbText(for: detail) else { return }
            liveToolVerb = (itemID, verb)
            refreshCompactStatus()
        case .ended:
            guard liveToolVerb?.itemID == itemID else { return }
            liveToolVerb = nil
            refreshCompactStatus()
        }
    }

    static func liveToolVerbText(for detail: AgentToolDetailObservation) -> String? {
        var fields: [String: String] = [:]
        for field in detail.fields where fields[field.key] == nil {
            fields[field.key] = field.value
        }
        if let query = fields["query"] { return "Searching \u{201C}\(query)\u{201D}" }
        if let pattern = fields["pattern"] { return "Searching \u{201C}\(pattern)\u{201D}" }
        if let url = fields["url"] { return "Fetching \(url)" }
        if let file = fields["file"] {
            let name = (detail.toolName ?? "").lowercased()
            return name.contains("read") ? "Reading \(file)" : "Editing \(file)"
        }
        if let description = fields["description"], let first = description.first {
            return first.uppercased() + description.dropFirst()
        }
        return nil
    }

    /// Fine-grained for settled turns (t3's formatter split): "4.3s" under ten
    /// seconds — with the 9.95s carve-out so it never reads "10.0s" — then
    /// whole seconds, then "3m 20s".
    static func settledDurationText(_ interval: TimeInterval) -> String {
        let clamped = max(0, interval)
        if clamped < 9.95 { return String(format: "%.1fs", clamped) }
        if clamped < 60 { return "\(Int(clamped.rounded()))s" }
        let minutes = Int(clamped) / 60
        let seconds = Int(clamped) % 60
        return seconds == 0 ? "\(minutes)m" : "\(minutes)m \(seconds)s"
    }

    private var managedImageResourceProvider: AgentImageResourceProvider {
        AgentImageResourceProvider(
            snapshot: { [weak self] id in
                MainActor.assumeIsolated {
                    self?.managedImageSnapshot(id)
                        ?? AgentImageResourceSnapshot(attachmentID: id, state: .missing)
                }
            },
            requestThumbnail: { [weak self] id, target, revision, completion in
                MainActor.assumeIsolated {
                    self?.requestManagedImageThumbnail(
                        id: id, target: target, revision: revision, completion: completion
                    ) ?? AgentImageThumbnailRequest()
                }
            },
            observe: { _, _ in AgentImageResourceObservation() }
        )
    }

    private func managedImageSnapshot(_ id: AgentImageAttachmentID) -> AgentImageResourceSnapshot {
        guard let metadata = managedImageMetadata[id] else {
            return AgentImageResourceSnapshot(attachmentID: id, state: .missing)
        }
        let state: AgentImageResourceState
        if managedImageAvailable.contains(id) {
            state = .available
        } else if v2AttachmentStore != nil, transcriptAttachmentOwnerAgentID != nil {
            state = .processing
        } else {
            state = .missing
        }
        return AgentImageResourceSnapshot(
            attachmentID: id,
            state: state,
            revision: managedImageRevisions[id] ?? 0,
            pixelSize: metadata.pixelWidth.flatMap { width in
                metadata.pixelHeight.map { NSSize(width: CGFloat(width), height: CGFloat($0)) }
            },
            displayName: metadata.displayName,
            contentType: metadata.contentType,
            byteCount: metadata.byteCount)
    }

    private func requestManagedImageThumbnail(
        id: AgentImageAttachmentID,
        target: NSSize,
        revision: UInt64,
        completion: @escaping @MainActor (AgentImageThumbnailResult) -> Void
    ) -> AgentImageThumbnailRequest {
        guard let store = v2AttachmentStore, let agentID = transcriptAttachmentOwnerAgentID else {
            completion(.failed)
            return AgentImageThumbnailRequest()
        }
        let bindingGeneration = managedImageBindingGeneration
        var task: Task<Void, Never>?
        let request = AgentImageThumbnailRequest { task?.cancel() }
        task = Task { @MainActor [weak self] in
            guard let self, self.managedImageBindingGeneration == bindingGeneration, !request.isCancelled,
                  let stored = try? await store.storedAttachment(for: id),
                  Self.isManagedImage(stored, for: agentID),
                  let localURL = AgentImageFileValidator.validatedLocalImageFile(stored.fileURL),
                  !request.isCancelled else {
                if !request.isCancelled { completion(.failed) }
                return
            }
            do {
                let maxPixelSize = max(1, Int(ceil(max(target.width, target.height))))
                let thumbnail = try await managedImageThumbnailPipeline.thumbnail(
                    for: localURL, maxPixelSize: maxPixelSize)
                guard !request.isCancelled,
                      self.managedImageBindingGeneration == bindingGeneration,
                      let image = NSImage(data: thumbnail.pngData) else {
                    return
                }
                completion(.success(AgentImageThumbnail(
                    attachmentID: id,
                    revision: revision,
                    image: image,
                    pixelSize: NSSize(width: thumbnail.pixelWidth, height: thumbnail.pixelHeight))))
            } catch is CancellationError {
                // A reused/offscreen cell cancelled its lease; do not publish a
                // stale completion into the new cell.
            } catch {
                if !request.isCancelled { completion(.failed) }
            }
        }
        return request
    }

    private static func isManagedImage(
        _ stored: AgentComposerStoredAttachment,
        for agentID: AgentID
    ) -> Bool {
        guard stored.manifest.ownership.agentID == agentID else { return false }
        switch stored.manifest.ownership.state {
        case .draft, .sent: return true
        }
    }

    private func hydrateManagedImagesFromDocument() {
        guard let store = v2AttachmentStore,
              let agentID = transcriptAttachmentOwnerAgentID else { return }
        var metadataByID: [AgentImageAttachmentID: AgentImageAttachmentMetadata] = [:]
        func collect(_ block: AgentBlock) {
            switch block.payload {
            case let .image(payload): metadataByID[payload.attachment.id] = payload.attachment
            case let .imageGallery(payload):
                payload.images.forEach { metadataByID[$0.attachment.id] = $0.attachment }
            default: break
            }
            block.children.forEach(collect)
        }
        model.document.entries.flatMap(\.blocks).forEach(collect)
        let bindingGeneration = managedImageBindingGeneration
        for (id, metadata) in metadataByID {
            managedImageMetadata[id] = metadata
            guard !managedImageAvailable.contains(id), !managedImageHydrating.contains(id) else { continue }
            managedImageHydrating.insert(id)
            Task { @MainActor [weak self] in
                defer { self?.managedImageHydrating.remove(id) }
                guard let self, self.managedImageBindingGeneration == bindingGeneration,
                      let stored = try? await store.storedAttachment(for: id),
                      Self.isManagedImage(stored, for: agentID),
                      AgentImageFileValidator.validatedLocalImageFile(stored.fileURL) != nil else { return }
                self.managedImageMetadata[id] = stored.manifest.metadata
                self.managedImageAvailable.insert(id)
                self.managedImageRevisions[id, default: 0] &+= 1
                try? self.transcriptCollectionFixture?.updateRenderContext(self.v2RenderContext)
            }
        }
    }

    private func resolveManagedImageAction(
        blockID: AgentNodeID,
        attachmentID: AgentImageAttachmentID,
        action: AgentRenderAction
    ) {
        guard imageAttachment(attachmentID, belongsTo: blockID),
              let store = v2AttachmentStore,
              let agentID = transcriptAttachmentOwnerAgentID else { return }
        let bindingGeneration = managedImageBindingGeneration
        Task { @MainActor [weak self] in
            guard let self, self.managedImageBindingGeneration == bindingGeneration,
                  self.transcriptAttachmentOwnerAgentID == agentID,
                  let stored = try? await store.storedAttachment(for: attachmentID),
                  Self.isManagedImage(stored, for: agentID),
                  let resource = AgentImageActionResource(
                    attachmentID: attachmentID,
                    localFileURL: stored.fileURL,
                    displayName: stored.manifest.metadata.displayName) else { return }
            switch action {
            case .previewImage: self.imagePreviewController.preview(localFileURL: resource.localFileURL)
            case .copyImage: _ = AgentImageAppKitActions.copy(resource)
            case .saveImageAs: AgentImageAppKitActions.saveAs(resource, from: self)
            case .revealImage: AgentImageAppKitActions.reveal(resource)
            default: break
            }
        }
    }

    private func imageAttachment(
        _ attachmentID: AgentImageAttachmentID,
        belongsTo blockID: AgentNodeID
    ) -> Bool {
        func contains(_ block: AgentBlock) -> Bool {
            switch block.payload {
            case let .image(payload):
                return payload.attachment.id == attachmentID
            case let .imageGallery(payload):
                return payload.images.contains { $0.attachment.id == attachmentID }
            default:
                return block.children.contains(where: contains)
            }
        }
        return model.document.entries.flatMap(\.blocks).first(where: { $0.id == blockID }).map(contains) == true
    }

    private var v2RenderContext: AgentRenderContext {
        AgentRenderContext(
            actions: AgentRenderActions { [weak self] action in
                self?.performV2RenderAction(action)
            },
            tokens: .transcript,
            appearance: effectiveTokenTheme,
            imageResources: managedImageResourceProvider,
            agentStatus: agentReferenceStatusSource
        )
    }

    /// C10: built from `agentSource` (the supervisor), never from anything the
    /// document carries. `turnSnapshot(for:)` and `addTurnCapabilitiesObserver`
    /// are both already tile-independent production seams — the same ones a
    /// headless/cross-project agent's row already resolves through — so a chip
    /// referencing a tile-less child works exactly like one referencing a
    /// tiled one.
    private var agentReferenceStatusSource: AgentReferenceStatusSource {
        guard let supervisor = agentSource else { return .unavailable }
        return AgentReferenceStatusSource(
            current: { [weak supervisor] rawAgentID in
                guard let supervisor else { return nil }
                let agentID = AgentID(rawValue: rawAgentID)
                guard let snapshot = supervisor.turnSnapshot(for: agentID) else { return nil }
                return InboxState.state(forSnapshot: snapshot)
            },
            subscribe: { [weak supervisor] rawAgentID, callback in
                guard let supervisor else { return nil }
                let agentID = AgentID(rawValue: rawAgentID)
                return supervisor.addTurnCapabilitiesObserver { [weak supervisor] changedID in
                    guard changedID == agentID, let supervisor else { return }
                    callback(supervisor.turnSnapshot(for: agentID).map { InboxState.state(forSnapshot: $0) })
                }
            },
            unsubscribe: { [weak supervisor] token in
                supervisor?.removeTurnCapabilitiesObserver(token)
            }
        )
    }

    private func cancelStreamingMarkupParseTimer() {
        streamingMarkupParseTimer?.invalidate()
        streamingMarkupParseTimer = nil
        streamingMarkupParseTimerScheduledDelay = nil
        streamingMarkupParseTimerGeneration &+= 1
    }

    private func scheduleStreamingMarkupParseTimerIfNeeded() {
        cancelStreamingMarkupParseTimer()
        guard let deadline = model.nextStreamingMarkupParseDeadline else { return }
        let generation = streamingMarkupParseTimerGeneration
        let delay = max(0, deadline - projectionMonotonicNow())
        streamingMarkupParseTimerScheduledDelay = delay
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.streamingMarkupParseTimerFired(generation: generation)
            }
        }
        streamingMarkupParseTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func streamingMarkupParseTimerFired(generation: UInt64) {
        guard generation == streamingMarkupParseTimerGeneration else { return }
        streamingMarkupParseTimer = nil
        streamingMarkupParseTimerScheduledDelay = nil
        if model.flushPendingStreamingMarkupIfDue() {
            synchronizeV2Transcript()
        }
        scheduleStreamingMarkupParseTimerIfNeeded()
    }

    private func flushPendingStreamingMarkupForBoundary(final: Bool) {
        if model.flushPendingStreamingMarkup() {
            synchronizeV2Transcript(final: final)
        }
    }

    private func prepareStreamingMarkupForTeardown(final: Bool) {
        flushPendingStreamingMarkupForBoundary(final: final)
        cancelStreamingMarkupParseTimer()
    }

    private func synchronizeV2Transcript(final: Bool = false) {
        guard let transcript = transcriptCollectionFixture else { return }
        // The content reducer owns the semantic document (locked rule 6): request
        // blocks arrive from AgentTranscriptProjection like every other event, so
        // the tile composes and never maintains a parallel request model. The
        // list consumes view-generation versions (reducer versions advance once
        // per mutation, the list contract requires exactly-once steps), and a
        // projection reset converges the same way: the emptied document diffs
        // against the last rendered snapshot and removes every stale row.
        // Change detection is the reducer's version, not an `entries` comparison.
        // `contentDelta` arrives once per streamed chunk, and comparing entries
        // deep-compared every block's text in the entire transcript on every
        // chunk — so per-chunk cost grew with conversation length and long
        // sessions stalled the main thread.
        let document = model.document
        hydrateManagedImagesFromDocument()
        refreshReplyOptions(from: document)
        guard document.version != lastForwardedDocumentVersion else { return }
        lastForwardedDocumentVersion = document.version
        let next = AgentDocument(version: v2RenderedDocument.version &+ 1, entries: document.entries)
        do {
            // The patch carries the REDUCER'S OWN changed set, drained from the
            // model. `enqueue` gates presentation at 30Hz and unions these across
            // everything it coalesces, so the list is told exactly which nodes
            // moved rather than rediscovering it.
            //
            // The empty patch this replaces was not a small thing. It left
            // `applyCoalesced` with no locality at all, so every streaming chunk
            // took the full walk: flatten the whole document, build an O(rows)
            // index, diff every row's content, rebuild every per-row structure.
            // Measured at 93ms per delta over 10,000 rows — and invisible, because
            // the gate drove `apply(document:patch:)`, which has no production
            // callers at all.
            //
            // Deriving the set HERE by diffing documents would be the old mistake
            // in a new place: this asks the reducer, which already computed it,
            // and costs a set union per chunk.
            let touched = model.drainTouchedNodes()
            let patch: AgentDocumentPatch
            if touched.isStructural || touched.ids.isEmpty {
                patch = try AgentDocumentPatch.empty(fromVersion: v2RenderedDocument.version)
            } else {
                patch = try AgentDocumentPatch(
                    fromVersion: v2RenderedDocument.version,
                    toVersion: next.version,
                    updated: Array(touched.ids))
            }
            try transcript.enqueue(document: next, patch: patch, final: final)
            v2RenderedDocument = next
            v2RenderError = nil
            if case .needsAction = v2TurnSnapshot?.state {
                // A pending request is an interaction boundary, not a streaming
                // frame: present it before scrolling so the anchor resolves
                // against the rows the reader is about to act on.
                transcript.flushPendingVisualUpdate()
                transcript.jumpToLatest()
            }
        } catch {
            v2RenderError = error
        }
    }

    /// Offers the choices the last settled turn asked for as composer chips.
    ///
    /// Deliberately NOT routed through the request/approval system: no harness
    /// opened a request here, so there is nothing to resolve and nothing may
    /// claim otherwise (see `AgentReplyOptionDetector`). A working turn withdraws
    /// the offer outright — the question it belongs to has already been answered
    /// by whatever the user just sent.
    private func refreshReplyOptions(from document: AgentDocument) {
        guard let composer = v2Composer else { return }
        let working = v2TurnSnapshot?.state == .working
        composer.setReplyOptions(working ? [] : AgentReplyOptionDetector.options(in: document))
    }

    private func performV2RenderAction(_ action: AgentRenderAction) {
        switch action {
        case let .previewImage(blockID, attachmentID),
             let .copyImage(blockID, attachmentID),
             let .saveImageAs(blockID, attachmentID),
             let .revealImage(blockID, attachmentID):
            resolveManagedImageAction(blockID: blockID, attachmentID: attachmentID, action: action)
            return
        case let .openLocalFile(_, destination):
            // The tile forwards the RAW authored destination and nothing else. The
            // app owns resolution: only it knows this tile's agent, and only that
            // agent's live cwd may resolve a relative path.
            onOpenLocalFile?(destination)
            return
        case let .activateLink(_, url, target):
            onOpenWebLink?(url, target)
            return
        case let .revealAgent(_, agentID, parentAgentID):
            onRevealAgent?(AgentID(rawValue: agentID), AgentID(rawValue: parentAgentID))
            return
        case .submitResponse:
            break
        default:
            return
        }
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
        v2Composer?.requestStop()
    }

    private func updateV2ComposerPresentation() {
        guard let button = v2ActionButton else { return }
        // One source of truth: the supervisor's live snapshot, not the cached copy
        // — the cache is exactly what latched "Unavailable" in the P5.5 live
        // finding. The cache remains only for callers with no live source (fixture
        // tiles, post-detach repaints).
        let snapshot: AgentTileTurnSnapshot?
        if let agentID = attachedAgentID, let live = agentSource?.turnSnapshot(for: agentID) {
            snapshot = live
        } else {
            snapshot = v2TurnSnapshot
        }
        // C5 — an agent Array MIRRORS has no runner behind it, so the composer and
        // the Stop are not "unavailable right now", they are not applicable at
        // all. A disabled control says try later; there is no later. The
        // transcript and the status row stay: watching is the whole point.
        let mirrored = snapshot?.isMirrored ?? false
        v2Composer?.isHidden = mirrored
        v2FooterRow?.isHidden = mirrored
        if mirrored {
            button.presentation = .resolve(
                state: .ready,
                capabilities: .init(canSend: false, canStop: false, canSteer: false, canQueue: false),
                hasDraft: false)
            providerFooter.controlsEnabled = false
            return
        }
        let capabilities = snapshot?.capabilities ?? .init()
        // With a snapshot, its execution state alone decides; the legacy
        // `descriptor.status` OR-terms re-imported the disagreeing derivation this
        // correction removes. Without one, the legacy status is all there is.
        let isWorking = snapshot.map { $0.executionState == .working }
            ?? (descriptor.status == .working || descriptor.status == .needsAttention)
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
        // In flight, not merely working (P5.5 consolidation): the pickers must
        // stay dark from send until the runner slot frees, or they flash
        // re-enabled during the spawn and drain windows a mid-turn pick still
        // cannot reach.
        providerFooter.controlsEnabled = !(isWorking || capabilities.canStop)
    }

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
        refreshTitleBarIdentity()
    }

    func applyLaunchSelection(_ selection: AgentLaunchSelection) {
        providerSettings = AgentModelConfig.Resolution(model: selection.model, thinking: selection.thinking)
        providerFooter.apply(selection)
        refreshTitleBarIdentity()
    }

    private func writeLaunchSelection(harness: AgentHarness, model: String, thinking: String) -> Bool {
        guard let agentID = attachedAgentID, let agentSource else { return false }
        guard agentSource.setProviderSettings(agentID: agentID, harness: harness, model: model, thinking: thinking) else {
            if let actual = agentSource.launchSelection(for: agentID) { applyLaunchSelection(actual) }
            return false
        }
        applyLaunchSelection(AgentLaunchSelection(harness: harness, model: model, thinking: thinking))
        return true
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

    private var composeIsBusy: Bool { promptInFlight || descriptor.status == .working }

    private func applyHeader(status: AgentStatus) {
        refreshTitleBarIdentity()
        applyAgentHeader(status: status)
    }

    private func refreshTitleBarIdentity() {
        let recordName = attachedAgentID
            .flatMap { agentSource?.records[$0]?.humanDisplayName }
        let candidate = recordName ?? headerAgentName ?? AgentRecord.defaultAgentName
        let name = AgentName.displayTitle(
            candidate,
            model: providerSettings.model,
            id: attachedAgentID?.rawValue
        )
        setTitleBarIdentity(
            title: "Agent · \(name)",
            providerModel: providerSettings.model
        )
    }

    private func applyAgentHeader(status: AgentStatus) {
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

    /// A detached tile keeps showing the agent it previously represented, but it
    /// no longer observes that agent. Demote current What immediately rather than
    /// freezing a claim such as “Reading” forever after its source/timer is gone.
    private func settleLocationForDetach(at now: Date = Date()) {
        guard let agentID = projectedAgentID,
              let snapshot = agentSource?.locationSnapshot(for: agentID, at: now) else { return }
        let settled = AgentLocationSnapshot(
            home: snapshot.home,
            whereDirectory: snapshot.workingLocation.directory,
            lastUsefulWhat: snapshot.lastUsefulWhat)
        refreshCompactStatus(at: now, location: settled)
    }

    private func refreshLocationStatus(at now: Date = Date()) {
        locationStaleTimer?.invalidate()
        locationStaleTimer = nil
        guard let agentID = projectedAgentID,
              let snapshot = agentSource?.locationSnapshot(for: agentID, at: now) else { return }
        refreshCompactStatus(at: now, location: snapshot)
        guard let expiresAt = snapshot.whatExpiresAt, expiresAt > now else { return }
        let timer = Timer(timeInterval: expiresAt.timeIntervalSince(now), repeats: false) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.refreshLocationStatus(at: expiresAt) }
        }
        RunLoop.main.add(timer, forMode: .common)
        locationStaleTimer = timer
    }

    override func sync(tile: Tile) {
        super.sync(tile: tile)
        applyHeader(status: descriptor.status)
    }

    // P1.8 deleted this view's private glyph/phase/colour maps. They were one of
    // the three disagreeing glyph sets (`◌` here meant *configuring*, in the
    // sidebar it meant *stale*) and they had drifted from the board's hues.
    // Everything now comes from `StatusChipPresenter`.

    /// The cards actually in the view hierarchy, so a reset can be asserted against
    /// the stack and not only against the model behind it.
    var qaRenderedCardCount: Int {
        transcriptCollectionFixture?.qaSemanticRowCount ?? 0
    }
    var qaTranscriptCollectionFixture: AgentTranscriptListView? { transcriptCollectionFixture }
    /// The compact row is exposed only as a deterministic geometry/AX witness;
    /// production updates it through `refreshCompactStatus` above.
    var qaCompactStatusRow: AgentCompactStatusRowView { compactStatusRow }
    var qaThinkingIndicatorVisible: Bool { transcriptCollectionFixture?.qaThinkingIndicatorVisible == true }
    // `.plans/45` S6 — deterministic seams for the optimistic-window witness.
    func qaBeginOptimisticSubmissionForChecks(_ text: String) {
        beginOptimisticSubmission(AgentPrompt(text))
    }
    func qaRefreshThinkingIndicatorForChecks() {
        refreshTranscriptThinkingIndicator()
    }
    var qaTranscriptForChecks: AgentTranscriptListView? { transcriptCollectionFixture }
    var qaDocumentForChecks: AgentDocument { model.document }
    var qaStatusThinkingIndicatorVisible: Bool { compactStatusRow.qaThinkingSlotVisible }
    var qaCompactStatusPhase: AgentCompactActivityPhase? { compactStatusResolution.phase }
    var qaCompactStatusContextState: AgentRadialContextMeterState { compactStatusRow.qaContextState }
    var qaCompactStatusContextFraction: Double? { compactStatusRow.qaContextFraction }
    var qaCompactStatusActivityText: String { compactStatusRow.qaActivityText }
    var qaCompactStatusAccessibilityLabel: String { compactStatusRow.qaAccessibilityLabel }
    var qaCompactStatusHasVisiblePrefixes: Bool { compactStatusRow.qaHasVisiblePrefixes }
    var qaCompactStatusContentFitsBounds: Bool { compactStatusRow.qaContentFitsBounds }
    var qaCompactStatusRowIsInstalled: Bool { compactStatusRow.superview != nil }
    var qaLegacyLocationStatusIsHidden: Bool { locationStatus.isHidden }
    var qaComposeEnabled: Bool {
        !composeIsBusy
    }
    var qaUsesV2Tile: Bool { true }
    var qaUsesFullTurnComposer: Bool {
        guard let composer = v2Composer, composer.superview != nil else { return false }
        if case .fullTurn = composer.variant { return true }
        return false
    }
    /// Structural probes over the LIVE view tree: after the P5.5 removal the
    /// legacy members no longer exist, so reachability is asserted by scanning
    /// for the classes the old path installed — a reintroduction fails the same
    /// assertions the removal satisfied.
    var qaHasLegacyComposeField: Bool {
        func containsBezeledField(_ view: NSView) -> Bool {
            if let field = view as? NSTextField, field.isBezeled { return true }
            return view.subviews.contains(where: containsBezeledField)
        }
        return contentView.map(containsBezeledField) ?? false
    }
    /// P5.5 deleted `UserInputCardView` and `ApprovalDockView` with the legacy
    /// path, so absence is a compile-time fact; these remain for the checks that
    /// assert the old UI is unreachable.
    var qaUserInputCardCount: Int { 0 }
    var qaHasPermanentApprovalDock: Bool { false }
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
    /// The reply-option chips the composer is currently offering, and a press
    /// through the real button. Read from the installed composer, never from a
    /// tile-side copy of the detector's answer.
    var qaReplyOptionChipTitles: [String] { v2Composer?.qaReplyOptionChipTitles ?? [] }
    var qaComposerDraftText: String { v2Composer?.qaDraftText ?? "" }
    @discardableResult
    func qaPressReplyOptionChip(titled title: String) -> Bool {
        v2Composer?.qaPressReplyOptionChip(titled: title) ?? false
    }
    var qaV2CanSend: Bool { v2TurnSnapshot?.capabilities.canSend == true }
    /// C5's witness surface: what a mirrored agent's tile actually offers.
    /// Drives the SAME presentation update production drives, from a snapshot of
    /// the shape `AgentSupervisor.turnSnapshot(for:)` produces. A check that set
    /// the hidden flags itself would pass while the tile still painted them.
    func qaApplyTurnSnapshotForChecks(_ snapshot: AgentTileTurnSnapshot) {
        v2TurnSnapshot = snapshot
        v2Composer?.updateTurnSnapshot(snapshot)
        updateV2ComposerPresentation()
    }

    var qaComposerIsOffered: Bool { !(v2Composer?.isHidden ?? true) }
    var qaProviderControlsAreOffered: Bool { !(v2FooterRow?.isHidden ?? true) }
    var qaV2ActionTitle: String? { v2ActionButton?.presentation.title }
    var qaV2ActionEnabled: Bool { v2ActionButton?.presentation.isEnabled == true }
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
    var qaProviderFooterView: AgentComposerFooterView { providerFooter }
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
    func qaPickHarness(_ harness: AgentHarness) -> Bool { providerFooter.qaPickHarness(harness) }
    @discardableResult
    func qaPickThinking(_ thinking: String) -> Bool { providerFooter.qaPickThinking(thinking) }
    /// nil when the chip is hidden, so "no branch is shown" and "an empty branch is
    /// shown" cannot be confused.
    var qaBranchChipText: String? {
        // `--agent-supervisor-check` consumes this accessor for unbound, isolated,
        // shared, and moved-checkout tiles. Return the INSTALLED header's chip so
        // the deterministic branch assertions exercise this shell. A shell/action
        // regression becomes an explicit check failure.
        guard qaV2HeaderContractHolds() else { return qaV2HeaderFailure }
        return agentHeader.qaBranch
    }
    /// Component Lab builds the real tile without an AgentStore/Supervisor. This
    /// preview-only seam paints the same host-local presentation production applies
    /// after attach; it accepts no snapshot/path-bearing model and publishes nothing.
    func applyLocationPresentationForComponentLab(
        _ presentation: AgentLocationStatusPresentation
    ) {
        lastLocationPresentation = presentation
        compactStatusRow.apply(AgentCompactStatusPresentation(
            location: .init(
                symbolName: presentation.whereIsExternal ? "arrow.up.forward.square" : "folder",
                text: presentation.locationText,
                accessibilityLabel: presentation.locationAccessibilityValue,
                detailText: presentation.detailText,
                isExternal: presentation.whereIsExternal),
            activity: .init(
                phase: .ready,
                symbolName: "checkmark.circle",
                text: presentation.whatText,
                elapsedText: nil,
                accessibilityLabel: presentation.whatAccessibilityValue,
                detailText: presentation.detailText,
                showsThinkingIndicator: false),
            context: AgentRadialContextMeterPresenter.present(nil)))
    }

    // These location accessors retain the semantic presenter witness for the
    // existing host checks; the visible and reachable owner is compactStatusRow.
    var qaLocationText: String { lastLocationPresentation?.locationText ?? compactStatusRow.qaLocationText }
    var qaWhatText: String { lastLocationPresentation?.whatText ?? compactStatusRow.qaActivityText }
    var qaLocationDetail: String { lastLocationPresentation?.detailText ?? "" }
    var qaWhereOutboundMarkerVisible: Bool { lastLocationPresentation?.whereIsExternal == true }
    var qaWhatOutboundMarkerVisible: Bool { lastLocationPresentation?.whatIsExternal == true }
    var qaLocationMarkerLanesDoNotOverlapText: Bool { compactStatusRow.qaContentFitsBounds }
    var qaLocationContentFitsBounds: Bool { compactStatusRow.qaContentFitsBounds }
    var qaLocationActionButtonAccessibilityLabel: String {
        compactStatusRow.qaLocationActionButtonAccessibilityLabel
    }
    var qaLocationActionButtonEnabled: Bool { compactStatusRow.qaLocationActionButtonEnabled }
    var qaLocationAccessibilityValue: String {
        lastLocationPresentation?.locationAccessibilityValue ?? ""
    }
    var qaWhatAccessibilityValue: String {
        lastLocationPresentation?.whatAccessibilityValue ?? ""
    }
    var qaLocationStaleTimerActive: Bool { locationStaleTimer?.isValid == true }
    var qaStreamingMarkupParseTimerActive: Bool { streamingMarkupParseTimer?.isValid == true }
    var qaStreamingMarkupParseTimerInterval: TimeInterval? { streamingMarkupParseTimerScheduledDelay }
    var qaStreamingMarkupParseTimerGeneration: UInt64 { streamingMarkupParseTimerGeneration }
    var qaStreamingMarkupParseCount: Int { model.streamingMarkupParseCount }
    func qaSemanticMarkupIsSingleStrongText(_ expected: String) -> Bool {
        guard let payload = model.document.entries.first?.blocks.first?.payload else { return false }
        switch payload {
        case .paragraph(let inlines):
            guard inlines.count == 1,
                  case .strong(let strongInlines) = inlines[0],
                  strongInlines.count == 1,
                  case .text(let text) = strongInlines[0] else { return false }
            return text == expected
        default:
            return false
        }
    }
    var qaTranscriptCompatibilityBodies: [String] { model.compatibilityRows.map(\.body) }
    func qaRefreshLocation(at now: Date) { refreshLocationStatus(at: now) }
    func qaPrepareStreamingMarkupForTeardown() { prepareStreamingMarkupForTeardown(final: true) }
    func qaFireStreamingMarkupTimer(generation: UInt64) { streamingMarkupParseTimerFired(generation: generation) }

    /// Presents whatever streamed markup is pending, through the production
    /// boundary path.
    ///
    /// The timer seam above is wall-clock gated (`flushPendingStreamingMarkupIfDue`),
    /// so in a fixture it is never due and a check that fires it measures an empty
    /// queue while believing it measured a cheap one. This is the same boundary a
    /// real turn crosses, just invoked deterministically.
    func qaFlushStreamingMarkupForChecks(final: Bool = false) {
        flushPendingStreamingMarkupForBoundary(final: final)
    }
    var qaBranchChipIsWarning: Bool {
        agentHeader.qaBranchIsWarning
    }
    var qaBranchChipTooltip: String? {
        agentHeader.qaBranchTooltip
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
        let transcriptLayoutsBeforeTick = transcriptCollectionFixture?.transcriptLayout.preparePassCount ?? 0
        agentHeader.qaTick(now: Date(timeIntervalSince1970: 165))
        contentView?.layoutSubtreeIfNeeded()
        let timerActive = agentHeader.qaTimerIsActive
        let elapsedText = agentHeader.qaElapsed
        let transcriptLayoutDelta = (transcriptCollectionFixture?.transcriptLayout.preparePassCount ?? 0) - transcriptLayoutsBeforeTick
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
    var qaUsesV2HeaderShell: Bool { agentHeader.superview != nil }
    var qaAgentHeaderName: String { agentHeader.qaName }
    func qaSubmitPrompt(_ prompt: String) {
        guard let composer = v2Composer else { return }
        composer.apply(AgentComposerDraft(
            text: prompt,
            selection: NSRange(location: (prompt as NSString).length, length: 0),
            revision: composer.draft.revision &+ 1
        ))
        composer.composerRequestedSend(composer.textView)
    }
    var qaTranscriptText: String {
        model.cards.map { "[\($0.title)] \($0.body)" }.joined(separator: "\n")
    }
    var qaLastAssistantCardBody: String? {
        model.cards.last { $0.title == "assistant" }?.body
    }
}
