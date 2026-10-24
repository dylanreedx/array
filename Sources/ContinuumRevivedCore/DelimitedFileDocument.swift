import Foundation

/// Immutable, validated delimited-file revision. Only sparse record offsets are
/// retained; independent page readers make concurrent requests safe. The source
/// snapshot remains alive until this document and all synchronous reads finish.
public final class DelimitedFileDocument: @unchecked Sendable {
    public enum Failure: Error, Equatable, LocalizedError {
        case cancelled, inputLimit, invalidEncoding, invalidRange, pageLimit
        public var errorDescription: String? {
            switch self {
            case .cancelled: return "The table preview was cancelled."
            case .inputLimit: return "The table exceeds the 256 MiB preview limit."
            case .invalidEncoding: return "The table must contain valid UTF-8 or BOM-marked UTF-16 text."
            case .invalidRange: return "The requested table page is outside the document."
            case .pageLimit: return "The requested table page exceeds the preview memory limit."
            }
        }
    }
    public let rowCount: Int
    public let columnCount: Int
    public let encodingName: String
    public let delimiter: UInt8
    public var checkpointCount: Int { checkpoints.count }
    /// Fixed-width sparse offsets; excludes constant object/array overhead.
    public var indexByteCount: Int { checkpoints.count * MemoryLayout<UInt64>.stride }
    private static let maxBytes = 256 * 1_024 * 1_024
    private static let stride = 128
    private let snapshot: SecureFileSnapshot
    private let url: URL
    private let stagingDirectory: URL?
    private let checkpoints: [UInt64]
    deinit { if let stagingDirectory { try? FileManager.default.removeItem(at: stagingDirectory) } }

    private init(snapshot: SecureFileSnapshot, url: URL, stagingDirectory: URL?,
                 encodingName: String, delimiter: UInt8, checkpoints: [UInt64], rows: Int, columns: Int) {
        self.snapshot = snapshot; self.url = url; self.stagingDirectory = stagingDirectory
        self.encodingName = encodingName; self.delimiter = delimiter
        self.checkpoints = checkpoints; rowCount = rows; columnCount = columns
    }

    public static func load(snapshot: SecureFileSnapshot, delimiter: UInt8 = 44,
                            cancelled: @escaping @Sendable () -> Bool = { false }) throws -> DelimitedFileDocument {
        guard snapshot.byteCount <= maxBytes else { throw Failure.inputLimit }
        if cancelled() { throw Failure.cancelled }
        let prepared = try prepare(snapshot.url, cancelled: cancelled)
        var retained = false
        defer { if !retained, let directory = prepared.directory { try? FileManager.default.removeItem(at: directory) } }
        let handle = try FileHandle(forReadingFrom: prepared.url)
        defer { try? handle.close() }
        var parser = try DelimitedTextParser(delimiter: delimiter, limits: .init(maxInputBytes: maxBytes))
        var offsets: [UInt64] = []
        var rows = 0, columns = 0
        func accept(_ record: DelimitedTextParser.Record) {
            if rows % Self.stride == 0 { offsets.append(UInt64(record.byteOffset)) }
            rows += 1; columns = max(columns, record.fields.count)
        }
        while true {
            if cancelled() { throw Failure.cancelled }
            let data = try handle.read(upToCount: 64 * 1_024) ?? Data()
            if data.isEmpty { break }
            try parser.appendRecords(data, onRecord: accept)
        }
        if cancelled() { throw Failure.cancelled }
        try parser.finishRecords(onRecord: accept)
        let result = DelimitedFileDocument(snapshot: snapshot, url: prepared.url, stagingDirectory: prepared.directory,
                                           encodingName: prepared.encoding, delimiter: delimiter,
                                           checkpoints: offsets, rows: rows, columns: columns)
        retained = true
        return result
    }

    /// At most 256 rows and 8 MiB of returned UTF-8 payload. Column projection
    /// bounds retained page width; missing ragged cells remain missing (not empty).
    public func rows(in range: Range<Int>, columns: Range<Int>? = nil,
                     cancelled: @Sendable () -> Bool = { false }) throws -> [[String]] {
        guard range.lowerBound >= 0, range.upperBound <= rowCount,
              columns.map({ $0.lowerBound >= 0 && $0.upperBound <= columnCount }) ?? true else { throw Failure.invalidRange }
        guard range.count <= 256 else { throw Failure.pageLimit }
        if cancelled() { throw Failure.cancelled }
        if range.isEmpty { return [] }
        let checkpoint = range.lowerBound / Self.stride
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: checkpoints[checkpoint])
        var parser = try DelimitedTextParser(delimiter: delimiter, limits: .init(maxInputBytes: Self.maxBytes), stripUTF8BOM: false)
        var current = checkpoint * Self.stride
        var result: [[String]] = []
        var payload = 0
        var overflow = false
        func accept(_ record: DelimitedTextParser.Record) {
            defer { current += 1 }
            guard range.contains(current), !overflow else { return }
            let fields: [String]
            if let columns {
                let lower = min(columns.lowerBound, record.fields.count)
                let upper = min(columns.upperBound, record.fields.count)
                fields = Array(record.fields[lower..<upper])
            } else { fields = record.fields }
            let bytes = fields.reduce(0) { $0 + $1.utf8.count }
            guard bytes <= 8 * 1_024 * 1_024 - payload else { overflow = true; result.removeAll(); return }
            payload += bytes; result.append(fields)
        }
        while current < range.upperBound && !overflow {
            if cancelled() { throw Failure.cancelled }
            let data = try handle.read(upToCount: 64 * 1_024) ?? Data()
            if data.isEmpty { try parser.finishRecords(onRecord: accept); break }
            try parser.appendRecords(data, onRecord: accept)
        }
        if cancelled() { throw Failure.cancelled }
        if overflow { throw Failure.pageLimit }
        return result
    }

    /// Transcode BOM-marked UTF-16 incrementally, validating surrogate pairs
    /// across chunk boundaries. UTF-8 needs no additional private copy.
    private static func prepare(_ url: URL, cancelled: @Sendable () -> Bool) throws -> (url: URL, directory: URL?, encoding: String) {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        let prefix = try input.read(upToCount: 2) ?? Data()
        guard prefix == Data([0xFF, 0xFE]) || prefix == Data([0xFE, 0xFF]) else { return (url, nil, "UTF-8") }
        let little = prefix.first == 0xFF
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("array-table-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        var retained = false
        defer { if !retained { try? FileManager.default.removeItem(at: directory) } }
        let outputURL = directory.appendingPathComponent("table.utf8")
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw Failure.invalidEncoding }
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }
        var pendingByte: UInt8?, high: UInt16?
        var encoded = Data(), total = 0
        func flush() throws {
            guard encoded.count <= maxBytes - total else { throw Failure.inputLimit }
            total += encoded.count; try output.write(contentsOf: encoded); encoded.removeAll(keepingCapacity: true)
        }
        while true {
            if cancelled() { throw Failure.cancelled }
            let data = try input.read(upToCount: 64 * 1_024) ?? Data()
            if data.isEmpty { break }
            for byte in data {
                guard let first = pendingByte else { pendingByte = byte; continue }
                pendingByte = nil
                let unit = little ? UInt16(first) | UInt16(byte) << 8 : UInt16(first) << 8 | UInt16(byte)
                let scalar: UInt32
                if let previous = high {
                    guard (0xDC00...0xDFFF).contains(unit) else { throw Failure.invalidEncoding }
                    scalar = 0x10000 + (UInt32(previous) - 0xD800) * 0x400 + UInt32(unit) - 0xDC00; high = nil
                } else if (0xD800...0xDBFF).contains(unit) { high = unit; continue }
                else {
                    guard !(0xDC00...0xDFFF).contains(unit) else { throw Failure.invalidEncoding }
                    scalar = UInt32(unit)
                }
                guard let value = UnicodeScalar(scalar) else { throw Failure.invalidEncoding }
                encoded.append(contentsOf: String(value).utf8)
                if encoded.count >= 64 * 1_024 { try flush() }
            }
        }
        guard pendingByte == nil && high == nil else { throw Failure.invalidEncoding }
        if cancelled() { throw Failure.cancelled }
        try flush()
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: outputURL.path)
        retained = true
        return (outputURL, directory, little ? "UTF-16 LE" : "UTF-16 BE")
    }
}
