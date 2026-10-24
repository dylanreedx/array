import Foundation
import zlib

/// A deliberately small ZIP32 reader for document containers. It never extracts
/// paths to disk, runs executable content, or retains expanded entries. Limits
/// apply to the entire directory before a caller can request its first entry.
public struct BoundedZIPArchive {
    public struct Limits: Sendable {
        public var maxArchiveBytes: Int
        public var maxExpandedBytes: Int
        public var maxEntryBytes: Int
        public var maxEntries: Int
        public var maxCompressionRatio: Int

        public init(maxArchiveBytes: Int = 64 * 1024 * 1024,
                    maxExpandedBytes: Int = 32 * 1024 * 1024,
                    maxEntryBytes: Int = 8 * 1024 * 1024,
                    maxEntries: Int = 2048, maxCompressionRatio: Int = 200) {
            self.maxArchiveBytes = maxArchiveBytes
            self.maxExpandedBytes = maxExpandedBytes
            self.maxEntryBytes = maxEntryBytes
            self.maxEntries = maxEntries
            self.maxCompressionRatio = maxCompressionRatio
        }
    }

    public enum ArchiveError: Error, Equatable {
        case cancelled
        case limitExceeded
        case malformed
        case unsupported
        case unsafePath
        case missingEntry
        case corruptEntry
    }

    private struct Entry {
        let name: String
        let method: UInt16
        let crc: UInt32
        let compressedSize: Int
        let expandedSize: Int
        let dataOffset: Int
    }

    private let bytes: Data
    private let entries: [String: Entry]
    private let cancelled: () -> Bool
    public let entryNames: [String]

    public init(url: URL, limits: Limits = Limits(),
                cancelled: @escaping () -> Bool = { false }) throws {
        guard !cancelled() else { throw ArchiveError.cancelled }
        guard limits.maxArchiveBytes >= 22, limits.maxArchiveBytes < Int.max,
              limits.maxExpandedBytes >= 0, limits.maxEntryBytes >= 0,
              limits.maxEntries >= 0, limits.maxCompressionRatio > 0 else {
            throw ArchiveError.limitExceeded
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        guard size <= UInt64(limits.maxArchiveBytes) else { throw ArchiveError.limitExceeded }
        try handle.seek(toOffset: 0)
        // The extra byte detects growth after the size check, without an unbounded read.
        let bytes = try handle.read(upToCount: limits.maxArchiveBytes + 1) ?? Data()
        guard bytes.count <= limits.maxArchiveBytes else { throw ArchiveError.limitExceeded }
        guard UInt64(bytes.count) == size, bytes.count >= 22 else { throw ArchiveError.malformed }

        func u16(_ offset: Int) throws -> UInt16 {
            guard offset >= 0, offset <= bytes.count - 2 else { throw ArchiveError.malformed }
            return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
        }
        func u32(_ offset: Int) throws -> UInt32 {
            guard offset >= 0, offset <= bytes.count - 4 else { throw ArchiveError.malformed }
            return UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
                | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
        }
        func validateExtra(_ start: Int, _ length: Int) throws {
            guard start >= 0, length >= 0, start <= bytes.count - length else { throw ArchiveError.malformed }
            var cursor = start
            while cursor < start + length {
                guard cursor + 4 <= start + length else { throw ArchiveError.malformed }
                let tag = try u16(cursor), count = Int(try u16(cursor + 2))
                guard tag != 0x0001 else { throw ArchiveError.unsupported } // ZIP64
                cursor += 4
                guard count <= start + length - cursor else { throw ArchiveError.malformed }
                cursor += count
            }
        }
        var end: Int?
        for cursor in stride(from: bytes.count - 22,
                             through: max(0, bytes.count - 22 - 65535), by: -1) {
            if try u32(cursor) == 0x06054b50,
               cursor + 22 + Int(try u16(cursor + 20)) == bytes.count {
                end = cursor
                break
            }
        }
        guard let end else { throw ArchiveError.malformed }
        guard try u16(end + 4) == 0, (try u16(end + 6)) == 0,
              (try u16(end + 8)) == (try u16(end + 10)) else { throw ArchiveError.unsupported }
        let count = Int(try u16(end + 10))
        let directorySize = Int(try u32(end + 12)), directoryStart = Int(try u32(end + 16))
        guard count != 65535, directorySize != Int(UInt32.max), directoryStart != Int(UInt32.max)
        else { throw ArchiveError.unsupported }
        guard count <= limits.maxEntries else { throw ArchiveError.limitExceeded }
        guard directoryStart <= end, directorySize == end - directoryStart else { throw ArchiveError.malformed }
        var cursor = directoryStart, total = 0
        var entries: [String: Entry] = [:], names: [String] = []
        var ranges: [Range<Int>] = []
        for _ in 0..<count {
            guard !cancelled() else { throw ArchiveError.cancelled }
            guard cursor <= end - 46, try u32(cursor) == 0x02014b50 else { throw ArchiveError.malformed }
            let flags = try u16(cursor + 8), method = try u16(cursor + 10)
            // Deflate tuning bits, data descriptor, and UTF-8 are the only supported flags.
            guard flags & ~UInt16(0x080e) == 0, method == 0 || method == 8,
                  try u16(cursor + 6) <= 20, (try u16(cursor + 34)) == 0 else { throw ArchiveError.unsupported }
            let crc = try u32(cursor + 16)
            let compressed = Int(try u32(cursor + 20)), expanded = Int(try u32(cursor + 24))
            let nameLength = Int(try u16(cursor + 28)), extraLength = Int(try u16(cursor + 30))
            let commentLength = Int(try u16(cursor + 32)), local = Int(try u32(cursor + 42))
            guard compressed != Int(UInt32.max), expanded != Int(UInt32.max), local != Int(UInt32.max)
            else { throw ArchiveError.unsupported }
            guard expanded <= limits.maxEntryBytes, expanded <= limits.maxExpandedBytes - total,
                  expanded == 0 || (compressed > 0 && Double(expanded) / Double(compressed) <= Double(limits.maxCompressionRatio))
            else { throw ArchiveError.limitExceeded }
            total += expanded
            guard nameLength > 0, nameLength + extraLength + commentLength <= end - cursor - 46
            else { throw ArchiveError.malformed }
            let rawName = bytes.subdata(in: cursor + 46..<cursor + 46 + nameLength)
            guard let name = String(data: rawName, encoding: .utf8),
                  flags & 0x0800 != 0 || rawName.allSatisfy({ $0 < 128 }) else { throw ArchiveError.unsupported }
            guard !name.hasPrefix("/"), !name.contains("\\"), !name.contains(":"), !name.contains("\0")
            else { throw ArchiveError.unsafePath }
            var parts = name.split(separator: "/", omittingEmptySubsequences: false)
            if name.hasSuffix("/") { parts.removeLast() }
            guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
            else { throw ArchiveError.unsafePath }
            guard entries[name] == nil else { throw ArchiveError.malformed }
            try validateExtra(cursor + 46 + nameLength, extraLength)
            guard local <= directoryStart - 30, try u32(local) == 0x04034b50,
                  (try u16(local + 4)) <= 20, (try u16(local + 6)) == flags, (try u16(local + 8)) == method,
                  Int((try u16(local + 26))) == nameLength else { throw ArchiveError.malformed }
            let localExtra = Int(try u16(local + 28))
            let dataOffset = local + 30 + nameLength + localExtra
            guard dataOffset <= directoryStart, compressed <= directoryStart - dataOffset,
                  bytes.subdata(in: local + 30..<local + 30 + nameLength) == rawName
            else { throw ArchiveError.malformed }
            try validateExtra(local + 30 + nameLength, localExtra)
            var entryEnd = dataOffset + compressed
            if flags & 8 == 0 {
                guard try u32(local + 14) == crc, Int((try u32(local + 18))) == compressed,
                      Int((try u32(local + 22))) == expanded else { throw ArchiveError.malformed }
            } else {
                let localCRC = try u32(local + 14), localCompressed = try u32(local + 18), localExpanded = try u32(local + 22)
                guard (localCRC == 0 || localCRC == crc),
                      (localCompressed == 0 || Int(localCompressed) == compressed),
                      (localExpanded == 0 || Int(localExpanded) == expanded) else { throw ArchiveError.malformed }
                let hasSignature = try entryEnd <= directoryStart - 4 && u32(entryEnd) == 0x08074b50
                if hasSignature { entryEnd += 4 }
                guard entryEnd <= directoryStart - 12, try u32(entryEnd) == crc,
                      Int((try u32(entryEnd + 4))) == compressed, Int((try u32(entryEnd + 8))) == expanded
                else { throw ArchiveError.malformed }
                entryEnd += 12
            }
            guard method != 0 || compressed == expanded else { throw ArchiveError.malformed }
            guard !name.hasSuffix("/") || expanded == 0 else { throw ArchiveError.malformed }
            ranges.append(local..<entryEnd)
            let entry = Entry(name: name, method: method, crc: crc, compressedSize: compressed,
                              expandedSize: expanded, dataOffset: dataOffset)
            entries[name] = entry
            names.append(name)
            cursor += 46 + nameLength + extraLength + commentLength
        }
        guard cursor == end else { throw ArchiveError.malformed }
        let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
        for index in 1..<max(1, sorted.count) {
            guard sorted[index - 1].upperBound <= sorted[index].lowerBound else { throw ArchiveError.malformed }
        }
        self.bytes = bytes
        self.entries = entries
        self.entryNames = names
        self.cancelled = cancelled
    }

    public func data(for name: String) throws -> Data {
        guard !cancelled() else { throw ArchiveError.cancelled }
        guard let entry = entries[name] else { throw ArchiveError.missingEntry }
        let compressed = bytes.subdata(in: entry.dataOffset..<entry.dataOffset + entry.compressedSize)
        var result: Data
        if entry.method == 0 {
            result = compressed
        } else {
            var stream = z_stream()
            guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK
            else { throw ArchiveError.corruptEntry }
            defer { inflateEnd(&stream) }
            // One extra byte catches a dishonest expanded-size declaration.
            result = Data(count: entry.expandedSize + 1)
            try compressed.withUnsafeBytes { input in
                try result.withUnsafeMutableBytes { output in
                    stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
                    stream.avail_in = uInt(input.count)
                    var status: Int32 = Z_OK
                    while status == Z_OK {
                        guard !cancelled() else { throw ArchiveError.cancelled }
                        let produced = Int(stream.total_out)
                        guard produced < output.count else { throw ArchiveError.corruptEntry }
                        stream.next_out = output.bindMemory(to: Bytef.self).baseAddress!.advanced(by: produced)
                        stream.avail_out = uInt(min(64 * 1024, output.count - produced))
                        let previousIn = stream.total_in, previousOut = stream.total_out
                        status = inflate(&stream, Z_NO_FLUSH)
                        guard status != Z_OK || stream.total_in != previousIn || stream.total_out != previousOut
                        else { throw ArchiveError.corruptEntry }
                    }
                    guard status == Z_STREAM_END, stream.total_out == entry.expandedSize,
                          stream.total_in == entry.compressedSize else { throw ArchiveError.corruptEntry }
                }
            }
            result.removeLast()
        }
        let actualCRC = result.withUnsafeBytes { buffer in
            crc32(0, buffer.bindMemory(to: Bytef.self).baseAddress, uInt(buffer.count))
        }
        guard actualCRC == uLong(entry.crc) else { throw ArchiveError.corruptEntry }
        guard !cancelled() else { throw ArchiveError.cancelled }
        return result
    }
}
