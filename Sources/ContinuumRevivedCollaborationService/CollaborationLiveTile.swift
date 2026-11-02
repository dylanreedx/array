import Foundation
import GRDB
import ContinuumRevivedCollaborationProtocol

/// One shared tile's lane: its owner's latest state and a bounded event log.
struct CollaborationLiveTileEntry {
    var host: String
    var state: Collaboration.LiveTile.State?
    var events: [Collaboration.LiveTile.Event] = []
    var head: UInt64 = 0
    var floor: UInt64 = 0
}
struct CollaborationLiveTileWaiter {
    let key: String
    let continuation: CheckedContinuation<Void, Never>
    let timeout: Task<Void, Never>
}
/// Memory only: a relay restart drops every lane, and hosts republish on their
/// next beat. Nothing here is durable, so nothing here needs a migration.
struct CollaborationLiveTileTable {
    var entries: [String: CollaborationLiveTileEntry] = [:]
    var waiters: [UUID: CollaborationLiveTileWaiter] = [:]
    static let maxWaiters = 1024
    static func key(_ area: UUID, _ object: UUID) -> String { area.uuidString + "/" + object.uuidString }
}

extension CollaborationStore {
    /// The item, if this area still publishes it as a live tile.
    private func liveTileItem(_ db: Database, area: UUID, object: UUID) throws -> SharedArea.Item {
        let state: Data = try Data.fetchOne(db, sql: "SELECT snapshot FROM areas WHERE id=?", arguments: [area.uuidString])!
        let document = try unseal(SharedArea.Document.self, state)
        guard let item = document.items.first(where: { $0.id.rawValue == object && $0.kind == .liveTile }),
              item.source != nil else { throw CollaborationStoreError.unavailable }
        return item
    }

    /// Only the registered device that hosts this item, as its owner, writes
    /// its state. A new generation replaces the old run; within one, the
    /// revision must grow.
    public func publishLiveTileState(token: String, area: UUID, object: UUID, report: Collaboration.LiveTile.PublishState) throws {
        let encoded = try JSONEncoder().encode(report.state.payload)
        guard report.state.schema == Collaboration.LiveTile.schema, encoded.count <= Collaboration.LiveTile.maxStateBytes else {
            throw CollaborationStoreError.invalidRequest
        }
        try database.read { db in
            let identity = try authenticate(db, token), access = try scope(db, identity, area)
            guard access.epoch == report.epoch else { throw CollaborationStoreError.staleEpoch }
            guard try String.fetchOne(db, sql: "SELECT device FROM hosts WHERE id=?", arguments: [report.host.rawValue.uuidString]) == identity.device.uuidString else {
                throw CollaborationStoreError.forbidden
            }
            let item = try liveTileItem(db, area: area, object: object)
            guard item.source?.host == report.host, item.source?.owner == identity.person else { throw CollaborationStoreError.forbidden }
        }
        let key = CollaborationLiveTileTable.key(area, object)
        var entry = liveTiles.entries[key] ?? .init(host: report.host.rawValue.uuidString)
        if entry.host != report.host.rawValue.uuidString { entry = .init(host: report.host.rawValue.uuidString) }
        if let current = entry.state, current.generation == report.state.generation, current.revision >= report.state.revision {
            guard current.revision == report.state.revision else { throw SharedArea.Failure.conflict }
            return
        }
        entry.state = report.state
        liveTiles.entries[key] = entry
        wakeLiveTile(key)
    }

    /// A member's input. The owner may append any event its kind takes; anyone
    /// else only where the kind takes guest input, and never to a terminal.
    public func appendLiveTileEvent(token: String, area: UUID, object: UUID,
                                    request: Collaboration.LiveTile.AppendEvent) throws -> Collaboration.LiveTile.Appended {
        guard try JSONEncoder().encode(request.body).count <= Collaboration.LiveTile.maxEventBytes else { throw CollaborationStoreError.invalidRequest }
        let (identity, item) = try database.read { db -> (Collaboration.Identity, SharedArea.Item) in
            let identity = try authenticate(db, token), access = try scope(db, identity, area)
            guard access.allows(.discuss) else { throw CollaborationStoreError.forbidden }
            return (identity, try liveTileItem(db, area: area, object: object))
        }
        let key = CollaborationLiveTileTable.key(area, object)
        guard var entry = liveTiles.entries[key], entry.host == item.source?.host.rawValue.uuidString, let kind = entry.state?.kind else {
            // Nothing to give input to until the host has said what it is.
            throw CollaborationStoreError.unavailable
        }
        // A read-only kind refuses a teammate whatever they send.
        let owner = item.source?.owner == identity.person
        guard owner || Collaboration.LiveTile.acceptsGuestInput(kind) else { throw CollaborationStoreError.forbidden }
        guard request.body.acceptedBy == kind else { throw CollaborationStoreError.invalidRequest }
        entry.head += 1
        entry.events.append(.init(sequence: entry.head, author: identity.person, at: clock(), body: request.body))
        if entry.events.count > Collaboration.LiveTile.retainedEvents {
            let drop = entry.events.count - Collaboration.LiveTile.retainedEvents
            entry.floor = entry.events[drop - 1].sequence
            entry.events.removeFirst(drop)
        }
        liveTiles.entries[key] = entry
        wakeLiveTile(key)
        return .init(sequence: entry.head)
    }

    /// Any current member reads. Returns at once when the reader is behind on
    /// either the state or the events; otherwise holds until one moves.
    public func readLiveTile(token: String, area: UUID, object: UUID,
                             request: Collaboration.LiveTile.ReadRequest) async throws -> Collaboration.LiveTile.Read {
        guard (0...Collaboration.LiveTile.maxWaitMilliseconds).contains(request.waitMilliseconds) else { throw CollaborationStoreError.invalidRequest }
        let key = CollaborationLiveTileTable.key(area, object)
        var page = try liveTilePage(token: token, area: area, object: object, key: key, request: request)
        let current = page.state == nil && page.events.isEmpty
        guard current, request.waitMilliseconds > 0, liveTiles.waiters.count < CollaborationLiveTileTable.maxWaiters else { return page }
        let id = UUID(), milliseconds = request.waitMilliseconds
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let timer = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(milliseconds))
                    await self?.finishLiveTileWaiter(id)
                }
                liveTiles.waiters[id] = .init(key: key, continuation: continuation, timeout: timer)
            }
        } onCancel: {
            Task { await self.finishLiveTileWaiter(id) }
        }
        try Task.checkCancellation()
        page = try liveTilePage(token: token, area: area, object: object, key: key, request: request)
        return page
    }

    private func liveTilePage(token: String, area: UUID, object: UUID, key: String,
                              request: Collaboration.LiveTile.ReadRequest) throws -> Collaboration.LiveTile.Read {
        let item = try database.read { db -> SharedArea.Item in
            let identity = try authenticate(db, token), access = try scope(db, identity, area)
            guard access.allows(.view) else { throw CollaborationStoreError.forbidden }
            return try liveTileItem(db, area: area, object: object)
        }
        guard let entry = liveTiles.entries[key], entry.host == item.source?.host.rawValue.uuidString else {
            return .init(state: nil, events: [], eventHead: 0, eventFloor: 0)
        }
        let fresh = entry.state.flatMap { state in
            state.generation == request.generation && state.revision == request.revision ? nil : state
        }
        let after = request.eventsAfter ?? entry.head
        let events = Array(entry.events.lazy.filter { $0.sequence > after }.prefix(Collaboration.LiveTile.maxEventsPerRead))
        return .init(state: fresh, events: events, eventHead: entry.head, eventFloor: entry.floor)
    }

    func wakeLiveTile(_ key: String) {
        for id in liveTiles.waiters.filter({ $0.value.key == key }).map(\.key) { finishLiveTileWaiter(id) }
    }
    func finishLiveTileWaiter(_ id: UUID) {
        guard let waiter = liveTiles.waiters.removeValue(forKey: id) else { return }
        waiter.timeout.cancel()
        waiter.continuation.resume()
    }

    /// An item that left the area, or moved to another host, loses its lane.
    func refreshLiveTileAccess(area: UUID, document: SharedArea.Document) {
        let prefix = area.uuidString + "/"
        let live = Dictionary(document.items.compactMap { item in
            item.kind == .liveTile ? item.source.map { (CollaborationLiveTileTable.key(area, item.id.rawValue), $0.host.rawValue.uuidString) } : nil
        }, uniquingKeysWith: { first, _ in first })
        for key in liveTiles.entries.keys where key.hasPrefix(prefix) && live[key] != liveTiles.entries[key]?.host {
            liveTiles.entries.removeValue(forKey: key)
            wakeLiveTile(key)
        }
    }
}
