import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import GRDB
import ContinuumRevivedCollaborationProtocol
import ContinuumRevivedCollaborationService
import ContinuumRevivedRelayCore
import ContinuumRevivedRelayNIO

private struct Failure: Error { let message: String }
private func check(_ value: Bool, _ message: String) throws {
    guard value else { throw Failure(message: message) }
    print("PASS: \(message)")
}
private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_800_000_000)
    func now() -> Date { lock.withLock { date } }
    func advance(_ seconds: TimeInterval) { lock.withLock { date = date.addingTimeInterval(seconds) } }
}
private struct Empty: Encodable {}
private struct HTTP: Sendable {
    let base: URL
    func send<T: Encodable>(_ method: String, _ path: String, token: String? = nil, epoch: Int64? = nil, body: T) async throws -> (Int, Data) {
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = method; request.timeoutInterval = 5
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        if method != "GET" && method != "DELETE" { request.httpBody = try encoder.encode(body) }
        if let epoch { request.setValue(String(epoch), forHTTPHeaderField: "if-match") }
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization") }
        let (bytes, response) = try await URLSession.shared.data(for: request)
        return ((response as! HTTPURLResponse).statusCode, bytes)
    }
    func value<T: Decodable, B: Encodable>(_ type: T.Type, _ method: String, _ path: String, token: String? = nil, body: B, status: Int = 200) async throws -> T {
        let (actual, data) = try await send(method, path, token: token, body: body)
        guard actual == status else { throw Failure(message: "\(method) \(path): expected \(status), received \(actual) \(String(decoding: data, as: UTF8.self))") }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }
    func denied<B: Encodable>(_ method: String, _ path: String, token: String?, body: B, status: Int, _ label: String) async throws {
        let (actual, bytes) = try await send(method, path, token: token, body: body)
        try check(actual == status, label + " status")
        try check(!String(decoding: bytes, as: UTF8.self).contains("shared-content-sentinel"), label + " excludes content bytes")
    }
}
private func run() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("array-collaboration-http-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let clock = Clock(), key = Data(repeating: 39, count: 32)
    let path = root.appendingPathComponent("collaboration.sqlite").path
    let store = try CollaborationStore(path: path, masterKey: key, clock: { clock.now() })
    let companion = try RelayStore(path: root.appendingPathComponent("companion.sqlite").path, masterKey: key)
    let server = RelayServer(store: companion, configuration: .init(host: "127.0.0.1", publicPort: 0, adminPort: 0), collaboration: store)
    try await server.start()
    do {
        let http = HTTP(base: URL(string: "http://127.0.0.1:\(server.listeningPublicPort!)/collaboration/v1")!)
        func person(_ label: String) async throws -> Collaboration.Credential {
            let enrollment = try await store.provisionPerson(label: label)
            return try await http.value(Collaboration.Credential.self, "POST", "enrollments/redeem", body: Collaboration.RedeemEnrollment(code: enrollment.code, deviceLabel: label), status: 201)
        }
        // Exercise the actual operator entry point using fixture paths/keys.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("continuum-relay")
        process.arguments = ["--collaboration-enroll", "Operator-admitted person"]
        var environment = ProcessInfo.processInfo.environment
        environment["RELAY_DATABASE_PATH"] = root.appendingPathComponent("operator-companion.sqlite").path
        environment["RELAY_MASTER_KEY"] = key.base64EncodedString()
        environment["RELAY_COLLABORATION_DATABASE_PATH"] = path
        environment["RELAY_COLLABORATION_MASTER_KEY"] = key.base64EncodedString()
        process.environment = environment
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output; process.standardError = errors
        try process.run(); process.waitUntilExit()
        try check(process.terminationStatus == 0, "operator enrollment process uses isolated configuration")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let operatorEnrollment = try decoder.decode(Collaboration.Enrollment.self, from: output.fileHandleForReading.readDataToEndOfFile())
        // Operator process uses real time, so redeem through a matching-clock store.
        let operatorStore = try CollaborationStore(path: path, masterKey: key)
        _ = try await operatorStore.redeem(.init(code: operatorEnrollment.code, deviceLabel: "Operator device"))
        print("PASS: operator entry point issues redeemable person enrollment")
        let a = try await person("Person A"), b = try await person("Person B"), c = try await person("Person C")
        try check(a.identity.person != b.identity.person && b.identity.person != c.identity.person, "independent person identities")
        let a2Enrollment = try await http.value(Collaboration.Enrollment.self, "POST", "devices/enrollments", token: a.token, body: Collaboration.DeviceEnrollmentRequest(), status: 201)
        let a2 = try await http.value(Collaboration.Credential.self, "POST", "enrollments/redeem", body: Collaboration.RedeemEnrollment(code: a2Enrollment.code, deviceLabel: "Second device"), status: 201)
        try check(a2.identity.person == a.identity.person && a2.identity.device != a.identity.device, "one person has separately authenticated devices")
        try await http.denied("POST", "enrollments/redeem", token: nil, body: Collaboration.RedeemEnrollment(code: a2Enrollment.code, deviceLabel: "Replay"), status: 410, "consumed enrollment")
        let first = try await http.value(Collaboration.State.self, "POST", "areas", token: a.token, body: Empty(), status: 201)
        let area = first.scope.area.rawValue, areaPath = "areas/\(area)"
        try await http.denied("GET", areaPath, token: c.token, body: Empty(), status: 404, "excluded C")
        let notFound = try await http.send("GET", "areas/\(UUID())", token: c.token, body: Empty())
        let excluded = try await http.send("GET", areaPath, token: c.token, body: Empty())
        try check(notFound.1 == excluded.1, "unknown and excluded areas have identical response bytes")
        let invite = try await http.value(Collaboration.Invitation.self, "POST", areaPath + "/invitations", token: a.token, body: Collaboration.InviteRequest(person: b.identity.person), status: 201)
        try await http.denied("POST", "invitations/accept", token: c.token, body: Collaboration.AcceptInvitation(code: invite.code), status: 410, "forwarded invitation")
        async let join1 = http.value(Collaboration.Scope.self, "POST", "invitations/accept", token: b.token, body: Collaboration.AcceptInvitation(code: invite.code))
        async let join2 = http.value(Collaboration.Scope.self, "POST", "invitations/accept", token: b.token, body: Collaboration.AcceptInvitation(code: invite.code))
        let scopes = try await (join1, join2)
        try check(scopes.0.area == scopes.1.area && scopes.0.role == .editor, "invitation race recovers same membership")
        let thread = SharedArea.Item(id: .init(), kind: .discussion)
        let position = SharedArea.Position(id: .init(), object: thread.id, rect: .init(x: 0, y: 0, width: 640, height: 520))
        let initial = SharedArea.Command(area: first.scope.area, expectedRevision: 0, edits: [.admit(thread, position), .post(.init(id: .init(), object: thread.id, author: a.identity.person, text: "shared-content-sentinel"))])
        let receipt = try await http.value(Collaboration.Receipt.self, "POST", areaPath + "/commands", token: a.token, body: Collaboration.Mutation(epoch: first.scope.epoch, command: initial))
        try check(receipt.revision == 1 && !receipt.duplicate, "authenticated durable area command")
        let retry = try await http.value(Collaboration.Receipt.self, "POST", areaPath + "/commands", token: a.token, body: Collaboration.Mutation(epoch: 1, command: initial))
        try check(retry.revision == 1 && retry.duplicate, "network retry returns original receipt")
        let observed = try await http.value(Collaboration.State.self, "GET", areaPath, token: b.token, body: Empty())
        try check(observed.document.posts.first?.text == "shared-content-sentinel", "invited B receives shared history")
        let forged = SharedArea.Command(area: first.scope.area, expectedRevision: 1, edits: [.post(.init(id: .init(), object: thread.id, author: a.identity.person, text: "forged"))])
        try await http.denied("POST", areaPath + "/commands", token: b.token, body: Collaboration.Mutation(epoch: 1, command: forged), status: 403, "forged authorship")
        let ownPost = SharedArea.Command(area: first.scope.area, expectedRevision: 1, edits: [.post(.init(id: .init(), object: thread.id, author: b.identity.person, text: "B contribution"))])
        _ = try await http.value(Collaboration.Receipt.self, "POST", areaPath + "/commands", token: b.token, body: Collaboration.Mutation(epoch: 1, command: ownPost))
        let hostA = try await http.value(Collaboration.Host.self, "POST", "hosts", token: a.token, body: Empty(), status: 201)
        let forgedSource = SharedArea.Item(id: .init(), kind: .agentObservation, source: .init(owner: a.identity.person, host: hostA.id, binding: .init()))
        let sourceCommand = SharedArea.Command(area: first.scope.area, expectedRevision: 2, edits: [.admit(forgedSource, .init(id: .init(), object: forgedSource.id, rect: position.rect))])
        try await http.denied("POST", areaPath + "/commands", token: b.token, body: Collaboration.Mutation(epoch: 1, command: sourceCommand), status: 403, "publishing another host")
        try await http.denied("POST", areaPath + "/commands", token: a2.token, body: Collaboration.Mutation(epoch: 1, command: sourceCommand), status: 403, "same person cannot claim another device host")
        // Abort after the snapshot write, during operation insertion. GRDB must
        // roll back both, and retrying the same operation must still work.
        let triggerDB = try DatabaseQueue(path: path)
        try await triggerDB.write { db in
            try db.execute(sql: "CREATE TRIGGER reject_operation BEFORE INSERT ON operations BEGIN SELECT RAISE(ABORT,'injected storage failure'); END")
        }
        try await http.denied("POST", areaPath + "/commands", token: a.token,
            body: Collaboration.Mutation(epoch: 1, command: sourceCommand), status: 500, "transaction failure")
        let rolledBack = try await http.value(Collaboration.State.self, "GET", areaPath, token: a.token, body: Empty())
        try check(rolledBack.document.revision == 2 && !rolledBack.document.items.contains(where: { $0.id == forgedSource.id }), "storage failure rolls back snapshot and receipt")
        try await triggerDB.write { try $0.execute(sql: "DROP TRIGGER reject_operation") }
        let published = try await http.value(Collaboration.Receipt.self, "POST", areaPath + "/commands", token: a.token,
            body: Collaboration.Mutation(epoch: 1, command: sourceCommand))
        try check(published.revision == 3 && !published.duplicate, "retry after rollback commits once")
        let reusedByB = SharedArea.Command(area: first.scope.area, id: sourceCommand.id, expectedRevision: 2, edits: [.remove(thread.id)])
        try await http.denied("POST", areaPath + "/commands", token: b.token, body: Collaboration.Mutation(epoch: 1, command: reusedByB), status: 409, "operation identity bound to actor")
        let other = try await http.value(Collaboration.State.self, "POST", "areas", token: a.token, body: Empty(), status: 201)
        try await http.denied("POST", "areas/\(other.scope.area.rawValue)/commands", token: a.token, body: Collaboration.Mutation(epoch: 1, command: ownPost), status: 404, "cross-area command")
        let viewerInvite = try await http.value(Collaboration.Invitation.self, "POST", "areas/\(other.scope.area.rawValue)/invitations", token: a.token, body: Collaboration.InviteRequest(person: c.identity.person, role: .viewer), status: 201)
        _ = try await http.value(Collaboration.Scope.self, "POST", "invitations/accept", token: c.token, body: Collaboration.AcceptInvitation(code: viewerInvite.code))
        try await http.denied("POST", "areas/\(other.scope.area.rawValue)/commands", token: c.token, body: Collaboration.Mutation(epoch: 1, command: .init(area: other.scope.area, expectedRevision: 0, edits: [])), status: 403, "viewer cannot edit")
        let expiryInvite = try await http.value(Collaboration.Invitation.self, "POST", areaPath + "/invitations", token: a.token, body: Collaboration.InviteRequest(person: c.identity.person, lifetime: 1), status: 201)
        clock.advance(2)
        try await http.denied("POST", "invitations/accept", token: c.token, body: Collaboration.AcceptInvitation(code: expiryInvite.code), status: 410, "expired invitation under injected clock")
        let remove = try await http.send("DELETE", areaPath + "/members/\(b.identity.person.rawValue)", token: a.token, epoch: 1, body: Empty())
        try check(remove.0 == 200, "owner removes teammate")
        let staleRemoval = try await http.send("DELETE", areaPath + "/members/\(b.identity.person.rawValue)", token: a.token, epoch: 1, body: Empty())
        try check(staleRemoval.0 == 409, "stale membership removal cannot affect a later generation")
        try await http.denied("GET", areaPath, token: b.token, body: Empty(), status: 404, "removed B loses history access")
        try await http.denied("POST", areaPath + "/commands", token: b.token, body: Collaboration.Mutation(epoch: 1, command: ownPost), status: 404, "removed B cannot recover old receipt")
        try await http.denied("POST", "invitations/accept", token: b.token, body: Collaboration.AcceptInvitation(code: invite.code), status: 404, "old invitation cannot restore removed B")
        try await http.denied("POST", areaPath + "/commands", token: a.token, body: Collaboration.Mutation(epoch: 1, command: initial), status: 409, "membership change invalidates queued epoch")
        let current = try await http.value(Collaboration.State.self, "GET", areaPath, token: a2.token, body: Empty())
        try check(current.scope.epoch == 2 && current.document.revision == 3, "epoch changes without altering document history")
        _ = try await http.send("DELETE", "devices/\(a2.identity.device)", token: a.token, body: Empty())
        try await http.denied("GET", areaPath, token: a2.token, body: Empty(), status: 401, "device revocation reauthenticates cached bearer")
        let recovered = try CollaborationStore(path: path, masterKey: key, clock: { clock.now() })
        let recoveredState = try await recovered.state(token: a.token, area: area)
        try check(try recoveredState.document.canonicalData() == current.document.canonicalData(), "SQLite restart restores exact document and membership")
        do { _ = try await recovered.state(token: b.token, area: area); throw Failure(message: "removed member survived restart") }
        catch CollaborationStoreError.unavailable { print("PASS: removal survives restart") }
        let storedFiles = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("collaboration.sqlite") }
        for file in storedFiles {
            let storage = try Data(contentsOf: file)
            try check(storage.range(of: Data("shared-content-sentinel".utf8)) == nil && storage.range(of: Data(a.token.utf8)) == nil, "database/journal excludes plaintext content and credentials")
        }
        // Existing v2 route still authenticates its own companion credentials.
        let alpha = try await companion.createAlphaInvite(expiresAt: Date().addingTimeInterval(60))
        let desktop = try await companion.redeemAlphaInvite(.init(code: alpha.code, deviceLabel: "Compatibility"))
        let v2 = HTTP(base: URL(string: "http://127.0.0.1:\(server.listeningPublicPort!)/v2")!)
        let compatible = try await v2.send("GET", "devices", token: desktop.credential, body: Empty())
        try check(compatible.0 == 200, "companion v2 remains functional")
        try await http.denied("GET", areaPath, token: desktop.credential, body: Empty(), status: 401, "companion credential is not collaboration identity")
        try await server.stop()
        let restarted = RelayServer(store: companion, configuration: .init(host: "127.0.0.1", publicPort: 0, adminPort: 0), collaboration: recovered)
        try await restarted.start()
        do {
            let secondHTTP = HTTP(base: URL(string: "http://127.0.0.1:\(restarted.listeningPublicPort!)/collaboration/v1")!)
            let fromRestart = try await secondHTTP.value(Collaboration.State.self, "GET", areaPath, token: a.token, body: Empty())
            try check(try fromRestart.document.canonicalData() == current.document.canonicalData(), "reconstructed HTTP service preserves discussion and layout")
            try await secondHTTP.denied("GET", areaPath, token: b.token, body: Empty(), status: 404, "reconstructed service preserves removal")
            try await restarted.stop()
        } catch { try? await restarted.stop(); throw error }
    } catch { try? await server.stop(); throw error }
    print("Collaboration service checks passed: real localhost HTTP, isolated SQLite and A/B/C; no native scene/host-execution claims.")
}
do {
    if CommandLine.arguments.contains("--retention-only") {
        try await runCollaborationRetentionChecks()
    } else if CommandLine.arguments.contains("--artifacts-only") {
        try await runCollaborationArtifactChecks()
    } else if CommandLine.arguments.contains("--boundary-audit-only") {
        try await runCollaborationBoundaryAuditChecks()
    } else if CommandLine.arguments.contains("--backup-restore-only") {
        try await runCollaborationBackupRestoreChecks()
        try await runCollaborationOperatorRecoveryChecks()
    } else if CommandLine.arguments.contains("--recovery-scale-only") {
        try await runCollaborationRecoveryScaleChecks()
    } else if CommandLine.arguments.contains("--host-liveness-only") {
        try await runCollaborationHostLivenessChecks()
    } else if CommandLine.arguments.contains("--capabilities-only") {
        try await runCollaborationCapabilityChecks()
    } else {
        if !CommandLine.arguments.contains("--updates-only") && !CommandLine.arguments.contains("--client-boundaries-only") { try await run() }
        if CommandLine.arguments.contains("--client-boundaries-only") {
            try await runCollaborationClientBoundaryChecks()
        } else {
            try await runCollaborationUpdatesChecks()
            try await runCollaborationClientBoundaryChecks()
        }
        try await runCollaborationDatabaseKeyChecks()
        if !CommandLine.arguments.contains("--client-boundaries-only") { try await runCollaborationCapabilityChecks() }
        if !CommandLine.arguments.contains("--client-boundaries-only") { try await runCollaborationHandoffChecks(); try await runCollaborationUsageChecks(); try await runCollaborationEndorsementChecks() }
        if !CommandLine.arguments.contains("--client-boundaries-only") { try await runCollaborationRecoveryScaleChecks() }
        if !CommandLine.arguments.contains("--client-boundaries-only") { try await runCollaborationRetentionChecks() }
        if !CommandLine.arguments.contains("--client-boundaries-only") { try await runCollaborationArtifactChecks() }
        if !CommandLine.arguments.contains("--client-boundaries-only") { try await runCollaborationBoundaryAuditChecks() }
        if !CommandLine.arguments.contains("--client-boundaries-only") { try await runCollaborationBackupRestoreChecks(); try await runCollaborationOperatorRecoveryChecks() }
        if !CommandLine.arguments.contains("--client-boundaries-only") { try await runCollaborationHostLivenessChecks() }
    }
} catch { print("FAIL: \(error)"); exit(1) }
