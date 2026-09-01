import Foundation

public enum RegistryStoreError: Error, Equatable {
    case unknownFutureSchema(path: String, version: Int, supported: Int)
}

public struct RegistryStore: Sendable {
    public let registryFile: URL
    public let backupsDirectory: URL
    private let writer: AtomicWriter

    public init(
        applicationSupportDirectory: URL? = nil,
        retainedBackups: Int = 3
    ) {
        let baseDir = applicationSupportDirectory ?? Self.defaultApplicationSupportDirectory()
        self.registryFile = baseDir.appendingPathComponent("registry.json", isDirectory: false)
        self.backupsDirectory = baseDir.appendingPathComponent("backups", isDirectory: true)
        self.writer = AtomicWriter(
            backupsDirectory: backupsDirectory,
            retainedBackups: retainedBackups,
            legacyBackupPolicy: .targetDedicated
        )
    }

    public static func defaultApplicationSupportDirectory() -> URL {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        // Channel split: "Array" only inside the prod-identified bundle;
        // dev bundles and bare binaries get "Array Dev" so dev/agent runs
        // can never touch the user's real state (see AppChannel).
        return appSupport.appendingPathComponent(AppChannel.liveApplicationSupportDirectoryName, isDirectory: true)
    }

    public func save(_ registry: Registry) throws {
        try writer.write(registry, to: registryFile)
    }

    public func load() throws -> Registry {
        let registry: Registry = try writer.read(at: registryFile)
        if registry.schemaVersion > Registry.currentSchemaVersion {
            throw RegistryStoreError.unknownFutureSchema(
                path: registryFile.path,
                version: registry.schemaVersion,
                supported: Registry.currentSchemaVersion
            )
        }
        return registry
    }

    /// Returns the registry on disk, or an empty registry if no file or
    /// recoverable backup exists. Future-version errors propagate so callers
    /// can choose how to surface them.
    public func loadOrEmpty() throws -> Registry {
        do {
            return try load()
        } catch AtomicWriterError.noValidBackup {
            return Registry.empty()
        }
    }
}
