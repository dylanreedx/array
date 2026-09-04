import Foundation

enum ProjectFileOperationChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }

    static func run() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("array-file-operations-\(UUID().uuidString)", isDirectory: true)
        let outside = manager.temporaryDirectory.appendingPathComponent("array-file-operations-outside-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        try manager.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root); try? manager.removeItem(at: outside) }

        let coordinator = ProjectFileOperationCoordinator(rootURL: root)
        let folder = try coordinator.createDirectory(parent: root, name: "Sources")
        let file = try coordinator.createFile(parent: folder, name: "Thing.swift")
        try expect(manager.fileExists(atPath: file.path), "create file must materialize inside the project")

        do {
            _ = try coordinator.createFile(parent: folder, name: "Thing.swift")
            throw Failure(description: "create must reject collisions")
        } catch ProjectFileOperationCoordinator.OperationError.collision { }

        for invalid in ["", ".", "..", "nested/name", " padded"] {
            do {
                _ = try coordinator.createFile(parent: folder, name: invalid)
                throw Failure(description: "create accepted invalid component \(invalid.debugDescription)")
            } catch ProjectFileOperationCoordinator.OperationError.invalidName { }
        }

        let caseRenamed = try coordinator.rename(entry: file, newName: "thing.swift")
        try expect(caseRenamed.destination.lastPathComponent == "thing.swift"
                   && manager.fileExists(atPath: caseRenamed.destination.path),
                   "case-only rename must preserve the file without overwrite")

        let link = root.appendingPathComponent("outside-link")
        try manager.createSymbolicLink(at: link, withDestinationURL: outside)
        do {
            _ = try coordinator.createFile(parent: link, name: "escape.txt")
            throw Failure(description: "a symlinked parent escaped the project root")
        } catch ProjectFileOperationCoordinator.OperationError.outsideRoot { }

        let movedFolder = try coordinator.rename(entry: folder, newName: "Code")
        try expect(movedFolder.isDirectory
                   && manager.fileExists(atPath: movedFolder.destination.appendingPathComponent("thing.swift").path),
                   "directory rename must move descendants as one no-overwrite operation")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
    }
}
