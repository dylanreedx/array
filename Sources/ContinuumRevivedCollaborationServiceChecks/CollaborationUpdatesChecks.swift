import Foundation
import GRDB
import ContinuumRevivedCollaborationProtocol
import ContinuumRevivedCollaborationClient
import ContinuumRevivedCollaborationService
import ContinuumRevivedRelayCore
import ContinuumRevivedRelayNIO

private struct UpdateFailure: Error { let message: String }
private func expect(_ value: Bool, _ message: String) throws {
    guard value else { throw UpdateFailure(message: message) }
    print("PASS updates: \(message)")
}
private final class UpdateClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_800_000_000)
    func now() -> Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
}
private func waitForReaders(_ store: CollaborationStore, _ count: Int) async throws {
    let clock = ContinuousClock(), deadline = clock.now.advanced(by: .seconds(5))
    while await store.activeUpdateRequests() != count {
        guard clock.now < deadline else { throw UpdateFailure(message: "held request count did not become \(count)") }
        try await Task.sleep(for: .milliseconds(5))
    }
}
private func denied(_ status: Int, _ action: () async throws -> Void) async throws {
    do { try await action(); throw UpdateFailure(message: "expected HTTP \(status)") }
    catch let error as CollaborationClientError {
        guard case let .server(actual, _) = error, actual == status else { throw error }
        print("PASS updates: refuses HTTP \(status)")
    }
}

func runCollaborationUpdatesChecks() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("array-collaboration-updates-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let key = Data(repeating: 53, count: 32), clock = UpdateClock()
    let path = root.appendingPathComponent("collaboration.sqlite").path
    let store = try CollaborationStore(path: path, masterKey: key, clock: { clock.now() })
    func enroll(_ name: String) async throws -> Collaboration.Credential {
        let enrollment = try await store.provisionPerson(label: name)
        return try await store.redeem(.init(code: enrollment.code, deviceLabel: name))
    }
    let a = try await enroll("A"), b = try await enroll("B"), c = try await enroll("C")
    let companion = try RelayStore(path: root.appendingPathComponent("companion.sqlite").path, masterKey: key)
    var server = RelayServer(store: companion, configuration: .init(host: "127.0.0.1", publicPort: 0, adminPort: 0), collaboration: store)
    try await server.start()
    do {
        let url = URL(string: "http://127.0.0.1:\(server.listeningPublicPort!)")!
        let apiA = try CollaborationAPI(baseURL: url, credential: a.token, allowsInsecureLoopback: true)
        let apiB = try CollaborationAPI(baseURL: url, credential: b.token, allowsInsecureLoopback: true)
        let apiC = try CollaborationAPI(baseURL: url, credential: c.token, allowsInsecureLoopback: true)
        let initial = try await apiA.createArea(), area = initial.scope.area.rawValue
        let invite = try await apiA.invite(area: area, request: .init(person: b.identity.person))
        _ = try await apiB.accept(code: invite.code)
        let item = SharedArea.Item(id: .init(), kind: .discussion)
        let position = SharedArea.Position(id: .init(), object: item.id, rect: .init(x: 0, y: 0, width: 640, height: 520))
        _ = try await apiA.apply(area: area, mutation: .init(epoch: 1, command: .init(area: initial.scope.area, expectedRevision: 0, edits: [.admit(item, position)])))
        for index in 1...600 {
            _ = try await store.apply(token: a.token, area: area, request: .init(epoch: 1, command: .init(area: initial.scope.area, expectedRevision: UInt64(index), edits: [.post(.init(id: .init(), object: item.id, author: a.identity.person, text: "Retained message \(index)"))])))
        }
        var replica = try CollaborationReplica(state: initial)
        try await replica.catchUp(using: apiB)
        try expect(replica.document.revision == 601 && replica.document.posts.count == 600, "more than 500 operations replay completely through the production client")
        let firstPage = try await apiB.updates(area: area, request: .init(after: 0, waitMilliseconds: 0))
        try expect(firstPage.events.count <= CollaborationStore.updatePageLimit && firstPage.hasMore, "catch-up page is bounded")
        let newCommand = SharedArea.Command(area: initial.scope.area, expectedRevision: 601, edits: [.post(.init(id: .init(), object: item.id, author: a.identity.person, text: "Commit during catch-up"))])
        _ = try await apiA.apply(area: area, mutation: .init(epoch: 1, command: newCommand))
        var fixed = try CollaborationReplica(state: initial)
        try fixed.receive(firstPage)
        while fixed.document.revision < firstPage.through {
            let page = try await apiB.updates(area: area, request: .init(after: fixed.document.revision, through: firstPage.through, waitMilliseconds: 0))
            try fixed.receive(page)
        }
        try expect(fixed.document.revision == 601, "concurrent commit cannot change a paged high-water mark")
        try await fixed.catchUp(using: apiB)
        try expect(fixed.document.revision == 602, "snapshot/catch-up-to-live handoff loses no concurrent commit")
        let current = try await apiB.updates(area: area, request: .init(after: 602, waitMilliseconds: 0))
        let live = Task { try await apiB.updates(area: area, request: .init(after: 602, presenceVersion: current.presenceVersion)) }
        try await waitForReaders(store, 1)
        let command = SharedArea.Command(area: initial.scope.area, expectedRevision: 602, edits: [.post(.init(id: .init(), object: item.id, author: a.identity.person, text: "Live commit"))])
        _ = try await apiA.apply(area: area, mutation: .init(epoch: 1, command: command))
        let delivered = try await live.value
        try expect(delivered.events.count == 1 && delivered.nextCursor == 603, "held HTTP subscription wakes on a committed operation")
        try await denied(404) { _ = try await apiC.updates(area: area, request: .init(after: 0, waitMilliseconds: 0)) }
        try await denied(409) { _ = try await apiB.updates(area: area, request: .init(after: 9999, waitMilliseconds: 0)) }

        let before = try await apiB.state(area: area)
        let session = try await apiB.beginPresence(area: area)
        try await apiB.publishPresence(area: area, value: .init(session: session.id, sequence: 1, cursor: .init(x: 100, y: 200)))
        let cursor = try await apiA.updates(area: area, request: .init(after: 603, waitMilliseconds: 0))
        try expect(cursor.presence.first?.identity == b.identity && cursor.presence.first?.cursor == .init(x: 100, y: 200), "cursor identity comes from authentication")
        for sequence in 2...30 {
            try await store.publishPresence(token: b.token, area: area, input: .init(session: session.id, sequence: UInt64(sequence), cursor: .init(x: Double(sequence), y: 300)))
        }
        let coalesced = try await apiA.updates(area: area, request: .init(after: 603, presenceVersion: cursor.presenceVersion))
        try expect(coalesced.presence.first?.cursor?.x == 30, "presence burst retains its final cursor")
        try await apiB.publishPresence(area: area, value: .init(session: session.id, sequence: 2, cursor: .init(x: -1, y: -1)))
        let ordered = try await apiA.updates(area: area, request: .init(after: 603, waitMilliseconds: 0))
        try expect(ordered.presence.first?.cursor?.x == 30, "late presence packets cannot move cursor backward")
        let after = try await apiB.state(area: area)
        try expect(try before.document.canonicalData() == after.document.canonicalData(), "presence produces zero durable document mutations")
        clock.advance(16)
        let expired = try await apiA.updates(area: area, request: .init(after: 603, waitMilliseconds: 0))
        try expect(expired.presence.isEmpty && expired.presenceVersion != ordered.presenceVersion, "presence expires independently of document/host state")
        let newSession = try await apiB.beginPresence(area: area)
        try await denied(400) { try await apiB.publishPresence(area: area, value: .init(session: session.id, sequence: 31, cursor: .init(x: 0, y: 0))) }
        try await apiB.publishPresence(area: area, value: .init(session: newSession.id, sequence: 1, cursor: .init(x: 55, y: 66)))
        let preRemoval = try await apiB.updates(area: area, request: .init(after: 603, waitMilliseconds: 0))
        let removedReader = Task { try await apiB.updates(area: area, request: .init(after: 603, presenceVersion: preRemoval.presenceVersion)) }
        try await waitForReaders(store, 1)
        try await apiA.removeMember(area: area, person: b.identity.person.rawValue, epoch: 1)
        try await denied(404) { _ = try await removedReader.value }
        try await waitForReaders(store, 0)
        let revoked = try await apiA.updates(area: area, request: .init(after: 603, waitMilliseconds: 0))
        try expect(revoked.presence.isEmpty && revoked.scope.epoch == 2, "active removal purges presence and updates membership epoch")

        let waiter1 = Task { try await apiA.updates(area: area, request: .init(after: 603, presenceVersion: revoked.presenceVersion)) }
        let waiter2 = Task { try await apiA.updates(area: area, request: .init(after: 603, presenceVersion: revoked.presenceVersion)) }
        try await waitForReaders(store, 2)
        try await denied(429) { _ = try await apiA.updates(area: area, request: .init(after: 603, presenceVersion: revoked.presenceVersion)) }
        waiter1.cancel(); waiter2.cancel()
        _ = try? await waiter1.value; _ = try? await waiter2.value
        try await waitForReaders(store, 0)
        print("PASS updates: cancellation releases held requests without waiting for timeout")
        var malformed = fixed
        let bad = Collaboration.Updates(scope: revoked.scope, after: 602, through: 604,
            events: [.init(revision: 604, actor: a.identity, command: command)], nextCursor: 604,
            presenceVersion: UUID(), presence: [], serverTime: clock.now())
        do { try malformed.receive(bad); throw UpdateFailure(message: "out-of-order event accepted") }
        catch CollaborationClientError.invalidSequence { print("PASS updates: replica refuses a sequence gap") }
        try expect(try malformed.document.canonicalData() == fixed.document.canonicalData(), "malformed page cannot partially mutate the replica")
        let sessionClient = try CollaborationSession(api: apiA, area: area)
        let statusStream = await sessionClient.start()
        let observer = Task { for await _ in statusStream {} }
        try await waitForReaders(store, 1)
        let sessionCommand = SharedArea.Command(area: initial.scope.area, expectedRevision: 603,
            edits: [.post(.init(id: .init(), object: item.id, author: a.identity.person, text: "Session-owned update"))])
        _ = try await apiA.apply(area: area, mutation: .init(epoch: 2, command: sessionCommand))
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while true {
            if case let .connected(replica) = await sessionClient.status, replica.document.revision == 604 { break }
            guard ContinuousClock.now < deadline else { throw UpdateFailure(message: "automatic session did not receive commit") }
            try await Task.sleep(for: .milliseconds(5))
        }
        print("PASS updates: native-facing session owns snapshot-to-live updates")
        await sessionClient.stop()
        _ = await observer.value
        try await waitForReaders(store, 0)
        print("PASS updates: session close cancels its live request")

        let byteArea = try await apiA.createArea(), byteID = byteArea.scope.area.rawValue
        let byteItem = SharedArea.Item(id: .init(), kind: .discussion)
        _ = try await apiA.apply(area: byteID, mutation: .init(epoch: 1, command: .init(area: byteArea.scope.area, expectedRevision: 0,
            edits: [.admit(byteItem, .init(id: .init(), object: byteItem.id, rect: position.rect))])))
        for index in 1...9 {
            _ = try await apiA.apply(area: byteID, mutation: .init(epoch: 1, command: .init(area: byteArea.scope.area, expectedRevision: UInt64(index),
                edits: [.post(.init(id: .init(), object: byteItem.id, author: a.identity.person, text: String(repeating: "x", count: 80_000)))])))
        }
        let bytePage = try await apiA.updates(area: byteID, request: .init(after: 0, waitMilliseconds: 0))
        try expect(bytePage.hasMore && bytePage.events.count < 10 && (try JSONEncoder().encode(bytePage.events).count) < CollaborationStore.updatePageBytes + 128,
            "large operations page by bytes before hitting the event count limit")
        var byteReplica = try CollaborationReplica(state: byteArea)
        try await byteReplica.catchUp(using: apiA)
        try expect(byteReplica.document.posts.count == 9, "byte-bounded replay loses no large operation")

        let reconnectClient = try CollaborationSession(api: apiA, area: area)
        let reconnectStream = await reconnectClient.start()
        let reconnectObserver = Task { for await _ in reconnectStream {} }
        try await waitForReaders(store, 1)
        let port = server.listeningPublicPort!
        try await server.stop()
        let reconnectDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while true {
            if case let .reconnecting(replica) = await reconnectClient.status {
                try expect(replica?.document.revision == 604, "network interruption preserves last accepted revision")
                break
            }
            guard ContinuousClock.now < reconnectDeadline else { throw UpdateFailure(message: "session did not observe network interruption") }
            try await Task.sleep(for: .milliseconds(5))
        }
        let resumedStore = try CollaborationStore(path: path, masterKey: key, clock: { clock.now() })
        _ = try await resumedStore.apply(token: a.token, area: area, request: .init(epoch: 2,
            command: .init(area: initial.scope.area, expectedRevision: 604, edits: [.post(.init(id: .init(), object: item.id, author: a.identity.person, text: "While disconnected"))])))
        server = RelayServer(store: companion, configuration: .init(host: "127.0.0.1", publicPort: port, adminPort: 0), collaboration: resumedStore)
        try await server.start()
        let resumeDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while true {
            if case let .connected(replica) = await reconnectClient.status, replica.document.revision == 605 { break }
            guard ContinuousClock.now < resumeDeadline else { throw UpdateFailure(message: "session did not reconnect to reconstructed service") }
            try await Task.sleep(for: .milliseconds(5))
        }
        await reconnectClient.stop(); _ = await reconnectObserver.value
        try await waitForReaders(resumedStore, 0)
        print("PASS updates: automatic reconnect resumes missed commits after service reconstruction")

        let deviceSession = try CollaborationSession(api: apiA, area: area)
        let deviceStream = await deviceSession.start()
        let deviceObserver = Task { for await _ in deviceStream {} }
        try await waitForReaders(resumedStore, 1)
        try await resumedStore.revokeDevice(token: a.token, device: a.identity.device)
        let revokeDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while true {
            if case .unavailable = await deviceSession.status { break }
            guard ContinuousClock.now < revokeDeadline else { throw UpdateFailure(message: "revoked session kept serving data") }
            try await Task.sleep(for: .milliseconds(5))
        }
        _ = await deviceObserver.value
        await deviceSession.stop()
        try await waitForReaders(resumedStore, 0)
        print("PASS updates: device revocation ends the native-facing session")
        try await server.stop()
    } catch { try? await server.stop(); throw error }
    let migrationDB = try DatabaseQueue(path: path)
    try await migrationDB.write { db in
        try db.execute(sql: "DROP TABLE collaboration_key_marker")
        try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier='collaboration-v3-database-key'")
        try db.execute(sql: "ALTER TABLE areas DROP COLUMN revision")
        try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier='collaboration-v2-head-revision'")
    }
    do {
        _ = try CollaborationStore(path: path, masterKey: Data(repeating: 0, count: 32))
        throw UpdateFailure(message: "wrong key migration accepted")
    } catch is UpdateFailure { throw UpdateFailure(message: "wrong key migration accepted") }
      catch { print("PASS updates: wrong-key migration refuses") }
    let hasRevision = try await migrationDB.read { db in try Row.fetchAll(db, sql: "PRAGMA table_info(areas)").contains { ($0["name"] as String) == "revision" } }
    try expect(!hasRevision, "failed head migration rolls back its schema change")
    let migrated = try CollaborationStore(path: path, masterKey: key, clock: { clock.now() })
    // B still has an active credential, and its separate memberships are unchanged.
    let migratedIdentity = try await migrated.identity(token: b.token)
    try expect(migratedIdentity == b.identity, "head migration preserves identity records")
    let migratedHeads = try await migrationDB.read { db in try Int64.fetchAll(db, sql: "SELECT revision FROM areas ORDER BY revision") }
    try expect(migratedHeads == [10, 605], "v1 encrypted snapshots backfill exact durable heads")
    print("Collaboration updates checks passed: paged catch-up, live wakeup, coalesced expiring presence, active revocation and cancellation through real HTTP/client.")
}
