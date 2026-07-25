import CloudKit
import ContinuumRevivedCore
import ContinuumRevivedSync
import Foundation

// Ticket: docs/38-tickets/57-cloudkit-transport-impl.md
//
// Night-3 amendment #4: NEVER instantiate `CKContainer`/`CKDatabase` here — an
// unentitled process crashes on container access. Every check below drives
// only the free `encodeOpRecord`/`decodeOpRecord`/`CloudKitRetry.withRetry`
// functions and bare `CKRecord`/`CKError` VALUES, which are headless-safe.
// The four suites are exactly the ones the ruling names: round-trip per `Op`
// case, record-name idempotency, malformed-record rejection, and the
// injected-sleep retry sequence (incl. non-retryable passthrough).

private let cksRepA = UUID(uuidString: "C1000000-0000-4000-8000-00000000000A")!
private let cksRepB = UUID(uuidString: "C1000000-0000-4000-8000-00000000000B")!
private let cksTile = UUID(uuidString: "C1000000-0000-4000-8000-0000000000A1")!
private let cksZone = UUID(uuidString: "C1000000-0000-4000-8000-0000000000B1")!

/// One representative `Op` per case — every case in the enum, so the
/// round-trip check exercises all 19, not a sample.
private func allOpCases() -> [(String, Op)] {
    let frame = TileFrame(x: 10, y: 20, width: 300, height: 200)
    let origin = ZonePoint(x: 5, y: 5)
    let size = ZoneSize(width: 400, height: 300)
    return [
        ("createTile", .createTile(id: cksTile, kind: .terminal, title: "t", frame: frame, zPosition: FracIndex(value: 0.5))),
        ("deleteTile", .deleteTile(id: cksTile)),
        ("createZone", .createZone(id: cksZone, projectId: cksRepA, origin: origin, size: size, name: "Z", color: "mint")),
        ("deleteZone", .deleteZone(id: cksZone)),
        ("setTileFrame", .setTileFrame(id: cksTile, frame: frame)),
        ("setTileZIndex", .setTileZIndex(id: cksTile, z: FracIndex(value: 0.6))),
        ("setTileTitle", .setTileTitle(id: cksTile, title: "renamed")),
        ("setTileKind", .setTileKind(id: cksTile, kind: .note)),
        ("setTileCollapsed", .setTileCollapsed(id: cksTile, collapsed: true)),
        ("setZoneOrigin", .setZoneOrigin(id: cksZone, origin: origin)),
        ("setZoneSize", .setZoneSize(id: cksZone, size: size)),
        ("setZoneName", .setZoneName(id: cksZone, name: "renamed-zone")),
        ("setZoneColor", .setZoneColor(id: cksZone, color: "grape")),
        ("setZoneCollapsed", .setZoneCollapsed(id: cksZone, collapsed: true)),
        ("setZoneProjectId", .setZoneProjectId(id: cksZone, projectId: nil)),
        ("setZonePosition", .setZonePosition(id: cksZone, position: FracIndex(value: 0.4))),
        ("setTileZone", .setTileZone(tileId: cksTile, zoneId: cksZone)),
        ("setLastActiveTile", .setLastActiveTile(id: cksTile)),
        ("setLastActiveZone", .setLastActiveZone(id: cksZone)),
    ]
}

/// 1. Round-trip encoding: `encodeOpRecord` → `decodeOpRecord` reproduces the
/// original `LoggedOp` exactly, for every `Op` case, and the record name is
/// exactly `"\(lamport)-\(replicaUUID)"`.
private func checkRoundTripEncoding() {
    let cases = allOpCases()
    expect(cases.count == 19, "round-trip: exercises all 19 Op cases, got \(cases.count)")
    for (index, (label, op)) in cases.enumerated() {
        let opId = OpId(lamport: UInt64(index + 1), replica: index % 2 == 0 ? cksRepA : cksRepB)
        let logged = LoggedOp(opId: opId, op: op)
        let record = try! encodeOpRecord(logged)
        expect(
            record.recordID.recordName == "\(opId.lamport)-\(opId.replica.uuidString)",
            "round-trip[\(label)]: recordName is exactly \"lamport-replicaUUID\", got \(record.recordID.recordName)"
        )
        expect(record.recordType == CKRecordTypes.syncOp, "round-trip[\(label)]: recordType is SyncOp")
        // Round-2 reviewer concern #1: every SyncOp record must live in the
        // custom sync zone, never the default zone (the default zone does
        // not support the change-token tracking fetchChanges()/the
        // subscription depend on).
        expect(
            record.recordID.zoneID == cloudKitSyncZoneID,
            "round-trip[\(label)]: recordID.zoneID is the custom sync zone, not the default zone"
        )
        // Round-2 reviewer concern #7: prove `opPayload` is the CANONICAL
        // `JSONCodec.makeOpLogEncoder()` bytes, not just "some JSON that
        // happens to decode" — a plain JSONEncoder would satisfy the
        // decode-round-trips-back assertion below without satisfying the
        // ticket's "opPayload is encoded with JSONCodec.makeOpLogEncoder()"
        // Done-when line.
        let canonicalBytes = try! JSONCodec.makeOpLogEncoder().encode(op)
        let recordBytes = record[SyncOpField.opPayload] as? Data
        expect(
            recordBytes == canonicalBytes,
            "round-trip[\(label)]: opPayload bytes are exactly JSONCodec.makeOpLogEncoder().encode(op), not a different encoder's output"
        )
        let decoded = try! decodeOpRecord(record)
        expect(decoded == logged, "round-trip[\(label)]: decodeOpRecord(encodeOpRecord(x)) == x")
    }
    print("cloudkit-sync-transport: round-trip encoding — all 19 Op cases encode/decode byte-for-byte identical, record names exactly \"lamport-replicaUUID\", zoneID is the custom sync zone, opPayload matches JSONCodec.makeOpLogEncoder() canonical bytes exactly")
}

/// 2. Idempotency of record names: two `LoggedOp`s sharing an `OpId` produce
/// identical `CKRecord.ID.recordName`s, proving a retry collides on the
/// server instead of creating a duplicate.
///
/// Round-3 reviewer concern #5: the previous version used the SAME payload
/// (`"first attempt"`/`"first attempt"`) for both records, so a
/// payload-derived `recordName` would have passed this check too — it never
/// actually proved the name is derived from the `OpId` alone. Use two
/// DIFFERENT payloads sharing the same `OpId` instead: only an OpId-only
/// `recordName` construction can make this pass.
private func checkRecordNameIdempotency() {
    let sharedOpId = OpId(lamport: 42, replica: cksRepA)
    let first = LoggedOp(opId: sharedOpId, op: .setTileTitle(id: cksTile, title: "first attempt"))
    let retry = LoggedOp(opId: sharedOpId, op: .setTileTitle(id: cksTile, title: "a completely different payload on retry"))
    let recordFirst = try! encodeOpRecord(first)
    let recordRetry = try! encodeOpRecord(retry)
    expect(
        recordFirst.recordID.recordName == recordRetry.recordID.recordName,
        "idempotency: encodeOpRecord produces identical recordName for identical OpId even with a different payload (recordName is OpId-derived, not payload-derived)"
    )
    expect(
        recordFirst.recordID.recordName == syncOpRecordName(for: sharedOpId),
        "idempotency: recordName matches syncOpRecordName(for:) exactly"
    )
    print("cloudkit-sync-transport: record-name idempotency — retrying the same OpId (even with a different payload) always yields the same CKRecord.ID.recordName (\(recordFirst.recordID.recordName))")
}

/// 2b. The `CKError.serverRecordChanged`-as-success half of the idempotency
/// contract (round-3 reviewer concerns #2/#5): the Done-when line "a retry of
/// the same OpId receives CKError.serverRecordChanged and treats it as
/// success" was previously confirmed only by the record-NAME check above,
/// never by actually driving `isServerRecordChanged` — the exact classifier
/// `pushOp`'s retry wrapper calls to decide "treat as success" vs "propagate"
/// — against real `CKError` VALUES. `isServerRecordChanged(error, key:)`
/// returning `true` IS the "treats it as success" behavior: every call site
/// in `CloudKitSyncTransport` is exactly `if isServerRecordChanged(...) {
/// return } else { throw error }`, so asserting the classifier's output
/// directly asserts the outcome.
private func checkServerRecordChangedClassifier() {
    let recordId = CKRecord.ID(recordName: syncOpRecordName(for: OpId(lamport: 7, replica: cksRepA)), zoneID: cloudKitSyncZoneID)
    let otherRecordId = CKRecord.ID(recordName: syncOpRecordName(for: OpId(lamport: 8, replica: cksRepB)), zoneID: cloudKitSyncZoneID)

    // Top-level thrown CKError.serverRecordChanged — the common atomic-save
    // conflict shape — is treated as success (retry of the same OpId).
    expect(
        CloudKitSyncTransport.isServerRecordChanged(CKError(.serverRecordChanged), key: recordId),
        "serverRecordChanged classifier: a top-level CKError.serverRecordChanged is treated as success"
    )

    // Nested under partialErrorsByItemID, keyed to THIS record — also success.
    let nestedError = CKError(.partialFailure, userInfo: [
        CKPartialErrorsByItemIDKey: [recordId: CKError(.serverRecordChanged) as Error],
    ])
    expect(
        CloudKitSyncTransport.isServerRecordChanged(nestedError, key: recordId),
        "serverRecordChanged classifier: a nested partialErrorsByItemID[key] == .serverRecordChanged is treated as success"
    )

    // Nested under a DIFFERENT record's ID must not match this record's push.
    let nestedOtherKey = CKError(.partialFailure, userInfo: [
        CKPartialErrorsByItemIDKey: [otherRecordId: CKError(.serverRecordChanged) as Error],
    ])
    expect(
        !CloudKitSyncTransport.isServerRecordChanged(nestedOtherKey, key: recordId),
        "serverRecordChanged classifier: a conflict nested under a DIFFERENT record's ID does not falsely match this record's push"
    )

    // A genuinely different, non-retryable error must propagate (classifier
    // false) — the negative case that proves this is a narrow classifier,
    // not a catch-all.
    expect(
        !CloudKitSyncTransport.isServerRecordChanged(CKError(.invalidArguments), key: recordId),
        "serverRecordChanged classifier: an unrelated CKError code (invalidArguments) is NOT treated as success"
    )
    expect(
        !CloudKitSyncTransport.isServerRecordChanged(TransportError.malformedRecord, key: recordId),
        "serverRecordChanged classifier: a non-CKError Error is NOT treated as success"
    )
    print("cloudkit-sync-transport: isServerRecordChanged classifier — top-level and nested-by-key serverRecordChanged are treated as success; mismatched key, unrelated CKError code, and non-CKError errors are not")
}

/// 2c. The pure, presumptive half of the duplicate-subscription
/// classification (round-3 reviewer concerns #1/#2/#4): confirms
/// `isPresumedDuplicateSubscription` correlates on `.serverRejectedRequest`
/// for the subscription's own ID, top-level and nested, and — the negative
/// case the previous suite never exercised at all — that unrelated CKError
/// codes are NOT presumed-duplicate. The sufficient half of the fix (actually
/// confirming the subscription exists via a fetch before declaring success)
/// necessarily touches `CKDatabase` and is exercised only by the
/// `device-gate-owed` integration leg, per the ticket's headless-safety
/// doctrine — see `ensureSubscription()`'s doc comment.
private func checkPresumedDuplicateSubscriptionClassifier() {
    let subscriptionID = "continuum-sync-ops"
    let otherSubscriptionID = "some-other-subscription"

    expect(
        CloudKitSyncTransport.isPresumedDuplicateSubscription(CKError(.serverRejectedRequest), subscriptionID: subscriptionID),
        "duplicate-subscription classifier: a top-level CKError.serverRejectedRequest is presumed-duplicate"
    )

    let nestedError = CKError(.partialFailure, userInfo: [
        CKPartialErrorsByItemIDKey: [subscriptionID: CKError(.serverRejectedRequest) as Error],
    ])
    expect(
        CloudKitSyncTransport.isPresumedDuplicateSubscription(nestedError, subscriptionID: subscriptionID),
        "duplicate-subscription classifier: nested partialErrorsByItemID[subscriptionID] == .serverRejectedRequest is presumed-duplicate"
    )

    let nestedOtherId = CKError(.partialFailure, userInfo: [
        CKPartialErrorsByItemIDKey: [otherSubscriptionID: CKError(.serverRejectedRequest) as Error],
    ])
    expect(
        !CloudKitSyncTransport.isPresumedDuplicateSubscription(nestedOtherId, subscriptionID: subscriptionID),
        "duplicate-subscription classifier: a rejection nested under a DIFFERENT subscription ID does not falsely match"
    )

    // Negative case (this is the crux of concerns #1/#4): a genuinely
    // different rejection reason (e.g. a quota/permission failure) must not
    // be presumed-duplicate by a DIFFERENT CKError code — the classifier only
    // narrows within .serverRejectedRequest; distinguishing OTHER
    // serverRejectedRequest causes from a true duplicate is exactly what the
    // confirmatory fetch in `ensureSubscription()` exists for, and cannot be
    // proven by this pure classifier alone (see its doc comment).
    expect(
        !CloudKitSyncTransport.isPresumedDuplicateSubscription(CKError(.permissionFailure), subscriptionID: subscriptionID),
        "duplicate-subscription classifier: an unrelated CKError code (permissionFailure) is NOT presumed-duplicate"
    )
    print("cloudkit-sync-transport: isPresumedDuplicateSubscription classifier — top-level and nested-by-ID serverRejectedRequest are presumed-duplicate; mismatched ID and unrelated CKError codes are not (the confirmatory-fetch half is device-gate-owed, see ensureSubscription())")
}

/// Asserts `decodeOpRecord` throws exactly `TransportError.malformedRecord`
/// for a given deliberately-broken record — never a crash, never a
/// different error.
private func expectMalformedRecordRejected(_ record: CKRecord, _ label: String) {
    do {
        _ = try decodeOpRecord(record)
        expect(false, "malformed record[\(label)]: decodeOpRecord must throw")
    } catch TransportError.malformedRecord {
        // expected
    } catch {
        expect(false, "malformed record[\(label)]: expected TransportError.malformedRecord, got \(error)")
    }
}

/// 3. Malformed record rejection: a handful of ways a `SyncOp` record can
/// be broken (accidentally, or by an old/new-format client sharing the
/// container per the ticket's "Watch out") must all be rejected as
/// `TransportError.malformedRecord`, never crash the process and never
/// silently decode something wrong.
///
/// Round-2 reviewer concern #8: the previous suite covered only the
/// missing-`opPayload` case, which does not exercise `decodeOpRecord`'s
/// `UInt64(lamport)` conversion — a negative `lamport` value traps
/// (`fatalError`, not a throw) rather than being rejected. Broadened to
/// also cover negative lamport, a non-UUID replica string, and a payload
/// that is present but not valid `Op` JSON.
private func checkMalformedRecordRejection() {
    // (a) opPayload missing entirely.
    let missingPayload = CKRecord(recordType: CKRecordTypes.syncOp, recordID: CKRecord.ID(recordName: "1-\(cksRepA.uuidString)"))
    missingPayload[SyncOpField.lamport] = Int64(1) as CKRecordValue
    missingPayload[SyncOpField.replica] = cksRepA.uuidString as CKRecordValue
    expectMalformedRecordRejected(missingPayload, "missing opPayload")

    // (b) negative lamport — must be rejected, not trap UInt64(lamport).
    let validPayload = try! JSONCodec.makeOpLogEncoder().encode(Op.deleteTile(id: cksTile))
    let negativeLamport = CKRecord(recordType: CKRecordTypes.syncOp, recordID: CKRecord.ID(recordName: "-1-\(cksRepA.uuidString)"))
    negativeLamport[SyncOpField.lamport] = Int64(-1) as CKRecordValue
    negativeLamport[SyncOpField.replica] = cksRepA.uuidString as CKRecordValue
    negativeLamport[SyncOpField.opPayload] = validPayload as CKRecordValue
    expectMalformedRecordRejected(negativeLamport, "negative lamport")

    // (c) replica field present but not a valid UUID string.
    let badReplica = CKRecord(recordType: CKRecordTypes.syncOp, recordID: CKRecord.ID(recordName: "1-not-a-uuid"))
    badReplica[SyncOpField.lamport] = Int64(1) as CKRecordValue
    badReplica[SyncOpField.replica] = "not-a-uuid" as CKRecordValue
    badReplica[SyncOpField.opPayload] = validPayload as CKRecordValue
    expectMalformedRecordRejected(badReplica, "non-UUID replica")

    // (d) opPayload present but not valid Op JSON (e.g. a newer client's
    // unrecognized discriminator, or plain corruption).
    let garbagePayload = CKRecord(recordType: CKRecordTypes.syncOp, recordID: CKRecord.ID(recordName: "1-\(cksRepA.uuidString)"))
    garbagePayload[SyncOpField.lamport] = Int64(1) as CKRecordValue
    garbagePayload[SyncOpField.replica] = cksRepA.uuidString as CKRecordValue
    garbagePayload[SyncOpField.opPayload] = Data("{\"notAnOp\":true}".utf8) as CKRecordValue
    expectMalformedRecordRejected(garbagePayload, "garbage opPayload")

    print("cloudkit-sync-transport: malformed record rejection — missing opPayload, negative lamport (no UInt64 trap), non-UUID replica, and garbage opPayload all throw TransportError.malformedRecord")
}

/// 3b. Outbound integer safety (round-3 binding fix #3): a `UInt64`
/// lamport/sequence value above `Int64.max` cannot be represented in
/// CloudKit's `Int64` field. `Int64(someUInt64)` TRAPS (fatal error, not a
/// throw) above that threshold — the encoder must use the checked
/// `Int64(exactly:)` initializer and throw `TransportError.outboundIntegerOverflow`
/// instead, alongside the existing negative-INBOUND case above (`decodeOpRecord`
/// rejecting a negative lamport rather than trapping `UInt64(exactly:)`).
private func checkOutboundIntegerOverflow() {
    // (a) LoggedOp — encodeOpRecord's `lamport` field.
    let overflowOpId = OpId(lamport: UInt64(Int64.max) + 1, replica: cksRepA)
    let overflowLogged = LoggedOp(opId: overflowOpId, op: .deleteTile(id: cksTile))
    do {
        _ = try encodeOpRecord(overflowLogged)
        expect(false, "outbound overflow[LoggedOp]: encodeOpRecord must throw for a lamport above Int64.max, not crash or silently truncate")
    } catch TransportError.outboundIntegerOverflow {
        // expected
    } catch {
        expect(false, "outbound overflow[LoggedOp]: expected TransportError.outboundIntegerOverflow, got \(error)")
    }
    // A lamport exactly at Int64.max is representable — must NOT throw.
    let maxOpId = OpId(lamport: UInt64(Int64.max), replica: cksRepA)
    let maxLogged = LoggedOp(opId: maxOpId, op: .deleteTile(id: cksTile))
    expect((try? encodeOpRecord(maxLogged)) != nil, "outbound overflow[LoggedOp]: a lamport exactly at Int64.max encodes without error")

    // (b) AgentActivityEvent — encodeActivityEventRecord's `sequence` field.
    let overflowEvent = AgentActivityEvent(
        stamping: AgentActivityEventDraft(
            agentId: cksTile, runId: nil, tone: .info, kind: "status",
            status: .idle, summary: "overflow probe", occurredAt: Date()
        ),
        sequence: UInt64(Int64.max) + 1,
        replicaId: cksRepA
    )
    do {
        _ = try encodeActivityEventRecord(overflowEvent)
        expect(false, "outbound overflow[AgentActivityEvent]: encodeActivityEventRecord must throw for a sequence above Int64.max, not crash or silently truncate")
    } catch TransportError.outboundIntegerOverflow {
        // expected
    } catch {
        expect(false, "outbound overflow[AgentActivityEvent]: expected TransportError.outboundIntegerOverflow, got \(error)")
    }

    print("cloudkit-sync-transport: outbound integer safety — a lamport/sequence above Int64.max throws TransportError.outboundIntegerOverflow (checked Int64(exactly:), no trap); Int64.max itself still encodes")
}

/// A single-threaded-in-practice mutable recorder. `withRetry`'s `body`/
/// `sleep` closures are `@Sendable` (so the type checker allows them to run
/// off the calling task), but this check drives them strictly sequentially —
/// `@unchecked Sendable` here is exactly that "actually never touched
/// concurrently" case, not a real data race.
private final class Recorder: @unchecked Sendable {
    var callCount = 0
    var delays: [TimeInterval] = []
}

/// 4. Retry backoff sequence: an injected `sleep` closure (no real
/// `Task.sleep`) proves the delay sequence is exactly 1, 2, 4, 8 between the
/// 5 attempts `withRetry`'s default `maxAttempts` allows, that the last error
/// surfaces once attempts are exhausted, and that a non-retryable error
/// propagates on the very first throw with no sleep at all.
private func checkRetryBackoffSequence() async throws {
    let retryable = Recorder()
    do {
        _ = try await CloudKitRetry.withRetry(
            sleep: { seconds in retryable.delays.append(seconds) }
        ) { () -> Void in
            retryable.callCount += 1
            throw CKError(.networkFailure)
        }
        expect(false, "retry backoff: withRetry must surface the last error once attempts are exhausted")
    } catch let error as CKError {
        expect(error.code == .networkFailure, "retry backoff: the surfaced error is the last retryable CKError, got \(error.code)")
    }
    expect(retryable.callCount == 5, "retry backoff: body is called exactly maxAttempts (5) times, got \(retryable.callCount)")
    expect(retryable.delays == [1, 2, 4, 8], "retry backoff: delay sequence is exactly [1, 2, 4, 8] between the 5 attempts, got \(retryable.delays)")

    // Non-retryable: propagates immediately, no sleep, one call.
    let nonRetryable = Recorder()
    do {
        _ = try await CloudKitRetry.withRetry(
            sleep: { seconds in nonRetryable.delays.append(seconds) }
        ) { () -> Void in
            nonRetryable.callCount += 1
            throw CKError(.internalError)
        }
        expect(false, "retry backoff: a non-retryable error must propagate, not be swallowed")
    } catch let error as CKError {
        expect(error.code == .internalError, "retry backoff: the propagated error is the original non-retryable CKError, got \(error.code)")
    }
    expect(nonRetryable.callCount == 1, "retry backoff: a non-retryable error stops after exactly 1 call, got \(nonRetryable.callCount)")
    expect(nonRetryable.delays.isEmpty, "retry backoff: a non-retryable error never sleeps, got \(nonRetryable.delays)")

    print("cloudkit-sync-transport: retry backoff — 5 calls on networkFailure with delays [1, 2, 4, 8], last error surfaced; internalError propagates immediately after 1 call with zero sleeps")
}

func runCloudKitSyncTransportChecks() async throws {
    checkRoundTripEncoding()
    checkRecordNameIdempotency()
    checkServerRecordChangedClassifier()
    checkPresumedDuplicateSubscriptionClassifier()
    checkMalformedRecordRejection()
    checkOutboundIntegerOverflow()
    try await checkRetryBackoffSequence()
    print("ContinuumRevivedSyncChecks passed: CloudKitSyncTransport logic — round-trip (19/19 Op cases), record-name idempotency (OpId-derived, not payload-derived), serverRecordChanged classifier, presumed-duplicate-subscription classifier, malformed-record rejection, outbound integer overflow (checked conversion, no trap), retry backoff sequence (incl. non-retryable passthrough), all headless (no CKContainer/CKDatabase instantiated)")
}
