import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

struct BoardLibraryEntry: Equatable {
    var id: UUID
    var title: String
    var isOpen: Bool
}

/// Project-local navigation; document mutations belong to the host.
@MainActor
final class BoardLibraryView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private let table = BoardLibraryTableView()
    private let scroll = NSScrollView()
    private let heading = NSTextField(labelWithString: "Boards")
    private let create = NSButton(title: "New board", target: nil, action: nil)
    private let actions = NSButton(title: "…", target: nil, action: nil)
    private let actionPicker = ChoicePopoverController()
    private var renameField: NSTextField?
    private var renameID: UUID?
    private(set) var entries: [BoardLibraryEntry] = []
    private var current: UUID?
    var onSelect: ((UUID) -> Void)?
    var onCreate: (() -> Void)?
    var onRename: ((UUID, String) -> String?)?
    var onDelete: ((UUID) -> Void)?
    var onError: ((String) -> Void)?
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        heading.font = NSFont.token(.label)
        create.isBordered = false
        create.font = NSFont.token(.caption)
        create.target = self
        create.action = #selector(createBoard)
        actions.isBordered = false
        actions.setAccessibilityLabel("Board actions")
        actions.target = self
        actions.action = #selector(showActions)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("board"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 42
        table.intercellSpacing = .zero
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(selectBoard)
        table.onActivate = { [weak self] row in self?.activate(row: row) }
        table.setAccessibilityLabel("Project boards")
        scroll.documentView = table
        scroll.scrollerStyle = .overlay
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let children: [NSView] = [heading, create, actions, scroll]
        children.forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func render(_ entries: [BoardLibraryEntry], current: UUID) {
        self.entries = entries
        self.current = current
        table.reloadData()
        updateDocumentFrame()
        needsLayout = true
        if let row = entries.firstIndex(where: { $0.id == current }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
    }
    override func layout() {
        super.layout()
        setFrameIfChanged(heading, NSRect(x: 12, y: 10, width: max(0, bounds.width - 48), height: 20))
        setFrameIfChanged(actions, NSRect(x: max(0, bounds.width - 34), y: 10, width: 24, height: 20))
        setFrameIfChanged(create, NSRect(x: 8, y: 36, width: max(0, bounds.width - 16), height: 24))
        setFrameIfChanged(scroll, NSRect(x: 0, y: 66, width: bounds.width, height: max(0, bounds.height - 66)))
        updateDocumentFrame()
    }
    private func updateDocumentFrame() {
        let width = max(0, scroll.contentSize.width)
        let height = max(scroll.contentSize.height, CGFloat(entries.count) * table.rowHeight)
        setFrameIfChanged(table, NSRect(x: 0, y: 0, width: width, height: height))
        if let column = table.tableColumns.first, column.width != width { column.width = width }
    }

    /// Outcomes from cells AppKit actually installed inside the visible clip.
    /// A nonempty model alone does not prove the list drew any rows.
    var visibleRowTitles: [String] {
        guard !isHidden, window != nil, scroll.contentView.bounds.width > 0,
              scroll.contentView.bounds.height > 0 else { return [] }
        return entries.indices.compactMap { row in
            guard table.rect(ofRow: row).intersects(table.visibleRect),
                  let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView,
                  !cell.isHidden, cell.bounds.width > 0, cell.bounds.height > 0,
                  let label = cell.textField, !label.isHidden,
                  cell.bounds.contains(label.frame), label.frame.height > 0,
                  label.frame.width > 0 else { return nil }
            return label.stringValue
        }

    }
    private func setFrameIfChanged(_ view: NSView, _ frame: NSRect) {
        if view.frame != frame { view.frame = frame }
    }
    func applyTokens(in owner: NSView) {
        let background = SurfaceToken.tileBody.color.nsColor(in: owner)
        table.backgroundColor = background
        heading.textColor = TextToken.textPrimary.color.nsColor(in: owner)
        actions.attributedTitle = NSAttributedString(string: "…", attributes: [
            .font: NSFont.token(.label), .foregroundColor: TextToken.textPrimary.color.nsColor(in: owner)])
        table.reloadData()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("BoardLibraryRow")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? BoardLibraryCellView ?? BoardLibraryCellView()
        cell.identifier = id
        let entry = entries[row]
        let state = entry.id == current ? "Current" : (entry.isOpen ? "On canvas" : "Closed")
        cell.textField?.stringValue = "\(entry.title)\n\(state)"
        cell.textField?.usesSingleLineMode = false
        cell.textField?.maximumNumberOfLines = 2
        cell.textField?.textColor = TextToken.textPrimary.color.nsColor(in: self)
        cell.needsLayout = true
        return cell
    }
    @objc private func createBoard() { onCreate?() }
    @objc private func selectBoard() {
        activate(row: table.clickedRow)
    }
    private func activate(row: Int) {
        guard entries.indices.contains(row) else { return }
        onSelect?(entries[row].id)
    }
    @objc private func showActions() {
        let row = table.selectedRow
        guard entries.indices.contains(row) else { return }
        let entry = entries[row]
        actionPicker.present(items: [
            ChoiceItem(id: "rename", title: "Rename", icon: .system("pencil")),
            ChoiceItem(id: "delete", title: "Delete board…", icon: .system("trash"), destructive: true)
        ], selectedID: nil, presentation: .commands, anchor: actions.bounds, relativeTo: actions,
        accessibilityLabel: "Board actions", onSelection: { [weak self] item in
            if item.id == "rename" { self?.beginRename(entry) }
            else { self?.onDelete?(entry.id) }
        }, focusReturnView: actions)
    }
    func beginRenameCurrentBoard() {
        guard let entry = entries.first(where: { $0.id == current }) else { return }
        beginRename(entry)
    }
    private func beginRename(_ entry: BoardLibraryEntry) {
        renameField?.removeFromSuperview()
        let field = NSTextField(string: entry.title)
        field.font = NSFont.token(.body)
        field.delegate = self
        field.frame = NSRect(x: 8, y: 36, width: max(0, bounds.width - 16), height: 26)
        addSubview(field)
        renameField = field
        renameID = entry.id
        window?.makeFirstResponder(field)
        field.selectText(nil)
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard renameField != nil, renameID != nil else { return false }
        if selector == #selector(NSResponder.cancelOperation(_:)) { finishRename(); return true }
        guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
        _ = finishPendingRename()
        return true
    }
    func finishPendingRename() -> Bool {
        guard let field = renameField, let id = renameID else { return true }
        if let error = onRename?(id, field.stringValue) { onError?(error); return false }
        finishRename()
        return true
    }
    private func finishRename() {
        renameField?.removeFromSuperview()
        renameField = nil
        renameID = nil
        window?.makeFirstResponder(table)
    }
}

/// Arrow keys select; Return opens the selected board through the same callback
/// as pointer activation, independent of NSTableView's last clicked row.
@MainActor
private final class BoardLibraryTableView: NSTableView {
    var onActivate: ((Int) -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {
            onActivate?(selectedRow)
            return
        }
        super.keyDown(with: event)
    }
}

/// The table installs cells after asking its delegate for them. Lay text out
/// against that final frame instead of autoresizing from an initial zero frame.
@MainActor
private final class BoardLibraryCellView: NSTableCellView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        let label = NSTextField(labelWithString: "")
        label.font = NSFont.token(.caption)
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        textField = label
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func layout() {
        super.layout()
        let textFrame = NSRect(x: 12, y: 3, width: max(0, bounds.width - 24),
                               height: max(0, min(36, bounds.height - 6)))
        if textField?.frame != textFrame { textField?.frame = textFrame }
    }
}
