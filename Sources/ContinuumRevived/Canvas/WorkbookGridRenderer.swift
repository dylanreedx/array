import AppKit
import ContinuumRevivedCore
import ContinuumRevivedAgentUI

/// A projected sheet keeps the admission lease alive even while a page/copy
/// request outlives its host. Hidden sheets are never included in the picker.
final class WorkbookGridSource: FileGridDataSource, @unchecked Sendable {
    private struct Content {
        let sheet: XLSXDocument.Sheet
        let owner: FileContentLoad
        let viewerLease: FileContentBudget.Lease
    }
    private let lock = NSLock()
    private var content: Content?
    let rowCount: Int
    let columnCount: Int
    var encodingName: String { "XLSX · cached values" }
    init(sheet: XLSXDocument.Sheet, owner: FileContentLoad, viewerLease: FileContentBudget.Lease) {
        content = Content(sheet: sheet, owner: owner, viewerLease: viewerLease)
        rowCount = sheet.rowCount; columnCount = sheet.columnCount
    }
    func releaseSource() { lock.withLock { content = nil } }
    private func borrow() throws -> Content {
        guard let value = lock.withLock({ content }) else { throw CancellationError() }
        return value
    }
    func inspectCell(row: Int, column: Int) -> String? {
        guard let value = try? borrow() else { return nil }
        defer { withExtendedLifetime(value) {} }
        guard let cell = value.sheet.value(row: row, column: column) else { return "Blank cell (no stored value)" }
        return "Display: \(cell.display)\nRaw: \(cell.raw)\nType: \(cell.type.rawValue)\nFormula: \(cell.formula ?? "None")\nCached result: \(cell.cached ?? "Missing")"
    }
    func nextMatch(query: String, afterRow: Int, column: Int) throws -> FileGridMatch? {
        let value = try borrow()
        defer { withExtendedLifetime(value) {} }
        return try Self.nextSparseMatch(query: query, afterRow: afterRow, column: column,
            cells: value.sheet.cells.lazy.filter { value.sheet.isCellVisible(reference: $0.key) }.map { ($0.key, $0.value.display) })
    }
    static func nextSparseMatch<S: Sequence>(query: String, afterRow: Int, column: Int,
                                            cells: S) throws -> FileGridMatch? where S.Element == (String, String) {
        guard !query.isEmpty else { return nil }
        var following: FileGridMatch?, wrapped: FileGridMatch?
        func earlier(_ a: FileGridMatch, than b: FileGridMatch?) -> Bool {
            b == nil || a.row < b!.row || (a.row == b!.row && a.column < b!.column)
        }
        for (address, value) in cells {
            try Task.checkCancellation()
            guard value.localizedCaseInsensitiveContains(query) else { continue }
            var c = 0, r = 0, readingRow = false
            for byte in address.utf8 {
                if byte >= 65 && byte <= 90 && !readingRow { c = c * 26 + Int(byte - 64) }
                else if byte >= 48 && byte <= 57 { readingRow = true; r = r * 10 + Int(byte - 48) }
                else { r = 0; break }
            }
            guard r > 0, c > 0 else { continue }
            let match = FileGridMatch(row: r - 1, column: c - 1)
            if match.row > afterRow || (match.row == afterRow && match.column > column) {
                if earlier(match, than: following) { following = match }
            } else if earlier(match, than: wrapped) { wrapped = match }
        }
        return following ?? wrapped
    }
    func rows(in range: Range<Int>, columns: Range<Int>?) throws -> [[String]] {
        let value = try borrow()
        defer { withExtendedLifetime(value) {} }
        guard range.count <= 256, range.lowerBound >= 0, range.upperBound <= rowCount else { throw DelimitedFileDocument.Failure.invalidRange }
        let projection = columns ?? 0..<columnCount
        guard projection.lowerBound >= 0, projection.upperBound <= columnCount,
              range.count * projection.count <= 65_536 else { throw DelimitedFileDocument.Failure.pageLimit }
        var result: [[String]] = [], cost = 0
        for row in range {
            try Task.checkCancellation()
            var values: [String] = []
            for column in projection {
                let text = value.sheet.value(row: row, column: column)?.display ?? ""
                cost += text.utf8.count
                guard cost <= 8 * 1_024 * 1_024 else { throw DelimitedFileDocument.Failure.pageLimit }
                values.append(text)
            }
            result.append(values)
        }
        return result
    }
}

/// Captured work retains this revocable source, not its backend forever. Each
/// actual read borrows the backend and its admission until the read completes.
final class RetainedDelimitedSource: FileGridDataSource, @unchecked Sendable {
    private struct Content {
        let document: DelimitedFileDocument
        let owner: FileContentLoad
        let viewerLease: FileContentBudget.Lease
    }
    private let lock = NSLock()
    private var content: Content?
    let rowCount: Int
    let columnCount: Int
    let encodingName: String
    init(document: DelimitedFileDocument, owner: FileContentLoad, viewerLease: FileContentBudget.Lease) {
        rowCount = document.rowCount; columnCount = document.columnCount; encodingName = document.encodingName
        content = Content(document: document, owner: owner, viewerLease: viewerLease)
    }
    func releaseSource() { lock.withLock { content = nil } }
    func rows(in range: Range<Int>, columns: Range<Int>?) throws -> [[String]] {
        guard let value = lock.withLock({ content }) else { throw CancellationError() }
        defer { withExtendedLifetime(value) {} }
        return try value.document.rows(in: range, columns: columns, cancelled: { Task.isCancelled })
    }
}

@MainActor
final class WorkbookGridRenderer: NSView, FileTileRenderer {
    private(set) var workbook: XLSXDocument?
    private var owner: FileContentLoad?
    private var viewerLease: FileContentBudget.Lease?
    private let sheetChoice = ChoiceButton(title: "Sheet")
    private let notice = NSTextField(labelWithString: "")
    private var grid: DelimitedGridRenderer?
    private(set) var revision: UInt64 = 1
    var onRevisionChange: (() -> Void)?
    var view: NSView { self }
    var focusView: NSView { grid?.focusView ?? self }
    var scrollOffsets: [CGPoint] { grid?.scrollOffsets ?? [] }
    var qaSelectedSheet: String? { sheetChoice.selectedID }
    var qaGrid: DelimitedGridRenderer? { grid }

    init(workbook: XLSXDocument, owner: FileContentLoad, viewerLease: FileContentBudget.Lease) {
        self.workbook = workbook; self.owner = owner; self.viewerLease = viewerLease
        super.init(frame: .zero)
        clipsToBounds = true
        let sheets = workbook.visibleSheets
        sheetChoice.items = sheets.enumerated().map { ChoiceItem(id: String($0.offset), title: $0.element.name) }
        sheetChoice.onSelection = { [weak self] item in
            guard let index = Int(item.id) else { return }
            self?.selectSheet(index)
        }
        notice.font = .token(.caption)
        notice.stringValue = sheets.isEmpty ? "No visible sheets in this workbook" : "Read-only · cached formulas · data view"
        notice.toolTip = workbook.notices.joined(separator: "\n")
        notice.setAccessibilityLabel(notice.toolTip ?? notice.stringValue)
        addSubview(sheetChoice); addSubview(notice)
        selectSheet(0)
        applyTheme()
    }
    required init?(coder: NSCoder) { nil }
    func selectSheet(_ index: Int) {
        guard let workbook, let owner, let viewerLease else { return }
        let sheets = workbook.visibleSheets
        guard sheets.indices.contains(index) else { return }
        grid?.dispose(); grid?.view.removeFromSuperview()
        sheetChoice.selectedID = String(index)
        let replacement = DelimitedGridRenderer(source: WorkbookGridSource(sheet: sheets[index], owner: owner, viewerLease: viewerLease), title: sheets[index].name)
        replacement.onRevisionChange = { [weak self] in self?.changed() }
        grid = replacement; addSubview(replacement.view)
        needsLayout = true; changed()
    }
    override func draw(_ dirtyRect: NSRect) {
        SurfaceToken.tileBody.color.nsColor(in: self).setFill()
        dirtyRect.intersection(bounds).fill()
    }
    override func layout() {
        super.layout()
        let picker = NSRect(x: 8, y: max(0, bounds.height - 30), width: min(180, bounds.width * 0.4), height: 24)
        if sheetChoice.frame != picker { sheetChoice.frame = picker }
        let label = NSRect(x: picker.maxX + 8, y: picker.minY + 3, width: max(0, bounds.width - picker.maxX - 16), height: 18)
        if notice.frame != label { notice.frame = label }
        let body = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - 36))
        if grid?.view.frame != body { grid?.view.frame = body }
    }
    private func changed() { revision &+= 1; onRevisionChange?() }
    func applyTheme() {
        needsDisplay = true
        sheetChoice.applyTokens()
        notice.textColor = TextToken.textSecondary.color.nsColor(in: self)
        grid?.applyTheme(); changed()
    }
    func setVisible(_ visible: Bool) { grid?.setVisible(visible) }
    func dispose() {
        grid?.dispose(); grid?.view.removeFromSuperview(); grid = nil
        workbook = nil; owner = nil; viewerLease = nil; onRevisionChange = nil
    }
}
