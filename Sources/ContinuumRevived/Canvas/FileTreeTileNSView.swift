import AppKit
import ContinuumRevivedAgentUI
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
    private let pathLabel = NSTextField(labelWithString: "")
    private let collapseButton = NSButton()
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

    /// P1.11. Four surfaces the tile used to paint as four independent `white:0.10`
    /// literals plus a `white:0.16` banner, now one `tileBody` and one
    /// `tileChrome`. `NSOutlineView.backgroundColor` and the two `NSTextField`
    /// colours are not layer colours, so they are read back per appearance by
    /// `runDocumentTileTokenCheck` rather than by the sentinel sweep.
    ///
    /// Row text is re-asserted by reloading: `outlineView(_:viewFor:)` resolves the
    /// row's token when the cell is built, so the visible rows have to be rebuilt
    /// for a flip to reach them.
    override func applyTokens() {
        super.applyTokens()
        let body = SurfaceToken.tileBody.color
        rootStack.layer?.backgroundColor = body.cgColor(in: self)
        stateContainer.layer?.backgroundColor = body.cgColor(in: self)
        outlineView.backgroundColor = body.nsColor(in: self)
        stateLabel.textColor = TextToken.textSecondary.color.nsColor(in: self)
        truncationBanner.backgroundColor = SurfaceToken.tileChrome.color.nsColor(in: self)
        truncationBanner.textColor = AccentToken.accentApproval.color.nsColor(in: self)
        pathLabel.textColor = TextToken.textSecondary.color.nsColor(in: self)
        collapseButton.contentTintColor = TextToken.textSecondary.color.nsColor(in: self)
        if outlineView.numberOfRows > 0 { outlineView.reloadData() }
    }

    override func acquireFocus(reason: FocusRequest) -> Bool {
        canvas?.bringToFront(tileId: tile.id)
        window?.makeFirstResponder(searchField)
        return true
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "f" {
            window?.makeFirstResponder(searchField)
            return true
        }
        return super.performKeyEquivalent(with: event)
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
        view.imageView?.image = icon(for: item)
        view.imageView?.contentTintColor = item.node.isDirectory
            ? AccentToken.accentWorking.color.nsColor(in: self)
            : TextToken.textSecondary.color.nsColor(in: self)
        // P1.11: an ignored path is de-emphasised metadata, so `textSecondary` —
        // Apple's `secondaryLabelColor` measures 2.07:1 on a card and 3.95:1 on
        // white and cannot clear AA by construction (P0.4 root cause 1).
        view.textField?.textColor = (item.node.isIgnored ? TextToken.textSecondary : TextToken.textPrimary)
            .color.nsColor(in: self)
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
        outlineView.reloadItem(item)
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
        outlineView.reloadItem(item)
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

    @objc private func openSelectedAsTile(_ sender: Any?) {
        guard let item = clickedOrSelectedItem(), !item.node.isDirectory else { return }
        onSpawnFile?(absolutePath(for: item.node.relativePath))
    }

    @objc private func collapseAll(_ sender: Any?) {
        suppressExpansionPersistence = true
        collapseVisibleItems()
        suppressExpansionPersistence = false
        fileTreeTile.expandedPaths.removeAll()
        persist()
    }

    private func buildContent() {
        rootStack.orientation = .vertical
        rootStack.spacing = 0
        rootStack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 10, right: 10)
        rootStack.wantsLayer = true

        pathLabel.stringValue = URL(fileURLWithPath: fileTreeTile.rootPath).lastPathComponent
        pathLabel.toolTip = fileTreeTile.rootPath
        pathLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        collapseButton.image = NSImage(systemSymbolName: "chevron.up.chevron.down", accessibilityDescription: "Collapse all folders")
        collapseButton.isBordered = false
        collapseButton.controlSize = .small
        collapseButton.target = self
        collapseButton.action = #selector(collapseAll(_:))
        collapseButton.toolTip = "Collapse all folders"
        let header = NSStackView(views: [pathLabel, collapseButton])
        header.orientation = .horizontal
        header.spacing = 6
        header.alignment = .centerY

        searchField.font = NSFont.token(.bodyMono)
        searchField.placeholderString = "Filter files (fuzzy)"
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false

        truncationBanner.font = NSFont.systemFont(ofSize: 12, weight: .medium)
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
        outlineView.rowHeight = 24
        outlineView.intercellSpacing = .zero
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
            title: "Open as File Tile",
            action: #selector(openSelectedAsTile(_:)),
            keyEquivalent: ""
        ))
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
        stateLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
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

        rootStack.addArrangedSubview(header)
        rootStack.addArrangedSubview(searchField)
        rootStack.setCustomSpacing(6, after: header)
        rootStack.setCustomSpacing(8, after: searchField)
        rootStack.addArrangedSubview(truncationBanner)
        rootStack.addArrangedSubview(scrollView)
        setContentView(rootStack)
        // `super.init` already ran `applyTokens()`, but the surfaces it paints only
        // gained `wantsLayer` here — so this is the first call that reaches them.
        applyTokens()
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

    /// QA (P1.11): ingest a canned snapshot so a check can render real ROWS without a
    /// filesystem. Added because the negative test showed the gate could not see
    /// `outlineView(_:viewFor:)`'s row and badge colours at all — the only fixture
    /// available took the recoverable-error branch, which draws no rows.
    func applySnapshotForQA(_ snapshot: FileTreeSnapshot) {
        apply(snapshot)
        outlineView.layoutSubtreeIfNeeded()
    }

    private func apply(_ snapshot: FileTreeSnapshot) {
        latestSnapshot = snapshot
        pathLabel.stringValue = "\(snapshot.root.lastPathComponent)  ·  \(snapshot.nodes.count)"
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

    private func icon(for item: FileTreeOutlineItem) -> NSImage? {
        if item.node.isDirectory {
            return NSImage(
                systemSymbolName: outlineView.isItemExpanded(item) ? "folder.fill" : "folder",
                accessibilityDescription: "Folder"
            )
        }
        let ext = URL(fileURLWithPath: item.node.displayName).pathExtension.lowercased()
        let symbol: String
        switch ext {
        case "swift", "js", "jsx", "ts", "tsx", "go", "rs", "c", "h", "cpp", "hpp", "cs", "py", "sh":
            symbol = "chevron.left.forwardslash.chevron.right"
        case "html", "css", "scss": symbol = "globe"
        case "json", "yaml", "yml", "toml": symbol = "curlybraces"
        case "md", "markdown", "txt", "rtf": symbol = "doc.text"
        case "png", "jpg", "jpeg", "gif", "webp", "svg": symbol = "photo"
        default: symbol = "doc"
        }
        return NSImage(systemSymbolName: symbol, accessibilityDescription: "File")
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

    /// P1.11: the six git-status badges are `AccentToken`s, matching the diff
    /// renderer's mapping so a modified file reads the same in the tree as in the
    /// diff. Two defects went with the literals: they were `calibratedRed:`, whose
    /// generic RGB space renders OFF the sRGB luminance every gate measures
    /// (ticket 87 watch-out #1), and `untracked` was `secondaryLabelColor`, which
    /// cannot clear AA on any surface.
    private func badgeToken(for gitStatus: FileTreeGitStatus) -> AccentToken? {
        switch gitStatus {
        case .modified: return .accentApproval
        case .added: return .accentDone
        case .deleted: return .accentFailed
        case .renamed: return .accentWorking
        case .conflicted: return .accentInput
        // Untracked is the one status that asks nothing of you, which is the same
        // read `StatusChipPresenter` gives idle — muted, not an accent.
        case .untracked: return nil
        }
    }

    private func badgeColor(for gitStatus: FileTreeGitStatus?) -> NSColor {
        guard let gitStatus else { return .clear }
        guard let token = badgeToken(for: gitStatus) else {
            return TextToken.textSecondary.color.nsColor(in: self)
        }
        return token.color.nsColor(in: self)
    }

    private func makeCellView() -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = Self.rowIdentifier
        let text = NSTextField(labelWithString: "")
        text.font = NSFont.token(.bodyMono)
        text.lineBreakMode = .byTruncatingTail
        text.translatesAutoresizingMaskIntoConstraints = false
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let badge = NSTextField(labelWithString: "")
        badge.tag = 1
        badge.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
        badge.alignment = .center
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)
        let icon = NSImageView()
        icon.imageScaling = .scaleProportionallyDown
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        icon.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(icon)
        cell.addSubview(text)
        cell.addSubview(badge)
        cell.textField = text
        cell.imageView = icon
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 3),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
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
