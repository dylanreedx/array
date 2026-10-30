import Foundation
import Crypto
import GRDB
import ContinuumRevivedCollaborationProtocol

public enum CollaborationBackupError: Error, Equatable {
    case destinationExists, unknownSchema, damaged, hotJournal
}

/// What a verified backup holds. Counts only: no content, labels or hashes.
public struct CollaborationBackupReport: Codable, Equatable, Sendable {
    public var migrations: [String]
    public var people = 0, devices = 0, revokedDevices = 0, hosts = 0
    public var areas = 0, activeMembers = 0, removedMembers = 0, operations = 0
    public var invitations = 0, agentControls = 0, agentDispatches = 0, usageReports = 0
    public var receipts = 0, compactedAreas = 0, artifactBlobs = 0, artifactRevisions = 0, artifactReviews = 0
}

/// The one backup path: operator backup, verification and restore for the
/// collaboration database. The companion database is never touched here.
extension CollaborationStore {
    /// SQLite's online backup API copies one consistent read snapshot while the
    /// live relay keeps serving. The copy is verified before it is published at
    /// `destination`, so a file at that path is always a complete backup.
    public static func backup(databaseAt source: String, to destination: String, masterKey: Data) async throws -> CollaborationBackupReport {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: destination) else { throw CollaborationBackupError.destinationExists }
        let target = URL(fileURLWithPath: destination)
        try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = target.deletingLastPathComponent().appendingPathComponent(".\(target.lastPathComponent).partial-\(UUID())")
        defer { try? fileManager.removeItem(at: partial) }
        var readOnly = Configuration(); readOnly.readonly = true; readOnly.busyMode = .timeout(10)
        let live = try DatabaseQueue(path: source, configuration: readOnly)
        let copy = try DatabaseQueue(path: partial.path)
        try live.backup(to: copy)
        try copy.close(); try live.close()
        let report = try await verifyBackup(at: partial.path, masterKey: masterKey)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: partial.path)
        try fileManager.moveItem(at: partial, to: target)
        return report
    }

    /// Authenticates the key marker and every sealed record of a backup, and
    /// rebuilds every area head from its horizon snapshot plus retained tail
    /// (`verifyIntegrity`). Runs on a scratch copy so neither verification nor
    /// migration writes the backup.
    public static func verifyBackup(at path: String, masterKey: Data) async throws -> CollaborationBackupReport {
        let fileManager = FileManager.default
        let scratch = fileManager.temporaryDirectory.appendingPathComponent("array-collaboration-verify-\(UUID())")
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: scratch) }
        // The migrations this build knows are exactly the ones a fresh store records.
        let known = try migrations(of: CollaborationStore(path: scratch.appendingPathComponent("empty.sqlite").path, masterKey: masterKey).database)
        let copy = scratch.appendingPathComponent("backup.sqlite")
        try fileManager.copyItem(at: URL(fileURLWithPath: path), to: copy)
        let recorded: [String]
        do { recorded = try migrations(of: DatabaseQueue(path: copy.path)) } catch { throw CollaborationBackupError.damaged }
        guard Set(recorded).isSubset(of: Set(known)) else { throw CollaborationBackupError.unknownSchema }
        let store: CollaborationStore
        do { store = try CollaborationStore(path: copy.path, masterKey: masterKey) }
        catch CollaborationStoreError.invalidDatabaseKey { throw CollaborationStoreError.invalidDatabaseKey }
        catch { throw CollaborationBackupError.damaged }
        var report = try await store.auditBackupRecords(keyData: Data(SHA256.hash(data: masterKey)))
        do { _ = try await store.verifyIntegrity() } catch { throw CollaborationBackupError.damaged }
        report.migrations = recorded
        return report
    }

    /// Installs a verified backup at `livePath`. An existing database is moved
    /// aside, never deleted; the relay must be stopped first and restarted after.
    public static func restore(backup: String, to livePath: String, masterKey: Data) async throws -> (report: CollaborationBackupReport, movedAside: String?) {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: livePath + "-journal"), !fileManager.fileExists(atPath: livePath + "-wal") else {
            throw CollaborationBackupError.hotJournal
        }
        let report = try await verifyBackup(at: backup, masterKey: masterKey)
        let live = URL(fileURLWithPath: livePath)
        try fileManager.createDirectory(at: live.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = live.deletingLastPathComponent().appendingPathComponent(".\(live.lastPathComponent).restore-\(UUID())")
        defer { try? fileManager.removeItem(at: partial) }
        try fileManager.copyItem(at: URL(fileURLWithPath: backup), to: partial)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: partial.path)
        var movedAside: String?
        if fileManager.fileExists(atPath: livePath) {
            var index = 1, aside = livePath + ".before-restore"
            while fileManager.fileExists(atPath: aside) { index += 1; aside = livePath + ".before-restore-\(index)" }
            try fileManager.moveItem(atPath: livePath, toPath: aside)
            movedAside = aside
        }
        try fileManager.moveItem(at: partial, to: live)
        return (report, movedAside)
    }

    private static func migrations(of database: DatabaseQueue) throws -> [String] {
        try database.read { db in
            guard try db.tableExists("grdb_migrations") else { return [] }
            return try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
        }
    }

    /// Opens every sealed record through this store's own key and AAD rules.
    func auditBackupRecords(keyData: Data) throws -> CollaborationBackupReport {
        try database.read { db in
            func count(_ sql: String) throws -> Int { try Int.fetchOne(db, sql: sql) ?? 0 }
            func table(_ name: String, _ sql: String) throws -> Int { try db.tableExists(name) ? count(sql) : 0 }
            do {
                guard try String.fetchAll(db, sql: "PRAGMA integrity_check") == ["ok"],
                      try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty else { throw CollaborationBackupError.damaged }
                for row in try Row.fetchAll(db, sql: "SELECT id,revision,snapshot FROM areas") {
                    let document = try unseal(SharedArea.Document.self, row["snapshot"])
                    let head: Int64 = row["revision"]
                    guard UUID(uuidString: row["id"]) == document.id.rawValue, UInt64(head) == document.revision else { throw CollaborationBackupError.damaged }
                }
                for row in try Row.fetchAll(db, sql: "SELECT area,revision,operation_id,command FROM operations") {
                    let command = try unseal(SharedArea.Command.self, row["command"])
                    let revision: Int64 = row["revision"]
                    guard UUID(uuidString: row["area"]) == command.area.rawValue, UUID(uuidString: row["operation_id"]) == command.id.rawValue,
                          revision > 0, command.expectedRevision == UInt64(revision - 1) else { throw CollaborationBackupError.damaged }
                }
                if try db.tableExists("collaboration_usage") {
                    for row in try Row.fetchAll(db, sql: "SELECT host,payload FROM collaboration_usage") {
                        let snapshot = try unseal(Collaboration.UsageSnapshot.self, row["payload"])
                        guard snapshot.host.rawValue == UUID(uuidString: row["host"]) else { throw CollaborationBackupError.damaged }
                    }
                }
                if try db.tableExists("collaboration_artifact_blobs") {
                    for row in try Row.fetchAll(db, sql: "SELECT area,object,digest,length,sealed FROM collaboration_artifact_blobs") {
                        guard let area = UUID(uuidString: row["area"]), let object = UUID(uuidString: row["object"]) else { throw CollaborationBackupError.damaged }
                        let digest: String = row["digest"], length: Int = row["length"]
                        let bytes = try AES.GCM.open(AES.GCM.SealedBox(combined: row["sealed"] as Data), using: key, authenticating: Self.blobAAD(area, object, digest))
                        guard bytes.count == length, Artifact.digest(bytes) == digest else { throw CollaborationBackupError.damaged }
                    }
                    for row in try Row.fetchAll(db, sql: "SELECT record FROM collaboration_artifact_revisions") { _ = try unseal(Artifact.Record.self, row["record"]) }
                    for row in try Row.fetchAll(db, sql: "SELECT review FROM collaboration_artifact_reviews") { _ = try unseal(Artifact.Review.self, row["review"]) }
                }
                if try db.tableExists("collaboration_agent_projection") {
                    for row in try Row.fetchAll(db, sql: "SELECT object,host,payload FROM collaboration_agent_projection") {
                        let log = try unseal(Collaboration.AgentProjection.Log.self, row["payload"])
                        guard log.head.object.rawValue == UUID(uuidString: row["object"]), log.head.host.rawValue == UUID(uuidString: row["host"]),
                              log.head.valid else { throw CollaborationBackupError.damaged }
                    }
                }
                try Self.validateHandoffCiphertext(db, keyData: keyData)
            } catch let error as CollaborationBackupError { throw error }
            catch { throw CollaborationBackupError.damaged }
            var report = CollaborationBackupReport(migrations: [])
            report.people = try count("SELECT COUNT(*) FROM people")
            report.devices = try count("SELECT COUNT(*) FROM devices")
            report.revokedDevices = try count("SELECT COUNT(*) FROM devices WHERE revoked<>0")
            report.hosts = try count("SELECT COUNT(*) FROM hosts")
            report.areas = try count("SELECT COUNT(*) FROM areas")
            report.activeMembers = try count("SELECT COUNT(*) FROM members WHERE active<>0")
            report.removedMembers = try count("SELECT COUNT(*) FROM members WHERE active=0")
            report.operations = try count("SELECT COUNT(*) FROM operations")
            report.invitations = try count("SELECT COUNT(*) FROM invitations")
            report.agentControls = try table("agent_control", "SELECT COUNT(*) FROM agent_control")
            report.agentDispatches = try table("agent_dispatches", "SELECT COUNT(*) FROM agent_dispatches")
            report.usageReports = try table("collaboration_usage", "SELECT COUNT(*) FROM collaboration_usage")
            report.receipts = try table("operation_receipts", "SELECT COUNT(*) FROM operation_receipts")
            report.compactedAreas = try db.columns(in: "areas").contains { $0.name == "horizon" } ? count("SELECT COUNT(*) FROM areas WHERE horizon>0") : 0
            report.artifactBlobs = try table("collaboration_artifact_blobs", "SELECT COUNT(*) FROM collaboration_artifact_blobs")
            report.artifactRevisions = try table("collaboration_artifact_revisions", "SELECT COUNT(*) FROM collaboration_artifact_revisions")
            report.artifactReviews = try table("collaboration_artifact_reviews", "SELECT COUNT(*) FROM collaboration_artifact_reviews")
            return report
        }
    }
}
