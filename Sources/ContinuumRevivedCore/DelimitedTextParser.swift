import Foundation

/// Incremental, strict UTF-8 CSV/TSV parser. Retains only the current bounded
/// logical record; completed rows belong to the caller. Does not infer headers,
/// trim strings, coerce types, skip blank records or access the filesystem.
public struct DelimitedTextParser: Sendable {
    public struct Limits: Equatable, Sendable {
        public var maxFieldBytes: Int
        /// Raw record bytes including delimiters, quotes and its first terminator
        /// byte; the optional LF following an outside-quote CR is excluded.
        public var maxRecordBytes: Int
        public var maxColumns: Int
        public var maxRows: Int
        public var maxInputBytes: Int

        public init(maxFieldBytes: Int = 4 * 1_024 * 1_024,
                    maxRecordBytes: Int = 4 * 1_024 * 1_024,
                    maxColumns: Int = 4_096, maxRows: Int = 1_000_000,
                    maxInputBytes: Int = 64 * 1_024 * 1_024) {
            self.maxFieldBytes = maxFieldBytes
            self.maxRecordBytes = maxRecordBytes
            self.maxColumns = maxColumns
            self.maxRows = maxRows
            self.maxInputBytes = maxInputBytes
        }
    }

    public struct Failure: Error, Equatable, Sendable {
        public enum Kind: String, Sendable {
            case invalidConfiguration, alreadyFinished, invalidUTF8
            case unexpectedQuote, unexpectedCharacterAfterQuote, unterminatedQuote
            case fieldLimit, recordLimit, columnLimit, rowLimit, inputLimit
        }
        public let kind: Kind
        /// Zero-based byte offset into the original input (including a BOM).
        public let byteOffset: Int
        /// One-based logical record number; quoted newlines do not advance it.
        public let recordNumber: Int
    }

    public struct Record: Equatable, Sendable {
        public let fields: [String]
        /// Zero-based start in this parser's input. A leading BOM is not part
        /// of the record, so the first record after a UTF-8 BOM starts at 3.
        public let byteOffset: Int
    }

    private var recordStart = 0
    private enum State: Sendable { case fieldStart, unquoted, quoted, afterQuote }
    private let delimiter: UInt8
    private let limits: Limits
    private var state: State = .fieldStart
    private var field: [UInt8] = []
    private var row: [String] = []
    private var rowStringBytes = 0
    private var recordBytes = 0
    private var prefix: [UInt8] = []
    private var checkedBOM = false
    private var skipLF = false
    private var finished = false
    public private(set) var failure: Failure?
    public private(set) var inputBytes = 0
    public private(set) var recordCount = 0
    /// Payload bytes retained, excluding Swift collection/object overhead.
    public var bufferedBytes: Int { field.count + rowStringBytes + prefix.count }

    /// Only ASCII single-byte separators other than quote, CR, LF and NUL are
    /// accepted. UTF-16, custom escapes and permissive malformed CSV are outside
    /// this parser's contract. LF, CR and CRLF record separators are accepted.
    public init(delimiter: UInt8 = 44, limits: Limits = .init(), stripUTF8BOM: Bool = true) throws {
        guard delimiter > 0, delimiter < 128, ![10, 13, 34].contains(delimiter),
              limits.maxFieldBytes > 0, limits.maxRecordBytes > 0,
              limits.maxColumns > 0, limits.maxRows > 0, limits.maxInputBytes > 0 else {
            throw Failure(kind: .invalidConfiguration, byteOffset: 0, recordNumber: 1)
        }
        self.delimiter = delimiter
        self.limits = limits
        self.checkedBOM = !stripUTF8BOM
    }

    /// Calls onRow synchronously for each complete record. The callback must not
    /// retain all rows for an unbounded file. Cancel between bounded append calls.
    public mutating func append(_ data: Data, onRow: ([String]) -> Void) throws {
        try appendRecords(data, onRecord: { onRow($0.fields) })
    }

    /// Record offsets allow sparse indexes without retaining completed rows.
    /// Disable BOM stripping when starting a parser at a nonzero file offset.
    public mutating func appendRecords(_ data: Data, onRecord: (Record) -> Void) throws {
        try checkOpen()
        for byte in data {
            guard inputBytes < limits.maxInputBytes else { throw fail(.inputLimit, at: inputBytes) }
            let offset = inputBytes
            inputBytes += 1
            if !checkedBOM {
                prefix.append(byte)
                let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
                if prefix.elementsEqual(bom.prefix(prefix.count)) {
                    if prefix.count == 3 { checkedBOM = true; prefix.removeAll(keepingCapacity: false) }
                    continue
                }
                checkedBOM = true
                let pending = prefix
                prefix.removeAll(keepingCapacity: false)
                for (index, value) in pending.enumerated() {
                    try consume(value, at: offset - pending.count + 1 + index, onRecord: onRecord)
                }
            } else {
                try consume(byte, at: offset, onRecord: onRecord)
            }
        }
    }

    /// Finalizes a last record without a newline; a trailing record separator
    /// does not create an extra row. An empty file produces no records.
    public mutating func finish(onRow: ([String]) -> Void) throws {
        try finishRecords(onRecord: { onRow($0.fields) })
    }

    public mutating func finishRecords(onRecord: (Record) -> Void) throws {
        try checkOpen()
        let pending = prefix
        prefix.removeAll(keepingCapacity: false)
        for (index, byte) in pending.enumerated() {
            try consume(byte, at: inputBytes - pending.count + index, onRecord: onRecord)
        }
        guard state != .quoted else { throw fail(.unterminatedQuote, at: inputBytes) }
        if recordBytes > 0 { try emitRow(at: inputBytes, onRecord: onRecord) }
        finished = true
    }

    private mutating func checkOpen() throws {
        if let failure { throw failure }
        if finished { throw Failure(kind: .alreadyFinished, byteOffset: inputBytes, recordNumber: recordCount + 1) }
    }

    private mutating func consume(_ byte: UInt8, at offset: Int, onRecord: (Record) -> Void) throws {
        if skipLF {
            skipLF = false
            if byte == 10 { return }
        }
        guard recordBytes < limits.maxRecordBytes else { throw fail(.recordLimit, at: offset) }
        if recordBytes == 0 { recordStart = offset }
        recordBytes += 1
        if state == .quoted {
            if byte == 34 { state = .afterQuote }
            else { try appendField(byte, at: offset) }
            return
        }
        if state == .afterQuote && byte == 34 {
            try appendField(34, at: offset)
            state = .quoted
        } else if byte == delimiter {
            try emitField(at: offset)
            // There must be room for the field following this delimiter.
            guard row.count < limits.maxColumns else { throw fail(.columnLimit, at: offset) }
            state = .fieldStart
        } else if byte == 10 || byte == 13 {
            try emitRow(at: offset, onRecord: onRecord)
            skipLF = byte == 13
        } else if state == .afterQuote {
            throw fail(.unexpectedCharacterAfterQuote, at: offset)
        } else if byte == 34 {
            guard state == .fieldStart else { throw fail(.unexpectedQuote, at: offset) }
            state = .quoted
        } else {
            try appendField(byte, at: offset)
            state = .unquoted
        }
    }

    private mutating func appendField(_ byte: UInt8, at offset: Int) throws {
        guard field.count < limits.maxFieldBytes else { throw fail(.fieldLimit, at: offset) }
        field.append(byte)
    }

    private mutating func emitField(at offset: Int) throws {
        guard row.count < limits.maxColumns else { throw fail(.columnLimit, at: offset) }
        guard let value = String(bytes: field, encoding: .utf8) else { throw fail(.invalidUTF8, at: offset) }
        rowStringBytes += field.count
        row.append(value)
        field.removeAll(keepingCapacity: false)
    }

    private mutating func emitRow(at offset: Int, onRecord: (Record) -> Void) throws {
        guard recordCount < limits.maxRows else { throw fail(.rowLimit, at: offset) }
        try emitField(at: offset)
        recordCount += 1
        let completed = row
        row = []
        rowStringBytes = 0
        recordBytes = 0
        state = .fieldStart
        onRecord(Record(fields: completed, byteOffset: recordStart))
    }

    private mutating func fail(_ kind: Failure.Kind, at offset: Int) -> Failure {
        let result = Failure(kind: kind, byteOffset: offset, recordNumber: recordCount + 1)
        failure = result
        field = []
        row = []
        prefix = []
        rowStringBytes = 0
        return result
    }
}
