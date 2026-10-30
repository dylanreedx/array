import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import GRDB
import ContinuumRevivedCollaborationProtocol
import ContinuumRevivedCollaborationClient
import ContinuumRevivedCollaborationService
import ContinuumRevivedRelayCore
import ContinuumRevivedRelayNIO

private struct RetentionFailure: Error { let message: String }
private func retentionExpect(_ value: Bool, _ message: String) throws {
    guard value else { throw RetentionFailure(message: message) }
    print("PASS retention: \(message)")
}
private func refusal(_ status: Int, _ code: String, _ label: String, _ body: () async throws -> Void) async throws {
    do { try await body() }
    catch CollaborationClientError.server(let actual, let actualCode) {
        try retentionExpect(actual == status && actualCode == code, "\(label) (\(actual) \(actualCode))")
        return
    }
    throw RetentionFailure(message: "\(label): expected \(status) \(code), request succeeded")
}
private actor BurstLedger {
    private(set) var commands: [SharedArea.Command] = []
    func accept(_ command: SharedArea.Command) { commands.append(command) }
}
private final class RetentionClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_900_000_000)
    func now() -> Date { lock.withLock { date } }
    func advance(_ seconds: TimeInterval) { lock.withLock { date = date.addingTimeInterval(seconds) } }
}

/// COL-19: compaction folds the old log into an encrypted horizon snapshot while
/// tombstones, receipts and membership survive; behind-horizon cursors take an
/// explicit snapshot; the database restores into replacement directories, both
/// from an online backup and from a cold copy after SIGKILL. Real HTTP only.
func runCollaborationRetentionChecks() async throws {
    let root = URL(fileURLWithPath: FileManager.default.temporaryDirectory.path).resolvingSymlinksInPath()
        .appendingPathComponent("array-collaboration-retention-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let key = Data(repeating: 83, count: 32), clock = RetentionClock()
    let path = root.appendingPathComponent("collaboration.sqlite").path
    let retention = CollaborationRetention(operationTail: 8, operationAge: 60, compactionBatch: 16, dispatchAuthorityWindow: 300)
    let store = try CollaborationStore(path: path, masterKey: key, clock: { clock.now() }, retention: retention)
    let companion = try RelayStore(path: root.appendingPathComponent("companion.sqlite").path, masterKey: key)
    let server = RelayServer(store: companion, configuration: .init(host: "127.0.0.1", publicPort: 0, adminPort: 0), collaboration: store)
    try await server.start()
    var serverRunning = true
    var relays: [RelayProcess] = []
    defer { for relay in relays { relay.kill() } }
    do {
        let base = URL(string: "http://127.0.0.1:\(server.listeningPublicPort!)")!
        func api(_ token: String?, _ url: URL = base) throws -> CollaborationAPI {
            try CollaborationAPI(baseURL: url, credential: token, allowsInsecureLoopback: true)
        }
        func person(_ label: String) async throws -> Collaboration.Credential {
            let enrollment = try await store.provisionPerson(label: label)
            return try await api(nil).redeem(code: enrollment.code, deviceLabel: label)
        }
        let a = try await person("Retention A"), b = try await person("Retention B"), c = try await person("Retention C")
        let a2Enrollment = try await store.enrollDevice(token: a.token, lifetime: 600)
        let a2 = try await api(nil).redeem(code: a2Enrollment.code, deviceLabel: "Retention A second device")
        let apiA = try api(a.token), apiB = try api(b.token), apiC = try api(c.token), apiA2 = try api(a2.token)
        let created = try await apiA.createArea(), area = created.scope.area, areaID = area.rawValue
        _ = try await apiB.accept(code: try await apiA.invite(area: areaID, request: .init(person: b.identity.person)).code)
        _ = try await apiC.accept(code: try await apiA.invite(area: areaID, request: .init(person: c.identity.person)).code)

        let thread = SharedArea.Item(id: .init(), kind: .discussion), artifact = SharedArea.Item(id: .init(), kind: .artifact)
        let threadPlacement = SharedArea.ID<SharedArea.Placement>()
        let artifactAdmit = SharedArea.Edit.admit(artifact, .init(id: .init(), object: artifact.id, rect: .init(x: 700, y: 0, width: 200, height: 120)))
        _ = try await apiA.apply(area: areaID, mutation: .init(epoch: 1, command: .init(area: area, expectedRevision: 0, edits: [
            .admit(thread, .init(id: threadPlacement, object: thread.id, rect: .init(x: 0, y: 0, width: 640, height: 520))), artifactAdmit
        ])))
        let early = try await apiB.state(area: areaID)
        var full = try CollaborationReplica(state: early)
        // An operation ID with no author field, so another member could submit
        // the identical bytes: only the retained actor binding refuses it.
        let placeCommand = SharedArea.Command(area: area, expectedRevision: 1,
            edits: [.place(.init(id: threadPlacement, object: thread.id, rect: .init(x: 40, y: 20, width: 640, height: 520)))])
        let placed = try await apiA.apply(area: areaID, mutation: .init(epoch: 1, command: placeCommand))
        _ = try await apiA.apply(area: areaID, mutation: .init(epoch: 1, command: .init(area: area, expectedRevision: 2, edits: [.remove(artifact.id)])))
        try await apiA.removeMember(area: areaID, person: c.identity.person.rawValue, epoch: 1)
        try await store.revokeDevice(token: a.token, device: a2.identity.device)

        var head: UInt64 = 3
        func postNext(_ text: String, by credential: Collaboration.Credential? = nil) async throws -> Collaboration.Receipt {
            let author = credential ?? (head % 2 == 0 ? a : b)
            let command = SharedArea.Command(area: area, expectedRevision: head,
                edits: [.post(.init(id: .init(), object: thread.id, author: author.identity.person, text: text))])
            let receipt = try await api(author.token).apply(area: areaID, mutation: .init(epoch: 2, command: command))
            head = receipt.revision
            return receipt
        }
        for index in 1...520 { _ = try await postNext("Retained \(index)") }
        try retentionExpect(try await store.verifyIntegrity().horizons[areaID] == 0,
            "operations younger than the retention age are never compacted, however many accumulate")
        try await full.catchUp(using: apiB)
        try retentionExpect(full.document.revision == head && head > 500, "full-replay client pages through \(head) operations before compaction")

        // Age the log past the window; the next commit folds everything but the tail.
        clock.advance(120)
        _ = try await postNext("First aged commit")
        let folded = try await store.verifyIntegrity()
        try retentionExpect(folded.horizons[areaID] == head - 8 && folded.retainedOperations == 8 && folded.receipts == Int(head),
            "compaction folds \(head - 8) operations into a horizon snapshot, keeps an 8-operation tail and one receipt per revision")
        let failures = await store.compactionFailures
        try retentionExpect(failures == 0, "compaction ran without a maintenance failure")
        try await full.catchUp(using: apiB)

        // An ancient cursor is refused explicitly, never served as an empty page.
        try await refusal(409, "snapshotRequired", "a cursor behind the horizon is told to take the snapshot") {
            _ = try await apiB.updates(area: areaID, request: .init(after: early.document.revision, waitMilliseconds: 0))
        }
        let edge = try await apiB.updates(area: areaID, request: .init(after: head - 8, waitMilliseconds: 0))
        try retentionExpect(edge.events.count == 8 && edge.nextCursor == head, "a cursor at the horizon still replays the retained tail")
        let ancient = try CollaborationSession(api: apiB, area: areaID, initial: early)
        let log = StatusLog(), stream = await ancient.start()
        let observer = Task { for await status in stream { await log.record(status) } }
        try await eventually("ancient client recovers") {
            if case .connected(let replica) = await ancient.status { return replica.document.revision == head }
            return false
        }
        guard case .connected(let recovered) = await ancient.status else { throw RetentionFailure(message: "ancient session lost") }
        await ancient.stop(); _ = await observer.value
        let authoritative = try await apiA.state(area: areaID).document.canonicalData()
        try retentionExpect(try recovered.document.canonicalData() == authoritative && full.document.canonicalData() == authoritative,
            "post-compaction snapshot client ends byte-equal to the client that replayed every operation")
        let connectedRevisions = await log.entries.filter { $0.kind == .connected }.map(\.revision)
        try retentionExpect(!connectedRevisions.isEmpty && connectedRevisions.allSatisfy { $0 == head },
            "the ancient client never presents its stale revision as connected shared state")
        try retentionExpect(!recovered.document.items.contains { $0.id == artifact.id } && recovered.document.posts.count == Int(head) - 3,
            "the deleted artifact stays deleted and every retained discussion post is present")

        // Tombstones, receipts and membership all predate the horizon.
        try await refusal(400, "invalidCommand", "a stale client cannot resurrect an object deleted before the horizon") {
            _ = try await apiA.apply(area: areaID, mutation: .init(epoch: 2, command: .init(area: area, expectedRevision: head, edits: [artifactAdmit])))
        }
        let retried = try await apiA.apply(area: areaID, mutation: .init(epoch: 2, command: placeCommand))
        try retentionExpect(retried.duplicate && retried.revision == placed.revision,
            "a retry of a compacted operation returns its original receipt (revision \(placed.revision)), not a second effect")
        try await refusal(409, "changedIntent", "another person cannot claim a compacted operation ID with identical bytes") {
            _ = try await apiB.apply(area: areaID, mutation: .init(epoch: 2, command: placeCommand))
        }
        try await refusal(404, "notFound", "a member removed before compaction stays removed") { _ = try await apiC.state(area: areaID) }
        try await refusal(401, "unauthorized", "a device revoked before compaction stays revoked") { _ = try await apiA2.state(area: areaID) }
        try await refusal(409, "staleEpoch", "the pre-removal membership epoch stays stale after compaction") {
            _ = try await apiA.apply(area: areaID, mutation: .init(epoch: 1, command: .init(area: area, expectedRevision: head,
                edits: [.post(.init(id: .init(), object: thread.id, author: a.identity.person, text: "old epoch"))])))
        }
        try await refusal(400, "invalidCommand", "an unsupported command schema is refused") {
            _ = try await apiA.apply(area: areaID, mutation: .init(epoch: 2, command: .init(schema: 2, area: area, expectedRevision: head,
                edits: [.post(.init(id: .init(), object: thread.id, author: a.identity.person, text: "future schema"))])))
        }
        try retentionExpect(try await apiA.state(area: areaID).document.canonicalData() == authoritative,
            "refused stale, foreign, old-epoch and unsupported requests leave the document unchanged")

        // Crash inside compaction: the snapshot and the retirement roll back together.
        let horizonBefore = head - 8
        let probe = try DatabaseQueue(path: path)
        func horizonRow() async throws -> (Int64, Data?) {
            try await probe.read { db in
                let row = try Row.fetchOne(db, sql: "SELECT horizon,horizon_snapshot FROM areas WHERE id=?", arguments: [areaID.uuidString])!
                return (row["horizon"], row["horizon_snapshot"])
            }
        }
        let sealedBefore = try await horizonRow()
        try await probe.write { try $0.execute(sql: "CREATE TRIGGER reject_compaction BEFORE DELETE ON operations BEGIN SELECT RAISE(ABORT,'injected compaction fault'); END") }
        for index in 1...16 { _ = try await postNext("Before fault \(index)") }
        clock.advance(120)
        let committed = try await postNext("Commit during compaction fault")
        let afterFault = try await horizonRow()
        let faultFailures = await store.compactionFailures
        try retentionExpect(!committed.duplicate && faultFailures == 1 && afterFault.0 == sealedBefore.0 && afterFault.1 == sealedBefore.1
                && UInt64(afterFault.0) == horizonBefore,
            "a fault inside compaction keeps the committed command and rolls back the snapshot and horizon together")
        _ = try await store.verifyIntegrity()
        try await probe.write { try $0.execute(sql: "DROP TRIGGER reject_compaction") }
        try await full.catchUp(using: apiB)
        _ = try await postNext("Commit after fault")
        let resumed = try await store.verifyIntegrity()
        try retentionExpect((resumed.horizons[areaID] ?? 0) > horizonBefore && resumed.receipts == Int(head),
            "the next commit compacts the deferred range and the log still reconstructs the head")
        try await full.catchUp(using: apiB)
        let sourceState = try await apiA.state(area: areaID)
        try retentionExpect(try full.document.canonicalData() == sourceState.document.canonicalData(),
            "the live full-replay client stays byte-equal across compaction")

        // Restore 1: an online backup while the service is serving.
        let replacement = root.appendingPathComponent("replacement-online", isDirectory: true)
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: true)
        let restoredPath = replacement.appendingPathComponent("collaboration.sqlite").path
        // The one backup path: the verified operator backup (CollaborationBackup.swift).
        _ = try await CollaborationStore.backup(databaseAt: path, to: restoredPath, masterKey: key)
        let keyFile = replacement.appendingPathComponent("collaboration.key")
        try key.base64EncodedString().write(to: keyFile, atomically: true, encoding: .utf8)
        try await server.stop(); serverRunning = false
        let carriedKey = Data(base64Encoded: try String(contentsOf: keyFile, encoding: .utf8))!
        let restored = try await verifyRestored(
            label: "online backup", directory: replacement, path: restoredPath, key: carriedKey, area: area, head: head,
            expected: sourceState.document, horizon: resumed.horizons[areaID]!, early: early.document.revision,
            a: a, b: b, c: c, a2: a2, placeCommand: placeCommand, placedRevision: placed.revision, artifactAdmit: artifactAdmit)
        relays.append(restored)

        // Restore 2: SIGKILL the restored relay during a write burst, cold-copy
        // its files to a second replacement and serve them again.
        let restoredA = try api(a.token, restored.base)
        let ledger = BurstLedger(), start = head
        let burst = Task {
            var current = start
            for index in 1...2_000 {
                let command = SharedArea.Command(area: area, expectedRevision: current,
                    edits: [.post(.init(id: .init(), object: thread.id, author: a.identity.person, text: "Burst \(index)"))])
                guard let receipt = try? await restoredA.apply(area: areaID, mutation: .init(epoch: 2, command: command)) else { return }
                await ledger.accept(command); current = receipt.revision
            }
        }
        try await eventually("burst under way") { await ledger.commands.count >= 20 }
        restored.kill()
        await burst.value
        let acknowledged = await ledger.commands
        try retentionExpect(!acknowledged.isEmpty && acknowledged.count < 2_000, "SIGKILL lands inside a burst after \(acknowledged.count) acknowledged commits")
        let cold = root.appendingPathComponent("replacement-cold", isDirectory: true)
        try FileManager.default.createDirectory(at: cold, withIntermediateDirectories: true)
        for file in try FileManager.default.contentsOfDirectory(atPath: replacement.path) where file.hasPrefix("collaboration.") {
            try FileManager.default.copyItem(atPath: replacement.appendingPathComponent(file).path, toPath: cold.appendingPathComponent(file).path)
        }
        let coldKey = Data(base64Encoded: try String(contentsOf: cold.appendingPathComponent("collaboration.key"), encoding: .utf8))!
        let coldStore = try CollaborationStore(path: cold.appendingPathComponent("collaboration.sqlite").path, masterKey: coldKey)
        let coldReport = try await coldStore.verifyIntegrity()
        let coldState = try await coldStore.state(token: a.token, area: areaID)
        let acknowledgedPosts = Set(acknowledged.flatMap { $0.edits.compactMap { edit -> SharedArea.ID<SharedArea.Message>? in
            if case .post(let post) = edit { return post.id }; return nil } })
        let coldPosts = Set(coldState.document.posts.map(\.id))
        try retentionExpect(acknowledgedPosts.isSubset(of: coldPosts) && coldState.document.revision >= head + UInt64(acknowledged.count)
                && coldReport.receipts == Int(coldState.document.revision),
            "a cold copy after SIGKILL keeps every acknowledged commit and reconstructs its head from horizon plus tail")
        let coldRelay = try await verifyRestored(
            label: "cold copy after SIGKILL", directory: cold, path: cold.appendingPathComponent("collaboration.sqlite").path, key: coldKey,
            area: area, head: coldState.document.revision, expected: coldState.document, horizon: resumed.horizons[areaID]!,
            early: early.document.revision, a: a, b: b, c: c, a2: a2, placeCommand: placeCommand, placedRevision: placed.revision,
            artifactAdmit: artifactAdmit)
        relays.append(coldRelay)
        coldRelay.kill()
        print("Collaboration retention checks passed: compaction, explicit snapshot recovery, tombstones, receipts, membership and two replacement-directory restores.")
    } catch {
        if serverRunning { try? await server.stop() }
        throw error
    }
}

/// A new relay process on the replacement directory. Nothing is shared with the
/// original service except the copied files and the separately carried key.
private func verifyRestored(label: String, directory: URL, path: String, key: Data, area: SharedArea.ID<SharedArea.Area>, head: UInt64,
                            expected: SharedArea.Document, horizon: UInt64, early: UInt64,
                            a: Collaboration.Credential, b: Collaboration.Credential, c: Collaboration.Credential, a2: Collaboration.Credential,
                            placeCommand: SharedArea.Command, placedRevision: UInt64, artifactAdmit: SharedArea.Edit) async throws -> RelayProcess {
    let operatorStore = try CollaborationStore(path: path, masterKey: key)
    let report = try await operatorStore.verifyIntegrity()
    try retentionExpect(report.horizons[area.rawValue] == horizon && report.receipts == Int(head),
        "\(label): integrity verifies horizon \(horizon) plus tail against the stored head")
    let relay = try RelayProcess(root: directory, collaborationPath: path, key: key)
    try await relay.start()
    do {
        func api(_ token: String) throws -> CollaborationAPI { try CollaborationAPI(baseURL: relay.base, credential: token, allowsInsecureLoopback: true) }
        let apiA = try api(a.token), apiB = try api(b.token)
        let state = try await apiA.state(area: area.rawValue)
        try retentionExpect(try state.document.canonicalData() == expected.canonicalData() && state.scope.epoch == 2,
            "\(label): restored service serves the exact document at epoch 2")
        try await refusal(404, "notFound", "\(label): removed member stays removed") { _ = try await api(c.token).state(area: area.rawValue) }
        try await refusal(401, "unauthorized", "\(label): revoked device stays revoked") { _ = try await api(a2.token).state(area: area.rawValue) }
        try await refusal(409, "staleEpoch", "\(label): the old epoch stays stale") {
            _ = try await apiA.apply(area: area.rawValue, mutation: .init(epoch: 1, command: .init(area: area, expectedRevision: head,
                edits: [.post(.init(id: .init(), object: expected.posts[0].object, author: a.identity.person, text: "old epoch"))])))
        }
        let retried = try await apiA.apply(area: area.rawValue, mutation: .init(epoch: 2, command: placeCommand))
        try retentionExpect(retried.duplicate && retried.revision == placedRevision, "\(label): compacted receipt returns the original revision")
        try await refusal(409, "changedIntent", "\(label): operation ID stays bound to its original person") {
            _ = try await apiB.apply(area: area.rawValue, mutation: .init(epoch: 2, command: placeCommand))
        }
        try await refusal(400, "invalidCommand", "\(label): tombstone still refuses resurrection") {
            _ = try await apiA.apply(area: area.rawValue, mutation: .init(epoch: 2, command: .init(area: area, expectedRevision: head, edits: [artifactAdmit])))
        }
        try await refusal(409, "snapshotRequired", "\(label): a pre-horizon cursor is still told to take the snapshot") {
            _ = try await apiB.updates(area: area.rawValue, request: .init(after: early, waitMilliseconds: 0))
        }
        let after = try await apiA.state(area: area.rawValue)
        try retentionExpect(try after.document.canonicalData() == expected.canonicalData(), "\(label): refused requests change nothing")
        return relay
    } catch { relay.kill(); throw error }
}
