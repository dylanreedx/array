import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

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
final class AgentTranscriptListView: NSView {
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
    /// This scope is host-local composition state. It is never copied into the
    /// semantic document or any runtime/sync payload.
    private var toolDetailScope: AgentToolDetailScope?
    /// The list owns the view-state binding because the existing tile context
    /// deliberately carries only semantic render actions. Entry IDs remain the
    /// disclosure key; this opaque owner token prevents state crossing lists.
    private let disclosureStateStore = DisclosureStateStore()
    private let disclosureOwnerID: AgentID
    /// Duration is an optional host-attested presentation input. The current
    /// transcript model has no duration field, so the production default is nil
    /// rather than a locally inferred or fabricated clock.
    private let authoritativeReasoningDuration: (AgentEntry) -> TimeInterval?
    private var dataSource: NSCollectionViewDiffableDataSource<Int, AgentNodeID>!
    private var rows: [Row] = []
    private var rowsByID: [AgentNodeID: Row] = [:]
    private var topLevelIDsByNodeID: [AgentNodeID: Set<AgentNodeID>] = [:]
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
        toolDetailScope: AgentToolDetailScope? = nil
    ) {
        self.registry = registry
        disclosureOwnerID = AgentID(rawValue: UUID())
        self.renderContext = renderContext
        self.authoritativeReasoningDuration = authoritativeReasoningDuration
        self.toolDetailStore = toolDetailStore
        self.toolDetailProvider = toolDetailProvider
        self.toolDetailScope = toolDetailScope
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
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.register(
            AgentTranscriptCollectionItem.self,
            forItemWithIdentifier: NSUserInterfaceItemIdentifier("AgentTranscriptCollectionItem")
        )
        scrollView.documentView = collectionView
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

        transcriptLayout.itemCount = { [weak self] in self?.rows.count ?? 0 }
        transcriptLayout.measuredHeight = { [weak self] index, width in
            guard let self, rows.indices.contains(index) else { return 1 }
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
            guard let self, let row = rowsByID[id] else { return nil }
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
        if newWindow == nil { updateScheduler.flush() }
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
        let flattened = try flatten(document)
        try applyWithScroll(
            document: document,
            flattened: flattened,
            changedNodeIDs: Set(patch.updated + patch.moved)
        )
        latestEnqueuedVersion = document.version
    }

    private func applyWithScroll(
        document: AgentDocument,
        flattened: (rows: [Row], topLevelIDsByNodeID: [AgentNodeID: Set<AgentNodeID>], toolDetailIDByBlockID: [AgentNodeID: AgentToolDetailKey]),
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
        flattened: (rows: [Row], topLevelIDsByNodeID: [AgentNodeID: Set<AgentNodeID>], toolDetailIDByBlockID: [AgentNodeID: AgentToolDetailKey]),
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
        let reasoningIDs = Set(topLevelIDs.filter { topLevelID in
            guard let content = rowsByID[topLevelID]?.content else { return false }
            if case .completedReasoning = content { return true }
            return false
        })
        guard !reasoningIDs.isEmpty else { return }
        scrollController.apply(
            in: scrollView,
            idAtY: { [weak self] y in self?.transcriptID(at: y) },
            yForID: { [weak self] id in self?.transcriptY(for: id) },
            isSelecting: { [weak self] in self?.hasActiveTextSelection() ?? false },
            update: { [weak self] in
                guard let self else { return }
                transcriptLayout.invalidate(changedIDs: reasoningIDs)
                layoutSubtreeIfNeeded()
            }
        )
        jumpToLatestButton.isHidden = !scrollController.showsJumpToLatest
    }

    override func layout() {
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

    private func flatten(
        _ document: AgentDocument
    ) throws -> (
        rows: [Row],
        topLevelIDsByNodeID: [AgentNodeID: Set<AgentNodeID>],
        toolDetailIDByBlockID: [AgentNodeID: AgentToolDetailKey]
    ) {
        var rows: [Row] = []
        var owners: [AgentNodeID: Set<AgentNodeID>] = [:]
        var toolDetailIDs: [AgentNodeID: AgentToolDetailKey] = [:]
        var topLevelIDs: Set<AgentNodeID> = []

        func index(_ block: AgentBlock, owner: AgentNodeID, detailID: AgentToolDetailKey?) {
            owners[block.id] = [owner]
            if let detailID { toolDetailIDs[block.id] = detailID }
            block.children.forEach { index($0, owner: owner, detailID: detailID) }
        }
        for entry in document.entries {
            var detailID: AgentToolDetailKey?
            if case let .providerItem(provider, itemID?) = entry.provenance,
               let itemID = AgentToolDetailID(itemID) {
                detailID = AgentToolDetailKey(
                    scope: toolDetailScope ?? .unscoped,
                    providerItemID: itemID
                )
                // The provider component is part of the key even when the
                // caller supplied no explicit host scope.
                if let scope = toolDetailScope {
                    detailID = AgentToolDetailKey(
                        scope: AgentToolDetailScope(
                            agentID: scope.agentID, threadID: scope.threadID,
                            turnID: scope.turnID, provider: provider
                        ), providerItemID: itemID
                    )
                }
            } else {
                detailID = nil
            }
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
                rows.append(Row(content: .completedReasoning(entry), role: .reasoning))
                owners[entry.id] = [entry.id]
                for block in entry.blocks {
                    index(block, owner: entry.id, detailID: detailID)
                }
                continue
            }

            for block in entry.blocks {
                guard topLevelIDs.insert(block.id).inserted else {
                    throw UpdateError.duplicateTopLevelBlock(block.id)
                }
                rows.append(Row(content: .block(block), role: entry.role))
                index(block, owner: block.id, detailID: detailID)
            }
            owners[entry.id] = []
        }
        return (rows, owners, toolDetailIDs)
    }

    /// Applies only a sanitized compact summary to a terminal tool block. Active
    /// work deliberately stays on the semantic activity/status path and never
    /// reads local detail. The document and its Codable payload remain unchanged.
    private func presentedToolBlock(_ block: AgentBlock) -> AgentBlock {
        guard case let .toolCall(payload) = block.payload,
              payload.status != .pending,
              payload.status != .inProgress,
              let providerID = toolDetailIDByBlockID[block.id],
              let detail = toolDetailProvider?(providerID) ?? toolDetailsByID[providerID],
              detail.status != .pending,
              detail.status != .inProgress else { return block }
        var presented = block
        var presentedPayload = payload
        // The compact human summary may include a basename or command query.
        // The disclosure surface is stricter: expose only the presenter's
        // value-free accessibility/count summary, never a path or raw value.
        presentedPayload.summary = AgentToolDetailPresenter.compact(detail).accessibilitySummary
        presented.payload = .toolCall(presentedPayload)
        return presented
    }

    /// Refreshes the host-local actor snapshot without putting tool details into
    /// semantic rows, runtime events, or sync payloads. Callers that connect the
    /// provider observer may invoke this after a terminal tool event as well.
    func refreshToolDetailPresentation() {
        scheduleToolDetailRefresh()
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
    func captureRuntimeEvent(_ event: AgentRuntimeEvent) {
        guard let toolDetailStore else { return }
        switch event {
        case let .turnStarted(threadID, turnID):
            toolDetailScope = runtimeScope(threadID: threadID, turnID: turnID)
        case let .itemStarted(threadID, itemID, kind, title):
            guard Self.isToolDetailKind(kind), let providerID = AgentToolDetailID(itemID) else { return }
            let turnID = toolDetailScope?.threadID == threadID ? toolDetailScope?.turnID : nil
            let scope = runtimeScope(threadID: threadID, turnID: turnID)
            toolDetailScope = scope
            let identity = AgentToolDetailKey(scope: scope, providerItemID: providerID)
            Task { [weak self, toolDetailStore] in
                _ = await toolDetailStore.recordStart(AgentToolDetailStart(
                    identity: identity,
                    toolName: title ?? "Tool"
                ))
                self?.refreshToolDetailPresentation()
            }
        case let .itemCompleted(threadID, itemID, kind, status):
            guard Self.isToolDetailKind(kind), let providerID = AgentToolDetailID(itemID) else { return }
            let turnID = toolDetailScope?.threadID == threadID ? toolDetailScope?.turnID : nil
            let scope = runtimeScope(threadID: threadID, turnID: turnID)
            let identity = AgentToolDetailKey(scope: scope, providerItemID: providerID)
            let mapped: AgentItemStatus = status == .failed ? .failed : (status == .declined ? .cancelled : .completed)
            Task { [weak self, toolDetailStore] in
                _ = await toolDetailStore.recordEnd(AgentToolDetailEnd(identity: identity, status: mapped))
                self?.refreshToolDetailPresentation()
            }
        default:
            break
        }
    }

    func captureRuntimeObservation(_ observation: AgentRuntimeObservation) {
        guard let toolDetailStore else { return }
        guard case let .toolActivity(itemID, activity) = observation,
              let providerID = AgentToolDetailID(itemID) else { return }
        let scope = toolDetailScope ?? runtimeScope(threadID: "")
        let identity = AgentToolDetailKey(scope: scope, providerItemID: providerID)
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

    private func runtimeScope(threadID: String, turnID: String? = nil) -> AgentToolDetailScope {
        AgentToolDetailScope(
            agentID: disclosureOwnerID.rawValue.uuidString,
            threadID: threadID,
            turnID: turnID,
            provider: "runtime"
        )
    }

    private static func isToolDetailKind(_ kind: ItemKind) -> Bool {
        switch kind {
        case .commandExecution, .mcpToolCall, .webSearch: return true
        case .fileChange, .assistantMessage, .reasoning, .plan, .error: return false
        }
    }

    private func track(_ host: AgentBlockHostView) {
        let identity = ObjectIdentifier(host)
        if trackedHosts[identity] == nil { trackedHosts[identity] = WeakHost(host) }
    }

    // Deterministic fixture observations; no production owner depends on these.
    var qaSemanticRowCount: Int { rows.count }
    func qaDisclosureState(for entryID: AgentNodeID) -> Bool? {
        disclosureStateStore.explicitState(for: ToolDisclosureKey(
            agentID: disclosureOwnerID, blockID: entryID
        ))
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

    /// Production-route probe: returns the exact compact text supplied to the
    /// renderer, never the actor record or semantic payload. This lets geometry
    /// and privacy probes prove that terminal detail composes while active work
    /// remains summary/status-only.
    func qaPresentedToolSummary(for blockID: AgentNodeID) -> String? {
        guard let block = rows.compactMap(\.block).first(where: { $0.id == blockID }),
              case let .toolCall(payload) = presentedToolBlock(block).payload else { return nil }
        return payload.summary
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
