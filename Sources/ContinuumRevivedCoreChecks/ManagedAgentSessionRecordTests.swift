import ContinuumRevivedCore
import Foundation

func runManagedAgentSessionRecordTests() {
    do {
        try runManagedAgentSessionStoreContract()
        try runManagedSessionReconciliationContract()
        print("ManagedAgentSessionRecord checks: store contract, payload extraction, sync-boundary isolation, and the P3.1 launch sweep (isTerminal totality, v1 byte migration, double-sweep byte + backup identity) passed")
    } catch {
        fputs("FAIL: ManagedAgentSessionRecord checks failed: \(error)\n", stderr)
        Foundation.exit(1)
    }
}

private func runManagedAgentSessionStoreContract() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("continuum-managed-session-record-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let store = ManagedAgentSessionStore(projectRoot: root)
    let tileId = UUID(uuidString: "23000000-0000-4000-8000-000000000001")!
    let now = Date(timeIntervalSince1970: 1_800_000_001)
    let payload = try ManagedAgentSessionRecord.makeRuntimePayload(windowTarget: "%42", cwd: "/tmp/continuum")
    let cursor = Data([0x63, 0x75, 0x72, 0x73, 0x6f, 0x72])
    let record = ManagedAgentSessionRecord(
        tileId: tileId,
        agentKind: .claude,
        status: .running,
        lastSeenAt: now,
        resumeCursor: cursor,
        runtimePayload: payload
    )

    try store.upsert(record)
    guard let loaded = try store.load(tileId: tileId) else {
        throw ManagedSessionCheckError("round-trip load returned nil")
    }
    expect(loaded == record, "ManagedAgentSessionRecord round-trip preserves all fields")
    expect(loaded.tmuxWindowTarget() == "%42", "ManagedAgentSessionRecord extracts tmuxWindowTarget from runtimePayload")

    let stopped = ManagedAgentSessionRecord(
        tileId: tileId,
        agentKind: .claude,
        status: .stopped,
        lastSeenAt: Date(timeIntervalSince1970: 1_800_000_002),
        resumeCursor: cursor,
        runtimePayload: payload
    )
    try store.upsert(stopped)
    let upserted = try store.load(tileId: tileId)
    expect(upserted == stopped, "ManagedAgentSessionStore upsert overwrites same tile record")

    try store.delete(tileId: tileId)
    let deleted = try store.load(tileId: tileId)
    let missing = try store.load(tileId: UUID(uuidString: "23000000-0000-4000-8000-000000000099")!)
    expect(deleted == nil, "ManagedAgentSessionStore delete removes record")
    expect(missing == nil, "ManagedAgentSessionStore missing file returns nil")

    let ids = [
        UUID(uuidString: "23000000-0000-4000-8000-000000000011")!,
        UUID(uuidString: "23000000-0000-4000-8000-000000000012")!,
        UUID(uuidString: "23000000-0000-4000-8000-000000000013")!
    ]
    for (index, id) in ids.enumerated() {
        try store.upsert(ManagedAgentSessionRecord(
            tileId: id,
            agentKind: .shell,
            status: index == 0 ? .starting : .running,
            lastSeenAt: now.addingTimeInterval(TimeInterval(index)),
            runtimePayload: try ManagedAgentSessionRecord.makeRuntimePayload(windowTarget: "%\(50 + index)", cwd: nil)
        ))
    }
    let corrupt = ProjectStoreLayout(projectRoot: root).managedSessionsDirectory
        .appendingPathComponent("corrupt.json", isDirectory: false)
    try "{not-json".write(to: corrupt, atomically: true, encoding: .utf8)
    let all = try store.loadAll()
    expect(all.count == 3, "ManagedAgentSessionStore loadAll skips corrupt json and returns exactly three records")

    let opJSON = try JSONCodec.makeEncoder().encode(LoggedOp(
        opId: OpId(lamport: 1, replica: UUID(uuidString: "23000000-0000-4000-8000-000000000021")!),
        op: .createTile(
            id: UUID(uuidString: "23000000-0000-4000-8000-000000000022")!,
            kind: .terminal,
            title: "Terminal",
            frame: TileFrame(x: 1, y: 2, width: 3, height: 4),
            zPosition: .fromLegacyRank(1)
        )
    ))
    let activityJSON = try JSONCodec.makeEncoder().encode(AgentActivityEvent(
        stamping: AgentActivityEventDraft(
            agentId: UUID(uuidString: "23000000-0000-4000-8000-000000000024")!,
            runId: "run-1",
            tone: .info,
            kind: "turn.started",
            status: .working,
            summary: "working",
            occurredAt: now
        ),
        sequence: 1,
        replicaId: UUID(uuidString: "23000000-0000-4000-8000-000000000023")!
    ))
    let treeJSON = try JSONCodec.makeEncoder().encode(ActivityLogSnapshot.empty)
    let forbiddenTokens = ["ManagedAgentSessionRecord", "resumeCursor", "runtimePayload", "endedReason"]
    let encodedSyncPayloads = [
        String(decoding: opJSON, as: UTF8.self),
        String(decoding: activityJSON, as: UTF8.self),
        String(decoding: treeJSON, as: UTF8.self)
    ]
    let violations = encodedSyncPayloads.reduce(0) { count, payload in
        count + forbiddenTokens.filter { payload.contains($0) }.count
    }
    expect(violations == 0, "ManagedAgentSessionRecord private fields must not appear in spatial/activity JSON")

    let encodedRecord = try JSONCodec.makeEncoder().encode(record)
    let loadedBytes = try Data(contentsOf: ProjectStoreLayout(projectRoot: root).managedSessionFile(tileId: ids[0]))
    writeManagedSessionManifest([
        "roundTripBytesMatch": true,
        "writtenRecordBytesHex": encodedRecord.hexStringForManagedSessionCheck(),
        "loadedRecordBytesHex": try JSONCodec.makeEncoder().encode(loaded).hexStringForManagedSessionCheck(),
        "extractedWindowTarget": loaded.tmuxWindowTarget() ?? "",
        "loadAllCount": all.count,
        "syncBoundaryViolationsFound": violations,
        "samplePersistedBytesHex": loadedBytes.hexStringForManagedSessionCheck(),
        "labAgentKindRendered": AgentKind.shell.rawValue,
        "labStatusRendered": ManagedSessionStatus.running.rawValue,
        "labWindowTargetRendered": "%42"
    ])
}

/// P3.1: a record on disk proves something happened, never that something is
/// happening. Everything below is about the sweep that enforces it — that it
/// terminalizes exactly the two words claiming liveness, that it MIGRATES a v1
/// file (asserted on the bytes, not on a decoded value, because a reinterpreting
/// reader would pass a decoded assertion), and that running it twice writes
/// nothing the second time.
private func runManagedSessionReconciliationContract() throws {
    // MARK: 1 · isTerminal is total, and only two words claim liveness

    let nonTerminal = ManagedSessionStatus.allCases.filter { !$0.isTerminal }
    let terminal = ManagedSessionStatus.allCases.filter { $0.isTerminal }
    expect(ManagedSessionStatus.allCases.count == 5,
           "ManagedSessionStatus has exactly five words — a new one must choose a side of isTerminal, not inherit one")
    expect(Set(nonTerminal) == Set([ManagedSessionStatus.starting, .running]),
           "ManagedSessionStatus: only starting and running claim liveness — got \(nonTerminal.map(\.rawValue))")
    expect(Set(terminal) == Set([ManagedSessionStatus.stopped, .cancelled, .error]),
           "ManagedSessionStatus: stopped, cancelled and error describe the past — got \(terminal.map(\.rawValue))")
    expect(ManagedSessionStatus.cancelled.rawValue != ManagedSessionStatus.stopped.rawValue,
           "ManagedSessionStatus: system-cancel and user-stop must stay distinct words on disk — both read '\(ManagedSessionStatus.cancelled.rawValue)'")
    expect(ManagedSessionEndReason.allCases.count == 4,
           "ManagedSessionEndReason has exactly four reasons — got \(ManagedSessionEndReason.allCases.map(\.rawValue))")
    expect(Set(ManagedSessionEndReason.allCases.map(\.displayText)).count == ManagedSessionEndReason.allCases.count,
           "ManagedSessionEndReason: every reason presents its own sentence, so a human can tell a restart from a quit")
    expect(ManagedSessionEndReason.allCases.allSatisfy { !$0.displayText.isEmpty },
           "ManagedSessionEndReason: the reason is reachable by the UI as text, not merely logged")
    expect(ManagedAgentSessionRecord.currentSchemaVersion == 2,
           "P3.1's schema bump is the migration marker the byte assertion below looks for — currentSchemaVersion must be 2, got \(ManagedAgentSessionRecord.currentSchemaVersion)")

    // MARK: 2 · the sweep terminalizes exactly the non-terminal records

    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("continuum-managed-session-sweep-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ManagedAgentSessionStore(projectRoot: root)
    let layout = ProjectStoreLayout(projectRoot: root)

    func tile(_ suffix: String) -> UUID {
        UUID(uuidString: "31000000-0000-4000-8000-0000000000\(suffix)")!
    }
    // 1_700_000_000 == 2023-11-14T22:13:20Z, a whole second so the ISO 8601
    // round-trip is exact and the string below can be asserted verbatim.
    let lastSeenAt = Date(timeIntervalSince1970: 1_700_000_000)
    let lastSeenISO = "2023-11-14T22:13:20Z"
    let sweptAt = Date(timeIntervalSince1970: 1_800_000_000)
    let seeded: [(tileId: UUID, status: ManagedSessionStatus)] = [
        (tileId: tile("01"), status: .starting),
        (tileId: tile("02"), status: .running),
        (tileId: tile("03"), status: .stopped),
        (tileId: tile("04"), status: .cancelled),
        (tileId: tile("05"), status: .error)
    ]
    for seed in seeded {
        try store.upsert(ManagedAgentSessionRecord(
            tileId: seed.tileId,
            agentKind: .managed,
            status: seed.status,
            lastSeenAt: lastSeenAt
        ))
    }
    let terminalBytesBefore = try seeded.filter { $0.status.isTerminal }.map {
        try Data(contentsOf: layout.managedSessionFile(tileId: $0.tileId))
    }

    let (report, proof) = try ManagedSessionReconciliation.reconcile(
        store: store,
        reason: .continuumRestarted,
        now: sweptAt
    )
    expect(report.scanned == seeded.count,
           "ManagedSessionReconciliation scans every persisted record — scanned \(report.scanned) of \(seeded.count)")
    expect(report.terminalized == [tile("01"), tile("02")],
           "ManagedSessionReconciliation terminalizes exactly the records claiming liveness — got \(report.terminalized)")
    expect(report.alreadyTerminal == [tile("03"), tile("04"), tile("05")],
           "ManagedSessionReconciliation reports the already-terminal records instead of rewriting them — got \(report.alreadyTerminal)")

    for seed in seeded where !seed.status.isTerminal {
        guard let swept = try store.load(tileId: seed.tileId) else {
            throw ManagedSessionCheckError("swept record \(seed.tileId) is missing after reconciliation")
        }
        expect(swept.status == .cancelled,
               "a swept \(seed.status.rawValue) record reads cancelled — got \(swept.status.rawValue)")
        expect(swept.status != .stopped,
               "the sweep must not collapse system-cancel onto user-stop — a restarted \(seed.status.rawValue) record now reads the same word a human's stop writes")
        expect(swept.endedReason == .continuumRestarted,
               "a swept record records WHY it ended — got \(String(describing: swept.endedReason))")
        expect(swept.lastSeenAt == lastSeenAt,
               "the sweep carries lastSeenAt over instead of restamping it to the sweep's clock — got \(swept.lastSeenAt) for a record last seen \(lastSeenAt)")
        expect(swept.schemaVersion == ManagedAgentSessionRecord.currentSchemaVersion,
               "the sweep rebuilds through init, which stamps schema \(ManagedAgentSessionRecord.currentSchemaVersion) — got \(swept.schemaVersion)")
    }

    let terminalBytesAfter = try seeded.filter { $0.status.isTerminal }.map {
        try Data(contentsOf: layout.managedSessionFile(tileId: $0.tileId))
    }
    expect(terminalBytesAfter == terminalBytesBefore,
           "an already-terminal record is not rewritten by the sweep — that skip IS the idempotency, asserted on bytes")

    let listed = try store.reconciledRecords(proof)
    expect(listed.count == seeded.count,
           "a listing read takes the sweep's proof and returns every record — got \(listed.count) of \(seeded.count)")
    expect(listed.allSatisfy { $0.status.isTerminal },
           "after the sweep no persisted record reports a non-terminal status — got \(listed.map { $0.status.rawValue })")

    // MARK: 3 · the reason round-trips through the file, for every reason

    for (index, reason) in ManagedSessionEndReason.allCases.enumerated() {
        let reasonTile = tile("1\(index)")
        try store.upsert(ManagedAgentSessionRecord(
            tileId: reasonTile,
            agentKind: .claude,
            status: .cancelled,
            endedReason: reason,
            lastSeenAt: lastSeenAt
        ))
        let reloaded = try store.load(tileId: reasonTile)
        expect(reloaded?.endedReason == reason,
               "ManagedSessionEndReason.\(reason.rawValue) survives the round-trip to disk — got \(String(describing: reloaded?.endedReason))")
    }

    // MARK: 4 · a v1 file is MIGRATED, not reinterpreted — asserted on the bytes

    let v1Root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("continuum-managed-session-v1-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: v1Root) }
    let v1Store = ManagedAgentSessionStore(projectRoot: v1Root)
    let v1Layout = ProjectStoreLayout(projectRoot: v1Root)
    let v1Tile = tile("A1")
    let v1File = v1Layout.managedSessionFile(tileId: v1Tile)
    try FileManager.default.createDirectory(at: v1Layout.managedSessionsDirectory, withIntermediateDirectories: true)
    // Hand-written, exactly as the old spawn path left it: schema 1, no
    // endedReason key at all, and a status that no writer would ever transition.
    let v1JSON = """
    {
      "schemaVersion" : 1,
      "tileId" : "\(v1Tile.uuidString)",
      "agentKind" : "managed",
      "status" : "starting",
      "lastSeenAt" : "\(lastSeenISO)"
    }
    """
    try Data(v1JSON.utf8).write(to: v1File)
    guard let v1Decoded = try v1Store.load(tileId: v1Tile) else {
        throw ManagedSessionCheckError("a v1 record with no endedReason key failed to decode under schema \(ManagedAgentSessionRecord.currentSchemaVersion)")
    }
    expect(v1Decoded.schemaVersion == 1 && v1Decoded.endedReason == nil && v1Decoded.status == .starting,
           "a v1 file decodes unchanged before the sweep — got schema \(v1Decoded.schemaVersion), reason \(String(describing: v1Decoded.endedReason)), status \(v1Decoded.status.rawValue)")

    let (v1Report, _) = try ManagedSessionReconciliation.reconcile(
        store: v1Store,
        reason: .continuumRestarted,
        now: sweptAt
    )
    expect(v1Report.terminalized == [v1Tile],
           "the sweep terminalizes the record the old spawn path wrote — got \(v1Report.terminalized)")
    let migratedBytes = try Data(contentsOf: v1File)
    // Whitespace-stripped so the assertion reads the same whether the writer
    // pretty-prints or not; no value below contains a space.
    let migrated = String(decoding: migratedBytes, as: UTF8.self).filter { !$0.isWhitespace }
    expect(migrated.contains("\"status\":\"cancelled\""),
           "the migrated FILE says cancelled — a reader that merely reinterprets a stale status leaves these bytes saying starting: \(migrated)")
    expect(!migrated.contains("\"status\":\"starting\""),
           "the migrated file no longer claims liveness anywhere in its bytes: \(migrated)")
    expect(migrated.contains("\"endedReason\":\"continuumRestarted\""),
           "the migrated file records the reason it was cancelled: \(migrated)")
    expect(migrated.contains("\"schemaVersion\":2"),
           "the migrated file carries schema 2 — the rebuild through init IS the migration marker: \(migrated)")
    expect(migrated.contains("\"lastSeenAt\":\"\(lastSeenISO)\""),
           "the v1 timestamp survives the migration — lastSeenAt is the elapsed anchor, not the sweep's clock: \(migrated)")

    // MARK: 5 · running the sweep twice changes nothing the second time

    let backupsAfterFirst = try managedSessionBackupCount(in: v1Layout.backupsDirectory)
    expect(backupsAfterFirst == 1,
           "the first sweep did write, leaving one backup — without this the count comparison below would pass vacuously (got \(backupsAfterFirst))")
    let (secondReport, _) = try ManagedSessionReconciliation.reconcile(
        store: v1Store,
        reason: .continuumQuit,
        now: sweptAt.addingTimeInterval(60)
    )
    expect(secondReport.terminalized.isEmpty,
           "a second sweep terminalizes nothing — got \(secondReport.terminalized)")
    expect(secondReport.alreadyTerminal == [v1Tile],
           "a second sweep reports the record it left alone — got \(secondReport.alreadyTerminal)")
    let bytesAfterSecond = try Data(contentsOf: v1File)
    expect(bytesAfterSecond == migratedBytes,
           "a second sweep leaves the file byte-identical, so a later reason cannot overwrite the first one recorded")
    let backupsAfterSecond = try managedSessionBackupCount(in: v1Layout.backupsDirectory)
    expect(backupsAfterSecond == backupsAfterFirst,
           "a second sweep performs no write at all — AtomicWriter backs up on every write, so \(backupsAfterSecond) backups against \(backupsAfterFirst) is the proof")

    writeManagedSessionManifest([
        "statusCaseCount": ManagedSessionStatus.allCases.count,
        "nonTerminalStatuses": nonTerminal.map(\.rawValue),
        "terminalStatuses": terminal.map(\.rawValue),
        "endReasonCases": ManagedSessionEndReason.allCases.map(\.rawValue),
        "sweptScanned": report.scanned,
        "sweptTerminalizedCount": report.terminalized.count,
        "sweptAlreadyTerminalCount": report.alreadyTerminal.count,
        "terminalRecordBytesUnchanged": terminalBytesAfter == terminalBytesBefore,
        "migratedV1Bytes": migrated,
        "secondSweepTerminalizedCount": secondReport.terminalized.count,
        "secondSweepBytesIdentical": bytesAfterSecond == migratedBytes,
        "backupsAfterFirstSweep": backupsAfterFirst,
        "backupsAfterSecondSweep": backupsAfterSecond
    ], named: "ticket94-p31-managed-session-sweep.json")
}

private func managedSessionBackupCount(in directory: URL) throws -> Int {
    guard FileManager.default.fileExists(atPath: directory.path) else { return 0 }
    return try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
    ).count
}

private struct ManagedSessionCheckError: Error, CustomStringConvertible {
    var description: String

    init(_ description: String) {
        self.description = description
    }
}

private extension Data {
    func hexStringForManagedSessionCheck() -> String {
        map { String(format: "%02x", $0) }.joined()
    }
}

private func writeManagedSessionManifest(
    _ fields: [String: Any],
    named name: String = "ticket23-managed-session-record.json"
) {
    let dir = URL(fileURLWithPath: ".build/checks-manifests", isDirectory: true)
    do {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent(name, isDirectory: false)
        let data = try JSONSerialization.data(withJSONObject: fields, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: path, options: .atomic)
    } catch {
        fputs("WARN: ManagedAgentSessionRecord check: could not write manifest: \(error)\n", stderr)
    }
}
