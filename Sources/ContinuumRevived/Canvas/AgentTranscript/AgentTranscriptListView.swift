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

/// Reusable semantic transcript fixture. The compatibility transcript remains the
/// live tile path; this list is exercised behind the internal fixture flag until
/// the later migration ticket owns visibility and scroll behavior.
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

    static let fixtureEnvironmentKey = "CONTINUUM_AGENT_TRANSCRIPT_COLLECTION_FIXTURE"
    static var isFixtureEnabled: Bool {
        ProcessInfo.processInfo.environment[fixtureEnvironmentKey] == "1"
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
    private var renderingError: Error?
    private var renderContext: AgentRenderContext

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
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func configureCollectionView() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        collectionView.collectionViewLayout = transcriptLayout
        collectionView.isSelectable = true
        collectionView.register(
            AgentTranscriptCollectionItem.self,
            forItemWithIdentifier: NSUserInterfaceItemIdentifier("AgentTranscriptCollectionItem")
        )
        scrollView.documentView = collectionView
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
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

    /// Applies one reducer result. Diffable snapshots preserve item identity for
    /// unchanged IDs; reconfiguration is limited to rows touched by the patch.
    /// There is intentionally no reloadData path after (or before) initial load.
    func apply(document: AgentDocument, patch: AgentDocumentPatch) throws {
        guard document.version == patch.toVersion else {
            throw UpdateError.documentPatchMismatch(document: document.version, patch: patch.toVersion)
        }
        if let appliedVersion, patch.fromVersion != appliedVersion {
            throw UpdateError.versionMismatch(expected: appliedVersion, actual: patch.fromVersion)
        }

        let flattened = try Self.flatten(document)
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

        let changedNodeIDs = Set(patch.updated + patch.moved)
        var changedTopLevelIDs = Set(changedNodeIDs.flatMap { topLevelIDsByNodeID[$0] ?? [] })
        // Entry revisions also advance when one child changes. Do not fan that
        // bookkeeping update out to every sibling; only a role change affects all
        // renderer families in the entry.
        changedTopLevelIDs.formUnion(rows.compactMap { row in
            guard let old = oldRowsByID[row.block.id], old.role != row.role else { return nil }
            return row.block.id
        })
        let survivingChanged = changedTopLevelIDs.intersection(newIDs)
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
}
