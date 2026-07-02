import Foundation

public final class ManagedAgentSessionStore: @unchecked Sendable {
    private let writer: AtomicWriter
    private let layout: ProjectStoreLayout

    public init(projectRoot: URL, retainedBackups: Int = 3) {
        self.layout = ProjectStoreLayout(projectRoot: projectRoot)
        self.writer = AtomicWriter(
            backupsDirectory: layout.backupsDirectory,
            retainedBackups: retainedBackups
        )
    }

    public func upsert(_ record: ManagedAgentSessionRecord) throws {
        try writer.write(record, to: layout.managedSessionFile(tileId: record.tileId))
    }

    public func load(tileId: UUID) throws -> ManagedAgentSessionRecord? {
        let url = layout.managedSessionFile(tileId: tileId)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try writer.read(at: url)
    }

    public func delete(tileId: UUID) throws {
        let url = layout.managedSessionFile(tileId: tileId)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    public func loadAll() throws -> [ManagedAgentSessionRecord] {
        let dir = layout.managedSessionsDirectory
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
        let entries = try FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        var records: [ManagedAgentSessionRecord] = []
        for entry in entries where entry.pathExtension == "json" {
            do {
                let record: ManagedAgentSessionRecord = try writer.read(at: entry)
                records.append(record)
            } catch {
                continue
            }
        }
        return records
    }
}
