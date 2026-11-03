import Foundation
import ContinuumRevivedRelayCore
import ContinuumRevivedRelayProtocol

/// Phone → Mac commands through the relay store: the phone's capability and
/// device are the relay's, the Mac collects pending work it missed while
/// offline, the first result wins, and nothing runs after its lifetime or
/// after the sending phone is revoked.
func runRelayCommandChecks() async throws {
    struct Failure: Error { let message: String }
    func check(_ value: Bool, _ message: String) throws { if !value { throw Failure(message: message) } }
    func refuses(_ expected: RelayStoreError, _ body: () async throws -> Void) async -> Bool {
        do { try await body(); return false } catch let error as RelayStoreError { return error == expected } catch { return false }
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("array-relay-commands-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try RelayStore(path: directory.appendingPathComponent("relay.sqlite").path, masterKey: Data(repeating: 3, count: 32))
    let invite = try await store.createAlphaInvite(expiresAt: Date().addingTimeInterval(60))
    let mac = try await store.authenticate(try await store.redeemAlphaInvite(.init(code: invite.code, deviceLabel: "Mac")).credential)
    func pair(_ label: String) async throws -> (RelayCompanionProvisioning, RelayCredentialContext) {
        let grant = try await store.createPairingGrant(auth: mac, deviceLabel: label)
        let phone = try await store.exchangePairingGrant(.init(code: grant.code, deviceLabel: label))
        return (phone, try await store.authenticate(phone.credential))
    }
    let (phone, phoneAuth) = try await pair("Phone")
    let (_, otherAuth) = try await pair("iPad")
    let t0 = Date()

    // The Mac was offline: the command waits, payload intact, sender stamped.
    let agent = UUID()
    let approval = RelayCommandRequest(idempotencyKey: UUID(), kind: RelayCommandKind.approvalRespond, agentID: agent, payload: Data("{\"decision\":\"accept\"}".utf8))
    _ = try await store.acceptCommand(auth: phoneAuth, request: approval, now: t0)
    let page = try await store.pendingCommands(auth: mac, now: t0.addingTimeInterval(120))
    try check(page.commands.count == 1 && page.commands[0].payload == approval.payload && page.commands[0].deviceID == phone.deviceID
              && page.commands[0].agentID == agent && page.commands[0].kind == RelayCommandKind.approvalRespond,
              "the Mac collects the command it missed, with its payload and the relay-authenticated sender")
    try check(try await store.commandStatus(auth: phoneAuth, key: approval.idempotencyKey, now: t0.addingTimeInterval(120)).state == .pending,
              "the phone sees it pending")

    // Who may do what.
    try check(await refuses(.forbidden) { _ = try await store.pendingCommands(auth: phoneAuth) }, "a phone cannot read the Mac's queue")
    try check(await refuses(.forbidden) { _ = try await store.completeCommand(auth: phoneAuth, key: approval.idempotencyKey, result: .init(outcome: "stopped")) },
              "a phone cannot write a result")
    try check(await refuses(.forbidden) { _ = try await store.acceptCommand(auth: mac, request: .init(idempotencyKey: UUID(), kind: RelayCommandKind.agentStop, agentID: agent)) },
              "the Mac does not send itself commands")
    try check(await refuses(.commandNotFound) { _ = try await store.commandStatus(auth: otherAuth, key: approval.idempotencyKey) },
              "another phone cannot read this phone's command")
    try check(await refuses(.invalidCommand) { _ = try await store.acceptCommand(auth: phoneAuth, request: .init(idempotencyKey: UUID(), kind: "agent.delete", agentID: agent)) },
              "an unknown kind is refused")
    try check(await refuses(.payloadTooLarge) {
        _ = try await store.acceptCommand(auth: phoneAuth, request: .init(idempotencyKey: UUID(), kind: RelayCommandKind.agentStop, agentID: agent,
                                                                           payload: Data(count: RelayCommandLimits.maximumPayloadBytes + 1)))
    }, "an oversized payload is refused")
    try check(await refuses(.commandConflict) {
        _ = try await store.acceptCommand(auth: phoneAuth, request: .init(idempotencyKey: approval.idempotencyKey, kind: RelayCommandKind.agentStop, agentID: agent))
    }, "a reused key carrying a different command is refused")
    let retry = try await store.acceptCommand(auth: phoneAuth, request: approval, now: t0.addingTimeInterval(5))
    let afterRetry = try await store.pendingCommands(auth: mac, now: t0.addingTimeInterval(6))
    try check(abs(retry.createdAt.timeIntervalSince(t0)) < 0.001 && afterRetry.commands.count == 1, "a retried command is one command")

    // The first result wins and the command leaves the queue.
    let done = try await store.completeCommand(auth: mac, key: approval.idempotencyKey, result: .init(outcome: "sent"), now: t0.addingTimeInterval(130))
    let again = try await store.completeCommand(auth: mac, key: approval.idempotencyKey, result: .init(outcome: "unknownRequest"), now: t0.addingTimeInterval(140))
    try check(done.state == .completed && done.outcome == "sent" && again.outcome == "sent", "the first result wins")
    try check(try await store.commandStatus(auth: phoneAuth, key: approval.idempotencyKey).outcome == "sent", "the phone reads the Mac's result")
    try check((try await store.pendingCommands(auth: mac, now: t0.addingTimeInterval(141))).commands.isEmpty, "a completed command is not collected again")
    try check(await refuses(.invalidCommand) { _ = try await store.completeCommand(auth: mac, key: approval.idempotencyKey, result: .init(outcome: "")) },
              "an empty outcome is refused")

    // Too late: never collected, never completed, the phone is told.
    let stale = RelayCommandRequest(idempotencyKey: UUID(), kind: RelayCommandKind.agentStop, agentID: agent)
    _ = try await store.acceptCommand(auth: phoneAuth, request: stale, now: t0)
    let late = t0.addingTimeInterval(RelayCommandLimits.lifetime + 1)
    try check((try await store.pendingCommands(auth: mac, now: late)).commands.isEmpty, "an expired command is never collected")
    let lateResult = try await store.completeCommand(auth: mac, key: stale.idempotencyKey, result: .init(outcome: "stopped"), now: late)
    try check(lateResult.state == .expired && lateResult.outcome == nil, "an expired command takes no result")
    try check(try await store.commandStatus(auth: phoneAuth, key: stale.idempotencyKey, now: late).state == .expired, "the phone sees it expired")

    // Revoking the phone drops what it queued.
    let queued = RelayCommandRequest(idempotencyKey: UUID(), kind: RelayCommandKind.agentStop, agentID: agent)
    _ = try await store.acceptCommand(auth: otherAuth, request: queued)
    let beforeRevoke = try await store.pendingCommands(auth: mac).commands.map(\.idempotencyKey)
    try check(beforeRevoke.contains(queued.idempotencyKey) && beforeRevoke.contains(stale.idempotencyKey), "both phones' commands are queued")
    try await store.revokeCredential(auth: mac, credentialID: otherAuth.credentialID)
    let afterRevoke = try await store.pendingCommands(auth: mac).commands.map(\.idempotencyKey)
    try check(!afterRevoke.contains(queued.idempotencyKey) && afterRevoke.contains(stale.idempotencyKey),
              "a revoked phone's queued command does not run; the other phone's still does")

    // Old rows go once they are a day old, on the next command; younger ones stay.
    let dayLater = t0.addingTimeInterval(RelayCommandLimits.retention + 1)
    let young = RelayCommandRequest(idempotencyKey: UUID(), kind: RelayCommandKind.agentStop, agentID: agent)
    _ = try await store.acceptCommand(auth: phoneAuth, request: young, now: t0.addingTimeInterval(RelayCommandLimits.retention - 60))
    _ = try await store.acceptCommand(auth: phoneAuth, request: .init(idempotencyKey: UUID(), kind: RelayCommandKind.agentStop, agentID: agent), now: dayLater)
    try check(await refuses(.commandNotFound) { _ = try await store.commandStatus(auth: phoneAuth, key: approval.idempotencyKey, now: dayLater) },
              "a day-old answered command is deleted")
    try check(await refuses(.commandNotFound) { _ = try await store.commandStatus(auth: phoneAuth, key: stale.idempotencyKey, now: dayLater) },
              "a day-old expired command is deleted")
    try check(try await store.commandStatus(auth: phoneAuth, key: young.idempotencyKey, now: dayLater).state == .pending,
              "a command younger than a day is kept")

    print("Relay command checks passed: offline Mac collects with payload and sender, roles enforced, retries are one command, first result wins, expiry and revocation drop commands, day-old rows are pruned")
}
