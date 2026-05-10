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

    private let rootStack = NSStackView()
    private let searchField = NSSearchField()
    private let scrollView = NSScrollView()
    private let outlineView = FileTreeOutlineView()
    private let stateContainer = NSView()
    private let stateLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()

    var onPersist: ((FileTreeTile) -> Void)?
    var onSpawnFile: ((String) -> Void)?
    var onOpenFile: ((String) -> Void)?

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
            ignoreList: Set(fileTreeTile.ignoredNames)
        )
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

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
        return view
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard let item = selectedItem() else {
            return
        }
        fileTreeTile.selectedPath = item.node.relativePath
        persist()
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let item = notification.userInfo?["NSObject"] as? FileTreeOutlineItem else {
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

    private func commitSearch() {
        fileTreeTile.searchQuery = searchField.stringValue
        persist()
        if let latestSnapshot {
            apply(latestSnapshot)
        }
    }

    private func apply(_ snapshot: FileTreeSnapshot) {
        latestSnapshot = snapshot
        outlineModel = FileTreeOutlineModel(snapshot: snapshot, query: fileTreeTile.searchQuery)
        outlineView.reloadData()
        restoreExpansion()
        restoreSelection()

        if outlineModel.rootItems.isEmpty {
            showEmpty()
        } else {
            showOutline()
        }
    }

    private func restoreExpansion() {
        let expanded = Set(fileTreeTile.expandedPaths)
        expandMatchingItems(in: nil, expanded: expanded)
    }

    private func expandMatchingItems(in parent: FileTreeOutlineItem?, expanded: Set<String>) {
        for child in outlineModel.children(of: parent) {
            if expanded.contains(child.node.relativePath) {
                outlineView.expandItem(child)
            }
            expandMatchingItems(in: child, expanded: expanded)
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
        stateLabel.stringValue = "Scanning..."
        spinner.startAnimation(nil)
        showStateView()
    }

    private func showEmpty() {
        stateLabel.stringValue = "No files in \(URL(fileURLWithPath: fileTreeTile.rootPath).lastPathComponent)"
        spinner.stopAnimation(nil)
        showStateView()
    }

    private func showError(_ error: Error) {
        stateLabel.stringValue = "Could not read directory: \(error.localizedDescription)"
        spinner.stopAnimation(nil)
        showStateView()
    }

    private func showOutline() {
        spinner.stopAnimation(nil)
        replaceBody(with: scrollView)
    }

    private func showStateView() {
        replaceBody(with: stateContainer)
    }

    private func replaceBody(with view: NSView) {
        if rootStack.arrangedSubviews.count == 2, rootStack.arrangedSubviews[1] === view {
            return
        }
        if rootStack.arrangedSubviews.count == 2 {
            let oldView = rootStack.arrangedSubviews[1]
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
        let prefix = item.node.isDirectory ? "> " : "  "
        return prefix + item.node.displayName
    }

    private func makeCellView() -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = Self.rowIdentifier
        let text = NSTextField(labelWithString: "")
        text.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        text.lineBreakMode = .byTruncatingTail
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(text)
        cell.textField = text
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    private func persist() {
        onPersist?(fileTreeTile)
    }
}

@MainActor
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
