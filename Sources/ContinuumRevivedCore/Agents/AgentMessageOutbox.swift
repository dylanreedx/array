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

        public init(context: AgentMessageQueueContext, message: AgentComposerQueuedMessage, queuePosition: Int? = nil) {
            self.context = context; self.message = message; self.phase = .queued
            self.queuePosition = queuePosition
        }
    }

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

    public func entries() throws -> [Entry] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .map { try JSONCodec.makeDecoder().decode(Entry.self, from: Data(contentsOf: $0)) }
            .sorted { $0.message.queuedAt < $1.message.queuedAt }
    }

    public func save(_ entry: Entry) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try writer.write(entry, to: url(caller: entry.context.caller, key: entry.context.idempotencyKey))
    }
}
