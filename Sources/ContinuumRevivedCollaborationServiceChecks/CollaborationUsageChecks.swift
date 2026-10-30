import Foundation
import ContinuumRevivedCollaborationProtocol
import ContinuumRevivedCollaborationService

private struct ServiceUsageFailure: Error { let message: String }
func runCollaborationUsageChecks() async throws {
    func expect(_ value: Bool, _ message: String) throws {
        guard value else { throw ServiceUsageFailure(message: message) }
        print("PASS usage authority: \(message)")
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("array-usage-service-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let key = Data(repeating: 41, count: 32), path = root.appendingPathComponent("collaboration.sqlite").path
    let store = try CollaborationStore(path: path, masterKey: key)
    func enroll(_ label: String) async throws -> Collaboration.Credential {
        let code = try await store.provisionPerson(label: label)
        return try await store.redeem(.init(code: code.code, deviceLabel: label))
    }
    let a = try await enroll("Peer A"), b = try await enroll("Peer B"), c = try await enroll("Excluded")
    let initial = try await store.createArea(token: a.token)
    let area = initial.document.id.rawValue
    let invitation = try await store.invite(token: a.token, area: area, request: .init(person: b.identity.person))
    _ = try await store.accept(token: b.token, code: invitation.code)
    let host = try await store.registerHost(token: a.token)
    let scope = try await store.state(token: a.token, area: area).scope
    let object = SharedArea.Item(id: .init(), kind: .agentObservation,
        source: .init(owner: a.identity.person, host: host.id, binding: .init()))
    let command = SharedArea.Command(area: .init(area), expectedRevision: 0,
        edits: [.admit(object, .init(id: .init(), object: object.id, rect: .init(x: 0, y: 0, width: 200, height: 200)))])
    _ = try await store.apply(token: a.token, area: area, request: .init(epoch: scope.epoch, command: command))
    let now = Date()
    func snapshot(_ sequence: UInt64, _ input: UInt64) -> Collaboration.UsageSnapshot {
        .init(host: host.id, sequence: sequence, inputTokens: input, outputTokens: 20, todayInputTokens: input,
            todayOutputTokens: 20, dayUTC: "2026-10-30", observedSince: now, measuredAt: now,
            coveredAgents: 1, runningAgents: 1, partial: false)
    }
    let session = try await store.beginPresence(token: a.token, area: area)
    try await store.publishPresence(token: a.token, area: area, input: .init(session: session.id, sequence: 1, cursor: .init(x: 40, y: 50)))
    try await store.reportUsage(token: a.token, area: area, report: .init(epoch: scope.epoch, snapshot: snapshot(1, 100)))
    try await store.reportUsage(token: a.token, area: area, report: .init(epoch: scope.epoch, snapshot: snapshot(2, 150)))
    try await store.reportUsage(token: a.token, area: area, report: .init(epoch: scope.epoch, snapshot: snapshot(1, 100)))
    let page = try await store.updates(token: b.token, area: area, request: .init(after: 1, waitMilliseconds: 0))
    try expect(page.presence.first?.usage?.inputTokens == 150 && page.presence.first?.label == "Peer A",
        "teammate receives authenticated human label and latest host accounting without double counting old reports")
    do { try await store.reportUsage(token: b.token, area: area, report: .init(epoch: scope.epoch, snapshot: snapshot(3, 200))); throw ServiceUsageFailure(message: "teammate forged another host's accounting") }
    catch CollaborationStoreError.forbidden { print("PASS usage authority: teammate cannot forge publishing-host totals") }
    do { _ = try await store.updates(token: c.token, area: area, request: .init(after: 1, waitMilliseconds: 0)); throw ServiceUsageFailure(message: "excluded person read usage") }
    catch CollaborationStoreError.unavailable { print("PASS usage authority: excluded person cannot read cursor or usage") }
    let reopened = try CollaborationStore(path: path, masterKey: key)
    let freshSession = try await reopened.beginPresence(token: a.token, area: area)
    try await reopened.publishPresence(token: a.token, area: area, input: .init(session: freshSession.id, sequence: 1, cursor: .init(x: 40, y: 50)))
    let restored = try await reopened.updates(token: b.token, area: area, request: .init(after: 1, waitMilliseconds: 0))
    try expect(restored.presence.first?.usage?.inputTokens == 150, "relay restart retains authenticated durable totals while cursors start a new ephemeral session")
    let secondHost = try await reopened.registerHost(token: a.token)
    let secondObject = SharedArea.Item(id: .init(), kind: .agentObservation,
        source: .init(owner: a.identity.person, host: secondHost.id, binding: .init()))
    _ = try await reopened.apply(token: a.token, area: area, request: .init(epoch: scope.epoch,
        command: .init(area: .init(area), expectedRevision: 1, edits: [.admit(secondObject,
            .init(id: .init(), object: secondObject.id, rect: .init(x: 250, y: 0, width: 200, height: 200)))])))
    let secondReport = Collaboration.UsageSnapshot(host: secondHost.id, sequence: 1, inputTokens: 25, outputTokens: 5,
        todayInputTokens: 25, todayOutputTokens: 5, dayUTC: "2026-10-30", observedSince: now, measuredAt: now,
        coveredAgents: 1, runningAgents: 0, partial: false)
    try await reopened.reportUsage(token: a.token, area: area, report: .init(epoch: scope.epoch, snapshot: secondReport))
    let combined = try await reopened.updates(token: b.token, area: area, request: .init(after: 2, waitMilliseconds: 0))
    try expect(combined.presence.first?.usage?.inputTokens == 175 && combined.presence.first?.usage?.outputTokens == 25
        && combined.presence.first?.usage?.coveredAgents == 2 && combined.presence.first?.usage?.runningAgents == 1,
        "multiple registered hosts on one device aggregate independent totals instead of choosing the largest sequence")
    _ = try await reopened.apply(token: a.token, area: area, request: .init(epoch: scope.epoch,
        command: .init(area: .init(area), expectedRevision: 2, edits: [.remove(object.id), .remove(secondObject.id)])))
    let revoked = try await reopened.updates(token: b.token, area: area, request: .init(after: 3, waitMilliseconds: 0))
    try expect(revoked.presence.first?.usage == nil, "source unpublication revokes future accounting projection in the document transaction")
}
