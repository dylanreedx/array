import ContinuumRevivedCore
import ContinuumRevivedRelayCore
import ContinuumRevivedRelayProtocol
import ContinuumRevivedSync
import Foundation

/// The Mac's task batch must stop growing. Every restart turns in-flight turns
/// into unknown tasks; before the quiet-task window they rode every batch for
/// ever (production carried 290 of them) and the batch crept towards the
/// relay's 512-task cap, past which publication is withheld and task alerts
/// stop. End to end: host ledger, Sync wire mapping, the relay's own store.
private final class FixtureClock: @unchecked Sendable {
    private let lock = NSLock(); private var value = Date(timeIntervalSince1970: 1_800_000_000)
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) { lock.lock(); value += seconds; lock.unlock() }
}

func runTaskBatchRetentionChecks() async throws {
    struct Failure: Error { let message: String }
    func check(_ value: Bool, _ message: String) throws { if !value { throw Failure(message: message) } }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("array-task-retention-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let clock = FixtureClock()
    var ledger = try CompanionTaskLedger(applicationSupportDirectory: root.appendingPathComponent("mac"), clock: clock.now)
    let store = try RelayStore(path: root.appendingPathComponent("relay.sqlite").path, masterKey: Data(repeating: 3, count: 32), outboxTrace: { _ in })
    let invite = try await store.createAlphaInvite(expiresAt: clock.now().addingTimeInterval(3600 * 24 * 30))
    let mac = try await store.redeemAlphaInvite(.init(code: invite.code, deviceLabel: "Retention Mac"))
    let auth = try await store.authenticate(mac.credential)
    let grant = try await store.createPairingGrant(auth: auth, deviceLabel: "Retention phone")
    let phone = try await store.exchangePairingGrant(.init(code: grant.code, deviceLabel: "Retention phone"))
    try await store.savePushToken(auth: try await store.authenticate(phone.credential), kind: .apns, token: Data("retention-fixture-token".utf8))
    func publish() async throws -> RelayTaskBatch {
        let batch = try ledger.snapshot().relayTaskBatch
        _ = try await store.publish(auth: auth, request: .init(kind: "task.batch.v1", payload: JSONEncoder().encode(batch)))
        return batch
    }

    // Five days. Each day 120 agents start a turn and the Mac restarts under
    // them, so every one of those tasks becomes unknown and never settles.
    let perDay = 120
    var sizes: [Int] = [], firstUnknown: CompanionTaskRunHandle?
    for _ in 0..<5 {
        for _ in 0..<perDay {
            let run = try ledger.begin(agentID: UUID())
            try ledger.observe(.turnStarted(threadId: "t", turnId: "work"), run: run)
            firstUnknown = firstUnknown ?? run
        }
        ledger = try CompanionTaskLedger(applicationSupportDirectory: root.appendingPathComponent("mac"), clock: clock.now)
        sizes.append(try await publish().tasks.count)
        clock.advance(CompanionTaskLedger.quietTaskWindow + 60)
    }
    // 600 unknown tasks exist in the ledger; only the last day's ride.
    try check(sizes.allSatisfy { $0 <= perDay }, "task batch grows with unknown tasks older than the window: \(sizes)")
    try check(try await store.pendingAlertCount(instanceID: mac.instanceID) == 0, "unknown tasks leaving the batch must not alert")

    // Alerts still fire: a new task finishing queues exactly one completion.
    let agent = UUID()
    let done = try ledger.begin(agentID: agent)
    try ledger.observe(.turnStarted(threadId: "t", turnId: "done"), run: done)
    let working = try await publish()
    try check(working.tasks.contains { $0.taskID == done.taskID }, "a running task is always in the batch")
    try ledger.observe(.turnCompleted(threadId: "t", turnId: "done", outcome: .completed, errorMessage: nil), run: done)
    let finished = try await publish()
    try check(finished.tasks.count <= perDay + 1, "batch stays bounded after the completion: \(finished.tasks.count)")
    try check(try await store.pendingAlertCount(instanceID: mac.instanceID) == 1, "a new completion must queue one alert")

    // A live task never ages out: waiting on a person for days still rides.
    let asking = try ledger.begin(agentID: UUID())
    try ledger.observe(.turnStarted(threadId: "t", turnId: "ask"), run: asking)
    _ = try ledger.holdAttention(asking, requestID: "retention-ask-0123456789")
    try ledger.observe(.turnCompleted(threadId: "t", turnId: "ask", outcome: .completed, errorMessage: nil), run: asking)
    clock.advance(CompanionTaskLedger.quietTaskWindow * 3)
    let later = try ledger.snapshot()
    try check(later.tasks.contains { $0.taskID == asking.taskID }, "a task waiting on a person must stay in the batch")
    try check(!later.tasks.contains { $0.taskID == done.taskID }, "a settled task must leave the batch after the window")

    // An aged-out task comes back the moment it changes.
    guard let old = firstUnknown else { throw Failure(message: "no aged task") }
    try check(!later.tasks.contains { $0.taskID == old.taskID }, "an old unknown task must have left the batch")
    try ledger.settleHostWork(old.runID, state: .failed)
    try check(try ledger.snapshot().tasks.contains { $0.taskID == old.taskID }, "a changed old task must rejoin the batch")
    print("PASS task batch retention: 600 unknown tasks over 5 days, batch ≤ \(perDay) each day \(sizes); completion queues one alert; waiting task stays; changed task rejoins")
}
