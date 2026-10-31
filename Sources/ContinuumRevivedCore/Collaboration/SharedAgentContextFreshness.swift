import Foundation
import CryptoKit
import GRDB
import ContinuumRevivedCollaborationProtocol

public enum SharedAgentFreshnessError: Error { case invalidDirectory, invalidState, changedIntent, excerptRejected }

/// What one agent incarnation was given, measured only by host acceptance.
/// "Accepted" means the owning host accepted the exact frozen command. It is
/// never a claim that the agent read, understood or followed the agreement.
public struct SharedAgentContextFreshness: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        /// This ledger holds no accepted delivery for the incarnation. Receipts
        /// are visible only to their requester and the agent's owner, so this
        /// is not proof that nobody else sent one.
        case notSent
        case current(SharedArea.ID<SharedArea.Revision>)
        case changedSinceSent(sent: SharedArea.ID<SharedArea.Revision>, current: SharedArea.ID<SharedArea.Revision>, newerRevisions: Int)
        /// The agreement this agent last received is no longer in the area.
        case agreementRemoved(sent: SharedArea.ID<SharedArea.Revision>)
    }
    public let state: State
    /// Last delivery the host accepted; the baseline every comparison uses.
    public let lastAccepted: Collaboration.AgentDispatchCommand?
    /// A newer delivery still between queued and a final outcome.
    public let awaitingHost: Collaboration.AgentDispatchCommand?
    /// A newer delivery that ended refused or uncertain. It does not move
    /// the baseline: a refusal changed nothing and uncertainty proves nothing.
    public let unresolved: (command: Collaboration.AgentDispatchCommand, phase: Collaboration.AgentDispatchPhase)?
    /// 1-based position of each revision in its agreement's history.
    public let sentOrdinal: Int?
    public let currentOrdinal: Int?

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.state == rhs.state && lhs.lastAccepted == rhs.lastAccepted && lhs.awaitingHost == rhs.awaitingHost
            && lhs.unresolved?.command == rhs.unresolved?.command && lhs.unresolved?.phase == rhs.unresolved?.phase
            && lhs.sentOrdinal == rhs.sentOrdinal && lhs.currentOrdinal == rhs.currentOrdinal
    }

    public var label: String {
        switch state {
        case .notSent: return "No accepted revision recorded on this device"
        case .current: return "Last accepted revision \(sentOrdinal ?? 0) · Current"
        case .changedSinceSent:
            return "Last accepted revision \(sentOrdinal ?? 0) · Current revision \(currentOrdinal ?? 0) · Changed since sent"
        case .agreementRemoved: return "Last accepted revision \(sentOrdinal ?? 0) · Agreement no longer shared"
        }
    }
    /// Shown beside every label; acceptance is the only evidence recorded.
    public static let caveat = "Accepted by the agent's host. Not a record that the agent read or followed it."
}

/// Per-device, per-area record of dispatch receipts and frozen result excerpts.
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

    /// Changes when another connection (the handoff client's hook) commits.
    public func changeToken() throws -> Int {
        try database.read { db in try Int.fetchOne(db, sql: "PRAGMA data_version") ?? 0 }
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

    public func freshness(of incarnation: Collaboration.AgentIncarnation, agreement: SharedArea.ID<SharedArea.Object>,
                          in document: SharedArea.Document) throws -> SharedAgentContextFreshness {
        let rows = try database.read { db in
            try Row.fetchAll(db, sql: "SELECT frozen,phase,observed,accepted FROM freshness_deliveries WHERE object=? AND generation=? ORDER BY observed",
                arguments: [incarnation.object.rawValue.uuidString, incarnation.hostGeneration.uuidString])
        }
        var deliveries: [(command: Collaboration.AgentDispatchCommand, phase: Collaboration.AgentDispatchPhase, observed: Int64, accepted: Int64?)] = []
        for row in rows {
            let command = try JSONDecoder().decode(Collaboration.AgentDispatchCommand.self, from: row["frozen"] as Data)
            // A prompt sent without an agreement revision says nothing about it.
            guard command.context?.object == agreement, let phase = Collaboration.AgentDispatchPhase(rawValue: row["phase"]) else { continue }
            deliveries.append((command, phase, row["observed"], row["accepted"]))
        }
        let baseline = deliveries.filter { $0.phase == .accepted }.max { ($0.accepted ?? 0) < ($1.accepted ?? 0) }
        let after = deliveries.filter { $0.observed > (baseline?.observed ?? 0) && $0.phase != .accepted }
        let awaiting = after.last { !$0.phase.isFinal }?.command
        let unresolved = after.last { $0.phase.isFinal }.map { (command: $0.command, phase: $0.phase) }
        let history = document.contexts.filter { $0.object == agreement }
        let head = document.items.contains(where: { $0.id == agreement }) ? history.last : nil
        func ordinal(_ id: SharedArea.ID<SharedArea.Revision>) -> Int? { history.firstIndex { $0.id == id }.map { $0 + 1 } }
        let state: SharedAgentContextFreshness.State
        if let sent = baseline?.command.context?.id {
            if let head {
                state = head.id == sent ? .current(sent)
                    : .changedSinceSent(sent: sent, current: head.id, newerRevisions: (ordinal(head.id) ?? 0) - (ordinal(sent) ?? 0))
            } else { state = .agreementRemoved(sent: sent) }
        } else { state = .notSent }
        return .init(state: state, lastAccepted: baseline?.command, awaitingHost: awaiting, unresolved: unresolved,
                     sentOrdinal: baseline?.command.context.flatMap { ordinal($0.id) }, currentOrdinal: head.flatMap { ordinal($0.id) })
    }

    /// Keeps a frozen quote. The same ID can never be rewritten.
    public func keep(_ excerpt: Collaboration.ResultExcerpt) throws {
        guard excerpt.isWellFormed else { throw SharedAgentFreshnessError.excerptRejected }
        let frozen = try Self.encode(excerpt)
        let digest = Data(SHA256.hash(data: frozen))
        try database.write { db in
            if let prior = try Data.fetchOne(db, sql: "SELECT digest FROM freshness_excerpts WHERE id=?", arguments: [excerpt.id.uuidString]) {
                guard prior == digest else { throw SharedAgentFreshnessError.changedIntent }
                return
            }
            let next = (try Int64.fetchOne(db, sql: "SELECT MAX(observed) FROM freshness_excerpts") ?? 0) + 1
            try db.execute(sql: "INSERT INTO freshness_excerpts(id,digest,frozen,observed) VALUES (?,?,?,?)",
                arguments: [excerpt.id.uuidString, digest, frozen, next])
        }
    }
    public func excerpts() throws -> [Collaboration.ResultExcerpt] {
        try database.read { db in
            try Data.fetchAll(db, sql: "SELECT frozen FROM freshness_excerpts ORDER BY observed")
                .map { try JSONDecoder().decode(Collaboration.ResultExcerpt.self, from: $0) }
        }
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
}
