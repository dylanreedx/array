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
        try writer.write(document, to: layout.canvasFile)
    }

    public func load() throws -> WorkspaceDocument {
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

    public func deleteDocument() throws {
        try FileManager.default.removeItem(at: layout.workspaceDirectory)
    }
}

extension WorkspaceStore: WorkspaceStoring {}
