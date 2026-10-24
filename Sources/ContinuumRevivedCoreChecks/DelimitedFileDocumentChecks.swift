import ContinuumRevivedCore
import Foundation
import Darwin

/// Filesystem witnesses use private scratch revisions, never a project or GUI.
func runDelimitedFileDocumentChecks() {
    // Foundation may preserve /var's system symlink when resolving a temp URL;
    // capture deliberately requires every path component to be canonical.
    guard let canonical = realpath(FileManager.default.temporaryDirectory.path, nil) else {
        expect(false, "table scratch canonicalization"); return
    }
    let temporaryRoot = String(cString: canonical)
    free(canonical)
    let root = URL(fileURLWithPath: temporaryRoot, isDirectory: true)
        .appendingPathComponent("array-table-check-\(UUID().uuidString)")
    do { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    catch { expect(false, "table scratch creation: \(error)"); return }
    defer { try? FileManager.default.removeItem(at: root) }
    func document(_ data: Data, delimiter: UInt8 = 44) throws -> DelimitedFileDocument {
        let url = root.appendingPathComponent(UUID().uuidString + ".csv")
        try data.write(to: url)
        let snapshot = try SecureFileSnapshot.capture(path: url.path, maxBytes: 256 * 1_024 * 1_024)
        return try DelimitedFileDocument.load(snapshot: snapshot, delimiter: delimiter)
    }
    do {
        var text = "\u{FEFF}id,value,extra\r\n"
        for row in 1..<1_030 { text += "\(row),\"line\r\n\(row)\",00123\r\n" }
        let table = try document(Data(text.utf8))
        expect(table.rowCount == 1_030 && table.columnCount == 3, "table shape counts logical records, not quoted newlines")
        expect(table.checkpointCount == 9 && table.indexByteCount == 72, "index retains one fixed-width offset per 128 logical rows")
        let header = try table.rows(in: 0..<1)
        expect(header == [["id", "value", "extra"]], "BOM does not enter the first cell when paging")
        for row in [1, 127, 128, 129, 255, 256, 1_029] {
            let actual = try table.rows(in: row..<(row + 1), columns: 1..<3)
            expect(actual == [["line\r\n\(row)", "00123"]], "sparse page \(row) retains exact field values")
        }
        let ragged = try document(Data("a,b,c\nx\n,\"\"".utf8))
        let projected = try ragged.rows(in: 0..<3, columns: 1..<3)
        expect(projected == [["b", "c"], [], [""]], "missing ragged fields differ from empty values")
        let empty = try document(Data())
        let emptyRows = try empty.rows(in: 0..<0)
        expect(empty.rowCount == 0 && empty.checkpointCount == 0 && emptyRows.isEmpty, "empty documents need no checkpoint")
        do { _ = try table.rows(in: 0..<257); expect(false, "oversized pages reject") }
        catch let error as DelimitedFileDocument.Failure { expect(error == .pageLimit, "row page budget is typed") }
        do { _ = try table.rows(in: 1_030..<1_031); expect(false, "out of range pages reject") }
        catch let error as DelimitedFileDocument.Failure { expect(error == .invalidRange, "range errors are typed") }
        do { _ = try table.rows(in: 128..<129, cancelled: { true }); expect(false, "cancelled page reads reject") }
        catch let error as DelimitedFileDocument.Failure { expect(error == .cancelled, "page cancellation is typed") }

        // Independent expected rows stress offsets after CR-only separators,
        // quoted delimiters/escapes, blank records and a final unterminated row.
        let variedRows = (0..<520).map { row in ["\(row)", "quote \" and ,", row % 2 == 0 ? "" : "😀"] }
        let variedText = variedRows.map { "\($0[0]),\"quote \"\" and ,\",\($0[2])" }.joined(separator: "\r")
        let varied = try document(Data(variedText.utf8))
        for lower in [0, 126, 128, 255, 384, 518] {
            let upper = min(lower + 2, variedRows.count)
            let page = try varied.rows(in: lower..<upper)
            expect(page == Array(variedRows[lower..<upper]), "CR-only sparse pages preserve escaped quotes and final rows at \(lower)")
        }

        let unicode = "id\tvalue\r\n00123\t😀é\r\n"
        for (encoding, bom, name): (String.Encoding, [UInt8], String) in [(.utf16LittleEndian, [0xFF, 0xFE], "UTF-16 LE"), (.utf16BigEndian, [0xFE, 0xFF], "UTF-16 BE")] {
            let bytes = Data(bom) + unicode.data(using: encoding)!
            let utf16 = try document(bytes, delimiter: 9)
            let actual = try utf16.rows(in: 0..<2)
            expect(actual == [["id", "value"], ["00123", "😀é"]] && utf16.encodingName == name, "\(name) streaming decode preserves scalar pairs")
        }
        // Force a high/low surrogate pair across the transcoder's 64 KiB read.
        let boundary = String(repeating: "a", count: 32_767) + "😀\n"
        let splitPair = try document(Data([0xFF, 0xFE]) + boundary.data(using: .utf16LittleEndian)!)
        let decoded = try splitPair.rows(in: 0..<1)
        expect(decoded == [[String(repeating: "a", count: 32_767) + "😀"]], "UTF-16 surrogate pairs survive I/O chunk boundaries")
        for bytes: [UInt8] in [[0xFF, 0xFE, 0x00], [0xFF, 0xFE, 0x00, 0xD8], [0xFE, 0xFF, 0xDC, 0x00]] {
            do { _ = try document(Data(bytes)); expect(false, "malformed UTF-16 rejects") }
            catch let error as DelimitedFileDocument.Failure { expect(error == .invalidEncoding, "malformed UTF-16 produces an encoding error") }
        }
        let large = String(repeating: "v", count: 3 * 1_024 * 1_024)
        let wide = try document(Data((large + ",ok\n" + large + ",ok\n" + large + ",ok\n").utf8))
        do { _ = try wide.rows(in: 0..<3); expect(false, "payload budget rejects oversized returned pages") }
        catch let error as DelimitedFileDocument.Failure { expect(error == .pageLimit, "payload budget is typed") }
        let narrow = try wide.rows(in: 0..<3, columns: 1..<2)
        expect(narrow == [["ok"], ["ok"], ["ok"]], "projected pages bound output for wide records")
        let sourceURL = root.appendingPathComponent("immutable.csv")
        try Data("old,001\n".utf8).write(to: sourceURL)
        let snapshot = try SecureFileSnapshot.capture(path: sourceURL.path, maxBytes: 1_024)
        let immutable = try DelimitedFileDocument.load(snapshot: snapshot)
        try Data("new,999\n".utf8).write(to: sourceURL)
        let original = try immutable.rows(in: 0..<1)
        expect(original == [["old", "001"]], "table pages retain one immutable source revision")
        do { _ = try DelimitedFileDocument.load(snapshot: snapshot, cancelled: { true }); expect(false, "cancelled indexing rejects") }
        catch let error as DelimitedFileDocument.Failure { expect(error == .cancelled, "index cancellation is typed") }
    } catch { expect(false, "delimited file witness: \(error)") }
    print("DelimitedFileDocumentChecks passed")
}
