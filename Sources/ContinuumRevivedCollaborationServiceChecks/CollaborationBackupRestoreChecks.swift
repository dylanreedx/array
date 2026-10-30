import Foundation
import ContinuumRevivedCollaborationProtocol
import ContinuumRevivedCollaborationClient
import ContinuumRevivedCollaborationService
import ContinuumRevivedRelayCore
import ContinuumRevivedRelayNIO

private struct BackupCheckFailure: Error { let message: String }
private func backupCheck(_ value: Bool, _ label: String) throws {
    guard value else { throw BackupCheckFailure(message: label) }
    print("PASS backup/restore: \(label)")
}
private final class BackupClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date()
    func now() -> Date { lock.withLock { date } }
    func advance(_ seconds: TimeInterval) { lock.withLock { date = date.addingTimeInterval(seconds) } }
}
private final class Flag: @unchecked Sendable {
    private let lock = NSLock(); private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}
private struct OperatorRun { let status: Int32; let report: CollaborationBackupReport?; let output: String }

/// Runs the shipped `continuum-relay` operator command with only the
/// collaboration database configured. The companion path points into a
/// directory that must never be created.
private func operatorCommand(_ command: String, _ path: String, live: String, key: Data, companion: String) async throws -> OperatorRun {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("continuum-relay")
    process.arguments = [command, path]
    var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("RELAY_") && !$0.key.hasPrefix("APNS_") }
    environment["RELAY_COLLABORATION_DATABASE_PATH"] = live
    environment["RELAY_COLLABORATION_MASTER_KEY"] = key.base64EncodedString()
    environment["RELAY_DATABASE_PATH"] = companion
    process.environment = environment
    let output = Pipe(); process.standardOutput = output; process.standardError = output
    let status: Int32 = try await withCheckedThrowingContinuation { continuation in
        process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
        do { try process.run() } catch { process.terminationHandler = nil; continuation.resume(throwing: error) }
    }
    let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    let first = text.split(separator: "\n").first.map(String.init) ?? ""
    let report = status == 0 ? try? JSONDecoder().decode(CollaborationBackupReport.self, from: Data(first.utf8)) : nil
    return .init(status: status, report: report, output: text)
}

/// A disposable multi-area dataset, backed up online through the operator
/// command while the live relay is serving writes, restored into a replacement
/// directory and in place, then read back through the real HTTP routes.
func runCollaborationBackupRestoreChecks() async throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent("array-collaboration-backup-\(UUID())")
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: root) }
    let key = Data(repeating: 77, count: 32), wrongKey = Data(repeating: 78, count: 32), clock = BackupClock()
    let live = root.appendingPathComponent("live/collaboration.sqlite").path
    let companionNever = root.appendingPathComponent("companion-never/relay.sqlite").path
    let backupPath = root.appendingPathComponent("backups/collaboration-backup.sqlite").path
    try fileManager.createDirectory(atPath: (live as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    let store = try CollaborationStore(path: live, masterKey: key, clock: { clock.now() })
    let companion = try RelayStore(path: root.appendingPathComponent("companion.sqlite").path, masterKey: key)
    let server = RelayServer(store: companion, configuration: .init(host: "127.0.0.1", publicPort: 0, adminPort: 0), collaboration: store)
    try await server.start()

    func enroll(_ label: String) async throws -> Collaboration.Credential {
        let code = try await store.provisionPerson(label: label)
        return try await store.redeem(.init(code: code.code, deviceLabel: label))
    }
    func extraDevice(_ owner: Collaboration.Credential, _ label: String) async throws -> Collaboration.Credential {
        let code = try await store.enrollDevice(token: owner.token, lifetime: 600)
        return try await store.redeem(.init(code: code.code, deviceLabel: label))
    }
    let a = try await enroll("Backup A"), b = try await enroll("Backup B"), c = try await enroll("Backup C"), d = try await enroll("Backup D")
    let aRevokedBefore = try await extraDevice(a, "A device revoked before backup")
    let aRevokedAfter = try await extraDevice(a, "A device revoked after backup")
    let sentinel = "backup-content-sentinel"

    // Area 1: discussion, agreement revisions, a published agent, an accepted
    // handoff dispatch and durable usage.
    let one = try await store.createArea(token: a.token), area1 = one.document.id.rawValue
    let invite1 = try await store.invite(token: a.token, area: area1, request: .init(person: b.identity.person))
    _ = try await store.accept(token: b.token, code: invite1.code)
    let hostA = try await store.registerHost(token: a.token)
    let thread = SharedArea.Item(id: .init(), kind: .discussion), agreement = SharedArea.Item(id: .init(), kind: .agreement)
    let agent = SharedArea.Item(id: .init(), kind: .agentObservation, source: .init(owner: a.identity.person, host: hostA.id, binding: .init()))
    let r1 = SharedArea.Context(id: .init(), object: agreement.id, parent: nil, author: a.identity.person, text: "First agreement revision")
    let firstCommand = SharedArea.Command(area: one.document.id, expectedRevision: 0, edits: [
        .admit(thread, .init(id: .init(), object: thread.id, rect: .init(x: -400, y: 0, width: 320, height: 240))),
        .admit(agreement, .init(id: .init(), object: agreement.id, rect: .init(x: 0, y: 0, width: 320, height: 240))),
        .admit(agent, .init(id: .init(), object: agent.id, rect: .init(x: 400, y: 0, width: 320, height: 240))),
        .post(.init(id: .init(), object: thread.id, author: a.identity.person, text: sentinel)), .context(r1)])
    _ = try await store.apply(token: a.token, area: area1, request: .init(epoch: 1, command: firstCommand))
    let r2 = SharedArea.Context(id: .init(), object: agreement.id, parent: r1.id, author: b.identity.person, text: "Second agreement revision")
    _ = try await store.apply(token: b.token, area: area1, request: .init(epoch: 1, command: .init(area: one.document.id, expectedRevision: 1, edits: [
        .post(.init(id: .init(), object: thread.id, author: b.identity.person, text: "B reply")), .context(r2)])))
    let generation = UUID()
    var control = try await store.registerAgentHost(token: a.token, area: area1, request: .init(epoch: 1, object: agent.id, generation: generation))
    let offer = Collaboration.AgentHandoffOffer(id: UUID(), recipient: b.identity.person)
    control = try await store.changeAgentControl(token: a.token, area: area1, object: agent.id,
        request: .init(epoch: 1, expectedRevision: control.revision, hostGeneration: generation, action: .offer(offer)))
    control = try await store.changeAgentControl(token: b.token, area: area1, object: agent.id,
        request: .init(epoch: 1, expectedRevision: control.revision, hostGeneration: generation, action: .accept(offer: offer.id)))
    let prompt = try await store.enqueueAgentPrompt(token: b.token, area: area1, object: agent.id, request: .init(epoch: 1,
        controlRevision: control.revision, hostGeneration: generation, contextRevision: r2.id, text: "Handed-off prompt"))
    let claim = Collaboration.AgentHostClaim(claimID: UUID(), hostGeneration: generation)
    _ = try await store.claimAgentDispatch(token: a.token, area: area1, id: prompt.command.id, claim: claim)
    _ = try await store.claimAgentDispatch(token: a.token, area: area1, id: prompt.command.id, claim: claim, admit: true)
    let accepted = try await store.finishAgentDispatch(token: a.token, area: area1, id: prompt.command.id, outcome: .init(claim: claim, phase: .accepted))
    let now = clock.now()
    try await store.reportUsage(token: a.token, area: area1, report: .init(epoch: 1, snapshot: .init(host: hostA.id, sequence: 1,
        inputTokens: 200, outputTokens: 40, todayInputTokens: 200, todayOutputTokens: 40, dayUTC: "2026-10-30",
        observedSince: now, measuredAt: now, coveredAgents: 1, runningAgents: 0, partial: false)))

    // Area 2: a viewer, and a teammate who joined and was then removed.
    let two = try await store.createArea(token: a.token), area2 = two.document.id.rawValue
    let viewer = try await store.invite(token: a.token, area: area2, request: .init(person: c.identity.person, role: .viewer))
    _ = try await store.accept(token: c.token, code: viewer.code)
    let removed = try await store.invite(token: a.token, area: area2, request: .init(person: b.identity.person))
    _ = try await store.accept(token: b.token, code: removed.code)
    let note = SharedArea.Item(id: .init(), kind: .discussion)
    _ = try await store.apply(token: a.token, area: area2, request: .init(epoch: 1, command: .init(area: two.document.id, expectedRevision: 0, edits: [
        .admit(note, .init(id: .init(), object: note.id, rect: .init(x: 10, y: 10, width: 300, height: 200))),
        .post(.init(id: .init(), object: note.id, author: a.identity.person, text: "Area two note"))])))
    try await store.removeMember(token: a.token, area: area2, person: b.identity.person.rawValue, expectedEpoch: 1)

    // Area 3: owned by B, with a pending and an expired invitation.
    let three = try await store.createArea(token: b.token), area3 = three.document.id.rawValue
    let invite3 = try await store.invite(token: b.token, area: area3, request: .init(person: a.identity.person))
    _ = try await store.accept(token: a.token, code: invite3.code)
    let pending = try await store.invite(token: b.token, area: area3, request: .init(person: d.identity.person, lifetime: 86_400))
    let expired = try await store.invite(token: b.token, area: area3, request: .init(person: c.identity.person, lifetime: 1))
    clock.advance(2)
    let board = SharedArea.Item(id: .init(), kind: .discussion)
    _ = try await store.apply(token: b.token, area: area3, request: .init(epoch: 1, command: .init(area: three.document.id, expectedRevision: 0, edits: [
        .admit(board, .init(id: .init(), object: board.id, rect: .init(x: 0, y: -300, width: 300, height: 200)))])))
    try await store.revokeDevice(token: a.token, device: aRevokedBefore.identity.device)

    var expected: [UUID: (data: Data, epoch: Int64)] = [:]
    for (area, token) in [(area1, a.token), (area2, a.token)] {
        let state = try await store.state(token: token, area: area)
        expected[area] = (try state.document.canonicalData(), state.scope.epoch)
    }
    let area3Before = try await store.state(token: b.token, area: area3).document.revision

    // Online backup while a writer keeps committing to area 3.
    let stop = Flag()
    let writer = Task { () -> Int in
        var writes = 0
        while !stop.isSet {
            let head = try await store.state(token: a.token, area: area3).document.revision
            _ = try await store.apply(token: a.token, area: area3, request: .init(epoch: 1, command: .init(area: three.document.id,
                expectedRevision: head, edits: [.post(.init(id: .init(), object: board.id, author: a.identity.person, text: "concurrent \(writes)"))])))
            writes += 1
        }
        return writes
    }
    let made = try await operatorCommand("--collaboration-backup", backupPath, live: live, key: key, companion: companionNever)
    stop.set()
    let concurrentWrites = try await writer.value
    let area3After = try await store.state(token: b.token, area: area3).document.revision
    try backupCheck(made.status == 0 && fileManager.fileExists(atPath: backupPath), "operator backup command copies the live database while it serves writes (\(concurrentWrites) concurrent commits)")
    guard let report = made.report else { throw BackupCheckFailure(message: "backup printed no report: \(made.output)") }
    try backupCheck(report.areas == 3 && report.people == 4 && report.revokedDevices == 1 && report.removedMembers == 1
        && report.agentDispatches == 1 && report.agentControls == 1 && report.usageReports == 1 && report.invitations == 6,
        "backup report counts every area, person, revocation, removal, dispatch and usage row")
    let attributes = try fileManager.attributesOfItem(atPath: backupPath)
    try backupCheck((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "backup file is private to the operator account")
    let backupBytes = try Data(contentsOf: URL(fileURLWithPath: backupPath))
    try backupCheck(backupBytes.range(of: Data(sentinel.utf8)) == nil && backupBytes.range(of: Data(a.token.utf8)) == nil
        && backupBytes.range(of: Data(pending.code.utf8)) == nil, "backup bytes exclude plaintext content, bearer tokens and invitation codes")
    try backupCheck(!fileManager.fileExists(atPath: (companionNever as NSString).deletingLastPathComponent), "operator commands never open the companion database")
    let leftovers = try fileManager.contentsOfDirectory(atPath: (backupPath as NSString).deletingLastPathComponent)
    try backupCheck(leftovers == ["collaboration-backup.sqlite"], "backup leaves no partial file beside the published copy")

    let again = try await operatorCommand("--collaboration-backup", backupPath, live: live, key: key, companion: companionNever)
    try backupCheck(again.status != 0 && (try Data(contentsOf: URL(fileURLWithPath: backupPath))) == backupBytes, "backup refuses to overwrite an existing backup")
    let wrongVerify = try await operatorCommand("--collaboration-verify-backup", backupPath, live: live, key: wrongKey, companion: companionNever)
    try backupCheck(wrongVerify.status != 0, "verification with a different master key refuses")
    var damaged = backupBytes
    let middle = damaged.count / 2
    for offset in middle..<(middle + 512) { damaged[offset] ^= 0x5A }
    let damagedPath = root.appendingPathComponent("backups-damaged/damaged.sqlite").path
    try fileManager.createDirectory(atPath: (damagedPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try damaged.write(to: URL(fileURLWithPath: damagedPath))
    let damagedVerify = try await operatorCommand("--collaboration-verify-backup", damagedPath, live: live, key: key, companion: companionNever)
    try backupCheck(damagedVerify.status != 0, "verification refuses a backup with damaged pages")
    let verified = try await operatorCommand("--collaboration-verify-backup", backupPath, live: live, key: key, companion: companionNever)
    try backupCheck(verified.status == 0 && verified.report == report, "verification of the published backup reproduces its report")

    // Work after the backup point: lost by restore, by design.
    _ = try await store.apply(token: a.token, area: area1, request: .init(epoch: 1, command: .init(area: one.document.id, expectedRevision: 2, edits: [
        .post(.init(id: .init(), object: thread.id, author: a.identity.person, text: "written after the backup"))])))
    try await store.revokeDevice(token: a.token, device: aRevokedAfter.identity.device)
    try await server.stop()
    let liveAfterStop = try Data(contentsOf: URL(fileURLWithPath: live))

    // Restore into a replacement directory, as on a replacement machine.
    let replacement = root.appendingPathComponent("replacement/collaboration.sqlite").path
    let wrongRestore = try await operatorCommand("--collaboration-restore", backupPath, live: replacement, key: wrongKey, companion: companionNever)
    try backupCheck(wrongRestore.status != 0 && !fileManager.fileExists(atPath: replacement), "restore with the wrong key installs nothing")
    let restored = try await operatorCommand("--collaboration-restore", backupPath, live: replacement, key: key, companion: companionNever)
    try backupCheck(restored.status == 0 && !restored.output.contains("moved_aside"), "operator restore installs the backup in a replacement directory")
    let restoredStore = try CollaborationStore(path: replacement, masterKey: key, clock: { clock.now() })
    do { _ = try CollaborationStore(path: replacement, masterKey: wrongKey); throw BackupCheckFailure(message: "restored database opened with the wrong key") }
    catch CollaborationStoreError.invalidDatabaseKey { print("PASS backup/restore: restored database refuses a different master key") }
    let restoredServer = RelayServer(store: companion, configuration: .init(host: "127.0.0.1", publicPort: 0, adminPort: 0), collaboration: restoredStore)
    try await restoredServer.start()
    do {
        let endpoint = URL(string: "http://127.0.0.1:\(restoredServer.listeningPublicPort!)")!
        func client(_ token: String) throws -> CollaborationAPI { try CollaborationAPI(baseURL: endpoint, credential: token, allowsInsecureLoopback: true) }
        func refuses(_ code: Int, _ label: String, _ action: () async throws -> Void) async throws {
            do { try await action(); throw BackupCheckFailure(message: "\(label) unexpectedly succeeded") }
            catch let error as CollaborationClientError {
                guard case .server(let actual, _) = error, actual == code else { throw BackupCheckFailure(message: "\(label): \(error)") }
                print("PASS backup/restore: \(label)")
            }
        }
        let aa = try client(a.token), bb = try client(b.token), cc = try client(c.token), dd = try client(d.token)
        for (area, value) in expected {
            let state = try await aa.state(area: area)
            try backupCheck(try state.document.canonicalData() == value.data && state.scope.epoch == value.epoch,
                "restored HTTP service returns area \(area.uuidString.prefix(8)) byte-identical with its membership epoch")
        }
        let restoredOne = try await aa.state(area: area1)
        try backupCheck(!restoredOne.document.posts.contains { $0.text == "written after the backup" }, "a write after the backup point is absent: restore is point-in-time")
        let restoredThree = try await bb.state(area: area3)
        try backupCheck(restoredThree.document.revision >= area3Before && restoredThree.document.revision <= area3After
            && restoredThree.document.posts.count == Int(restoredThree.document.revision) - 1,
            "the area written during the backup restores one consistent revision (\(restoredThree.document.revision) of \(area3Before)...\(area3After))")
        let receipt = try await bb.agentDispatchReceipt(area: area1, id: prompt.command.id)
        try backupCheck(receipt == accepted && receipt.command.requester.person == b.identity.person, "accepted handoff receipt and its human attribution survive restore")
        let retry = try await aa.apply(area: area1, mutation: .init(epoch: 1, command: firstCommand))
        try backupCheck(retry.duplicate && retry.revision == 1, "an original command retried after restore returns its first receipt")
        try await refuses(401, "a device revoked before the backup stays revoked after restore") { _ = try await client(aRevokedBefore.token).state(area: area1) }
        try await refuses(404, "a member removed before the backup stays removed after restore") { _ = try await bb.state(area: area2) }
        try await refuses(404, "excluded C still cannot read area 1") { _ = try await cc.state(area: area1) }
        try await refuses(410, "a consumed invitation stays consumed after restore") { _ = try await cc.accept(code: invite1.code) }
        try await refuses(410, "an expired invitation stays expired after restore") { _ = try await cc.accept(code: expired.code) }
        _ = try await dd.accept(code: pending.code)
        let joined = try await dd.state(area: area3)
        try backupCheck(joined.scope.role == .editor, "an invitation pending at the backup point is still redeemable")
        // A revocation made after the backup point is NOT in the backup. The
        // operator must re-apply it; this witness pins that hazard.
        let resurrected = try await client(aRevokedAfter.token).state(area: area1)
        try backupCheck(resurrected.scope.area.rawValue == area1, "HAZARD pinned: a device revoked after the backup point is valid again until the operator re-revokes it")
        try await restoredStore.revokeDevice(token: a.token, device: aRevokedAfter.identity.device)
        try await refuses(401, "re-applying the post-backup revocation closes that device again") { _ = try await client(aRevokedAfter.token).state(area: area1) }
        let session = try await aa.beginPresence(area: area1)
        try await aa.publishPresence(area: area1, value: .init(session: session.id, sequence: 1, cursor: .init(x: 5, y: 5)))
        let updates = try await bb.updates(area: area1, request: .init(after: restoredOne.document.revision, waitMilliseconds: 0))
        let usage = updates.presence.first { $0.identity.person == a.identity.person }?.usage
        try backupCheck(usage?.inputTokens == 200 && usage?.outputTokens == 40, "durable usage totals survive restore without double counting")
        try await restoredServer.stop()
    } catch { try? await restoredServer.stop(); throw error }

    // In-place restore over the original path keeps the newer file aside.
    try Data().write(to: URL(fileURLWithPath: live + "-journal"))
    let hot = try await operatorCommand("--collaboration-restore", backupPath, live: live, key: key, companion: companionNever)
    try backupCheck(hot.status != 0 && (try Data(contentsOf: URL(fileURLWithPath: live))) == liveAfterStop, "restore refuses while a rollback journal shows an interrupted write")
    try fileManager.removeItem(atPath: live + "-journal")
    let inPlace = try await operatorCommand("--collaboration-restore", backupPath, live: live, key: key, companion: companionNever)
    try backupCheck(inPlace.status == 0 && inPlace.output.contains("moved_aside"), "in-place restore succeeds and reports the moved-aside database")
    try backupCheck((try Data(contentsOf: URL(fileURLWithPath: live + ".before-restore"))) == liveAfterStop, "the replaced database is kept byte-identical, never deleted")
    let reverified = try await operatorCommand("--collaboration-verify-backup", live, live: live, key: key, companion: companionNever)
    try backupCheck(reverified.status == 0 && reverified.report?.areas == 3, "the in-place restored database verifies")
    try backupCheck(!fileManager.fileExists(atPath: (companionNever as NSString).deletingLastPathComponent), "no operator command created the companion database")
    print("Collaboration backup/restore checks passed: online operator backup under writes, verification, replacement and in-place restore through the real HTTP service.")
}
