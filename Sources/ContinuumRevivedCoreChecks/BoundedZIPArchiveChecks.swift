import Foundation
import ContinuumRevivedCore

/// Offline container checks use tiny independently specified ZIP records, not a
/// writer sharing the reader's parsing code. Deflate/CRC constants are fixed.
func runBoundedZIPArchiveChecks() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("array-zip-check-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    var sequence = 0
    func open(_ bytes: Data, limits: BoundedZIPArchive.Limits = .init(),
              cancelled: @escaping () -> Bool = { false }) throws -> BoundedZIPArchive {
        sequence += 1
        let url = root.appendingPathComponent("\(sequence).zip")
        try bytes.write(to: url)
        return try BoundedZIPArchive(url: url, limits: limits, cancelled: cancelled)
    }
    func rejects(_ bytes: Data, _ message: String,
                 limits: BoundedZIPArchive.Limits = .init(),
                 cancelled: @escaping () -> Bool = { false }) {
        do {
            _ = try open(bytes, limits: limits, cancelled: cancelled)
            expect(false, message)
        } catch { expect(true, message) }
    }
    func rejectsContent(_ bytes: Data, _ message: String) {
        do {
            let archive = try open(bytes)
            _ = try archive.data(for: "hello.txt")
            expect(false, message)
        } catch { expect(true, message) }
    }
    let plain = ZIPCheckRecord(name: "hello.txt")
    let stored = zipCheckArchive([plain])
    let archive = try open(stored)
    expect(archive.entryNames == ["hello.txt"], "ZIP lists central-directory names")
    let storedContent = try archive.data(for: "hello.txt")
    expect(storedContent == Data("hello".utf8), "ZIP reads stored content exactly")
    do {
        _ = try archive.data(for: "missing")
        expect(false, "ZIP missing entry throws")
    } catch BoundedZIPArchive.ArchiveError.missingEntry { expect(true, "ZIP missing entry throws") }
    let deflate = ZIPCheckRecord(name: "hello.txt", method: 8, payload: Data([0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0x07, 0x00]))
    let compressedArchive = try open(zipCheckArchive([deflate]))
    let deflatedContent = try compressedArchive.data(for: "hello.txt")
    expect(deflatedContent == Data("hello".utf8), "ZIP reads raw deflate with CRC")
    for signature in [false, true] {
        let descriptor = ZIPCheckRecord(name: "hello.txt", method: 8, flags: 8,
                                        payload: deflate.payload, descriptorSignature: signature)
        let streamed = try open(zipCheckArchive([descriptor]))
        let streamedContent = try streamed.data(for: "hello.txt")
        expect(streamedContent == Data("hello".utf8), "ZIP reads descriptor with signature=\(signature)")
    }
    var empty = plain
    empty.name = "empty"; empty.payload = Data(); empty.expanded = 0; empty.crc = 0
    let emptyArchive = try open(zipCheckArchive([empty]))
    let emptyContent = try emptyArchive.data(for: "empty")
    expect(emptyContent.isEmpty, "ZIP supports empty stored entry")
    let noEntries = try open(zipCheckArchive([]))
    expect(noEntries.entryNames.isEmpty, "ZIP supports empty directory without an index trap")
    rejects(Data(stored.dropLast()), "ZIP rejects truncated EOCD")
    var junk = stored; junk.append(0)
    rejects(junk, "ZIP rejects unaccounted trailing data")
    rejects(zipCheckArchive([plain, plain]), "ZIP rejects duplicate entry names")
    for name in ["../hello.txt", "/hello.txt", "a//b", "a/./b", "a\\b", "C:hello", "a/../b", "nul\0x"] {
        var unsafe = plain; unsafe.name = name
        rejects(zipCheckArchive([unsafe]), "ZIP rejects unsafe path \(name.debugDescription)")
    }
    var encrypted = plain; encrypted.flags = 1
    rejects(zipCheckArchive([encrypted]), "ZIP rejects encrypted entries")
    var unsupported = plain; unsupported.method = 99
    rejects(zipCheckArchive([unsupported]), "ZIP rejects unsupported compression")
    var zip64 = plain; zip64.extra = Data([1, 0, 0, 0])
    rejects(zipCheckArchive([zip64]), "ZIP rejects ZIP64 extra fields")
    var mismatch = stored; mismatch[30] = UInt8(ascii: "x")
    rejects(mismatch, "ZIP rejects mismatched local and central names")
    var wrongCRC = plain; wrongCRC.crc = 0
    rejectsContent(zipCheckArchive([wrongCRC]), "ZIP verifies stored CRC")
    var corruptDeflate = deflate; corruptDeflate.payload = Data([0xff, 0xff, 0xff])
    rejectsContent(zipCheckArchive([corruptDeflate]), "ZIP rejects corrupt deflate")
    var wrongSize = deflate; wrongSize.expanded = 4
    rejectsContent(zipCheckArchive([wrongSize]), "ZIP rejects understated expansion size")
    var trailingDeflate = deflate; trailingDeflate.payload.append(0)
    rejectsContent(zipCheckArchive([trailingDeflate]), "ZIP rejects trailing bytes inside deflate entry")
    var truncatedDeflate = deflate; truncatedDeflate.payload.removeLast()
    rejectsContent(zipCheckArchive([truncatedDeflate]), "ZIP rejects truncated deflate stream")
    var disk = stored; disk[disk.count - 18] = 1
    rejects(disk, "ZIP rejects multidisk archives")
    var sentinel = stored
    sentinel[sentinel.count - 12] = 0xff; sentinel[sentinel.count - 11] = 0xff
    rejects(sentinel, "ZIP rejects ZIP64 entry-count sentinel")
    rejects(stored, "ZIP enforces archive byte ceiling", limits: .init(maxArchiveBytes: stored.count - 1))
    rejects(stored, "ZIP enforces per-entry expanded ceiling", limits: .init(maxEntryBytes: 4))
    var other = plain; other.name = "other.txt"
    rejects(zipCheckArchive([plain, other]), "ZIP enforces aggregate expanded ceiling", limits: .init(maxExpandedBytes: 9))
    rejects(stored, "ZIP enforces entry-count ceiling", limits: .init(maxEntries: 0))
    var bomb = deflate; bomb.expanded = 2000
    rejects(zipCheckArchive([bomb]), "ZIP enforces compression-ratio ceiling")
    rejects(stored, "ZIP cancels before loading", cancelled: { true })
    var cancel = false
    let cancellable = try open(stored, cancelled: { cancel })
    cancel = true
    do {
        _ = try cancellable.data(for: "hello.txt")
        expect(false, "ZIP cancels entry access")
    } catch BoundedZIPArchive.ArchiveError.cancelled { expect(true, "ZIP cancels entry access") }
}

private struct ZIPCheckRecord {
    var name: String
    var method: UInt16 = 0
    var flags: UInt16 = 0
    var payload: Data = Data("hello".utf8)
    var expanded: UInt32 = 5
    var crc: UInt32 = 0x3610a686
    var extra = Data()
    var descriptorSignature = true
}

// Layout constants independently follow PKWARE APPNOTE 4.3.7/4.3.9/4.3.12/4.3.16.
private func zipCheckArchive(_ records: [ZIPCheckRecord]) -> Data {
    func word(_ value: UInt16) -> Data { Data([UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8)]) }
    func dword(_ value: UInt32) -> Data {
        Data([UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8),
              UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 24)])
    }
    var locals = Data(), directory = Data()
    for record in records {
        let name = Data(record.name.utf8), offset = UInt32(locals.count)
        locals.append(dword(0x04034b50)); locals.append(word(20)); locals.append(word(record.flags))
        locals.append(word(record.method)); locals.append(Data(repeating: 0, count: 4))
        locals.append(dword(record.flags & 8 == 0 ? record.crc : 0))
        locals.append(dword(record.flags & 8 == 0 ? UInt32(record.payload.count) : 0))
        locals.append(dword(record.flags & 8 == 0 ? record.expanded : 0))
        locals.append(word(UInt16(name.count))); locals.append(word(UInt16(record.extra.count)))
        locals.append(name); locals.append(record.extra); locals.append(record.payload)
        if record.flags & 8 != 0 {
            if record.descriptorSignature { locals.append(dword(0x08074b50)) }
            locals.append(dword(record.crc)); locals.append(dword(UInt32(record.payload.count))); locals.append(dword(record.expanded))
        }
        directory.append(dword(0x02014b50)); directory.append(word(20)); directory.append(word(20))
        directory.append(word(record.flags)); directory.append(word(record.method)); directory.append(Data(repeating: 0, count: 4))
        directory.append(dword(record.crc)); directory.append(dword(UInt32(record.payload.count))); directory.append(dword(record.expanded))
        directory.append(word(UInt16(name.count))); directory.append(word(UInt16(record.extra.count)))
        directory.append(Data(repeating: 0, count: 10)); directory.append(dword(offset))
        directory.append(name); directory.append(record.extra)
    }
    let start = UInt32(locals.count)
    locals.append(directory); locals.append(dword(0x06054b50)); locals.append(Data(repeating: 0, count: 4))
    locals.append(word(UInt16(records.count))); locals.append(word(UInt16(records.count)))
    locals.append(dword(UInt32(directory.count))); locals.append(dword(start)); locals.append(word(0))
    return locals
}
