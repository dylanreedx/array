import Foundation
import GRDB
import ContinuumRevivedCollaborationProtocol

/// One published agent stream's lane: its owning host and the log.
struct CollaborationAgentTranscriptEntry {
    var host: String
    var log: Collaboration.AgentTranscript.Log
}
struct CollaborationAgentTranscriptWaiter {
    let key: String
    let continuation: CheckedContinuation<Void, Never>
    let timeout: Task<Void, Never>
}
/// Memory only, like the live tile lane: nothing durable, no migration.
struct CollaborationAgentTranscriptTable {
    var entries: [String: CollaborationAgentTranscriptEntry] = [:]
    var waiters: [UUID: CollaborationAgentTranscriptWaiter] = [:]
    static let maxWaiters = 1024
    static func key(_ area: UUID, _ object: UUID, _ stream: String) -> String {
        area.uuidString + "/" + object.uuidString + "/" + stream
    }
}

extension CollaborationStore {
    /// The source of an agent observation this area still publishes.
    func agentTranscriptSource(_ db: Database, area: UUID, object: UUID) throws -> SharedArea.Source {
        let state: Data = try Data.fetchOne(db, sql: "SELECT snapshot FROM areas WHERE id=?", arguments: [area.uuidString])!
        let document = try unseal(SharedArea.Document.self, state)
        guard let source = document.items.first(where: { $0.id.rawValue == object && $0.kind == .agentObservation })?.source else {
            throw CollaborationStoreError.unavailable
        }
        return source
    }

    /// Only the registered device that hosts this agent, as its owner, writes.
    public func publishAgentTranscript(token: String, area: UUID, object: UUID, report: Collaboration.AgentTranscript.Publish) throws {
        try database.read { db in
            let identity = try authenticate(db, token), access = try scope(db, identity, area)
            guard access.epoch == report.epoch else { throw CollaborationStoreError.staleEpoch }
            guard try String.fetchOne(db, sql: "SELECT device FROM hosts WHERE id=?", arguments: [report.host.rawValue.uuidString]) == identity.device.uuidString else {
                throw CollaborationStoreError.forbidden
            }
            let source = try agentTranscriptSource(db, area: area, object: object)
            guard source.host == report.host, source.owner == identity.person else { throw CollaborationStoreError.forbidden }
        }
        let key = CollaborationAgentTranscriptTable.key(area, object, report.stream)
        let held = agentTranscripts.entries[key].flatMap { $0.host == report.host.rawValue.uuidString ? $0.log : nil }
        let next: Collaboration.AgentTranscript.Log
        do { next = try Collaboration.AgentTranscript.Log.publish(report, onto: held) }
        catch .checkpointRequired { throw CollaborationStoreError.invalidCursor }
        catch .stale { throw SharedArea.Failure.conflict }
        catch { throw CollaborationStoreError.invalidRequest }
        agentTranscripts.entries[key] = .init(host: report.host.rawValue.uuidString, log: next)
        wakeAgentTranscript(key)
    }

    /// Any current member reads. Holds until a frame arrives when the reader is current.
    public func readAgentTranscript(token: String, area: UUID, object: UUID,
                                    request: Collaboration.AgentTranscript.ReadRequest) async throws -> Collaboration.AgentTranscript.Read {
        guard (0...Collaboration.AgentTranscript.maxWaitMilliseconds).contains(request.waitMilliseconds),
              Collaboration.AgentTranscript.validStream(request.stream) else { throw CollaborationStoreError.invalidRequest }
        let key = CollaborationAgentTranscriptTable.key(area, object, request.stream)
        var page = try agentTranscriptPage(token: token, area: area, object: object, key: key, request: request)
        guard case let .frames(_, frames, _) = page, frames.isEmpty, request.waitMilliseconds > 0,
              agentTranscripts.waiters.count < CollaborationAgentTranscriptTable.maxWaiters else { return page }
        let id = UUID(), milliseconds = request.waitMilliseconds
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let timer = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(milliseconds))
                    await self?.finishAgentTranscriptWaiter(id)
                }
                agentTranscripts.waiters[id] = .init(key: key, continuation: continuation, timeout: timer)
            }
        } onCancel: {
            Task { await self.finishAgentTranscriptWaiter(id) }
        }
        try Task.checkCancellation()
        page = try agentTranscriptPage(token: token, area: area, object: object, key: key, request: request)
        return page
    }

    private func agentTranscriptPage(token: String, area: UUID, object: UUID, key: String,
                                     request: Collaboration.AgentTranscript.ReadRequest) throws -> Collaboration.AgentTranscript.Read {
        let source = try database.read { db -> SharedArea.Source in
            let identity = try authenticate(db, token), access = try scope(db, identity, area)
            guard access.allows(.view) else { throw CollaborationStoreError.forbidden }
            return try agentTranscriptSource(db, area: area, object: object)
        }
        // No lane yet (an older host, or a relay restart): the reader falls back.
        guard let entry = agentTranscripts.entries[key], entry.host == source.host.rawValue.uuidString else {
            throw CollaborationStoreError.unavailable
        }
        return entry.log.read(after: request.cursor)
    }

    func wakeAgentTranscript(_ key: String) {
        for id in agentTranscripts.waiters.filter({ $0.value.key == key }).map(\.key) { finishAgentTranscriptWaiter(id) }
    }
    func finishAgentTranscriptWaiter(_ id: UUID) {
        guard let waiter = agentTranscripts.waiters.removeValue(forKey: id) else { return }
        waiter.timeout.cancel()
        waiter.continuation.resume()
    }

    /// An agent that left the area, or moved to another host, loses its lanes.
    func refreshAgentTranscriptAccess(area: UUID, document: SharedArea.Document) {
        let prefix = area.uuidString + "/"
        let live = Dictionary(document.items.compactMap { item in
            item.kind == .agentObservation ? item.source.map { (item.id.rawValue.uuidString, $0.host.rawValue.uuidString) } : nil
        }, uniquingKeysWith: { first, _ in first })
        for (key, entry) in agentTranscripts.entries where key.hasPrefix(prefix) {
            let object = key.dropFirst(prefix.count).split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
            if live[object] != entry.host {
                agentTranscripts.entries.removeValue(forKey: key)
                wakeAgentTranscript(key)
            }
        }
    }
}
