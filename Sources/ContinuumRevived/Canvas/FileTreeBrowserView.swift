import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import ContinuumRevivedFileTree

/// Reusable project navigator used by editor tiles. It deliberately owns no
/// canvas identity and performs no filesystem mutations; its host supplies
/// navigation and file-operation callbacks.
@MainActor
final class FileTreeBrowserView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSSearchFieldDelegate, TokenThemed {
    struct State: Equatable {
        var expandedPaths: [String] = []
        var selectedPath: String?
        var searchQuery = ""
    }

    private static let rowID = NSUserInterfaceItemIdentifier("EditorFileTreeRow")
    private let rootURL: URL
    private let viewModel: FileTreeViewModel
    private var state: State
    private var snapshot: FileTreeSnapshot?
    private var outlineModel: FileTreeOutlineModel
    private var suppressState = false
    private(set) var isScanning = false
    // AppKit owns this view on the main actor; deinit is nonisolated under
    // Swift 6, so permit teardown to invalidate the actor-confined timer.
    nonisolated(unsafe) private var searchTimer: Timer?

    private let stack = NSStackView()
    private let searchField = NSSearchField()
    private let outline = EditorNavigatorOutlineView()
    private let projectTitle = NSTextField(labelWithString: "")
    private var isDark = false
    private var nameEntry: NSTextField?
    private var nameEntryCompletion: ((String?) -> Void)?
    private let scroll = NSScrollView()
    private let status = NSTextField(labelWithString: "Scanning…")

    var onActivateFile: ((URL) -> Void)?
    var onOpenInNewTile: ((URL) -> Void)?
    var onOpenExternally: ((URL) -> Void)?
    var onCreateFile: ((URL) -> Void)?
    var onCreateFolder: ((URL) -> Void)?
    var onRename: ((URL) -> Void)?
    var onMoveToTrash: ((URL) -> Void)?
    var onStateChange: ((State) -> Void)?

    init(rootURL: URL, state: State = State(), viewModel: FileTreeViewModel = FileTreeViewModel()) {
        self.rootURL = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        self.state = state
        self.viewModel = viewModel
        self.outlineModel = FileTreeOutlineModel(snapshot: FileTreeSnapshot(root: rootURL, nodes: []), query: state.searchQuery)
        super.init(frame: .zero)
        build()
        configureModel()
        applyTokens()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func start() {
        guard !isScanning else { return }
        isScanning = true
        status.stringValue = "Scanning…"
        show(status)
        viewModel.start(rootPath: rootURL.path, ignoreList: [], gitBadgeMode: .cheap)
    }

    func stop() {
        isScanning = false
        flushState()
        viewModel.cancel()
    }

    func refresh() {
        stop()
        start()
    }

    func focusSearch() { window?.makeFirstResponder(searchField) }

    func currentState() -> State {
        flushState()
        return state
    }

    /// Updates navigator selection without opening a file or expanding folders.
    /// Used when navigation is cancelled or reveals a different editor tile.
    func selectFile(_ url: URL?) {
        let canonical = url?.standardizedFileURL.resolvingSymlinksInPath().path
        let prefix = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        state.selectedPath = canonical.flatMap { path in
            path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : nil
        }
        suppressState = true
        outline.deselectAll(nil)
        restoreSelection()
        suppressState = false
        changed()
    }

    var selectedFilePath: String? {
        state.selectedPath.map { absoluteURL($0).path }
    }

    /// Inline, transient filename entry. The host remains responsible for
    /// validation and filesystem mutation; cancelling never changes selection.
    func beginNameEntry(initialValue: String, placeholder: String, completion: @escaping (String?) -> Void) {
        finishNameEntry(nil)
        let field = NSTextField(string: initialValue)
        field.placeholderString = placeholder
        field.setAccessibilityLabel(placeholder)
        field.font = .systemFont(ofSize: 12)
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.focusRingType = .exterior
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        nameEntry = field
        nameEntryCompletion = completion
        stack.insertArrangedSubview(field, at: 1)
        field.heightAnchor.constraint(equalToConstant: 26).isActive = true
        window?.makeFirstResponder(field)
        field.selectText(nil)
    }

    private func finishNameEntry(_ value: String?) {
        guard let field = nameEntry else { return }
        let completion = nameEntryCompletion
        nameEntry = nil
        nameEntryCompletion = nil
        let hadFocus = field.currentEditor() != nil
        stack.removeArrangedSubview(field)
        field.removeFromSuperview()
        if hadFocus { window?.makeFirstResponder(outline) }
        completion?(value)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === nameEntry else { return false }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            finishNameEntry(nameEntry?.stringValue)
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            finishNameEntry(nil)
            return true
        }
        return false
    }

    func selectedURL(defaultingToRoot: Bool = true) -> URL? {
        guard let item = selectedItem() else { return defaultingToRoot ? rootURL : nil }
        let url = absoluteURL(item.node.relativePath)
        return item.node.isDirectory ? url : url.deletingLastPathComponent()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stop() } else { start() }
    }

    func applyEditorAppearance(isDark: Bool) {
        appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        applyTokens()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    func applyTokens() {
        isDark = effectiveTokenTheme == .dark
        let theme: EditorThemeTokens = isDark ? .dark : .light
        wantsLayer = true
        let background = StatusChipNSView.nsColor(theme.resolvedColor(\.sidebarBackground))
        layer?.backgroundColor = background.cgColor
        outline.backgroundColor = background
        projectTitle.textColor = StatusChipNSView.nsColor(theme.resolvedColor(\.foreground))
        status.textColor = StatusChipNSView.nsColor(theme.resolvedColor(\.mutedForeground))
        searchField.textColor = projectTitle.textColor
        for row in 0..<outline.numberOfRows {
            if let view = outline.rowView(atRow: row, makeIfNecessary: false) as? EditorNavigatorRowView {
                view.isDark = isDark
                view.needsDisplay = true
            }
        }
        outline.enumerateAvailableRowViews { rowView, row in
            guard let item = self.outline.item(atRow: row) as? FileTreeOutlineItem,
                  let cell = rowView.view(atColumn: 0) as? NSTableCellView else { return }
            self.style(cell, item: item)
        }
    }

    private func build() {
        stack.orientation = .vertical
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 8, bottom: 8, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        let title = projectTitle
        title.stringValue = rootURL.lastPathComponent
        title.setAccessibilityLabel("Project " + rootURL.lastPathComponent)
        title.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        title.lineBreakMode = .byTruncatingMiddle
        title.toolTip = rootURL.path
        let add = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "New file or folder")!, target: self, action: #selector(showAddMenu(_:)))
        add.isBordered = false
        let collapse = NSButton(image: NSImage(systemSymbolName: "chevron.up.chevron.down", accessibilityDescription: "Collapse folders")!, target: self, action: #selector(collapseAll(_:)))
        collapse.isBordered = false
        let header = NSStackView(views: [title, add, collapse])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 4

        searchField.placeholderString = "Filter files"
        searchField.stringValue = state.searchQuery
        searchField.delegate = self
        searchField.font = NSFont.systemFont(ofSize: 12)
        searchField.focusRingType = .none
        searchField.setAccessibilityLabel("Filter project files")

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("EditorFileTreeColumn"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowHeight = 28
        outline.indentationPerLevel = 14
        outline.selectionHighlightStyle = .regular
        outline.focusRingType = .none
        outline.setAccessibilityLabel("Project files")
        outline.intercellSpacing = .zero
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(clickedFile(_:))
        outline.onReturn = { [weak self] in self?.activateSelectedFile() }

        let menu = NSMenu()
        for (title, action) in [
            ("Open", #selector(activate(_:))),
            ("Open in New Tile", #selector(openInNewTile(_:))),
            ("Open in Preferred Editor", #selector(openExternally(_:))),
            ("Rename…", #selector(rename(_:))),
            ("Move to Trash…", #selector(moveToTrash(_:)))
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        outline.menu = menu

        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.scrollerStyle = .overlay
        scroll.documentView = outline

        status.alignment = .center
        status.maximumNumberOfLines = 0
        status.font = NSFont.systemFont(ofSize: 12)

        stack.addArrangedSubview(header)
        stack.addArrangedSubview(searchField)
        stack.addArrangedSubview(status)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            searchField.heightAnchor.constraint(equalToConstant: 26)
        ])
    }

    private func configureModel() {
        viewModel.onSnapshotChange = { [weak self] in self?.apply($0) }
        viewModel.onError = { [weak self] error in
            self?.status.stringValue = "Could not read files\n\(error.localizedDescription)"
            if let self { self.show(self.status) }
        }
    }

    private func apply(_ snapshot: FileTreeSnapshot) {
        self.snapshot = snapshot
        outlineModel = FileTreeOutlineModel(snapshot: snapshot, query: state.searchQuery)
        suppressState = true
        outline.reloadData()
        collapseVisible()
        restoreExpansion(parent: nil)
        restoreSelection()
        suppressState = false
        if outlineModel.rootItems.isEmpty {
            status.stringValue = state.searchQuery.isEmpty ? "No files" : "No matching files"
            show(status)
        } else {
            show(scroll)
        }
    }

    private func show(_ view: NSView) {
        guard stack.arrangedSubviews.last !== view else { return }
        if let old = stack.arrangedSubviews.last, old !== searchField {
            stack.removeArrangedSubview(old)
            old.removeFromSuperview()
        }
        stack.addArrangedSubview(view)
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        outlineModel.children(of: item as? FileTreeOutlineItem).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        outlineModel.children(of: item as? FileTreeOutlineItem)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let item = item as? FileTreeOutlineItem else { return false }
        return outlineModel.isExpandable(item)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? FileTreeOutlineItem else { return nil }
        let cell = outlineView.makeView(withIdentifier: Self.rowID, owner: self) as? NSTableCellView ?? makeCell()
        cell.textField?.stringValue = item.node.displayName
        style(cell, item: item)
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !suppressState else { return }
        state.selectedPath = selectedItem()?.node.relativePath
        changed()
    }

    func outlineViewItemDidExpand(_ notification: Notification) { captureExpansion() }
    func outlineViewItemDidCollapse(_ notification: Notification) { captureExpansion() }

    func controlTextDidChange(_ obj: Notification) {
        guard obj.object as? NSSearchField === searchField else { return }
        searchTimer?.invalidate()
        searchTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.commitSearch() }
        }
    }

    private func commitSearch() {
        searchTimer?.invalidate()
        searchTimer = nil
        state.searchQuery = searchField.stringValue
        changed()
        if let snapshot { apply(snapshot) }
    }

    private func flushState() { if searchField.stringValue != state.searchQuery { commitSearch() } }

    private func captureExpansion() {
        guard !suppressState, state.searchQuery.isEmpty else { return }
        state.expandedPaths = (0..<outline.numberOfRows).compactMap { row in
            guard let item = outline.item(atRow: row) as? FileTreeOutlineItem, outline.isItemExpanded(item) else { return nil }
            return item.node.relativePath
        }
        changed()
    }

    private func restoreExpansion(parent: FileTreeOutlineItem?) {
        for child in outlineModel.children(of: parent) {
            if !state.searchQuery.isEmpty || state.expandedPaths.contains(child.node.relativePath) { outline.expandItem(child) }
            restoreExpansion(parent: child)
        }
    }

    private func restoreSelection() {
        guard let selected = state.selectedPath else { return }
        for row in 0..<outline.numberOfRows where (outline.item(atRow: row) as? FileTreeOutlineItem)?.node.relativePath == selected {
            outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            return
        }
    }

    private func collapseVisible() {
        guard outline.numberOfRows > 0 else { return }
        for row in stride(from: outline.numberOfRows - 1, through: 0, by: -1) where outline.isItemExpanded(outline.item(atRow: row)) {
            outline.collapseItem(outline.item(atRow: row))
        }
    }

    private func selectedItem(clicked: Bool = false) -> FileTreeOutlineItem? {
        let row = clicked && outline.clickedRow >= 0 ? outline.clickedRow : outline.selectedRow
        return row >= 0 ? outline.item(atRow: row) as? FileTreeOutlineItem : nil
    }

    private func absoluteURL(_ relative: String) -> URL { rootURL.appendingPathComponent(relative).standardizedFileURL }

    @objc private func clickedFile(_ sender: Any?) {
        // The second mouse-down in a double click must not dispatch again.
        guard (NSApp.currentEvent?.clickCount ?? 1) < 2,
              let item = selectedItem(clicked: true) else { return }
        if item.node.isDirectory {
            // AppKit owns disclosure clicks; row/name clicks toggle the same folder.
            if let event = NSApp.currentEvent {
                let point = outline.convert(event.locationInWindow, from: nil)
                if outline.frameOfOutlineCell(atRow: outline.clickedRow).contains(point) { return }
            }
            activateItem(item)
            return
        }
        let url = absoluteURL(item.node.relativePath)
        if NSApp.currentEvent?.modifierFlags.contains(.command) == true { onOpenInNewTile?(url) }
        else { onActivateFile?(url) }
    }

    private func activateSelectedFile() {
        guard let item = selectedItem() else { return }
        activateItem(item)
    }

    private func activateItem(_ item: FileTreeOutlineItem) {
        if item.node.isDirectory {
            outline.isItemExpanded(item) ? outline.collapseItem(item) : outline.expandItem(item)
        } else { onActivateFile?(absoluteURL(item.node.relativePath)) }
    }

    @objc private func openInNewTile(_ sender: Any?) {
        guard let item = selectedItem(clicked: true) else { return }
        if item.node.isDirectory {
            // AppKit owns disclosure clicks; row/name clicks toggle the same folder.
            if let event = NSApp.currentEvent {
                let point = outline.convert(event.locationInWindow, from: nil)
                if outline.frameOfOutlineCell(atRow: outline.clickedRow).contains(point) { return }
            }
            activateItem(item)
            return
        }
        onOpenInNewTile?(absoluteURL(item.node.relativePath))
    }

    @objc private func activate(_ sender: Any?) {
        guard let item = selectedItem(clicked: true) else { return }
        activateItem(item)
    }

    @objc private func openExternally(_ sender: Any?) {
        guard let item = selectedItem(clicked: true) else { return }
        if item.node.isDirectory {
            // AppKit owns disclosure clicks; row/name clicks toggle the same folder.
            if let event = NSApp.currentEvent {
                let point = outline.convert(event.locationInWindow, from: nil)
                if outline.frameOfOutlineCell(atRow: outline.clickedRow).contains(point) { return }
            }
            activateItem(item)
            return
        }
        onOpenExternally?(absoluteURL(item.node.relativePath))
    }
    @objc private func rename(_ sender: Any?) { if let item = selectedItem(clicked: true) { onRename?(absoluteURL(item.node.relativePath)) } }
    @objc private func moveToTrash(_ sender: Any?) { if let item = selectedItem(clicked: true) { onMoveToTrash?(absoluteURL(item.node.relativePath)) } }

    @objc private func showAddMenu(_ sender: NSButton) {
        let menu = NSMenu()
        let file = NSMenuItem(title: "New File…", action: #selector(createFile(_:)), keyEquivalent: "")
        let folder = NSMenuItem(title: "New Folder…", action: #selector(createFolder(_:)), keyEquivalent: "")
        file.target = self; folder.target = self
        menu.addItem(file); menu.addItem(folder)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY), in: sender)
    }
    @objc private func createFile(_ sender: Any?) { if let parent = selectedURL() { onCreateFile?(parent) } }
    @objc private func createFolder(_ sender: Any?) { if let parent = selectedURL() { onCreateFolder?(parent) } }
    @objc private func collapseAll(_ sender: Any?) { state.expandedPaths = []; if let snapshot { apply(snapshot) }; changed() }

    private func changed() { onStateChange?(state) }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let row = EditorNavigatorRowView()
        row.isDark = isDark
        return row
    }

    private func style(_ cell: NSTableCellView, item: FileTreeOutlineItem) {
        let theme: EditorThemeTokens = isDark ? .dark : .light
        let foreground: KeyPath<EditorThemeTokens, String> = item.node.isIgnored ? \.mutedForeground : \.foreground
        cell.textField?.textColor = StatusChipNSView.nsColor(theme.resolvedColor(foreground))
        let ext = (item.node.displayName as NSString).pathExtension.lowercased()
        let symbol: String
        let tint: NSColor
        if item.node.isDirectory { symbol = "folder.fill"; tint = .systemBlue }
        else {
            switch ext {
            case "swift": symbol = "swift"; tint = .systemOrange
            case "js", "jsx", "ts", "tsx": symbol = "chevron.left.forwardslash.chevron.right"; tint = ext.hasPrefix("t") ? .systemBlue : .systemYellow
            case "json", "yaml", "yml", "toml": symbol = "curlybraces"; tint = .systemPurple
            case "md", "mdx", "txt": symbol = "text.alignleft"; tint = StatusChipNSView.nsColor(theme.resolvedColor(\.mutedForeground))
            case "png", "jpg", "jpeg", "svg", "gif", "webp": symbol = "photo"; tint = .systemPink
            case "py", "go", "rs", "c", "cpp", "h", "html", "css", "sh": symbol = "chevron.left.forwardslash.chevron.right"; tint = .systemTeal
            default: symbol = "doc"; tint = StatusChipNSView.nsColor(theme.resolvedColor(\.mutedForeground))
            }
        }
        cell.imageView?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        cell.imageView?.contentTintColor = tint.withAlphaComponent(item.node.isIgnored ? 0.45 : 0.85)
        cell.toolTip = item.node.relativePath
        cell.setAccessibilityLabel(item.node.displayName + (item.node.isDirectory ? ", folder" : ", file"))
    }

    private func makeCell() -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = Self.rowID
        let icon = NSImageView()
        let text = NSTextField(labelWithString: "")
        icon.translatesAutoresizingMaskIntoConstraints = false
        text.translatesAutoresizingMaskIntoConstraints = false
        text.font = NSFont.systemFont(ofSize: 12.5)
        text.lineBreakMode = .byTruncatingTail
        cell.addSubview(icon); cell.addSubview(text)
        cell.imageView = icon; cell.textField = text
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 3), icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 15), icon.heightAnchor.constraint(equalToConstant: 15),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7), text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -3), text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }
}

@MainActor
private final class EditorNavigatorOutlineView: NSOutlineView {
    var onReturn: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 { onReturn?(); return }
        super.keyDown(with: event)
    }
}

@MainActor
private final class EditorNavigatorRowView: NSTableRowView {
    var isDark = false
    private var hovered = false
    private var hoverTracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverTracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func drawBackground(in dirtyRect: NSRect) {
        if hovered && !isSelected {
            let theme: EditorThemeTokens = isDark ? .dark : .light
            StatusChipNSView.nsColor(theme.resolvedColor(\.hover)).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 5, yRadius: 5).fill()
        }
    }
    override func drawSelection(in dirtyRect: NSRect) {
        let theme: EditorThemeTokens = isDark ? .dark : .light
        let accent = StatusChipNSView.nsColor(theme.resolvedColor(\.selection))
        accent.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 5, yRadius: 5).fill()
    }
}
