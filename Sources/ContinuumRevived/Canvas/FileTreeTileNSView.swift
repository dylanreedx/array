import AppKit
import ContinuumRevivedCore
import ContinuumRevivedFileTree
import Foundation

@MainActor
final class FileTreeTileNSView: TileNSView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSSearchFieldDelegate {
    private static let rowIdentifier = NSUserInterfaceItemIdentifier("FileTreeRow")
    private static let outlineColumnIdentifier = NSUserInterfaceItemIdentifier("FileTreeColumn")

    private var fileTreeTile: FileTreeTile
    private let viewModel: FileTreeViewModel
    private var outlineModel = FileTreeOutlineModel(snapshot: FileTreeSnapshot(root: URL(fileURLWithPath: "/"), nodes: []), query: "")
    private var latestSnapshot: FileTreeSnapshot?
    private var searchDebounce: Timer?
    private var suppressExpansionPersistence = false

    private let rootStack = NSStackView()
    private let searchField = NSSearchField()
    private let truncationBanner = NSTextField(labelWithString: "")
    private let scrollView = NSScrollView()
    private let outlineView = FileTreeOutlineView()
    private let stateContainer = NSView()
    private let stateLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()

    var onPersist: ((FileTreeTile) -> Void)?
    var onSpawnFile: ((String) -> Void)?
    var onOpenFile: ((String) -> Void)?
    var currentFileTreeTile: FileTreeTile {
        flushPendingSearchForDehydrate()
        return fileTreeTile
    }
    var currentSnapshot: FileTreeSnapshot? { latestSnapshot }
    private(set) var isRecoverableError = false
    private(set) var recoverableErrorMessage: String?

    init(tile: Tile, fileTreeTile: FileTreeTile, viewModel: FileTreeViewModel = FileTreeViewModel()) {
        self.fileTreeTile = fileTreeTile
        self.viewModel = viewModel
        super.init(tile: tile)
        buildContent()
        configureViewModel()
        applySearchText(fileTreeTile.searchQuery)
        showLoading()
        viewModel.start(
            rootPath: fileTreeTile.rootPath,
            ignoreList: Set(fileTreeTile.ignoredNames),
            gitBadgeMode: fileTreeTile.gitBadges
        )
    }

    init(tile: Tile, fileTreeTile: FileTreeTile, recoverableErrorMessage: String) {
        self.fileTreeTile = fileTreeTile
        self.viewModel = FileTreeViewModel()
        self.isRecoverableError = true
        self.recoverableErrorMessage = recoverableErrorMessage
        super.init(tile: tile)
        buildContent()
        applySearchText(fileTreeTile.searchQuery)
        showRecoverableError(recoverableErrorMessage)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func acquireFocus(reason: FocusRequest) -> Bool {
        canvas?.bringToFront(tileId: tile.id)
        window?.makeFirstResponder(searchField)
        return true
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        outlineModel.children(of: item as? FileTreeOutlineItem).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        outlineModel.children(of: item as? FileTreeOutlineItem)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let item = item as? FileTreeOutlineItem else {
            return false
        }
        return outlineModel.isExpandable(item)
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        viewFor tableColumn: NSTableColumn?,
        item: Any
    ) -> NSView? {
        guard let item = item as? FileTreeOutlineItem else {
            return nil
        }
        let view = outlineView.makeView(withIdentifier: Self.rowIdentifier, owner: self) as? NSTableCellView
            ?? makeCellView()
        view.textField?.stringValue = rowTitle(for: item)
        view.textField?.textColor = item.node.isIgnored
            ? NSColor.secondaryLabelColor
            : NSColor(white: 0.88, alpha: 1.0)
        if let badge = view.viewWithTag(1) as? NSTextField {
            badge.stringValue = badgeTitle(for: item.node)
            badge.textColor = badgeColor(for: item.node.gitStatus)
            badge.isHidden = item.node.isDirectory || item.node.gitStatus == nil
        }
        return view
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard let item = selectedItem() else {
            return
        }
        fileTreeTile.selectedPath = item.node.relativePath
        persist()
    }

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let item = item as? FileTreeOutlineItem,
              !item.node.isDirectory else {
            return nil
        }
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(
            URL(fileURLWithPath: absolutePath(for: item.node.relativePath)).absoluteString,
            forType: .fileURL
        )
        return pasteboardItem
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        draggingSession session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let item = notification.userInfo?["NSObject"] as? FileTreeOutlineItem else {
            return
        }
        guard shouldPersistExpansionChanges else {
            return
        }
        if !fileTreeTile.expandedPaths.contains(item.node.relativePath) {
            fileTreeTile.expandedPaths.append(item.node.relativePath)
            persist()
        }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard let item = notification.userInfo?["NSObject"] as? FileTreeOutlineItem else {
            return
        }
        guard shouldPersistExpansionChanges else {
            return
        }
        fileTreeTile.expandedPaths.removeAll { $0 == item.node.relativePath }
        persist()
    }

    func controlTextDidChange(_ obj: Notification) {
        searchDebounce?.invalidate()
        searchDebounce = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.commitSearch()
            }
        }
    }

    @objc private func activateSelectedRow(_ sender: Any?) {
        guard let item = selectedItem() else {
            return
        }
        if item.node.isDirectory {
            if outlineView.isItemExpanded(item) {
                outlineView.collapseItem(item)
            } else {
                outlineView.expandItem(item)
            }
            return
        }
        onSpawnFile?(absolutePath(for: item.node.relativePath))
    }

    @objc private func openSelectedInEditor(_ sender: Any?) {
        guard let item = clickedOrSelectedItem(), !item.node.isDirectory else {
            return
        }
        onOpenFile?(absolutePath(for: item.node.relativePath))
    }

    private func buildContent() {
        rootStack.orientation = .vertical
        rootStack.spacing = 0
        rootStack.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 8, right: 8)
        rootStack.wantsLayer = true
        rootStack.layer?.backgroundColor = NSColor(white: 0.10, alpha: 1.0).cgColor

        searchField.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        searchField.placeholderString = "Search files"
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false

        truncationBanner.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        truncationBanner.textColor = NSColor(calibratedRed: 0.96, green: 0.80, blue: 0.45, alpha: 1.0)
        truncationBanner.backgroundColor = NSColor(white: 0.16, alpha: 1.0)
        truncationBanner.drawsBackground = true
        truncationBanner.isBezeled = false
        truncationBanner.isEditable = false
        truncationBanner.maximumNumberOfLines = 2
        truncationBanner.lineBreakMode = .byWordWrapping
        truncationBanner.isHidden = true

        let column = NSTableColumn(identifier: Self.outlineColumnIdentifier)
        column.title = "Files"
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.rowHeight = 22
        outlineView.intercellSpacing = NSSize(width: 0, height: 2)
        outlineView.backgroundColor = NSColor(white: 0.10, alpha: 1.0)
        outlineView.selectionHighlightStyle = .regular
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.doubleAction = #selector(activateSelectedRow(_:))
        outlineView.onReturn = { [weak self] in self?.activateSelectedRow(nil) }
        outlineView.registerForDraggedTypes([.fileURL])
        outlineView.setDraggingSourceOperationMask(.copy, forLocal: false)

        let menu = NSMenu()
        menu.addItem(NSMenuItem(
            title: "Open in Preferred Editor",
            action: #selector(openSelectedInEditor(_:)),
            keyEquivalent: ""
        ))
        menu.items.forEach { $0.target = self }
        outlineView.menu = menu

        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.hasHorizontalScroller = true
        scrollView.drawsBackground = false
        scrollView.documentView = outlineView

        stateContainer.wantsLayer = true
        stateContainer.layer?.backgroundColor = NSColor(white: 0.10, alpha: 1.0).cgColor
        stateLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        stateLabel.textColor = NSColor(white: 0.82, alpha: 1.0)
        stateLabel.alignment = .center
        stateLabel.maximumNumberOfLines = 0
        stateLabel.lineBreakMode = .byWordWrapping
        spinner.style = .spinning
        spinner.controlSize = .small

        let stateStack = NSStackView(views: [spinner, stateLabel])
        stateStack.orientation = .vertical
        stateStack.spacing = 8
        stateStack.alignment = .centerX
        stateStack.translatesAutoresizingMaskIntoConstraints = false
        stateContainer.addSubview(stateStack)
        NSLayoutConstraint.activate([
            stateStack.centerXAnchor.constraint(equalTo: stateContainer.centerXAnchor),
            stateStack.centerYAnchor.constraint(equalTo: stateContainer.centerYAnchor),
            stateStack.leadingAnchor.constraint(greaterThanOrEqualTo: stateContainer.leadingAnchor, constant: 16),
            stateStack.trailingAnchor.constraint(lessThanOrEqualTo: stateContainer.trailingAnchor, constant: -16),
            searchField.heightAnchor.constraint(equalToConstant: 28)
        ])

        rootStack.addArrangedSubview(searchField)
        rootStack.addArrangedSubview(truncationBanner)
        rootStack.addArrangedSubview(scrollView)
        setContentView(rootStack)
    }

    private func configureViewModel() {
        viewModel.onSnapshotChange = { [weak self] snapshot in
            self?.apply(snapshot)
        }
        viewModel.onError = { [weak self] error in
            self?.showError(error)
        }
    }

    private func applySearchText(_ query: String) {
        searchField.stringValue = query
    }

    func flushPendingSearchForDehydrate() {
        searchDebounce?.invalidate()
        searchDebounce = nil
        let liveQuery = searchField.stringValue
        guard fileTreeTile.searchQuery != liveQuery else {
            return
        }
        fileTreeTile.searchQuery = liveQuery
        if let latestSnapshot {
            apply(latestSnapshot)
        }
    }

    private func commitSearch() {
        searchDebounce?.invalidate()
        searchDebounce = nil
        fileTreeTile.searchQuery = searchField.stringValue
        persist()
        if let latestSnapshot {
            apply(latestSnapshot)
        }
    }

    private func apply(_ snapshot: FileTreeSnapshot) {
        latestSnapshot = snapshot
        outlineModel = FileTreeOutlineModel(snapshot: snapshot, query: fileTreeTile.searchQuery)
        suppressExpansionPersistence = true
        outlineView.reloadData()
        collapseVisibleItems()
        restoreExpansion()
        suppressExpansionPersistence = false
        restoreSelection()

        if snapshot.isTruncated {
            showTruncatedStatus(snapshot)
            showOutline()
        } else if outlineModel.rootItems.isEmpty {
            showEmpty()
        } else {
            showOutline()
        }
    }

    private var isSearchActive: Bool {
        !fileTreeTile.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var shouldPersistExpansionChanges: Bool {
        !suppressExpansionPersistence && !isSearchActive
    }

    private func restoreExpansion() {
        let expanded = Set(fileTreeTile.expandedPaths)
        expandMatchingItems(in: nil, expanded: expanded, revealAll: isSearchActive)
    }

    private func collapseVisibleItems() {
        guard outlineView.numberOfRows > 0 else {
            return
        }
        for row in stride(from: outlineView.numberOfRows - 1, through: 0, by: -1) {
            guard let item = outlineView.item(atRow: row) as? FileTreeOutlineItem,
                  outlineView.isItemExpanded(item) else {
                continue
            }
            outlineView.collapseItem(item)
        }
    }

    private func expandMatchingItems(in parent: FileTreeOutlineItem?, expanded: Set<String>, revealAll: Bool) {
        for child in outlineModel.children(of: parent) {
            if revealAll || expanded.contains(child.node.relativePath) {
                outlineView.expandItem(child)
            }
            expandMatchingItems(in: child, expanded: expanded, revealAll: revealAll)
        }
    }

    private func restoreSelection() {
        guard let selectedPath = fileTreeTile.selectedPath,
              let row = row(for: selectedPath),
              row >= 0 else {
            return
        }
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outlineView.scrollRowToVisible(row)
    }

    private func row(for relativePath: String) -> Int? {
        for row in 0..<outlineView.numberOfRows {
            guard let item = outlineView.item(atRow: row) as? FileTreeOutlineItem,
                  item.node.relativePath == relativePath else {
                continue
            }
            return row
        }
        return nil
    }

    private func showLoading() {
        hideTruncatedStatus()
        stateLabel.stringValue = "Scanning..."
        spinner.startAnimation(nil)
        showStateView()
    }

    private func showEmpty() {
        hideTruncatedStatus()
        stateLabel.stringValue = "No files in \(URL(fileURLWithPath: fileTreeTile.rootPath).lastPathComponent)"
        spinner.stopAnimation(nil)
        showStateView()
    }

    private func showError(_ error: Error) {
        hideTruncatedStatus()
        stateLabel.stringValue = "Could not read directory: \(error.localizedDescription)"
        spinner.stopAnimation(nil)
        showStateView()
    }

    private func showRecoverableError(_ message: String) {
        hideTruncatedStatus()
        stateLabel.stringValue = message
        spinner.stopAnimation(nil)
        showStateView()
    }

    private func showTruncatedStatus(_ snapshot: FileTreeSnapshot) {
        let limit = snapshot.nodeLimit ?? snapshot.nodes.count
        truncationBanner.stringValue = "Showing first \(snapshot.nodes.count) items. Scan truncated at \(limit) items."
        truncationBanner.isHidden = false
    }

    private func hideTruncatedStatus() {
        truncationBanner.stringValue = ""
        truncationBanner.isHidden = true
    }

    private func showOutline() {
        spinner.stopAnimation(nil)
        replaceBody(with: scrollView)
    }

    private func showStateView() {
        replaceBody(with: stateContainer)
    }

    private func replaceBody(with view: NSView) {
        if rootStack.arrangedSubviews.last === view {
            return
        }
        if let oldView = rootStack.arrangedSubviews.last, oldView !== searchField, oldView !== truncationBanner {
            rootStack.removeArrangedSubview(oldView)
            oldView.removeFromSuperview()
        }
        rootStack.addArrangedSubview(view)
    }

    private func selectedItem() -> FileTreeOutlineItem? {
        let row = outlineView.selectedRow
        guard row >= 0 else {
            return nil
        }
        return outlineView.item(atRow: row) as? FileTreeOutlineItem
    }

    private func clickedOrSelectedItem() -> FileTreeOutlineItem? {
        let row = outlineView.clickedRow >= 0 ? outlineView.clickedRow : outlineView.selectedRow
        guard row >= 0 else {
            return nil
        }
        return outlineView.item(atRow: row) as? FileTreeOutlineItem
    }

    private func absolutePath(for relativePath: String) -> String {
        FileTreeOutlineModel.absolutePath(
            for: relativePath,
            root: URL(fileURLWithPath: fileTreeTile.rootPath, isDirectory: true)
        )
    }

    private func rowTitle(for item: FileTreeOutlineItem) -> String {
        // The NSOutlineView disclosure triangle already marks expandable
        // directories; a "> " text prefix duplicated it as a second, dim chevron.
        item.node.displayName
    }

    private func badgeTitle(for node: FileTreeNode) -> String {
        guard let gitStatus = node.gitStatus else {
            return ""
        }
        switch gitStatus {
        case .modified:
            return "M"
        case .added:
            return "A"
        case .deleted:
            return "D"
        case .renamed:
            return "R"
        case .untracked:
            return "?"
        case .conflicted:
            return "!"
        }
    }

    private func badgeColor(for gitStatus: FileTreeGitStatus?) -> NSColor {
        guard let gitStatus else {
            return .clear
        }
        switch gitStatus {
        case .modified:
            return NSColor(calibratedRed: 0.95, green: 0.68, blue: 0.28, alpha: 1.0)
        case .added:
            return NSColor(calibratedRed: 0.32, green: 0.78, blue: 0.45, alpha: 1.0)
        case .deleted:
            return NSColor(calibratedRed: 0.90, green: 0.34, blue: 0.34, alpha: 1.0)
        case .renamed:
            return NSColor(calibratedRed: 0.36, green: 0.62, blue: 0.96, alpha: 1.0)
        case .untracked:
            return NSColor.secondaryLabelColor
        case .conflicted:
            return NSColor(calibratedRed: 0.72, green: 0.44, blue: 0.95, alpha: 1.0)
        }
    }

    private func makeCellView() -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = Self.rowIdentifier
        let text = NSTextField(labelWithString: "")
        text.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        text.lineBreakMode = .byTruncatingTail
        text.translatesAutoresizingMaskIntoConstraints = false
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let badge = NSTextField(labelWithString: "")
        badge.tag = 1
        badge.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
        badge.alignment = .center
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)
        cell.addSubview(text)
        cell.addSubview(badge)
        cell.textField = text
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            text.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor, constant: -6),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            badge.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            badge.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: 14)
        ])
        return cell
    }

    private func persist() {
        onPersist?(fileTreeTile)
    }

    static func runTruncatedOutlineSelfCheck() throws -> [String: Any] {
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

        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("continuum-file-tree-truncated-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let tileId = UUID(uuidString: "00000000-0000-0000-0000-000000001122")!
        let tile = Tile(
            id: tileId,
            kind: .fileTree,
            title: "Files",
            frame: TileFrame(x: 0, y: 0, width: 420, height: 360),
            zPosition: .fromLegacyRank(1),
            runtimeRef: nil,
            metadata: TileMetadata(filePath: root.path)
        )
        let fileTreeTile = FileTreeTile(
            tileId: tileId,
            rootPath: root.path,
            expandedPaths: ["Sources"],
            selectedPath: nil,
            searchQuery: "",
            ignoredNames: [],
            gitBadges: .off
        )
        let view = FileTreeTileNSView(tile: tile, fileTreeTile: fileTreeTile, viewModel: FileTreeViewModel())
        let snapshot = FileTreeSnapshot(root: root, nodes: [
            FileTreeNode(relativePath: "Sources", displayName: "Sources", isDirectory: true, childCount: 1, isIgnored: false, gitStatus: nil),
            FileTreeNode(relativePath: "Sources/App.swift", displayName: "App.swift", isDirectory: false, childCount: 0, isIgnored: false, gitStatus: nil)
        ], isTruncated: true, nodeLimit: 2)
        view.apply(snapshot)
        let visiblePaths = (0..<view.outlineView.numberOfRows).compactMap { row in
            (view.outlineView.item(atRow: row) as? FileTreeOutlineItem)?.node.relativePath
        }

        try expect(view.truncationBanner.isHidden == false, "truncated banner should be visible")
        try expect(view.rootStack.arrangedSubviews.last === view.scrollView, "truncated state should keep outline visible")
        try expect(visiblePaths.contains("Sources"), "truncated outline should show capped root row")
        try expect(visiblePaths.contains("Sources/App.swift"), "truncated outline should show capped child row")

        return [
            "check": "file-tree-truncated-outline",
            "bannerVisible": !view.truncationBanner.isHidden,
            "bannerText": view.truncationBanner.stringValue,
            "bodyIsOutline": view.rootStack.arrangedSubviews.last === view.scrollView,
            "visiblePaths": visiblePaths
        ]
    }

    static func runDebounceFlushSelfCheck() throws -> [String: Any] {
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

        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("continuum-file-tree-debounce-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let tileId = UUID(uuidString: "00000000-0000-0000-0000-000000001120")!
        let tile = Tile(
            id: tileId,
            kind: .fileTree,
            title: "Files",
            frame: TileFrame(x: 0, y: 0, width: 420, height: 360),
            zPosition: .fromLegacyRank(1),
            runtimeRef: nil,
            metadata: TileMetadata(filePath: root.path)
        )
        let fileTreeTile = FileTreeTile(
            tileId: tileId,
            rootPath: root.path,
            expandedPaths: [],
            selectedPath: nil,
            searchQuery: "",
            ignoredNames: [],
            gitBadges: .off
        )
        let view = FileTreeTileNSView(tile: tile, fileTreeTile: fileTreeTile, viewModel: FileTreeViewModel())
        let typedQuery = "CON120-needle-\(UUID().uuidString)"
        let start = ContinuousClock.now
        view.searchField.stringValue = typedQuery
        view.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: view.searchField))
        let dehydrated = view.currentFileTreeTile
        let store = ProjectStore(projectRoot: root)
        try store.saveFileTreeState(FileTreeState(tiles: [dehydrated]))
        let reloaded = try store.loadFileTreeState().tiles.first { $0.tileId == tileId }
        let elapsed = start.duration(to: ContinuousClock.now)
        let elapsedMs = Double(elapsed.components.seconds) * 1000.0 + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000.0

        try expect(elapsedMs < 200.0, "dehydrate should run before debounce interval")
        try expect(dehydrated.searchQuery == typedQuery, "dehydrate should flush live search text")
        try expect(reloaded?.searchQuery == typedQuery, "dehydrated search text should persist to and reload from sidecar")
        try expect(view.searchDebounce == nil, "dehydrate should invalidate pending debounce timer")

        return [
            "check": "file-tree-debounce-flush",
            "debounceMs": 200,
            "elapsedBeforeFlushMs": elapsedMs,
            "typedQuery": typedQuery,
            "persistedQuery": dehydrated.searchQuery,
            "reloadedQuery": reloaded?.searchQuery ?? "",
            "timerInvalidated": true
        ]
    }

    static func runSearchVisibilitySelfCheck() throws -> [String: Any] {
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

        let fileManager = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("continuum-file-tree-search-visibility-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let tile = Tile(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000F01")!,
            kind: .fileTree,
            title: "Files",
            frame: TileFrame(x: 0, y: 0, width: 420, height: 360),
            zPosition: .fromLegacyRank(1),
            runtimeRef: nil,
            metadata: TileMetadata()
        )
        let snapshot = FileTreeSnapshot(root: root, nodes: [
            FileTreeNode(relativePath: "Sources", displayName: "Sources", isDirectory: true, childCount: 2, isIgnored: false, gitStatus: nil),
            FileTreeNode(relativePath: "Sources/Deep", displayName: "Deep", isDirectory: true, childCount: 2, isIgnored: false, gitStatus: nil),
            FileTreeNode(relativePath: "Sources/Deep/Needle.swift", displayName: "Needle.swift", isDirectory: false, childCount: 0, isIgnored: false, gitStatus: nil),
            FileTreeNode(relativePath: "Sources/Deep/Other.swift", displayName: "Other.swift", isDirectory: false, childCount: 0, isIgnored: false, gitStatus: nil),
            FileTreeNode(relativePath: "Docs", displayName: "Docs", isDirectory: true, childCount: 1, isIgnored: false, gitStatus: nil),
            FileTreeNode(relativePath: "Docs/Guide.md", displayName: "Guide.md", isDirectory: false, childCount: 0, isIgnored: false, gitStatus: nil)
        ])

        func makeView(expandedPaths: [String], query: String, recorder: FileTreeSearchVisibilityPersistRecorder) -> FileTreeTileNSView {
            let fileTreeTile = FileTreeTile(
                tileId: tile.id,
                rootPath: root.path,
                expandedPaths: expandedPaths,
                selectedPath: nil,
                searchQuery: query,
                ignoredNames: [],
                gitBadges: .off
            )
            let view = FileTreeTileNSView(tile: tile, fileTreeTile: fileTreeTile, viewModel: FileTreeViewModel())
            view.frame = NSRect(x: 0, y: 0, width: 420, height: 360)
            view.onPersist = { tile in recorder.expandedPaths.append(tile.expandedPaths) }
            view.layoutSubtreeIfNeeded()
            return view
        }

        func visiblePaths(in view: FileTreeTileNSView) -> [String] {
            (0..<view.outlineView.numberOfRows).compactMap { row in
                (view.outlineView.item(atRow: row) as? FileTreeOutlineItem)?.node.relativePath
            }
        }

        func isExpanded(_ path: String, in view: FileTreeTileNSView) -> Bool {
            for row in 0..<view.outlineView.numberOfRows {
                guard let item = view.outlineView.item(atRow: row) as? FileTreeOutlineItem,
                      item.node.relativePath == path else {
                    continue
                }
                return view.outlineView.isItemExpanded(item)
            }
            return false
        }

        func row(_ name: String, view: FileTreeTileNSView, persisted: [[String]]) -> [String: Any] {
            [
                "scenario": name,
                "query": view.currentFileTreeTile.searchQuery,
                "visiblePaths": visiblePaths(in: view),
                "expandedPaths": view.currentFileTreeTile.expandedPaths,
                "isSourcesExpanded": isExpanded("Sources", in: view),
                "isDeepExpanded": isExpanded("Sources/Deep", in: view),
                "persistedCallCount": persisted.count,
                "persistedExpandedPaths": persisted
            ]
        }

        var table: [[String: Any]] = []

        let collapsedRecorder = FileTreeSearchVisibilityPersistRecorder()
        let collapsedView = makeView(expandedPaths: [], query: "", recorder: collapsedRecorder)
        collapsedView.apply(snapshot)
        try expect(visiblePaths(in: collapsedView) == ["Sources", "Docs"], "empty collapsed tree should show only root rows")
        try expect(collapsedView.currentFileTreeTile.expandedPaths.isEmpty, "empty collapsed tree should keep expandedPaths empty")
        table.append(row("empty-collapsed", view: collapsedView, persisted: collapsedRecorder.expandedPaths))

        collapsedView.fileTreeTile.searchQuery = "Needle.swift"
        collapsedView.applySearchText("Needle.swift")
        collapsedView.apply(snapshot)
        let searchCollapsedPaths = visiblePaths(in: collapsedView)
        try expect(searchCollapsedPaths.contains("Sources"), "search should keep matching file's root ancestor visible")
        try expect(searchCollapsedPaths.contains("Sources/Deep"), "search should reveal collapsed intermediate ancestor")
        try expect(searchCollapsedPaths.contains("Sources/Deep/Needle.swift"), "search should show matched descendant file as an outline row")
        try expect(!searchCollapsedPaths.contains("Docs"), "search should hide unrelated roots")
        try expect(!searchCollapsedPaths.contains("Sources/Deep/Other.swift"), "search should hide unrelated siblings")
        try expect(collapsedView.currentFileTreeTile.expandedPaths.isEmpty, "search reveal should not append collapsed ancestors to expandedPaths")
        try expect(collapsedRecorder.expandedPaths.isEmpty, "search reveal should not persist expansion changes")
        table.append(row("search-collapsed", view: collapsedView, persisted: collapsedRecorder.expandedPaths))

        collapsedView.fileTreeTile.searchQuery = ""
        collapsedView.applySearchText("")
        collapsedView.apply(snapshot)
        try expect(visiblePaths(in: collapsedView) == ["Sources", "Docs"], "clearing search should restore collapsed root-only visibility")
        try expect(collapsedView.currentFileTreeTile.expandedPaths.isEmpty, "clearing search should keep collapsed expandedPaths empty")
        table.append(row("clear-restores-collapsed", view: collapsedView, persisted: collapsedRecorder.expandedPaths))

        let expandedRecorder = FileTreeSearchVisibilityPersistRecorder()
        let expandedView = makeView(expandedPaths: ["Sources"], query: "", recorder: expandedRecorder)
        expandedView.apply(snapshot)
        try expect(visiblePaths(in: expandedView) == ["Sources", "Sources/Deep", "Docs"], "empty persisted-expanded tree should reveal only persisted ancestors")
        try expect(expandedView.currentFileTreeTile.expandedPaths == ["Sources"], "empty persisted-expanded tree should preserve expandedPaths")
        table.append(row("empty-persisted-expanded", view: expandedView, persisted: expandedRecorder.expandedPaths))

        expandedView.fileTreeTile.searchQuery = "needle.swift"
        expandedView.applySearchText("needle.swift")
        expandedView.apply(snapshot)
        let searchExpandedPaths = visiblePaths(in: expandedView)
        try expect(searchExpandedPaths.contains("Sources/Deep/Needle.swift"), "case-insensitive search should show matched descendant file")
        try expect(!searchExpandedPaths.contains("Docs"), "search from persisted-expanded state should hide unrelated roots")
        try expect(expandedView.currentFileTreeTile.expandedPaths == ["Sources"], "search should preserve pre-existing expandedPaths exactly")
        try expect(expandedRecorder.expandedPaths.isEmpty, "search should not persist transient expansion for pre-expanded state")
        table.append(row("search-preserves-persisted", view: expandedView, persisted: expandedRecorder.expandedPaths))

        expandedView.fileTreeTile.searchQuery = ""
        expandedView.applySearchText("")
        expandedView.apply(snapshot)
        try expect(visiblePaths(in: expandedView) == ["Sources", "Sources/Deep", "Docs"], "clearing search should restore persisted expansion visibility")
        try expect(!isExpanded("Sources/Deep", in: expandedView), "clearing search should collapse search-expanded intermediate ancestor")
        try expect(expandedView.currentFileTreeTile.expandedPaths == ["Sources"], "clearing search should preserve persisted expandedPaths exactly")
        table.append(row("clear-restores-persisted", view: expandedView, persisted: expandedRecorder.expandedPaths))

        return [
            "check": "file-tree-search-visibility",
            "table": table
        ]
    }
}

@MainActor
private final class FileTreeSearchVisibilityPersistRecorder {
    var expandedPaths: [[String]] = []
}

private final class FileTreeOutlineView: NSOutlineView {
    var onReturn: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 0x24 {
            onReturn?()
            return
        }
        super.keyDown(with: event)
    }
}
