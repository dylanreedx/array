import ContinuumRevivedCore
import ContinuumRevivedSync
import Foundation

// Ticket: docs/38-tickets/57-cloudkit-transport-impl.md — "How we test it / Backend"
//
// Night-3 amendment #4: this is the ONE place `CloudKitSyncTransport` (and
// therefore `CKContainer`) may actually be instantiated — and only behind
// `CLOUDKIT_ENABLED=1`. In the standard overnight matrix (and any
// unprovisioned/unsigned environment) that variable is absent, so this
// target compiles and runs but performs zero CloudKit calls, records
// `cloudkit_available=false` in the manifest, and exits 0. Do NOT fake a
// green CK integration: the branch below that actually talks to CloudKit is
// real, measured, gated behind a real container/entitlement, and is
// `device-gate-owed` — a human runs it manually once the container is
// provisioned and the app is signed (see the ticket's "Execution mode").

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

/// Drains `transport.inbound` into an actor-protected buffer for the
/// duration of the check, so the polling loops below can inspect what has
/// arrived so far without racing a raw `AsyncStream.Iterator` across tasks.
private actor InboundCollector {
    private(set) var messages: [SyncMessage] = []

    func run(_ stream: AsyncStream<SyncMessage>) async {
        for await message in stream { messages.append(message) }
    }
}

/// Polls `probe()` every 100ms until it returns non-nil or `timeoutSeconds`
/// elapses.
private func poll<T: Sendable>(timeoutSeconds: Double, _ probe: @Sendable () async -> T?) async -> T? {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while true {
        if let value = await probe() { return value }
        if Date() >= deadline { return nil }
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
}

private func millis(_ interval: TimeInterval) -> Int {
    Int((interval * 1000).rounded())
}

func runGatedCloudKitIntegrationChecks() async throws {
    let containerIdentifier = ProcessInfo.processInfo.environment["CLOUDKIT_CONTAINER_IDENTIFIER"]
        ?? "iCloud.io.bannockburn.continuum"
    let replicaId = UUID()

    let transport = CloudKitSyncTransport(containerIdentifier: containerIdentifier)
    let collector = InboundCollector()
    let drainTask = Task { await collector.run(transport.inbound) }
    defer { drainTask.cancel() }

    // 1. Push a fresh LoggedOp; assert the save completes without error.
    let op = LoggedOp(
        opId: OpId(lamport: 1, replica: replicaId),
        op: .setTileTitle(id: UUID(), title: "cloudkit-integration-check")
    )
    let pushStart = Date()
    try await transport.send(.op(op))
    let pushLatencyMs = millis(Date().timeIntervalSince(pushStart))

    // 2. Fetch it back via the public seam (fetchChanges → inbound), not a
    // private db.record(for:) reach-in — this exercises the real,
    // consumer-visible round trip.
    let fetchStart = Date()
    try await transport.fetchChanges()
    let deliveredFirst = await poll(timeoutSeconds: 10) {
        await collector.messages.contains { if case .op(let logged) = $0 { return logged.opId == op.opId } else { return false } } ? true : nil
    }
    let fetchLatencyMs = millis(Date().timeIntervalSince(fetchStart))
    expect(deliveredFirst == true, "cloudkit integration: pushed op is fetched back via fetchChanges within 10s")

    // 3. Idempotency: push the exact same OpId again — must not throw
    // (CKError.serverRecordChanged is caught and treated as success).
    var idempotentPushSucceeded = true
    do {
        try await transport.send(.op(op))
    } catch {
        idempotentPushSucceeded = false
        fputs("cloudkit integration: idempotent re-push failed: \(error)\n", stderr)
    }
    expect(idempotentPushSucceeded, "cloudkit integration: re-pushing the same OpId does not throw")

    // 4. Subscription + a NEW op, delivered via fetchChanges within 10s.
    // (A true silent-push delivery needs a signed, foregrounded app on a
    // real device — out of reach even with CLOUDKIT_ENABLED=1 in a headless
    // process. This exercises the CATCH-UP path — fetchChanges after a
    // manual push — not silent-push delivery itself; the manifest key below
    // is named accordingly so it never implies otherwise. Real silent-push
    // delivery remains device-gate-owed.)
    try await transport.ensureSubscription()
    let secondOp = LoggedOp(
        opId: OpId(lamport: 2, replica: replicaId),
        op: .setTileTitle(id: UUID(), title: "cloudkit-integration-check-2")
    )
    try await transport.send(.op(secondOp))
    try await transport.fetchChanges()
    let subscriptionCatchupDelivered = await poll(timeoutSeconds: 10) {
        await collector.messages.contains { if case .op(let logged) = $0 { return logged.opId == secondOp.opId } else { return false } } ? true : nil
    } ?? false
    expect(subscriptionCatchupDelivered, "cloudkit integration: a subscribed-for op is delivered (via fetchChanges catch-up) within 10s")

    // Server-side verification (ticket "Integration check honesty" fix):
    // confirm the registered subscription actually has the shape
    // ensureSubscription() requires — a CKRecordZoneSubscription on
    // cloudKitSyncZoneID with shouldSendContentAvailable — rather than only
    // observing that the catch-up path happened to work.
    let subscriptionShapeVerified = await transport.verifySubscriptionShape()
    expect(
        subscriptionShapeVerified,
        "cloudkit integration: the registered \"continuum-sync-ops\" subscription is a CKRecordZoneSubscription on cloudKitSyncZoneID with shouldSendContentAvailable"
    )

    // 5. Activity snapshot push/fetch round trip.
    let snapshot = ActivityLogSnapshot(
        snapshotSequence: 1,
        snapshotReplicaId: replicaId,
        byAgent: [:]
    )
    let snapshotPushStart = Date()
    try await transport.send(.activity(.snapshot(snapshot)))
    let snapshotPushLatencyMs = millis(Date().timeIntervalSince(snapshotPushStart))
    try await transport.send(.activitySubscribe(ActivitySubscribeRequest(cursor: nil)))
    let snapshotFetchRoundtripSucceeded = await poll(timeoutSeconds: 10) {
        await collector.messages.contains {
            if case .activity(.snapshot(let received)) = $0 { return received == snapshot } else { return false }
        } ? true : nil
    } ?? false
    expect(snapshotFetchRoundtripSucceeded, "cloudkit integration: pushed ActivityLogSnapshot round-trips via activitySubscribe's local refetch trigger")

    let manifest = InvariantManifest(
        invariantId: "ticket57-cloudkit-transport-impl",
        runId: UUID().uuidString,
        measuredAt: ISO8601DateFormatter().string(from: Date()),
        measurements: [
            "cloudkit_available": .bool(true),
            "container_identifier": .string(containerIdentifier),
            "push_latency_ms": .int(pushLatencyMs),
            "fetch_latency_ms": .int(fetchLatencyMs),
            "idempotent_push_succeeded": .bool(idempotentPushSucceeded),
            "subscription_catchup_delivered": .bool(subscriptionCatchupDelivered),
            "subscription_shape_verified": .bool(subscriptionShapeVerified),
            "snapshot_push_latency_ms": .int(snapshotPushLatencyMs),
            "snapshot_fetch_roundtrip_succeeded": .bool(snapshotFetchRoundtripSucceeded),
        ],
        outcome: InvariantOutcome.pass.rawValue,
        failureReason: nil
    )
    try writeManifest(manifest)
    print("ContinuumRevivedSyncIntegrationChecks passed: real CloudKit round-trip against \(containerIdentifier) — push \(pushLatencyMs)ms, fetch \(fetchLatencyMs)ms, idempotent=\(idempotentPushSucceeded), subscriptionCatchupDelivered=\(subscriptionCatchupDelivered) (catch-up path, not silent push — device-gate-owed), subscriptionShapeVerified=\(subscriptionShapeVerified), snapshot push \(snapshotPushLatencyMs)ms roundtrip=\(snapshotFetchRoundtripSucceeded)")
}

func writeManifest(_ manifest: InvariantManifest) throws {
    let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("continuum-\(manifest.invariantId)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    try InvariantManifestWriter.write(manifest, to: tmpDir)
    print("manifest at \(tmpDir.appendingPathComponent("invariant-\(manifest.invariantId)-\(manifest.runId).json").path)")
}

// MARK: - Entry point

if ProcessInfo.processInfo.environment["CLOUDKIT_ENABLED"] == "1" {
    try await runGatedCloudKitIntegrationChecks()
} else {
    // Skip gracefully — this is the expected path in the overnight matrix
    // and any unprovisioned/unsigned environment (see the ticket's
    // "Execution mode": backend/UX verification "must be performed by a
    // human with access to the provisioned environment").
    let manifest = InvariantManifest(
        invariantId: "ticket57-cloudkit-transport-impl",
        runId: UUID().uuidString,
        measuredAt: ISO8601DateFormatter().string(from: Date()),
        measurements: ["cloudkit_available": .bool(false)],
        outcome: InvariantOutcome.stub.rawValue,
        failureReason: "CLOUDKIT_ENABLED not set — device-gate-owed, run manually against a provisioned iCloud.io.bannockburn.continuum container with a signed app"
    )
    try writeManifest(manifest)
    print("ContinuumRevivedSyncIntegrationChecks SKIPPED: CLOUDKIT_ENABLED not set — no CKContainer/CKDatabase instantiated (device-gate-owed; run manually with a provisioned container + signed app, see the ticket's \"Execution mode\")")
}
