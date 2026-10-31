import Foundation
import Crypto
import ContinuumRevivedRelayCore
import ContinuumRevivedRelayProtocol

/// A paired Mac republishes every known task in each task.batch.v1 event. The
/// relay must spend work on the tasks whose decision changed, not on every
/// task it already knows: production stalled its health endpoint for ~45 s
/// while 336 settled tasks were re-decided, re-queried and logged per event.
private struct BatchLoadFailure: Error, CustomStringConvertible { let description: String }
private final class Counter: @unchecked Sendable {
    private let lock = NSLock(); private var value = 0
    func add() { lock.lock(); value += 1; lock.unlock() }
    func take() -> Int { lock.lock(); defer { value = 0; lock.unlock() }; return value }
}
private final class TraceLog: @unchecked Sendable {
    private let lock = NSLock(); private var values: [RelayNotificationTrace] = []
    func add(_ trace: RelayNotificationTrace) { lock.lock(); values.append(trace); lock.unlock() }
    func take() -> [RelayNotificationTrace] { lock.lock(); defer { values = []; lock.unlock() }; return values }
}
private actor LoadTransport: RelayAPNSTransport {
    var alerts = 0
    func send(_ request: RelayAPNSRequest) async throws -> RelayAPNSResponse {
        if request.headers["apns-push-type"] == "alert" { alerts += 1 }
        return .init(statusCode: 200)
    }
    func alertCount() -> Int { alerts }
}

private struct BurstCost { let statements: [Int]; let traces: [Int]; let outboxTraces: [Int]; let seconds: Double }

/// One phone, `known` settled tasks plus one live task. Every event after the
/// baseline changes only the live task.
private func measureBurst(known: Int, events: Int) async throws -> BurstCost {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("array-task-batch-load-\(UUID())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let statements = Counter(), outbox = Counter(), batches = Counter(), traces = TraceLog()
    let store = try RelayStore(path: dir.appendingPathComponent("relay.sqlite").path, masterKey: Data(repeating: 7, count: 32),
                               outboxTrace: { _ in outbox.add() }, statementObserver: { statements.add() })
    let invite = try await store.createAlphaInvite(expiresAt: Date().addingTimeInterval(60))
    let mac = try await store.redeemAlphaInvite(.init(code: invite.code, deviceLabel: "Load Mac"))
    let auth = try await store.authenticate(mac.credential)
    let grant = try await store.createPairingGrant(auth: auth, deviceLabel: "Load phone")
    let phone = try await store.exchangePairingGrant(.init(code: grant.code, deviceLabel: "Load phone"))
    try await store.savePushToken(auth: try await store.authenticate(phone.credential), kind: .apns, token: Data("load-fixture-token".utf8))
    let transport = LoadTransport()
    let sender = try RelayAPNSService(store: store,
        configuration: .init(keyID: "fixture", teamID: "fixture", privateKeyPEM: P256.Signing.PrivateKey().pemRepresentation),
        transport: transport, trace: { traces.add($0) }, batchTrace: { _ in batches.add() })
    func settled(_ index: Int) -> RelayTaskState {
        let run = UUID()
        // The production mix: mostly unknown-membership tasks (T-02), some
        // finished (T-06), failed (T-05) and cancelled (T-07) ones.
        switch index % 10 {
        case 0: return .init(taskID: UUID(), rootRunID: run, membershipComplete: true, members: [.init(agentID: UUID(), runID: run, state: .succeeded)])
        case 1: return .init(taskID: UUID(), rootRunID: run, membershipComplete: true, members: [.init(agentID: UUID(), runID: run, state: .failed)])
        case 2: return .init(taskID: UUID(), rootRunID: run, membershipComplete: true, members: [.init(agentID: UUID(), runID: run, state: .cancelled)])
        default: return .init(taskID: UUID(), rootRunID: run, membershipComplete: false, members: [.init(agentID: UUID(), runID: run, state: .succeeded)])
        }
    }
    let liveRun = UUID(), liveAgent = UUID()
    var batch = RelayTaskBatch(publisherID: UUID(), revision: 1, tasks: (0..<known).map(settled) + [
        .init(taskID: UUID(), rootRunID: liveRun, membershipComplete: true, members: [.init(agentID: liveAgent, runID: liveRun, state: .running)]),
    ])
    let live = batch.tasks.count - 1
    func publish() async throws {
        let event = try await store.publish(auth: auth, request: .init(kind: "task.batch.v1", payload: JSONEncoder().encode(batch)))
        await sender.deliverPublished(event: event, instanceID: mac.instanceID)
    }
    try await publish()                       // quiet baseline
    batch.revision = 2; try await publish()   // a second owner revision: settled tasks become known decisions
    _ = statements.take(); _ = traces.take(); _ = outbox.take(); _ = batches.take()
    var cost = BurstCost(statements: [], traces: [], outboxTraces: [], seconds: 0)
    let started = Date()
    for step in 0..<events {
        batch.revision += 1
        batch.tasks[live].members[0].state = step % 2 == 0 ? .queued : .running
        try await publish()
        guard batches.take() == 1 else { throw BatchLoadFailure(description: "each delivered batch must log exactly one batch line") }
        cost = .init(statements: cost.statements + [statements.take()], traces: cost.traces + [traces.take().count],
                     outboxTraces: cost.outboxTraces + [outbox.take()], seconds: 0)
    }
    let seconds = Date().timeIntervalSince(started)
    // Behaviour must survive the cut: the live task finishing alerts once, a
    // republish of the same state never alerts again, and no settled task alerts.
    batch.revision += 1; batch.tasks[live].members[0].state = .succeeded; try await publish()
    await sender.drainOutbox()
    guard await transport.alertCount() == 1 else { throw BatchLoadFailure(description: "live task completion sent \(await transport.alertCount()) alerts, want 1") }
    batch.revision += 1; try await publish(); await sender.drainOutbox()
    guard await transport.alertCount() == 1 else { throw BatchLoadFailure(description: "republished completion alerted again") }
    return .init(statements: cost.statements, traces: cost.traces, outboxTraces: cost.outboxTraces, seconds: seconds)
}

/// Skipping unchanged tasks must not strand an alert the outbox refused for
/// capacity: that task stays undecided and the next batch queues it.
private func capacityRejectedAlertRetries() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("array-task-batch-capacity-\(UUID())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = try RelayStore(path: dir.appendingPathComponent("relay.sqlite").path, masterKey: Data(repeating: 5, count: 32), outboxTrace: { _ in })
    let invite = try await store.createAlphaInvite(expiresAt: Date().addingTimeInterval(60))
    let mac = try await store.redeemAlphaInvite(.init(code: invite.code, deviceLabel: "Capacity Mac"))
    let auth = try await store.authenticate(mac.credential)
    let grant = try await store.createPairingGrant(auth: auth, deviceLabel: "Capacity phone")
    let phone = try await store.exchangePairingGrant(.init(code: grant.code, deviceLabel: "Capacity phone"))
    try await store.savePushToken(auth: try await store.authenticate(phone.credential), kind: .apns, token: Data("capacity-fixture-token".utf8))
    let transport = LoadTransport()
    let sender = try RelayAPNSService(store: store,
        configuration: .init(keyID: "fixture", teamID: "fixture", privateKeyPEM: P256.Signing.PrivateKey().pemRepresentation),
        transport: transport, trace: { _ in }, batchTrace: { _ in })
    let count = RelayOutboxPolicy.maximumPendingPerInstance + 1
    let runs = (0..<count).map { _ in UUID() }
    var batch = RelayTaskBatch(publisherID: UUID(), revision: 1, tasks: runs.map {
        .init(taskID: UUID(), rootRunID: $0, membershipComplete: true, members: [.init(agentID: UUID(), runID: $0, state: .running)])
    })
    _ = try await store.publish(auth: auth, request: .init(kind: "task.batch.v1", payload: JSONEncoder().encode(batch)))
    // Every task finishes at once: one more completion than the outbox holds.
    // Publish without delivering, so the outbox stays full.
    batch.revision = 2
    for index in batch.tasks.indices { batch.tasks[index].members[0].state = .succeeded }
    _ = try await store.publish(auth: auth, request: .init(kind: "task.batch.v1", payload: JSONEncoder().encode(batch)))
    await sender.drainOutbox(); while try await store.pendingAlertCount(instanceID: mac.instanceID) > 0 { await sender.drainOutbox() }
    guard await transport.alertCount() == count - 1 else { throw BatchLoadFailure(description: "full outbox sent \(await transport.alertCount()), want \(count - 1)") }
    // The same state again: only the refused completion is still undecided.
    batch.revision = 3
    let event = try await store.publish(auth: auth, request: .init(kind: "task.batch.v1", payload: JSONEncoder().encode(batch)))
    await sender.deliverPublished(event: event, instanceID: mac.instanceID)
    guard await transport.alertCount() == count else {
        throw BatchLoadFailure(description: "capacity-rejected completion was not retried: \(await transport.alertCount()) alerts, want \(count)")
    }
}

func runRelayTaskBatchLoadChecks() async throws {
    try await capacityRejectedAlertRetries()
    print("PASS task batch capacity: a completion the full outbox refused is queued by the next batch, once")
    let small = try await measureBurst(known: 40, events: 6)
    let large = try await measureBurst(known: 400, events: 6)
    print("task batch load: 40 known tasks → statements/event \(small.statements), traces/event \(small.traces), \(String(format: "%.3f", small.seconds)) s")
    print("task batch load: 400 known tasks → statements/event \(large.statements), traces/event \(large.traces), \(String(format: "%.3f", large.seconds)) s")
    guard large.statements == small.statements else {
        throw BatchLoadFailure(description: "per-event database statements grow with known tasks: 40 → \(small.statements), 400 → \(large.statements)")
    }
    guard large.traces == small.traces, large.traces.allSatisfy({ $0 <= 2 }) else {
        throw BatchLoadFailure(description: "per-event notification log lines grow with known tasks: 40 → \(small.traces), 400 → \(large.traces)")
    }
    guard large.outboxTraces == small.outboxTraces else {
        throw BatchLoadFailure(description: "per-event outbox traces grow with known tasks: 40 → \(small.outboxTraces), 400 → \(large.outboxTraces)")
    }
    print("PASS task batch load: per-event statements and log lines do not grow with known tasks (40 vs 400); one completion alert, no repeat")
}
