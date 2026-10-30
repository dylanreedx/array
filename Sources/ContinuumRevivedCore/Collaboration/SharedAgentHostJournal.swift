import Foundation
import CryptoKit
import GRDB
import ContinuumRevivedCollaborationProtocol

public enum SharedAgentHostJournalError: Error { case invalidDirectory, invalidState, changedIntent, lostAttempt }

/// Host-local irreversible boundary. A persisted `attempting` from an older
/// process is uncertain; no provider action is automatically replayed.
public final class SharedAgentHostJournal: @unchecked Sendable {
    public enum Phase: String, Codable, Sendable { case prepared, attempting, accepted, refused, uncertain }
    public struct Attempt: Sendable {
        public let id: UUID
        public let claimID: UUID
        public let phase: Phase
        public let bootID: UUID?
    }
    private let database: DatabaseQueue
    public init(directory: URL) throws {
        guard directory.isFileURL, directory.path.hasPrefix("/") else { throw SharedAgentHostJournalError.invalidDirectory }
        let fm = FileManager.default
        if fm.fileExists(atPath: directory.path) {
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw SharedAgentHostJournalError.invalidDirectory }
        } else { try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        let file = directory.appendingPathComponent("agent-host-journal.sqlite")
        if fm.fileExists(atPath: file.path), try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
            throw SharedAgentHostJournalError.invalidDirectory
        }
        var config = Configuration(); config.busyMode = .timeout(2)
        database = try DatabaseQueue(path: file.path, configuration: config)
        try database.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS handoff_journal_schema(version INTEGER NOT NULL);
                INSERT INTO handoff_journal_schema(version) SELECT 1 WHERE NOT EXISTS(SELECT 1 FROM handoff_journal_schema);
                """)
            guard try Int.fetchOne(db, sql: "SELECT version FROM handoff_journal_schema") == 1 else { throw SharedAgentHostJournalError.invalidState }
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS handoff_bindings(object TEXT PRIMARY KEY NOT NULL, digest BLOB NOT NULL, generation TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS handoff_attempts(id TEXT PRIMARY KEY NOT NULL, digest BLOB NOT NULL,
                  claim TEXT NOT NULL, phase TEXT NOT NULL, boot TEXT);
                CREATE TABLE IF NOT EXISTS handoff_queue(item TEXT PRIMARY KEY NOT NULL, command BLOB NOT NULL);
                """)
        }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    public func generation(for binding: SharedAreaLocalSourceBinding) throws -> UUID {
        struct LogicalBinding: Encodable {
            let object: SharedArea.ID<SharedArea.Object>
            let binding: SharedArea.ID<SharedArea.Binding>
            let host: SharedArea.ID<SharedArea.Host>
            let projectID: UUID
            let agentID: AgentID?
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let logical = LogicalBinding(object: binding.object, binding: binding.binding, host: binding.host,
            projectID: binding.projectID, agentID: binding.agentID)
        let digest = Data(SHA256.hash(data: try encoder.encode(logical)))
        return try database.write { db in
            if let row = try Row.fetchOne(db, sql: "SELECT digest,generation FROM handoff_bindings WHERE object=?", arguments: [binding.object.rawValue.uuidString]),
               row["digest"] as Data == digest, let generation = UUID(uuidString: row["generation"]) { return generation }
            let generation = UUID()
            try db.execute(sql: "INSERT INTO handoff_bindings(object,digest,generation) VALUES (?,?,?) ON CONFLICT(object) DO UPDATE SET digest=excluded.digest,generation=excluded.generation",
                arguments: [binding.object.rawValue.uuidString, digest, generation.uuidString])
            return generation
        }
    }
    public func prepare(_ command: Collaboration.AgentDispatchCommand) throws -> Attempt {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let digest = Data(SHA256.hash(data: try encoder.encode(command)))
        return try database.write { db in
            if let row = try Row.fetchOne(db, sql: "SELECT * FROM handoff_attempts WHERE id=?", arguments: [command.id.uuidString]) {
                guard row["digest"] as Data == digest else { throw SharedAgentHostJournalError.changedIntent }
                return try attempt(row)
            }
            let claim = UUID()
            try db.execute(sql: "INSERT INTO handoff_attempts(id,digest,claim,phase) VALUES (?,?,?,'prepared')",
                arguments: [command.id.uuidString, digest, claim.uuidString])
            return .init(id: command.id, claimID: claim, phase: .prepared, bootID: nil)
        }
    }
    public func beginAttempt(_ attempt: Attempt, bootID: UUID) throws -> Bool {
        try database.write { db in
            try db.execute(sql: "UPDATE handoff_attempts SET phase='attempting',boot=? WHERE id=? AND claim=? AND phase='prepared'",
                arguments: [bootID.uuidString, attempt.id.uuidString, attempt.claimID.uuidString])
            return db.changesCount == 1
        }
    }
    public func finish(_ attempt: Attempt, phase: Phase) throws {
        guard phase == .accepted || phase == .refused || phase == .uncertain else { throw SharedAgentHostJournalError.invalidState }
        try database.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM handoff_attempts WHERE id=? AND claim=?",
                                            arguments: [attempt.id.uuidString, attempt.claimID.uuidString]) else { throw SharedAgentHostJournalError.lostAttempt }
            let prior = try self.attempt(row)
            if prior.phase == phase { return }
            guard prior.phase == .attempting || (prior.phase == .prepared && phase == .refused) else { throw SharedAgentHostJournalError.invalidState }
            try db.execute(sql: "UPDATE handoff_attempts SET phase=? WHERE id=? AND claim=?",
                arguments: [phase.rawValue, attempt.id.uuidString, attempt.claimID.uuidString])
        }
    }
    public func attempts() throws -> [Attempt] {
        try database.read { db in try Row.fetchAll(db, sql: "SELECT * FROM handoff_attempts ORDER BY rowid").map(attempt) }
    }
    public func rememberQueued(item: UUID, command: Collaboration.AgentDispatchCommand) throws {
        guard command.mode == .queue else { throw SharedAgentHostJournalError.invalidState }
        try database.write { db in
            if let data = try Data.fetchOne(db, sql: "SELECT command FROM handoff_queue WHERE item=?", arguments: [item.uuidString]) {
                guard try JSONDecoder().decode(Collaboration.AgentDispatchCommand.self, from: data) == command else { throw SharedAgentHostJournalError.changedIntent }
                return
            }
            try db.execute(sql: "INSERT INTO handoff_queue(item,command) VALUES (?,?)", arguments: [item.uuidString, try JSONEncoder().encode(command)])
        }
    }
    public func queuedCommand(item: UUID) throws -> Collaboration.AgentDispatchCommand? {
        try database.read { db in
            guard let bytes = try Data.fetchOne(db, sql: "SELECT command FROM handoff_queue WHERE item=?", arguments: [item.uuidString]) else { return nil }
            return try JSONDecoder().decode(Collaboration.AgentDispatchCommand.self, from: bytes)
        }
    }
    private func attempt(_ row: Row) throws -> Attempt {
        let boot: String? = row["boot"]
        guard let id = UUID(uuidString: row["id"]), let claim = UUID(uuidString: row["claim"]),
              let phase = Phase(rawValue: row["phase"]) else { throw SharedAgentHostJournalError.invalidState }
        return .init(id: id, claimID: claim, phase: phase, bootID: boot.flatMap(UUID.init(uuidString:)))
    }
}
