import Foundation

public struct WorkspaceStoreLayout: Sendable {
    public let applicationSupportDirectory: URL
    public let workspaceId: UUID

    public init(applicationSupportDirectory: URL, workspaceId: UUID) {
        self.applicationSupportDirectory = applicationSupportDirectory
        self.workspaceId = workspaceId
    }

    public var workspacesDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("workspaces", isDirectory: true)
    }

    public var workspaceDirectory: URL {
        workspacesDirectory.appendingPathComponent(workspaceId.uuidString, isDirectory: true)
    }

    public var canvasFile: URL {
        workspaceDirectory.appendingPathComponent("canvas.json", isDirectory: false)
    }

    public var backupsDirectory: URL {
        workspaceDirectory.appendingPathComponent("backups", isDirectory: true)
    }
}

public struct WorkspaceStore: Sendable {
    public let layout: WorkspaceStoreLayout
    private let writer: AtomicWriter

    public init(
        workspaceId: UUID,
        applicationSupportDirectory: URL? = nil,
        retainedBackups: Int = 3,
        descriptorOperations: AtomicWriterDescriptorOperations = .live,
        fileOperations: AtomicWriterFileOperations = .live,
        backupDate: @escaping @Sendable () -> Date = { Date() }
    ) {
        let baseDir = applicationSupportDirectory ?? Self.defaultApplicationSupportDirectory()
        let layout = WorkspaceStoreLayout(applicationSupportDirectory: baseDir, workspaceId: workspaceId)
        self.layout = layout
        self.writer = AtomicWriter(
            backupsDirectory: layout.backupsDirectory,
            retainedBackups: retainedBackups,
            descriptorOperations: descriptorOperations,
            fileOperations: fileOperations,
            backupDate: backupDate,
            legacyBackupPolicy: .targetDedicated
        )
    }

    public static func defaultApplicationSupportDirectory() -> URL {
        if let override = ProcessInfo.processInfo.environment["CONTINUUM_APP_SUPPORT"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return RegistryStore.defaultApplicationSupportDirectory()
    }

    public func save(_ document: WorkspaceDocument) throws {
        // `StoreFileWriter` is the QA fault seam; with no plan it is a direct call.
        try StoreFileWriter.perform(.write, at: layout.canvasFile) {
            try writer.write(document, to: layout.canvasFile)
        }
    }

    public func load() throws -> WorkspaceDocument {
        StoreReadProbe.shared.record()
        let document: WorkspaceDocument = try writer.read(at: layout.canvasFile)
        try document.validateSchema(at: layout.canvasFile)
        return document
    }

    public func tryLoad() throws -> WorkspaceDocument? {
        do {
            return try load()
        } catch AtomicWriterError.noValidBackup {
            return nil
        }
    }

    /// Where a deleted workspace's directory goes: `workspaces/.trash/`, which
    /// no workspace id can name. Recoverable by moving it back.
    public var trashDirectory: URL {
        layout.workspacesDirectory.appendingPathComponent(".trash", isDirectory: true)
    }

    /// Delete the workspace's document recoverably: its whole directory —
    /// document AND the AtomicWriter backups inside it — moves into
    /// `trashDirectory` as `<id>-<UTC timestamp>`. Removing it outright, as
    /// `deleteDocument` does, destroyed the only copies of its zones' names,
    /// colours and geometry. Returns the trashed directory.
    @discardableResult
    public func moveDocumentToTrash(now: Date = Date()) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        var destination = trashDirectory.appendingPathComponent(
            "\(layout.workspaceId.uuidString)-\(formatter.string(from: now))", isDirectory: true)
        var suffix = 1
        while FileManager.default.fileExists(atPath: destination.path) {
            suffix += 1
            destination = trashDirectory.appendingPathComponent(
                "\(layout.workspaceId.uuidString)-\(formatter.string(from: now))-\(suffix)", isDirectory: true)
        }
        try StoreFileWriter.perform(.remove, at: layout.workspaceDirectory) {
            try FileManager.default.createDirectory(at: trashDirectory, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: layout.workspaceDirectory, to: destination)
        }
        return destination
    }

    public func deleteDocument() throws {
        try StoreFileWriter.perform(.remove, at: layout.workspaceDirectory) {
            try FileManager.default.removeItem(at: layout.workspaceDirectory)
        }
    }
}

extension WorkspaceStore: WorkspaceStoring {}
