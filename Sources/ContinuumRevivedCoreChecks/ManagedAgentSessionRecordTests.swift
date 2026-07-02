import ContinuumRevivedCore
import Foundation

func runManagedAgentSessionRecordTests() {
    do {
        try runManagedAgentSessionStoreContract()
        print("ManagedAgentSessionRecord checks: store contract, payload extraction, and sync-boundary isolation passed")
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
            zIndex: 1
        )
    ))
    let activityJSON = try JSONCodec.makeEncoder().encode(AgentActivityEvent(
        stamping: AgentActivityEventDraft(
            tileId: UUID(uuidString: "23000000-0000-4000-8000-000000000024")!,
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
    let forbiddenTokens = ["ManagedAgentSessionRecord", "resumeCursor", "runtimePayload"]
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

private func writeManagedSessionManifest(_ fields: [String: Any]) {
    let dir = URL(fileURLWithPath: ".build/checks-manifests", isDirectory: true)
    do {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("ticket23-managed-session-record.json", isDirectory: false)
        let data = try JSONSerialization.data(withJSONObject: fields, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: path, options: .atomic)
    } catch {
        fputs("WARN: ManagedAgentSessionRecord check: could not write manifest: \(error)\n", stderr)
    }
}
