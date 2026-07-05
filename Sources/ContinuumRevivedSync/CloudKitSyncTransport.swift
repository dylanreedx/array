import CloudKit
import Foundation
import ContinuumRevivedCore

// Ticket: docs/38-tickets/57-cloudkit-transport-impl.md
//
// RULING (C-20260705-023, night3 B2): the conformance surface is the LANDED
// ticket-55 seam — `ContinuumRevivedSync.SyncTransport` (`send`/`inbound`/
// `connectionState`), NOT the older ticket-12 Core seam's `push`/`subscribe`/
// `fetchChanges` shape the ticket's prose and breadcrumb describe. The
// breadcrumb REMAINS authoritative for the CloudKit mechanics (record schema,
// idempotency, retry taxonomy, subscription naming) — those are reproduced
// here, just wired through `send(_:)` and `inbound` instead of separate
// protocol methods. `fetchChanges`/`ensureSubscription` are internal (public,
// non-protocol) methods the app-lifecycle layer calls; no coordinator exists
// yet to wire them in (see the ticket's "No app-startup injection tonight").
//
// C-20260701-009 applies: `ActivityStreamItem`/`CompactedSnapshot` are the
// shipped payload types (not the ticket prose's `ActivityTreeSnapshot`).
//
// Headless safety (night-3 amendment #4): `CKContainer`/`CKDatabase` are
// NEVER instantiated by a logic check (an unentitled process crashes on
// container access) — only `init` touches `CKContainer`. `CKRecord`/`CKError`
// VALUES are safe to construct headlessly and are what the logic checks in
// `ContinuumRevivedSyncChecks` exercise directly against the free
// encode/decode/retry functions below.

// MARK: - Record schema

/// `CKRecord.RecordType` constants — one per record shape this transport
/// writes/reads. Kept as plain `String` (== `CKRecord.RecordType`) constants
/// to avoid magic strings at every call site.
public enum CKRecordTypes {
    /// One record per `LoggedOp` (ticket-02's spatial op envelope). Public so
    /// the headless logic checks (ContinuumRevivedSyncChecks) can assert
    /// against it directly — see the ticket's "How we test it".
    public static let syncOp = "SyncOp"
    /// A single LWW record carrying the latest `CompactedSnapshot` a replica
    /// has pushed — keyed by a stable name, never per-project (the ruling's
    /// ".snapshot(CompactedSnapshot) → LWW snapshot record keyed by a stable
    /// name").
    static let compactedSnapshot = "CompactedSnapshotLWW"
    /// A single LWW record carrying the latest `ActivityLogSnapshot` (the
    /// per-tile activity read model — see C-20260701-009).
    static let activitySnapshot = "ActivitySnapshotLWW"
    /// One record per `AgentActivityEvent`, keyed the same idempotent way as
    /// `SyncOp` (sequence + replicaId) — the append-only half of
    /// `ActivityStreamItem`.
    static let activityEvent = "ActivityEvent"
}

public enum SyncOpField {
    public static let lamport = "lamport"     // Int64
    public static let replica = "replica"     // String (UUID)
    public static let opPayload = "opPayload" // Data (canonical JSON, makeOpLogEncoder())
}

enum CompactedSnapshotField {
    static let payload = "snapshotPayload" // Data (JSON-encoded CompactedSnapshot)
}

enum ActivitySnapshotField {
    static let payload = "snapshotPayload" // Data (JSON-encoded ActivityLogSnapshot)
    static let updatedAt = "updatedAt"      // Date
}

enum ActivityEventField {
    static let sequence = "sequence"     // Int64
    static let replicaId = "replicaId"   // String (UUID)
    static let payload = "eventPayload"  // Data (JSON-encoded AgentActivityEvent)
}

/// Stable, frozen record names for the two LWW singletons. Changing either
/// string is a migration event (orphans the previous record), same discipline
/// as the `SyncOp` record-name format below.
enum CKStableRecordNames {
    static let compactedSnapshot = "compacted-snapshot"
    static let activitySnapshot = "activity-log-snapshot"
}

/// Frozen subscription id — a retry/duplicate-create must always target the
/// same subscription, never a fresh one.
let cloudKitSyncOpSubscriptionId = "continuum-sync-ops"

/// The custom record zone every record this transport writes lives in.
///
/// FIX (round-2 reviewer concern #1): the original implementation wrote
/// every record to the private database's DEFAULT zone and paired it with a
/// `CKQuerySubscription` + `db.recordZoneChanges(inZoneWith: .default())`.
/// That pairing is broken on real CloudKit: change-token-based zone
/// tracking (`CKFetchRecordZoneChangesOperation` /
/// `recordZoneChanges(inZoneWith:since:)`) is only supported for CUSTOM
/// zones in the private database — the default zone does not support
/// server change tokens. A `CKQuerySubscription`'s push payload is also the
/// wrong shape for that API (it is the per-record-fetch pairing, not the
/// zone-changes pairing). Net effect: the inbound op tail — the entire
/// point of this transport — would very likely never have delivered.
///
/// The fix: every record (`SyncOp`, `ActivityEvent`, and both LWW
/// singletons) lives in this custom zone instead, `ensureSubscription()`
/// below registers a `CKRecordZoneSubscription` on it (the zone-changes
/// pairing), and `fetchChanges()` calls `recordZoneChanges(inZoneWith:)`
/// against the same zone. This is provable headlessly (the round-trip
/// logic check asserts every encoded record's `recordID.zoneID` is this
/// zone) but the end-to-end push-delivery *behavior* still requires a
/// signed build on a real device — flag this explicitly on the morning
/// device-gate checklist: verify a silent push on this zone subscription
/// actually invokes `fetchChanges()` and delivers a `SyncOp` within the
/// ticket's 10s window before relying on the tail in production.
///
/// Public (like `syncOpRecordName`/`encodeOpRecord` above) so the headless
/// logic checks in `ContinuumRevivedSyncChecks` can assert every encoded
/// record targets this zone, without ever touching `CKContainer`/`CKDatabase`.
public let cloudKitSyncZoneID = CKRecordZone.ID(zoneName: "ContinuumSyncZone")

public enum TransportError: Error, Sendable, Equatable {
    case malformedRecord
    /// FIX (round-3 reviewer concern #3 / ticket "Outbound integer safety"):
    /// an outgoing `lamport`/`sequence` value above `Int64.max` cannot be
    /// represented in CloudKit's `Int64` field type. `Int64(someUInt64)`
    /// TRAPS (fatal error, not a throw) above that threshold — a corrupt or
    /// adversarial in-memory value must never crash the process. Thrown by
    /// `encodeOpRecord`/`encodeActivityEventRecord` instead of converting.
    case outboundIntegerOverflow
}

// MARK: - Free encode/decode helpers (headless-testable — never touch CKContainer/CKDatabase)

/// The idempotency key, frozen per the ticket's "Watch out": never change this
/// format without treating it as a migration event. Public so the round-trip
/// and idempotency logic checks can assert against it directly.
public func syncOpRecordName(for opId: OpId) -> String {
    "\(opId.lamport)-\(opId.replica.uuidString)"
}

/// Public (not `private`/`internal`) per the ticket's "How we test it": the
/// logic checks in `ContinuumRevivedSyncChecks` call this directly, without
/// ever instantiating `CloudKitSyncTransport` itself (which would touch
/// `CKContainer`).
public func encodeOpRecord(_ logged: LoggedOp) throws -> CKRecord {
    // FIX (round-3 reviewer concern #3): `Int64(someUInt64)` TRAPS for any
    // value above `Int64.max` — a bare force-conversion, not a throw. CKit's
    // `lamport` field is `Int64`; use the checked initializer and surface a
    // typed error instead of crashing the process on an out-of-range value.
    guard let lamport = Int64(exactly: logged.opId.lamport) else {
        throw TransportError.outboundIntegerOverflow
    }
    let recordId = CKRecord.ID(recordName: syncOpRecordName(for: logged.opId), zoneID: cloudKitSyncZoneID)
    let record = CKRecord(recordType: CKRecordTypes.syncOp, recordID: recordId)
    record[SyncOpField.lamport] = lamport as CKRecordValue
    record[SyncOpField.replica] = logged.opId.replica.uuidString as CKRecordValue
    record[SyncOpField.opPayload] = try JSONCodec.makeOpLogEncoder().encode(logged.op) as CKRecordValue
    return record
}

/// Forward-tolerant by construction of its caller (`fetchChanges`), not by
/// itself: `Op`'s hand-written `Codable` (SpatialOp.swift, frozen by ticket
/// 02) throws loudly on an unknown discriminator rather than decoding an
/// `unknown` no-op case — adding such a case is out of this ticket's scope
/// (it would mean modifying the frozen `Op` enum). `decodeOpRecord` therefore
/// throws `TransportError.malformedRecord` on any decode failure (missing
/// field OR unrecognized `Op` payload); `fetchChanges` below calls this with
/// `try?` and skips the record rather than aborting the whole fetch, which is
/// the forward-tolerant behavior the ticket's "Watch out" asks for, applied
/// at the call site instead of inside the frozen `Op` type. Public for the
/// same reason as `encodeOpRecord` above.
public func decodeOpRecord(_ record: CKRecord) throws -> LoggedOp {
    guard
        let lamportRaw = record[SyncOpField.lamport] as? Int64,
        // FIX (round-2 reviewer concern #8): `UInt64(lamportRaw)` traps at
        // runtime (fatal error, not a throw) when `lamportRaw` is negative —
        // a malformed/adversarial record must be *rejected*, not crash the
        // process. `UInt64(exactly:)` returns nil instead of trapping.
        let lamport = UInt64(exactly: lamportRaw),
        let replicaStr = record[SyncOpField.replica] as? String,
        let replica = UUID(uuidString: replicaStr),
        let payloadData = record[SyncOpField.opPayload] as? Data
    else { throw TransportError.malformedRecord }
    guard let op = try? JSONCodec.makeDecoder().decode(Op.self, from: payloadData) else {
        throw TransportError.malformedRecord
    }
    return LoggedOp(opId: OpId(lamport: lamport, replica: replica), op: op)
}

/// Free-function counterpart to `encodeOpRecord` for the `ActivityEvent`
/// record shape — extracted so the outbound-overflow logic check can drive
/// it headlessly, without touching `CKContainer`/`CKDatabase`, exactly like
/// `encodeOpRecord` above. `pushActivityItem`'s `.event` case calls this
/// directly.
public func encodeActivityEventRecord(_ event: AgentActivityEvent) throws -> CKRecord {
    // FIX (round-3 reviewer concern #3): same checked-conversion fix as
    // `encodeOpRecord` — `sequence` is also `UInt64` and also lands in an
    // `Int64` CloudKit field.
    guard let sequence = Int64(exactly: event.sequence) else {
        throw TransportError.outboundIntegerOverflow
    }
    let recordId = CKRecord.ID(
        recordName: "\(event.sequence)-\(event.replicaId.uuidString)", zoneID: cloudKitSyncZoneID
    )
    let record = CKRecord(recordType: CKRecordTypes.activityEvent, recordID: recordId)
    record[ActivityEventField.sequence] = sequence as CKRecordValue
    record[ActivityEventField.replicaId] = event.replicaId.uuidString as CKRecordValue
    record[ActivityEventField.payload] = try JSONEncoder().encode(event) as CKRecordValue
    return record
}

// MARK: - Retry

/// Extracted as a `static func` on a namespacing `enum` (not a method on
/// `CloudKitSyncTransport`) so the logic check can drive it with an injected
/// `sleep` closure instead of a real `Task.sleep` — see the ticket's "Retry
/// backoff sequence" check. Public for the same reason.
public enum CloudKitRetry {
    /// The three transient `CKError` codes this layer retries. Every other
    /// error (including non-`CKError` failures) propagates immediately.
    public static let retryableCodes: Set<CKError.Code> = [.networkFailure, .serviceUnavailable, .requestRateLimited]

    /// Retries `body` on a retryable `CKError`, sleeping 1s/2s/4s/8s between
    /// attempts (capped at 30s — never reached at the default 5 attempts, but
    /// honored if `maxAttempts` is raised). Surfaces the last error once
    /// attempts are exhausted; a non-retryable error propagates on the first
    /// throw.
    public static func withRetry<T: Sendable>(
        maxAttempts: Int = 5,
        sleep: @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        },
        _ body: @Sendable () async throws -> T
    ) async throws -> T {
        var delay: TimeInterval = 1.0
        var lastError: Error!
        for attempt in 0..<maxAttempts {
            do {
                return try await body()
            } catch let error as CKError where retryableCodes.contains(error.code) {
                lastError = error
                if attempt < maxAttempts - 1 {
                    try await sleep(delay)
                    delay = min(delay * 2, 30)
                }
            }
        }
        throw lastError
    }
}

// MARK: - Change-token persistence

/// Holds the `CKServerChangeToken` `fetchChanges()` continues from on its
/// next call, for the lifetime of the owning `CloudKitSyncTransport`
/// instance (round-2 reviewer concern #6 — see the doc comment on the
/// `changeTokenStore` property). Cross-app-launch persistence is out of
/// scope here: the ticket's "Watch out" assigns the foreground/push catchup
/// call to the app-lifecycle layer, not this transport, and that same
/// layer is the natural owner of any on-disk token persistence.
private actor ChangeTokenStore {
    private(set) var token: CKServerChangeToken?
    func update(_ newToken: CKServerChangeToken?) {
        token = newToken
    }
}

// MARK: - CloudKitSyncTransport

/// The real, production `SyncTransport` conformance, backed exclusively by
/// `container.privateCloudDatabase` (locked decisions rule out `CKShare`/the
/// public or shared database — see the ticket's "The approach"). A plain
/// `Sendable` struct, not an actor: `CKDatabase`/`CKContainer` are themselves
/// `NS_SWIFT_SENDABLE`, and the two `AsyncStream.Continuation`s are Sendable
/// value types whose `yield` is safe to call from any thread — no actor
/// isolation, `DispatchQueue` lock, or `@MainActor` pinning is needed on this
/// layer (per the ticket's "Threading").
public struct CloudKitSyncTransport: SyncTransport, Sendable {
    private let db: CKDatabase
    private let containerIdentifier: String
    public let inbound: AsyncStream<SyncMessage>
    public let connectionState: AsyncStream<ConnectionState>
    private let inboundContinuation: AsyncStream<SyncMessage>.Continuation
    private let connectionContinuation: AsyncStream<ConnectionState>.Continuation
    // FIX (round-2 reviewer concern #6): `fetchChanges()` must continue the
    // server-change-token tail across calls, not restart from nil every
    // time (which would re-fetch and re-yield the whole zone on every
    // push/foreground). `CloudKitSyncTransport` is a plain `Sendable`
    // struct with only `let` storage — an `actor` reference held by `let`
    // gives cross-call, cross-copy mutable state without a lock or
    // `@MainActor` pin, consistent with the type's "Threading" doctrine.
    private let changeTokenStore = ChangeTokenStore()

    public init(containerIdentifier: String) {
        self.containerIdentifier = containerIdentifier
        self.db = CKContainer(identifier: containerIdentifier).privateCloudDatabase
        let (inboundStream, inboundContinuation) = AsyncStream<SyncMessage>.makeStream()
        let (stateStream, stateContinuation) = AsyncStream<ConnectionState>.makeStream()
        self.inbound = inboundStream
        self.inboundContinuation = inboundContinuation
        self.connectionState = stateStream
        self.connectionContinuation = stateContinuation
        // CloudKit's model is request/response, not a persistent socket — it
        // has no "connection" lifecycle a real transport would drive this
        // stream from. `.connected` is the honest, permanent state; a future
        // ticket wiring app-lifecycle reachability signals in is free to
        // yield `.reconnecting`/`.disconnected` from outside this type.
        stateContinuation.yield(.connected)
    }

    // MARK: - SyncTransport conformance

    public func send(_ message: SyncMessage) async throws {
        switch message {
        case .op(let logged):
            try await pushOp(logged)
        case .snapshot(let snapshot):
            try await pushCompactedSnapshot(snapshot)
        case .activity(let item):
            try await pushActivityItem(item)
        case .activitySubscribe(let request):
            try await triggerActivityRefetch(request)
        case .spatialSubscribe:
            try await triggerSpatialRefetch()
        }
    }

    // MARK: - Push paths

    private func pushOp(_ logged: LoggedOp) async throws {
        let record = try encodeOpRecord(logged)
        try await ensureZone()
        try await CloudKitRetry.withRetry {
            do {
                let result = try await self.db.modifyRecords(
                    saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true
                )
                // Round-2 reviewer concerns #3/#5: don't just discard the
                // per-record `Result` — a per-item `.failure` must not be
                // silently treated as success even though `atomically: true`
                // means the common conflict path already surfaces as a
                // thrown error instead (handled below).
                try Self.throwOnSaveFailure(result.saveResults, for: record.recordID)
            } catch {
                // Idempotency contract: a retried push of the same OpId hits
                // a record that already exists server-side and gets rejected
                // as changed — that IS the success case (see ticket "Save
                // policy must be ifServerRecordUnchanged").
                if Self.isServerRecordChanged(error, key: record.recordID) { return }
                throw error
            }
        }
    }

    private func pushCompactedSnapshot(_ snapshot: CompactedSnapshot) async throws {
        let recordId = CKRecord.ID(recordName: CKStableRecordNames.compactedSnapshot, zoneID: cloudKitSyncZoneID)
        let record = CKRecord(recordType: CKRecordTypes.compactedSnapshot, recordID: recordId)
        record[CompactedSnapshotField.payload] = try JSONEncoder().encode(snapshot) as CKRecordValue
        try await ensureZone()
        try await CloudKitRetry.withRetry {
            // LWW overwrite: `.changedKeys`, not `.ifServerRecordUnchanged` —
            // this record is meant to be clobbered every push, never to
            // conflict (it is never used for spatial convergence).
            let result = try await self.db.modifyRecords(
                saving: [record], deleting: [], savePolicy: .changedKeys, atomically: true
            )
            try Self.throwOnSaveFailure(result.saveResults, for: record.recordID)
        }
    }

    private func pushActivityItem(_ item: ActivityStreamItem) async throws {
        try await ensureZone()
        switch item {
        case .snapshot(let snapshot):
            let recordId = CKRecord.ID(recordName: CKStableRecordNames.activitySnapshot, zoneID: cloudKitSyncZoneID)
            let record = CKRecord(recordType: CKRecordTypes.activitySnapshot, recordID: recordId)
            record[ActivitySnapshotField.payload] = try JSONEncoder().encode(snapshot) as CKRecordValue
            record[ActivitySnapshotField.updatedAt] = Date() as CKRecordValue
            try await CloudKitRetry.withRetry {
                // Same LWW-overwrite rationale as the compacted snapshot above.
                let result = try await self.db.modifyRecords(
                    saving: [record], deleting: [], savePolicy: .changedKeys, atomically: true
                )
                try Self.throwOnSaveFailure(result.saveResults, for: record.recordID)
            }
        case .event(let event):
            // Append-only and idempotent, mirroring SyncOp: (sequence,
            // replicaId) is the same total-order key AgentActivityEvent's own
            // doc names for cross-device ordering. Encoding extracted to the
            // free `encodeActivityEventRecord` (see its doc comment) so the
            // outbound-overflow logic check can drive it headlessly.
            let record = try encodeActivityEventRecord(event)
            try await CloudKitRetry.withRetry {
                do {
                    let result = try await self.db.modifyRecords(
                        saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true
                    )
                    try Self.throwOnSaveFailure(result.saveResults, for: record.recordID)
                } catch {
                    if Self.isServerRecordChanged(error, key: record.recordID) { return }
                    throw error
                }
            }
        }
    }

    /// `.activitySubscribe` is a peer-request message (per the seam's
    /// original design, a receiver asking a sender to start streaming). On
    /// CloudKit there is no peer to ask — per the ruling, this is honestly a
    /// local trigger: arm a refetch of the current activity snapshot and
    /// surface it on `inbound` as if a peer had just responded, rather than
    /// writing a record nobody would ever read.
    private func triggerActivityRefetch(_ request: ActivitySubscribeRequest) async throws {
        let recordId = CKRecord.ID(recordName: CKStableRecordNames.activitySnapshot, zoneID: cloudKitSyncZoneID)
        guard
            let results = try? await db.records(for: [recordId]),
            case .success(let record)? = results[recordId],
            let data = record[ActivitySnapshotField.payload] as? Data,
            let snapshot = try? JSONDecoder().decode(ActivityLogSnapshot.self, from: data)
        else { return }
        inboundContinuation.yield(.activity(.snapshot(snapshot)))
    }

    /// `.spatialSubscribe` is the same peer-request-with-no-peer shape as
    /// `.activitySubscribe` above (ticket 61b): honestly a local trigger that
    /// refetches the current spatial `CompactedSnapshot` LWW record and
    /// surfaces it on `inbound`. No tail push here — ongoing `.op` traffic
    /// arrives however it always has, via `fetchChanges()`'s zone-change poll
    /// (`forwardChangedRecord`'s `CKRecordTypes.syncOp` case, already wired).
    private func triggerSpatialRefetch() async throws {
        let recordId = CKRecord.ID(recordName: CKStableRecordNames.compactedSnapshot, zoneID: cloudKitSyncZoneID)
        guard
            let results = try? await db.records(for: [recordId]),
            case .success(let record)? = results[recordId],
            let data = record[CompactedSnapshotField.payload] as? Data,
            let snapshot = try? JSONDecoder().decode(CompactedSnapshot.self, from: data)
        else { return }
        inboundContinuation.yield(.snapshot(snapshot))
    }

    // MARK: - Zone lifecycle

    /// Creates `cloudKitSyncZoneID` if it does not already exist. Saving a
    /// `CKRecordZone` whose ID already exists is a documented no-op success
    /// (no `CKError`), so — unlike the subscription/record idempotency below
    /// — there is no duplicate-error case to special-case here. Called
    /// before every zone-scoped write; see the "Simplicity First" tradeoff
    /// noted at the `changeTokenStore` property: this is a struct with no
    /// mutable "zone already ensured" cache, so it is a cheap extra round
    /// trip per push rather than a stateful optimization.
    private func ensureZone() async throws {
        try await CloudKitRetry.withRetry {
            _ = try await self.db.modifyRecordZones(saving: [CKRecordZone(zoneID: cloudKitSyncZoneID)], deleting: [])
        }
    }

    // MARK: - Subscription (public: called once per app launch by the app-lifecycle layer)

    /// Registers the silent-push subscription on `cloudKitSyncZoneID`.
    ///
    /// FIX (round-2 reviewer concern #1): this used to be a
    /// `CKQuerySubscription` on `SyncOp` in the default zone, paired with
    /// `fetchChanges()`'s zone-changes fetch — a mismatched, likely
    /// non-functional pairing (see `cloudKitSyncZoneID`'s doc comment for
    /// why). A `CKRecordZoneSubscription` on the custom zone is the correct
    /// pairing for `recordZoneChanges(inZoneWith:since:)`: it fires for any
    /// record type saved into the zone (`SyncOp`, `ActivityEvent`, and both
    /// LWW singletons), matching what `fetchChanges()` actually fetches.
    ///
    /// Not a `SyncTransport` protocol requirement (the ticket-55 seam has
    /// none) — the caller (app-lifecycle layer, not yet wired per this
    /// ticket's "No app-startup injection tonight") invokes this once at
    /// launch.
    public func ensureSubscription() async throws {
        try await ensureZone()
        let subscription = CKRecordZoneSubscription(
            zoneID: cloudKitSyncZoneID,
            subscriptionID: cloudKitSyncOpSubscriptionId
        )
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true // silent push: no badge, no alert
        subscription.notificationInfo = info
        try await CloudKitRetry.withRetry {
            do {
                let result = try await self.db.modifySubscriptions(saving: [subscription], deleting: [])
                // Round-2 reviewer concerns #3/#5: check the per-subscription
                // Result too, not just the thrown error.
                if case .failure(let itemError)? = result.saveResults[subscription.subscriptionID] {
                    throw itemError
                }
            } catch {
                // FIX (round-3 reviewer concerns #1/#4): `.serverRejectedRequest`
                // alone is only a PRESUMPTION of "duplicate subscription" — see
                // `isPresumedDuplicateSubscription`'s doc. Confirm the
                // presumption against actual server state before declaring
                // success: fetch this fixed `subscriptionID` back and inspect
                // its SHAPE (round-3 binding fix #1) rather than merely its
                // existence — a stale subscription registered under an older
                // version of this transport (a `CKQuerySubscription` in the
                // default zone, per the pre-round-2 design) exists too, but
                // would leave the silent-push tail permanently dark if
                // waved through as success.
                guard Self.isPresumedDuplicateSubscription(error, subscriptionID: subscription.subscriptionID) else {
                    throw error
                }
                switch await Self.classifyExistingSubscription(subscription.subscriptionID, in: self.db) {
                case .matchesExpectedShape:
                    // The harmless duplicate-create race: a correctly-shaped
                    // subscription is already registered — success.
                    return
                case .wrongShape:
                    // Never treat a wrong-shaped subscription as success —
                    // delete it and recreate the correct
                    // CKRecordZoneSubscription in its place.
                    _ = try? await self.db.modifySubscriptions(saving: [], deleting: [subscription.subscriptionID])
                    let recreateResult = try await self.db.modifySubscriptions(saving: [subscription], deleting: [])
                    if case .failure(let itemError)? = recreateResult.saveResults[subscription.subscriptionID] {
                        throw itemError
                    }
                case .doesNotExist:
                    // The rejection was NOT a duplicate-create race — this is
                    // a real registration failure (quota, malformed request,
                    // server policy, etc). Propagate instead of silently
                    // swallowing, which is exactly the failure mode the
                    // reviewer flagged (the entire silent-push tail going
                    // dark with no error surfaced).
                    throw error
                }
            }
        }
    }

    /// The three possible server-side states of the fixed
    /// `"continuum-sync-ops"` subscription ID, as classified by
    /// `classifyExistingSubscription` below.
    private enum ExistingSubscriptionShape {
        /// A `CKRecordZoneSubscription` on `cloudKitSyncZoneID` with
        /// `shouldSendContentAvailable` — exactly what `ensureSubscription()`
        /// registers. Safe to treat a duplicate-create rejection as success.
        case matchesExpectedShape
        /// Something exists under this ID, but it is not that shape — e.g. a
        /// stale `CKQuerySubscription` left over from before the round-2 zone
        /// fix. Must be deleted and recreated, never waved through.
        case wrongShape
        /// Nothing exists under this ID at all — the presumed-duplicate
        /// rejection was actually a genuine, unrelated failure.
        case doesNotExist
    }

    /// Fetches `subscriptionID` and classifies its shape against what
    /// `ensureSubscription()` requires. This is the network-dependent half
    /// of the duplicate-subscription check — it necessarily touches
    /// `CKDatabase`, so unlike `isPresumedDuplicateSubscription` it is NOT
    /// headlessly testable and is not exercised by
    /// `ContinuumRevivedSyncChecks`; flagged `device-gate-owed` alongside the
    /// rest of the real-CloudKit behavior. `CKDatabase.fetch(withSubscriptionID:)`
    /// has no async overload in this SDK (unlike most other `CKDatabase`
    /// APIs), so it is wrapped in a checked continuation per the ticket's
    /// "Threading" guidance for callbacks that arrive on arbitrary queues.
    private static func classifyExistingSubscription(
        _ subscriptionID: CKSubscription.ID, in db: CKDatabase
    ) async -> ExistingSubscriptionShape {
        await withCheckedContinuation { continuation in
            db.fetch(withSubscriptionID: subscriptionID) { subscription, _ in
                guard let subscription else {
                    continuation.resume(returning: .doesNotExist)
                    return
                }
                guard
                    let zoneSubscription = subscription as? CKRecordZoneSubscription,
                    zoneSubscription.zoneID == cloudKitSyncZoneID,
                    zoneSubscription.notificationInfo?.shouldSendContentAvailable == true
                else {
                    continuation.resume(returning: .wrongShape)
                    return
                }
                continuation.resume(returning: .matchesExpectedShape)
            }
        }
    }

    /// Server-side verification, exposed for the gated integration check
    /// (ticket "Integration check honesty" fix), that the subscription
    /// `ensureSubscription()` left in place actually has the expected shape
    /// — a `CKRecordZoneSubscription` on `cloudKitSyncZoneID` with
    /// `shouldSendContentAvailable`. This proves the subscription's shape,
    /// never silent-push delivery itself (still `device-gate-owed`).
    public func verifySubscriptionShape() async -> Bool {
        switch await Self.classifyExistingSubscription(cloudKitSyncOpSubscriptionId, in: db) {
        case .matchesExpectedShape: return true
        case .wrongShape, .doesNotExist: return false
        }
    }

    /// Pulls the tail of changed records in `cloudKitSyncZoneID` since the
    /// last call and surfaces each as a `SyncMessage` on `inbound`. Not a
    /// protocol requirement — the app-lifecycle layer calls this on
    /// push/foreground (per the ruling; the transport itself has no notion
    /// of "foreground").
    public func fetchChanges() async throws {
        var moreComing = true
        while moreComing {
            let sinceToken = await changeTokenStore.token
            do {
                let result = try await CloudKitRetry.withRetry {
                    try await self.db.recordZoneChanges(inZoneWith: cloudKitSyncZoneID, since: sinceToken)
                }
                for modificationResult in result.modificationResultsByID.values {
                    guard case .success(let modification) = modificationResult else { continue }
                    forwardChangedRecord(modification.record)
                }
                await changeTokenStore.update(result.changeToken)
                moreComing = result.moreComing
            } catch let error as CKError where error.code == .zoneNotFound {
                // Nothing has ever been pushed yet — the zone doesn't exist.
                // Not an error condition; there is simply no tail yet.
                return
            }
        }
    }

    private func forwardChangedRecord(_ record: CKRecord) {
        switch record.recordType {
        case CKRecordTypes.syncOp:
            // `try?` — see decodeOpRecord's doc for why this is the
            // forward-tolerant behavior instead of a change to the frozen `Op`.
            if let logged = try? decodeOpRecord(record) {
                inboundContinuation.yield(.op(logged))
            }
        case CKRecordTypes.compactedSnapshot:
            if let data = record[CompactedSnapshotField.payload] as? Data,
               let snapshot = try? JSONDecoder().decode(CompactedSnapshot.self, from: data) {
                inboundContinuation.yield(.snapshot(snapshot))
            }
        case CKRecordTypes.activitySnapshot:
            if let data = record[ActivitySnapshotField.payload] as? Data,
               let snapshot = try? JSONDecoder().decode(ActivityLogSnapshot.self, from: data) {
                inboundContinuation.yield(.activity(.snapshot(snapshot)))
            }
        case CKRecordTypes.activityEvent:
            if let data = record[ActivityEventField.payload] as? Data,
               let event = try? JSONDecoder().decode(AgentActivityEvent.self, from: data) {
                inboundContinuation.yield(.activity(.event(event)))
            }
        default:
            break
        }
    }

    // MARK: - CKError classification

    /// A save conflict can surface either as the top-level thrown `CKError`
    /// (typical for a single-record, atomic `modifyRecords` call) or nested
    /// under `partialErrorsByItemID` — check both so a future move to
    /// `atomically: false` or a multi-record batch doesn't silently break the
    /// idempotency contract.
    ///
    /// PUBLIC (round-3 reviewer concern #2): this is a pure function over
    /// bare `Error`/`CKError` VALUES — no `CKContainer`/`CKDatabase` touched —
    /// so it (and the "treat as success" decision it gates at every
    /// `pushOp`/`pushActivityItem` call site, which is literally `if
    /// isServerRecordChanged(...) { return } else { throw }`) is directly
    /// unit-testable from `ContinuumRevivedSyncChecks`, closing the test-
    /// coverage gap the reviewer flagged on the ticket's idempotency
    /// Done-when line.
    public static func isServerRecordChanged(_ error: Error, key: CKRecord.ID) -> Bool {
        guard let ckError = error as? CKError else { return false }
        if ckError.code == .serverRecordChanged { return true }
        if let itemError = ckError.partialErrorsByItemID?[key] as? CKError {
            return itemError.code == .serverRecordChanged
        }
        return false
    }

    /// FIX (round-2 reviewer concern #2): the previous version matched
    /// `ckError.localizedDescription.lowercased().contains("duplicate")`.
    /// `localizedDescription` is presented in the device's locale; on any
    /// non-English locale the string would not contain the English word
    /// "duplicate", so this would misclassify the duplicate-subscription
    /// case as a real failure on every launch after the first — the exact
    /// opposite of the Done-when contract ("a duplicate-subscription error
    /// is handled as success"). There is no locale-independent `CKError.Code`
    /// for this (the current SDK has no `.duplicateSubscription` case — see
    /// the original comment this replaces).
    ///
    /// FIX (round-3 reviewer concerns #1/#4): the previous version treated
    /// this signal alone as PROOF and returned success unconditionally.
    /// `CKError.serverRejectedRequest` is documented as a *generic*
    /// nonrecoverable-rejection code — CloudKit also returns it for quota,
    /// malformed-request, and server-policy failures that have nothing to do
    /// with a duplicate subscription. Treating any such rejection as success
    /// would silently disable the entire silent-push tail on a genuine
    /// registration failure, with no error ever surfaced — the exact
    /// regression flagged. Renamed to `isPresumedDuplicateSubscription` to
    /// make that honest: this pure function is only the necessary-but-not-
    /// sufficient half of the classification (correlated on `.serverRejected
    /// Request` for our fixed `subscriptionID`, which `ensureSubscription()`
    /// only ever saves as one, well-formed subscription). The sufficient
    /// half — confirming the subscription actually exists server-side via a
    /// fetch — lives in `ensureSubscription()`'s call site
    /// (`subscriptionExists`), because it necessarily touches `CKDatabase`
    /// and therefore cannot be part of this headlessly-testable function.
    public static func isPresumedDuplicateSubscription(_ error: Error, subscriptionID: CKSubscription.ID) -> Bool {
        guard let ckError = error as? CKError else { return false }
        if ckError.code == .serverRejectedRequest { return true }
        if let itemError = ckError.partialErrorsByItemID?[subscriptionID] as? CKError {
            return itemError.code == .serverRejectedRequest
        }
        return false
    }

    /// Round-2 reviewer concerns #3/#5: `CKDatabase.modifyRecords` returns a
    /// per-record `Result` dictionary in addition to (optionally) throwing.
    /// With `atomically: true` a conflict is expected to surface as a thrown
    /// `CKError.partialFailure` (handled by `isServerRecordChanged` at each
    /// call site above) — but discarding the returned dictionary via `_ =`
    /// means a `.failure` delivered through it instead of a throw would be
    /// silently treated as success. Checking it explicitly closes that gap
    /// without weakening the atomic path: a `.success` here is a no-op, and
    /// a `.failure` throws the underlying error so the caller's existing
    /// `isServerRecordChanged` classification still applies to it.
    private static func throwOnSaveFailure(
        _ results: [CKRecord.ID: Result<CKRecord, Error>], for recordID: CKRecord.ID
    ) throws {
        if case .failure(let error)? = results[recordID] {
            throw error
        }
    }
}
