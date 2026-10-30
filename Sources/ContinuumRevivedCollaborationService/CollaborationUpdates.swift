import Foundation
import GRDB
import ContinuumRevivedCollaborationProtocol

struct CollaborationPresenceKey: Hashable { let area: UUID; let device: UUID }
struct CollaborationPresenceEntry {
    let identity: Collaboration.Identity
    let session: UUID
    var sequence: UInt64?
    var lastPublished: Date?
    var value: Collaboration.Presence?
}
struct CollaborationCancelledUpdate { let area: UUID; let device: UUID; let until: Date }
struct CollaborationUpdateWaiter {
    let area: UUID
    let device: UUID
    let continuation: CheckedContinuation<Void, any Error>
    let timeout: Task<Void, Never>
}

extension CollaborationStore {
    public static let updatePageLimit = 128
    public static let updatePageBytes = 524_288
    /// Native scene, source host, capture review and one replacing view.
    public static let updateDeviceLimit = 4
    public static let updateGlobalLimit = 1024
    public static let presenceLifetime: TimeInterval = 15

    /// A subscription is one bounded, cancellable held HTTP request. No payload
    /// queue: commits wake readers, which reauthenticate and read their cursor.
    public func updates(token: String, area: UUID, request: Collaboration.UpdateRequest) async throws -> Collaboration.Updates {
        guard (0...25_000).contains(request.waitMilliseconds) else { throw CollaborationStoreError.invalidRequest }
        var page = try readUpdates(token: token, area: area, request: request)
        if request.through != nil || request.waitMilliseconds == 0 || page.hasMore || !page.events.isEmpty || page.presenceVersion != request.presenceVersion {
            return page
        }
        let identity = try identity(token: token)
        guard updateWaiters.values.filter({ $0.device == identity.device && $0.area == area }).count < Self.updateDeviceLimit,
              updateWaiters.count < Self.updateGlobalLimit else { throw CollaborationStoreError.tooManySubscriptions }
        // Wake at the earliest visible presence expiry, even without new traffic.
        let expiry = page.presence.map(\.expiresAt).min()?.timeIntervalSince(clock()) ?? 25
        let milliseconds = min(request.waitMilliseconds, max(1, Int(ceil(expiry * 1000))))
        let id = request.subscriptionID
        cancelledUpdateRequests = cancelledUpdateRequests.filter { $0.value.until > clock() }
        if let cancelled = cancelledUpdateRequests[id], cancelled.area == area, cancelled.device == identity.device { throw CancellationError() }
        guard updateWaiters[id] == nil else { throw CollaborationStoreError.tooManySubscriptions }
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                let timer = Task { [weak self] in
                    do { try await Task.sleep(for: .milliseconds(milliseconds)) } catch { return }
                    await self?.finishWaiter(id)
                }
                updateWaiters[id] = .init(area: area, device: identity.device, continuation: continuation, timeout: timer)
            }
        } onCancel: {
            Task { await self.finishWaiter(id, cancelled: true) }
        }
        try Task.checkCancellation()
        page = try readUpdates(token: token, area: area, request: request)
        return page
    }

    public func cancelUpdates(token: String, area: UUID, subscription: UUID) throws {
        let identity = try identity(token: token)
        try database.read { db in _ = try scope(db, identity, area) }
        cancelledUpdateRequests = cancelledUpdateRequests.filter { $0.value.until > clock() }
        if let waiter = updateWaiters[subscription] {
            guard waiter.area == area, waiter.device == identity.device else { throw CollaborationStoreError.unavailable }
            finishWaiter(subscription, cancelled: true)
        }
        guard cancelledUpdateRequests.count < 4096 else { throw CollaborationStoreError.tooManySubscriptions }
        // A cancellation may reach the server before its original held request.
        cancelledUpdateRequests[subscription] = .init(area: area, device: identity.device, until: clock().addingTimeInterval(30))
    }

    private func readUpdates(token: String, area: UUID, request: Collaboration.UpdateRequest) throws -> Collaboration.Updates {
        sweepPresence()
        return try database.read { db in
            let identity = try authenticate(db, token), scope = try scope(db, identity, area)
            let head = UInt64(try Int64.fetchOne(db, sql: "SELECT revision FROM areas WHERE id=?", arguments: [area.uuidString])!)
            let through = request.through ?? head
            guard request.after <= through, through <= head, request.after <= UInt64(Int64.max) else { throw CollaborationStoreError.invalidCursor }
            var events: [Collaboration.Event] = []
            var bytes = 0
            let rows = try Row.fetchCursor(db, sql: "SELECT o.revision,o.command,d.person,d.id FROM operations o JOIN devices d ON d.id=o.actor WHERE o.area=? AND o.revision>? AND o.revision<=? ORDER BY o.revision LIMIT ?",
                arguments: [area.uuidString, Int64(request.after), Int64(through), Self.updatePageLimit])
            let encoder = JSONEncoder()
            while let row = try rows.next() {
                let command = try unseal(SharedArea.Command.self, row["command"])
                let actor = Collaboration.Identity(person: .init(UUID(uuidString: row["person"])!), device: UUID(uuidString: row["id"])!)
                let event = Collaboration.Event(revision: UInt64(row["revision"] as Int64), actor: actor, command: command)
                let size = try encoder.encode(event).count
                if !events.isEmpty, bytes + size > Self.updatePageBytes { break }
                guard size <= Self.updatePageBytes else { throw CollaborationStoreError.invalidRequest }
                guard event.revision == (events.last?.revision ?? request.after) + 1 else { throw CollaborationStoreError.invalidCursor }
                events.append(event); bytes += size
            }
            let next = events.last?.revision ?? request.after
            guard next == through || !events.isEmpty else { throw CollaborationStoreError.invalidCursor }
            let presence = try presenceEntries.filter { $0.key.area == area }.values.compactMap(\.value)
                .sorted { $0.identity.device.uuidString < $1.identity.device.uuidString }
                .map { value in
                    Collaboration.Presence(identity: value.identity, cursor: value.cursor, viewport: value.viewport,
                        expiresAt: value.expiresAt, label: value.label,
                        usage: try usageForPresence(db, area: area, identity: value.identity))
                }
            let version = presenceVersions[area] ?? UUID()
            presenceVersions[area] = version
            return .init(scope: scope, after: request.after, through: through, events: events, nextCursor: next,
                presenceVersion: version, presence: presence, serverTime: clock())
        }
    }

    public func beginPresence(token: String, area: UUID) throws -> Collaboration.PresenceSession {
        sweepPresence()
        return try database.read { db in
            let identity = try authenticate(db, token)
            _ = try scope(db, identity, area)
            let id = UUID(), key = CollaborationPresenceKey(area: area, device: identity.device)
            let hadValue = presenceEntries[key]?.value != nil
            presenceFlushes.removeValue(forKey: key)?.cancel()
            presenceEntries[key] = .init(identity: identity, session: id)
            if hadValue { presenceChanged(area) }
            return .init(id: id)
        }
    }
    public func publishPresence(token: String, area: UUID, input: Collaboration.PresenceInput) throws {
        guard input.cursor?.valid != false, input.viewport?.valid != false else { throw CollaborationStoreError.invalidRequest }
        try database.read { db in
            let identity = try authenticate(db, token)
            _ = try scope(db, identity, area)
            let key = CollaborationPresenceKey(area: area, device: identity.device)
            guard var entry = presenceEntries[key], entry.session == input.session else { throw CollaborationStoreError.invalidRequest }
            if let sequence = entry.sequence, input.sequence <= sequence { return }
            let now = clock()
            // Keep the latest observation and bound fanout to 20 updates/sec.
            entry.sequence = input.sequence
            entry.value = .init(identity: identity, cursor: input.cursor, viewport: input.viewport,
                expiresAt: now.addingTimeInterval(Self.presenceLifetime),
                label: try String.fetchOne(db, sql: "SELECT label FROM people WHERE id=?", arguments: [identity.person.rawValue.uuidString]))
            if let last = entry.lastPublished, now.timeIntervalSince(last) < 0.05 {
                presenceEntries[key] = entry
                if presenceFlushes[key] == nil {
                    let delay = max(1, Int(ceil((0.05 - now.timeIntervalSince(last)) * 1000)))
                    presenceFlushes[key] = Task { [weak self] in
                        do { try await Task.sleep(for: .milliseconds(delay)) } catch { return }
                        await self?.flushPresence(key, session: input.session)
                    }
                }
            } else {
                presenceFlushes.removeValue(forKey: key)?.cancel()
                entry.lastPublished = now
                presenceEntries[key] = entry
                presenceChanged(area)
            }
        }
    }
    public func endPresence(token: String, area: UUID, session: UUID) throws {
        try database.read { db in
            let identity = try authenticate(db, token)
            _ = try scope(db, identity, area)
            let key = CollaborationPresenceKey(area: area, device: identity.device)
            if presenceEntries[key]?.session == session {
                presenceFlushes.removeValue(forKey: key)?.cancel()
                presenceEntries.removeValue(forKey: key)
                presenceChanged(area)
            }
        }
    }

    /// Count-only diagnostics for deterministic held-request/cancellation checks.
    public func activeUpdateRequests() -> Int { updateWaiters.count }

    func wakeArea(_ area: UUID) {
        for id in updateWaiters.filter({ $0.value.area == area }).map(\.key) { finishWaiter(id) }
    }
    func finishWaiter(_ id: UUID, cancelled: Bool = false) {
        guard let waiter = updateWaiters.removeValue(forKey: id) else { return }
        waiter.timeout.cancel()
        if cancelled { waiter.continuation.resume(throwing: CancellationError()) }
        else { waiter.continuation.resume() }
    }
    func invalidateDevice(_ device: UUID) {
        for id in updateWaiters.filter({ $0.value.device == device }).map(\.key) { finishWaiter(id) }
        for key in presenceEntries.keys.filter({ $0.device == device }) {
            presenceFlushes.removeValue(forKey: key)?.cancel()
            presenceEntries.removeValue(forKey: key)
            presenceChanged(key.area)
        }
    }
    func invalidateMember(area: UUID, person: UUID) {
        for key in presenceEntries.filter({ $0.key.area == area && $0.value.identity.person.rawValue == person }).map(\.key) {
            presenceFlushes.removeValue(forKey: key)?.cancel()
            presenceEntries.removeValue(forKey: key)
        }
        presenceChanged(area)
    }
    private func flushPresence(_ key: CollaborationPresenceKey, session: UUID) {
        presenceFlushes.removeValue(forKey: key)
        guard var entry = presenceEntries[key], entry.session == session else { return }
        entry.lastPublished = clock()
        presenceEntries[key] = entry
        presenceChanged(key.area)
    }
    func presenceChanged(_ area: UUID) { presenceVersions[area] = UUID(); wakeArea(area) }
    private func sweepPresence() {
        let now = clock()
        for key in Array(presenceEntries.keys) {
            guard var entry = presenceEntries[key] else { continue }
            if let value = entry.value, value.expiresAt <= now {
                entry.value = nil
                presenceEntries[key] = entry
                presenceChanged(key.area)
            }
        }
    }
}
