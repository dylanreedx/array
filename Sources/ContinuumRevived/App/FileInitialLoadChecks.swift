import AppKit
import ContinuumRevivedCore
import Foundation

/// Host-only lifecycle witnesses. Scene placement and API coverage stay in the
/// existing production-mount checks; these control the asynchronous I/O seam.
@MainActor
enum FileInitialLoadChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }

    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private let release = DispatchSemaphore(value: 0)
        private var calls = 0
        var entered: Bool { lock.withLock { calls > 0 } }
        var count: Int { lock.withLock { calls } }
        func resume() { release.signal() }
        func load(_ path: String) -> FileDocumentInitialLoad {
            // Capture old bytes before blocking, so a stale completion really
            // differs from the replacement document, rather than rereading it.
            let snapshot = FileDocumentSession.load(path: path)
            let first = lock.withLock { calls += 1; return calls == 1 }
            if first {
                release.wait()
            }
            return snapshot
        }
    }

    static func run() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("array-file-initial-load-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func model(_ url: URL) -> Tile {
            Tile(id: UUID(), kind: .file, title: url.lastPathComponent,
                 frame: .init(x: 0, y: 0, width: 640, height: 480),
                 zPosition: .fromLegacyRank(1), runtimeRef: nil,
                 metadata: TileMetadata(filePath: url.path))
        }
        let binary = root.appendingPathComponent("image.png")
        try Data([0, 1, 2]).write(to: binary)
        let binaryView = FileTileNSView(tile: model(binary))
        defer { binaryView.prepareForRemovalFromScene() }
        try expect(!binaryView.qaHasDocumentSession && binaryView.loadedText == nil,
                   "unsupported binary input must not own a text session")

        let renamedBinary = root.appendingPathComponent("renamed.png")
        try FileManager.default.moveItem(at: binary, to: renamedBinary)
        NotificationCenter.default.post(name: .arrayProjectFileMoved, object: nil,
                                        userInfo: ["source": binary.path, "destination": renamedBinary.path])
        try expect(!binaryView.qaHasDocumentSession && binaryView.loadedText == nil,
                   "renaming unsupported binary input must preserve admission")

        // Rename while the old read is blocked. The new path must install its
        // own bytes, even if the old completion is delivered afterward.
        let original = root.appendingPathComponent("before.txt")
        let renamed = root.appendingPathComponent("after.txt")
        try "before rename".write(to: original, atomically: true, encoding: .utf8)
        let renameGate = Gate()
        let renamedView = FileTileNSView(tile: model(original), initialLoader: { renameGate.load($0) }, loadAsynchronously: true)
        defer { renameGate.resume(); renamedView.prepareForRemovalFromScene() }
        try wait { renameGate.entered }
        let oldRenameTask = renamedView.qaPendingFileLoad
        try FileManager.default.moveItem(at: original, to: renamed)
        try "after rename".write(to: renamed, atomically: true, encoding: .utf8)
        NotificationCenter.default.post(name: .arrayProjectFileMoved, object: nil,
                                        userInfo: ["source": original.path, "destination": renamed.path])
        try wait { renamedView.loadedText == "after rename" }
        renameGate.resume()
        try drain(oldRenameTask)
        try expect(renamedView.loadedText == "after rename" && renamedView.qaDraftText == "after rename",
                   "rename must restart loading and reject the departed revision")
        try expect(renameGate.count == 2, "rename must schedule exactly one replacement load")

        let live = root.appendingPathComponent("restorable.txt")
        let trash = root.appendingPathComponent("trashed.txt")
        try "restored document".write(to: live, atomically: true, encoding: .utf8)
        let trashGate = Gate()
        let restoredView = FileTileNSView(tile: model(live), initialLoader: { trashGate.load($0) }, loadAsynchronously: true)
        defer { trashGate.resume(); restoredView.prepareForRemovalFromScene() }
        try wait { trashGate.entered }
        let oldTrashTask = restoredView.qaPendingFileLoad
        try FileManager.default.moveItem(at: live, to: trash)
        NotificationCenter.default.post(name: .arrayProjectFileTrashed, object: nil,
                                        userInfo: ["source": live.path, "trash": trash.path])
        restoredView.perform(NSSelectorFromString("restoreTrashedFile:"), with: nil)
        try wait { restoredView.loadedText == "restored document" }
        trashGate.resume()
        try drain(oldTrashTask)
        try expect(restoredView.qaDraftText == "restored document" && trashGate.count == 2,
                   "restore before first load must restart unified loading")

        let removalGate = Gate()
        let removedView = FileTileNSView(tile: model(live), initialLoader: { removalGate.load($0) }, loadAsynchronously: true)
        defer { removalGate.resume() }
        try wait { removalGate.entered }
        let removedTask = removedView.qaPendingFileLoad
        removedView.prepareForRemovalFromScene()
        removalGate.resume()
        try drain(removedTask)
        try expect(removedView.loadedText == nil && !removedView.qaHasDocumentSession,
                   "a removed host must never materialize the pending session")
        print("FileInitialLoadChecks passed: binary admission, async rename, Trash/Restore, removal")
    }

    /// Await the entire detached task, including its possible MainActor publish.
    /// Merely observing that the background loader returned is too early.
    private static func drain(_ task: Task<Void, Never>?) throws {
        guard let task else { throw Failure(description: "missing controlled load task") }
        var completed = false
        Task { @MainActor in
            await task.value
            completed = true
        }
        try wait { completed }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
    }
    private static func wait(_ predicate: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(10)
        while !predicate(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
        if !predicate() { throw Failure(description: "timed out waiting for initial file load") }
    }
}
