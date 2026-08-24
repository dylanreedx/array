import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

@MainActor
private final class AgentTranscriptTailItem: NSCollectionViewItem {
    private weak var installedIndicator: DualPlaneGyroTiltedThinkingIndicatorView?
    private weak var installedStatusLabel: NSTextField?

    override func loadView() {
        view = NSView(frame: .zero)
    }

    /// The live status rides the gyro: the spinning element and the words that
    /// describe it are one object, at the end of the transcript where the next
    /// output will appear. The label is owned by the list (so its text can be
    /// re-driven without rebuilding the item) and merely hosted here.
    func install(indicator: DualPlaneGyroTiltedThinkingIndicatorView, statusLabel: NSTextField) {
        installedIndicator?.removeFromSuperview()
        installedStatusLabel?.removeFromSuperview()
        installedIndicator = indicator
        installedStatusLabel = statusLabel
        indicator.removeFromSuperview()
        statusLabel.removeFromSuperview()
        indicator.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(indicator)
        view.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            indicator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            indicator.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            indicator.widthAnchor.constraint(equalToConstant: DualPlaneGyroIndicatorModel.side),
            indicator.heightAnchor.constraint(equalToConstant: DualPlaneGyroIndicatorModel.side),
            statusLabel.leadingAnchor.constraint(equalTo: indicator.trailingAnchor, constant: CGFloat(Space.s)),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: indicator.centerYAnchor),
        ])
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        installedIndicator?.removeFromSuperview()
        installedIndicator = nil
        installedStatusLabel?.removeFromSuperview()
        installedStatusLabel = nil
    }
}

@MainActor
private final class AgentTranscriptCollectionItem: NSCollectionViewItem {
    private(set) var hostView: AgentBlockHostView?
    private(set) var reasoningDisclosureView: CompletedReasoningDisclosureView?

    override func loadView() {
        view = NSView(frame: .zero)
    }

    func installHost(registry: AgentBlockRendererRegistry, cache: AgentBlockMeasurementCache) -> AgentBlockHostView {
        reasoningDisclosureView?.removeFromSuperview()
        reasoningDisclosureView = nil
        if let hostView { return hostView }
        let host = AgentBlockHostView(registry: registry, measurementCache: cache)
        host.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.topAnchor.constraint(equalTo: view.topAnchor),
            host.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        hostView = host
        return host
    }

    func installCompletedReasoningDisclosure() -> CompletedReasoningDisclosureView {
        hostView?.resetForReuse()
        hostView?.removeFromSuperview()
        hostView = nil
        if let reasoningDisclosureView { return reasoningDisclosureView }
        let disclosure = CompletedReasoningDisclosureView(frame: .zero)
        disclosure.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(disclosure)
        NSLayoutConstraint.activate([
            disclosure.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            disclosure.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            disclosure.topAnchor.constraint(equalTo: view.topAnchor),
            disclosure.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        reasoningDisclosureView = disclosure
        return disclosure
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        hostView?.resetForReuse()
        reasoningDisclosureView?.apply(entry: nil, authoritativeDuration: nil, context: .init(
            actions: .disabled, tokens: .transcript, appearance: .dark
        ))
    }
}

/// The live semantic transcript (P5.5 acceptance): the virtualized collection
/// list every managed-agent tile renders. The legacy card-stack transcript and
/// its fixture flag were deleted at that gate.
@MainActor
final class AgentTranscriptListView: NSView, RichInlineTextSelectionContainer {
    enum UpdateError: Error, CustomStringConvertible {
        case versionMismatch(expected: UInt64, actual: UInt64)
        case documentPatchMismatch(document: UInt64, patch: UInt64)
        case duplicateTopLevelBlock(AgentNodeID)
        case missingQARow(AgentNodeID)
        case renderer(Error)

        var description: String {
            switch self {
            case let .versionMismatch(expected, actual):
                return "transcript patch starts at version \(actual), expected \(expected)"
            case let .documentPatchMismatch(document, patch):
                return "document version \(document) does not match patch version \(patch)"
            case let .duplicateTopLevelBlock(id):
                return "duplicate top-level transcript block ID \(id.rawValue)"
            case let .missingQARow(id):
                return "missing transcript QA row \(id.rawValue)"
            case let .renderer(error):
                return "transcript renderer failed: \(error)"
            }
        }
    }

    struct Row {
        enum Content: Equatable {
            case block(AgentBlock)
            case completedReasoning(AgentEntry)
        }

        let content: Content
        let role: AgentEntryRole
        /// `.plans/45` T3. Which entry this row belongs to.
        ///
        /// Entry identity previously lived only in `rowPositions`, which the
        /// layout cannot see. Without it here, two consecutive assistant entries
        /// are indistinguishable from one entry's two paragraphs — so a turn
        /// boundary cannot be found at the point where spacing is decided.
        let entryID: AgentNodeID

        var id: AgentNodeID {
            switch content {
            case let .block(block): return block.id
            case let .completedReasoning(entry): return entry.id
            }
        }

        var block: AgentBlock? {
            guard case let .block(block) = content else { return nil }
            return block
        }

        var entry: AgentEntry? {
            guard case let .completedReasoning(entry) = content else { return nil }
            return entry
        }

        var copyBlocks: [AgentBlock] {
            switch content {
            case let .block(block): return [block]
            case let .completedReasoning(entry): return entry.blocks
            }
        }
    }

    let scrollView = NSScrollView(frame: .zero)
    let collectionView = NSCollectionView(frame: .zero)
    let transcriptLayout = AgentTranscriptLayout()

    private let registry: AgentBlockRendererRegistry
    private let measurementCache: AgentBlockMeasurementCache
    /// Host-local, non-semantic tool detail composition. The actor store is
    /// intentionally owned outside the document; this cache contains only the
    /// already-sanitized records used for the current host view.
    private let toolDetailStore: AgentToolDetailStore?
    private let toolDetailProvider: ((AgentToolDetailKey) -> AgentToolDetailRecord?)?
    private var toolDetailsByID: [AgentToolDetailKey: AgentToolDetailRecord] = [:]
    private var toolDetailRefreshTask: Task<Void, Never>?
    private var toolDetailIDByBlockID: [AgentNodeID: AgentToolDetailKey] = [:]
    /// Immutable host-local bindings are supplied at the composition boundary;
    /// they are never inferred from the current turn while flattening history.
    private var toolDetailIdentityByEntryID: [AgentNodeID: AgentToolDetailKey] = [:]
    private var toolDetailEntryLifecycleByID: [AgentNodeID: AgentEntry] = [:]
    private var runtimeIdentities: Set<AgentToolDetailKey> = []
    private var activeRuntimeScope: AgentToolDetailScope?
    private let toolDetailClock: @Sendable () -> Date
    private let toolDetailTimeToLive: TimeInterval?
    /// The list owns the view-state binding because the existing tile context
    /// deliberately carries only semantic render actions. Entry IDs remain the
    /// disclosure key; this opaque owner token prevents state crossing lists.
    private let disclosureStateStore = DisclosureStateStore()
    private let disclosureOwnerID: AgentID
    private var toolDetailAgentID: AgentID?
    private var pendingRuntimeObservations: [AgentToolDetailKey: AgentRuntimeObservation] = [:]
    private let tailThinkingIndicator = DualPlaneGyroTiltedThinkingIndicatorView()
    /// The live phase text that rides the gyro (e.g. "Reading Agent.swift · 12s").
    /// Owned here so a tick can re-drive the words without rebuilding the item.
    private let tailStatusLabel = NSTextField(labelWithString: "")
    private let tailThinkingIndicatorID = AgentNodeID(rawValue: "__agent_transcript_tail_thinking_indicator__")!
    private var tailThinkingIndicatorIsVisible = false
    /// Duration is an optional host-attested presentation input. The current
    /// transcript model has no duration field, so the production default is nil
    /// rather than a locally inferred or fabricated clock.
    private let authoritativeReasoningDuration: (AgentEntry) -> TimeInterval?
    private var dataSource: NSCollectionViewDiffableDataSource<Int, AgentNodeID>!
    private var rows: [Row] = []
    private var rowsByID: [AgentNodeID: Row] = [:]
    /// `.plans/45` T3. Turn chrome, drawn as LAYERS rather than views.
    ///
    /// A separator view per turn and a timestamp label per entry would be two
    /// more AppKit views per content item on the one surface whose view count has
    /// already frozen the app (`performance.md` trap 1; 0.4.16 put 725 of ~750
    /// samples in this file's prose layout). One shape layer holds every rule and
    /// one text layer serves whichever turn the pointer is over.
    private let turnSeparatorLayer = CAShapeLayer()
    private let hoverTimeLayer = CATextLayer()
    private var turnStartRowsByEntry: [(row: Int, entryID: AgentNodeID, date: Date?)] = []
    private var entryDatesByID: [AgentNodeID: Date?] = [:]
    private var hoveredTurnEntryID: AgentNodeID?
    private var transcriptTrackingArea: NSTrackingArea?
    private var preparedTurnChromeSignature: Int?
    private var topLevelIDsByNodeID: [AgentNodeID: Set<AgentNodeID>] = [:]

    /// Where a presented row lives in the applied document, so a delta that names
    /// its changed nodes can fetch their new content in O(1) instead of walking
    /// the conversation.
    ///
    /// Every position is VERIFIED against the incoming document before it is
    /// trusted — a position that no longer holds the same id makes the delta fall
    /// back to a full rebuild rather than silently presenting a neighbouring
    /// block's content under this row's identity.
    private struct RowPosition: Equatable {
        let entryID: AgentNodeID
        let entryIndex: Int
        /// `nil` for a `completedReasoning` row, whose content IS the entry.
        let blockIndex: Int?
        /// Index into `rows`. Carried here rather than rebuilt per delta: deriving
        /// it by walking `rows` would reintroduce the O(history) pass this index
        /// exists to remove, which a profile caught it doing.
        let slot: Int
    }

    private var rowPositions: [AgentNodeID: RowPosition] = [:]
    private var entryIndexByID: [AgentNodeID: Int] = [:]
    /// The document the caches above describe. Held so a delta can compare an
    /// entry's old role/lifecycle against the incoming one without a walk.
    private var appliedDocument: AgentDocument?

    private typealias RowIndex = (
        rows: [Row],
        topLevelIDsByNodeID: [AgentNodeID: Set<AgentNodeID>],
        toolDetailIDByBlockID: [AgentNodeID: AgentToolDetailKey],
        positions: [AgentNodeID: RowPosition],
        entryIndexByID: [AgentNodeID: Int]
    )

    private var appliedVersion: UInt64?
    private var latestEnqueuedVersion: UInt64?
    private var renderingError: Error?
    private var lastInvalidatedTopLevelCount = 0
    private var renderContext: AgentRenderContext
    private let updateScheduler = AgentTranscriptUpdateScheduler()
    let scrollController = AgentTranscriptScrollController()
    private lazy var jumpToLatestButton: NSButton = {
        let button = NSButton(title: "Jump to latest", target: self, action: #selector(handleJumpToLatest))
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isBordered = false
        button.bezelStyle = .recessed
        button.font = .systemFont(ofSize: 12, weight: .medium)
        button.setAccessibilityRole(.button)
        button.setAccessibilityLabel("Jump to latest transcript content")
        button.setAccessibilityChildren([])
        button.isHidden = true
        return button
    }()

    /// Weakly tracks every host created by the collection, including hosts AppKit
    /// has moved into its reuse pool. Counting only `visibleItems()` would miss a
    /// regression that permanently retained an offscreen host for every row.
    private final class WeakHost {
        weak var value: AgentBlockHostView?
        init(_ value: AgentBlockHostView) { self.value = value }
    }
    private var trackedHosts: [ObjectIdentifier: WeakHost] = [:]
    private var qaPermanentlyRetainedHosts: [AgentBlockHostView] = []
    private var qaReuseWitnessItem: AgentTranscriptCollectionItem?
    var qaRetainHostForEverySemanticRow = false

    init(
        registry: AgentBlockRendererRegistry = .production,
        renderContext: AgentRenderContext = AgentRenderContext(
            actions: .disabled, tokens: .transcript, appearance: .dark
        ),
        authoritativeReasoningDuration: @escaping (AgentEntry) -> TimeInterval? = { _ in nil },
        toolDetailStore: AgentToolDetailStore? = nil,
        toolDetailProvider: ((AgentToolDetailKey) -> AgentToolDetailRecord?)? = nil,
        toolDetailClock: (@Sendable () -> Date)? = nil,
        toolDetailTimeToLive: TimeInterval? = nil
    ) {
        self.registry = registry
        disclosureOwnerID = AgentID(rawValue: UUID())
        self.renderContext = renderContext
        self.authoritativeReasoningDuration = authoritativeReasoningDuration
        self.toolDetailStore = toolDetailStore
        self.toolDetailProvider = toolDetailProvider
        if let toolDetailClock {
            self.toolDetailClock = toolDetailClock
        } else if let toolDetailStore {
            self.toolDetailClock = toolDetailStore.currentDate
        } else {
            self.toolDetailClock = { Date() }
        }
        if let toolDetailTimeToLive {
            self.toolDetailTimeToLive = max(0, toolDetailTimeToLive)
        } else if let toolDetailStore {
            self.toolDetailTimeToLive = toolDetailStore.timeToLive
        } else {
            self.toolDetailTimeToLive = nil
        }
        measurementCache = AgentBlockMeasurementCache()
        super.init(frame: .zero)
        self.renderContext = contextWithDisclosureState(renderContext)
        configureCollectionView()
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Agent transcript")
        collectionView.setAccessibilityRole(.list)
        collectionView.setAccessibilityLabel("Transcript entries")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        toolDetailRefreshTask?.cancel()
    }

    private func configureCollectionView() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        // Without this, NSCollectionView paints its DEFAULT background —
        // `windowBackgroundColor`, which macOS tints toward the desktop wallpaper
        // — over the tile's `tileBody` backdrop. Offscreen gate renders resolve
        // that default to a plain dark gray (and the baselines were blessed with
        // it), so only a live desktop shows the wrong color (P5.5 live finding,
        // `plan-P5.5-review-corrections.md` defect 6).
        collectionView.backgroundColors = [.clear]
        scrollView.hasVerticalScroller = true
        collectionView.collectionViewLayout = transcriptLayout
        configureTurnChrome()
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.register(
            AgentTranscriptCollectionItem.self,
            forItemWithIdentifier: NSUserInterfaceItemIdentifier("AgentTranscriptCollectionItem")
        )
        collectionView.register(
            AgentTranscriptTailItem.self,
            forItemWithIdentifier: NSUserInterfaceItemIdentifier("AgentTranscriptTailItem")
        )
        scrollView.documentView = collectionView
        tailThinkingIndicator.isHidden = true
        tailThinkingIndicator.identifier = NSUserInterfaceItemIdentifier("agentTranscript.tailThinkingIndicator")
        tailStatusLabel.isHidden = true
        tailStatusLabel.identifier = NSUserInterfaceItemIdentifier("agentTranscript.tailStatusLabel")
        tailStatusLabel.lineBreakMode = .byTruncatingTail
        tailStatusLabel.setAccessibilityElement(false)
        applyTailStatusTokens()
        addSubview(scrollView)
        addSubview(jumpToLatestButton)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            jumpToLatestButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            jumpToLatestButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])

        transcriptLayout.itemCount = { [weak self] in
            guard let self else { return 0 }
            return rows.count + (tailThinkingIndicatorIsVisible ? 1 : 0)
        }
        // `.plans/45` T3. Three tiers of separation, decided where the neighbour
        // is known. Inside one prose block AssistantProseView already uses 8pt
        // between its sub-rows, and 12pt separates collection rows; the tier that
        // did not exist was turn -> turn, so a new user prompt carried exactly as
        // much weight as the next paragraph.
        transcriptLayout.spacingBefore = { [weak self] index in
            guard let self else { return nil }
            return Self.startsTurn(rows, at: index) ? AgentTranscriptLayout.interTurnSpacing : nil
        }
        transcriptLayout.boundarySignature = { [weak self] in
            guard let self else { return 0 }
            // Feeds the prepare() fast path. Without it, a row whose ENTRY changed
            // without the row COUNT changing returns stale geometry, because the
            // guard only compares width bucket and count.
            var hasher = Hasher()
            for row in rows { hasher.combine(row.entryID) }
            return hasher.finalize()
        }
        transcriptLayout.measuredHeight = { [weak self] index, width in
            guard let self else { return 1 }
            if index == rows.count, tailThinkingIndicatorIsVisible {
                return DualPlaneGyroIndicatorModel.side
            }
            guard rows.indices.contains(index) else { return 1 }
            let row = rows[index]
            do {
                switch row.content {
                case let .block(block):
                    let presented = presentedToolBlock(block)
                    return try measurementCache.height(
                        for: presented,
                        width: width,
                        context: renderContext,
                        entryRole: row.role,
                        renderer: registry.renderer(for: presented.kind, entryRole: row.role)
                    )
                case let .completedReasoning(entry):
                    return CompletedReasoningDisclosureView.measuredHeight(
                        for: entry,
                        authoritativeDuration: authoritativeReasoningDuration(entry),
                        width: width,
                        context: renderContext,
                        registry: registry
                    )
                }
            } catch {
                renderingError = error
                return 24
            }
        }

        dataSource = NSCollectionViewDiffableDataSource<Int, AgentNodeID>(collectionView: collectionView) {
            [weak self] collectionView, indexPath, id in
            guard let self else { return nil }
            if id == tailThinkingIndicatorID {
                let identifier = NSUserInterfaceItemIdentifier("AgentTranscriptTailItem")
                guard let item = collectionView.makeItem(withIdentifier: identifier, for: indexPath)
                    as? AgentTranscriptTailItem else { return nil }
                item.install(indicator: tailThinkingIndicator, statusLabel: tailStatusLabel)
                return item
            }
            guard let row = rowsByID[id] else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("AgentTranscriptCollectionItem")
            guard let item = collectionView.makeItem(withIdentifier: identifier, for: indexPath)
                as? AgentTranscriptCollectionItem else { return nil }
            do {
                switch row.content {
                case let .block(block):
                    let host = item.installHost(registry: registry, cache: measurementCache)
                    track(host)
                    try host.apply(block: presentedToolBlock(block), entryRole: row.role, context: renderContext)
                case let .completedReasoning(entry):
                    let disclosure = item.installCompletedReasoningDisclosure()
                    disclosure.apply(
                        entry: entry,
                        authoritativeDuration: authoritativeReasoningDuration(entry),
                        context: renderContext,
                        registry: registry
                    )
                }
            } catch {
                renderingError = error
            }
            return item
        }
    }

    /// Queues one valid reducer result. Every document/patch pair and every
    /// producer version edge is validated before coalescing; only visual work is
    /// skipped. The latest semantic snapshot is diffed against the last painted
    /// rows at flush time, without fabricating a multi-version document patch.
    func enqueue(
        document: AgentDocument,
        patch: AgentDocumentPatch,
        final: Bool = false
    ) throws {
        guard document.version == patch.toVersion else {
            throw UpdateError.documentPatchMismatch(document: document.version, patch: patch.toVersion)
        }
        let expected = latestEnqueuedVersion ?? appliedVersion ?? patch.fromVersion
        guard patch.fromVersion == expected else {
            throw UpdateError.versionMismatch(expected: expected, actual: patch.fromVersion)
        }
        latestEnqueuedVersion = patch.toVersion
        updateScheduler.schedule({ [weak self] in
            guard let self else { return }
            do { try applyCoalesced(document: document) }
            catch { renderingError = error }
        }, final: final)
    }

    /// Presents any enqueued-but-unpresented snapshot immediately. Callers that
    /// need the rendered rows to match the semantic document right now — an
    /// interaction boundary, a probe, a teardown — use this instead of dropping
    /// back to the ungated `apply` path.
    func flushPendingVisualUpdate() { updateScheduler.flush() }

    var qaVisualApplyCount: Int { updateScheduler.visualApplyCount }
    var qaLastInvalidatedTopLevelCount: Int { lastInvalidatedTopLevelCount }
    var qaRenderingErrorDescription: String? { renderingError.map(String.init(describing:)) }

    /// QA: how much work the row index cost. `qaFlattenNodeVisits` counts every
    /// block node walked including nested children, `qaFlattenedRowCount` the rows
    /// emitted, and `qaFullFlattenCount` the number of whole-document rebuilds.
    /// The streaming contract is that a one-row delta scales with the change and
    /// the visible rows, never with total history, so all three must stay flat as
    /// the transcript grows. Drives `--perf-budget-transcript-delta-check`.
    private(set) var qaFlattenNodeVisits = 0
    private(set) var qaFlattenedRowCount = 0
    private(set) var qaFullFlattenCount = 0

    func qaResetFlattenStats() {
        qaFlattenNodeVisits = 0
        qaFlattenedRowCount = 0
        qaFullFlattenCount = 0
    }

    /// QA: is the live index indistinguishable from a FROM-SCRATCH walk of the
    /// same document? Returns a description of the first difference, or nil.
    ///
    /// This is the oracle that lets the incremental path be trusted at all. Every
    /// count budget in `transcript.delta` would still pass if the fast path
    /// produced the WRONG rows — cheap and wrong is the failure mode a cost
    /// witness cannot see — so correctness is asserted against the full walk,
    /// which stays the reference implementation.
    ///
    /// The perf counters are saved and restored: the reference walk is the
    /// oracle's own work, not the production path's, and must not be reported as
    /// though a delta had paid for it.
    func qaIndexEquivalenceMismatch(for document: AgentDocument) -> String? {
        let savedVisits = qaFlattenNodeVisits
        let savedRows = qaFlattenedRowCount
        let savedFlattens = qaFullFlattenCount
        defer {
            qaFlattenNodeVisits = savedVisits
            qaFlattenedRowCount = savedRows
            qaFullFlattenCount = savedFlattens
        }
        let reference: RowIndex
        do { reference = try flatten(document) } catch { return "reference walk threw: \(error)" }

        guard reference.rows.count == rows.count else {
            return "row count \(rows.count) != reference \(reference.rows.count)"
        }
        for (index, expected) in reference.rows.enumerated() {
            let actual = rows[index]
            guard actual.id == expected.id else {
                return "row \(index) id \(actual.id.rawValue) != reference \(expected.id.rawValue)"
            }
            guard actual.role == expected.role else {
                return "row \(index) (\(actual.id.rawValue)) role \(actual.role) != reference \(expected.role)"
            }
            guard actual.content == expected.content else {
                return "row \(index) (\(actual.id.rawValue)) content differs from reference"
            }
        }
        guard rowsByID.count == rows.count else {
            return "rowsByID holds \(rowsByID.count) for \(rows.count) rows"
        }
        guard topLevelIDsByNodeID == reference.topLevelIDsByNodeID else {
            return "topLevelIDsByNodeID differs from reference"
        }
        guard toolDetailIDByBlockID == reference.toolDetailIDByBlockID else {
            return "toolDetailIDByBlockID differs from reference"
        }
        guard rowPositions == reference.positions else {
            return "row positions differ from reference"
        }
        guard entryIndexByID == reference.entryIndexByID else {
            return "entry index differs from reference"
        }
        return nil
    }

    override func accessibilityChildren() -> [Any]? {
        // Expose the actual virtualized semantic hosts in collection/document
        // order instead of trusting AppKit's reuse-pool traversal order. Each
        // host then forwards its heading/link/code/disclosure/action children.
        let orderedChildren: [(Int, Any)] = collectionView.visibleItems().compactMap { item in
            guard let item = item as? AgentTranscriptCollectionItem,
                  let indexPath = collectionView.indexPath(for: item) else { return nil }
            if let host = item.hostView { return (indexPath.item, host as Any) }
            if let disclosure = item.reasoningDisclosureView {
                return (indexPath.item, disclosure as Any)
            }
            return nil
        }
        var children: [Any] = orderedChildren.sorted { $0.0 < $1.0 }.map { $0.1 }
        if tailThinkingIndicatorIsVisible,
           let item = collectionView.item(at: IndexPath(item: rows.count, section: 0)) as? AgentTranscriptTailItem {
            children.append(item)
        }
        if !jumpToLatestButton.isHidden { children.append(jumpToLatestButton) }
        return children
    }

    override var acceptsFirstResponder: Bool { true }

    @objc func copy(_ sender: Any?) {
        // The standard Edit > Copy action reaches this responder when the
        // collection owns block selection. Text renderers still handle native
        // partial text selections in their own NSTextView responder.
        copySelectedBlocks()
    }

    private func hasActiveTextSelection() -> Bool {
        func containsSelection(in view: NSView) -> Bool {
            if let textView = view as? NSTextView, textView.selectedRange().length > 0 {
                return true
            }
            return view.subviews.contains(where: containsSelection)
        }
        return containsSelection(in: collectionView)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            updateScheduler.flush()
            tailThinkingIndicator.stopAnimating()
        } else if tailThinkingIndicatorIsVisible {
            tailThinkingIndicator.startAnimating()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    func jumpToLatest() {
        scrollController.jumpToLatest(in: scrollView)
        jumpToLatestButton.isHidden = true
    }

    @objc private func handleJumpToLatest() { jumpToLatest() }

    private func transcriptID(at y: CGFloat) -> AgentNodeID? {
        // A viewport may begin in the inter-row gap. Anchor to the next visible
        // row rather than falling back to row zero; otherwise insertion above the
        // reader's actual content restores against the wrong semantic ID.
        var lastID: AgentNodeID?
        for (index, row) in rows.enumerated() {
            guard let frame = collectionView.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame else { continue }
            if frame.maxY >= y { return row.id }
            lastID = row.id
        }
        return lastID
    }

    private func transcriptY(for id: AgentNodeID) -> CGFloat? {
        if id == tailThinkingIndicatorID, tailThinkingIndicatorIsVisible {
            return collectionView.layoutAttributesForItem(
                at: IndexPath(item: rows.count, section: 0)
            )?.frame.minY
        }
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return nil }
        return collectionView.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame.minY
    }

    func copySelectedBlocks(
        asMarkdown: Bool = false,
        pasteboard: NSPasteboard = .general
    ) {
        let selectedRows = collectionView.selectionIndexPaths
            .sorted { $0.item < $1.item }
            .compactMap { rows.indices.contains($0.item) ? rows[$0.item] : nil }
        let selected = selectedRows.flatMap(\.copyBlocks)
        guard !selected.isEmpty else { return }
        if asMarkdown {
            let value = AgentTranscriptCopyController.markdown(for: selected)
            pasteboard.clearContents()
            pasteboard.setString(value, forType: .string)
            pasteboard.setString(value, forType: NSPasteboard.PasteboardType("net.daringfireball.markdown"))
        } else {
            let responseOnly = selectedRows.allSatisfy { $0.role == .assistant || $0.role == .reasoning }
            let stringStyle: AgentTranscriptCopyController.StringPasteboardStyle = responseOnly ? .markdown : .plainText
            AgentTranscriptCopyController.writeToPasteboard(
                blocks: selected,
                pasteboard: pasteboard,
                stringPasteboardStyle: stringStyle
            )
        }
    }

    /// Applies one reducer result. Diffable snapshots preserve item identity for
    /// unchanged IDs; reconfiguration is limited to rows touched by the patch.
    /// There is intentionally no reloadData path after (or before) initial load.
    private func applyCoalesced(document: AgentDocument) throws {
        prepareToolDetailLifecycle(for: document)
        captureTurnTimes(from: document)
        // No patch here: this path derives its own changed set by comparing against
        // the cached rows, so the full walk is the only correct option.
        let flattened = try flatten(document)
        let oldIndexes = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($0.element.id, $0.offset) })
        let changedNodeIDs = Set(flattened.rows.compactMap { row -> AgentNodeID? in
            guard let old = rowsByID[row.id] else { return nil }
            return old.content != row.content || old.role != row.role ? row.id : nil
        })
        let moved = flattened.rows.enumerated().compactMap { index, row -> AgentNodeID? in
            guard let oldIndex = oldIndexes[row.id], oldIndex != index else { return nil }
            return row.id
        }
        try applyWithScroll(document: document, flattened: flattened, changedNodeIDs: changedNodeIDs.union(moved))
    }

    func apply(document: AgentDocument, patch: AgentDocumentPatch) throws {
        guard document.version == patch.toVersion else {
            throw UpdateError.documentPatchMismatch(document: document.version, patch: patch.toVersion)
        }
        if let appliedVersion, patch.fromVersion != appliedVersion {
            throw UpdateError.versionMismatch(expected: appliedVersion, actual: patch.fromVersion)
        }
        prepareToolDetailLifecycle(for: document)
        captureTurnTimes(from: document)
        // The patch already names the nodes that changed, so a local delta rebuilds
        // only those rows. The full walk is the FALLBACK, not the default: it runs
        // whenever `incrementallyIndexed` declines, which it does for anything
        // structural or anything it cannot verify against the incoming document.
        let flattened = try incrementallyIndexed(document: document, patch: patch) ?? flatten(document)
        try applyWithScroll(
            document: document,
            flattened: flattened,
            changedNodeIDs: Set(patch.updated + patch.moved)
        )
        latestEnqueuedVersion = document.version
    }

    private func applyWithScroll(
        document: AgentDocument,
        flattened: RowIndex,
        changedNodeIDs: Set<AgentNodeID>
    ) throws {
        try scrollController.apply(
            in: scrollView,
            idAtY: { [weak self] y in self?.transcriptID(at: y) },
            yForID: { [weak self] id in self?.transcriptY(for: id) },
            isSelecting: { [weak self] in self?.hasActiveTextSelection() ?? false },
            update: { [weak self] in
                guard let self else { return }
                try applyUnscrolled(
                    document: document,
                    flattened: flattened,
                    changedNodeIDs: changedNodeIDs
                )
            }
        )
        jumpToLatestButton.isHidden = !scrollController.showsJumpToLatest
    }

    private func applyUnscrolled(
        document: AgentDocument,
        flattened: RowIndex,
        changedNodeIDs: Set<AgentNodeID>
    ) throws {
        let oldIDs = rows.map(\.id)
        let oldRowsByID = rowsByID
        let oldReasoningEntries = Dictionary(
            uniqueKeysWithValues: rows.compactMap { row in
                row.entry.map { ($0.id, $0) }
            }
        )
        let newReasoningIDs = Set(flattened.rows.compactMap(\.entry).map(\.id))
        let removedReasoningIDs = Set(oldReasoningEntries.keys).subtracting(newReasoningIDs)
        if flattened.rows.isEmpty, !rows.isEmpty {
            // resetProjection presents an empty document before replaying the
            // next session. Clear the complete owner scope as well as the
            // individual removals so a reused entry ID cannot inherit the old
            // session's preference.
            disclosureStateStore.removeAll(for: disclosureOwnerID)
        } else {
            for id in removedReasoningIDs {
                guard let entry = oldReasoningEntries[id] else { continue }
                var descendantIDs: Set<AgentNodeID> = []
                func collect(_ block: AgentBlock) {
                    descendantIDs.insert(block.id)
                    block.children.forEach(collect)
                }
                entry.blocks.forEach(collect)
                disclosureStateStore.removeSubtree(
                    for: disclosureOwnerID,
                    rootID: id,
                    descendantIDs: descendantIDs
                )
            }
        }
        rows = flattened.rows
        rowsByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        topLevelIDsByNodeID = flattened.topLevelIDsByNodeID
        toolDetailIDByBlockID = flattened.toolDetailIDByBlockID
        // One commit point for the caches AND the document they describe, so a
        // position can never outlive the document it indexes.
        rowPositions = flattened.positions
        entryIndexByID = flattened.entryIndexByID
        appliedDocument = document
        renderingError = nil
        scheduleToolDetailRefresh()

        // Fault injection used only by the deterministic negative witness. It
        // recreates the forbidden permanent-stack architecture directly: one
        // retained host for every semantic row, including all offscreen rows.
        if qaRetainHostForEverySemanticRow, qaPermanentlyRetainedHosts.isEmpty {
            qaPermanentlyRetainedHosts = rows.map { _ in
                let host = AgentBlockHostView(registry: registry, measurementCache: measurementCache)
                track(host)
                return host
            }
        }

        let newIDs = rows.map(\.id)
        var snapshot = NSDiffableDataSourceSnapshot<Int, AgentNodeID>()
        snapshot.appendSections([0])
        snapshot.appendItems(newIDs, toSection: 0)
        if tailThinkingIndicatorIsVisible { snapshot.appendItems([tailThinkingIndicatorID], toSection: 0) }

        var changedTopLevelIDs = Set(changedNodeIDs.flatMap { topLevelIDsByNodeID[$0] ?? [] })
        // Entry revisions also advance when one child changes. Do not fan that
        // bookkeeping update out to every sibling; only a role change affects all
        // renderer families in the entry.
        changedTopLevelIDs.formUnion(rows.compactMap { row in
            guard let old = oldRowsByID[row.id], old.role != row.role else { return nil }
            return row.id
        })
        let survivingChanged = changedTopLevelIDs.intersection(newIDs)
        lastInvalidatedTopLevelCount = survivingChanged.count
        var changedHeight = false
        if !survivingChanged.isEmpty {
            let width = max(
                0, collectionView.bounds.width
                    - transcriptLayout.contentInsets.left - transcriptLayout.contentInsets.right
            )
            for id in survivingChanged {
                let oldHeight = try oldRowsByID[id].map { try measuredHeight(for: $0, width: width) }
                measurementCache.invalidate(id: id)
                let newHeight = try rowsByID[id].map { try measuredHeight(for: $0, width: width) }
                if oldHeight == nil || newHeight == nil || abs(oldHeight! - newHeight!) > 0.5 {
                    changedHeight = true
                }
            }
        }

        if oldIDs != newIDs || appliedVersion == nil {
            dataSource.apply(snapshot, animatingDifferences: false)
        }
        // AppKit's snapshot reloadItems replaces NSCollectionViewItem instances.
        // For a content-only patch the snapshot is unchanged and is not re-applied;
        // visible stable-ID hosts update directly, while offscreen rows consume the
        // current row value when reuse materializes them later.
        try updateVisibleHosts(ids: survivingChanged)
        if oldIDs != newIDs {
            transcriptLayout.invalidateForStructureChange()
        } else if changedHeight {
            transcriptLayout.invalidate(changedIDs: survivingChanged)
        }
        appliedVersion = document.version
        layoutSubtreeIfNeeded()
        if let renderingError { throw UpdateError.renderer(renderingError) }
    }

    func updateRenderContext(_ context: AgentRenderContext) throws {
        renderContext = contextWithDisclosureState(context)
        measurementCache.removeAll()
        transcriptLayout.invalidateForStructureChange()
        try updateVisibleHosts(ids: Set(rowsByID.keys))
    }

    /// Binds host-local tool detail to the managed agent identity. This is
    /// deliberately separate from semantic entries so the agent ID never enters
    /// Codable transcript state.
    func bindToolDetailAgent(_ agentID: AgentID?) {
        toolDetailAgentID = agentID
        activeRuntimeScope = nil
        runtimeIdentities.removeAll()
        pendingRuntimeObservations.removeAll()
    }

    /// The selected production thinking indicator is transcript-owned, not part
    /// of the compact status row. It is a tail decoration so the status/composer
    /// region retains its measured height and accessibility children.
    func setThinkingIndicatorVisible(_ visible: Bool) {
        guard tailThinkingIndicatorIsVisible != visible else { return }
        tailThinkingIndicatorIsVisible = visible
        tailThinkingIndicator.isHidden = !visible
        tailStatusLabel.isHidden = !visible
        if visible {
            tailThinkingIndicator.startAnimating()
        } else {
            tailThinkingIndicator.stopAnimating()
            tailStatusLabel.stringValue = ""
        }
        applyTailVisibilityWithScrollPreservation()
    }

    /// Re-drives the words beside the gyro without touching the snapshot: the
    /// elapsed tick calls this once a second, and rebuilding the collection item
    /// at that rate would fight scrolling and text selection.
    func setThinkingStatusText(_ text: String?) {
        let resolved = text ?? ""
        guard tailStatusLabel.stringValue != resolved else { return }
        tailStatusLabel.stringValue = resolved
        tailStatusLabel.toolTip = resolved.isEmpty ? nil : resolved
    }

    /// Text colour only — the label paints no layer, so this view stays off the
    /// TokenThemed census while still following the appearance.
    func applyTailStatusTokens() {
        tailStatusLabel.font = .token(.caption)
        tailStatusLabel.textColor = TextToken.textSecondary.color.nsColor(for: effectiveTokenTheme)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTailStatusTokens()
    }

    // QA seams for the tail status.
    var qaTailStatusText: String { tailStatusLabel.stringValue }
    var qaTailStatusIsVisible: Bool { !tailStatusLabel.isHidden }

    private func applyTailVisibilityWithScrollPreservation() {
        guard dataSource != nil else { return }
        scrollController.apply(
            in: scrollView,
            idAtY: { [weak self] y in self?.transcriptID(at: y) },
            yForID: { [weak self] id in self?.transcriptY(for: id) },
            isSelecting: { [weak self] in self?.hasActiveTextSelection() ?? false },
            update: { [weak self] in
                guard let self else { return }
                var snapshot = NSDiffableDataSourceSnapshot<Int, AgentNodeID>()
                snapshot.appendSections([0])
                snapshot.appendItems(rows.map(\.id), toSection: 0)
                if tailThinkingIndicatorIsVisible {
                    snapshot.appendItems([tailThinkingIndicatorID], toSection: 0)
                }
                dataSource.apply(snapshot, animatingDifferences: false)
                transcriptLayout.invalidateForStructureChange()
                layoutSubtreeIfNeeded()
            }
        )
        jumpToLatestButton.isHidden = !scrollController.showsJumpToLatest
    }

    var qaThinkingIndicatorVisible: Bool { tailThinkingIndicatorIsVisible && !tailThinkingIndicator.isHidden }
    var qaTailIsVirtualDocumentRow: Bool {
        tailThinkingIndicatorIsVisible &&
            collectionView.item(at: IndexPath(item: rows.count, section: 0)) is AgentTranscriptTailItem
    }
    var qaTranscriptDocumentHeight: CGFloat {
        layoutSubtreeIfNeeded()
        return transcriptLayout.collectionViewContentSize.height
    }
    var qaPendingRuntimeObservationCount: Int { pendingRuntimeObservations.count }
    var qaThinkingIndicatorFrame: NSRect {
        guard tailThinkingIndicator.superview != nil else { return .zero }
        return tailThinkingIndicator.convert(tailThinkingIndicator.bounds, to: self)
    }

    private func contextWithDisclosureState(_ context: AgentRenderContext) -> AgentRenderContext {
        var context = context
        context.actions = disclosureStateStore.renderActions(
            for: disclosureOwnerID,
            perform: context.actions.perform,
            invalidatePresentation: { [weak self] id in
                self?.remeasureDisclosure(id: id)
            }
        )
        return context
    }

    private func measuredHeight(for row: Row, width: CGFloat) throws -> CGFloat {
        switch row.content {
        case let .block(block):
            do {
                let presented = presentedToolBlock(block)
                let renderer = try registry.renderer(for: presented.kind, entryRole: row.role)
                return measurementCache.height(
                    for: presented,
                    width: width,
                    context: renderContext,
                    entryRole: row.role,
                    renderer: renderer
                )
            } catch {
                throw UpdateError.renderer(error)
            }
        case let .completedReasoning(entry):
            return CompletedReasoningDisclosureView.measuredHeight(
                for: entry,
                authoritativeDuration: authoritativeReasoningDuration(entry),
                width: width,
                context: renderContext,
                registry: registry
            )
        }
    }

    private func updateVisibleHosts(ids: Set<AgentNodeID>) throws {
        for case let item as AgentTranscriptCollectionItem in collectionView.visibleItems() {
            guard let id = item.hostView?.representedID ?? item.reasoningDisclosureView?.presentation?.entryID,
                  ids.contains(id), let row = rowsByID[id] else { continue }
            do {
                switch row.content {
                case let .block(block):
                    let host = item.installHost(registry: registry, cache: measurementCache)
                    try host.apply(block: presentedToolBlock(block), entryRole: row.role, context: renderContext)
                case let .completedReasoning(entry):
                    let disclosure = item.installCompletedReasoningDisclosure()
                    disclosure.apply(
                        entry: entry,
                        authoritativeDuration: authoritativeReasoningDuration(entry),
                        context: renderContext,
                        registry: registry
                    )
                }
            } catch {
                throw UpdateError.renderer(error)
            }
        }
    }

    private func remeasureDisclosure(id: AgentNodeID) {
        // Renderer callbacks carry the toggled block ID. A tool/command inside
        // a reasoning disclosure is not itself a collection item; route it back
        // through the flattened ownership map so the outer entry is remeasured.
        let topLevelIDs = topLevelIDsByNodeID[id] ?? []
        let affectedIDs = Set(topLevelIDs.filter { rowsByID[$0] != nil })
        guard !affectedIDs.isEmpty else { return }
        scrollController.applyPreservingReaderAnchor(
            in: scrollView,
            idAtY: { [weak self] y in self?.transcriptID(at: y) },
            yForID: { [weak self] id in self?.transcriptY(for: id) },
            update: { [weak self] in
                guard let self else { return }
                transcriptLayout.invalidate(changedIDs: affectedIDs)
                layoutSubtreeIfNeeded()
            }
        )
        jumpToLatestButton.isHidden = !scrollController.showsJumpToLatest
    }

    /// QA: layout passes this transcript has been put through. The profile of a
    /// real zoom names this method directly (~960 samples), so the tile body owns
    /// a real share of the traversal, not just AppKit's recursion around it.
    private(set) var qaLayoutPassCount = 0

    override func layout() {
        qaLayoutPassCount += 1
        super.layout()
        let clipSize = scrollView.contentView.bounds.size
        if abs(collectionView.frame.width - clipSize.width) > 0.5 {
            collectionView.setFrameSize(NSSize(
                width: clipSize.width, height: max(collectionView.frame.height, clipSize.height)
            ))
            transcriptLayout.invalidateForStructureChange()
        }
        // Materialize visible items in THIS pass: a live window's display cycle
        // does it on its own, but offscreen renders (baselines, Component Lab)
        // never run one — a document applied while the tile was still zero-sized
        // snapshots as an applied-but-EMPTY collection (P5.5 removal finding:
        // rows and layout attributes existed, live hosts were zero).
        collectionView.layoutSubtreeIfNeeded()
        // And drive the layout's own prepare pass: offscreen, AppKit neither
        // re-prepares an invalidated layout nor repositions materialized items —
        // both only happen in a live display cycle — so a probe re-hosted at a
        // new width otherwise snapshots 560pt-wide rows spilling out of a 320pt
        // tile. Both calls are idempotent in a live window (the width bucket and
        // the frames already match).
        transcriptLayout.prepare()
        for indexPath in collectionView.indexPathsForVisibleItems() {
            guard let item = collectionView.item(at: indexPath),
                  let attributes = transcriptLayout.layoutAttributesForItem(at: indexPath),
                  item.view.frame != attributes.frame else { continue }
            item.view.frame = attributes.frame
        }

        // `.plans/45` T3. Turn chrome is rebuilt only when something that can
        // MOVE a rule changed — the boundary set or the width. Rebuilding a
        // CGPath on every display cycle would be work proportional to content
        // repeated per display cycle, which is `performance.md`'s whole thesis.
        // It must run AFTER `transcriptLayout.prepare()` above: the rules are
        // positioned from PREPARED attributes, and reading them before the
        // prepare pass returns nothing, so the path came out empty.
        var hasher = Hasher()
        for row in rows { hasher.combine(row.entryID) }
        hasher.combine(Int(collectionView.bounds.width.rounded()))
        let signature = hasher.finalize()
        if signature != preparedTurnChromeSignature {
            preparedTurnChromeSignature = signature
            refreshTurnChrome()
        }

        // NSCollectionView's custom layout reports the scrollable content height,
        // but the document view still needs that height in AppKit's clip
        // coordinates. Keeping it at the viewport height makes offscreen layout
        // attributes unreachable even though they exist.
        collectionView.layoutSubtreeIfNeeded()
        let contentHeight = max(clipSize.height, transcriptLayout.collectionViewContentSize.height)
        if abs(collectionView.frame.height - contentHeight) > 0.5 {
            collectionView.setFrameSize(NSSize(width: clipSize.width, height: contentHeight))
        }
    }

    /// Binds a transcript entry to its immutable host-local provider identity.
    /// A conflicting lifecycle rebind is rejected; preserving the original
    /// binding keeps already-rendered and cached identity from being rewritten.
    @discardableResult
    func bindToolDetailIdentity(_ identity: AgentToolDetailKey, to entryID: AgentNodeID) -> Bool {
        if let toolDetailAgentID,
           identity.scope.agentID != toolDetailAgentID.rawValue.uuidString {
            return false
        }
        guard let existing = toolDetailIdentityByEntryID[entryID] else {
            toolDetailIdentityByEntryID[entryID] = identity
            return true
        }
        return existing == identity
    }

    private func prepareToolDetailLifecycle(for document: AgentDocument) {
        let incoming = Dictionary(uniqueKeysWithValues: document.entries.map { ($0.id, $0) })
        var invalidatedEntryIDs = Set(toolDetailEntryLifecycleByID.keys).subtracting(incoming.keys)
        var removedBlockIDsByEntry: [AgentNodeID: Set<AgentNodeID>] = [:]
        for (id, oldEntry) in toolDetailEntryLifecycleByID {
            guard let newEntry = incoming[id] else { continue }
            guard oldEntry.role == newEntry.role,
                  oldEntry.provenance == newEntry.provenance else {
                invalidatedEntryIDs.insert(id)
                continue
            }
            let oldBlockIDs = toolDetailBlockIDs(in: oldEntry)
            let newBlockIDs = toolDetailBlockIDs(in: newEntry)
            let removedBlockIDs = oldBlockIDs.subtracting(newBlockIDs)
            guard !removedBlockIDs.isEmpty else { continue }
            // A removed/replaced tool block invalidates the owning entry even
            // when a paragraph or another sibling survives. The provider
            // identity is entry-scoped, so a selective child purge would let
            // that identity/cache/runtime binding reach the replacement tool.
            let removedToolBlockIDs = toolBlockIDs(in: oldEntry).subtracting(toolBlockIDs(in: newEntry))
            if !removedToolBlockIDs.isEmpty || oldBlockIDs.isDisjoint(with: newBlockIDs) {
                invalidatedEntryIDs.insert(id)
            } else {
                // Non-tool sibling removal has no provider identity of its own;
                // retain the entry binding while clearing its local disclosure.
                removedBlockIDsByEntry[id] = removedBlockIDs
            }
        }
        if !invalidatedEntryIDs.isEmpty {
            purgeToolDetailState(for: invalidatedEntryIDs)
        }
        for (entryID, blockIDs) in removedBlockIDsByEntry where !invalidatedEntryIDs.contains(entryID) {
            purgeToolDetailBlockState(for: blockIDs)
        }
        if incoming.isEmpty {
            runtimeIdentities.removeAll()
            pendingRuntimeObservations.removeAll()
            activeRuntimeScope = nil
        }
        toolDetailEntryLifecycleByID = incoming
    }

    private func toolDetailBlockIDs(in entry: AgentEntry) -> Set<AgentNodeID> {
        var ids = Set<AgentNodeID>()
        var pendingBlocks = entry.blocks
        while let block = pendingBlocks.popLast() {
            ids.insert(block.id)
            pendingBlocks.append(contentsOf: block.children)
        }
        return ids
    }

    private func toolBlockIDs(in entry: AgentEntry) -> Set<AgentNodeID> {
        var ids = Set<AgentNodeID>()
        var pendingBlocks = entry.blocks
        while let block = pendingBlocks.popLast() {
            switch block.payload {
            case .toolCall, .diff: ids.insert(block.id)
            default: break
            }
            pendingBlocks.append(contentsOf: block.children)
        }
        return ids
    }

    private func purgeToolDetailState(for entryIDs: Set<AgentNodeID>) {
        guard !entryIDs.isEmpty else { return }
        var identities = Set<AgentToolDetailKey>()
        var blockIDs = Set<AgentNodeID>()
        for entryID in entryIDs {
            if let identity = toolDetailIdentityByEntryID.removeValue(forKey: entryID) {
                identities.insert(identity)
            }
            guard let entry = toolDetailEntryLifecycleByID[entryID] else { continue }
            var pendingBlocks = entry.blocks
            var entryBlockIDs = Set<AgentNodeID>()
            while let block = pendingBlocks.popLast() {
                entryBlockIDs.insert(block.id)
                pendingBlocks.append(contentsOf: block.children)
                if let identity = toolDetailIDByBlockID[block.id] {
                    identities.insert(identity)
                }
            }
            blockIDs.formUnion(entryBlockIDs)
            // This method is reached only for removal or an identity-changing
            // replacement. Content updates with the same entry/block IDs never
            // arrive here, so purge the complete old disclosure subtree for all
            // roles, including reasoning, before any ID can be reused.
            disclosureStateStore.removeSubtree(
                for: disclosureOwnerID,
                rootID: entryID,
                descendantIDs: entryBlockIDs
            )
        }
        for blockID in blockIDs {
            toolDetailIDByBlockID.removeValue(forKey: blockID)
        }
        removeToolDetailIdentities(identities)
    }

    private func purgeToolDetailBlockState(for blockIDs: Set<AgentNodeID>) {
        guard !blockIDs.isEmpty else { return }
        for blockID in blockIDs {
            disclosureStateStore.removeState(for: ToolDisclosureKey(
                agentID: disclosureOwnerID,
                blockID: blockID
            ))
            // The owning entry identity still survives this selective diff, so
            // retain its provider record/cache for any surviving sibling block.
            toolDetailIDByBlockID.removeValue(forKey: blockID)
        }
    }

    private func removeToolDetailIdentities(_ identities: Set<AgentToolDetailKey>) {
        for identity in identities {
            toolDetailsByID.removeValue(forKey: identity)
            runtimeIdentities.remove(identity)
        }
    }

    /// The provider tool-detail identity an entry's blocks inherit. Factored out of
    /// `flatten` so the incremental path computes it from the same rules verbatim —
    /// a second copy here is exactly how the two paths would drift apart, which the
    /// equivalence oracle in `--transcript-delta-index-oracle-check` would then
    /// have to catch after the fact.
    private func toolDetailKey(for entry: AgentEntry) -> AgentToolDetailKey? {
        guard case let .providerItem(provider, itemID?) = entry.provenance,
              let itemID = AgentToolDetailID(itemID),
              let candidate = toolDetailIdentityByEntryID[entry.id],
              candidate.providerItemID == itemID,
              (toolDetailAgentID == nil || candidate.scope.agentID == toolDetailAgentID?.rawValue.uuidString),
              candidate.scope.provider == provider
        else { return nil }
        return candidate
    }

    // MARK: - Turn chrome (`.plans/45` T3)

    /// A turn is a user prompt AND the reply it produced — not one entry.
    ///
    /// The first cut treated every entry change as a boundary, which put a rule
    /// between a prompt and its own answer: the transcript grew a horizontal line
    /// after every single message and read as a list of unrelated cards. Caught
    /// by looking at the rendered tour, not by any assertion, because "the gaps
    /// differ" was true of the wrong answer too.
    ///
    /// Consecutive assistant/reasoning entries inside one turn stay at the
    /// ordinary inter-block gap.
    static func startsTurn(_ rows: [Row], at index: Int) -> Bool {
        guard index > 0, rows.indices.contains(index), rows.indices.contains(index - 1)
        else { return false }
        guard rows[index].entryID != rows[index - 1].entryID else { return false }
        return rows[index].role == .user && rows[index - 1].role != .user
    }

    /// Records each entry's `createdAt`. The transcript renders NOTHING for a nil
    /// — `AgentSupervisor.replayCap` bounds a rebuilt tile to the last 500 events
    /// and every transcript persisted before T1 has none, so inventing one would
    /// put a false timestamp on real history.
    private func captureTurnTimes(from document: AgentDocument) {
        entryDatesByID = Dictionary(
            uniqueKeysWithValues: document.entries.map { ($0.id, $0.createdAt) })
    }

    private func configureTurnChrome() {
        collectionView.wantsLayer = true
        turnSeparatorLayer.fillColor = nil
        turnSeparatorLayer.actions = ["path": NSNull(), "fillColor": NSNull(), "frame": NSNull()]
        hoverTimeLayer.actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull()]
        hoverTimeLayer.opacity = 0
        hoverTimeLayer.contentsScale = window?.backingScaleFactor ?? 2
        collectionView.layer?.addSublayer(turnSeparatorLayer)
        collectionView.layer?.addSublayer(hoverTimeLayer)
    }

    /// Rebuilds the separator path from the layout's PREPARED attributes, so the
    /// rule sits in the gap the layout actually left rather than in the gap the
    /// spacing rule intended.
    func refreshTurnChrome() {
        // Two different sets, deliberately. A RULE is drawn between turns, so the
        // first turn has none — there is nothing above it to separate from. But
        // the first turn is still a turn, and hovering it must reveal its time
        // like any other, so the hover anchors include row 0.
        var boundaries: [(row: Int, entryID: AgentNodeID)] = []
        for index in rows.indices where Self.startsTurn(rows, at: index) {
            boundaries.append((index, rows[index].entryID))
        }
        var starts = boundaries
        if let first = rows.first { starts.insert((0, first.entryID), at: 0) }
        turnStartRowsByEntry = starts.map {
            ($0.row, $0.entryID, entryDatesByID[$0.entryID] ?? nil)
        }

        let path = CGMutablePath()
        let inset = transcriptLayout.contentInsets.left
        let width = max(0, collectionView.bounds.width - inset * 2)
        let thickness = max(CGFloat(LineWidth.hairline), 1.0 / (window?.backingScaleFactor ?? 2))
        for boundary in boundaries {
            guard let frame = transcriptLayout.layoutAttributesForItem(
                at: IndexPath(item: boundary.row, section: 0))?.frame else { continue }
            let y = frame.minY - AgentTranscriptLayout.interTurnSpacing / 2
            path.addRect(CGRect(x: inset, y: y, width: width, height: thickness))
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        turnSeparatorLayer.frame = collectionView.bounds
        turnSeparatorLayer.path = path
        turnSeparatorLayer.fillColor = AgentLineRole.decorativeHairline.color
            .cgColor(for: renderContext.appearance)
        CATransaction.commit()
        updateHoverTimeLayer()
    }

    private func updateHoverTimeLayer() {
        guard let hoveredTurnEntryID,
              let turn = turnStartRowsByEntry.first(where: { $0.entryID == hoveredTurnEntryID }),
              let date = turn.date,
              let frame = transcriptLayout.layoutAttributesForItem(
                  at: IndexPath(item: turn.row, section: 0))?.frame
        else {
            setHoverTime(opacity: 0)
            return
        }
        hoverTimeLayer.string = NSAttributedString(
            string: Self.hoverTimeFormatter.string(from: date),
            attributes: [
                .font: NSFont.token(.caption),
                .foregroundColor: renderContext.tokens.secondaryText.color
                    .nsColor(for: renderContext.appearance),
            ])
        let size = hoverTimeLayer.preferredFrameSize()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // In the left gutter, outside the reading column, so revealing it can
        // never reflow a line of text.
        hoverTimeLayer.frame = CGRect(
            x: max(0, transcriptLayout.contentInsets.left - size.width - CGFloat(Space.s)),
            y: frame.minY, width: size.width, height: size.height)
        CATransaction.commit()
        setHoverTime(opacity: 1)
    }

    /// Motion is "short and purposeful, and disabled by Reduce Motion"
    /// (`_DESIGN.md` §11). With that setting on the time still appears — it just
    /// does not fade.
    private func setHoverTime(opacity: Float) {
        guard hoverTimeLayer.opacity != opacity else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hoverTimeLayer.opacity = opacity
            CATransaction.commit()
        } else {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = hoverTimeLayer.opacity
            fade.toValue = opacity
            fade.duration = 0.12
            hoverTimeLayer.opacity = opacity
            hoverTimeLayer.add(fade, forKey: "opacity")
        }
    }

    private static let hoverTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let transcriptTrackingArea { removeTrackingArea(transcriptTrackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        transcriptTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = collectionView.convert(event.locationInWindow, from: nil)
        // Nothing here forces a layout pass: the row is found from already
        // prepared attributes, and only a layer's position and opacity change.
        var hovered: AgentNodeID?
        for turn in turnStartRowsByEntry {
            guard let frame = transcriptLayout.layoutAttributesForItem(
                at: IndexPath(item: turn.row, section: 0))?.frame else { continue }
            if point.y >= frame.minY - AgentTranscriptLayout.interTurnSpacing,
               point.y <= frame.maxY {
                hovered = turn.entryID
                break
            }
        }
        guard hovered != hoveredTurnEntryID else { return }
        hoveredTurnEntryID = hovered
        updateHoverTimeLayer()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        guard hoveredTurnEntryID != nil else { return }
        hoveredTurnEntryID = nil
        updateHoverTimeLayer()
    }

    /// QA: the turn rules currently painted, and the hover time's visibility.
    var qaTurnSeparatorCountForChecks: Int {
        guard let path = turnSeparatorLayer.path else { return 0 }
        var count = 0
        path.applyWithBlock { element in
            if element.pointee.type == .moveToPoint { count += 1 }
        }
        return count
    }

    var qaHoverTimeVisibleForChecks: Bool { hoverTimeLayer.opacity > 0 }

    func qaHoverTurnForChecks(entryID: AgentNodeID?) {
        hoveredTurnEntryID = entryID
        updateHoverTimeLayer()
    }

    private func flatten(_ document: AgentDocument) throws -> RowIndex {
        var rows: [Row] = []
        var owners: [AgentNodeID: Set<AgentNodeID>] = [:]
        var toolDetailIDs: [AgentNodeID: AgentToolDetailKey] = [:]
        var topLevelIDs: Set<AgentNodeID> = []
        var positions: [AgentNodeID: RowPosition] = [:]
        var entryIndexes: [AgentNodeID: Int] = [:]
        qaFullFlattenCount += 1
        var nodeVisits = 0
        defer {
            qaFlattenNodeVisits += nodeVisits
            qaFlattenedRowCount += rows.count
        }

        func index(_ block: AgentBlock, owner: AgentNodeID, detailID: AgentToolDetailKey?) {
            nodeVisits += 1
            owners[block.id] = [owner]
            if let detailID { toolDetailIDs[block.id] = detailID }
            block.children.forEach { index($0, owner: owner, detailID: detailID) }
        }
        for (entryIndex, entry) in document.entries.enumerated() {
            entryIndexes[entry.id] = entryIndex
            let detailID = toolDetailKey(for: entry)
            if entry.role == .reasoning {
                // Open reasoning is represented by the surrounding activity/status
                // owner, not by a second transcript row. Finished reasoning is one
                // stable entry row whose body remains semantic and role-aware inside
                // CompletedReasoningDisclosureView.
                guard entry.lifecycle == .finished, !entry.blocks.isEmpty else {
                    continue
                }
                guard topLevelIDs.insert(entry.id).inserted else {
                    throw UpdateError.duplicateTopLevelBlock(entry.id)
                }
                positions[entry.id] = RowPosition(entryID: entry.id, entryIndex: entryIndex, blockIndex: nil, slot: rows.count)
                rows.append(Row(content: .completedReasoning(entry), role: .reasoning, entryID: entry.id))
                owners[entry.id] = [entry.id]
                for block in entry.blocks {
                    index(block, owner: entry.id, detailID: detailID)
                }
                continue
            }

            for (blockIndex, block) in entry.blocks.enumerated() {
                guard topLevelIDs.insert(block.id).inserted else {
                    throw UpdateError.duplicateTopLevelBlock(block.id)
                }
                positions[block.id] = RowPosition(entryID: entry.id, entryIndex: entryIndex, blockIndex: blockIndex, slot: rows.count)
                rows.append(Row(content: .block(block), role: entry.role, entryID: entry.id))
                index(block, owner: block.id, detailID: detailID)
            }
            owners[entry.id] = []
        }
        return (rows, owners, toolDetailIDs, positions, entryIndexes)
    }

    /// Rebuild ONLY the rows a patch names, using the cached position index.
    ///
    /// Returns `nil` whenever the patch or the document makes that unsafe, and nil
    /// is always a CORRECT answer — it costs one full rebuild and nothing else, so
    /// every guard below can be conservative without risking wrong content. The
    /// structural cases are refused deliberately: an insert, a removal or a move
    /// changes row ORDER, and establishing order is precisely what the full walk
    /// is for.
    private func incrementallyIndexed(document: AgentDocument, patch: AgentDocumentPatch) -> RowIndex? {
        guard patch.inserted.isEmpty, patch.removed.isEmpty, patch.moved.isEmpty else { return nil }
        guard let applied = appliedDocument, !rows.isEmpty else { return nil }
        guard applied.entries.count == document.entries.count else { return nil }

        var owners = topLevelIDsByNodeID
        var toolDetails = toolDetailIDByBlockID
        var rowIDsToRebuild: Set<AgentNodeID> = []

        for id in patch.updated {
            guard let owning = owners[id] else { return nil }
            guard owning.isEmpty else {
                rowIDsToRebuild.formUnion(owning)
                continue
            }
            // An entry owns no row of its own, but its role and lifecycle decide
            // whether and how its blocks present at all, so skipping it is only
            // safe while both are unchanged. A change to either is structural and
            // belongs to the full walk.
            guard let entryIndex = entryIndexByID[id],
                  applied.entries.indices.contains(entryIndex),
                  document.entries.indices.contains(entryIndex)
            else { return nil }
            let old = applied.entries[entryIndex]
            let new = document.entries[entryIndex]
            guard old.id == id, new.id == id,
                  old.role == new.role,
                  old.lifecycle == new.lifecycle,
                  old.blocks.count == new.blocks.count
            else { return nil }
        }

        guard !rowIDsToRebuild.isEmpty else {
            // A bookkeeping-only revision: nothing presented changed.
            return (rows, owners, toolDetails, rowPositions, entryIndexByID)
        }

        var newRows = rows

        // Counted into the SAME witness the full walk reports to. A cheaper path
        // that stopped counting its own work would look free instead of local.
        var nodeVisits = 0
        func reindex(_ block: AgentBlock, owner: AgentNodeID, detailID: AgentToolDetailKey?) {
            nodeVisits += 1
            owners[block.id] = [owner]
            // `flatten` builds this map from empty and only ever inserts, so the
            // incremental path has to REMOVE a key it would not have written —
            // otherwise a block that lost its provider identity keeps a stale one.
            if let detailID { toolDetails[block.id] = detailID } else { toolDetails.removeValue(forKey: block.id) }
            block.children.forEach { reindex($0, owner: owner, detailID: detailID) }
        }

        for rowID in rowIDsToRebuild {
            guard let position = rowPositions[rowID],
                  newRows.indices.contains(position.slot),
                  newRows[position.slot].id == rowID,
                  document.entries.indices.contains(position.entryIndex)
            else { return nil }
            let slot = position.slot
            let entry = document.entries[position.entryIndex]
            guard entry.id == position.entryID else { return nil }
            let detailID = toolDetailKey(for: entry)
            if let blockIndex = position.blockIndex {
                guard entry.blocks.indices.contains(blockIndex) else { return nil }
                let block = entry.blocks[blockIndex]
                guard block.id == rowID else { return nil }
                newRows[slot] = Row(content: .block(block), role: entry.role, entryID: entry.id)
                reindex(block, owner: block.id, detailID: detailID)
            } else {
                // A completedReasoning row's content IS the entry, and it stops
                // being a row at all if it is no longer finished or loses its
                // blocks — structural, so refuse rather than present a stale row.
                guard entry.id == rowID, entry.role == .reasoning,
                      entry.lifecycle == .finished, !entry.blocks.isEmpty
                else { return nil }
                newRows[slot] = Row(content: .completedReasoning(entry), role: .reasoning, entryID: entry.id)
                owners[entry.id] = [entry.id]
                for block in entry.blocks { reindex(block, owner: entry.id, detailID: detailID) }
            }
        }

        qaFlattenNodeVisits += nodeVisits
        qaFlattenedRowCount += rowIDsToRebuild.count
        return (newRows, owners, toolDetails, rowPositions, entryIndexByID)
    }

    /// Composes sanitized host-local detail into a terminal tool or file-change
    /// block. Active work stays on the semantic activity/status path. The source
    /// document and its Codable payload remain unchanged.
    private func presentedToolBlock(_ block: AgentBlock) -> AgentBlock {
        switch block.payload {
        case let .toolCall(payload) where payload.status == .pending || payload.status == .inProgress:
            return block
        case .toolCall, .diff:
            break
        default:
            return block
        }
        guard let providerID = toolDetailIDByBlockID[block.id] else { return block }
        if let cached = toolDetailsByID[providerID],
           let timeToLive = toolDetailTimeToLive,
           (timeToLive <= 0 || toolDetailClock().timeIntervalSince(cached.updatedAt) >= timeToLive) {
            toolDetailsByID.removeValue(forKey: providerID)
        }
        let candidate: AgentToolDetailRecord
        let detail: AgentToolDetailRecord
        if let providerCandidate = toolDetailProvider?(providerID) {
            guard providerCandidate.identity == providerID,
                  let sanitized = AgentToolDetailPresenter.sanitizedProviderRecord(providerCandidate)
            else { return block }
            candidate = providerCandidate
            detail = sanitized
        } else {
            guard let stored = toolDetailsByID[providerID], stored.identity == providerID else { return block }
            // Actor-store snapshots have already crossed the sanitizer that
            // validates affected file URLs. Preserve those host-local paths;
            // applying the untrusted-provider boundary again erased the exact
            // file the disclosure exists to reveal.
            candidate = stored
            detail = stored
        }
        let candidateIsFresh: Bool
        if let timeToLive = toolDetailTimeToLive {
            candidateIsFresh = timeToLive > 0 &&
                toolDetailClock().timeIntervalSince(candidate.updatedAt) < timeToLive
        } else {
            candidateIsFresh = true
        }
        guard candidateIsFresh,
              candidate.status != .pending,
              candidate.status != .inProgress else { return block }
        var presented = block
        switch block.payload {
        case var .toolCall(payload):
            // The observable summary may include a sanitized basename or command
            // query. Opaque semantic arguments still never enter this presentation.
            payload.summary = AgentToolDetailPresenter.observableDisclosureText(detail)
            presented.payload = .toolCall(payload)
        case var .diff(payload):
            // A provider-authored semantic file list wins. Otherwise, compose
            // abbreviated host-local targets into this ephemeral presentation.
            // No filesystem capability or absolute path enters AgentDocument.
            if payload.files.isEmpty {
                payload.files = AgentToolDetailPresenter.observableAffectedFileNames(detail).map {
                    AgentDiffFileSummary(displayName: $0)
                }
            }
            presented.payload = .diff(payload)
        default:
            return block
        }
        return presented
    }

    /// Refreshes the host-local actor snapshot without putting tool details into
    /// semantic rows, runtime events, or sync payloads. Callers that connect the
    /// provider observer may invoke this after a terminal tool event as well.
    func refreshToolDetailPresentation() {
        scheduleToolDetailRefresh()
    }

    func qaWaitForToolDetailRefresh() async {
        await toolDetailRefreshTask?.value
    }

    private func scheduleToolDetailRefresh() {
        guard let toolDetailStore else {
            refreshVisibleToolDetails()
            return
        }
        toolDetailRefreshTask?.cancel()
        toolDetailRefreshTask = Task { [weak self, toolDetailStore] in
            let details = await toolDetailStore.allDetails()
            guard !Task.isCancelled, let self else { return }
            // `AgentToolDetailStore` owns the sanitizer. Keeping its records
            // intact here is what preserves approved affected-file observations.
            self.toolDetailsByID = Dictionary(uniqueKeysWithValues: details.map { ($0.identity, $0) })
            self.refreshVisibleToolDetails()
        }
    }

    private func refreshVisibleToolDetails() {
        let changed = Set(toolDetailIDByBlockID.keys.compactMap { blockID in
            topLevelIDsByNodeID[blockID]?.first
        })
        guard !changed.isEmpty else { return }
        for blockID in toolDetailIDByBlockID.keys { measurementCache.invalidate(id: blockID) }
        do {
            try scrollController.apply(
                in: scrollView,
                idAtY: { [weak self] y in self?.transcriptID(at: y) },
                yForID: { [weak self] id in self?.transcriptY(for: id) },
                isSelecting: { [weak self] in self?.hasActiveTextSelection() ?? false },
                update: { [weak self] in
                    guard let self else { return }
                    transcriptLayout.invalidate(changedIDs: changed)
                    try updateVisibleHosts(ids: changed)
                }
            )
        } catch {
            renderingError = UpdateError.renderer(error)
        }
        jumpToLatestButton.isHidden = !scrollController.showsJumpToLatest
    }

    /// Runtime capture remains a host-local adapter: only a non-Codable scoped
    /// key, sanitized tool name, lifecycle status, and approved path observation
    /// enter the actor. Raw runtime payloads never cross into this view or the
    /// document. Runtime events already carry thread/turn routing; this adapter
    /// derives local scope from them instead of widening their Codable shape.
    @discardableResult
    func captureRuntimeEvent(_ event: AgentRuntimeEvent) -> AgentToolDetailKey? {
        guard let toolDetailStore else { return nil }
        switch event {
        case let .turnStarted(threadID, turnID):
            // A new immutable scope invalidates every unmatched observation from
            // the prior turn. The provider may reuse item IDs, but it may never
            // reuse a complete scope.
            let newScope = runtimeScope(threadID: threadID, turnID: turnID)
            activeRuntimeScope = newScope
            pendingRuntimeObservations = pendingRuntimeObservations.filter {
                $0.key.scope == newScope
            }
            return nil
        case let .itemStarted(threadID, itemID, kind, title):
            guard Self.isToolDetailKind(kind),
                  let providerID = AgentToolDetailID(itemID),
                  let activeRuntimeScope,
                  activeRuntimeScope.threadID == threadID else { return nil }
            let identity = AgentToolDetailKey(scope: activeRuntimeScope, providerItemID: providerID)
            runtimeIdentities.insert(identity)
            let pending = pendingRuntimeObservations.removeValue(forKey: identity)
            Task { [weak self, toolDetailStore] in
                _ = await toolDetailStore.recordStart(AgentToolDetailStart(
                    identity: identity,
                    toolName: title ?? "Tool"
                ))
                if case let .toolActivity(_, activity) = pending {
                    _ = await toolDetailStore.recordStart(AgentToolDetailStart(
                        identity: identity,
                        toolName: activity.operation.rawValue,
                        affectedFiles: activity.targetPath.map { [$0] } ?? [],
                        startedAt: activity.startedAt
                    ))
                }
                self?.refreshToolDetailPresentation()
            }
            return identity
        case let .itemCompleted(threadID, itemID, kind, status):
            guard Self.isToolDetailKind(kind),
                  let providerID = AgentToolDetailID(itemID),
                  let scope = activeRuntimeScope,
                  scope.threadID == threadID else { return nil }
            let identity = AgentToolDetailKey(scope: scope, providerItemID: providerID)
            guard runtimeIdentities.contains(identity) else { return nil }
            let mapped: AgentItemStatus = status == .failed ? .failed : (status == .declined ? .cancelled : .completed)
            Task { [weak self, toolDetailStore] in
                _ = await toolDetailStore.recordEnd(AgentToolDetailEnd(identity: identity, status: mapped))
                self?.refreshToolDetailPresentation()
            }
        default:
            break
        }
        return nil
    }

    func captureRuntimeObservation(_ observation: AgentRuntimeObservation) {
        guard let toolDetailStore else { return }
        guard case let .toolActivity(itemID, activity) = observation,
              let providerID = AgentToolDetailID(itemID),
              let scope = activeRuntimeScope else { return }
        let identity = AgentToolDetailKey(scope: scope, providerItemID: providerID)
        guard runtimeIdentities.contains(identity) else {
            // Pi may publish its private observation before the normalized item
            // event. Hold only the sanitized observation under the complete
            // immutable agent/thread/turn/provider/item scope; a later turn can
            // never consume this value, even if Pi reuses the item ID.
            pendingRuntimeObservations[identity] = observation
            return
        }
        Task { [weak self, toolDetailStore] in
            _ = await toolDetailStore.recordStart(AgentToolDetailStart(
                identity: identity,
                toolName: activity.operation.rawValue,
                affectedFiles: activity.targetPath.map { [$0] } ?? [],
                startedAt: activity.startedAt
            ))
            self?.refreshToolDetailPresentation()
        }
    }

    private func runtimeScope(threadID: String, turnID: String) -> AgentToolDetailScope? {
        guard let toolDetailAgentID else { return nil }
        return AgentToolDetailScope(
            agentID: toolDetailAgentID.rawValue.uuidString,
            threadID: threadID,
            turnID: turnID,
            provider: "runtime"
        )
    }

    private static func isToolDetailKind(_ kind: ItemKind) -> Bool {
        switch kind {
        case .commandExecution, .fileChange, .mcpToolCall, .webSearch: return true
        case .assistantMessage, .reasoning, .plan, .error: return false
        }
    }

    private func track(_ host: AgentBlockHostView) {
        let identity = ObjectIdentifier(host)
        if trackedHosts[identity] == nil { trackedHosts[identity] = WeakHost(host) }
    }

    // Deterministic fixture observations; no production owner depends on these.
    var qaSemanticRowCount: Int { rows.count }
    func qaDisclosureState(for blockID: AgentNodeID) -> Bool? {
        disclosureStateStore.explicitState(for: ToolDisclosureKey(
            agentID: disclosureOwnerID, blockID: blockID
        ))
    }
    func qaSetDisclosureState(for blockID: AgentNodeID, expanded: Bool) {
        disclosureStateStore.setExpanded(
            expanded,
            for: ToolDisclosureKey(agentID: disclosureOwnerID, blockID: blockID)
        )
    }
    func qaDisclosureRevision(for blockID: AgentNodeID) -> UInt64 {
        disclosureStateStore.presentationRevision(for: ToolDisclosureKey(
            agentID: disclosureOwnerID, blockID: blockID
        ))
    }
    func qaTranscriptRowHeight(for id: AgentNodeID) -> CGFloat? {
        layoutSubtreeIfNeeded()
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return nil }
        return collectionView.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame.height
    }
    @discardableResult
    func qaPerformToolDisclosureClick(for id: AgentNodeID) -> Bool {
        guard let index = rows.firstIndex(where: { $0.id == id }),
              let item = collectionView.item(at: IndexPath(item: index, section: 0)) as? AgentTranscriptCollectionItem,
              let tool = item.hostView?.rendererView as? ToolCallView else { return false }
        tool.disclosureButton.performClick(nil)
        layoutSubtreeIfNeeded()
        return true
    }

    /// Production-route probe: returns the exact compact text supplied to the
    /// renderer, never the actor record or semantic payload. This lets geometry
    /// and privacy probes prove that terminal detail composes while active work
    /// remains summary/status-only.
    func qaPresentedToolSummary(for blockID: AgentNodeID) -> String? {
        guard let block = rows.compactMap(\.block).first(where: { $0.id == blockID }),
              case let .toolCall(payload) = presentedToolBlock(block).payload else { return nil }
        return payload.summary
    }
    func qaPresentedDiffFiles(for blockID: AgentNodeID) -> [AgentDiffFileSummary]? {
        guard let block = rows.compactMap(\.block).first(where: { $0.id == blockID }),
              case let .diff(payload) = presentedToolBlock(block).payload else { return nil }
        return payload.files
    }
    func richInlineTextViewsInSelectionOrder() -> [RichInlineTextView] {
        var found: [RichInlineTextView] = []
        func collect(_ view: NSView) {
            if let text = view as? RichInlineTextView { found.append(text) }
            view.subviews.forEach(collect)
        }
        collect(collectionView)
        return found.sorted { lhs, rhs in
            let left = lhs.convert(lhs.bounds, to: collectionView)
            let right = rhs.convert(rhs.bounds, to: collectionView)
            if abs(left.minY - right.minY) > 0.5 { return left.minY < right.minY }
            return left.minX < right.minX
        }
    }
    var qaLiveHostCount: Int {
        trackedHosts = trackedHosts.filter { $0.value.value != nil }
        return trackedHosts.count
    }
    var qaRepresentedHostIdentities: [AgentNodeID: ObjectIdentifier] {
        trackedHosts.values.reduce(into: [:]) { result, weakHost in
            guard let host = weakHost.value, let id = host.representedID else { return }
            result[id] = ObjectIdentifier(host)
        }
    }
    func qaHostIdentity(for id: AgentNodeID) -> ObjectIdentifier? {
        qaRepresentedHostIdentities[id]
    }
    /// Exercises the collection item's real reset/rebind path with an offscreen
    /// retained item, so incremental identity checks include a reused host that is
    /// not discoverable through `visibleItems()`.
    func qaExerciseReuseBoundary(from oldID: AgentNodeID, to newID: AgentNodeID) throws {
        guard let oldRow = rowsByID[oldID], let oldBlock = oldRow.block else {
            throw UpdateError.missingQARow(oldID)
        }
        guard let newRow = rowsByID[newID], let newBlock = newRow.block else {
            throw UpdateError.missingQARow(newID)
        }
        let item = AgentTranscriptCollectionItem()
        _ = item.view
        let host = item.installHost(registry: registry, cache: measurementCache)
        track(host)
        do {
            try host.apply(block: oldBlock, entryRole: oldRow.role, context: renderContext)
            item.prepareForReuse()
            try host.apply(block: newBlock, entryRole: newRow.role, context: renderContext)
        } catch {
            throw UpdateError.renderer(error)
        }
        qaReuseWitnessItem = item
    }
    var qaCachedMeasurementCount: Int { measurementCache.cachedMeasurementCount }
    var qaLayoutPreparePassCount: Int { transcriptLayout.preparePassCount }
    var qaShowsJumpToLatest: Bool { !jumpToLatestButton.isHidden }
    var qaVisibleAccessibilityText: [String] {
        collectionView.visibleItems().compactMap { item in
            guard let item = item as? AgentTranscriptCollectionItem,
                  let renderer = item.hostView?.rendererView else { return nil }
            return [renderer.accessibilityLabel(), renderer.accessibilityValue() as? String]
                .compactMap { $0 }
                .joined(separator: " ")
        }
    }

    var qaVisibleAccessibilityOrder: [AgentNodeID] {
        collectionView.visibleItems().compactMap { item -> (Int, AgentNodeID)? in
            guard let item = item as? AgentTranscriptCollectionItem,
                  let indexPath = collectionView.indexPath(for: item),
                  let id = item.hostView?.representedID else { return nil }
            return (indexPath.item, id)
        }.sorted { $0.0 < $1.0 }.map(\.1)
    }
}
