import Foundation
import Crypto
import GRDB
import ContinuumRevivedRelayCore
import ContinuumRevivedRelayProtocol

private struct OwnershipFailure: Error { let message: String }
private actor OwnershipTransport: RelayAPNSTransport {
    var requests: [RelayAPNSRequest] = []
    func send(_ request: RelayAPNSRequest) async throws -> RelayAPNSResponse { requests.append(request); return .init(statusCode: 200) }
    func count() -> Int { requests.count }
    func captured() -> [RelayAPNSRequest] { requests }
}

func runRelayTaskOwnershipChecks() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("array-task-owner-\(UUID())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = try RelayStore(path: dir.appendingPathComponent("relay.sqlite").path, masterKey: Data(repeating: 9, count: 32))
    // Deterministic writer contention: two relay processes may briefly overlap
    // during recovery. A valid enqueue/publication must wait for a short writer,
    // not disappear behind a swallowed SQLITE_BUSY preparation failure.
    let contentionPeer = try DatabaseQueue(path: dir.appendingPathComponent("relay.sqlite").path)
    let entered = AsyncStream<Void>.makeStream()
    let releaseWriter = DispatchSemaphore(value: 0)
    let heldWriter = Task.detached {
        try await contentionPeer.write { db in
            try db.execute(sql: "INSERT INTO relay_metadata(key,value) VALUES ('fixture_contention','true')")
            entered.continuation.yield(); entered.continuation.finish()
            guard releaseWriter.wait(timeout: .now() + 5) == .success else { throw OwnershipFailure(message: "writer contention fixture timed out") }
        }
    }
    var entry = entered.stream.makeAsyncIterator()
    guard await entry.next() != nil else { throw OwnershipFailure(message: "writer contention fixture did not acquire transaction") }
    let releaser = Task.detached { try await Task.sleep(for: .milliseconds(100)); releaseWriter.signal() }
    do {
        _ = try await store.createAlphaInvite(expiresAt: Date().addingTimeInterval(60))
    } catch {
        releaseWriter.signal(); _ = try? await heldWriter.value; _ = try? await releaser.value
        throw OwnershipFailure(message: "bounded overlapping writer caused valid relay write to fail")
    }
    try await heldWriter.value; try await releaser.value
    let invite = try await store.createAlphaInvite(expiresAt: Date().addingTimeInterval(60))
    let mac = try await store.redeemAlphaInvite(.init(code: invite.code, deviceLabel: "Task Mac"))
    let auth = try await store.authenticate(mac.credential)
    let grant = try await store.createPairingGrant(auth: auth, deviceLabel: "Task phone")
    let phone = try await store.exchangePairingGrant(.init(code: grant.code, deviceLabel: "Task phone"))
    try await store.savePushToken(auth: try await store.authenticate(phone.credential), kind: .apns, token: Data("task-fixture-token".utf8))
    let transport = OwnershipTransport()
    let sender = try RelayAPNSService(store: store,
        configuration: .init(keyID: "fixture", teamID: "fixture", privateKeyPEM: P256.Signing.PrivateKey().pemRepresentation),
        transport: transport, trace: { _ in })
    let agent = UUID(), run = UUID()
    let historicalRun = UUID()
    let historical = RelayTaskState(taskID: UUID(), rootRunID: historicalRun, membershipComplete: true,
        members: [.init(agentID: UUID(), runID: historicalRun, state: .succeeded)])
    // Commit legacy work without waking a sender, then hand ownership over.
    _ = try await store.publish(auth: auth, request: .init(kind: "sync.message", payload: JSONSerialization.data(withJSONObject: ["activity": ["event": [
        "agentId": agent.uuidString, "status": "done", "terminalOutcome": "succeeded",
    ]]])))
    let baseline = RelayTaskBatch(publisherID: UUID(), revision: 1, tasks: [
        .init(taskID: UUID(), rootRunID: run, membershipComplete: true, members: [.init(agentID: agent, runID: run, state: .running)]), historical,
    ])
    let batchEvent = try await store.publish(auth: auth, request: .init(kind: "task.batch.v1", payload: JSONEncoder().encode(baseline)))
    await sender.deliverPublished(event: batchEvent, instanceID: mac.instanceID)
    let legacy = try await store.publish(auth: auth, request: .init(kind: "sync.message", payload: JSONSerialization.data(withJSONObject: ["activity": ["event": [
        "agentId": agent.uuidString, "status": "done", "terminalOutcome": "succeeded",
    ]]])))
    await sender.deliverPublished(event: legacy, instanceID: mac.instanceID)
    guard await transport.count() == 0 else { throw OwnershipFailure(message: "task owner must suppress legacy completion while task is running") }
    func publish(_ batch: RelayTaskBatch) async throws {
        let event = try await store.publish(auth: auth, request: .init(kind: "task.batch.v1", payload: JSONEncoder().encode(batch)))
        await sender.deliverPublished(event: event, instanceID: mac.instanceID)
    }
    await sender.drainOutbox()
    guard await transport.count() == 0 else { throw OwnershipFailure(message: "baseline must cancel old legacy backlog and suppress historical completion") }
    var next = baseline
    next.revision = 2
    next.tasks[0].members[0].state = .succeeded
    try await publish(next)
    guard await transport.count() == 1 else { throw OwnershipFailure(message: "settled task must send exactly one completion") }
    let alert = await transport.captured()[0]
    let alertBody = try JSONSerialization.jsonObject(with: alert.body) as! [String: Any]
    let targetTask = next.tasks[0].taskID
    let expectedLink = "array://agent/\(agent)?task=\(targetTask)&run=\(run)&instance=\(mac.instanceID)"
    guard alertBody["deepLink"] as? String == expectedLink,
          alertBody["taskId"] as? String == targetTask.uuidString,
          alertBody["runId"] as? String == run.uuidString,
          alertBody["instanceId"] as? String == mac.instanceID.uuidString else {
        throw OwnershipFailure(message: "persisted task alert must retain exact agent/task/run/instance destination")
    }
    try await publish(next)
    guard await transport.count() == 1 else { throw OwnershipFailure(message: "same revision replay must not duplicate task completion") }
    let accepted = next
    next.revision = 3; next.tasks[0].members[0].state = .unknown; next.tasks[1].members[0].state = .unknown
    try await publish(next)
    next.revision = 4; next.tasks[0].members[0].state = .succeeded; next.tasks[1].members[0].state = .succeeded
    try await publish(next)
    guard await transport.count() == 1 else { throw OwnershipFailure(message: "accepted and baseline decisions must stay quiet after interim unknown state") }
    try await publish(accepted) // a late, valid older revision cannot change ownership
    guard try await store.taskNotificationOwner(instanceID: mac.instanceID)?.revision == 4 else { throw OwnershipFailure(message: "stale revision changed owner") }
    var conflict = next; conflict.tasks[0].members[0].state = .running
    do {
        try await publish(conflict)
        throw OwnershipFailure(message: "conflicting payload for same revision accepted")
    } catch RelayStoreError.notificationRevisionConflict {}
    var foreign = next; foreign.publisherID = UUID(); foreign.revision = 5
    do { try await publish(foreign); throw OwnershipFailure(message: "foreign publisher took ownership") }
    catch RelayStoreError.notificationOwnerMismatch {}
    do {
        _ = try await store.publish(auth: auth, request: .init(kind: "task.state.v1", payload: JSONEncoder().encode(historical)))
        throw OwnershipFailure(message: "unowned standalone task notification accepted")
    } catch RelayStoreError.notificationOwnerRequired {}
    let extraGrant = try await store.createPairingGrant(auth: auth, deviceLabel: "Later phone")
    let later = try await store.exchangePairingGrant(.init(code: extraGrant.code, deviceLabel: "Later phone"))
    try await store.savePushToken(auth: try await store.authenticate(later.credential), kind: .apns, token: Data("later-fixture-token".utf8))
    try await publish(next)
    guard await transport.count() == 1 else { throw OwnershipFailure(message: "newly paired phone received old completion replay") }
    let reopened = try RelayStore(path: dir.appendingPathComponent("relay.sqlite").path, masterKey: Data(repeating: 9, count: 32))
    guard try await reopened.taskNotificationOwner(instanceID: mac.instanceID) == .init(publisherID: baseline.publisherID, revision: 4) else {
        throw OwnershipFailure(message: "ownership fence did not survive store restart")
    }
    let restartSender = try RelayAPNSService(store: reopened,
        configuration: .init(keyID: "fixture", teamID: "fixture", privateKeyPEM: P256.Signing.PrivateKey().pemRepresentation), transport: transport, trace: { _ in })
    await restartSender.deliverPublished(event: legacy, instanceID: mac.instanceID)
    await restartSender.drainOutbox()
    guard await transport.count() == 1 else { throw OwnershipFailure(message: "restart reactivated legacy or old task delivery") }
    let newRun = UUID()
    next.revision = 5
    next.tasks.append(.init(taskID: UUID(), rootRunID: newRun, membershipComplete: true,
        members: [.init(agentID: UUID(), runID: newRun, state: .succeeded)]))
    try await publish(next)
    guard await transport.count() == 3 else { throw OwnershipFailure(message: "new decision must reach both currently paired phones") }
    let phoneAuth = try await store.authenticate(phone.credential)
    try await store.savePushToken(auth: phoneAuth, kind: .widget, token: Data("widget-fixture".utf8))
    try await store.savePushToken(auth: phoneAuth, kind: .liveActivity, token: Data("activity-fixture".utf8))
    try await store.savePushToken(auth: phoneAuth, kind: .liveActivityStart, token: Data("start-fixture".utf8))
    let activeRun = UUID()
    next.revision = 6
    next.tasks.append(.init(taskID: UUID(), rootRunID: activeRun, membershipComplete: true,
        members: [.init(agentID: UUID(), runID: activeRun, state: .running)]))
    try await publish(next)
    var surfaces = await transport.captured()
    guard surfaces.count == 5 else { throw OwnershipFailure(message: "task batch must send one widget and one existing activity update, no push-to-start") }
    let update = surfaces.last { $0.headers["apns-push-type"] == "liveactivity" }!
    let updateJSON = try JSONSerialization.jsonObject(with: update.body) as! [String: Any]
    guard (updateJSON["aps"] as? [String: Any])?["event"] as? String == "update" else {
        throw OwnershipFailure(message: "settled tasks must not end aggregate while another task runs")
    }
    await sender.deliverPublished(event: legacy, instanceID: mac.instanceID)
    guard await transport.count() == 5 else { throw OwnershipFailure(message: "legacy owner suppression must cover every hosted surface") }
    next.revision = 7; next.tasks[next.tasks.count - 1].members[0].state = .succeeded
    try await publish(next)
    surfaces = await transport.captured()
    guard surfaces.count == 9 else { throw OwnershipFailure(message: "new completion must send two alerts plus two aggregate surfaces") }
    let end = surfaces.last { $0.headers["apns-push-type"] == "liveactivity" }!
    let endJSON = try JSONSerialization.jsonObject(with: end.body) as! [String: Any]
    guard (endJSON["aps"] as? [String: Any])?["event"] as? String == "end" else { throw OwnershipFailure(message: "all-task terminal must end existing aggregate") }
    next.revision = 8; next.tasks[0].members[0].state = .needsInput; next.tasks[0].members[0].requestID = "new-attention"
    _ = try await store.publish(auth: auth, request: .init(kind: "task.batch.v1", payload: JSONEncoder().encode(next)))
    guard try await store.pendingAlertCount(instanceID: mac.instanceID) == 2 else { throw OwnershipFailure(message: "nonvacuity: pending attention must exist before resolution") }
    next.revision = 9; next.tasks[0].members[0].state = .succeeded; next.tasks[0].members[0].requestID = nil
    _ = try await store.publish(auth: auth, request: .init(kind: "task.batch.v1", payload: JSONEncoder().encode(next)))
    guard try await store.pendingAlertCount(instanceID: mac.instanceID) == 0 else { throw OwnershipFailure(message: "authoritative newer settled state must cancel pending attention even when terminal identity was already accepted") }
    await sender.drainOutbox()
    guard await transport.count() == 9 else { throw OwnershipFailure(message: "resolved attention reached sender after settled revision") }
    // A decision's original recipient cohort must survive intervening states.
    // Pair a third phone while the old task is unknown, then restore its terminal
    // identity: this is history, not a new completion for that phone.
    next.revision = 10; next.tasks[0].members[0].state = .unknown
    try await publish(next)
    let thirdGrant = try await store.createPairingGrant(auth: auth, deviceLabel: "Third phone")
    let third = try await store.exchangePairingGrant(.init(code: thirdGrant.code, deviceLabel: "Third phone"))
    try await store.savePushToken(auth: try await store.authenticate(third.credential), kind: .apns, token: Data("third-fixture-token".utf8))
    let beforeRestore = await transport.count()
    next.revision = 11; next.tasks[0].members[0].state = .succeeded
    try await publish(next)
    guard await transport.count() == beforeRestore + 2 else { throw OwnershipFailure(message: "new phone enrolled in historical decision after unknown/recovery; only two aggregate surfaces should update") }
    // Simulate only an ownership-query failure while registrations and all
    // legacy surface tables remain readable. Missing evidence must fail closed.
    let peer = try DatabaseQueue(path: dir.appendingPathComponent("relay.sqlite").path)
    try await peer.write { try $0.execute(sql: "ALTER TABLE notification_ownership RENAME TO fixture_unavailable_owner") }
    let beforeOwnerFailure = await transport.count()
    await sender.deliverPublished(event: legacy, instanceID: mac.instanceID)
    try await peer.write { try $0.execute(sql: "ALTER TABLE fixture_unavailable_owner RENAME TO notification_ownership") }
    guard await transport.count() == beforeOwnerFailure else { throw OwnershipFailure(message: "ownership read failure fell back to legacy surface delivery") }
    print("Task notification ownership checks passed: atomic legacy backlog cancellation, quiet historical baseline, later completion once, unknown/restore dedup, stale/conflicting/foreign revision fencing, no late pairing replay restart persistence and all-surface aggregate/no-start ownership")
}
