import AppKit
import ContinuumRevivedCore
import ContinuumRevivedAgentUI

/// Backends return bounded projected pages, preserving strings without inference.
protocol FileGridDataSource: Sendable {
    func releaseSource()
    var rowCount: Int { get }
    var columnCount: Int { get }
    var encodingName: String { get }
    func rows(in range: Range<Int>, columns: Range<Int>?) throws -> [[String]]
    func nextMatch(query: String, afterRow: Int, column: Int) throws -> FileGridMatch?
    func inspectCell(row: Int, column: Int) -> String?
}
struct FileGridMatch: Sendable, Equatable { let row: Int; let column: Int }
extension FileGridDataSource {
    func releaseSource() {}
    func inspectCell(row: Int, column: Int) -> String? { nil }
    func nextMatch(query: String, afterRow startRow: Int, column startColumn: Int) throws -> FileGridMatch? {
        guard !query.isEmpty, rowCount > 0, columnCount > 0 else { return nil }
        for segment in 0..<2 {
            let lower = segment == 0 ? startRow : 0
            let upper = segment == 0 ? rowCount : startRow + 1
            for first in stride(from: lower, to: upper, by: 64) {
                var earliest: FileGridMatch?
                for column in stride(from: 0, to: columnCount, by: 16) {
                    try Task.checkCancellation()
                    let values = try rows(in: first..<min(first + 64, upper), columns: column..<min(column + 16, columnCount))
                    for (rowOffset, row) in values.enumerated() {
                        for (columnOffset, value) in row.enumerated() {
                            let r = first + rowOffset, c = column + columnOffset
                            if segment == 0, r == startRow, c <= startColumn { continue }
                            if segment == 1, r == startRow, c > startColumn { continue }
                            if value.localizedCaseInsensitiveContains(query), earliest == nil || r < earliest!.row || (r == earliest!.row && c < earliest!.column) { earliest = FileGridMatch(row: r, column: c) }
                        }
                    }
                }
                if let earliest { return earliest }
            }
        }
        return nil
    }
}

/// All tiles share two worker permits. Admission precedes allocation; cancelled
/// waiters never execute, and an admitted task retains its source/leases until
/// the underlying operation actually exits, even when its host is disposed.
actor FileGridWorkScheduler {
    static let shared = FileGridWorkScheduler()
    private var active = 0
    private var peak = 0
    private var waiters: [(UUID, CheckedContinuation<Void, Error>)] = []
    var qaCounts: (active: Int, queued: Int, peak: Int) { (active, waiters.count, peak) }
    private func acquire() async throws {
        try Task.checkCancellation()
        if active < 2 { active += 1; peak = max(peak, active); return }
        let id = UUID()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { waiters.append((id, continuation)) }
            }
        }, onCancel: { Task { await self.cancelWaiter(id) } })
    }
    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.0 == id }) else { return }
        waiters.remove(at: index).1.resume(throwing: CancellationError())
    }
    private func release() {
        if waiters.isEmpty { active -= 1 }
        else { waiters.removeFirst().1.resume() }
    }
    func run<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        let worker = Task.detached(priority: .userInitiated) { try await operation() }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }
}
private struct EmptyFileGridSource: FileGridDataSource {
    var rowCount: Int { 0 }
    var columnCount: Int { 0 }
    var encodingName: String { "" }
    func rows(in range: Range<Int>, columns: Range<Int>?) throws -> [[String]] { throw CancellationError() }
}

extension DelimitedFileDocument: FileGridDataSource {
    func rows(in range: Range<Int>, columns: Range<Int>?) throws -> [[String]] {
        try rows(in: range, columns: columns, cancelled: { Task.isCancelled })
    }
}

/// Read-only paged data inspection. Exactly one drawing view, independent of the
/// number of records or columns. No parsing, page reads or text measurement in layout.
@MainActor
final class DelimitedGridRenderer: NSObject, FileTileRenderer {
    private let root = DelimitedGridContainer()
    private let scroll = NSScrollView()
    private let grid = DelimitedGridCanvas()
    private let headerChoice = ChoiceButton(title: "Headers")
    private let status = NSTextField(labelWithString: "")
    private let inspector = NSTextView()
    private let inspectorScroll = NSScrollView()
    private var storedDocument: (any FileGridDataSource)?
    private var document: any FileGridDataSource { storedDocument ?? EmptyFileGridSource() }
    private let search = NSSearchField()
    private let dialectChoice = ChoiceButton(title: "Delimiter")
    var onDelimiterChange: ((UInt8) -> Void)?
    private var findTask: Task<Void, Never>?
    private var findGeneration: UInt64 = 0
    private struct Page: Hashable { let row: Int; let column: Int }
    private let pageRows = 64, pageColumns = 16
    private let cacheLimit = 4 * 1_024 * 1_024
    private var pageCosts: [Page: Int] = [:]
    var qaCachedBytes: Int { pageCosts.values.reduce(0, +) }
    var qaIsLoading: Bool { pageTask != nil }
    var qaIsCopying: Bool { copyTask != nil }
    var qaIsFinding: Bool { findTask != nil }
    var qaStatus: String { status.stringValue }
    var qaInspectorText: String { inspector.string }
    private var pages: [Page: [[String]]] = [:]
    private var pageOrder: [Page] = []
    private var requestedPages: [Page] = []
    private var pageTask: Task<Void, Never>?
    private var copyTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var disposed = false
    private var visible = true
    private var boundsObserver: NSObjectProtocol?
    private(set) var revision: UInt64 = 1
    private(set) var qaPageReadCount = 0
    private(set) var qaCopiedTSV: String?
    private(set) var qaSelectedValue: String?
    var view: NSView { root }
    var focusView: NSView { grid }
    var scrollOffsets: [CGPoint] { [scroll.contentView.bounds.origin] }
    var qaVisibleCellCount: Int { grid.visibleCellCount }
    var qaDrawCount: Int { grid.drawCount }
    var qaCachedPageCount: Int { pages.count }
    var onRevisionChange: (() -> Void)?

    convenience init(document: DelimitedFileDocument) {
        self.init(source: document, title: "Data", allowsHeaderChoice: true, delimiter: document.delimiter)
    }

    init(source: any FileGridDataSource, title: String, allowsHeaderChoice: Bool = false, delimiter: UInt8 = 44) {
        self.storedDocument = source
        super.init()
        // macOS 14 allows drawing outside bounds by default. The grid body must
        // not erase its workbook toolbar or neighbouring controls.
        root.clipsToBounds = true
        grid.clipsToBounds = true
        let document = source
        headerChoice.isHidden = !allowsHeaderChoice
        dialectChoice.isHidden = !allowsHeaderChoice
        dialectChoice.items = [ChoiceItem(id: "44", title: "Comma"), ChoiceItem(id: "9", title: "Tab"), ChoiceItem(id: "59", title: "Semicolon"), ChoiceItem(id: "124", title: "Pipe")]
        dialectChoice.selectedID = String(delimiter)
        dialectChoice.onSelection = { [weak self] item in
            guard let byte = UInt8(item.id) else { return }
            self?.onDelimiterChange?(byte)
        }
        search.placeholderString = "Find next · whole file"
        search.target = self
        search.action = #selector(submitFind)
        search.sendsSearchStringImmediately = false
        search.setAccessibilityLabel("Find next matching cell in whole file")
        grid.setAccessibilityLabel(title + " data grid")
        root.owner = self
        grid.rowCount = document.rowCount
        grid.columnCount = document.columnCount
        grid.valueAt = { [weak self] row, column in self?.value(row: row, column: column) }
        grid.onSelection = { [weak self] in self?.selectionChanged() }
        grid.onCopy = { [weak self] in self?.copySelection() }
        headerChoice.items = [ChoiceItem(id: "none", title: "No Header Row"), ChoiceItem(id: "first", title: "First Row as Headers")]
        headerChoice.selectedID = "none"
        headerChoice.onSelection = { [weak self] item in
            guard let self else { return }
            self.grid.firstRowIsHeader = item.id == "first"
            self.grid.resetSelection()
            self.rebuildGeometry()
            self.changed()
        }
        status.font = .token(.label)
        status.lineBreakMode = .byTruncatingTail
        status.setAccessibilityLabel("Data preview status")
        inspector.isEditable = false
        inspector.isSelectable = true
        inspector.isRichText = false
        inspector.font = .token(.bodyMono)
        inspector.textContainerInset = NSSize(width: 10, height: 6)
        inspector.autoresizingMask = [.width]
        inspector.isVerticallyResizable = true
        inspector.textContainer?.widthTracksTextView = true
        inspector.setAccessibilityLabel("Full selected cell value")
        inspectorScroll.documentView = inspector
        inspectorScroll.hasVerticalScroller = true
        inspectorScroll.autohidesScrollers = true
        inspectorScroll.drawsBackground = false
        scroll.documentView = grid
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.contentView.postsBoundsChangedNotifications = true
        for child in [headerChoice, dialectChoice, search, status, scroll, inspectorScroll] as [NSView] { root.addSubview(child) }
        boundsObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.viewportChanged() }
        }
        updateStatus()
        applyTheme()
        rebuildGeometry()
        selectionChanged()
    }

    fileprivate func layout(in bounds: NSRect) {
        let toolbarHeight: CGFloat = 76
        let inspectorHeight: CGFloat = min(92, max(40, bounds.height * 0.22))
        let choiceWidth: CGFloat = min(180, max(100, bounds.width * 0.4))
        let headerChoiceFrame = NSRect(x: 8, y: 4, width: choiceWidth, height: 32)
        if headerChoice.frame != headerChoiceFrame { headerChoice.frame = headerChoiceFrame }
        let dialectChoiceFrame = NSRect(x: choiceWidth + 12, y: 4, width: max(80, min(120, bounds.width - choiceWidth - 20)), height: 32)
        if dialectChoice.frame != dialectChoiceFrame { dialectChoice.frame = dialectChoiceFrame }
        let searchFrame = NSRect(x: 8, y: 40, width: max(0, min(220, bounds.width * 0.45)), height: 24)
        if search.frame != searchFrame { search.frame = searchFrame }
        let statusFrame = NSRect(x: search.frame.maxX + 8, y: 44, width: max(0, bounds.width - search.frame.maxX - 16), height: 18)
        if status.frame != statusFrame { status.frame = statusFrame }
        let bodyFrame = NSRect(x: 0, y: toolbarHeight, width: bounds.width, height: max(0, bounds.height - toolbarHeight - inspectorHeight))
        if scroll.frame != bodyFrame { scroll.frame = bodyFrame }
        let inspectorFrame = NSRect(x: 0, y: bounds.height - inspectorHeight, width: bounds.width, height: inspectorHeight)
        if inspectorScroll.frame != inspectorFrame { inspectorScroll.frame = inspectorFrame }
        // Only geometry arithmetic; the viewport observer schedules I/O separately.
    }

    private func rebuildGeometry() {
        let size = NSSize(width: CGFloat(document.columnCount) * grid.cellWidth + grid.gutter,
                          height: CGFloat(grid.dataRowCount) * grid.cellHeight + grid.cellHeight)
        grid.setFrameSize(size)
        grid.needsDisplay = true
        viewportChanged()
    }

    private func changed() {
        revision &+= 1
        grid.needsDisplay = true
        onRevisionChange?()
    }

    func applyTheme() {
        root.needsDisplay = true
        grid.needsDisplay = true
        headerChoice.applyTokens()
        dialectChoice.applyTokens()
        status.textColor = TextToken.textSecondary.color.nsColor(in: root)
        inspector.backgroundColor = SurfaceToken.tileChrome.color.nsColor(in: root)
        inspector.textColor = TextToken.textPrimary.color.nsColor(in: root)
        changed()
    }

    func setVisible(_ isVisible: Bool) {
        guard visible != isVisible else { return }
        visible = isVisible
        if isVisible { viewportChanged() }
        else {
            generation &+= 1
            pageTask?.cancel(); pageTask = nil
            copyTask?.cancel(); copyTask = nil
            findGeneration &+= 1; findTask?.cancel(); findTask = nil
            requestedPages.removeAll()
        }
    }

    func dispose() {
        guard !disposed else { return }
        disposed = true
        generation &+= 1
        pageTask?.cancel(); pageTask = nil
        copyTask?.cancel(); copyTask = nil
        findGeneration &+= 1; findTask?.cancel(); findTask = nil
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
        boundsObserver = nil
        pages.removeAll(); pageCosts.removeAll(); pageOrder.removeAll(); requestedPages.removeAll()
        grid.valueAt = nil; grid.onSelection = nil; grid.onCopy = nil
        storedDocument?.releaseSource(); storedDocument = nil
        qaSelectedValue = nil; qaCopiedTSV = nil; inspector.string = ""
        onRevisionChange = nil; onDelimiterChange = nil
    }

    private func value(row: Int, column: Int) -> String? {
        guard row >= 0, column >= 0, row < document.rowCount, column < document.columnCount,
              let rows = pages[Page(row: row / pageRows, column: column / pageColumns)] else { return nil }
        let offset = row % pageRows
        let projected = column % pageColumns
        guard offset < rows.count else { return nil }
        // Ragged records have absent fields. Preserve empty field display without
        // manufacturing data in the backing document.
        return projected < rows[offset].count ? rows[offset][projected] : ""
    }

    private func viewportChanged() {
        guard visible, !disposed else { return }
        let rows = grid.visibleRows
        let columns = grid.visibleColumns
        var needed: [Page] = []
        if !rows.isEmpty, !columns.isEmpty {
            // The viewport itself is bounded by the window; cap requested tiles
            // defensively for offscreen harnesses with enormous view frames.
            outer: for row in rows.lowerBound / pageRows...((rows.upperBound - 1) / pageRows) {
                for column in columns.lowerBound / pageColumns...((columns.upperBound - 1) / pageColumns) {
                    guard needed.count < 7 else { break outer }
                    needed.append(Page(row: row, column: column))
                }
            }
        }
        if grid.firstRowIsHeader, !columns.isEmpty {
            for column in columns.lowerBound / pageColumns...((columns.upperBound - 1) / pageColumns) {
                let header = Page(row: 0, column: column)
                needed.removeAll { $0 == header }; needed.insert(header, at: 0)
            }
        }
        // A fixed working set also covers frozen headers at a far vertical
        // offset; never churn forever trying to fit more pages than the LRU.
        needed = Array(needed.prefix(7))
        if document.rowCount > 0 { needed.append(Page(row: grid.selectedRow / pageRows, column: grid.selectedColumn / pageColumns)) }
        requestedPages = Array(Set(needed)).filter { pages[$0] == nil }
        grid.needsDisplay = true
        pumpPage()
    }

    private func pumpPage() {
        guard pageTask == nil, visible, !disposed, !requestedPages.isEmpty else { return }
        let page = requestedPages.removeFirst()
        let start = page.row * pageRows
        let columns = (page.column * pageColumns)..<min((page.column + 1) * pageColumns, document.columnCount)
        guard start < document.rowCount else { return }
        let range = start..<min(start + pageRows, document.rowCount)
        let source = document
        let stamp = generation
        qaPageReadCount += 1
        pageTask = Task { [weak self] in
            let result: Result<[[String]], Error>
            do { result = .success(try await FileGridWorkScheduler.shared.run { try source.rows(in: range, columns: columns) }) }
            catch { result = .failure(error) }
            guard !Task.isCancelled, let self, !self.disposed, self.generation == stamp else { return }
            self.pageTask = nil
            switch result {
            case .success(let rows):
                let cost = rows.reduce(0) { $0 + $1.reduce(0) { $0 + $1.utf8.count + 32 } }
                guard cost <= self.cacheLimit else {
                    self.status.stringValue = "Cell page exceeds 4 MiB preview limit; narrow the data source."
                    self.pumpPage(); return
                }
                self.pages[page] = rows
                self.pageCosts[page] = cost
                self.pageOrder.removeAll { $0 == page }
                self.pageOrder.append(page)
                while self.pageOrder.count > 8 || self.qaCachedBytes > self.cacheLimit {
                    let oldest = self.pageOrder.removeFirst()
                    self.pages.removeValue(forKey: oldest); self.pageCosts.removeValue(forKey: oldest)
                }
                self.selectionChanged()
                self.changed()
            case .failure(let error):
                self.status.stringValue = "Unable to read data: \(error.localizedDescription)"
            }
            self.pumpPage()
        }
    }

    private func updateStatus(_ suffix: String? = nil) {
        status.stringValue = "\(document.rowCount) rows × \(document.columnCount) columns · \(document.encodingName) · Read-only" + (suffix.map { " · " + $0 } ?? "")
        status.toolTip = status.stringValue
    }

    private func selectionChanged() {
        if visible, !disposed { viewportChanged() }
        qaSelectedValue = value(row: grid.selectedRow, column: grid.selectedColumn)
        let coordinate = "Row \(grid.selectedRow + 1), Column \(grid.selectedColumn + 1)"
        let details = document.inspectCell(row: grid.selectedRow, column: grid.selectedColumn) ?? qaSelectedValue ?? "Loading cell…"
        let text = document.rowCount == 0 ? "No records" : coordinate + "\n" + details
        if inspector.string != text { inspector.string = text }
        grid.setAccessibilityValue(text)
        grid.setAccessibilityHelp("Read-only data grid. Use arrow keys to select a cell, Shift to extend selection, Command-C to copy. Tab moves to the next control. \(document.rowCount) rows and \(document.columnCount) columns.")
        NSAccessibility.post(element: grid, notification: .valueChanged)
        changed()
    }

    /// Exact field text with TSV quoting; no type inference or formula evaluation.
    nonisolated static func quotedTSV(_ rows: [[String]]) -> String {
        rows.map { row in row.map { value in
            if value.contains(where: { $0 == "\t" || $0 == "\n" || $0 == "\r" || $0 == "\"" }) {
                return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }
            return value
        }.joined(separator: "\t") }.joined(separator: "\n")
    }

    private func copySelection(writePasteboard: Bool = true) {
        guard !disposed, document.rowCount > 0, document.columnCount > 0 else { return }
        let rows = grid.selectedRows
        let columns = grid.selectedColumns
        guard rows.count <= 100_000 / max(1, columns.count) else {
            updateStatus("Selection exceeds 100,000-cell copy limit")
            return
        }
        copyTask?.cancel()
        let source = document
        let stamp = generation
        updateStatus("Copying selection…")
        copyTask = Task { [weak self] in
            let result: Result<String, Error>
            do { result = .success(try await FileGridWorkScheduler.shared.run { () throws -> String in
                var selected: [[String]] = []
                var bytes = 0
                for start in stride(from: rows.lowerBound, to: rows.upperBound, by: 256) {
                    try Task.checkCancellation()
                    let batch = try source.rows(in: start..<min(start + 256, rows.upperBound), columns: columns)
                    for row in batch {
                        let projected = (0..<columns.count).map { $0 < row.count ? row[$0] : "" }
                        bytes += projected.reduce(0) { $0 + $1.utf8.count * 2 + 4 }
                        guard bytes <= 8 * 1_024 * 1_024 else { throw DelimitedFileDocument.Failure.pageLimit }
                        selected.append(projected)
                    }
                }
                return Self.quotedTSV(selected)
            }) } catch { result = .failure(error) }
            guard !Task.isCancelled, let self, !self.disposed, self.generation == stamp else { return }
            switch result {
            case .success(let text):
                self.qaCopiedTSV = text
                if writePasteboard {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                self.updateStatus("Copied \(rows.count) × \(columns.count) cells")
            case .failure(let error): self.updateStatus("Copy failed: \(error.localizedDescription)")
            }
            self.copyTask = nil
        }
    }

    @objc private func submitFind() { findNext(query: search.stringValue) }

    /// Search all records, returning one next match instead of retaining an
    /// unbounded result set. Each source page is projected in both dimensions.
    func findNext(query: String) {
        findGeneration &+= 1
        findTask?.cancel(); findTask = nil
        guard !query.isEmpty, visible, !disposed, document.rowCount > 0, document.columnCount > 0 else { updateStatus(); return }
        let stamp = findGeneration, source = document
        let startRow = grid.selectedRow, startColumn = grid.selectedColumn
        updateStatus("Searching whole file…")
        findTask = Task { [weak self] in
            let result: Result<FileGridMatch?, Error>
            do { result = .success(try await FileGridWorkScheduler.shared.run {
                try source.nextMatch(query: query, afterRow: startRow, column: startColumn)
            }) } catch { result = .failure(error) }
            guard !Task.isCancelled, let self, !self.disposed, self.findGeneration == stamp else { return }
            self.findTask = nil
            switch result {
            case .success(let match):
                if let match { self.grid.select(row: match.row, column: match.column, extending: false); self.updateStatus("Match at row \(match.row + 1), column \(match.column + 1) · Whole file") }
                else { self.updateStatus("No matches · Whole file") }
            case .failure(let error): self.updateStatus("Search failed: \(error.localizedDescription)")
            }
        }
    }

    func qaSetHeaders(_ enabled: Bool) { grid.firstRowIsHeader = enabled; grid.resetSelection(); rebuildGeometry() }
    func qaSetViewport(_ point: NSPoint) { scroll.contentView.scroll(to: point); viewportChanged() }
    func qaSetScrollerStyle(_ style: NSScroller.Style) { scroll.scrollerStyle = style }
    func qaLayout(size: NSSize) { root.setFrameSize(size); root.layoutSubtreeIfNeeded(); viewportChanged() }
    func qaSelect(row: Int, column: Int, extending: Bool = false) { grid.select(row: row, column: column, extending: extending) }
    func qaCopySelection() { copySelection(writePasteboard: false) }
    func qaWaitForIdle() async {
        while let task = pageTask { await task.value }
        if let task = copyTask { await task.value }
        if let task = findTask { await task.value }
        while let task = pageTask { await task.value }
    }
}

@MainActor
private final class DelimitedGridContainer: NSView {
    weak var owner: DelimitedGridRenderer?
    override var isFlipped: Bool { true }
    override func layout() { super.layout(); owner?.layout(in: bounds) }
    override func draw(_ dirtyRect: NSRect) { SurfaceToken.tileBody.color.nsColor(in: self).setFill(); dirtyRect.intersection(bounds).fill() }
}

@MainActor
private final class DelimitedGridCanvas: NSView {
    let cellWidth: CGFloat = 140
    let cellHeight: CGFloat = 26
    let gutter: CGFloat = 62
    var rowCount = 0
    var columnCount = 0
    var firstRowIsHeader = false
    var valueAt: ((Int, Int) -> String?)?
    var onSelection: (() -> Void)?
    var onCopy: (() -> Void)?
    private(set) var selectedRow = 0
    private(set) var selectedColumn = 0
    private var anchorRow = 0
    private var anchorColumn = 0
    private(set) var visibleCellCount = 0
    private(set) var drawCount = 0
    var dataRowCount: Int { max(0, rowCount - (firstRowIsHeader ? 1 : 0)) }
    var selectedRows: Range<Int> { min(anchorRow, selectedRow)..<(max(anchorRow, selectedRow) + 1) }
    var selectedColumns: Range<Int> { min(anchorColumn, selectedColumn)..<(max(anchorColumn, selectedColumn) + 1) }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Data grid")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var visibleRows: Range<Int> {
        let offset = firstRowIsHeader ? 1 : 0
        let start = min(rowCount, max(offset, Int(max(0, visibleRect.minY) / cellHeight) + offset - 1))
        let end = min(rowCount, max(start, Int(max(0, visibleRect.maxY) / cellHeight) + offset + 1))
        return start..<end
    }

    var visibleColumns: Range<Int> {
        let start = min(columnCount, max(0, Int(max(0, visibleRect.minX) / cellWidth)))
        let end = min(columnCount, max(start, Int(max(0, visibleRect.maxX - gutter) / cellWidth) + 1))
        return start..<end
    }

    func resetSelection() {
        selectedRow = min(max(0, rowCount - 1), firstRowIsHeader ? 1 : 0)
        selectedColumn = 0; anchorRow = selectedRow; anchorColumn = 0
        onSelection?()
    }

    func select(row: Int, column: Int, extending: Bool) {
        guard dataRowCount > 0, columnCount > 0 else { return }
        selectedRow = min(rowCount - 1, max(firstRowIsHeader ? 1 : 0, row))
        selectedColumn = min(columnCount - 1, max(0, column))
        if !extending { anchorRow = selectedRow; anchorColumn = selectedColumn }
        let y = CGFloat(selectedRow - (firstRowIsHeader ? 1 : 0)) * cellHeight + cellHeight
        scrollToVisible(NSRect(x: gutter + CGFloat(selectedColumn) * cellWidth, y: y - cellHeight, width: cellWidth + gutter, height: cellHeight * 2))
        needsDisplay = true
        onSelection?()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        select(at: convert(event.locationInWindow, from: nil), extending: event.modifierFlags.contains(.shift))
    }
    override func mouseDragged(with event: NSEvent) {
        autoscroll(with: event)
        select(at: convert(event.locationInWindow, from: nil), extending: true)
    }
    private func select(at point: NSPoint, extending: Bool) {
        guard point.x >= visibleRect.minX + gutter, point.y >= visibleRect.minY + cellHeight else { return }
        select(row: Int((point.y - cellHeight) / cellHeight) + (firstRowIsHeader ? 1 : 0), column: Int((point.x - gutter) / cellWidth), extending: extending)
    }
    override func keyDown(with event: NSEvent) {
        let shift = event.modifierFlags.contains(.shift)
        let command = event.modifierFlags.contains(.command)
        if command, event.charactersIgnoringModifiers?.lowercased() == "c" { onCopy?(); return }
        var row = selectedRow, column = selectedColumn
        switch event.keyCode {
        case 123: column = command ? 0 : column - 1
        case 124: column = command ? columnCount - 1 : column + 1
        case 125: row = command ? rowCount - 1 : row + 1
        case 126: row = command ? 0 : row - 1
        case 115: row = 0; column = 0
        case 119: row = rowCount - 1; column = columnCount - 1
        case 116: row -= max(1, Int(visibleRect.height / cellHeight) - 1)
        case 121: row += max(1, Int(visibleRect.height / cellHeight) - 1)
        case 48:
            if shift { window?.selectPreviousKeyView(self) } else { window?.selectNextKeyView(self) }
            return
        default: super.keyDown(with: event); return
        }
        select(row: row, column: column, extending: shift)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "c" { onCopy?(); return true }
        return super.performKeyEquivalent(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        drawCount += 1
        SurfaceToken.tileBody.color.nsColor(in: self).setFill(); dirtyRect.intersection(bounds).fill()
        let viewport = visibleRect
        guard viewport.width > 0, viewport.height > 0 else { visibleCellCount = 0; return }
        let firstColumn = visibleColumns.lowerBound
        let lastColumn = visibleColumns.upperBound
        let rows = visibleRows
        visibleCellCount = rows.count * (lastColumn - firstColumn)
        for row in rows {
            let y = cellHeight + CGFloat(row - (firstRowIsHeader ? 1 : 0)) * cellHeight
            for column in firstColumn..<lastColumn {
                let rect = NSRect(x: gutter + CGFloat(column) * cellWidth, y: y, width: cellWidth, height: cellHeight)
                if selectedRows.contains(row), selectedColumns.contains(column) {
                    AgentSurfaceRole.rowSelected.color.nsColor(in: self).setFill(); rect.fill()
                }
                paintCell(valueAt?(row, column) ?? "…", in: rect, secondary: false)
                LineToken.separator.color.nsColor(in: self).setStroke()
                let line = NSBezierPath(); line.move(to: NSPoint(x: rect.maxX, y: rect.minY)); line.line(to: NSPoint(x: rect.maxX, y: rect.maxY)); line.line(to: NSPoint(x: rect.minX, y: rect.maxY)); line.lineWidth = 0.5; line.stroke()
                if row == selectedRow, column == selectedColumn {
                    LineToken.borderStrong.color.nsColor(in: self).setStroke()
                    let ring = NSBezierPath(rect: rect.insetBy(dx: 1, dy: 1)); ring.lineWidth = 1; ring.stroke()
                }
            }
        }
        // Frozen row numbers and column headings are painted over the cells.
        SurfaceToken.tileChrome.color.nsColor(in: self).setFill()
        NSRect(x: viewport.minX, y: viewport.minY, width: gutter, height: viewport.height).fill()
        NSRect(x: viewport.minX, y: viewport.minY, width: viewport.width, height: cellHeight).fill()
        for row in rows {
            let y = cellHeight + CGFloat(row - (firstRowIsHeader ? 1 : 0)) * cellHeight
            paintCell(String(row + 1), in: NSRect(x: viewport.minX, y: y, width: gutter, height: cellHeight), secondary: true)
        }
        for column in firstColumn..<lastColumn {
            let title = firstRowIsHeader ? (valueAt?(0, column) ?? "…") : "Column \(column + 1)"
            paintCell(title, in: NSRect(x: gutter + CGFloat(column) * cellWidth, y: viewport.minY, width: cellWidth, height: cellHeight), secondary: true)
        }
        SurfaceToken.tileChrome.color.nsColor(in: self).setFill()
        NSRect(x: viewport.minX, y: viewport.minY, width: gutter, height: cellHeight).fill()
    }

    private func paintCell(_ text: String, in rect: NSRect, secondary: Bool) {
        guard rect.intersects(visibleRect) else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.token(secondary ? .label : .bodyMono),
            .foregroundColor: (secondary ? TextToken.textSecondary : .textPrimary).color.nsColor(in: self),
            .paragraphStyle: paragraph
        ]
        // Bounded rendering even for a multi-megabyte field. Inspector/copy keep
        // the complete original string; the grid is explicitly a single-line view.
        let display = String(decoding: text.utf8.prefix(2_048), as: UTF8.self).replacingOccurrences(of: "\n", with: " ↵ ").replacingOccurrences(of: "\r", with: " ")
        (display as NSString).draw(in: rect.insetBy(dx: 8, dy: 5), withAttributes: attributes)
    }
}
