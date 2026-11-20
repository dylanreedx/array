import Foundation
import CryptoKit

/// Host identity travels with the queue item, never inferred from its text.
public struct AgentMessageQueueContext: Codable, Equatable, Sendable {
    public var caller: AgentID
    public var recipient: AgentID
    public var operationId: String
    public var idempotencyKey: String
    public var payloadHash: String

    public init(caller: AgentID, recipient: AgentID, operationId: String,
                idempotencyKey: String, payloadHash: String) {
        self.caller = caller; self.recipient = recipient; self.operationId = operationId
        self.idempotencyKey = idempotencyKey; self.payloadHash = payloadHash
    }
}

/// Durable admission is separate from the asynchronous composer queue mirror.
/// Retained terminal entries prevent retrying an accepted key after restart.
@MainActor
public final class AgentMessageOutbox {
    public struct Entry: Codable, Equatable, Sendable {
        public enum Phase: String, Codable, Sendable { case queued, started, settled, cancelled }
        public var context: AgentMessageQueueContext
        public var message: AgentComposerQueuedMessage
        public var phase: Phase
        public var result: SpawnResultFile?
        public var queuePosition: Int?
        /// Why the recipient's queue held this message at admission, so an
        /// idempotent replay after a restart still says so.
        public var heldReason: String?

        public init(context: AgentMessageQueueContext, message: AgentComposerQueuedMessage, queuePosition: Int? = nil) {
            self.context = context; self.message = message; self.phase = .queued
            self.queuePosition = queuePosition
        }
    }

    public private(set) var writeRevision: UInt64 = 0
    public let directory: URL
    private let writer = AtomicWriter(retainedBackups: 0)

    public init(applicationSupportDirectory: URL) {
        directory = applicationSupportDirectory.appendingPathComponent("agent-message-outbox", isDirectory: true)
    }

    private func url(caller: AgentID, key: String) -> URL {
        let digest = SHA256.hash(data: Data((caller.rawValue.uuidString + "\n" + key).utf8))
            .map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest + ".json")
    }

    public func lookup(caller: AgentID, key: String) throws -> Entry? {
        let path = url(caller: caller, key: key)
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        return try JSONCodec.makeDecoder().decode(Entry.self, from: Data(contentsOf: path))
    }

    /// Entry files `entries()` has decoded since launch, for the restore-at-scale
    /// witness: restore once decoded the whole outbox per agent and hung boot.
    public static var entriesDecodedForQA: Int { entriesDecoded.value }
    private static let entriesDecoded = QACounter()

    public static var enumerationsForQA: Int { enumerations.value }
    private static let enumerations = QACounter()

    /// The decoded outbox, kept from the first read. Only this object writes entry
    /// files (`save`), so the directory cannot change under it. Every finished turn
    /// drains its agent's queue on the main thread and asks for `entries()`; with a
    /// few hundred retained entries that was a directory scan plus a JSON decode of
    /// every file per turn (44% of the main thread's busy time in a live sample).
    /// `CONTINUUM_QA_LEGACY_OUTBOX_RESCAN=1` restores the rescan for the witness.
    private var cachedEntries: [Entry]?
    private static let legacyRescan = ProcessInfo.processInfo.environment["CONTINUUM_QA_LEGACY_OUTBOX_RESCAN"] == "1"

    public func entries() throws -> [Entry] {
        if !Self.legacyRescan, let cachedEntries { return cachedEntries }
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        Self.enumerations.increment()
        let decoded = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .map { Self.entriesDecoded.increment(); return try JSONCodec.makeDecoder().decode(Entry.self, from: Data(contentsOf: $0)) }
            .sorted { $0.message.queuedAt < $1.message.queuedAt }
        cachedEntries = decoded
        return decoded
    }

    public func save(_ entry: Entry) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try writer.write(entry, to: url(caller: entry.context.caller, key: entry.context.idempotencyKey))
        writeRevision &+= 1
        if var cached = cachedEntries {
            let at = cached.firstIndex {
                $0.context.caller == entry.context.caller && $0.context.idempotencyKey == entry.context.idempotencyKey
            }
            if let at { cached[at] = entry } else { cached.append(entry) }
            cachedEntries = cached.sorted { $0.message.queuedAt < $1.message.queuedAt }
        }
    }
}
