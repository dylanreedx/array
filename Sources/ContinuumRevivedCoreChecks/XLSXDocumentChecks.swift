import Foundation
import ContinuumRevivedCore

/// Tiny independently assembled OOXML fixtures exercise the complete archive →
/// XML → sparse-value path without Office, network access or a Python runtime.
func runXLSXDocumentChecks() {
    let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("array-xlsx-check-\(UUID().uuidString)")
    do { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    catch { expect(false, "XLSX scratch: \(error)"); return }
    defer { try? FileManager.default.removeItem(at: root) }
    func load(sheet: String, date1904: Bool = false, extra: [(String, String)] = [], limits: XLSXDocument.Limits = .init(), cancelled: @escaping @Sendable () -> Bool = { false }) throws -> XLSXDocument {
        let files = [
            ("xl/workbook.xml", "<workbook xmlns:r=\"urn:relationships\"><workbookPr date1904=\"\(date1904 ? 1 : 0)\"/><sheets><sheet name=\"Visible\" r:id=\"rId1\"/><sheet name=\"Hidden\" state=\"veryHidden\" r:id=\"rId2\"/></sheets></workbook>"),
            ("xl/_rels/workbook.xml.rels", "<Relationships><Relationship Id=\"rId1\" Target=\"worksheets/sheet1.xml\"/><Relationship Id=\"rId2\" Target=\"worksheets/sheet2.xml\"/></Relationships>"),
            ("xl/worksheets/sheet1.xml", sheet),
            ("xl/worksheets/sheet2.xml", "<worksheet><sheetData><row><c r=\"A1\"><v>9</v></c></row></sheetData></worksheet>"),
            ("xl/sharedStrings.xml", "<sst><si><r><t>00</t></r><r><t>123</t></r><rPh><t>phonetic</t></rPh></si></sst>"),
            ("xl/styles.xml", "<styleSheet><cellXfs><xf numFmtId=\"0\"/><xf numFmtId=\"14\"/></cellXfs></styleSheet>")
        ] + extra
        let url = root.appendingPathComponent(UUID().uuidString + ".xlsx")
        try xlsxStoredZIP(files).write(to: url)
        let snapshot = try SecureFileSnapshot.capture(path: url.path, maxBytes: 2 * 1_024 * 1_024)
        return try XLSXDocument.load(snapshot: snapshot, limits: limits, cancelled: cancelled)
    }
    let sheet = """
    <worksheet><sheetData><row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="inlineStr"><is><t>large ID 9007199254740993</t></is></c><c r="C1"><f>1+2</f><v>3</v></c><c r="D1"><f>NOW()</f></c><c r="F1" s="1"><v>61</v></c><c r="G1" t="b"><v>1</v></c><c r="H1" t="e"><v>#DIV/0!</v></c></row><row r="1000"><c r="Z1000"><v>9007199254740993</v></c></row></sheetData><mergeCells><mergeCell ref="A1:B1"/></mergeCells></worksheet>
    """
    do {
        let visibility = try load(sheet: #"<worksheet><cols><col min="2" max="2" hidden="1"/></cols><sheetData><row r="1"><c r="A1"><v>1</v></c><c r="B1"><v>2</v></c></row><row r="2" hidden="1"><c r="A2"><v>3</v></c></row></sheetData></worksheet>"#)
        expect(visibility.visibleSheets[0].value(row: 0, column: 0)?.raw == "1" && visibility.visibleSheets[0].value(row: 0, column: 1) == nil && visibility.visibleSheets[0].value(row: 1, column: 0) == nil, "hidden rows and columns must not expose values through the data view")
        let document = try load(sheet: sheet)
        expect(document.sheets.count == 2 && document.visibleSheets.count == 1, "hidden and very-hidden sheets are excluded by default")
        let first = document.visibleSheets[0]
        expect(first.name == "Visible" && first.rowCount == 1_000 && first.columnCount == 26 && first.cells.count == 8, "sparse shape does not materialize empty cells")
        expect(first.value(row: 0, column: 0)?.display == "00123", "rich shared strings preserve exact text and omit phonetic runs")
        expect(first.value(row: 999, column: 25)?.raw == "9007199254740993", "numeric raw values preserve integers beyond double precision")
        expect(first.value(row: 0, column: 2)?.formula == "1+2" && first.value(row: 0, column: 2)?.cached == "3", "formula source and cached result remain distinct")
        expect(first.value(row: 0, column: 3)?.cached == nil && first.value(row: 0, column: 3)?.display == "No cached result", "missing formula cache is explicit")
        expect(first.value(row: 0, column: 4) == nil, "missing cells remain missing")
        expect(first.value(row: 0, column: 5)?.display == "1900-03-01", "1900 date system handles the leap-day discontinuity")
        expect(first.value(row: 0, column: 6)?.display == "TRUE" && first.value(row: 0, column: 7)?.type == .error, "boolean and error types remain explicit")
        expect(first.mergedRanges == ["A1:B1"], "merged ranges are exposed without inventing duplicate values")
        let dated = "<worksheet><sheetData><row><c r=\"A1\" s=\"1\"><v>0</v></c></row></sheetData></worksheet>"
        let newer = try load(sheet: dated, date1904: true)
        expect(newer.visibleSheets[0].value(row: 0, column: 0)?.display == "1904-01-01", "1904 epoch uses its own date base")
        let leap = try load(sheet: dated.replacingOccurrences(of: "<v>0</v>", with: "<v>60</v>"))
        expect(leap.visibleSheets[0].value(row: 0, column: 0)?.display == "1900-02-29 (Excel leap day)", "Excel fictitious leap day is labeled rather than silently corrected")
        for malicious in [
            "<!DOCTYPE worksheet><worksheet/>",
            "<!DOCTYPE worksheet [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><worksheet>&x;</worksheet>",
            "<worksheet><sheetData><row><c r=\"XFE1\"><v>1</v></c></row></sheetData></worksheet>",
            "<worksheet><sheetData><row><c r=\"A1\" t=\"s\"><v>99</v></c></row></sheetData></worksheet>",
            "<worksheet><sheetData><row><c r=\"A1\"><v>1</v></c><c r=\"A1\"><v>2</v></c></row></sheetData></worksheet>"
        ] {
            do { _ = try load(sheet: malicious); expect(false, "malformed or active XML rejects") }
            catch is XLSXDocument.Failure { expect(true, "malformed or active XML rejects before rendering") }
        }
        do {
            _ = try load(sheet: sheet, extra: [("xl/worksheets/_rels/sheet1.xml.rels", "<Relationships><Relationship TargetMode=\"External\" Target=\"https://example.com/\"/></Relationships>")])
            expect(false, "external relationships reject")
        } catch let error as XLSXDocument.Failure { expect(error == .externalRelationship, "external relationships reject even outside workbook relationships") }
        var tiny = XLSXDocument.Limits(); tiny.maxCells = 2
        do { _ = try load(sheet: sheet, limits: tiny); expect(false, "cell limit rejects") }
        catch let error as XLSXDocument.Failure { expect(error == .limit, "aggregate cell count is bounded") }
        tiny = .init(); tiny.maxTextBytes = 2
        do { _ = try load(sheet: sheet, limits: tiny); expect(false, "text limit rejects") }
        catch let error as XLSXDocument.Failure { expect(error == .limit, "aggregate retained text is bounded") }
        do { _ = try load(sheet: sheet, cancelled: { true }); expect(false, "cancelled workbook rejects") }
        catch { expect(true, "cancelled workbook does not publish a document") }
    } catch { expect(false, "XLSX document witness: \(error)") }
}

private func xlsxStoredZIP(_ files: [(String, String)]) -> Data {
    var output = Data(), central = Data()
    func u16(_ value: Int) -> Data { var value = UInt16(value).littleEndian; return withUnsafeBytes(of: &value) { Data($0) } }
    func u32(_ value: UInt32) -> Data { var value = value.littleEndian; return withUnsafeBytes(of: &value) { Data($0) } }
    func crc(_ bytes: Data) -> UInt32 {
        var result: UInt32 = 0xFFFFFFFF
        for byte in bytes { result ^= UInt32(byte); for _ in 0..<8 { result = (result >> 1) ^ (result & 1 == 1 ? 0xEDB88320 : 0) } }
        return result ^ 0xFFFFFFFF
    }
    for (path, contents) in files {
        let name = Data(path.utf8), data = Data(contents.utf8), offset = output.count, checksum = crc(data)
        let localParts: [Data] = [u32(0x04034B50), u16(20), u16(0), u16(0), u16(0), u16(0), u32(checksum), u32(UInt32(data.count)), u32(UInt32(data.count)), u16(name.count), u16(0), name, data]
        for part in localParts { output.append(part) }
        let centralParts: [Data] = [u32(0x02014B50), u16(20), u16(20), u16(0), u16(0), u16(0), u16(0), u32(checksum), u32(UInt32(data.count)), u32(UInt32(data.count)), u16(name.count), u16(0), u16(0), u16(0), u16(0), u32(0), u32(UInt32(offset)), name]
        for part in centralParts { central.append(part) }
    }
    let offset = output.count
    output += central
    let endParts: [Data] = [u32(0x06054B50), u16(0), u16(0), u16(files.count), u16(files.count), u32(UInt32(central.count)), u32(UInt32(offset)), u16(0)]
    for part in endParts { output.append(part) }
    return output
}
