import ContinuumRevivedCore
import Foundation

/// Pure parser checks: no filesystem, GUI, subprocess or provider access.
func runDelimitedTextParserChecks() {
    func parse(_ bytes: [UInt8], split: Int, delimiter: UInt8 = 44,
               limits: DelimitedTextParser.Limits = .init()) throws -> [[String]] {
        var parser = try DelimitedTextParser(delimiter: delimiter, limits: limits)
        var rows: [[String]] = []
        try parser.append(Data(bytes.prefix(split))) { rows.append($0) }
        try parser.append(Data(bytes.dropFirst(split))) { rows.append($0) }
        try parser.finish { rows.append($0) }
        return rows
    }
    let fixtures: [(String, [[String]])] = [
        ("", []), ("\n", [[""]]), ("a,b,", [["a", "b", ""]]),
        ("a,b\r\nc\r\n", [["a", "b"], ["c"]]),
        ("\u{FEFF}id,value\n00123,9007199254740993", [["id", "value"], ["00123", "9007199254740993"]]),
        ("\"a,b\",\"x\"\"y\"\r\n\"line\r\nbreak\",😀é\n", [["a,b", "x\"y"], ["line\r\nbreak", "😀é"]]),
        ("\"\",NA, null ,=1+2\na", [["", "NA", " null ", "=1+2"], ["a"]]),
        ("a\rb\nc\r\n", [["a"], ["b"], ["c"]])
    ]
    for (input, expected) in fixtures {
        let bytes = Array(input.utf8)
        for split in 0...bytes.count {
            do { let actual = try parse(bytes, split: split); expect(actual == expected, "delimited strings must survive chunk boundary \(split) in \(input.debugDescription)") }
            catch { expect(false, "valid delimited fixture rejected: \(error)") }
        }
    }
    do {
        let tsv = Array("a\t\"b\tc\"\n\"d\ne\"\t".utf8)
        let actualTSV = try parse(tsv, split: 5, delimiter: 9)
        expect(actualTSV == [["a", "b\tc"], ["d\ne", ""]], "TSV must share quoted-field semantics")
        var parser = try DelimitedTextParser()
        var rows: [[String]] = []
        for byte in Array("\u{FEFF}\"😀\"\r\nlast,".utf8) {
            try parser.append(Data([byte])) { rows.append($0) }
        }
        try parser.finish { rows.append($0) }
        expect(rows == [["😀"], ["last", ""]], "single-byte chunks must retain BOM, scalar and CRLF state")
        expect(parser.recordCount == 2 && parser.bufferedBytes == 0, "successful finish must release pending row storage")
    } catch { expect(false, "incremental delimited parse failed: \(error)") }

    func rejects(_ bytes: [UInt8], _ kind: DelimitedTextParser.Failure.Kind,
                 limits: DelimitedTextParser.Limits = .init()) {
        do {
            _ = try parse(bytes, split: bytes.count / 2, limits: limits)
            expect(false, "delimited parser must reject \(kind)")
        } catch let error as DelimitedTextParser.Failure {
            expect(error.kind == kind, "expected \(kind), got \(error)")
        } catch { expect(false, "unexpected delimited error: \(error)") }
    }
    rejects(Array("\"unfinished".utf8), .unterminatedQuote)
    rejects(Array("a\"b".utf8), .unexpectedQuote)
    rejects(Array("\"a\"x".utf8), .unexpectedCharacterAfterQuote)
    rejects([0x61, 0xFF], .invalidUTF8)
    rejects([0xEF, 0xBB], .invalidUTF8)
    rejects(Array("abcd".utf8), .fieldLimit, limits: .init(maxFieldBytes: 3))
    rejects(Array("a,b,c".utf8), .columnLimit, limits: .init(maxColumns: 2))
    rejects(Array("a,b,c".utf8), .recordLimit, limits: .init(maxRecordBytes: 4))
    rejects(Array("a\nb".utf8), .rowLimit, limits: .init(maxRows: 1))
    rejects(Array("ab".utf8), .inputLimit, limits: .init(maxInputBytes: 1))
    do {
        var parser = try DelimitedTextParser(limits: .init(maxFieldBytes: 3))
        do { try parser.append(Data("abcd".utf8)) { _ in }; expect(false, "field budget must fail during append") }
        catch let failure as DelimitedTextParser.Failure {
            expect(failure.kind == .fieldLimit && failure.byteOffset == 3 && failure.recordNumber == 1,
                   "failure must report the exact source byte and logical record")
            expect(parser.bufferedBytes == 0, "failed parser must release retained content")
            do { try parser.finish { _ in }; expect(false, "failure must be sticky") }
            catch let repeated as DelimitedTextParser.Failure { expect(repeated == failure, "subsequent calls must retain original failure") }
        }
    } catch { expect(false, "failure-state check failed: \(error)") }
    do {
        var parser = try DelimitedTextParser(limits: .init(maxFieldBytes: 8, maxRecordBytes: 16))
        var delivered = 0
        var peakBuffered = 0
        for _ in 0..<10_000 {
            for byte in Array("abcd,efgh\r\n".utf8) {
                try parser.append(Data([byte])) { row in
                    expect(row == ["abcd", "efgh"], "streamed records must retain exact strings")
                    delivered += 1
                }
                peakBuffered = max(peakBuffered, parser.bufferedBytes)
            }
        }
        try parser.finish { _ in expect(false, "trailing CRLF must not mint another record") }
        expect(delivered == 10_000 && peakBuffered <= 8 && parser.bufferedBytes == 0,
               "retained parser content must stay bounded independently of delivered row count")
        do { try parser.append(Data()) { _ in }; expect(false, "finished parser must reject more input") }
        catch let failure as DelimitedTextParser.Failure {
            expect(failure.kind == .alreadyFinished, "finished parser must expose a typed lifecycle error")
        }
        do { _ = try DelimitedTextParser(delimiter: 34); expect(false, "quote delimiter is ambiguous") }
        catch let failure as DelimitedTextParser.Failure {
            expect(failure.kind == .invalidConfiguration, "bad dialect must fail before reading")
        }
        do { _ = try DelimitedTextParser(limits: .init(maxColumns: 0)); expect(false, "zero budget must fail") }
        catch let failure as DelimitedTextParser.Failure {
            expect(failure.kind == .invalidConfiguration, "invalid limits must not trap")
        }
    } catch { expect(false, "bounded stream check failed: \(error)") }
    print("DelimitedTextParserChecks passed")
}
