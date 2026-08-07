import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedAgentUI

@MainActor
private final class AgentTranscriptCollectionItem: NSCollectionViewItem {
    private(set) var hostView: AgentBlockHostView?

    override func loadView() {
        view = NSView(frame: .zero)
    }

    func installHost(registry: AgentBlockRendererRegistry, cache: AgentBlockMeasurementCache) -> AgentBlockHostView {
        if let hostView { return hostView }
        let host = AgentBlockHostView(registry: registry, measurementCache: cache)
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

    override func prepareForReuse() {
        super.prepareForReuse()
        hostView?.resetForReuse()
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
        let block: AgentBlock
        let role: AgentEntryRole
    }

    let scrollView = NSScrollView(frame: .zero)
    let collectionView = NSCollectionView(frame: .zero)
    let transcriptLayout = AgentTranscriptLayout()

    private let registry: AgentBlockRendererRegistry
    private let measurementCache: AgentBlockMeasurementCache
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
        )
    ) {
        self.registry = registry
        self.renderContext = renderContext
        measurementCache = AgentBlockMeasurementCache()
        super.init(frame: .zero)
        configureCollectionView()
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Agent transcript")
        collectionView.setAccessibilityRole(.list)
        collectionView.setAccessibilityLabel("Transcript entries")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

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
                return try measurementCache.height(
                    for: row.block,
                    width: width,
                    context: renderContext,
                    entryRole: row.role,
                    renderer: registry.renderer(for: row.block.kind, entryRole: row.role)
                )
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
            let host = item.installHost(registry: registry, cache: measurementCache)
            track(host)
            do {
                try host.apply(block: row.block, entryRole: row.role, context: renderContext)
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
        let orderedHosts: [(Int, AgentBlockHostView)] = collectionView.visibleItems().compactMap { item in
            guard let item = item as? AgentTranscriptCollectionItem,
                  let indexPath = collectionView.indexPath(for: item),
                  let host = item.hostView else { return nil }
            return (indexPath.item, host)
        }
        var children: [Any] = orderedHosts.sorted { $0.0 < $1.0 }.map { $0.1 as Any }
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
            if frame.maxY >= y { return row.block.id }
            lastID = row.block.id
        }
        return lastID
    }

    private func transcriptY(for id: AgentNodeID) -> CGFloat? {
        guard let index = rows.firstIndex(where: { $0.block.id == id }) else { return nil }
        return collectionView.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame.minY
    }

    func copySelectedBlocks(
        asMarkdown: Bool = false,
        pasteboard: NSPasteboard = .general
    ) {
        let selectedRows = collectionView.selectionIndexPaths
            .sorted { $0.item < $1.item }
            .compactMap { rows.indices.contains($0.item) ? rows[$0.item] : nil }
        let selected = selectedRows.map(\.block)
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
        let flattened = try Self.flatten(document)
        let oldIndexes = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($0.element.block.id, $0.offset) })
        let changedNodeIDs = Set(flattened.rows.compactMap { row -> AgentNodeID? in
            guard let old = rowsByID[row.block.id] else { return nil }
            return old.block != row.block || old.role != row.role ? row.block.id : nil
        })
        let moved = flattened.rows.enumerated().compactMap { index, row -> AgentNodeID? in
            guard let oldIndex = oldIndexes[row.block.id], oldIndex != index else { return nil }
            return row.block.id
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
        let flattened = try Self.flatten(document)
        try applyWithScroll(
            document: document,
            flattened: flattened,
            changedNodeIDs: Set(patch.updated + patch.moved)
        )
        latestEnqueuedVersion = document.version
    }

    private func applyWithScroll(
        document: AgentDocument,
        flattened: (rows: [Row], topLevelIDsByNodeID: [AgentNodeID: Set<AgentNodeID>]),
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
        flattened: (rows: [Row], topLevelIDsByNodeID: [AgentNodeID: Set<AgentNodeID>]),
        changedNodeIDs: Set<AgentNodeID>
    ) throws {
        let oldIDs = rows.map(\.block.id)
        let oldRowsByID = rowsByID
        rows = flattened.rows
        rowsByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.block.id, $0) })
        topLevelIDsByNodeID = flattened.topLevelIDsByNodeID
        renderingError = nil

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

        let newIDs = rows.map(\.block.id)
        var snapshot = NSDiffableDataSourceSnapshot<Int, AgentNodeID>()
        snapshot.appendSections([0])
        snapshot.appendItems(newIDs, toSection: 0)

        var changedTopLevelIDs = Set(changedNodeIDs.flatMap { topLevelIDsByNodeID[$0] ?? [] })
        // Entry revisions also advance when one child changes. Do not fan that
        // bookkeeping update out to every sibling; only a role change affects all
        // renderer families in the entry.
        changedTopLevelIDs.formUnion(rows.compactMap { row in
            guard let old = oldRowsByID[row.block.id], old.role != row.role else { return nil }
            return row.block.id
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
        renderContext = context
        measurementCache.removeAll()
        transcriptLayout.invalidateForStructureChange()
        try updateVisibleHosts(ids: Set(rowsByID.keys))
    }

    private func measuredHeight(for row: Row, width: CGFloat) throws -> CGFloat {
        do {
            return measurementCache.height(
                for: row.block,
                width: width,
                context: renderContext,
                entryRole: row.role,
                renderer: try registry.renderer(for: row.block.kind, entryRole: row.role)
            )
        } catch {
            throw UpdateError.renderer(error)
        }
    }

    private func updateVisibleHosts(ids: Set<AgentNodeID>) throws {
        for case let item as AgentTranscriptCollectionItem in collectionView.visibleItems() {
            guard let host = item.hostView, let id = host.representedID,
                  ids.contains(id), let row = rowsByID[id] else { continue }
            do {
                try host.apply(block: row.block, entryRole: row.role, context: renderContext)
            } catch {
                throw UpdateError.renderer(error)
            }
        }
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

    private static func flatten(
        _ document: AgentDocument
    ) throws -> (rows: [Row], topLevelIDsByNodeID: [AgentNodeID: Set<AgentNodeID>]) {
        var rows: [Row] = []
        var owners: [AgentNodeID: Set<AgentNodeID>] = [:]
        var topLevelIDs: Set<AgentNodeID> = []

        func index(_ block: AgentBlock, owner: AgentNodeID) {
            owners[block.id] = [owner]
            block.children.forEach { index($0, owner: owner) }
        }
        for entry in document.entries {
            for block in entry.blocks {
                guard topLevelIDs.insert(block.id).inserted else {
                    throw UpdateError.duplicateTopLevelBlock(block.id)
                }
                rows.append(Row(block: block, role: entry.role))
                index(block, owner: block.id)
            }
            owners[entry.id] = []
        }
        return (rows, owners)
    }

    private func track(_ host: AgentBlockHostView) {
        let identity = ObjectIdentifier(host)
        if trackedHosts[identity] == nil { trackedHosts[identity] = WeakHost(host) }
    }

    // Deterministic fixture observations; no production owner depends on these.
    var qaSemanticRowCount: Int { rows.count }
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
        guard let oldRow = rowsByID[oldID] else { throw UpdateError.missingQARow(oldID) }
        guard let newRow = rowsByID[newID] else { throw UpdateError.missingQARow(newID) }
        let item = AgentTranscriptCollectionItem()
        _ = item.view
        let host = item.installHost(registry: registry, cache: measurementCache)
        track(host)
        do {
            try host.apply(block: oldRow.block, entryRole: oldRow.role, context: renderContext)
            item.prepareForReuse()
            try host.apply(block: newRow.block, entryRole: newRow.role, context: renderContext)
        } catch {
            throw UpdateError.renderer(error)
        }
        qaReuseWitnessItem = item
    }
    var qaCachedMeasurementCount: Int { measurementCache.cachedMeasurementCount }
    var qaLayoutPreparePassCount: Int { transcriptLayout.preparePassCount }
    var qaShowsJumpToLatest: Bool { !jumpToLatestButton.isHidden }
    var qaVisibleAccessibilityOrder: [AgentNodeID] {
        collectionView.visibleItems().compactMap { item -> (Int, AgentNodeID)? in
            guard let item = item as? AgentTranscriptCollectionItem,
                  let indexPath = collectionView.indexPath(for: item),
                  let id = item.hostView?.representedID else { return nil }
            return (indexPath.item, id)
        }.sorted { $0.0 < $1.0 }.map(\.1)
    }
}
