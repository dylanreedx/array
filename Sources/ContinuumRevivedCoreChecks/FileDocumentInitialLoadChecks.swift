import ContinuumRevivedCore
import Foundation

/// Behavioral contract for initial preview/baseline consistency and admission.
func runFileDocumentInitialLoadChecks() {
    final class Disk: @unchecked Sendable {
        var bytes = Data("first revision\n".utf8)
        var reads = 0
        var writes = 0
        var attributeCalls = 0
        var declaredSize: UInt64?
        var missing = false
        var regular = true
        var operations: FileDocumentFileOperations {
            FileDocumentFileOperations(
                attributes: { [self] _ in
                    attributeCalls += 1
                    if missing { throw CocoaError(.fileReadNoSuchFile) }
                    return [.type: regular ? FileAttributeType.typeRegular : .typeDirectory,
                            .size: NSNumber(value: declaredSize ?? UInt64(bytes.count))]
                },
                read: { [self] _ in reads += 1; return bytes },
                write: { [self] data, _ in writes += 1; bytes = data }
            )
        }
    }

    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("array-initial-load-\(UUID().uuidString).txt").path
    let disk = Disk()
    let loaded = FileDocumentSession.load(path: path, fileOperations: disk.operations)
    expect(disk.reads == 1 && disk.attributeCalls == 1,
           "initial text loading must read one disk revision once")
    // Mutate disk before materialization: the displayed revision and baseline
    // must remain the original snapshot, not a second independently read value.
    disk.bytes = Data("second revision\n".utf8)
    guard let session = loaded.makeSession() else {
        expect(false, "admitted text must materialize an editable session")
        return
    }
    expect(disk.reads == 1 && loaded.preview == .text("first revision\n")
           && session.baselineText == "first revision\n" && session.draftText == session.baselineText
           && !session.isDirty,
           "session materialization must use the displayed revision without disk I/O")
    _ = session.updateDraft("local draft\n")
    expect(session.save() == .conflict && disk.writes == 0 && session.isDirty,
           "single-read initial loading must preserve external-change save protection")
    let revision = session.revision
    expect(session.save(overwriteExternalChanges: true) == .saved(revision: revision + 1)
           && disk.writes == 1 && disk.bytes == Data("local draft\n".utf8) && !session.isDirty,
           "explicit overwrite must still save the draft and advance its baseline")

    let bom = Disk()
    bom.bytes = Data([0xEF, 0xBB, 0xBF]) + Data("BOM text".utf8)
    let bomLoad = FileDocumentSession.load(path: path, fileOperations: bom.operations)
    expect(bomLoad.preview == .text("BOM text") && bomLoad.makeSession()?.baselineText == "BOM text"
           && bom.reads == 1,
           "UTF-8 BOM normalization must agree between preview and editable baseline")

    let missing = Disk()
    missing.missing = true
    let missingLoad = FileDocumentSession.load(path: path, fileOperations: missing.operations)
    expect(missingLoad.preview == .unavailable("File not found") && missingLoad.makeSession() == nil
           && missing.reads == 0,
           "missing files must return the existing placeholder without reading or creating a session")

    let directory = Disk()
    directory.regular = false
    let directoryLoad = FileDocumentSession.load(path: path, fileOperations: directory.operations)
    expect(directoryLoad.preview == .unavailable("File not found") && directoryLoad.makeSession() == nil
           && directory.reads == 0,
           "nonregular files must fail before reading or session creation")

    for bytes in [Data([0, 1, 2]), Data([0xFF, 0xFE, 0x61, 0]), Data([0xFF])] {
        let binary = Disk()
        binary.bytes = bytes
        let binaryLoad = FileDocumentSession.load(path: path, fileOperations: binary.operations)
        expect(binaryLoad.preview == .unavailable("Binary file -- open in preferred editor")
               && binaryLoad.makeSession() == nil && binary.reads == 1,
               "binary and unsupported encodings must have no editable session or duplicate read")
    }

    let oversized = Disk()
    oversized.declaredSize = UInt64(FileDocumentSession.maxBytes) + 1
    let oversizedLoad = FileDocumentSession.load(path: path, fileOperations: oversized.operations)
    expect(oversizedLoad.preview == .unavailable("File too large to preview (> 1 MB)")
           && oversizedLoad.makeSession() == nil && oversized.reads == 0,
           "declared oversized files must fail before reading or session creation")

    let growing = Disk()
    growing.declaredSize = 1
    growing.bytes = Data(repeating: 65, count: FileDocumentSession.maxBytes + 1)
    let growingLoad = FileDocumentSession.load(path: path, fileOperations: growing.operations)
    expect(growingLoad.preview == .unavailable("File too large to preview (> 1 MB)")
           && growingLoad.makeSession() == nil && growing.reads == 1,
           "files growing after metadata inspection must retain the post-read size guard")

    let boundary = Disk()
    boundary.bytes = Data(repeating: 65, count: FileDocumentSession.maxBytes)
    let boundaryLoad = FileDocumentSession.load(path: path, fileOperations: boundary.operations)
    expect(boundaryLoad.makeSession()?.baselineText?.utf8.count == FileDocumentSession.maxBytes
           && boundary.reads == 1,
           "the exact text size limit must remain admitted in one read")
}
