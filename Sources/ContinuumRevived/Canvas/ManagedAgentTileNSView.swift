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
/// The provider-controls row. Its own `layout()` is the one moment its width
/// is final, so that is where the dictation mic decides whether it fits.
@MainActor
private final class ProviderControlsRow: NSStackView {
    var onLayoutWidth: ((CGFloat) -> Void)?

    override func layout() {
        super.layout()
        onLayoutWidth?(bounds.width)
    }
}

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
final class ManagedAgentTileNSView: TileNSView, CornerStyled {
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

    // MARK: - WS5 page zoom
    //
    // The scale boundary is `contentBackdrop` and everything below it. That is
    // the narrowest view that contains every inner surface the contract names —
    // header, transcript, status row, composer, rails, footer, action — and
    // excludes every part of `TileNSView` the contract freezes: the title bar,
    // the resize/corner overlays, the tile's world frame and its zone stamp.
    // Those are the base class's views and siblings of the content slot, so a
    // change confined to this subtree cannot reach them.
    //
    // The value is a plain stored property on the MOUNTED view. It is
    // deliberately not in `tile.metadata`, not in `canvas.json`, not in the
    // workspace document and not in UserDefaults: a recreated tile builds a new
    // `ManagedAgentTileNSView`, which starts at `.default`, because there is
    // nowhere the old rung could have been read back from.
    private(set) var pageZoom: AgentPageZoom = .default
    /// Positive control: how many times a NEW rung was pushed through this tile.
    private(set) var qaPageZoomApplyCount = 0
    /// Positive control: how many `AgentPageZoomScalable` views the last apply
    /// reached. A witness that asserts "the title bar did not move" is vacuous
    /// if the walk reached nothing.
    private(set) var qaPageZoomScaledViewCount = 0
    private var agentHeaderHeight: NSLayoutConstraint?
    private var compactStatusRowHeight: NSLayoutConstraint?
    private var providerFooterHeight: NSLayoutConstraint?
    private var actionButtonHeight: NSLayoutConstraint?
    private var composerWidthInset: NSLayoutConstraint?
    private var footerRowWidthInset: NSLayoutConstraint?
    private var compactStatusWidthInset: NSLayoutConstraint?
    private var statusProviderSpacerHeight: NSLayoutConstraint?
    private let header: NSStackView = {
        let stack = NSStackView()
        stack.wantsLayer = true
        return stack
    }()
    /// P5.1: the replacement header is constructed independently but installed
    /// only under the v2 fixture flag. The compatibility shell and its baselines
    /// remain untouched until final live migration.
    private let agentHeader = AgentTileHeaderView()
    private var referenceDropTask: Task<Void, Never>?
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

    private let transcriptCollectionFixture: (any AgentTranscriptSurface)?
    /// ARRAY_TRANSCRIPT_RENDERER=canvas: the body rests detached and one view
    /// draws it (`AgentTileChromeCanvasView`). Read once, with the transcript.
    private let drawsRestingChrome: Bool
    private var chromeCanvas: AgentTileChromeCanvasView?
    private var chromeRestWork: DispatchWorkItem?
    private(set) var qaChromeWakeCount = 0
    private(set) var qaChromeSettleWakeCount = 0
    fileprivate(set) var qaChromeMotionRestCount = 0
    /// The row renderer when it is the one installed; list-only QA seams read it.
    private var listTranscript: AgentTranscriptListView? { transcriptCollectionFixture as? AgentTranscriptListView }
    func prepareBoardTask(
        boardID: UUID,
        card: BoardCard,
        revision: UInt64,
        store: BoardAttachmentStore,
        focusComposer: Bool = true,
        confirmReplacement: Bool = true
    ) async throws {
        guard let v2Composer else { throw NSError(domain: "BoardTask", code: 1, userInfo: [NSLocalizedDescriptionKey: "The agent composer is unavailable."]) }
        try await v2Composer.prepareBoardTask(
            boardID: boardID,
            card: card,
            revision: revision,
            store: store,
            focusComposer: focusComposer,
            confirmReplacement: confirmReplacement
        )
    }
    func clearBoardTask(boardID: UUID, cardID: UUID) async {
        await v2Composer?.clearBoardTask(boardID: boardID, cardID: cardID)
    }
    private let v2Composer: AgentComposerView?
    private let v2ActionButton: ComposerActionButton?
    /// 2026-10-13 — Steer (and its menu of queue / force send) beside a compact
    /// Stop, only while a turn works and there is a draft.
    private let v2SendChoice = ComposerSendChoiceView(frame: .zero)
    /// DI-01 — the composer's microphone, beside Send. Absent below macOS 26
    /// and when dictation is turned off in Settings.
    private let v2DictationButton = ComposerDictationButton(frame: .zero)
    /// What the mic grows into while a session is live, over the provider
    /// controls. Not an arranged view: it moves by frame, so its spring never
    /// reflows the row or re-runs the footer's measured fit.
    private let v2DictationPill = ComposerDictationPillView(frame: .zero)
    private var dictationDefaultsObserver: NSObjectProtocol?
    /// False at tile widths where the mic would squeeze the provider controls
    /// below their condensed tier (the 320 pt floor). ⇧⌘D still works there.
    private var dictationFitsFooter = true
    /// Where the composer's pending steer/queue rail is docked: under the
    /// transcript, above the compose strip.
    private weak var v2PendingDock: PendingMessageDockView?
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
    /// The session fact a running context compaction contributes. Every other
    /// session/turn fact the row shows comes from `currentPresence`.
    private var compactionSessionFact: AgentCompactStatusPhaseFacts.Session?
    /// Facts a geometry/appearance probe injected (`qaApplyCompactStatusFacts`);
    /// held so the elapsed tick repaints what the probe asked for.
    private var injectedCompactFacts: (session: AgentCompactStatusPhaseFacts.Session?, turn: AgentCompactStatusPhaseFacts.Turn?)?
    private var compactStatusInteraction: AgentCompactStatusPhaseFacts.Interaction?
    private var compactContextWindow: AgentContextWindowSnapshot?
    private var compactStatusResolution = AgentCompactStatusPhaseResolution.unknown
    /// Subscription to the supervisor's turn-capability seam. The runner slot
    /// frees strictly after the last runtime event a tile ingests, so without
    /// this the composer's last repaint shows `canSend == false` forever
    /// (P5.5 live finding, `plan-P5.5-review-corrections.md` defect 1).
    private var capabilityObserverToken: UUID?
    private var promptEchoObserverToken: UUID?
    private var localNoticeObserverToken: UUID?
    private var outsideHistoryObserverToken: UUID?
    private var runtimeObservationObserverToken: UUID?
    private var displayNameObserverToken: UUID?
    /// 0.7.30 — the process tracker's change notification, while attached.
    private var backgroundJobsObserver: NSObjectProtocol?
    private var identityColorObserverToken: UUID?
    /// The agent's identity colour NAME as the record holds it (a zone-palette
    /// name), nil for none. `identityColor` is its resolved, unmuted tint.
    private var identityColorName: String?
    /// The top-bar treatment. Created only while a colour is set and removed when
    /// it is cleared, so a colourless tile carries no extra view at all — every
    /// census and every rest-state witness sees exactly the tile it saw before.
    /// Where the style setting is read. `.standard` in the app; a check injects a
    /// suite so it never reads or writes the real domain.
    var identityStyleDefaults: UserDefaults = .standard {
        didSet { applyIdentityChrome() }
    }
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
    /// This tile's own reduction of what it ingests, with the same reducer the
    /// supervisor owns. It is what the tile paints from only when no supervisor
    /// is attached (ComponentLab, a detached view) and between Return and the
    /// supervisor accepting the prompt; otherwise `currentPresence` reads the
    /// supervisor's, so the tile, row, badge and sidebar can never disagree.
    private var localPresence = AgentTurnPresence()
    /// Whether this tile has any session fact at all (an attach or an event).
    /// A brand-new tile has none, and says nothing rather than "Ready".
    private var hasPresenceFacts = false
    /// True from `attach` until `detach` begins: only a tile following an agent
    /// may speak with the supervisor's presence.
    private var followsSupervisorPresence = false

    /// THE presence this tile paints from (`AgentTurnPresence`).
    var currentPresence: AgentTurnPresence {
        if pendingOptimisticSubmissionID == nil,
           followsSupervisorPresence,
           let agentID = attachedAgentID,
           let supervised = agentSource?.turnPresence(for: agentID) {
            return supervised
        }
        return localPresence
    }

    /// See `TurnLiveness`. A projection of `currentPresence`, never a fact of
    /// its own.
    var turnLiveness: TurnLiveness {
        let presence = currentPresence
        if presence.isLive { return .inFlight }
        if presence.phase.isTerminal { return .completed }
        return .unknown
    }
    /// Explicit provider response transport for v2 request blocks.
    ///
    /// Returns whether the app ACCEPTED the response for dispatch — not whether
    /// the provider received it, which cannot be known on this turn (the
    /// transport blocks on a round trip). False, or an unbound seam, means
    /// nothing was dispatched and the tile paints `.failed`; true means
    /// `.submitting`, and the request still stays open until a real
    /// `requestResolved`/`userInputResolved` runtime event arrives. This tile
    /// never fabricates a resolution locally.
    ///
    /// Bound in `AppDelegate.wireManagedAgentTile`. The buttons that reach it are
    /// gated on `AgentTurnCapabilities.canRespondToRequests`, so a runner with no
    /// response transport renders a readable request and no controls at all —
    /// rather than controls that press into nothing.
    var onProviderResponse: ((_ requestID: String, _ value: String) -> Bool)?
    /// App-owned recovery route for a context-full transcript error. The tile
    /// validates the block and copies its transcript locally; compaction and
    /// fork actions cross this closure to the runner/session owner.
    var onContextFullRecoveryAction: ((_ blockID: AgentNodeID, _ action: AgentContextFullRecovery.Action) -> Void)?
    /// App-owned sink for a user-requested context compaction from the native
    /// warning meter. The row only exposes the action for warning/critical
    /// readings; the session owner chooses provider routing.
    var onCompactContextRequested: (() -> Void)?

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
    /// An agent-message card's sender, revealed through the same app-owned path.
    var onRevealMessageSender: ((AgentID) -> Void)?
    /// Fired after this tile ingests an event, so the app can mirror the stream
    /// onto the syncable activity timeline (88.4c) without owning the subscription.
    var onIngestedEvent: ((AgentRuntimeEvent) -> Void)?
    /// Fired when the user submits a prompt from the tile's compose row.
    /// The app wires this to a PiAgentRunner (ticket 88.4b). Minimal now; the
    /// framework ComposeBox component supersedes it later.
    var onSubmitPrompt: ((String) -> Void)?
    var onAcceptedBoardTask: ((_ agentID: AgentID, _ context: BoardTaskContext) -> Void)?
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
        monotonicNow: @escaping @Sendable () -> TimeInterval = { AgentTranscriptClock.monotonic() }
    ) {
        let fileIndex = AgentFileIndex()
        // No fixtures. The filter here used to drop `fixture.files` and
        // `fixture.commands` and keep `fixture.skills`, which put two invented
        // rows ("review", "research") on the live `$` menu of every managed
        // agent tile — and `$` is a real trigger for this composer variant.
        self.v2DefaultCompletionRegistry = AgentCompletionProviderRegistry(
            providers: [AgentCommandCompletionProvider(),
                        AgentFileCompletionProvider(index: fileIndex)]
        )
        self.threadId = threadId
        self.statusRowPlacement = statusRowPlacement
        self.projectionMonotonicNow = monotonicNow
        self.model = ManagedAgentTranscriptModel(threadId: threadId, monotonicNow: monotonicNow)
        self.providerSettings = providerSettings ?? AgentModelConfig.resolvedFromDefaults()
        // P5.5 acceptance: v2 IS the tile. The reversible construction seam and
        // the legacy view-only card path were removed at this supervised gate.
        // ARRAY_TRANSCRIPT_RENDERER=canvas (or the `continuum.transcript.renderer`
        // default) draws the transcript as one CoreText view; the row list stays
        // the default until the canvas renderer covers every block.
        let canvasRenderer = AgentTranscriptCanvasView.isSelected
        self.drawsRestingChrome = canvasRenderer
        self.transcriptCollectionFixture = canvasRenderer
            ? AgentTranscriptCanvasView(toolDetailStore: toolDetailStore)
            : AgentTranscriptListView(toolDetailStore: toolDetailStore)
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
        NotificationCenter.default.addObserver(
            self, selector: #selector(identityStyleSettingChanged(_:)),
            name: SettingChangeEvent.name(for: SettingID(rawValue: AgentIdentityColorConfig.styleKey)),
            object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(terminalToggleSettingChanged(_:)),
            name: SettingChangeEvent.name(for: SettingID(rawValue: AgentTerminalFaceConfig.showToggleKey)),
            object: nil)
        agentHeader.installStatusBadge(awarenessBadge)
        enableTitleBarActions()
        compactStatusRow.hideLocationActions()
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
        compactStatusRow.onCompactContextRequested = { [weak self] in
            self?.onCompactContextRequested?()
        }
        compactStatusRow.onBackgroundJobsMenuRequested = { [weak self] anchor in
            self?.showBackgroundProcesses(from: anchor)
        }
        v2Composer?.onDraftChange = { [weak self] _ in self?.updateV2ComposerPresentation() }
        v2Composer?.onDraftApplied = { [weak self] in self?.updateV2ComposerPresentation() }
        v2Composer?.onSubmitPrompt = { [weak self] prompt in self?.onSubmitPrompt?(prompt) }
        v2Composer?.onSubmissionStarted = { [weak self] prompt in
            self?.beginOptimisticSubmission(prompt)
        }
        v2Composer?.onSubmissionRefused = { [weak self] refusal in
            self?.pendingSubmissionRefusal = refusal
        }
        v2Composer?.onSubmissionFinished = { [weak self] accepted in
            self?.finishOptimisticSubmission(accepted: accepted)
        }
        v2Composer?.onAcceptedBoardTask = { [weak self] context in
            guard let self, let agentID = self.projectedAgentID else { return }
            self.onAcceptedBoardTask?(agentID, context)
        }
        v2ActionButton?.target = self
        v2ActionButton?.action = #selector(performV2PrimaryAction)
        v2DictationButton.target = self
        v2DictationButton.action = #selector(toggleV2Dictation)
        v2Composer?.onDictationStateChange = { [weak self] state in
            self?.dictationStateDidChange(state)
        }
        v2Composer?.onDictationLevel = { [weak self] level in
            self?.v2DictationPill.waveform.record(level: level)
        }
        v2Composer?.onDictationPreparation = { [weak self] downloading in
            self?.v2DictationPill.setMode(.preparing(downloadingModel: downloading))
        }
        v2DictationPill.onFinish = { [weak self] in self?.v2Composer?.toggleDictation() }
        v2DictationPill.onExpansionChange = { [weak self] expansion in
            guard let self else { return }
            // What the pill covers fades as it grows; the mic hides the moment
            // the pill leaves it, since the pill's stop button sits on it.
            self.providerFooter.alphaValue = 1 - expansion
            self.v2DictationButton.alphaValue = self.v2DictationPill.isHidden ? 1 : 0
        }
        updateDictationAvailability()
        dictationDefaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateDictationAvailability() }
        }
        v2SendChoice.isHidden = true
        v2SendChoice.onChoose = { [weak self] modifier in
            guard let composer = self?.v2Composer else { return }
            composer.composerRequestedSend(composer.textView, modifier: modifier)
        }
        v2Composer?.onEditorFocusChange = { [weak self] focused in
            if !focused { self?.scheduleChromeRest() }
        }
        setContentView(makeV2ContentView())
        applyHeader(status: self.descriptor.status)
        applyUnknownCompactStatus()
        refreshTranscriptThinkingIndicator()
        synchronizeV2Transcript(final: true)
        restChromeIfIdle()
    }

    func acceptCurrentSendIntent() {
        v2Composer?.acceptCurrentSendIntent()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    isolated deinit {
        if let dictationDefaultsObserver { NotificationCenter.default.removeObserver(dictationDefaultsObserver) }
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
    override var surfaceableBody: NSView? {
        // The drawn chrome exists so that nothing is ever shown as a picture.
        guard !drawsRestingChrome else { return nil }
        return terminalFaceSession == nil ? contentBackdrop : nil
    }

    /// Far parking takes no picture, so the drawn body may still park.
    override var farParkableBody: NSView? {
        guard let chromeCanvas else { return surfaceableBody }
        return terminalFaceSession == nil ? chromeCanvas : nil
    }

    /// The Array face's body: the drawn chrome when it is in use.
    private var arrayFaceBody: NSView { chromeCanvas ?? contentBackdrop }

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
        guard let transcript = transcriptCollectionFixture else { return [] }
        return [transcript.transcriptScrollOrigin]
    }

    /// A transcript control's action, through the dispatch its renderer calls.
    func qaPerformRenderAction(_ action: AgentRenderAction) {
        performV2RenderAction(action)
    }

    /// Scroll the transcript from a witness without reaching into its privates.
    func qaScrollTranscript(toY y: CGFloat) {
        transcriptCollectionFixture?.scrollTranscript(toY: y)
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
        followsSupervisorPresence = true
        backgroundJobsObserver = NotificationCenter.default.addObserver(
            forName: .agentBackgroundJobsDidChange, object: nil, queue: .main
        ) { [weak self] note in
            let changed = note.userInfo?["agentIDs"] as? Set<AgentID>
            MainActor.assumeIsolated {
                guard let self, let id = self.attachedAgentID, changed?.contains(id) ?? true else { return }
                self.refreshBackgroundJobs()
            }
        }
        refreshBackgroundJobs()
        v2Composer?.bindCompletionContext(supervisor.completionContext(for: agentID))
        headerAgentName = supervisor.records[agentID]?.humanDisplayName
        displayNameObserverToken = supervisor.addDisplayNameObserver(for: agentID) { [weak self] name in
            guard let self, self.headerAgentName != name else { return }
            self.headerAgentName = name
            self.refreshTitleBarIdentity()
            self.applyAgentHeader(status: self.descriptor.status)
        }
        identityColorObserverToken = supervisor.addIdentityColorObserver(for: agentID) { [weak self] name in
            self?.setIdentityColorName(name)
        }
        setIdentityColorName(supervisor.records[agentID]?.identityColor)
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
            composer.onResumeQueue = { [weak supervisor] in
                supervisor?.resumeQueue(for: agentID)
            }
            // T5b: the rail's per-item verbs. Send-now on a follow-up is D2's
            // force send; on a held steer it hands the steer over at once.
            composer.onSendQueuedMessageNow = { [weak supervisor] messageID in
                Task { @MainActor in _ = await supervisor?.sendQueuedItemNow(messageID, for: agentID) }
            }
            composer.onMoveQueuedMessage = { [weak supervisor] messageID, index in
                supervisor?.moveQueuedItem(messageID, toFollowUpIndex: index, for: agentID)
            }
            composer.onTakeQueuedMessageForEditing = { [weak supervisor] messageID in
                await supervisor?.takeQueuedItemForEditing(messageID, for: agentID)
            }
            composer.onRestoreQueuedMessageAfterFailedEdit = { [weak supervisor] message in
                await supervisor?.restoreQueuedItemAfterFailedEdit(message, for: agentID)
            }
            composer.updateQueueRail(supervisor.queueRailState(for: agentID))
            // T5 — a prompt the supervisor started itself (a drained follow-up,
            // a delivered steer) has no composer bubble; show it when it runs.
            // Until then it is pending in the rail docked under the transcript
            // (2026-10-13), which lets it go on the same repaint: the pending
            // message becomes the sent one, never both.
            if let token = promptEchoObserverToken { supervisor.removePromptEchoObserver(token, for: agentID) }
            promptEchoObserverToken = supervisor.addPromptEchoObserver(for: agentID) { [weak self] prompt in
                guard let self, self.attachedAgentID == agentID else { return }
                self.appendUserPrompt(prompt)
            }
            // S3: Array's own replies (`/status`, a held prompt that could not
            // go) land in the live transcript as they are written.
            if let token = localNoticeObserverToken { supervisor.removeLocalNoticeObserver(token, for: agentID) }
            localNoticeObserverToken = supervisor.addLocalNoticeObserver(for: agentID) { [weak self] notice in
                guard let self, self.attachedAgentID == agentID else { return }
                self.model.appendNotice(id: notice.id, title: notice.title, text: notice.body)
                self.synchronizeV2Transcript(final: true)
                self.refreshCompactStatus()
                self.refreshTranscriptThinkingIndicator()
            }
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
            // ST-01 — an account quota reading changes a row element without
            // producing any runtime EVENT, so nothing else in this tile would
            // repaint it.
            if case .accountQuota = observation { self?.refreshCompactStatus() }
            // S3: a retry changes what the tail says without any runtime event.
            if case .providerRetry = observation { self?.refreshCompactStatus() }
        }
        hydrateManagedImagesFromDocument()
        // The render context reads `agentSource` (a chip's live status, an agent
        // message's sender), and the app binds the composer — the context's
        // other refresh — BEFORE it attaches. Refreshed here, before the
        // snapshot draws, so a freshly wired tile does not draw every row
        // against a context that knows no supervisor.
        try? transcriptCollectionFixture?.updateRenderContext(v2RenderContext)
        // Turns the session took outside Array, as the supervisor appends them
        // to the agent's transcript (`.plans/79`: one rule for history).
        outsideHistoryObserverToken = supervisor.addOutsideHistoryObserver(for: agentID) { [weak self] history in
            guard let self, self.attachedAgentID == agentID else { return }
            switch history {
            case .restored(let transcript): self.renderRehydratedPreviousSession(transcript)
            case let .turns(transcript, boundary): self.appendTurnsTakenOutside(transcript, boundary: boundary)
            }
            self.synchronizeV2Transcript(final: true)
        }
        let attachment = supervisor.transcriptAttachment(for: agentID, reboundTo: threadId)
        if let snapshot = attachment.snapshot {
            installTranscriptSnapshot(snapshot)
            // The agent's transcript starts from its restore: it is drawn.
            if supervisor.rehydratedTranscript(for: agentID) != nil { hasRenderedRehydratedSession = true }
        }
        let stream = attachment.tail
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
        if attachment.snapshot == nil, let rehydrated = supervisor.rehydratedTranscript(for: agentID) {
            renderRehydratedPreviousSession(rehydrated)
        }
        refreshTranscriptThinkingIndicator()
        refreshFaceSwitch()
    }

    /// Install the supervisor-owned semantic truth before following its live tail.
    /// The view's prior projection was already reset by `attach`; forcing a full
    /// document handoff here makes a workspace round trip independent of raw-event
    /// replay caps and preserves an unfinished streamed response.
    private func installTranscriptSnapshot(_ snapshot: ManagedAgentTranscriptModel) {
        prepareStreamingMarkupForTeardown(final: true)
        model = snapshot
        descriptor.status = model.currentStatus
        agentStatus = model.currentStatus
        lastForwardedDocumentVersion = nil
        synchronizeV2Transcript(final: true)
        scheduleStreamingMarkupParseTimerIfNeeded()
    }

    var agentReferenceForDragging: AgentPromptReference? {
        guard let id = attachedAgentID, let record = agentSource?.records[id] else { return nil }
        return AgentPromptReference(agentID: id, displayName: record.humanDisplayName)
    }

    func acceptsAgentReference(_ reference: AgentPromptReference) -> Bool {
        guard let target = attachedAgentID, target != reference.agentID,
              let records = agentSource?.records,
              let source = records[reference.agentID], let recipient = records[target] else { return false }
        return source.projectId == recipient.projectId && terminalFaceSession == nil
            && !composeBackdrop.isHidden && v2Composer != nil && !isHiddenOrHasHiddenAncestor
    }

    /// Where another agent's header drag drops as a reference, in this tile's
    /// own coordinates: the composer, and the middle half of the body. The title
    /// bar and the body's outer quarters stay layout — swap and slide in between.
    var agentReferenceDropRegions: [CGRect] {
        guard window != nil, !composeBackdrop.isHidden, !composeBackdrop.bounds.isEmpty,
              !isHiddenOrHasHiddenAncestor else { return [] }
        let header = chromeBarHeight
        let body = CGRect(x: bounds.width / 4, y: header,
                          width: bounds.width / 2, height: max(0, bounds.height - header))
        return [body, composeBackdrop.convert(composeBackdrop.bounds, to: self)]
    }

    func setAgentReferenceDropHighlight(_ value: Bool) {
        v2Composer?.setReferenceDropHighlight(value)
    }

    /// The drop of another agent's header drag. No tile geometry, zone,
    /// selection or canvas persistence takes part: the drag has already put
    /// every tile back where it rested.
    @discardableResult
    func handleAgentReference(_ reference: AgentPromptReference, commit: Bool) -> Bool {
        guard let target = attachedAgentID, target != reference.agentID,
              let supervisor = agentSource,
              let sourceRecord = supervisor.records[reference.agentID],
              let targetRecord = supervisor.records[target],
              sourceRecord.projectId == targetRecord.projectId,
              terminalFaceSession == nil, !composeBackdrop.isHidden,
              let composer = v2Composer else {
            v2Composer?.setReferenceDropHighlight(false)
            return false
        }
        promoteForIncomingFocus()
        guard commit else { composer.setReferenceDropHighlight(true); return true }
        composer.setReferenceDropHighlight(false)
        // Resolve the display snapshot from the trusted record, never the
        // caller's label. The stable ID remains the only lookup key.
        let trusted = AgentPromptReference(agentID: reference.agentID, displayName: sourceRecord.humanDisplayName)
        let previous = referenceDropTask
        referenceDropTask = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, self.attachedAgentID == target, !Task.isCancelled else { return }
            let accepted = await composer.addAgentReferenceAfterRestore(trusted, expectedAgentID: target)
            if accepted, self.attachedAgentID == target { self.window?.makeFirstResponder(composer.textView) }
        }
        return true
    }

    func qaAwaitReferenceDrop() async { await referenceDropTask?.value }

    override func layout() {
        super.layout()
        awarenessBorder.frame = bounds.insetBy(dx: 2, dy: 2)

    }

    func applyAwarenessSignal(_ signal: AgentSignal?) {
        defer { chromeDidChange() }
        awarenessBadge.apply(signal)
        awarenessBorder.apply(signal)
        needsLayout = true
    }

    var qaAwarenessSignal: AgentSignal? { awarenessBadge.signal }

    // MARK: - WS4 · the finite completion acknowledgment

    /// A completion that landed while this tile was being watched. The signal has
    /// already been cleared by then (it counts as read), so what is left is one
    /// bounded acknowledgment on the border and then the ordinary read appearance.
    func beginCompletionAcknowledgment(_ plan: AgentCompletionAcknowledgmentPlan) {
        awarenessBorder.beginCompletionAcknowledgment(plan)
        needsLayout = true
    }

    var qaAcknowledgmentPhase: AgentSignalBorderView.CompletionAcknowledgmentPhase {
        awarenessBorder.completionAcknowledgmentPhase
    }
    var qaAcknowledgmentGeneration: UInt64 { awarenessBorder.completionAcknowledgmentGeneration }
    var qaAcknowledgmentsStarted: Int { awarenessBorder.qaAcknowledgmentsStarted }
    var qaAcknowledgmentsFinished: Int { awarenessBorder.qaAcknowledgmentsFinished }
    var qaAcknowledgmentAnimationCount: Int { awarenessBorder.qaActiveAnimationCount }
    var qaAcknowledgmentHasScheduledWork: Bool { awarenessBorder.qaHasScheduledAcknowledgmentWork }
    var qaAwarenessBorderIsHidden: Bool { awarenessBorder.isHidden }
    var qaAcknowledgmentPlan: AgentCompletionAcknowledgmentPlan? { awarenessBorder.qaAcknowledgmentPlan }
    var qaAcknowledgmentAnimationRepeatCount: Float? { awarenessBorder.qaAcknowledgmentAnimationRepeatCount }
    var qaAcknowledgmentAnimationTotalDuration: TimeInterval? { awarenessBorder.qaAcknowledgmentAnimationTotalDuration }

    // MARK: - WS5 page zoom

    /// The one writer of this tile's rung.
    ///
    /// Returns whether the rung actually moved, so a caller at an end stop can
    /// tell "nothing to do" from "done" — and so a witness can assert that a
    /// disabled command is inert rather than merely idempotent.
    @discardableResult
    func setPageZoom(_ next: AgentPageZoom) -> Bool {
        guard next != pageZoom else { return false }
        pageZoom = next
        qaPageZoomApplyCount += 1
        applyPageZoomToContent()
        return true
    }

    @discardableResult
    func performPageZoomCommand(_ command: AgentPageZoomCommand) -> Bool {
        setPageZoom(command.apply(to: pageZoom))
    }

    /// Push the current rung through the content subtree.
    ///
    /// Order matters. The Auto Layout constants and the scalable views are
    /// updated first so that when the transcript re-measures — inside
    /// `updateRenderContext`, which preserves the reader's semantic anchor — the
    /// widths it measures against are already the new ones. Doing it the other
    /// way round anchors the reader against a width that is about to change.
    /// Corner style (Settings › Appearance › Corner style): re-deliver the
    /// current rung through the content subtree and the transcript's render
    /// context, which is where every agent surface resolves its radii.
    func applyCornerStyle() { applyPageZoomToContent() }

    private func applyPageZoomToContent() {
        // Constraint constants move here, which the resting fingerprint cannot see.
        defer { chromeCanvas?.forceRestingRedraw(); chromeDidChange() }
        let zoom = pageZoom
        agentHeaderHeight?.constant = AgentTileHeaderView.preferredHeight(zoom: zoom)
        compactStatusRowHeight?.constant = AgentCompactStatusRowView.preferredHeight(zoom: zoom)
        providerFooterHeight?.constant = AgentComposerFooterView.height(zoom: zoom)
        actionButtonHeight?.constant = ComposerActionButton.controlHeight(zoom: zoom)
        let horizontalInset = -CGFloat(zoom.scaled(Inset.row).horizontal)
        composerWidthInset?.constant = horizontalInset
        footerRowWidthInset?.constant = horizontalInset
        compactStatusWidthInset?.constant = horizontalInset
        statusProviderSpacerHeight?.constant = CGFloat(zoom.scaled(Space.l))
        v2ComposeColumn?.spacing = CGFloat(zoom.scaled(Space.m))
        v2ComposeColumn?.edgeInsets = NSEdgeInsets(Inset.row, zoom: zoom)
        v2FooterRow?.spacing = CGFloat(zoom.scaled(Space.m))
        qaPageZoomScaledViewCount = AgentPageZoomScaling.apply(zoom, in: contentBackdrop)
        // The transcript is not on the scalable walk: it is a renderer host, and
        // its rung travels in the render context so that a REUSED row adopts the
        // current rung when it materializes. This is also the transaction that
        // preserves the reader's anchor, the selection and the disclosures.
        do {
            try transcriptCollectionFixture?.updateRenderContext(v2RenderContext)
        } catch {
            v2RenderError = error
        }
        contentBackdrop.needsLayout = true
        contentBackdrop.layoutSubtreeIfNeeded()
    }

    /// The zoom submenu, offered on the title-bar menu and the tile context menu
    /// (they are the same menu — `TileNSView` builds one from this seam).
    private func makePageZoomMenuItems() -> [NSMenuItem] {
        let root = NSMenuItem(title: "Zoom", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Zoom")
        // The current percentage, always visible so the rung is discoverable
        // without stepping. Disabled: it is a readout, not a command.
        let readout = NSMenuItem(
            title: "Page Zoom \(pageZoom.displayPercentage)", action: nil, keyEquivalent: "")
        readout.isEnabled = false
        readout.identifier = NSUserInterfaceItemIdentifier("agentTile.pageZoom.readout")
        menu.addItem(readout)
        menu.addItem(.separator())
        menu.addItem(pageZoomItem(title: "Zoom In", command: .zoomIn, keyEquivalent: "+"))
        menu.addItem(pageZoomItem(title: "Zoom Out", command: .zoomOut, keyEquivalent: "-"))
        menu.addItem(pageZoomItem(title: "Actual Size", command: .reset, keyEquivalent: "0"))
        root.submenu = menu
        return [root]
    }

    private func pageZoomItem(
        title: String, command: AgentPageZoomCommand, keyEquivalent: String
    ) -> NSMenuItem {
        let item = NSMenuItem(
            title: title, action: #selector(performPageZoomMenuItem(_:)), keyEquivalent: keyEquivalent)
        item.keyEquivalentModifierMask = [.command]
        item.target = self
        item.representedObject = command.rawValue
        item.identifier = NSUserInterfaceItemIdentifier("agentTile.pageZoom.\(command.rawValue)")
        // The end stops are DISABLED, not hidden: a command that cannot move the
        // value must not look available.
        item.isEnabled = command.isEnabled(for: pageZoom)
        return item
    }

    @objc private func performPageZoomMenuItem(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let command = AgentPageZoomCommand(rawValue: raw) else { return }
        // Re-checked here and not only on the item: AppKit will send a disabled
        // item's action if something else validates it, and the value must be
        // inert at an end stop however it is reached.
        guard command.isEnabled(for: pageZoom) else { return }
        performPageZoomCommand(command)
    }

    /// Route one key equivalent. Returns whether it was consumed — nil-shaped
    /// chords are never consumed, which is what leaves the browser, the canvas
    /// and every editable control's own shortcuts untouched.
    @discardableResult
    func handlePageZoomKeyEquivalent(with event: NSEvent) -> Bool {
        guard let command = AgentPageZoomShortcut.command(
            characters: event.characters,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            modifiers: AgentPageZoomModifier.set(from: event.modifierFlags)
        ) else { return false }
        // A chord at an end stop is still OURS — consuming it stops it falling
        // through to some other Command-plus owner mid-gesture.
        performPageZoomCommand(command)
        return true
    }

    var locationMenuProvider: ((AgentID) -> NSMenu?)?

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
        let location = projectedAgentID.flatMap { locationMenuProvider?($0) }
        let locationItems = location?.items ?? []
        locationItems.forEach { location?.removeItem($0) }
        return makeFaceMenuItems() + locationItems + (locationItems.isEmpty ? [] : [.separator()]) + makePageZoomMenuItems() + [root]
            + makeIdentityColorMenuItems() + makeWorkspaceToolsMenuItems() + makeBackgroundProcessesMenuItems()
    }

    // MARK: - Terminal face (.plans/79-session-handoff)
    //
    // One tile, two faces. The Array face is this tile's own transcript and
    // composer; the Terminal face is the real `claude` TUI on the same
    // conversation, in a Ghostty surface in the same frame, under the same name,
    // colour and sidebar row. Exactly one of them owns the session at a time:
    // the supervisor refuses every send while the Terminal face holds it.

    /// Set by the host. nil (checks that never flip, an unwired tile) means no
    /// switch at all.
    var terminalFaceEnvironment: AgentTerminalFaceEnvironment? {
        didSet { refreshFaceSwitch() }
    }
    private(set) var terminalFaceSession: AgentTerminalFaceSession?
    var face: AgentTileFace { terminalFaceSession == nil ? .array : .terminal }
    /// The flip to Terminal is waiting for the turn to end (edge case 9).
    private(set) var pendingTerminalFlip = false
    private let faceFlipBanner = AgentFaceFlipBanner(frame: .zero)
    private var terminalFaceReattachments = 0

    /// The Terminal face is Claude Code's alone. Codex is hidden on purpose:
    /// `codex resume <thread>` exists, but codex writes no per-process session
    /// file, so Array could not tell when that TUI is busy or follow it to a
    /// new thread, and the flip-back reader is claude's. Pi has no TUI resume.
    private var supportsTerminalFace: Bool {
        guard terminalFaceEnvironment != nil, let agentID = attachedAgentID ?? projectedAgentID else { return false }
        return agentSource?.records[agentID]?.harness == .claudeCode
    }

    private func refreshFaceSwitch() {
        guard supportsTerminalFace || terminalFaceSession != nil else {
            setTitleBarFaceSwitch(nil)
            refreshFaceAccessibilityActions()
            return
        }
        // Keep the return/cancel affordance while Terminal is active or pending,
        // even for people who hide the entry toggle from their chat headers.
        if face == .array, !pendingTerminalFlip,
           !AgentTerminalFaceConfig.showsToggle(defaults: terminalFaceEnvironment?.defaults ?? .standard) {
            setTitleBarFaceSwitch(nil)
            refreshFaceAccessibilityActions()
            return
        }
        var reason: String?
        if terminalFaceSession == nil, let agentID = attachedAgentID,
           case .unavailable(let why)? = agentSource?.terminalFaceReadiness(for: agentID) {
            reason = why
        }
        setTitleBarFaceSwitch(FaceSwitchState(
            selected: face, pendingTerminal: pendingTerminalFlip, unavailableReason: reason))
        refreshFaceAccessibilityActions()
    }

    @objc private func terminalToggleSettingChanged(_ notification: Notification) {
        refreshFaceSwitch()
    }

    override func faceSwitchRequested(_ requested: AgentTileFace) {
        switch requested {
        case .terminal where face == .array: requestTerminalFace()
        case .array where face == .terminal: requestArrayFace()
        case .array where pendingTerminalFlip: cancelPendingTerminalFlip()
        default: break
        }
    }

    /// ⌃⌘T, the ⋯ menu and the accessibility action. Returns whether the tile
    /// took it.
    @discardableResult
    func toggleFace() -> Bool {
        guard supportsTerminalFace || terminalFaceSession != nil else { return false }
        faceSwitchRequested(face == .array && !pendingTerminalFlip ? .terminal : .array)
        return true
    }

    private func makeFaceMenuItems() -> [NSMenuItem] {
        guard supportsTerminalFace || terminalFaceSession != nil else { return [] }
        let title = face == .array ? "Switch to Terminal" : "Switch to Array"
        let item = NSMenuItem(title: title, action: #selector(toggleFaceFromMenu(_:)), keyEquivalent: "t")
        item.keyEquivalentModifierMask = [.command, .control]
        item.target = self
        item.identifier = NSUserInterfaceItemIdentifier("agentTile.switchFace")
        return [item, .separator()]
    }

    @objc private func toggleFaceFromMenu(_ sender: Any?) { toggleFace() }

    private func refreshFaceAccessibilityActions() {
        guard supportsTerminalFace || terminalFaceSession != nil else {
            setTitleBarAccessibilityActions(nil)
            return
        }
        let name = face == .array ? "Switch to Terminal" : "Switch to Array"
        setTitleBarAccessibilityActions([NSAccessibilityCustomAction(name: name) { [weak self] in
            self?.toggleFace() ?? false
        }])
    }

    private func requestTerminalFace() {
        guard let agentID = attachedAgentID, let supervisor = agentSource else { return }
        switch supervisor.terminalFaceReadiness(for: agentID) {
        case .ready:
            enterTerminalFace()
        case .busy:
            pendingTerminalFlip = true
            faceFlipBanner.show(.pendingFlip)
            refreshFaceSwitch()
        case .unavailable(let reason):
            // News about a click, not part of the conversation: the banner
            // slot, for a few seconds, never a transcript entry.
            faceFlipBanner.show(.refusal(reason))
            refreshFaceSwitch()
        }
    }

    /// The turn moved; a waiting flip goes now, or learns why it cannot.
    private func evaluatePendingTerminalFlip() {
        guard pendingTerminalFlip, let agentID = attachedAgentID, let supervisor = agentSource else { return }
        switch supervisor.terminalFaceReadiness(for: agentID) {
        case .busy:
            return
        case .ready:
            clearPendingTerminalFlip()
            enterTerminalFace()
        case .unavailable(let reason):
            clearPendingTerminalFlip()
            faceFlipBanner.show(.refusal(reason))
        }
    }

    private func stopTurnForPendingFlip() {
        guard let agentID = attachedAgentID, let supervisor = agentSource else { return }
        Task { @MainActor in _ = await supervisor.accept(.stop, for: agentID) }
    }

    private func cancelPendingTerminalFlip() {
        clearPendingTerminalFlip()
    }

    private func clearPendingTerminalFlip() {
        pendingTerminalFlip = false
        faceFlipBanner.dismiss(.pendingFlip)
        refreshFaceSwitch()
    }

    /// The flip. Marks where the session file ends — everything the Array face
    /// shows lies before that byte — then takes the session from the
    /// supervisor (which stops its claude first) and only then starts the TUI.
    private func enterTerminalFace() {
        guard terminalFaceSession == nil, let environment = terminalFaceEnvironment,
              let agentID = attachedAgentID, let supervisor = agentSource,
              let launch = supervisor.beginTerminalFace(for: agentID) else { return }
        let url = ClaudeTerminalFace.sessionFileURL(
            claudeHome: environment.claudeHome, cwd: launch.cwd, sessionId: launch.sessionId)
        let state = AgentTerminalFaceState(
            sessionId: launch.sessionId, cwd: launch.cwd,
            sessionFileOffset: ClaudeTerminalFace.sessionFileLength(url))
        let watch = supervisor.watchTerminalFace(for: agentID, tileId: tile.id, state: state, environment: environment)
        startTerminalFaceSurface(watch: watch, launch: launch)
        persistTerminalFace(state)
    }

    /// A tile wired with its Terminal face persisted: a relaunch, a
    /// workspace's return, a tile rebuilt for the agent. Returns whether the
    /// face owns this tile's history — the tile is in its Terminal face, or
    /// will be once tmux has answered, or the face's end is bringing the
    /// turns in — so the host runs no restore of its own over it.
    @discardableResult
    func reattachTerminalFaceIfNeeded() -> Bool {
        guard let state = tile.metadata.agentTerminalFace else { return false }
        // A parked tile coming back: its surface never went (review #9).
        if terminalFaceSession != nil { return true }
        guard let environment = terminalFaceEnvironment, let agentID = attachedAgentID,
              let supervisor = agentSource else { return false }
        // It ended while the tile was away; its turns are in the transcript.
        if supervisor.hasEndedTerminalFace(onTile: tile.id) {
            persistTerminalFace(nil)
            return false
        }
        // This launch watches it, and kept its surface: show it again.
        let watched = supervisor.terminalFaceWatch(for: agentID)
        if let watch = watched, let kept = watch.takeKeptSurface() {
            host(watch: watch, surface: kept, start: false)
            return true
        }
        // Otherwise tmux answers, off the main thread, whether claude is still
        // there — a new client must never start a claude that just left.
        let control = environment.tmuxPath.map { ProcessTmuxControl(tmuxPath: $0, defaults: environment.defaults) }
        let tileId = tile.id
        Task { @MainActor [weak self, weak supervisor] in
            let alive = await AgentTerminalFaceWatch.tmuxSessionExists(tileId: tileId, control: control)
            guard let self, let supervisor, self.attachedAgentID == agentID, self.terminalFaceSession == nil,
                  self.tile.metadata.agentTerminalFace == state else { return }
            if let watch = watched {
                guard supervisor.terminalFaceWatch(for: agentID) === watch else { return }
                if alive, !watch.launchArguments.isEmpty {
                    self.host(watch: watch, surface: AgentTerminalFaceSession(watch: watch, arguments: watch.launchArguments))
                } else {
                    self.persistTerminalFace(nil)
                    supervisor.finishTerminalFace(for: agentID)
                }
                return
            }
            if alive, let launch = supervisor.beginTerminalFace(for: agentID, reattaching: true) {
                let watch = supervisor.watchTerminalFace(for: agentID, tileId: tileId, state: state, environment: environment)
                self.startTerminalFaceSurface(watch: watch, launch: launch)
            } else {
                // Gone: what the terminal did comes home through the face's one
                // end, and the record adopts the session and model claude ended
                // on (review #10).
                self.persistTerminalFace(nil)
                supervisor.finishTerminalFace(for: agentID, persisted: state, tileId: tileId, claudeHome: environment.claudeHome)
            }
        }
        return true
    }

    private func startTerminalFaceSurface(watch: AgentTerminalFaceWatch, launch: AgentSupervisor.TerminalFaceLaunch) {
        let arguments = ClaudeTerminalFace.launchArguments(
            claude: watch.environment.claudeCommand(),
            sessionId: watch.state.sessionId,
            conversationExists: launch.conversationExists,
            model: launch.model,
            effort: launch.effort,
            processOwner: launch.processOwner,
            path: PiAgentRunner.childEnvironment()["PATH"] ?? "/usr/bin:/bin",
            forkSession: launch.forkSession)
        watch.launchArguments = arguments
        host(watch: watch, surface: AgentTerminalFaceSession(watch: watch, arguments: arguments))
    }

    /// Shows `surface` in this tile and reflects its face. What happens to the
    /// agent is the watch's; this tile only follows it.
    private func host(watch: AgentTerminalFaceWatch, surface: AgentTerminalFaceSession, start: Bool = true) {
        watch.onHostClientDetached = { [weak self, weak watch] in
            guard let self, let watch, self.terminalFaceSession?.watch === watch else { return }
            self.terminalFaceSession?.detachSurface()
            self.terminalFaceSession = nil
            // A client that keeps dying is not worth chasing: end claude, and
            // its exit ends the face with nothing left writing.
            self.terminalFaceReattachments += 1
            guard self.terminalFaceReattachments <= 3 else {
                watch.endClaude(surface: nil)
                return
            }
            self.host(watch: watch, surface: AgentTerminalFaceSession(watch: watch, arguments: watch.launchArguments))
        }
        watch.onHostSessionChange = { [weak self] state in self?.persistTerminalFace(state) }
        watch.onHostEnded = { [weak self] turns in self?.showArrayFaceAfterTerminal(appendedTurns: turns) }
        promoteBodyToNative()
        terminalFaceSession = surface
        setContentView(surface.hostView)
        if start { surface.start() }
        refreshFaceSwitch()
        if window?.firstResponder === v2Composer?.textView || window?.firstResponder == nil {
            surface.runtime.focus()
        }
    }

    /// Switch to Array from the Terminal face. Claude has to go first — two
    /// writers is the one thing the faces exist to prevent — so a busy claude
    /// is asked about, and then its exit ends the face.
    private func requestArrayFace() {
        guard let session = terminalFaceSession else { return }
        if session.isBusy, let environment = terminalFaceEnvironment,
           !environment.confirm("Claude is working in this terminal.", "Stop and Switch") { return }
        session.watch.endClaude(surface: session)
    }

    /// The face is over (`/exit`, a crash, Array ending it). Never closes the
    /// tile: the Array face comes back, and the terminal's turns are already
    /// in its transcript, appended by the supervisor.
    private func showArrayFaceAfterTerminal(appendedTurns turns: Int) {
        terminalFaceReattachments = 0
        terminalFaceSession?.detachSurface()
        terminalFaceSession = nil
        setContentView(arrayFaceBody)
        persistTerminalFace(nil)
        // Edge case 12: the picker shows what the terminal actually ran.
        if let agentID = attachedAgentID, let selection = agentSource?.launchSelection(for: agentID) {
            applyLaunchSelection(selection)
        }
        descriptor.status = .idle
        descriptor.statusUpdatedAt = Date()
        agentStatus = .idle
        applyHeader(status: .idle)
        refreshTranscriptThinkingIndicator()
        synchronizeV2Transcript(final: true)
        refreshFaceSwitch()
        qaTerminalFaceAppendedTurns = turns
    }

    static let terminalBoundarySymbol = AgentSupervisor.outsideBoundarySymbol

    /// Appends turns this agent's session took outside the tile under the
    /// supervisor's boundary ("In Terminal · 2 turns"), through the restore's
    /// own replay — the same steps the agent's transcript took.
    func appendTurnsTakenOutside(_ appended: RehydratedTranscript, boundary: String) {
        guard !appended.steps.isEmpty else { return }
        model.appendSessionBoundary(
            id: "outside-\(UUID().uuidString)", text: boundary, symbolName: Self.terminalBoundarySymbol)
        replayRehydratedSteps(appended)
    }

    /// "In Terminal · 1 turn" — the divider over the turns the face took.
    static func terminalBoundaryText(turns: Int, place: String = "Terminal") -> String {
        AgentSupervisor.outsideBoundaryText(turns: turns, place: place)
    }

    private func persistTerminalFace(_ state: AgentTerminalFaceState?) {
        guard tile.metadata.agentTerminalFace != state else { return }
        var next = tile
        next.metadata.agentTerminalFace = state
        tile = next
        canvas?.updateTile(next, recalculateZoneBounds: false)
    }

    /// × in the Terminal face closes the agent's tile as it always has, after
    /// asking when claude is mid-turn (edge case 6). Claude ends with it: a
    /// session nobody can see must not keep writing. Its turns reach the
    /// agent's transcript through the face's one end, for the next tile.
    override func handleCloseRequest() {
        guard let session = terminalFaceSession else {
            super.handleCloseRequest()
            return
        }
        if session.isBusy, let environment = terminalFaceEnvironment,
           !environment.confirm("Claude is working in this terminal.", "Stop and Close") { return }
        let watch = session.watch
        watch.onHostEnded = nil
        watch.onHostClientDetached = nil
        watch.onHostSessionChange = nil
        terminalFaceSession = nil
        if session.tmuxSessionName != nil {
            // The client goes now; claude's session is killed off the main
            // thread, and the watch sees it gone.
            session.detachSurface()
            watch.endClaude(surface: nil)
        } else {
            // Claude is this surface's child and ends with it.
            session.detachSurface()
            agentSource?.finishTerminalFace(for: watch.agentID)
        }
        persistTerminalFace(nil)
        setContentView(arrayFaceBody)
        super.handleCloseRequest()
    }

    /// QA: how many turns the last flip back appended.
    private(set) var qaTerminalFaceAppendedTurns = 0
    var qaFaceFlipBannerVisible: Bool { !faceFlipBanner.isHidden }
    var qaFaceFlipBanner: AgentFaceFlipBanner { faceFlipBanner }

    // MARK: - A session another app holds (.plans/79-session-handoff, phase 2)
    //
    // Watching a session from another app, waiting to move it here, or paused
    // because one of this agent's sessions was opened elsewhere. The host
    // decides which (`AppDelegate.reconcileExternalSessions`); the tile shows
    // it in place of the composer and keeps its transcript current by reading
    // the CLI's own session file, a whole line at a time, from where it left
    // off.

    /// Pressed banner buttons, for the host.
    var onSessionHandoffAction: ((AgentSessionHandoffAction) -> Void)?
    private let sessionHandoffBanner = AgentSessionHandoffBanner(frame: .zero)
    private(set) var sessionHandoffState: AgentSessionHandoffState?

    func applySessionHandoff(_ state: AgentSessionHandoffState?, status: AgentStatus? = nil) {
        defer { chromeDidChange() }
        sessionHandoffState = state
        if let state { sessionHandoffBanner.apply(state) }
        sessionHandoffBanner.isHidden = state == nil
        composeBackdrop.isHidden = state != nil
        switch state {
        case let .watching(app, _, _), let .ended(app): setTitleBarWhereMarker("\(app) \u{00B7} read-only")
        case .waitingToMove, .paused, nil: setTitleBarWhereMarker(nil)
        }
        agentStatusOverride = state == nil ? nil : status
        applyAgentHeader(status: descriptor.status)
    }

    /// How often a followed session file is asked for its length. One stat
    /// per interval while the tile is resident, and nothing per frame.
    static var sessionFollowInterval: TimeInterval = 1.5
    private struct SessionFollow {
        var url: URL
        var provider: ExternalSessionProvider
        /// Just past the last whole line rendered.
        var offset: UInt64
        var reading: Bool
        /// Stopping: one last read renders what is left, then nothing more.
        var finishing = false
    }
    private var sessionFollow: SessionFollow?
    private var sessionFollowTimer: Timer?

    /// Renders a session from its file and follows it as the other app writes.
    /// A second call for the same file only makes sure the follower runs.
    func followSessionFile(_ url: URL, provider: ExternalSessionProvider, origin: String) {
        if sessionFollow?.url == url {
            startSessionFollowTimer()
            return
        }
        sessionFollow = SessionFollow(url: url, provider: provider, offset: 0, reading: true)
        let threadId = threadId
        let maxBytes = RehydrationLimits().maxBytes
        Task.detached(priority: .userInitiated) { [weak self] in
            let tail = SessionFileTail.tail(in: url, maxBytes: maxBytes)
            let transcript = Self.parseSession(tail.lines, provider: provider, threadId: threadId, truncated: tail.truncated)
            await MainActor.run {
                guard let self, var follow = self.sessionFollow, follow.url == url else { return }
                if !transcript.steps.isEmpty {
                    // A tile made a moment ago may not have laid out yet, and a
                    // transcript list given rows before its first layout leaves
                    // the last of them off screen.
                    self.layoutSubtreeIfNeeded()
                    let count = transcript.restoredMessageCount
                    let text = "From \(origin) \u{2014} \(count) \(count == 1 ? "message" : "messages")"
                        + (transcript.omittedEarlier ? " \u{00B7} earlier history not shown" : "")
                    self.renderRehydratedPreviousSession(transcript, boundaryText: text)
                }
                follow.offset = tail.end
                follow.reading = false
                self.sessionFollow = follow
                if follow.finishing {
                    self.readFollowedSessionFile()
                } else {
                    self.startSessionFollowTimer()
                }
            }
        }
    }

    /// Stops following. `catchUp` first renders whatever was written since the
    /// last read — the moment a session becomes this agent's, nothing the other
    /// app wrote may be missing from the transcript. The read runs off the main
    /// thread, after any read already in flight, from where that one ends.
    func stopFollowingSessionFile(catchUp: Bool) {
        sessionFollowTimer?.invalidate()
        sessionFollowTimer = nil
        guard var follow = sessionFollow else { return }
        guard catchUp else {
            sessionFollow = nil
            return
        }
        follow.finishing = true
        sessionFollow = follow
        if !follow.reading { readFollowedSessionFile() }
    }

    /// What the followed file holds past the last read: read and parsed off
    /// the main thread — bounded as a restore is — and replayed on it.
    private func readFollowedSessionFile() {
        guard var follow = sessionFollow, !follow.reading else { return }
        follow.reading = true
        sessionFollow = follow
        let (url, offset, provider, threadId) = (follow.url, follow.offset, follow.provider, threadId)
        let limits = RehydrationLimits()
        Task.detached(priority: .utility) { [weak self] in
            let chunk = SessionFileTail.lines(in: url, from: offset, maxBytes: limits.maxBytes)
            let transcript = Self.parseSession(chunk.lines, provider: provider, threadId: threadId, truncated: chunk.truncated)
            await MainActor.run {
                guard let self, var follow = self.sessionFollow, follow.url == url, follow.offset == offset else { return }
                if !transcript.steps.isEmpty { self.replayRehydratedSteps(transcript) }
                follow.offset = chunk.end
                follow.reading = false
                self.sessionFollow = follow.finishing ? nil : follow
            }
        }
    }

    nonisolated private static func parseSession(
        _ lines: [String], provider: ExternalSessionProvider, threadId: String, truncated: Bool = false,
        limits: RehydrationLimits = RehydrationLimits()
    ) -> RehydratedTranscript {
        switch provider {
        case .claude:
            return ClaudeSessionTranscriptReader.parse(lines: lines, threadId: threadId, truncated: truncated, limits: limits)
        case .codex:
            return CodexSessionTranscriptReader.parse(lines: lines, threadId: threadId, truncated: truncated, limits: limits)
        }
    }

    private func startSessionFollowTimer() {
        guard sessionFollowTimer == nil, sessionFollow != nil else { return }
        let timer = Timer(timeInterval: Self.sessionFollowInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollSessionFile() }
        }
        RunLoop.main.add(timer, forMode: .common)
        sessionFollowTimer = timer
    }

    /// One stat; a read only when the file grew. The read and parse run off
    /// the main thread, the replay on it.
    func pollSessionFile() {
        guard let follow = sessionFollow, !follow.reading, !follow.finishing,
              SessionFileTail.length(follow.url) > follow.offset else { return }
        readFollowedSessionFile()
    }

    /// QA: a follower still reading, or finishing its last read.
    var qaSessionFollowBusy: Bool { sessionFollow != nil }

    var qaSessionHandoffBanner: AgentSessionHandoffBanner? {
        sessionHandoffBanner.isHidden ? nil : sessionHandoffBanner
    }
    var qaComposerHidden: Bool { composeBackdrop.isHidden }
    var qaSessionFollowOffset: UInt64? { sessionFollow?.offset }
    var qaSessionFollowReading: Bool { sessionFollow?.reading ?? false }
    var qaSessionFollowTimerRunning: Bool { sessionFollowTimer?.isValid == true }

    // MARK: - Identity colour

    /// Posted (object: the tile) whenever `identityColor` changes, for views that
    /// borrow the agent's tint — the composer's dictation waveform is the first.
    static let identityColorDidChangeNotification = Notification.Name("array.agentTile.identityColorChanged")
    /// The title bar's wash over `tileChrome`. A zone tint at full strength is
    /// the loudest thing on a tile; this keeps the hue identifiable and quiet,
    /// and the title legible on it.
    static let identityBarAlpha: CGFloat = 0.3
    /// Full border mode: a stroke a muted tint still reads at, kept under
    /// `LineWidth.rule` (the state-bearing edge) and drawn under the canvas's
    /// focus and attention overlays, which therefore still win.
    static let identityBorderWidth = CGFloat(LineWidth.hairline)
    static let identityBorderAlpha: CGFloat = 0.7

    /// The agent's identity tint, unmuted — nil when the agent has none or the
    /// tile follows no agent. Kept current on attach and on every record change;
    /// `identityColorDidChangeNotification` announces each change.
    private(set) var identityColor: NSColor? {
        // A live dictation session wears the agent's colour; none falls back
        // to the input accent inside the pill.
        didSet { v2DictationPill.tint = identityColor }
    }

    private func setIdentityColorName(_ name: String?) {
        guard name != identityColorName else { return }
        identityColorName = name
        identityColor = name.map { ZoneChromeNSView.color(named: $0) }
        applyIdentityChrome()
        NotificationCenter.default.post(name: Self.identityColorDidChangeNotification, object: self)
    }

    @objc private func identityStyleSettingChanged(_ notification: Notification) {
        applyIdentityChrome()
    }

    /// The tile's resting perimeter and the identity treatment, from scratch.
    /// With no colour this is exactly the shipped rest state: no title-bar wash and a
    /// zero-width outline. The style is read only when there is something to draw.
    private func applyIdentityChrome() {
        defer { chromeDidChange() }
        let theme = effectiveTokenTheme
        let style = identityColor == nil ? nil : AgentIdentityColorConfig.style(defaults: identityStyleDefaults)
        if let tint = identityColor, style == .border {
            layer?.borderWidth = Self.identityBorderWidth
            layer?.borderColor = tint.withAlphaComponent(Self.identityBorderAlpha).cgColor
        } else {
            layer?.borderWidth = 0
            layer?.borderColor = AgentLineRole.decorativeHairline.color.cgColor(for: theme)
        }
        setTitleBarTint(style == .topBar ? identityColor?.withAlphaComponent(Self.identityBarAlpha) : nil)
    }

    /// "Color" — None and the zone palette, the current one checked. The same
    /// vocabulary and order as a zone's Color submenu, so an agent and the zone
    /// it sits in can be matched by name. ABSENT for a tile with no agent: the
    /// colour belongs to the agent's record, never to the tile.
    private func makeIdentityColorMenuItems() -> [NSMenuItem] {
        guard let agentID = attachedAgentID,
              let record = agentSource?.records[agentID] else { return [] }
        let root = NSMenuItem(title: "Color", action: nil, keyEquivalent: "")
        root.identifier = NSUserInterfaceItemIdentifier("agentTile.identityColor")
        let menu = NSMenu(title: "Color")
        let current = record.identityColor?.lowercased()
        let none = NSMenuItem(title: "None", action: #selector(selectIdentityColor(_:)), keyEquivalent: "")
        none.target = self
        none.representedObject = ""
        none.identifier = NSUserInterfaceItemIdentifier("agentTile.identityColor.none")
        none.state = current == nil ? .on : .off
        menu.addItem(none)
        menu.addItem(.separator())
        for color in ZoneColorConfig.palette {
            let item = NSMenuItem(title: color.capitalized, action: #selector(selectIdentityColor(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = color
            item.identifier = NSUserInterfaceItemIdentifier("agentTile.identityColor.\(color)")
            item.state = current == color ? .on : .off
            menu.addItem(item)
        }
        root.submenu = menu
        return [root]
    }

    @objc private func selectIdentityColor(_ sender: NSMenuItem) {
        guard let agentID = attachedAgentID, let supervisor = agentSource,
              let raw = sender.representedObject as? String else { return }
        _ = supervisor.setIdentityColor(agentID: agentID, raw.isEmpty ? nil : raw)
    }

    /// CX-01 (`.plans/59` §14.1): the per-agent workspace-tools policy, offered on
    /// the tile the agent lives in. A checkmark, not a submenu — it is one boolean.
    ///
    /// It reads `AgentRecord.workspaceToolsEnabled` and writes it through
    /// `AgentSupervisor.setWorkspaceToolsEnabled`, whose `onWorkspaceToolsChanged`
    /// makes the host service drop every grant it had minted for this agent, so
    /// unchecking it revokes rather than only affecting the next dispatch. ABSENT
    /// (not disabled) for a tile with no agent behind it: there is no record to
    /// toggle, and the policy belongs to the agent, never to the tile.
    private func makeWorkspaceToolsMenuItems() -> [NSMenuItem] {
        guard let agentID = attachedAgentID,
              let record = agentSource?.records[agentID] else { return [] }
        let item = NSMenuItem(
            title: "Workspace Tools",
            action: #selector(toggleWorkspaceToolsMenuItem(_:)),
            keyEquivalent: "")
        item.target = self
        item.identifier = NSUserInterfaceItemIdentifier("agentTile.workspaceTools.toggle")
        item.state = record.workspaceToolsEnabled ? .on : .off
        return [item]
    }

    @objc private func toggleWorkspaceToolsMenuItem(_ sender: NSMenuItem) {
        // Re-read the record rather than trusting the item's painted state: the
        // menu can have been built before another surface (Settings, a revoking
        // API deny) moved the flag.
        guard let agentID = attachedAgentID,
              let supervisor = agentSource,
              let record = supervisor.records[agentID] else { return }
        _ = supervisor.setWorkspaceToolsEnabled(agentID: agentID, !record.workspaceToolsEnabled)
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
        if let session = terminalFaceSession {
            terminalFaceSession = nil
            let watch = session.watch
            watch.onHostEnded = nil
            watch.onHostClientDetached = nil
            watch.onHostSessionChange = nil
            if session.tmuxSessionName == nil, !watch.isEnded {
                // tmux off: claude is this surface's child, and ending it here
                // would stop a turn nobody was asked about (review #17). The
                // surface keeps running with no tile; a tile rebuilt for the
                // agent shows it again, and claude's exit still ends the face.
                session.hostView.removeFromSuperview()
                watch.keepSurfaceAlive(session)
            } else {
                // The client goes; claude stays in tmux, and the watch follows it.
                session.detachSurface()
            }
        }
        detach()
    }

    /// A parked agent tile does no per-event view work: it lets go of its event
    /// subscription and observers (the agent keeps running in the supervisor)
    /// and the workspace's return re-attaches it from the supervisor's
    /// transcript snapshot — the same view object, not a rebuilt one. `detach`
    /// is idempotent, so an eviction after a park cancels nothing twice.
    override func prepareForParking() {
        detach()
    }

    var isAttachedToAgent: Bool { attachedAgentID != nil }

    func detach() {
        prepareStreamingMarkupForTeardown(final: true)
        // A detached tile follows nothing: no session file is read for it.
        sessionFollowTimer?.invalidate()
        sessionFollowTimer = nil
        // Detach is an immediate visual/lifecycle boundary: a retained transcript
        // may remain visible, but its live Gyro tail must stop and leave the list
        // document before any later reuse.
        transcriptCollectionFixture?.setThinkingIndicatorVisible(false)
        // Clear lifecycle facts before the detached-location demotion so the
        // final compact projection keeps recent What without retaining a live
        // phase claim. A detached view follows no agent, so it holds no
        // presence of its own either: it has nothing authoritative to say.
        followsSupervisorPresence = false
        localPresence = AgentTurnPresence()
        hasPresenceFacts = false
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
        // The colour stays on screen with the transcript a detached view keeps
        // showing; only the subscription ends, so a later pick on another view of
        // the agent cannot repaint a view that no longer follows it.
        if let identityColorObserverToken, let agentID = attachedAgentID {
            agentSource?.removeIdentityColorObserver(identityColorObserverToken, for: agentID)
            self.identityColorObserverToken = nil
        }
        if let promptEchoObserverToken, let agentID = attachedAgentID {
            agentSource?.removePromptEchoObserver(promptEchoObserverToken, for: agentID)
            self.promptEchoObserverToken = nil
        }
        if let localNoticeObserverToken, let agentID = attachedAgentID {
            agentSource?.removeLocalNoticeObserver(localNoticeObserverToken, for: agentID)
            self.localNoticeObserverToken = nil
        }
        if let outsideHistoryObserverToken, let agentID = attachedAgentID {
            agentSource?.removeOutsideHistoryObserver(outsideHistoryObserverToken, for: agentID)
            self.outsideHistoryObserverToken = nil
        }
        // Before the flush: a closing or parked tile keeps no hypothesis, and
        // the draft it flushes is the one the user had before speaking.
        v2Composer?.cancelDictation()
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
        if let backgroundJobsObserver { NotificationCenter.default.removeObserver(backgroundJobsObserver) }
        backgroundJobsObserver = nil
        compactStatusRow.applyBackgroundJobs(value: nil, detail: "", spoken: "")
        updateV2ComposerPresentation()
    }

    /// The chip reads the tracker; the tracker says when to.
    private func refreshBackgroundJobs() {
        defer { chromeDidChange() }
        guard let agentID = attachedAgentID, let tracker = agentSource?.processTracker else {
            compactStatusRow.applyBackgroundJobs(value: nil, detail: "", spoken: "")
            return
        }
        let jobs = tracker.jobs(for: agentID)
        let now = Date()
        compactStatusRow.applyBackgroundJobs(
            value: AgentBackgroundJobText.chipValue(jobs),
            detail: AgentBackgroundJobText.detail(jobs, now: now),
            spoken: "Background processes: " + jobs.map { AgentBackgroundJobText.menuTitle($0, now: now) }
                .joined(separator: ", ") + ".")
    }

    var qaBackgroundJobsChipValue: String? { compactStatusRow.qaBackgroundJobsValue }

    /// This agent's processes, in the live panel, opened from the chip.
    func showBackgroundProcesses(from anchor: NSView? = nil) {
        guard let agentID = attachedAgentID, let tracker = agentSource?.processTracker else { return }
        tracker.panel.toggle(from: anchor ?? compactStatusRow.backgroundJobsAnchor, scope: agentID)
    }

    private func makeBackgroundProcessesMenuItems() -> [NSMenuItem] {
        guard let agentID = attachedAgentID, let tracker = agentSource?.processTracker,
              !tracker.jobs(for: agentID).isEmpty else { return [] }
        let item = NSMenuItem(title: "Show Background Processes", action: #selector(showBackgroundProcessesFromMenu(_:)), keyEquivalent: "")
        item.target = self
        item.identifier = NSUserInterfaceItemIdentifier("agentTile.backgroundProcesses")
        return [item]
    }

    @objc private func showBackgroundProcessesFromMenu(_ sender: Any?) {
        // After the menu closes, so the panel's outside-click watch does not
        // see the menu's own dismissal.
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.showBackgroundProcesses() } }
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
        if let terminalFaceSession {
            terminalFaceSession.runtime.focus()
            return true
        }
        // Before the composer is targeted, not after: while surfaced, that text view
        // is inside the parked body, and AppKit would focus it there.
        promoteForIncomingFocus()
        wakeChrome()
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

    /// Re-read the agent's branch state and repaint, at a turn boundary: the whole
    /// point is to see what that turn did, so the read is fresh, never the cache's.
    ///
    /// Off the main thread. Reading a branch is a `git` launch, and run here it
    /// held the canvas still for tens of milliseconds every time any agent finished
    /// a turn — the periodic hitch under a pan or zoom (one per agent per turn on the
    /// motion benchmark). The chip keeps the branch it shows until the read lands.
    private func refreshBranchContext() {
        guard let agentSource, let agentID = projectedAgentID,
              let repo = agentSource.checkoutRoot(for: agentID) else { return }
        branchRefreshGeneration &+= 1
        let generation = branchRefreshGeneration
        Task { [weak self] in
            let branch = await Task.detached(priority: .utility) {
                (try? WorktreeManager().currentBranch(repo: repo)) ?? nil
            }.value
            guard let self, self.branchRefreshGeneration == generation,
                  self.projectedAgentID == agentID, let source = self.agentSource else { return }
            source.storeCheckedOutBranch(branch, repo: repo)
            self.applyBranchContext(source.branchContextCachedOnly(for: agentID))
            self.qaBranchRefreshesLanded += 1
        }
    }
    private var branchRefreshGeneration = 0
    private(set) var qaBranchRefreshesLanded = 0

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
        // A followed session renders again from its file on the next wire.
        stopFollowingSessionFile(catchUp: false)
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

    /// The tile's agent is not in this copy of Array's agent store — typically
    /// another install made it (CLAUDE.md hazard 10). Nothing is started until
    /// the person sends a prompt.
    static let unboundAgentNoticeText =
        "No agent here — this tile's agent belongs to another copy of Array. Send a prompt to start a new agent in this tile."
    /// The tile's agent exists in this store but its Home directory is gone.
    /// It is kept, not replaced: the folder may come back.
    static let unavailableAgentNoticeText =
        "Agent unavailable — its Home folder no longer exists. Restore the folder and relaunch to continue."

    /// Says why a prompt was not sent, in the transcript where the user is already
    /// looking. EVERY refusal appends: the id used to carry only the reason's
    /// hash, so the second identical refusal was dropped as a duplicate and the
    /// user saw their bubble and nothing else — the void.
    func showSendRefusedNotice(_ text: String) {
        sendRefusalOrdinal += 1
        model.appendNotice(
            id: "notice-send-refused-\(sendRefusalOrdinal)",
            title: "Not sent",
            text: text
        )
        synchronizeV2Transcript(final: true)
    }

    private var sendRefusalOrdinal = 0
    /// The reason the composer reported for the submission now resolving.
    private var pendingSubmissionRefusal: IntentRefusal?

    /// The words for a refused submission: the supervisor's own reason for a
    /// CLI that cannot take it, never a generic "not sent".
    private func refusalText(for refusal: IntentRefusal?) -> String {
        let retry = "Your message is back in the composer — press Return to retry."
        switch refusal {
        case .harnessNotReady?:
            if let agentID = attachedAgentID, let reason = agentSource?.sendRefusal(for: agentID) {
                return "\(reason) \(retry)"
            }
            return "The agent's CLI is not ready. \(retry)"
        case .turnNotReady?:
            return "The agent is still busy with the last message. \(retry)"
        case .invalidAttachment?:
            return "An attachment could not be sent — remove it and try again."
        case .unknownAgent?:
            return "There is no agent behind this tile to send to."
        case .unsupported?:
            return "This agent can\u{2019}t run that. \(retry)"
        case .emptyDraft?, .noTurnInProgress?, nil:
            return "Message was not sent. \(retry)"
        }
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

    /// Hazard 10's tile: no record for it in this store. Says so, and what the
    /// person can do; the app binds `onSubmitPrompt` to that explicit start.
    func showUnboundAgentNotice() {
        model.appendNotice(id: "notice-agent-unbound", title: "no agent", text: Self.unboundAgentNoticeText)
        synchronizeV2Transcript(final: true)
    }

    /// The tile's agent is in this store but its Home is gone.
    func showUnavailableAgentNotice() {
        model.appendNotice(id: "notice-agent-unavailable", title: "unavailable", text: Self.unavailableAgentNoticeText)
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
    func renderRehydratedPreviousSession(_ transcript: RehydratedTranscript, boundaryText: String? = nil) {
        guard !hasRenderedRehydratedSession else { return }
        hasRenderedRehydratedSession = true
        cancelStreamingMarkupParseTimer()
        if let boundaryText {
            // A watched session's history ("From cmux — 12 messages"): the
            // divider every session that came from outside the tile uses.
            model.appendSessionBoundary(id: "previous-session", text: boundaryText, symbolName: "eye")
        } else {
            model.appendNotice(
                id: "notice-previous-session",
                title: "previous session",
                text: transcript.boundaryNoticeText)
        }
        replayRehydratedSteps(transcript)
    }

    /// The replay half of a restore, callable again: flipping back from the
    /// Terminal face appends the turns taken there through this same loop, so
    /// they render exactly as a full restore of the session would render them
    /// (`.plans/79`, "Flipping back is proven").
    private func replayRehydratedSteps(_ transcript: RehydratedTranscript) {
        cancelStreamingMarkupParseTimer()
        for (index, step) in transcript.steps.enumerated() {
            // A missing source instant must remain unknown. Replaying history
            // on the live clock makes hours of work look like milliseconds.
            let timestamp = transcript.stepTimestamps.indices.contains(index)
                ? transcript.stepTimestamps[index] : nil
            AgentTranscriptClock.withWallClock(timestamp) {
                switch step {
                case .userPrompt(let text):
                    model.appendUserPrompt(text)
                case .event(let event):
                    // The model filters on this tile's thread id; rebind exactly as
                    // the live subscription does, but ingest DIRECTLY (never via the
                    // event stream) so activity mirroring stays untriggered.
                    let bound = event.withThreadId(threadId)
                    // TR-01 — the host-local capture seam runs here too. It used to
                    // live only on the live path (`ingest(_:originalEvent:)`), so a
                    // restored file change reached the document with no detail
                    // identity and no store record, and its card could only report
                    // that it knew nothing. This is the same three-step dance the
                    // live path performs: capture, ingest, bind the entry the event
                    // just created.
                    let priorEntryIDs = Set(model.document.entries.map(\.id))
                    let capturedIdentity = transcriptCollectionFixture?.captureRuntimeEvent(bound)
                    model.ingest(bound)
                    if let identity = capturedIdentity,
                       case let .itemStarted(_, itemID, _, _) = bound {
                        let candidates = model.document.entries.filter { entry in
                            guard !priorEntryIDs.contains(entry.id),
                                  case let .providerItem(provider, providerItemID) = entry.provenance
                            else { return false }
                            return provider == identity.scope.provider && providerItemID == itemID
                        }
                        if candidates.count == 1 {
                            _ = transcriptCollectionFixture?.bindToolDetailIdentity(identity, to: candidates[0].id)
                        }
                    }
                case .observation(let observation):
                    // Parked by the view until the matching item starts, exactly as
                    // a live provider observation that arrives on the same frame is.
                    transcriptCollectionFixture?.captureRuntimeObservation(observation)
                }
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
        // Return arms the submission and starts its one clock. The supervisor
        // is told the same instant so its own arm, a main-actor hop and any
        // attachment await later, measures from here too.
        let returnedAt = Date()
        presenceBeforeOptimisticSubmission = localPresence
        localPresence.arm(at: returnedAt)
        hasPresenceFacts = true
        if let agentID = attachedAgentID {
            agentSource?.noteSubmissionReturn(for: agentID, at: returnedAt)
        }
        cancelStreamingMarkupParseTimer()
        model.appendUserPrompt(id: id, prompt: prompt)
        // final: true — the user's own words must not wait on the 30Hz streaming gate.
        synchronizeV2Transcript(final: true)
        // S3: your own message is where the transcript goes, even if you had
        // scrolled up to read something earlier.
        transcriptCollectionFixture?.layoutSubtreeIfNeeded()
        transcriptCollectionFixture?.jumpToLatest()
        transcriptCollectionFixture?.setTurnInFlight(true)
        refreshCompactStatus()
        transcriptCollectionFixture?.setThinkingStatusText("Sending")
        transcriptCollectionFixture?.setThinkingIndicatorVisible(true)
    }

    /// The local presence before Return armed it, restored if the prompt is
    /// refused: a refused prompt never became a submission.
    private var presenceBeforeOptimisticSubmission: AgentTurnPresence?

    private func finishOptimisticSubmission(accepted: Bool) {
        guard let optimisticID = pendingOptimisticSubmissionID else { return }
        pendingOptimisticSubmissionID = nil
        let armedLocally = presenceBeforeOptimisticSubmission
        presenceBeforeOptimisticSubmission = nil
        let refusal = pendingSubmissionRefusal
        pendingSubmissionRefusal = nil
        guard accepted else {
            if let armedLocally { localPresence = armedLocally }
            transcriptCollectionFixture?.setTurnInFlight(false)
            refreshCompactStatus()
            transcriptCollectionFixture?.setThinkingIndicatorVisible(false)
            // The bubble never went anywhere: take it back (the draft is in the
            // composer) and say "Not sent" with the real reason, every time.
            model.withdrawLocalPrompt(id: optimisticID)
            showSendRefusedNotice(refusalText(for: refusal))
            return
        }
        // Array-owned slash commands are accepted without starting a provider
        // turn. The old unconditional "Starting" paint left their gyro spinning
        // forever because no runtime event exists to take it down. At acceptance
        // time the supervisor has already armed its presence for every prompt
        // that really does start a turn (or is held for a starting CLI), so the
        // presence owner is the truthful split.
        guard let agentID = attachedAgentID,
              agentSource?.turnPresence(for: agentID)?.isLive == true else {
            if let armedLocally { localPresence = armedLocally }
            transcriptCollectionFixture?.setTurnInFlight(false)
            refreshCompactStatus()
            transcriptCollectionFixture?.setThinkingIndicatorVisible(false)
            return
        }
        // The supervisor has armed its own presence by now; the row and tail
        // read it from here on ("Starting · Ns" on the one clock).
        refreshCompactStatus()
        refreshTranscriptThinkingIndicator()
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
        // Compatibility-only local anchor. The v2 header uses the supervisor's
        // stamped snapshot; do not restamp this fallback when replay or a provider
        // repeats the same turn boundary.
        surfaceVisualEpoch &+= 1
        if case .turnStarted = event, startedAt == nil { startedAt = Date() }
        // A prompt is done once the agent settles or a turn ends. Clearing the
        // in-flight latch here re-enables the compose row (see submitPrompt).
        switch event {
        case .turnCompleted, .runtimeError,
             .sessionStateChanged(.ready), .sessionStateChanged(.stopped), .sessionStateChanged(.error):
            promptInFlight = false
            startedAt = nil
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
        localPresence.reduce(event, at: AgentElapsedClock.now())
        hasPresenceFacts = true
        let captureEvent = originalEvent ?? event
        let capturedIdentity = transcriptCollectionFixture?.captureRuntimeEvent(captureEvent)
        // Only an item event binds a tool detail; building the set of every entry
        // ID on every streamed chunk cost O(transcript) per chunk (history S02).
        let priorEntryIDs: Set<AgentNodeID> = capturedIdentity == nil
            ? [] : Set(model.document.entries.map(\.id))
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
        // A streamed chunk changes no status fact (the location projector dedupes
        // it, and the elapsed clock has its own tick), but rebuilding the row per
        // chunk was a tenth of the main thread with eight agents streaming
        // (`.plans/84`). Chunks refresh it at most every `chunkStatusInterval`;
        // every other event refreshes it at once.
        if case .contentDelta = event {
            scheduleChunkStatusRefresh()
        } else {
            refreshLocationStatus()
        }
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
        // The turn's phase and clock are read live from the supervisor's
        // presence (`currentPresence`); only the facts presence does not own are
        // seeded here.
        hasPresenceFacts = true
        if let snapshot = supervisor.turnSnapshot(for: agentID) {
            switch snapshot.state {
            case .compacting:
                compactionSessionFact = .init(state: .running)
                liveToolVerb = (itemID: "context-compaction", text: "Compacting context…")
            case .needsAction:
                compactStatusInteraction = .pending(startedAt: nil)
            case .ready, .restored, .starting, .working, .queued, .failed:
                break
            }
        }
        if compactContextWindow == nil,
           var contextSeed = supervisor.contextWindowSnapshot(for: agentID) {
            if case .live = contextSeed.freshness { contextSeed.freshness = .stale }
            compactContextWindow = contextSeed
        }
        if compactContextWindow == nil,
           let freshSeed = supervisor.freshSessionContextWindow(for: agentID) {
            // Zero prior turns: the supervisor states the model's window when it
            // knows one (0%) and none otherwise (the empty ring). The tile looks
            // nothing up itself.
            compactContextWindow = freshSeed
        }
        refreshCompactStatus()
    }

    /// Update the compact-row facts from the same managed-agent event stream as
    /// the transcript. Events do not carry provider timestamps, so only the
    /// supervisor's stamped turn start is used as an elapsed anchor; interaction
    /// and session receipt times remain nil rather than becoming fake precision.
    private func updateCompactStatusFacts(for event: AgentRuntimeEvent) {
        // Session and turn phase are NOT written here: they are projections of
        // `currentPresence`, which a provider's session event cannot regress.
        switch event {
        case let .sessionStateChanged(state):
            if state == .ready || state == .stopped || state == .error {
                compactStatusInteraction = nil
            }
        case .turnStarted:
            transcriptCollectionFixture?.setTurnInFlight(true)
        case .contentDelta:
            break
        case .turnCompleted:
            liveToolVerb = nil
            transcriptCollectionFixture?.setTurnInFlight(false)
            compactStatusInteraction = .clear
        case .requestOpened, .userInputRequested:
            compactStatusInteraction = .pending(startedAt: nil)
        case .requestResolved, .userInputResolved:
            compactStatusInteraction = .clear
        case .runtimeError:
            transcriptCollectionFixture?.setTurnInFlight(false)
            compactStatusInteraction = .clear
        case .compactionChanged(_, let lifecycle):
            switch lifecycle.phase {
            case .requested, .running:
                liveToolVerb = (itemID: "context-compaction", text: "Compacting context…")
                compactionSessionFact = .init(state: .running, startedAt: lifecycle.observedAt)
            case .succeeded, .failed, .cancelled, .indeterminate:
                liveToolVerb = nil
                compactionSessionFact = nil
            }
        case .itemStarted, .itemCompleted, .tokenUsageUpdated, .childAgentSpawned, .semanticSignal:
            break
        case let .contextWindowUpdated(_, snapshot):
            // The supervisor's reading, rendered as delivered. It owns the
            // window lookup and the merge (`AgentContextMeter`); a tile that
            // derived its own lost the window for any model pi's store lacks.
            compactContextWindow = snapshot
        }
    }

    /// `now` defaults to `AgentElapsedClock` (`Date()` outside the film build), the
    /// clock the header's own elapsed readout uses, so the two never disagree.
    private func refreshCompactStatus(at now: Date = AgentElapsedClock.now(), location: AgentLocationSnapshot? = nil) {
        defer { chromeDidChange() }
        // Turn cards: the newest turn's work strip reads the same presence the
        // row does, on the same tick.
        transcriptCollectionFixture?.setTurnPresence(currentPresence)
        guard let snapshot = location ?? projectedAgentID.flatMap({
            agentSource?.locationSnapshot(for: $0, at: now)
        }) else {
            applyUnknownCompactStatus()
            return
        }
        let phaseFacts = compactPhaseFacts()
        let facts = AgentCompactStatusPhaseFacts(
            session: phaseFacts.session,
            turn: phaseFacts.turn,
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
                contextWindow: compactContextWindow,
                accountQuota: currentAccountQuota(),
                enabledElements: AgentStatusElementConfig.visibleElements())
            compactStatusRow.apply(presentationWithoutThinkingIndicator(presented))
            // A running compaction names itself; the silence and tool
            // overrides describe a turn, which this is not.
            let compacting = compactionSessionFact != nil
            setLiveTailStatusText(
                (compacting ? nil : presenceTailOverride(now: now)) ?? Self.tailStatusText(
                    for: presented.activity, liveToolVerb: liveToolVerb?.text,
                    startupDetail: currentPresence.startupDetail, compacting: compacting))
            syncCompactStatusTick(for: presented.activity)
            return
        }
        activity = unknownCompactActivity()
        compactStatusRow.apply(presentationWithoutThinkingIndicator(AgentCompactStatusPresentation(
            location: compactLocationPresentation(snapshot, detail: locationPresentation),
            activity: activity,
            context: AgentRadialContextMeterPresenter.present(compactContextWindow),
            quotas: currentQuotaPresentations(at: now),
            cost: currentCostPresentation(),
            enabledElements: AgentStatusElementConfig.visibleElements())))
        setLiveTailStatusText(Self.tailStatusText(
            for: activity, liveToolVerb: liveToolVerb?.text, compacting: compactionSessionFact != nil))
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

    /// What the tail says instead of the phase when the provider's silence is
    /// the news: a retry it announced ("Retrying (2/5) in 3s"), or a minute
    /// with no output while no tool is running ("No output for 1m · still
    /// running" — calm, not a failure; a running tool may legitimately be
    /// quiet and keeps its own clock).
    private func presenceTailOverride(now: Date) -> String? {
        let presence = currentPresence
        guard presence.isLive else { return nil }
        if let retry = presence.retry {
            var text = "Retrying"
            if let maximum = retry.maxAttempts {
                text += " (\(retry.attempt)/\(maximum))"
            } else {
                text += " (attempt \(retry.attempt))"
            }
            if let delay = retry.delay {
                let remaining = Int((delay - now.timeIntervalSince(retry.observedAt)).rounded(.up))
                if remaining > 0 { text += " in \(remaining)s" }
            }
            return text
        }
        if case let .tool(tool) = presence.phase {
            // An open tool keeps its verb and its clock even when the
            // location observation behind the row has nothing specific to say
            // (it used to fall back to "Thinking" while a command ran).
            if let phase = compactStatusResolution.phase,
               [.reading, .searching, .editing, .running].contains(phase) { return nil }
            let verb = liveToolVerb?.text ?? "Running \(Self.shortToolTitle(tool))"
            guard let since = presence.currentToolStartedAt else { return verb }
            return "\(verb) · \(Self.liveElapsedText(now.timeIntervalSince(since)))"
        }
        guard let quiet = presence.quietInterval(now: now), quiet >= Self.quietThreshold else { return nil }
        return "No output for \(Self.quietDurationText(quiet)) · still running"
    }

    static let quietThreshold: TimeInterval = 60

    /// The provider's title for a step, one short line; its kind otherwise.
    static func shortToolTitle(_ tool: AgentTurnPresence.Tool) -> String {
        let line = tool.title?.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard !line.isEmpty else { return tool.name }
        return line.count > 40 ? String(line.prefix(40)) + "…" : line
    }

    /// "12s", "1m", "1m 12s" — a live step's clock.
    static func liveElapsedText(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        if seconds < 60 { return "\(seconds)s" }
        return seconds % 60 == 0 ? "\(seconds / 60)m" : "\(seconds / 60)m \(seconds % 60)s"
    }

    /// "1m", "12m", "1h 5m" — silence is read in minutes.
    static func quietDurationText(_ interval: TimeInterval) -> String {
        let minutes = max(1, Int(interval) / 60)
        if minutes < 60 { return "\(minutes)m" }
        let remainder = minutes % 60
        return remainder == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(remainder)m"
    }

    /// The compact row's session/turn facts, projected from `currentPresence`
    /// on the one clock (Return). A running compaction adds its own session
    /// fact; a probe's injected facts win while it holds them.
    private func compactPhaseFacts() -> (session: AgentCompactStatusPhaseFacts.Session?, turn: AgentCompactStatusPhaseFacts.Turn?) {
        if let injectedCompactFacts { return injectedCompactFacts }
        let presence = currentPresence
        let anchor = presence.startedAt
        var session: AgentCompactStatusPhaseFacts.Session?
        var turn: AgentCompactStatusPhaseFacts.Turn?
        switch presence.phase {
        case .idle:
            session = hasPresenceFacts ? .init(state: .ready) : nil
        case .starting:
            session = .init(state: .starting, startedAt: anchor)
        case .thinking, .tool:
            session = .init(state: .running)
            turn = .active(startedAt: anchor, stream: nil, streamStartedAt: nil)
        case .writing:
            session = .init(state: .running)
            turn = .active(startedAt: anchor, stream: .assistant, streamStartedAt: anchor)
        case let .settled(cause):
            session = .init(state: .ready)
            turn = .completed(outcome: cause == .completed ? .completed : .interrupted, phaseStartedAt: nil)
        case .failed:
            session = .init(state: .error)
            turn = .completed(outcome: .failed, phaseStartedAt: nil)
        }
        if let compactionSessionFact {
            session = compactionSessionFact
            // The compaction IS the operation in flight, anchored at its own
            // start. No runner forwards a turn for it, and a running session
            // alone resolves to "unknown" — so once the location's 30s "what"
            // expired, the live line went blank mid-compaction while the
            // header still said "Compacting context…" (Codex, 2026-10-13).
            if !presence.isLive {
                turn = .active(startedAt: compactionSessionFact.startedAt, stream: nil, streamStartedAt: nil)
            }
        }
        return (session, turn)
    }

    private func resetCompactStatusProjection(at now: Date = Date()) {
        cancelCompactStatusTick()
        compactStatusPhaseAdapter.reset()
        compactStatusResolution = .unknown
        compactionSessionFact = nil
        injectedCompactFacts = nil
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
                context: AgentRadialContextMeterPresenter.present(nil),
                quotas: currentQuotaPresentations(at: now),
                cost: currentCostPresentation(),
                enabledElements: AgentStatusElementConfig.visibleElements())))
        } else {
            applyUnknownCompactStatus()
        }
    }

    private func applyUnknownCompactStatus() {
        defer { chromeDidChange() }
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
            context: AgentRadialContextMeterPresenter.present(nil),
            // Even a fully-unknown row keeps the enabled set and the account
            // reading: the quota belongs to the harness, not to whatever this
            // tile currently knows about its own location.
            quotas: currentQuotaPresentations(at: Date()),
            cost: currentCostPresentation(),
            enabledElements: AgentStatusElementConfig.visibleElements())))
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
        // Only the ACTIVITY is being rewritten here. Everything else must be
        // carried across verbatim: this helper sits on every production repaint,
        // so a field it forgets is a field the row never shows.
        guard !activity.isSilent, Self.footerRetainsPhase(activity.phase) else {
            return AgentCompactStatusPresentation(
                location: presentation.location,
                activity: .silent(detailText: activity.detailText),
                context: presentation.context,
                quotas: presentation.quotas,
                cost: presentation.cost,
                enabledElements: presentation.enabledElements)
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
            context: presentation.context,
            quotas: presentation.quotas,
            cost: presentation.cost,
            enabledElements: presentation.enabledElements)
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
        liveToolVerb: String? = nil,
        startupDetail: String? = nil,
        compacting: Bool = false
    ) -> String? {
        guard !activity.isSilent, !footerRetainsPhase(activity.phase), !activity.text.isEmpty else {
            return nil
        }
        // A manual or automatic compaction holds the session live with no
        // stream, which the phase adapter reads as a generic active turn —
        // "Thinking". The header already says what is happening; so must this.
        if compacting {
            let text = "Compacting context…"
            guard let elapsed = activity.elapsedText, !elapsed.isEmpty else { return text }
            return "\(text) · \(elapsed)"
        }
        // `.plans/45` S6 — the verb carries the detail when the store knows it:
        // "Searching \u{201C}NBA finals\u{201D} · 31s", never just "searching".
        let text: String
        switch activity.phase {
        case .reading, .searching, .editing, .running:
            text = liveToolVerb ?? activity.text
        case .starting:
            // What the submission is waiting on, when Array knows.
            text = startupDetail ?? activity.text
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
    /// `accountQuota` is an injection seam, not a second source of truth: nil
    /// falls through to `currentAccountQuota()`, exactly what production reads.
    /// A probe needs it because the geometry harness builds a tile with no
    /// supervisor to deliver an observation through.
    func qaApplyCompactStatusFacts(
        _ facts: AgentCompactStatusPhaseFacts,
        location: AgentLocationSnapshot,
        contextWindow: AgentContextWindowSnapshot? = nil,
        accountQuota: AgentAccountQuotaSnapshot? = nil,
        enabledElements: [AgentStatusElement]? = nil,
        now: Date
    ) {
        injectedCompactFacts = (facts.session, facts.turn)
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
                contextWindow: contextWindow,
                accountQuota: accountQuota ?? currentAccountQuota(),
                // An explicit set keeps a probe deterministic. Reading live
                // defaults here would make the witness depend on whichever
                // toggles the developer happens to have set.
                enabledElements: enabledElements ?? AgentStatusElementConfig.visibleElements())
            // Same split as production: footer filter, then the gyro's words.
            // A probe that skipped either would witness a surface no user sees.
            // The rebuild is exactly where the account chips were being dropped,
            // so a witness MUST come through here rather than calling
            // `compactStatusRow.apply` with a presentation of its own.
            compactStatusRow.apply(presentationWithoutThinkingIndicator(presented))
            setLiveTailStatusText(Self.tailStatusText(for: presented.activity, liveToolVerb: liveToolVerb?.text))
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
                context: AgentRadialContextMeterPresenter.present(contextWindow),
                quotas: AgentStatusElementConfig.visibleElements()
                    .filter(\.isAccountScoped)
                    .compactMap { AgentAccountQuotaPresenter.present(
                        accountQuota ?? currentAccountQuota(), element: $0, now: now) },
                cost: currentCostPresentation(),
                enabledElements: AgentStatusElementConfig.visibleElements())))
            setLiveTailStatusText(Self.tailStatusText(for: activity, liveToolVerb: liveToolVerb?.text))
            syncCompactStatusTick(for: activity)
        }
    }

    /// The words currently riding the gyro, for witnesses.
    var qaTailStatusText: String { transcriptCollectionFixture?.qaTailStatusText ?? "" }

    /// TR-01 — the thread the model filters on, so a witness can bind a restored
    /// transcript to this tile the way the supervisor does.
    /// (`qaTranscriptForChecks` and `qaDocumentForChecks` already exist below.)
    var qaThreadIdForChecks: String { threadId }

    /// This agent's harness-wide account quota, or nil when the provider reports
    /// none. Read live rather than cached on the tile: one reading serves every
    /// agent on the login, so the supervisor is its only owner.
    private func currentAccountQuota() -> AgentAccountQuotaSnapshot? {
        guard let id = projectedAgentID else { return nil }
        return agentSource?.accountQuota(for: id)
    }

    private func currentQuotaPresentations(at now: Date) -> [AgentQuotaElementPresentation] {
        let quota = currentAccountQuota()
        return AgentStatusElementConfig.visibleElements()
            .filter(\.isAccountScoped)
            .compactMap { AgentAccountQuotaPresenter.present(quota, element: $0, now: now) }
    }

    private func currentCostPresentation() -> AgentCostElementPresentation? {
        guard AgentStatusElementConfig.isVisible(.cost) else { return nil }
        return AgentAccountQuotaPresenter.presentCost(compactContextWindow)
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
        defer { chromeDidChange() }
        evaluatePendingTerminalFlip()
        refreshFaceSwitch()
        if let agentID = attachedAgentID,
           let snapshot = agentSource?.turnSnapshot(for: agentID) {
            let couldRespond = v2TurnSnapshot?.capabilities.canRespondToRequests ?? false
            v2TurnSnapshot = snapshot
            v2Composer?.updateTurnSnapshot(snapshot)
            // TR-06: request choices are drawn only while the runner can answer,
            // and the runner slot being taken or freed moves that with no runtime
            // event. Without this the transcript keeps the context from before
            // the runner bound and an answerable request shows no choices.
            if snapshot.capabilities.canRespondToRequests != couldRespond {
                try? transcriptCollectionFixture?.updateRenderContext(v2RenderContext)
            }
            // B4: the queue mutates on the same seam (enqueue, drain, cancel,
            // clear all route through `notifyTurnCapabilitiesChanged`), so the
            // chips stay in lockstep with the primary control's own repaint.
            if let supervisor = agentSource {
                v2Composer?.bindCompletionContext(supervisor.completionContext(for: agentID))
                v2Composer?.updateQueueRail(supervisor.queueRailState(for: agentID))
            }
            // TR-06: the reply chips are a function of the turn state as well as
            // the document, and queueing moves ONLY the state — it appends no
            // entry. Refreshed on the same seam as the queue rail so the two
            // cannot disagree about whether the last question is still open.
            refreshReplyOptions(from: model.document)
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
        // overlays; the surface ladder supplies the quiet containment. The one
        // exception is an identity colour in Full border mode, which
        // `applyIdentityChrome` owns — it re-runs here so an appearance flip
        // cannot reset the outline under it.
        applyIdentityChrome()
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
        let footerRow = ProviderControlsRow(views: [providerFooter, v2DictationButton, actionButton, v2SendChoice])
        footerRow.onLayoutWidth = { [weak self] width in
            self?.fitDictationButton(rowWidth: width)
            self?.placeDictationPill()
        }
        v2DictationPill.isHidden = true
        footerRow.addSubview(v2DictationPill)
        v2FooterRow = footerRow
        footerRow.orientation = .horizontal
        footerRow.alignment = .centerY
        footerRow.spacing = CGFloat(pageZoom.scaled(Space.m))
        footerRow.translatesAutoresizingMaskIntoConstraints = false
        actionButton.setContentHuggingPriority(.required, for: .horizontal)
        actionButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        v2DictationButton.translatesAutoresizingMaskIntoConstraints = false
        v2DictationButton.setContentHuggingPriority(.required, for: .horizontal)
        v2DictationButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        v2SendChoice.translatesAutoresizingMaskIntoConstraints = false
        v2SendChoice.setContentHuggingPriority(.required, for: .horizontal)
        v2SendChoice.setContentCompressionResistancePriority(.required, for: .horizontal)

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
            let spacerHeight = statusSpacer.heightAnchor.constraint(
                equalToConstant: CGFloat(pageZoom.scaled(Space.l)))
            spacerHeight.isActive = true
            statusProviderSpacerHeight = spacerHeight
        }
        let composeColumn = NSStackView(views: composeViews)
        composeColumn.identifier = NSUserInterfaceItemIdentifier("agentTile.composeColumn")
        v2ComposeColumn = composeColumn
        composeColumn.orientation = .vertical
        composeColumn.alignment = .leading
        composeColumn.spacing = CGFloat(pageZoom.scaled(Space.m))
        composeColumn.edgeInsets = NSEdgeInsets(Inset.row, zoom: pageZoom)
        composeColumn.translatesAutoresizingMaskIntoConstraints = false
        compactStatusRow.identifier = NSUserInterfaceItemIdentifier("agentTile.statusRow")
        composer.identifier = NSUserInterfaceItemIdentifier("agentTile.composer")
        footerRow.identifier = NSUserInterfaceItemIdentifier("agentTile.providerControls")
        composeBackdrop.addSubview(composeColumn)

        locationStatus.isHidden = true
        // 2026-10-13 — pending steers and queued messages dock at the foot of
        // the transcript, on its surface and above the compose strip, so they
        // read as messages waiting to go rather than as part of the draft.
        let pendingDock = PendingMessageDockView(rail: composer.pendingMessageRail)
        pendingDock.identifier = NSUserInterfaceItemIdentifier("agentTile.pendingMessages")
        v2PendingDock = pendingDock
        faceFlipBanner.onStopNow = { [weak self] in self?.stopTurnForPendingFlip() }
        faceFlipBanner.onCancel = { [weak self] in self?.cancelPendingTerminalFlip() }
        sessionHandoffBanner.isHidden = true
        sessionHandoffBanner.onAction = { [weak self] action in self?.onSessionHandoffAction?(action) }
        // With the drawn chrome, a slot holds the transcript's place in the stack
        // and the transcript itself lives on the chrome view, so it can stay in
        // the window while the rest of the body rests detached.
        let slot: AgentTileChromeCanvasView.TranscriptSlotView? = drawsRestingChrome ? {
            let slot = AgentTileChromeCanvasView.TranscriptSlotView()
            slot.identifier = NSUserInterfaceItemIdentifier("agentTile.transcriptSlot")
            slot.translatesAutoresizingMaskIntoConstraints = false
            for axis in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
                slot.setContentHuggingPriority(transcript.contentHuggingPriority(for: axis), for: axis)
                slot.setContentCompressionResistancePriority(
                    transcript.contentCompressionResistancePriority(for: axis), for: axis)
            }
            return slot
        }() : nil
        let transcriptInStack: NSView = slot ?? transcript
        let layout = NSStackView(views: [
            agentHeader, locationStatus, transcriptInStack, pendingDock, faceFlipBanner, sessionHandoffBanner,
            composeBackdrop,
        ])
        layout.orientation = .vertical
        layout.spacing = 0
        layout.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(layout)
        // WS5: every constraint whose constant is a METRIC is held, because a
        // literal baked into an activated anchor constraint is a number nothing
        // can rescale afterwards.
        let headerHeight = agentHeader.heightAnchor.constraint(
            equalToConstant: AgentTileHeaderView.preferredHeight(zoom: pageZoom))
        let statusHeight = compactStatusRow.heightAnchor.constraint(
            equalToConstant: AgentCompactStatusRowView.preferredHeight(zoom: pageZoom))
        let footerHeight = providerFooter.heightAnchor.constraint(
            equalToConstant: AgentComposerFooterView.height(zoom: pageZoom))
        let actionHeight = actionButton.heightAnchor.constraint(
            equalToConstant: ComposerActionButton.controlHeight(zoom: pageZoom))
        let composerWidth = composer.widthAnchor.constraint(
            equalTo: composeColumn.widthAnchor,
            constant: -CGFloat(pageZoom.scaled(Inset.row).horizontal))
        let footerWidth = footerRow.widthAnchor.constraint(
            equalTo: composeColumn.widthAnchor,
            constant: -CGFloat(pageZoom.scaled(Inset.row).horizontal))
        let statusWidth = compactStatusRow.widthAnchor.constraint(
            equalTo: composeColumn.widthAnchor,
            constant: -CGFloat(pageZoom.scaled(Inset.row).horizontal))
        agentHeaderHeight = headerHeight
        compactStatusRowHeight = statusHeight
        providerFooterHeight = footerHeight
        actionButtonHeight = actionHeight
        composerWidthInset = composerWidth
        footerRowWidthInset = footerWidth
        compactStatusWidthInset = statusWidth
        NSLayoutConstraint.activate([
            layout.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            layout.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            layout.topAnchor.constraint(equalTo: root.topAnchor),
            layout.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            headerHeight,
            agentHeader.widthAnchor.constraint(equalTo: layout.widthAnchor),
            locationStatus.widthAnchor.constraint(equalTo: layout.widthAnchor),
            transcriptInStack.widthAnchor.constraint(equalTo: layout.widthAnchor),
            composeBackdrop.widthAnchor.constraint(equalTo: layout.widthAnchor),
            faceFlipBanner.widthAnchor.constraint(equalTo: layout.widthAnchor),
            sessionHandoffBanner.widthAnchor.constraint(equalTo: layout.widthAnchor),
            composeColumn.leadingAnchor.constraint(equalTo: composeBackdrop.leadingAnchor),
            composeColumn.trailingAnchor.constraint(equalTo: composeBackdrop.trailingAnchor),
            composeColumn.topAnchor.constraint(equalTo: composeBackdrop.topAnchor),
            composeColumn.bottomAnchor.constraint(equalTo: composeBackdrop.bottomAnchor),
            composerWidth,
            footerWidth,
            statusWidth,
            statusHeight,
            footerHeight,
            actionHeight,
        ])
        composeBackdrop.setContentHuggingPriority(.required, for: .vertical)
        composeBackdrop.setContentCompressionResistancePriority(.required, for: .vertical)
        composer.layer?.borderColor = AgentLineRole.controlBoundary.color.cgColor(for: effectiveTokenTheme)
        if let slot {
            let chrome = AgentTileChromeCanvasView(body: root, transcript: transcript, transcriptSlot: slot)
            chrome.onRestingPress = { [weak self] event in self?.redeliverRestingPress(event) }
            chromeCanvas = chrome
            return chrome
        }
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
        transcriptCollectionFixture.setTurnPresence(currentPresence)
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
        // One owner: the tail is up exactly while the submission is live and
        // the agent is not waiting on the user (the request block says that).
        let presence = currentPresence
        let awaitingUser: Bool
        if case .needsAction = v2TurnSnapshot?.state { awaitingUser = true } else { awaitingUser = false }
        let statusIsActive = presence.isLive && !awaitingUser
        let showsWorkingTail = Self.showsWorkingTail(
            statusIsActive: statusIsActive, document: model.document,
            turnLiveness: turnLiveness)
        if let settled = settledTailStatusText {
            transcriptCollectionFixture.setSettledTailStatus(settled)
            return
        }
        transcriptCollectionFixture.setThinkingIndicatorVisible(showsWorkingTail)
    }

    /// The settled "Worked for Ns" the tail shows now, or nil while it is live.
    /// The settled row is pinned to the foot of the document; once a compaction
    /// boundary lands after that turn it would sit BELOW the boundary and read
    /// as the compaction's duration, so the boundary retires it — as the next
    /// turn starting already does.
    private var settledTailStatusText: String? {
        guard pendingOptimisticSubmissionID == nil else { return nil }
        let presence = currentPresence
        let awaitingUser: Bool
        if case .needsAction = v2TurnSnapshot?.state { awaitingUser = true } else { awaitingUser = false }
        guard !presence.isLive || awaitingUser else { return nil }
        guard model.document.entries.last?.blocks.last?.kind != .compaction else { return nil }
        return Self.settledTailText(for: presence)
    }

    /// The gyro's live words. With nothing live to say, a settled tail keeps its
    /// own words: the compact status re-renders whenever anything about the agent
    /// lands — a branch read that finishes off the main thread after the turn
    /// ended, a quota, a location — and each of those blanked "Worked for Ns".
    /// Live words (a compaction running after the turn) still take the tail.
    private func setLiveTailStatusText(_ text: String?) {
        let live = text ?? ""
        transcriptCollectionFixture?.setThinkingStatusText(live.isEmpty ? (settledTailStatusText ?? live) : live)
    }

    /// The tail's words for a settled submission, measured Return → settle,
    /// naming who ended it: the user's Stop is never confused with a crash or
    /// a provider-side interrupt.
    static func settledTailText(for presence: AgentTurnPresence) -> String? {
        guard let interval = presence.settledDuration else { return nil }
        let duration = settledDurationText(interval)
        switch presence.phase {
        case .settled(.completed): return "Worked for \(duration)"
        case .settled(.stoppedByUser): return "You stopped after \(duration)"
        case .settled(.interrupted): return "Interrupted after \(duration)"
        case .settled(.processLost): return "Ended after \(duration) — the agent process exited without finishing"
        case .idle, .starting, .thinking, .tool, .writing, .failed: return nil
        }
    }

    /// `.plans/45` S6 — the live tool verb, derived from whitelisted detail
    /// fields only (query/url/pattern/basename/description). A shell's
    /// `command` does ride the observation now (for its transcript row), and is
    /// deliberately not read here: the compact tail never prints a command.
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
            pageZoom: pageZoom,
            imageResources: managedImageResourceProvider,
            agentStatus: agentReferenceStatusSource,
            agentMessageSenders: agentMessageSenderSource,
            // TR-06 — read LIVE from the supervisor, exactly like
            // `updateV2ComposerPresentation` does, and never from the cached
            // `v2TurnSnapshot` alone: the cache is what latched a stale
            // "Unavailable" onto the composer in the P5.5 live finding, and a
            // stale read here would either hide a usable button or offer a dead
            // one. The cache remains the fallback for tiles with no live source
            // (fixtures, post-detach repaints).
            canRespondToRequests: liveTurnSnapshot?.capabilities.canRespondToRequests ?? false
        )
    }

    /// The supervisor's current snapshot when one is reachable, else the cached
    /// copy. One accessor, so every live-capability reader agrees.
    private var liveTurnSnapshot: AgentTileTurnSnapshot? {
        if let agentID = attachedAgentID, let live = agentSource?.turnSnapshot(for: agentID) {
            return live
        }
        return v2TurnSnapshot
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

    /// Read from the supervisor's records when a card is drawn, so a sender's
    /// colour is the one it has now and a deleted sender has no button.
    private var agentMessageSenderSource: AgentMessageSenderSource {
        guard let supervisor = agentSource else { return .unavailable }
        return AgentMessageSenderSource(current: { [weak supervisor] rawAgentID in
            guard let record = supervisor?.records[AgentID(rawValue: rawAgentID)] else { return nil }
            return .init(identityColorName: record.identityColor, hasTile: record.tileId != nil)
        })
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
    /// claim otherwise (see `AgentReplyOptionDetector`). A turn that is no longer
    /// idle withdraws the offer outright — the question it belongs to has already
    /// been answered by whatever the user just sent.
    ///
    /// TR-06: the withdrawal covers every non-idle state, not just `.working`.
    /// `.starting` and `.working` self-corrected (the optimistic user echo becomes
    /// the last entry, and the detector only reads assistant turns), but a QUEUED
    /// reply adds no entry at all — so the chips for a question the user has
    /// already answered stayed on screen, ready to overwrite the answer waiting
    /// to be sent. `.needsAction` is included for a different reason: a provider
    /// holding a real request is the one moment prose guesswork must not compete
    /// with the actual answer controls.
    private func refreshReplyOptions(from document: AgentDocument) {
        guard let composer = v2Composer else { return }
        let working: Bool
        switch v2TurnSnapshot?.state {
        case .working, .starting, .queued, .compacting, .needsAction:
            working = true
        case .ready, .failed, .restored, .none:
            working = false
        }
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
        case let .revealMessageSender(_, agentID):
            onRevealMessageSender?(AgentID(rawValue: agentID))
            return
        case let .contextFullRecovery(blockID, recoveryAction):
            guard isContextFullErrorBlock(blockID) else { return }
            if recoveryAction == .copyTranscript {
                let blocks = model.document.entries.flatMap(\.blocks)
                AgentTranscriptCopyController.writeToPasteboard(blocks: blocks)
            } else {
                onContextFullRecoveryAction?(blockID, recoveryAction)
            }
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
        // TR-06 — one press, one dispatch. The second press is refused here,
        // because the first left the block `.submitting` and this reads the
        // block. That is a LOCAL delivery state and never makes the request look
        // resolved; only a real runtime `requestResolved`/`userInputResolved`
        // does that.
        //
        // Marking happens after the seam returns rather than before, which is
        // safe only because the seam is synchronous on the main actor: nothing
        // can press again between the call and the mark.
        //
        // This is the ONLY duplicate guard. The supervisor validates that the
        // request is still pending, which a second press also satisfies, so it
        // would happily put a second answer on the wire. `--provider-request-
        // response-check` deletes this line to prove it.
        guard payload.responseState != .submitting else { return }
        // An unbound seam is a refusal, exactly like a bound seam returning
        // false: nothing was dispatched, so nothing may claim it was.
        guard onProviderResponse?(requestID, value) == true else {
            markProviderResponse(requestID: requestID, .failed)
            return
        }
        markProviderResponse(requestID: requestID, .submitting)
    }

    private func isContextFullErrorBlock(_ blockID: AgentNodeID) -> Bool {
        func matchingBlock(in blocks: [AgentBlock]) -> AgentBlock? {
            for block in blocks {
                if block.id == blockID { return block }
                if let nested = matchingBlock(in: block.children) { return nested }
            }
            return nil
        }
        guard let block = matchingBlock(in: model.document.entries.flatMap(\.blocks)),
              case let .error(payload) = block.payload else { return false }
        return payload.message == AgentContextFullRecovery.canonicalErrorMessage
    }

    /// TR-06 — the app's report that a dispatch it accepted did not reach the
    /// provider. Separate from the accept/refuse return value because the
    /// transport blocks on a provider round trip and cannot answer on the press's
    /// own turn (see `AgentSupervisor.respondToRequest`).
    ///
    /// The request stays OPEN. A delivery failure is not a decision, and the user
    /// may press again — which is why this clears `.submitting` rather than
    /// latching the block.
    func reportProviderResponseFailure(requestID: String, message: String?) {
        markProviderResponse(requestID: requestID, .failed)
        if let message, !message.isEmpty {
            showActionFailedNotice("Couldn't send that response — \(message)")
        } else {
            showActionFailedNotice("Couldn't send that response to the provider.")
        }
    }

    private func markProviderResponse(
        requestID: String, _ state: AgentRequestResponseState
    ) {
        guard model.markRequestResponseState(requestID: requestID, state) else { return }
        synchronizeV2Transcript()
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

    @objc private func toggleV2Dictation() {
        v2Composer?.toggleDictation()
    }

    private func dictationStateDidChange(_ state: DictationState) {
        defer { chromeDidChange() }
        v2DictationButton.apply(state)
        switch state {
        case .preparing, .listening:
            v2DictationPill.setMode(state == .listening ? .listening : .preparing(downloadingModel: false))
            placeDictationPill()
            v2DictationPill.setExpanded(true)
        case .finalizing:
            v2DictationPill.setMode(.finalizing)
        case .idle, .error:
            v2DictationPill.setExpanded(false)
        }
    }

    /// Pinned where the mic is — or would be, at widths where it hides — and
    /// grown over the provider controls to the row's leading edge.
    private func placeDictationPill() {
        guard let actionButton = v2ActionButton, let row = v2FooterRow else { return }
        let height = ComposerActionButton.controlHeight(zoom: pageZoom)
        let maxX = v2DictationButton.isHidden ? actionButton.frame.minX - row.spacing : v2DictationButton.frame.maxX
        v2DictationPill.place(.init(
            maxX: maxX, midY: actionButton.frame.midY, height: height,
            expandedWidth: maxX - providerFooter.frame.minX))
    }

    private func updateDictationAvailability() {
        defer { chromeDidChange() }
        let offered = ComposerDictationController.isOffered
        if !offered { v2Composer?.cancelDictation() }
        let shown = offered && dictationFitsFooter
        if v2DictationButton.isHidden == shown { v2DictationButton.isHidden = !shown }
    }

    /// Decided from the row's width and the other controls' fixed widths, never
    /// from the mic's own visibility, so hiding it cannot flip the decision.
    private func fitDictationButton(rowWidth: CGFloat) {
        guard let actionButton = v2ActionButton, let row = v2FooterRow, rowWidth > 0 else { return }
        let gap = row.spacing
        var fixed = actionButton.intrinsicContentSize.width + gap
            + v2DictationButton.intrinsicContentSize.width + gap
        if !v2SendChoice.isHidden { fixed += v2SendChoice.intrinsicContentSize.width + gap }
        let fits = rowWidth - fixed >= providerFooter.condensedFittingWidth
        guard fits != dictationFitsFooter else { return }
        dictationFitsFooter = fits
        updateDictationAvailability()
    }

    var qaDictationButtonForChecks: ComposerDictationButton { v2DictationButton }
    var qaDictationPillForChecks: ComposerDictationPillView { v2DictationPill }
    /// Probe seam (hazard 8): the pill as a live session shows it, grown
    /// through its own spring, so the census sees it paint.
    func qaShowLiveDictationPill() {
        layoutSubtreeIfNeeded()
        v2DictationPill.setMode(.listening)
        placeDictationPill()
        v2DictationPill.setExpanded(true)
        var steps = 0
        while v2DictationPill.qaIsAnimating, steps < 240 {
            v2DictationPill.advanceMotion(by: 1.0 / 60.0)
            steps += 1
        }
    }
    var qaProviderFooterAlpha: CGFloat { providerFooter.alphaValue }

    @objc private func performV2PrimaryAction() {
        guard let composer = v2Composer, let presentation = v2ActionButton?.presentation else { return }
        switch presentation.primaryAction {
        case .send: composer.composerRequestedSend(composer.textView)
        case .stop: composer.requestStop()
        case .unavailable: break
        }
    }

    private func applyWorkingSendChoices(_ choices: [ComposerSendChoiceView.Choice], to button: ComposerActionButton) {
        v2SendChoice.setChoices(choices)
        v2SendChoice.isHidden = choices.isEmpty
        button.isCompact = !choices.isEmpty && button.presentation.primaryAction == .stop
    }

    private func requestV2Stop() {
        v2Composer?.requestStop()
    }

    private func updateV2ComposerPresentation() {
        defer { chromeDidChange() }
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
            applyWorkingSendChoices([], to: button)
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
            hasDraft: !(v2Composer?.draft.agentReferences.isEmpty ?? true) || v2Composer?.draft.taskContext != nil || !(v2Composer?.draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        )
        // 2026-10-13 — a draft typed while the turn works is offered its ways
        // in beside the Stop; an empty busy composer offers Stop alone.
        let hasDraft = !(v2Composer?.draft.agentReferences.isEmpty ?? true) || v2Composer?.draft.taskContext != nil
            || !(v2Composer?.draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let workingNow = snapshot?.executionState == .working
        applyWorkingSendChoices(
            workingNow && hasDraft ? ComposerSendChoiceView.choices(for: capabilities) : [], to: button)
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
        defer { chromeDidChange() }
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
        defer { chromeDidChange() }
        if let shown = agentStatusOverride {
            // Another app's session decides it (`.plans/79` phase 2).
            agentHeader.apply(AgentTileStatePresenter.present(
                name: headerAgentName ?? tile.title, status: shown, branchContext: branchContext, startedAt: startedAt))
        } else if let snapshot = v2TurnSnapshot {
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
    private func settleLocationForDetach(at now: Date = AgentElapsedClock.now()) {
        guard let agentID = projectedAgentID,
              let snapshot = agentSource?.locationSnapshot(for: agentID, at: now) else { return }
        let settled = AgentLocationSnapshot(
            home: snapshot.home,
            whereDirectory: snapshot.workingLocation.directory,
            lastUsefulWhat: snapshot.lastUsefulWhat)
        refreshCompactStatus(at: now, location: settled)
    }

    static let chunkStatusInterval: TimeInterval = 0.25
    private var chunkStatusTimer: Timer?
    /// QA: status-row refreshes, however they were triggered.
    private(set) var qaLocationRefreshCount = 0

    private func scheduleChunkStatusRefresh() {
        guard chunkStatusTimer == nil else { return }
        let timer = Timer(timeInterval: Self.chunkStatusInterval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshLocationStatus() }
        }
        RunLoop.main.add(timer, forMode: .common)
        chunkStatusTimer = timer
    }

    private func refreshLocationStatus(at now: Date = AgentElapsedClock.now()) {
        defer { chromeDidChange() }
        qaLocationRefreshCount += 1
        chunkStatusTimer?.invalidate()
        chunkStatusTimer = nil
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
        listTranscript?.qaSemanticRowCount ?? 0
    }
    var qaTranscriptCollectionFixture: AgentTranscriptListView? { listTranscript }
    /// The compact row is exposed only as a deterministic geometry/AX witness;
    /// production updates it through `refreshCompactStatus` above.
    var qaCompactStatusRow: AgentCompactStatusRowView { compactStatusRow }
    var qaThinkingIndicatorVisible: Bool { transcriptCollectionFixture?.qaThinkingIndicatorVisible == true }
    // `.plans/45` S6 — deterministic seams for the optimistic-window witness.
    func qaBeginOptimisticSubmissionForChecks(_ text: String) {
        beginOptimisticSubmission(AgentPrompt(text))
    }

    func qaFinishOptimisticSubmissionForChecks(accepted: Bool) {
        finishOptimisticSubmission(accepted: accepted)
    }
    func qaRefreshThinkingIndicatorForChecks() {
        refreshTranscriptThinkingIndicator()
    }
    var qaTranscriptForChecks: AgentTranscriptListView? { listTranscript }
    /// Whichever renderer this tile installed.
    var qaTranscriptSurface: (any AgentTranscriptSurface)? { transcriptCollectionFixture }

    // MARK: - WS5 page-zoom QA seams
    //
    // These read back what the tile ACTUALLY laid out — frames, constants,
    // resolved font point sizes — never what a policy would have returned.

    /// The scale boundary itself. Everything under it scales; the title bar and
    /// the resize overlays are siblings of it and do not.
    var qaPageZoomContentRoot: NSView { contentBackdrop }
    var qaPageZoomComposeBackdrop: NSView { composeBackdrop }
    var qaPageZoomHeaderView: AgentTileHeaderView { agentHeader }
    var qaPageZoomComposerView: AgentComposerView? { v2Composer }
    var qaPageZoomActionButton: ComposerActionButton? { v2ActionButton }
    /// The constants Auto Layout is currently solving with.
    var qaPageZoomHeaderHeightConstant: CGFloat { agentHeaderHeight?.constant ?? -1 }
    var qaPageZoomStatusHeightConstant: CGFloat { compactStatusRowHeight?.constant ?? -1 }
    var qaPageZoomFooterHeightConstant: CGFloat { providerFooterHeight?.constant ?? -1 }
    var qaPageZoomActionHeightConstant: CGFloat { actionButtonHeight?.constant ?? -1 }
    var qaPageZoomComposerWidthInset: CGFloat { composerWidthInset?.constant ?? 1 }
    var qaPageZoomComposeColumnInsets: NSEdgeInsets {
        v2ComposeColumn?.edgeInsets ?? NSEdgeInsets()
    }
    var qaPageZoomComposeColumnSpacing: CGFloat { v2ComposeColumn?.spacing ?? -1 }
    /// Every menu item the zoom submenu offers, as (identifier, title, enabled).
    func qaPageZoomMenuEntries() -> [(id: String, title: String, enabled: Bool)] {
        guard let submenu = makeAdditionalTitleBarMenuItems()
            .first(where: { $0.title == "Zoom" })?.submenu else { return [] }
        return submenu.items.compactMap { item in
            guard let id = item.identifier?.rawValue else { return nil }
            return (id: id, title: item.title, enabled: item.isEnabled)
        }
    }
    /// The workspace-tools item as the menu offers it, or nil when it is absent.
    func qaWorkspaceToolsMenuEntry() -> (title: String, isOn: Bool)? {
        guard let item = makeAdditionalTitleBarMenuItems()
            .first(where: { $0.identifier?.rawValue == "agentTile.workspaceTools.toggle" })
        else { return nil }
        return (title: item.title, isOn: item.state == .on)
    }

    /// The identity Color submenu as offered: (identifier, title, checked), or
    /// empty when the tile offers none.
    func qaIdentityColorMenuEntries() -> [(id: String, title: String, isOn: Bool)] {
        guard let submenu = makeAdditionalTitleBarMenuItems()
            .first(where: { $0.identifier?.rawValue == "agentTile.identityColor" })?.submenu
        else { return [] }
        return submenu.items.compactMap { item in
            guard let id = item.identifier?.rawValue else { return nil }
            return (id: id, title: item.title, isOn: item.state == .on)
        }
    }

    /// Invoke one identity-colour item exactly as AppKit would, target and all.
    @discardableResult
    func qaInvokeIdentityColorMenuItem(_ identifier: String) -> Bool {
        guard let item = makeAdditionalTitleBarMenuItems()
            .first(where: { $0.identifier?.rawValue == "agentTile.identityColor" })?.submenu?
            .items.first(where: { $0.identifier?.rawValue == identifier }),
            let action = item.action, let target = item.target else { return false }
        _ = target.perform(action, with: item)
        return true
    }

    /// The title bar's identity wash as drawn: the bar's frame and the colour, or nil.
    var qaIdentityBar: (frame: NSRect, color: CGColor?)? {
        qaTitleBarTint.map { (qaTitleBarFrame, $0.cgColor) }
    }

    /// Invoke the workspace-tools item exactly as AppKit would, target and all.
    @discardableResult
    func qaInvokeWorkspaceToolsMenuItem() -> Bool {
        guard let item = makeAdditionalTitleBarMenuItems()
            .first(where: { $0.identifier?.rawValue == "agentTile.workspaceTools.toggle" }),
            let action = item.action, let target = item.target else { return false }
        _ = target.perform(action, with: item)
        return true
    }

    /// Invoke a zoom menu item exactly as AppKit would, target and all.
    @discardableResult
    func qaInvokePageZoomMenuItem(_ identifier: String) -> Bool {
        guard let submenu = makeAdditionalTitleBarMenuItems()
            .first(where: { $0.title == "Zoom" })?.submenu,
            let item = submenu.items.first(where: { $0.identifier?.rawValue == identifier }),
            let action = item.action, let target = item.target else { return false }
        _ = target.perform(action, with: item)
        return true
    }
    var qaDocumentForChecks: AgentDocument { model.document }
    /// The strip the newest turn shows ("Worked 3s", "You stopped after 2s").
    var qaNewestWorkStripText: String? { listTranscript?.qaNewestWorkStripModelForChecks?.text }
    /// Every session-boundary divider drawn now.
    var qaSessionBoundaryViews: [CompactionBoundaryView] {
        func walk(_ view: NSView) -> [CompactionBoundaryView] {
            let own = view.identifier?.rawValue == "agent.sessionBoundary" ? [view as? CompactionBoundaryView].compactMap { $0 } : []
            return own + view.subviews.flatMap(walk)
        }
        return transcriptCollectionFixture.map(walk) ?? []
    }
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
    /// TR-06 — the LOCAL delivery state of this machine's response, read from the
    /// reducer-owned document like every other request fact.
    func qaV2RequestResponseState(_ requestID: String) -> AgentRequestResponseState? {
        v2RequestPayload(requestID)?.responseState
    }
    /// TR-06 — whether the APP bound the response transport.
    ///
    /// The point of this seam is that a witness may assert the binding without
    /// creating it. `onProviderResponse` sat declared-and-unbound through every
    /// release of the request system, and the one check that exercised it bound
    /// the closure itself — so it proved the tile's dispatch logic and nothing
    /// at all about production.
    var qaHasProviderResponseBinding: Bool { onProviderResponse != nil }
    /// The reply-option chips the composer is currently offering, and a press
    /// through the real button. Read from the installed composer, never from a
    /// tile-side copy of the detector's answer.
    var qaReplyOptionChipTitles: [String] { v2Composer?.qaReplyOptionChipTitles ?? [] }
    var qaReplyOptionChipAccessibilityLabels: [String] {
        v2Composer?.qaReplyOptionChipAccessibilityLabels ?? []
    }
    var qaComposerDraftText: String { v2Composer?.qaDraftText ?? "" }
    /// T5b — the installed composer itself, so a check drives its real rail,
    /// key path and hint line rather than a copy.
    var qaComposerForChecks: AgentComposerView? { v2Composer }
    /// Drives the composer's real draft-apply path, so clearing a draft in a
    /// check runs the same observer production runs.
    func qaSetComposerDraftForChecks(_ text: String) {
        v2Composer?.apply(.init(text: text, selection: NSRange(location: text.utf16.count, length: 0), revision: 0))
    }
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
        // Mirrors `refreshV2TurnSnapshot`: a state change withdraws the chips.
        refreshReplyOptions(from: model.document)
    }

    /// TR-06 — whether the chips are reachable by keyboard, read from the real
    /// buttons. A control that only a mouse can reach is not an accessible
    /// control, and nothing asserted this before.
    var qaReplyOptionChipsAcceptFocus: Bool {
        v2Composer?.qaReplyOptionChipsAcceptFocus ?? false
    }

    var qaComposerIsOffered: Bool { !(v2Composer?.isHidden ?? true) }
    var qaProviderControlsAreOffered: Bool { !(v2FooterRow?.isHidden ?? true) }
    #if ARRAY_FILM
    /// Film build only: where a pointer types and clicks Send (`at: composer|send`).
    var filmComposerTextView: NSView? { v2Composer?.textView }
    var filmActionButton: NSView? { v2ActionButton }
    #endif
    var qaV2ActionTitle: String? { v2ActionButton?.presentation.title }
    /// 2026-10-13 — what the busy send choice offers, read from the real
    /// control: its primary title and its menu rows ("title  chord").
    struct QAWorkingSendChoice: Equatable {
        let primary: String
        let alternatives: [String]
    }
    var qaWorkingSendChoice: QAWorkingSendChoice? {
        guard !v2SendChoice.isHidden, v2SendChoice.superview != nil else { return nil }
        return QAWorkingSendChoice(primary: v2SendChoice.qaPrimaryTitle, alternatives: v2SendChoice.qaMenuRows)
    }
    var qaStopIsCompact: Bool { v2ActionButton?.isCompact == true }
    /// The vertical space the docked pending rail takes: 0 when nothing waits.
    var qaPendingRailSpace: CGFloat { v2PendingDock?.occupiedHeight ?? -1 }
    func qaChooseWorkingSend(_ modifier: AgentComposerSubmitModifier) -> Bool {
        guard qaWorkingSendChoice != nil else { return false }
        return v2SendChoice.qaChoose(modifier)
    }
    var qaV2ActionEnabled: Bool { v2ActionButton?.presentation.isEnabled == true }
    /// The choice titles the installed transcript actually presents for a
    /// request: the canvas's drawn choices, or the list's choice buttons.
    func qaV2RequestChoiceTitles(_ requestID: String) -> [String] {
        if let canvas = transcriptCollectionFixture as? AgentTranscriptCanvasView {
            canvas.flushPendingVisualUpdate()
            canvas.layoutSubtreeIfNeeded()
            return canvas.qaRequestChoiceTitles(requestID: requestID)
        }
        guard let list = listTranscript else { return [] }
        list.flushPendingVisualUpdate()
        list.layoutSubtreeIfNeeded()
        list.collectionView.layoutSubtreeIfNeeded()
        func titles(in view: NSView) -> [String] {
            if let button = view as? AgentRequestChoiceButton,
               (button.superview as? AgentRequestView)?.requestID == requestID {
                return [button.title]
            }
            return view.subviews.flatMap(titles)
        }
        return titles(in: list)
    }

    @discardableResult
    func qaClickV2RequestChoice(requestID: String, value: String) -> Bool {
        if let canvas = transcriptCollectionFixture as? AgentTranscriptCanvasView {
            canvas.flushPendingVisualUpdate()
            canvas.layoutSubtreeIfNeeded()
            if canvas.qaPressRequestChoice(requestID: requestID, value: value) { return true }
            // No drawn choice (no transport draws none): the same semantic
            // fallback the list takes below.
            guard v2RequestPayload(requestID)?.choices.contains(value) == true else { return false }
            performV2RenderAction(.submitResponse(requestID: requestID, value: value))
            return true
        }
        guard let transcriptCollectionFixture = listTranscript else { return false }
        transcriptCollectionFixture.layoutSubtreeIfNeeded()
        transcriptCollectionFixture.collectionView.layoutSubtreeIfNeeded()
        func find(in view: NSView) -> AgentRequestChoiceButton? {
            if let button = view as? AgentRequestChoiceButton,
               button.title == ApprovalDecision.displayTitle(forChoice: value),
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
            context: AgentRadialContextMeterPresenter.present(nil),
            // Preview seam with no supervisor: there is no account reading to
            // show, and inventing one for a screenshot is how a fabricated
            // number ends up in a design review.
            quotas: [],
            cost: nil,
            enabledElements: [.location, .activity, .contextMeter]))
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
              titleBarUsesCustomOverflowForQA,
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
        let menu = titleBarContextMenuForQA()
        for title in [AgentTileHeaderView.stopActionTitle, AgentTileHeaderView.detachActionTitle] {
            guard let item = menu.items.first(where: { $0.title == title }), let action = item.action,
                  NSApp.sendAction(action, to: item.target, from: item) else { return false }
        }
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
        let transcriptLayoutsBeforeTick = listTranscript?.transcriptLayout.preparePassCount ?? 0
        agentHeader.qaTick(now: Date(timeIntervalSince1970: 165))
        contentView?.layoutSubtreeIfNeeded()
        let timerActive = agentHeader.qaTimerIsActive
        let elapsedText = agentHeader.qaElapsed
        let transcriptLayoutDelta = (listTranscript?.transcriptLayout.preparePassCount ?? 0) - transcriptLayoutsBeforeTick
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
            + "custom=\(titleBarUsesCustomOverflowForQA) "
            + "elapsed=\(agentHeader.qaElapsed ?? "nil") timer=\(agentHeader.qaTimerIsActive) "
            + "detail=\(qaV2ContractDetail) border=\(layer?.borderWidth ?? -1) "
            + "titleActions=\(titleBarContextMenuForQA().items.map(\.title))"
    }
    var qaUsesV2HeaderShell: Bool { agentHeader.superview != nil }
    var qaAgentHeaderName: String { agentHeader.qaName }
    /// The Send button's own action, draft untouched — a board task dropped on
    /// the tile is sent with whatever the composer holds, as a click sends it.
    func qaPressSendForChecks() { performV2PrimaryAction() }
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

// MARK: - Resting chrome (ARRAY_TRANSCRIPT_RENDERER=canvas)
//
// A resting tile is six views, each of which draws: the tile, the chrome canvas,
// the transcript canvas, the title bar (drawing its own controls), the corner
// overlay and the awareness border. Everything else is real and current but
// detached; see `AgentTileChromeCanvasView`. With the switch off every hook here
// is a no-op: `chromeCanvas` is nil.
extension ManagedAgentTileNSView {
    var isChromeResting: Bool { chromeCanvas?.isResting == true }
    var qaChromeCanvas: AgentTileChromeCanvasView? { chromeCanvas }
    var qaProviderFooterForChecks: AgentComposerFooterView { providerFooter }
    var qaChromeBody: NSView { contentBackdrop }

    /// The hardware's pressed buttons. Injectable: a check must not read the
    /// user's own mouse, which they may be holding while it runs.
    static var chromePressedMouseButtons: () -> Int = { NSEvent.pressedMouseButtons }

    /// Presses wake the chrome; scroll, magnify and hover routing do not.
    private static let chromeWakingEvents: Set<NSEvent.EventType> = [
        .leftMouseDown, .rightMouseDown, .otherMouseDown,
    ]

    override func hitTest(_ point: NSPoint) -> NSView? {
        if let chromeCanvas, chromeCanvas.isResting, contentView === chromeCanvas,
           let type = NSApp.currentEvent?.type, Self.chromeWakingEvents.contains(type) {
            let local = superview.map { convert(point, from: $0) } ?? point
            let transcript = chromeCanvas.convert(chromeCanvas.transcriptFrame, to: self)
            if bounds.contains(local), !transcript.contains(local) { wakeChrome() }
        }
        return super.hitTest(point)
    }

    /// A press that reached the tile itself while its title-bar controls were
    /// drawn (the hit-test wake did not run): wake, then route it again.
    override func mouseDown(with event: NSEvent) {
        if titleBarControlsAreDrawn, redeliverRestingPress(event) { return }
        super.mouseDown(with: event)
    }

    /// The pointer entering wakes the chrome — unless the camera is moving, in
    /// which case the tile most likely slid under a still pointer; the canvas
    /// wakes the one tile under the pointer at the settle instead.
    override func mouseEntered(with event: NSEvent) {
        cancelChromeRest()
        if canvas?.isCameraInMotion != true, Self.qaPointerInside == nil { wakeChrome() }
        super.mouseEntered(with: event)
    }

    /// The canvas's settle edge found this tile under the pointer.
    func wakeChromeAfterCameraMotion() {
        guard isChromeResting else { return }
        qaChromeSettleWakeCount += 1
        wakeChrome()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        scheduleChromeRest()
    }

    override func accessibilityChildren() -> [Any]? {
        if isChromeResting, TileNSView.assistiveClientActive() { wakeChrome() }
        return super.accessibilityChildren()
    }

    /// Checks only: stands in for the real pointer, which a benchmark must not
    /// depend on (wherever the cursor happened to sit kept one tile live).
    static var qaPointerInside: ((ManagedAgentTileNSView) -> Bool)?

    /// Put the real controls back. Idempotent and cheap when already live.
    func wakeChrome() {
        cancelChromeRest()
        guard let chromeCanvas, chromeCanvas.isResting else { return }
        qaChromeWakeCount += 1
        chromeCanvas.wake()
        setTitleBarControlsDrawn(false)
    }

    /// Rest once nothing needs the real controls: no pointer over the tile, no
    /// focus or popover inside it, no press in progress, nothing animating.
    @discardableResult
    func restChromeIfIdle() -> Bool { restChrome(forCameraMotion: false, pressBelongsToPan: false) }

    /// A camera gesture's first step: the pointer over this tile is no reason to
    /// keep its ~230 real views live through every step — one hovered tile cost a
    /// zoom a third of its frames, and a zoom is always over the tile it centres
    /// on. Focus, an open choice list, a held press and dictation still keep it
    /// live. The settle wakes the tile under the pointer again.
    @discardableResult
    func restChromeForCameraMotion(pressBelongsToPan: Bool) -> Bool {
        restChrome(forCameraMotion: true, pressBelongsToPan: pressBelongsToPan)
    }

    private func restChrome(forCameraMotion: Bool, pressBelongsToPan: Bool) -> Bool {
        guard let chromeCanvas, !chromeCanvas.isResting, contentView === chromeCanvas,
              terminalFaceSession == nil, !chromeIsAnimating else { return false }
        // Otherwise never re-parent ~230 views while the camera moves; the rest waits.
        if !forCameraMotion, canvas?.isCameraInMotion == true {
            scheduleChromeRest()
            return false
        }
        if let window {
            if !pressBelongsToPan, Self.chromePressedMouseButtons() != 0 { return false }
            if forCameraMotion {
                // The pointer does not count.
            } else if let inside = Self.qaPointerInside {
                if inside(self) { return false }
            } else {
                let pointer = convert(window.mouseLocationOutsideOfEventStream, from: nil)
                if window.isVisible, bounds.contains(pointer) { return false }
            }
            if let responder = window.firstResponder as? NSView, responder !== self,
               responder.isDescendant(of: contentBackdrop) || (qaTitleBarView.map(responder.isDescendant(of:)) ?? false) {
                return false
            }
        }
        if Self.presentsChoices(contentBackdrop) { return false }
        if forCameraMotion { qaChromeMotionRestCount += 1 }
        chromeCanvas.rest()
        setTitleBarControlsDrawn(true) { [weak self] event in
            self?.redeliverRestingPress(event) ?? false
        }
        return true
    }

    func scheduleChromeRest() {
        guard chromeCanvas?.isResting == false else { return }
        chromeRestWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.chromeRestWork = nil
            self?.restChromeIfIdle()
        }
        chromeRestWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func cancelChromeRest() {
        chromeRestWork?.cancel()
        chromeRestWork = nil
    }

    /// A press that arrived at a drawn control without passing the hit-test wake
    /// (a direct `NSWindow.sendEvent`): wake, then deliver the same press again,
    /// now to the real view under it.
    @discardableResult
    fileprivate func redeliverRestingPress(_ event: NSEvent) -> Bool {
        wakeChrome()
        // Only once the real views are back; anything else would deliver the
        // press to the drawn chrome again.
        guard let window, !isChromeResting, !titleBarControlsAreDrawn else { return false }
        window.sendEvent(event)
        return true
    }

    /// The live gyro and the dictation pill move on their own clocks; drawing
    /// them would freeze them, so a tile showing one stays live.
    private var chromeIsAnimating: Bool {
        compactStatusRow.qaThinkingSlotVisible || !v2DictationPill.isHidden
    }

    /// Something the body shows moved. A resting body is redrawn; a live one
    /// redraws itself and may now be able to rest.
    func chromeDidChange() {
        guard let chromeCanvas else { return }
        if chromeIsAnimating { wakeChrome(); return }
        if chromeCanvas.isResting {
            chromeCanvas.invalidateRestingChrome()
        } else if chromeRestWork == nil {
            scheduleChromeRest()
        }
    }

    private static func presentsChoices(_ view: NSView) -> Bool {
        if let button = view as? ChoiceButton, button.presentedPopoverIsVisible { return true }
        return view.subviews.contains(where: presentsChoices)
    }
}

