import Foundation
import CryptoKit
import GRDB
import ContinuumRevivedCollaborationProtocol

public enum SharedAgentFreshnessError: Error { case invalidDirectory, invalidState, changedIntent }

/// Per-device, per-area record of dispatch receipts.
/// It observes receipts and never sends: nothing here can start a dispatch.
public final class SharedAgentFreshnessLedger: @unchecked Sendable {
    private let database: DatabaseQueue

    public init(directory: URL) throws {
        guard directory.isFileURL, directory.path.hasPrefix("/") else { throw SharedAgentFreshnessError.invalidDirectory }
        let fm = FileManager.default
        if fm.fileExists(atPath: directory.path) {
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw SharedAgentFreshnessError.invalidDirectory }
        } else { try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        let file = directory.appendingPathComponent("agent-freshness.sqlite")
        if fm.fileExists(atPath: file.path), try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
            throw SharedAgentFreshnessError.invalidDirectory
        }
        var config = Configuration(); config.busyMode = .timeout(2)
        database = try DatabaseQueue(path: file.path, configuration: config)
        try database.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS freshness_schema(version INTEGER NOT NULL);
                INSERT INTO freshness_schema(version) SELECT 1 WHERE NOT EXISTS(SELECT 1 FROM freshness_schema);
                """)
            guard try Int.fetchOne(db, sql: "SELECT version FROM freshness_schema") == 1 else { throw SharedAgentFreshnessError.invalidState }
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS freshness_deliveries(command TEXT PRIMARY KEY NOT NULL, object TEXT NOT NULL,
                  generation TEXT NOT NULL, digest BLOB NOT NULL, frozen BLOB NOT NULL, phase TEXT NOT NULL,
                  observed INTEGER NOT NULL, accepted INTEGER);
                CREATE TABLE IF NOT EXISTS freshness_excerpts(id TEXT PRIMARY KEY NOT NULL, digest BLOB NOT NULL,
                  frozen BLOB NOT NULL, observed INTEGER NOT NULL);
                """)
        }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    /// Records a service receipt. The frozen command is written once: a receipt
    /// whose command differs under the same ID is refused, so a later agreement
    /// edit can never rewrite what an agent was already given. Final phases are
    /// sticky; only the first `.accepted` assigns the acceptance order.
    @discardableResult
    public func record(_ receipt: Collaboration.AgentDispatchReceipt) throws -> Collaboration.AgentDispatchPhase {
        let command = receipt.command
        let frozen = try Self.encode(command)
        let digest = Data(SHA256.hash(data: frozen))
        return try database.write { db in
            let next = (try Int64.fetchOne(db, sql: "SELECT MAX(n) FROM (SELECT MAX(observed) n FROM freshness_deliveries UNION ALL SELECT MAX(accepted) FROM freshness_deliveries)") ?? 0) + 1
            guard let row = try Row.fetchOne(db, sql: "SELECT digest,phase FROM freshness_deliveries WHERE command=?", arguments: [command.id.uuidString]) else {
                try db.execute(sql: """
                    INSERT INTO freshness_deliveries(command,object,generation,digest,frozen,phase,observed,accepted) VALUES (?,?,?,?,?,?,?,?)
                    """, arguments: [command.id.uuidString, command.object.rawValue.uuidString, command.hostGeneration.uuidString,
                                     digest, frozen, receipt.phase.rawValue, next, receipt.phase == .accepted ? next : nil])
                return receipt.phase
            }
            guard row["digest"] as Data == digest else { throw SharedAgentFreshnessError.changedIntent }
            guard let prior = Collaboration.AgentDispatchPhase(rawValue: row["phase"]) else { throw SharedAgentFreshnessError.invalidState }
            if prior.isFinal || prior == receipt.phase { return prior }
            try db.execute(sql: "UPDATE freshness_deliveries SET phase=?, accepted=? WHERE command=?",
                arguments: [receipt.phase.rawValue, receipt.phase == .accepted ? next : nil, command.id.uuidString])
            return receipt.phase
        }
    }

    /// Commands still between queued and a final outcome. A client re-reads
    /// each from the service; only the most recent one is otherwise refreshed.
    public func unsettledCommands() throws -> [UUID] {
        try database.read { db in
            try String.fetchAll(db, sql: "SELECT command FROM freshness_deliveries WHERE phase NOT IN ('accepted','refused','uncertain') ORDER BY observed")
                .compactMap(UUID.init(uuidString:))
        }
    }

    /// The exact execution input recorded for a command, never re-derived from
    /// the area's current agreement.
    public func frozenCommand(_ id: UUID) throws -> Collaboration.AgentDispatchCommand? {
        try database.read { db in
            try Data.fetchOne(db, sql: "SELECT frozen FROM freshness_deliveries WHERE command=?", arguments: [id.uuidString])
                .map { try JSONDecoder().decode(Collaboration.AgentDispatchCommand.self, from: $0) }
        }
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
}
