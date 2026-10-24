import ContinuumRevivedCore
import Foundation
import Darwin

func runSecureFileSnapshotChecks() {
    typealias Snapshot = SecureFileSnapshot
    typealias Failure = SecureFileSnapshot.CaptureError
    final class Observation: @unchecked Sendable {
        var stagedURL: URL?
        var cancel = false
        var mutated = false
    }
    // Resolve the trusted fixture root with POSIX realpath. Foundation URL
    // canonicalization can preserve macOS's /var alias, which production's
    // deliberately strict no-follow walker correctly refuses.
    let proposedRoot = FileManager.default.temporaryDirectory.appendingPathComponent("array-snapshot-check-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: proposedRoot, withIntermediateDirectories: true)
    let resolvedRoot = proposedRoot.path.withCString { realpath($0, nil) }!
    let root = URL(fileURLWithPath: String(cString: resolvedRoot), isDirectory: true)
    free(resolvedRoot)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("data.csv")
    let bytes = Data("id,value\n001,hello\n".utf8)
    try! bytes.write(to: file)

    func fails(_ expected: Failure? = nil, _ message: String, _ body: () throws -> Void) {
        do {
            try body()
            expect(false, message)
        } catch let error as Failure {
            expect(expected == nil || error == expected, message + " (unexpected error: \(error))")
        } catch { expect(false, message + " (unexpected error: \(error))") }
    }

    var snapshot: Snapshot? = try! Snapshot.capture(path: file.path, maxBytes: bytes.count)
    let staged = snapshot!.url
    let directory = staged.deletingLastPathComponent()
    expect(snapshot!.byteCount == bytes.count && (try! Data(contentsOf: staged)) == bytes,
           "snapshot must contain the exact admitted revision")
    expect(staged.pathExtension == "csv" && staged.path != file.path,
           "private staging must preserve format suffix without reusing the source path")
    let mode = (try! FileManager.default.attributesOfItem(atPath: staged.path)[.posixPermissions]) as! NSNumber
    let directoryMode = (try! FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions]) as! NSNumber
    expect(mode.intValue == 0o400 && directoryMode.intValue == 0o700,
           "staging must be private with a read-only final snapshot")
    let second = try! Snapshot.capture(path: file.path, maxBytes: bytes.count)
    expect(second.revision == snapshot!.revision && second.url != staged,
           "unchanged source must have stable revision and individually owned staging")
    try! Data("later".utf8).write(to: file)
    expect((try! Data(contentsOf: staged)) == bytes,
           "later source replacement must not alter an admitted snapshot")
    snapshot = nil
    expect(!FileManager.default.fileExists(atPath: directory.path) && FileManager.default.fileExists(atPath: second.url.path),
           "snapshot disposal must delete only its own staging directory")

    fails(.tooLarge(maxBytes: 1), "oversized metadata must reject capture") {
        _ = try Snapshot.capture(path: file.path, maxBytes: 1)
    }
    fails(.cancelled, "initial cancellation must reject capture") {
        _ = try Snapshot.capture(path: file.path, maxBytes: 100, cancelled: { true })
    }
    for path in ["relative.csv", root.path + "/../other", root.path + "/./data.csv", file.path + "/", file.path + "\0bad"] {
        fails(.invalidPath, "noncanonical lexical paths must not be reauthorized") {
            _ = try Snapshot.capture(path: path, maxBytes: 100)
        }
    }
    let package = root.appendingPathComponent("book.numbers", isDirectory: true)
    try! FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
    fails(.notRegularFile, "directory packages must be explicitly refused") {
        _ = try Snapshot.capture(path: package.path, maxBytes: 100)
    }
    let fifo = root.appendingPathComponent("fifo")
    expect(mkfifo(fifo.path, mode_t(0o600)) == 0, "FIFO fixture must be created")
    fails(.notRegularFile, "special-file replacement must not block or enter the stream") {
        _ = try Snapshot.capture(path: fifo.path, maxBytes: 100)
    }
    let link = root.appendingPathComponent("link.csv")
    try! FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
    fails(nil, "final symbolic links must be refused") {
        _ = try Snapshot.capture(path: link.path, maxBytes: 100)
    }
    let parentLink = root.appendingPathComponent("linked-parent")
    try! FileManager.default.createSymbolicLink(at: parentLink, withDestinationURL: root)
    fails(nil, "parent symbolic links must be refused") {
        _ = try Snapshot.capture(path: parentLink.appendingPathComponent("data.csv").path, maxBytes: 100)
    }

    let cancelled = Observation()
    fails(.cancelled, "cancellation after staging must abort and clean up") {
        _ = try Snapshot.capture(path: file.path, maxBytes: 100, cancelled: { cancelled.cancel }, phase: { phase in
            if case let .stagingCreated(url) = phase { cancelled.stagedURL = url; cancelled.cancel = true }
        })
    }
    expect(cancelled.stagedURL != nil && !FileManager.default.fileExists(atPath: cancelled.stagedURL!.deletingLastPathComponent().path),
           "cancelled capture must remove incomplete staging")

    let midCopy = Observation()
    try! Data(repeating: 65, count: 128 * 1_024).write(to: file)
    fails(.cancelled, "cancellation between chunks must stop copying and remove staging") {
        _ = try Snapshot.capture(path: file.path, maxBytes: 128 * 1_024, cancelled: { midCopy.cancel }, phase: { phase in
            if case let .stagingCreated(url) = phase { midCopy.stagedURL = url }
            if case .copiedChunk = phase { midCopy.cancel = true }
        })
    }
    expect(midCopy.stagedURL != nil && !FileManager.default.fileExists(atPath: midCopy.stagedURL!.deletingLastPathComponent().path),
           "chunk cancellation must not leave a private staging directory")

    let mutated = Observation()
    try! bytes.write(to: file)
    fails(.changedDuringCapture, "same-size in-place mutation must invalidate the copied revision") {
        _ = try Snapshot.capture(path: file.path, maxBytes: 100, cancelled: { false }, phase: { phase in
            if case let .stagingCreated(url) = phase { mutated.stagedURL = url }
            if case .copyFinished = phase {
                let handle = try! FileHandle(forWritingTo: file)
                try! handle.write(contentsOf: Data(repeating: 88, count: bytes.count))
                try! handle.close()
            }
        })
    }
    expect(mutated.stagedURL != nil && !FileManager.default.fileExists(atPath: mutated.stagedURL!.deletingLastPathComponent().path),
           "revision rejection must remove incomplete staging")

    try! bytes.write(to: file)
    let replaced = Observation()
    fails(.changedDuringCapture, "atomic same-size replacement must fail final path binding") {
        _ = try Snapshot.capture(path: file.path, maxBytes: 100, cancelled: { false }, phase: { phase in
            if case let .stagingCreated(url) = phase { replaced.stagedURL = url }
            if case .copyFinished = phase {
                let stamp = try! FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as! Date
                try! bytes.write(to: file, options: .atomic)
                try! FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: file.path)
            }
        })
    }
    expect(replaced.stagedURL != nil && !FileManager.default.fileExists(atPath: replaced.stagedURL!.deletingLastPathComponent().path),
           "path replacement rejection must clean staging")

    let swap = Observation()
    fails(.changedDuringCapture, "a final path swapped to a symbolic link during copying must fail") {
        _ = try Snapshot.capture(path: file.path, maxBytes: 100, cancelled: { false }, phase: { phase in
            if case .copyFinished = phase {
                try! FileManager.default.removeItem(at: file)
                try! FileManager.default.createSymbolicLink(at: file, withDestinationURL: second.url)
                swap.mutated = true
            }
        })
    }
    expect(swap.mutated, "symlink-race fixture must run its mutation")
    try! FileManager.default.removeItem(at: file)
    try! bytes.write(to: file)

    let parent = root.appendingPathComponent("parent")
    let movedParent = root.appendingPathComponent("old-parent")
    try! FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    let nested = parent.appendingPathComponent("data.csv")
    try! bytes.write(to: nested)
    fails(.changedDuringCapture, "replacement of a parent directory must fail final path rebinding") {
        _ = try Snapshot.capture(path: nested.path, maxBytes: 100, cancelled: { false }, phase: { phase in
            if case .copyFinished = phase {
                try! FileManager.default.moveItem(at: parent, to: movedParent)
                try! FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
                try! bytes.write(to: nested)
            }
        })
    }

    let linkedParent = root.appendingPathComponent("swapped-parent")
    let retainedParent = root.appendingPathComponent("retained-parent")
    try! FileManager.default.createDirectory(at: linkedParent, withIntermediateDirectories: true)
    let linkedNested = linkedParent.appendingPathComponent("data.csv")
    try! bytes.write(to: linkedNested)
    fails(.changedDuringCapture, "a parent symlink swap must fail even when it points back to the same file") {
        _ = try Snapshot.capture(path: linkedNested.path, maxBytes: 100, cancelled: { false }, phase: { phase in
            if case .copyFinished = phase {
                try! FileManager.default.moveItem(at: linkedParent, to: retainedParent)
                try! FileManager.default.createSymbolicLink(at: linkedParent, withDestinationURL: retainedParent)
            }
        })
    }

    try! bytes.write(to: file)
    fails(.tooLarge(maxBytes: bytes.count), "growth after admission must respect streamed byte limit") {
        _ = try Snapshot.capture(path: file.path, maxBytes: bytes.count, cancelled: { false }, phase: { phase in
            if case .sourceValidated = phase {
                let handle = try! FileHandle(forWritingTo: file)
                try! handle.seekToEnd()
                try! handle.write(contentsOf: Data([65]))
                try! handle.close()
            }
        })
    }
    let empty = root.appendingPathComponent("empty")
    try! Data().write(to: empty)
    let emptySnapshot = try! Snapshot.capture(path: empty.path, maxBytes: 0)
    expect(emptySnapshot.byteCount == 0, "zero-byte files must remain valid with a zero-byte limit")
}
