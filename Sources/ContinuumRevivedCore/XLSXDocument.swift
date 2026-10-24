import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// A deliberately bounded, read-only OOXML view. Formulas are never executed;
/// cached values and source values remain distinct. No relationship is fetched.
public struct XLSXDocument: Sendable {
    public struct Limits: Sendable {
        public var maxCells = 100_000
        public var maxTextBytes = 16 * 1_024 * 1_024
        public var maxXMLBytes = 16 * 1_024 * 1_024
        public var maxSheets = 128
        public init() {}
    }
    public enum Failure: Error, Equatable, LocalizedError {
        case malformed(String), limit, cancelled, externalRelationship
        public var errorDescription: String? {
            switch self {
            case .malformed(let detail): return "The workbook is unsupported or malformed: \(detail)."
            case .limit: return "The workbook exceeds the bounded preview limits."
            case .cancelled: return "Workbook preview was cancelled."
            case .externalRelationship: return "Workbooks with external relationships cannot be previewed safely."
            }
        }
    }
    public enum CellType: String, Sendable { case string, number, boolean, date, error, blank }
    public struct Cell: Sendable {
        public let raw: String
        public let display: String
        public let formula: String?
        public let cached: String?
        public let type: CellType
    }
    public struct Sheet: Sendable {
        public let name: String
        public let isHidden: Bool
        public let rowCount: Int
        public let columnCount: Int
        public let cells: [String: Cell]
        public let mergedRanges: [String]
        public let hiddenRows: Set<Int>
        public let hiddenColumns: [ClosedRange<Int>]
        public func isCellVisible(reference: String) -> Bool {
            guard let coordinate = XLSXDocument.coordinate(reference) else { return false }
            return !hiddenRows.contains(coordinate.0) && !hiddenColumns.contains(where: { $0.contains(coordinate.1) })
        }
        public func value(row: Int, column: Int) -> Cell? {
            guard row >= 0, row < 1_048_576, column >= 0, column < 16_384 else { return nil }
            guard !hiddenRows.contains(row), !hiddenColumns.contains(where: { $0.contains(column) }) else { return nil }
            return cells[XLSXDocument.address(row: row, column: column)]
        }
    }
    public let sheets: [Sheet]
    public var visibleSheets: [Sheet] { sheets.filter { !$0.isHidden } }
    public let notices: [String]

    public static func load(snapshot: SecureFileSnapshot, limits: Limits = .init(),
                            cancelled: @escaping @Sendable () -> Bool = { false }) throws -> XLSXDocument {
        guard limits.maxCells > 0, limits.maxTextBytes > 0, limits.maxXMLBytes > 0, limits.maxSheets > 0 else { throw Failure.limit }
        let archive = try BoundedZIPArchive(url: snapshot.url, cancelled: cancelled)
        var xmlBytes = 0
        func read(_ path: String) throws -> XMLNode {
            if cancelled() { throw Failure.cancelled }
            let data = try archive.data(for: path)
            guard data.count <= limits.maxXMLBytes - xmlBytes else { throw Failure.limit }
            xmlBytes += data.count
            return try XMLReader.read(data, cancelled: cancelled)
        }
        // Reject external links anywhere, including relationships not traversed by
        // the sheet loader. Reject macro-enabled content rather than imply support.
        guard !archive.entryNames.contains(where: { $0.lowercased().hasSuffix("vbaproject.bin") }) else { throw Failure.malformed("macros") }
        var relationships: [String: String] = [:]
        for path in archive.entryNames.filter({ $0.hasSuffix(".rels") }).sorted() {
            let root = try read(path)
            for rel in root.children where rel.name == "Relationship" {
                guard rel.attributes["TargetMode"]?.lowercased() != "external" else { throw Failure.externalRelationship }
                if path == "xl/_rels/workbook.xml.rels", let id = rel.attributes["Id"], let target = rel.attributes["Target"] {
                    guard relationships[id] == nil else { throw Failure.malformed("duplicate relationship") }
                    relationships[id] = try relationshipPath(target)
                }
            }
        }
        let workbook = try read("xl/workbook.xml")
        guard workbook.name == "workbook" else { throw Failure.malformed("workbook root") }
        let date1904 = ["1", "true"].contains(workbook.children.first(where: { $0.name == "workbookPr" })?.attributes["date1904"] ?? "")
        var shared: [String] = []
        var textBytes = 0
        func account(_ text: String) throws {
            guard text.utf8.count <= limits.maxTextBytes - textBytes else { throw Failure.limit }
            textBytes += text.utf8.count
        }
        if archive.entryNames.contains("xl/sharedStrings.xml") {
            let root = try read("xl/sharedStrings.xml")
            for item in root.children where item.name == "si" {
                guard shared.count < limits.maxCells else { throw Failure.limit }
                let value = item.textDescendants(named: "t")
                try account(value)
                shared.append(value)
            }
        }
        var dateStyles: Set<Int> = []
        var customStyles = false
        if archive.entryNames.contains("xl/styles.xml") {
            let styles = try read("xl/styles.xml")
            var formats: [Int: String] = [:]
            for item in styles.children.first(where: { $0.name == "numFmts" })?.children ?? [] {
                if let id = Int(item.attributes["numFmtId"] ?? ""), let format = item.attributes["formatCode"] { formats[id] = format }
            }
            for (index, item) in (styles.children.first(where: { $0.name == "cellXfs" })?.children ?? []).enumerated() {
                let id = Int(item.attributes["numFmtId"] ?? "0") ?? 0
                // Locale-dependent built-ins 27...36/50...58 vary by producer;
                // show raw values rather than guess their units.
                if ((14...17).contains(id) || id == 22) || formats[id].map(isDateFormat) == true { dateStyles.insert(index) }
                else if id != 0 { customStyles = true }
            }
        }
        let definitions = workbook.children.first(where: { $0.name == "sheets" })?.children.filter { $0.name == "sheet" } ?? []
        guard !definitions.isEmpty, definitions.count <= limits.maxSheets else { throw Failure.limit }
        var sheets: [Sheet] = []
        var totalCells = 0
        var missingCaches = false
        for definition in definitions {
            if cancelled() { throw Failure.cancelled }
            guard let name = definition.attributes["name"], let id = definition.attributes["r:id"], let path = relationships[id], path.hasPrefix("xl/") else { throw Failure.malformed("sheet relationship") }
            let root = try read(path)
            guard root.name == "worksheet" else { throw Failure.malformed("worksheet root") }
            var cells: [String: Cell] = [:]
            var rows = 0, columns = 0
            var hiddenRows: Set<Int> = [], hiddenColumns: [ClosedRange<Int>] = []
            for column in root.children.first(where: { $0.name == "cols" })?.children ?? [] {
                guard hiddenColumns.count < 16_384 else { throw Failure.limit }
                if ["1", "true"].contains(column.attributes["hidden"] ?? "") {
                    guard let lower = Int(column.attributes["min"] ?? ""), let upper = Int(column.attributes["max"] ?? ""),
                          lower >= 1, upper <= 16_384, lower <= upper else { throw Failure.malformed("hidden column") }
                    hiddenColumns.append((lower - 1)...(upper - 1))
                }
            }
            let declaredRows = root.children.first(where: { $0.name == "sheetData" })?.children ?? []
            guard declaredRows.count <= limits.maxCells else { throw Failure.limit }
            for row in declaredRows {
                let isHidden = ["1", "true"].contains(row.attributes["hidden"] ?? "")
                if isHidden, let number = Int(row.attributes["r"] ?? "") {
                    guard (1...1_048_576).contains(number) else { throw Failure.malformed("hidden row") }
                    hiddenRows.insert(number - 1)
                }
                for node in row.children where node.name == "c" {
                    if cancelled() { throw Failure.cancelled }
                    totalCells += 1
                    guard totalCells <= limits.maxCells else { throw Failure.limit }
                    guard let reference = node.attributes["r"], let coordinate = coordinate(reference), cells[reference] == nil else { throw Failure.malformed("cell coordinate") }
                    if isHidden { hiddenRows.insert(coordinate.0) }
                    rows = max(rows, coordinate.0 + 1); columns = max(columns, coordinate.1 + 1)
                    let formula = node.children.first(where: { $0.name == "f" })?.text
                    let cached = node.children.first(where: { $0.name == "v" })?.text
                    let raw = cached ?? ""
                    var display = raw
                    var type: CellType = .number
                    switch node.attributes["t"] ?? "n" {
                    case "s":
                        guard let index = Int(raw), shared.indices.contains(index) else { throw Failure.malformed("shared string index") }
                        display = shared[index]; type = .string
                    case "inlineStr": display = node.children.first(where: { $0.name == "is" })?.textDescendants(named: "t") ?? ""; type = .string
                    case "str": type = .string
                    case "b":
                        guard raw == "0" || raw == "1" else { throw Failure.malformed("boolean") }
                        display = raw == "1" ? "TRUE" : "FALSE"; type = .boolean
                    case "e": type = .error
                    case "d": type = .date
                    case "n":
                        if raw.isEmpty { type = .blank }
                        else if let value = Double(raw), value.isFinite {
                            if let style = Int(node.attributes["s"] ?? ""), dateStyles.contains(style) {
                                display = dateDisplay(value, date1904: date1904); type = .date
                            }
                        } else { throw Failure.malformed("numeric value") }
                    default: throw Failure.malformed("cell type")
                    }
                    if formula != nil && cached == nil { display = "No cached result"; missingCaches = true }
                    try account(raw); try account(display); if let formula { try account(formula) }
                    cells[reference] = Cell(raw: raw, display: display, formula: formula, cached: cached, type: type)
                }
            }
            let merges = root.children.first(where: { $0.name == "mergeCells" })?.children.compactMap { $0.attributes["ref"] } ?? []
            for range in merges {
                let pieces = range.split(separator: ":")
                guard pieces.count == 2, let a = coordinate(String(pieces[0])), let b = coordinate(String(pieces[1])), a.0 <= b.0, a.1 <= b.1 else { throw Failure.malformed("merged range") }
            }
            sheets.append(Sheet(name: name, isHidden: ["hidden", "veryHidden"].contains(definition.attributes["state"] ?? ""), rowCount: rows, columnCount: columns, cells: cells, mergedRanges: merges, hiddenRows: hiddenRows, hiddenColumns: hiddenColumns))
        }
        var notices = ["Read-only values. Formulas are not recalculated; cached results may be stale.", "Charts, images, layout and conditional formatting are not rendered."]
        if sheets.contains(where: { !$0.hiddenRows.isEmpty || !$0.hiddenColumns.isEmpty }) { notices.append("Hidden row and column values are omitted; cell coordinates are preserved.") }
        if missingCaches { notices.append("Some formulas have no cached result.") }
        if customStyles { notices.append("Some number formats are shown as raw values.") }
        if sheets.contains(where: { !$0.mergedRanges.isEmpty }) { notices.append("Merged ranges are indicated; values remain in their anchor cells.") }
        return XLSXDocument(sheets: sheets, notices: notices)
    }

    private static func relationshipPath(_ target: String) throws -> String {
        guard !target.isEmpty, !target.contains(":"), !target.contains("\\"), !target.contains("%"), !target.contains("#"), !target.contains("?") else { throw Failure.malformed("relationship target") }
        let path = target.hasPrefix("/") ? String(target.dropFirst()) : "xl/" + target
        guard path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw Failure.malformed("relationship traversal") }
        return path
    }
    private static func coordinate(_ reference: String) -> (Int, Int)? {
        var col = 0, row = 0, digits = false
        for byte in reference.utf8 {
            if (65...90).contains(byte), !digits { col = col * 26 + Int(byte - 64); if col > 16_384 { return nil } }
            else if (48...57).contains(byte), col > 0 { digits = true; row = row * 10 + Int(byte - 48); if row > 1_048_576 { return nil } }
            else { return nil }
        }
        guard digits, row > 0, col > 0 else { return nil }
        return (row - 1, col - 1)
    }
    private static func address(row: Int, column: Int) -> String {
        var col = column + 1, letters = ""
        while col > 0 { col -= 1; letters = String(UnicodeScalar(65 + col % 26)!) + letters; col /= 26 }
        return letters + String(row + 1)
    }
    private static func isDateFormat(_ format: String) -> Bool {
        var quoted = false, bracket = false, escaped = false, result = ""
        for char in format.lowercased() {
            if escaped { escaped = false; continue }
            if char == "\\" || char == "_" || char == "*" { escaped = true; continue }
            if char == "\"" { quoted.toggle(); continue }
            if quoted { continue }
            if char == "[" { bracket = true; continue }; if char == "]" { bracket = false; continue }
            if !bracket { result.append(char) }
        }
        return result.contains("y") || result.contains("d")
    }
    private static func dateDisplay(_ serial: Double, date1904: Bool) -> String {
        // ISO display is deliberate; it does not pretend to reproduce Excel's
        // locale or every number-format token. Preserve the fictitious leap day.
        guard serial >= 0, serial < 2_958_466 else { return String(serial) }
        if !date1904 && floor(serial) == 60 { return "1900-02-29 (Excel leap day)" }
        let seconds = (serial - (date1904 ? 24_107 : (serial < 60 ? 25_568 : 25_569))) * 86_400
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = serial == floor(serial) ? "yyyy-MM-dd" : "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: Date(timeIntervalSince1970: seconds))
    }
}

private final class XMLNode {
    let name: String
    let attributes: [String: String]
    var text = ""
    var children: [XMLNode] = []
    init(_ name: String, _ attributes: [String: String]) { self.name = name; self.attributes = attributes }
    func textDescendants(named name: String) -> String {
        if self.name == name { return text }
        return children.filter { $0.name != "rPh" }.map { $0.textDescendants(named: name) }.joined()
    }
}
private final class XMLReader: NSObject, XMLParserDelegate {
    var stack: [XMLNode] = []
    var root: XMLNode?
    var count = 0
    var failure: XLSXDocument.Failure?
    let cancelled: @Sendable () -> Bool
    init(cancelled: @escaping @Sendable () -> Bool) { self.cancelled = cancelled }
    static func read(_ data: Data, cancelled: @escaping @Sendable () -> Bool) throws -> XMLNode {
        for encoding: String.Encoding in [.utf8, .utf16LittleEndian, .utf16BigEndian, .utf32LittleEndian, .utf32BigEndian] {
            for marker in ["<!DOCTYPE", "<!ENTITY"] {
                if let bytes = marker.data(using: encoding), data.range(of: bytes) != nil { throw XLSXDocument.Failure.malformed("DTD") }
            }
        }
        // XMLParser's declaration callbacks cover UTF-16 too; byte scanning alone
        // would permit encoding-based DTD bypasses.
        let reader = XMLReader(cancelled: cancelled), parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false; parser.delegate = reader
        let ok = parser.parse()
        if let failure = reader.failure { throw failure }
        guard ok, let root = reader.root, reader.stack.isEmpty else { throw XLSXDocument.Failure.malformed("XML") }
        return root
    }
    func reject(_ parser: XMLParser, _ failure: XLSXDocument.Failure) { self.failure = failure; parser.abortParsing() }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        if cancelled() { reject(parser, .cancelled); return }
        count += 1
        guard count <= 600_000, stack.count < 64 else { reject(parser, .limit); return }
        let node = XMLNode(elementName, attributes)
        if let parent = stack.last { parent.children.append(node) }
        else if root == nil { root = node }
        else { reject(parser, .malformed("multiple XML roots")); return }
        stack.append(node)
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) { if !stack.isEmpty { stack.removeLast() } }
    func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text.append(string) }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { guard let value = String(data: CDATABlock, encoding: .utf8) else { reject(parser, .malformed("CDATA")); return }; stack.last?.text.append(value) }
    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) { reject(parser, .malformed("DTD")) }
    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) { reject(parser, .malformed("DTD")) }
    func parser(_ parser: XMLParser, foundElementDeclarationWithName elementName: String, model: String) { reject(parser, .malformed("DTD")) }
    func parser(_ parser: XMLParser, foundAttributeDeclarationWithName attributeName: String, forElement elementName: String, type: String?, defaultValue: String?) { reject(parser, .malformed("DTD")) }
    func parser(_ parser: XMLParser, foundNotationDeclarationWithName name: String, publicID: String?, systemID: String?) { reject(parser, .malformed("DTD")) }
    func parser(_ parser: XMLParser, foundUnparsedEntityDeclarationWithName name: String, publicID: String?, systemID: String?, notationName: String?) { reject(parser, .malformed("DTD")) }
    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? { reject(parser, .externalRelationship); return nil }
}
