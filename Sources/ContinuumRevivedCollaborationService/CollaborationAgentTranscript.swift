import Foundation
import GRDB
import ContinuumRevivedCollaborationProtocol

/// One published agent stream's lane: its owning host and the log.
struct CollaborationAgentTranscriptEntry {
    var host: String
    var log: Collaboration.AgentTranscript.Log
    var charge: Int
    var lastWrite: UInt64
}
struct CollaborationAgentTranscriptWaiter {
    let key: String
    let continuation: CheckedContinuation<Void, Never>
    let timeout: Task<Void, Never>
}
/// Memory only, like the live tile lane: nothing durable, no migration.
struct CollaborationAgentTranscriptRate {
    var tokens: Double
    var bytes: Double
    var at: Date
}
struct CollaborationAgentTranscriptTable {
    var entries: [String: CollaborationAgentTranscriptEntry] = [:]
    var waiters: [UUID: CollaborationAgentTranscriptWaiter] = [:]
    var rates: [String: CollaborationAgentTranscriptRate] = [:]
    var writeSequence: UInt64 = 0
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
        let tile = area.uuidString + "/" + object.uuidString + "/"
        let tileEntries = agentTranscripts.entries.filter { $0.key.hasPrefix(tile) }
        func size(_ log: Collaboration.AgentTranscript.Log) -> Int {
            // Charge metadata as well as bodies, including empty streams and frames.
            512 + log.checkpoint.body.count + log.retainedBytes + 128 * log.frames.count
        }
        let oldBytes = agentTranscripts.entries[key]?.charge ?? 0
        let nextBytes = size(next)
        guard nextBytes <= Collaboration.AgentTranscript.maxBytesPerTile,
              nextBytes <= Collaboration.AgentTranscript.maxBytesTotal else { throw CollaborationStoreError.rateLimited }
        var tileBytes = tileEntries.values.reduce(0) { $0 + $1.charge } - oldBytes + nextBytes
        var totalBytes = agentTranscripts.entries.values.reduce(0) { $0 + $1.charge } - oldBytes + nextBytes
        let isNew = agentTranscripts.entries[key] == nil
        var tileCount = tileEntries.count + (isNew ? 1 : 0)
        var totalCount = agentTranscripts.entries.count + (isNew ? 1 : 0)
        // Select victims before changing anything: a rejected/rate-limited
        // publish must not discard a reader's retained checkpoint.
        let oldest = agentTranscripts.entries.filter { $0.key != key }.sorted {
            $0.value.lastWrite == $1.value.lastWrite ? $0.key < $1.key : $0.value.lastWrite < $1.value.lastWrite
        }
        var victims: Set<String> = []
        for entry in oldest where entry.key.hasPrefix(tile) {
            guard tileCount > Collaboration.AgentTranscript.maxStreamsPerTile || tileBytes > Collaboration.AgentTranscript.maxBytesPerTile else { break }
            victims.insert(entry.key); tileCount -= 1; totalCount -= 1
            tileBytes -= entry.value.charge; totalBytes -= entry.value.charge
        }
        guard tileCount <= Collaboration.AgentTranscript.maxStreamsPerTile,
              tileBytes <= Collaboration.AgentTranscript.maxBytesPerTile else { throw CollaborationStoreError.rateLimited }
        for entry in oldest where !victims.contains(entry.key) {
            guard totalCount > Collaboration.AgentTranscript.maxStreamsTotal || totalBytes > Collaboration.AgentTranscript.maxBytesTotal else { break }
            victims.insert(entry.key); totalCount -= 1; totalBytes -= entry.value.charge
        }
        guard totalCount <= Collaboration.AgentTranscript.maxStreamsTotal,
              totalBytes <= Collaboration.AgentTranscript.maxBytesTotal else { throw CollaborationStoreError.rateLimited }
        // Per-tile token buckets bound both patch rate and bytes, including batches.
        let now = clock(), previous = agentTranscripts.rates[tile] ?? .init(tokens: 32, bytes: 2_097_152, at: now)
        let elapsed = max(0, now.timeIntervalSince(previous.at))
        let tokens = min(32, previous.tokens + elapsed * 16)
        let bytes = min(2_097_152, previous.bytes + elapsed * 1_048_576)
        let cost = Double(max(1, report.frames.count)), byteCost = Double(report.bodyBytes)
        guard tokens >= cost, bytes >= byteCost else { throw CollaborationStoreError.rateLimited }
        agentTranscripts.rates[tile] = .init(tokens: tokens - cost, bytes: bytes - byteCost, at: now)
        let affectedTiles = Set(victims.map { $0.split(separator: "/").prefix(2).joined(separator: "/") + "/" })
        for victim in victims { agentTranscripts.entries.removeValue(forKey: victim); wakeAgentTranscript(victim) }
        agentTranscripts.writeSequence &+= 1
        agentTranscripts.entries[key] = .init(host: report.host.rawValue.uuidString, log: next, charge: nextBytes,
                                               lastWrite: agentTranscripts.writeSequence)
        for affected in affectedTiles where !agentTranscripts.entries.keys.contains(where: { $0.hasPrefix(affected) }) {
            agentTranscripts.rates.removeValue(forKey: affected)
        }
        wakeAgentTranscript(key)
    }

    /// Any current member reads. Holds until a frame arrives when the reader is current.
    public func readAgentTranscript(token: String, area: UUID, object: UUID,
                                    request: Collaboration.AgentTranscript.ReadRequest) async throws -> Collaboration.AgentTranscript.Read {
        guard (0...Collaboration.AgentTranscript.maxWaitMilliseconds).contains(request.waitMilliseconds),
              Collaboration.AgentTranscript.validStream(request.stream) else { throw CollaborationStoreError.invalidRequest }
        let key = CollaborationAgentTranscriptTable.key(area, object, request.stream)
        var page = try agentTranscriptPage(token: token, area: area, object: object, key: key, request: request)
        guard case let .frames(_, frames, _) = page, frames.isEmpty, request.waitMilliseconds > 0 else { return page }
        guard agentTranscripts.waiters.count < CollaborationAgentTranscriptTable.maxWaiters,
              agentTranscripts.waiters.values.filter({ $0.key == key }).count < 32 else { throw CollaborationStoreError.rateLimited }
        let id = UUID(), milliseconds = request.waitMilliseconds
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(); return }
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
        let liveTiles = Set(agentTranscripts.entries.keys.map { $0.split(separator: "/").prefix(2).joined(separator: "/") + "/" })
        agentTranscripts.rates = agentTranscripts.rates.filter { liveTiles.contains($0.key) }
    }

    func forgetAgentTranscripts(area: UUID) {
        let prefix = area.uuidString + "/"
        for key in agentTranscripts.entries.keys.filter({ $0.hasPrefix(prefix) }) {
            agentTranscripts.entries.removeValue(forKey: key)
            wakeAgentTranscript(key)
        }
        agentTranscripts.rates = agentTranscripts.rates.filter { !$0.key.hasPrefix(prefix) }
    }
}
