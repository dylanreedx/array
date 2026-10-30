import Foundation
import GRDB
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
    process.arguments = path.isEmpty ? [command] : [command, path]
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
    // A tight retention window so the area written during the backup compacts:
    // the backup then carries a horizon snapshot, a short tail and receipts.
    let retention = CollaborationRetention(operationTail: 8, operationAge: 0, compactionBatch: 16)
    let store = try CollaborationStore(path: live, masterKey: key, clock: { clock.now() }, retention: retention)
    let companion = try RelayStore(path: root.appendingPathComponent("companion.sqlite").path, masterKey: key)
    let server = RelayServer(store: companion, configuration: .init(host: "127.0.0.1", publicPort: 0, adminPort: 0), collaboration: store)
    try await server.start()
    let liveEndpoint = URL(string: "http://127.0.0.1:\(server.listeningPublicPort!)")!

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

    // An artifact revision with its sealed blob and a teammate's review.
    typealias A = Collaboration.Artifact
    let artifact = SharedArea.Item(id: .init(), kind: .artifact, source: .init(owner: a.identity.person, host: hostA.id, binding: .init()))
    _ = try await store.apply(token: a.token, area: area1, request: .init(epoch: 1, command: .init(area: one.document.id, expectedRevision: 2, edits: [
        .admit(artifact, .init(id: .init(), object: artifact.id, rect: .init(x: 0, y: 400, width: 320, height: 240)))])))
    let artifactText = Data("@@ -1 +1 @@\n-old\n+backup-artifact-sentinel\n".utf8), artifactDigest = A.digest(artifactText)
    let manifest = A.Manifest(object: artifact.id, parent: nil, kind: .diff, base: .init(head: String(repeating: "a", count: 40)),
        declaration: .init(range: .workingTree, includesCommitted: false, includesStaged: true, includesUnstaged: true,
                           includesUntracked: false, omittedChangedPaths: 0, omittedUntrackedPaths: 0),
        entries: [.init(path: "src/main.swift", change: .modified, coverage: .included, blob: artifactDigest, length: artifactText.count,
                        mediaType: "text/x-diff", sourceDigest: String(repeating: "b", count: 64))],
        capturedAt: 1_800_000_000_000)
    let liveA = try CollaborationAPI(baseURL: liveEndpoint, credential: a.token, allowsInsecureLoopback: true)
    let liveB = try CollaborationAPI(baseURL: liveEndpoint, credential: b.token, allowsInsecureLoopback: true)
    _ = try await liveA.publishArtifact(area: area1, epoch: 1, capture: .init(manifest: manifest, blobs: [artifactDigest: artifactText]))
    let review = try await liveB.reviewArtifact(area: area1, object: artifact.id.rawValue,
        request: .init(epoch: 1, revision: manifest.id, verdict: .approve, note: "Reviewed before the backup"))

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
    let boardCommand = SharedArea.Command(area: three.document.id, expectedRevision: 0, edits: [
        .admit(board, .init(id: .init(), object: board.id, rect: .init(x: 0, y: -300, width: 300, height: 200)))])
    _ = try await store.apply(token: b.token, area: area3, request: .init(epoch: 1, command: boardCommand))
    // Enough history that area 3 compacts before the backup, whatever the
    // concurrent writer below manages to add.
    for index in 0..<40 {
        _ = try await store.apply(token: a.token, area: area3, request: .init(epoch: 1, command: .init(area: three.document.id,
            expectedRevision: UInt64(index + 1), edits: [.post(.init(id: .init(), object: board.id, author: a.identity.person, text: "history \(index)"))])))
    }
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
        && report.agentDispatches == 1 && report.agentControls == 1 && report.usageReports == 1 && report.invitations == 6
        && report.artifactBlobs == 1 && report.artifactRevisions == 1 && report.artifactReviews == 1,
        "backup report counts every area, person, revocation, removal, dispatch, usage and artifact row")
    try backupCheck(report.compactedAreas == 1 && report.receipts > report.operations,
        "the backup carries a compacted area: horizon snapshot, short tail and every operation receipt (\(report.receipts) receipts, \(report.operations) retained operations)")
    let attributes = try fileManager.attributesOfItem(atPath: backupPath)
    try backupCheck((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "backup file is private to the operator account")
    let backupBytes = try Data(contentsOf: URL(fileURLWithPath: backupPath))
    try backupCheck(backupBytes.range(of: Data(sentinel.utf8)) == nil && backupBytes.range(of: Data(a.token.utf8)) == nil
        && backupBytes.range(of: Data("backup-artifact-sentinel".utf8)) == nil
        && backupBytes.range(of: Data(pending.code.utf8)) == nil, "backup bytes exclude plaintext content, bearer tokens and invitation codes")
    try backupCheck(!fileManager.fileExists(atPath: (companionNever as NSString).deletingLastPathComponent), "operator commands never open the companion database")
    let leftovers = try fileManager.contentsOfDirectory(atPath: (backupPath as NSString).deletingLastPathComponent)
    try backupCheck(leftovers == ["collaboration-backup.sqlite"], "backup leaves no partial file beside the published copy")

    let again = try await operatorCommand("--collaboration-backup", backupPath, live: live, key: key, companion: companionNever)
    try backupCheck(again.status != 0 && (try Data(contentsOf: URL(fileURLWithPath: backupPath))) == backupBytes, "backup refuses to overwrite an existing backup")
    let wrongVerify = try await operatorCommand("--collaboration-verify-backup", backupPath, live: live, key: wrongKey, companion: companionNever)
    try backupCheck(wrongVerify.status != 0, "verification with a different master key refuses")
    // Tampering that every ciphertext still authenticates through: only the
    // horizon+tail replay and the artifact AAD/digest audit can see these.
    func tampered(_ name: String, _ sql: String) async throws -> Int32 {
        let path = root.appendingPathComponent("backups-damaged/\(name).sqlite").path
        try fileManager.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try fileManager.copyItem(atPath: backupPath, toPath: path)
        let database = try DatabaseQueue(path: path)
        try await database.write { try $0.execute(sql: sql) }
        try database.close()
        return try await operatorCommand("--collaboration-verify-backup", path, live: live, key: key, companion: companionNever).status
    }
    let gap = try await tampered("tail-gap", "DELETE FROM operations WHERE area='\(area3.uuidString)' AND revision=(SELECT MAX(revision) FROM operations WHERE area='\(area3.uuidString)')-1")
    try backupCheck(gap != 0, "verification refuses a backup missing one retained operation of a compacted area")
    let relabelled = try await tampered("blob-relabel", "UPDATE collaboration_artifact_blobs SET digest='\(String(repeating: "f", count: 64))'")
    try backupCheck(relabelled != 0, "verification refuses an artifact blob relabelled to another digest")
    var damaged = backupBytes
    // A slice of every page after the header, so the damage cannot fall in
    // free space by luck of page layout (it did, once, on Linux).
    for page in stride(from: 4096, to: damaged.count, by: 4096) {
        for offset in (page + 128)..<min(page + 640, damaged.count) { damaged[offset] ^= 0x5A }
    }
    let damagedPath = root.appendingPathComponent("backups-damaged/damaged.sqlite").path
    try fileManager.createDirectory(atPath: (damagedPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try damaged.write(to: URL(fileURLWithPath: damagedPath))
    let damagedVerify = try await operatorCommand("--collaboration-verify-backup", damagedPath, live: live, key: key, companion: companionNever)
    try backupCheck(damagedVerify.status != 0, "verification refuses a backup with damaged pages")
    let verified = try await operatorCommand("--collaboration-verify-backup", backupPath, live: live, key: key, companion: companionNever)
    try backupCheck(verified.status == 0 && verified.report == report, "verification of the published backup reproduces its report")

    // Work after the backup point: lost by restore, by design.
    _ = try await store.apply(token: a.token, area: area1, request: .init(epoch: 1, command: .init(area: one.document.id, expectedRevision: 3, edits: [
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
    let restoredStore = try CollaborationStore(path: replacement, masterKey: key, clock: { clock.now() }, retention: retention)
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
        let compactedRetry = try await bb.apply(area: area3, mutation: .init(epoch: 1, command: boardCommand))
        try backupCheck(compactedRetry.duplicate && compactedRetry.revision == 1, "a command compacted out of the log before the backup still dedupes by its receipt")
        let integrity = try await restoredStore.verifyIntegrity()
        try backupCheck((integrity.horizons[area3] ?? 0) > 0, "the restored compacted area rebuilds its head from horizon plus tail")
        let artifactRead = try await bb.readArtifact(area: area1, object: artifact.id.rawValue, revision: manifest.id.rawValue)
        let artifactState = try await bb.artifactState(area: area1, object: artifact.id.rawValue)
        try backupCheck(artifactRead.bytes["src/main.swift"] == artifactText && artifactRead.record.contentDigest == manifest.contentDigest
            && artifactState.reviews.contains { $0.review == review && $0.review.revision == manifest.id },
            "the artifact's exact bytes, digest and revision-pinned review survive restore")
        try await refuses(404, "excluded C cannot read the restored artifact") { _ = try await cc.readArtifact(area: area1, object: artifact.id.rawValue) }
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

/// Existing-account recovery through the operator command: the lost devices
/// die, the same person ID gets one enrollment, and membership survives.
func runCollaborationOperatorRecoveryChecks() async throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent("array-collaboration-recovery-\(UUID())")
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: root) }
    let key = Data(repeating: 81, count: 32)
    let live = root.appendingPathComponent("collaboration.sqlite").path
    let companionNever = root.appendingPathComponent("companion-never/relay.sqlite").path
    let store = try CollaborationStore(path: live, masterKey: key)
    let companion = try RelayStore(path: root.appendingPathComponent("companion.sqlite").path, masterKey: key)
    let server = RelayServer(store: companion, configuration: .init(host: "127.0.0.1", publicPort: 0, adminPort: 0), collaboration: store)
    try await server.start()
    do {
        let endpoint = URL(string: "http://127.0.0.1:\(server.listeningPublicPort!)")!
        func enroll(_ label: String) async throws -> Collaboration.Credential {
            let code = try await store.provisionPerson(label: label)
            return try await CollaborationAPI(baseURL: endpoint, allowsInsecureLoopback: true).redeem(code: code.code, deviceLabel: label)
        }
        func refuses(_ code: Int, _ label: String, _ action: () async throws -> Void) async throws {
            do { try await action(); throw BackupCheckFailure(message: "\(label) unexpectedly succeeded") }
            catch let error as CollaborationClientError {
                guard case .server(let actual, _) = error, actual == code else { throw BackupCheckFailure(message: "\(label): \(error)") }
                print("PASS operator recovery: \(label)")
            }
        }
        let a = try await enroll("Recovery A"), b = try await enroll("Recovery B")
        let aa = try CollaborationAPI(baseURL: endpoint, credential: a.token, allowsInsecureLoopback: true)
        let bb = try CollaborationAPI(baseURL: endpoint, credential: b.token, allowsInsecureLoopback: true)
        let state = try await aa.createArea(), area = state.document.id.rawValue
        _ = try await bb.accept(code: try await aa.invite(area: area, request: .init(person: b.identity.person)).code)
        let host = try await aa.registerHost()
        let agent = SharedArea.Item(id: .init(), kind: .agentObservation, source: .init(owner: a.identity.person, host: host.id, binding: .init()))
        _ = try await aa.apply(area: area, mutation: .init(epoch: 1, command: .init(area: state.document.id, expectedRevision: 0, edits: [
            .admit(agent, .init(id: .init(), object: agent.id, rect: .init(x: 0, y: 0, width: 300, height: 200)))])))
        let before = try await aa.state(area: area)
        let lostSibling = try await store.enrollDevice(token: a.token, lifetime: 600)

        let listed = try await operatorCommand("--collaboration-list-people", "", live: live, key: key, companion: companionNever)
        let people = try JSONDecoder().decode([CollaborationPersonSummary].self, from: Data((listed.output.split(separator: "\n").first ?? "").utf8))
        try backupCheck(listed.status == 0 && people.contains { $0.person == a.identity.person.rawValue && $0.label == "Recovery A" && $0.activeDevices == 1 && $0.areas == 1 },
            "operator roster lists each person with device and area counts")
        try backupCheck(!listed.output.contains(a.token) && !listed.output.contains(lostSibling.code), "roster output carries no bearer token or enrollment code")
        let unknown = try await operatorCommand("--collaboration-recover-person", UUID().uuidString, live: live, key: key, companion: companionNever)
        try backupCheck(unknown.status != 0, "recovering an unknown person ID refuses")
        let recovered = try await operatorCommand("--collaboration-recover-person", a.identity.person.rawValue.uuidString, live: live, key: key, companion: companionNever)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let enrollment = try decoder.decode(Collaboration.Enrollment.self, from: Data((recovered.output.split(separator: "\n").first ?? "").utf8))
        try backupCheck(recovered.status == 0 && enrollment.person == a.identity.person, "recovery issues an enrollment for the SAME person ID, not a new account")
        try await refuses(401, "the lost device's credential is revoked by recovery") { _ = try await aa.state(area: area) }
        try await refuses(410, "an enrollment the lost device issued earlier is dead") {
            _ = try await CollaborationAPI(baseURL: endpoint, allowsInsecureLoopback: true).redeem(code: lostSibling.code, deviceLabel: "Thief")
        }
        let replacement = try await CollaborationAPI(baseURL: endpoint, allowsInsecureLoopback: true).redeem(code: enrollment.code, deviceLabel: "Replacement Mac")
        try backupCheck(replacement.identity.person == a.identity.person && replacement.identity.device != a.identity.device, "the replacement Mac redeems into the original person")
        let restoredClient = try CollaborationAPI(baseURL: endpoint, credential: replacement.token, allowsInsecureLoopback: true)
        let after = try await restoredClient.state(area: area)
        try backupCheck(after.scope.role == before.scope.role && (try after.document.canonicalData()) == (try before.document.canonicalData()),
            "the replacement device keeps area ownership and sees the unchanged document")
        try await refuses(410, "the recovery enrollment cannot be replayed") {
            _ = try await CollaborationAPI(baseURL: endpoint, allowsInsecureLoopback: true).redeem(code: enrollment.code, deviceLabel: "Replay")
        }
        let teammate = try await bb.state(area: area)
        try backupCheck(teammate.document.revision == before.document.revision, "recovery leaves other people's devices untouched")
        try backupCheck(!fileManager.fileExists(atPath: (companionNever as NSString).deletingLastPathComponent), "recovery commands never open the companion database")
        try await server.stop()
    } catch { try? await server.stop(); throw error }
    print("Collaboration operator recovery checks passed: roster, same-person recovery, lost-device revocation and preserved membership.")
}
