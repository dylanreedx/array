# CloudKit private-database sync transport

> **RULING BANNER — C-20260705-023 (night3 B2, orchestrator 2026-07-05). Binding; overrides the
> ticket text below where they conflict.**
>
> 1. **Conformance surface = the landed ticket-55 seam**, `ContinuumRevivedSync.SyncTransport`
>    (`Sources/ContinuumRevivedSync/SyncTransport.swift:56`): `send(_ message: SyncMessage) async
>    throws` + `inbound: AsyncStream<SyncMessage>` + `connectionState: AsyncStream<ConnectionState>`.
>    The breadcrumb `push/subscribe/fetchChanges` shape below describes the FROZEN ticket-12 Core
>    seam (`Sources/ContinuumRevivedCore/Substrates/SyncTransport.swift`) — it is NOT the
>    conformance target; do not modify that Core file. The breadcrumbs REMAIN authoritative for the
>    CloudKit mechanics: `SyncOp` record schema keyed `"\(lamport)-\(replicaUUID)"` (idempotency by
>    record ID; `.serverRecordChanged` treated as success), retry taxonomy + backoff (1/2/4/8 s
>    capped 30, non-retryable errors propagate immediately), silent-push `CKQuerySubscription`
>    named `"continuum-sync-ops"` with duplicate-subscription-as-success, LWW snapshot record.
>    Message mapping: `.op(LoggedOp)` → `SyncOp` record; `.snapshot(CompactedSnapshot)` → LWW
>    snapshot record keyed by a stable name; `.activity(ActivityStreamItem)` → design honestly
>    (LWW or sequence-keyed records); `.activitySubscribe` is a peer-request message with no
>    CloudKit peer semantics — a documented local trigger (fetch/refetch arming) rather than a
>    stored record is acceptable. Received records surface through `inbound`; `fetchChanges`
>    becomes an internal method on the concrete type (called by the app-lifecycle layer on
>    push/foreground), not a protocol requirement.
> 2. **C-20260701-009 applies:** read this ticket's `ActivityTreeSnapshot` as the shipped types —
>    the seam's payloads are `CompactedSnapshot`/`ActivityStreamItem` (`ActivityLogSnapshot` is the
>    byTile read model). Do not introduce a new `ActivityTreeSnapshot` type.
> 3. **No app-startup injection tonight:** `Sources/ContinuumRevived/` has ZERO `SyncTransport`
>    references — no coordinator/injection site exists (that wiring belongs to the supervisor/
>    wiring tickets). Do NOT invent app-runtime wiring or touch `ContinuumApp.swift` for the swap;
>    that Done-when line is descoped to the ticket that creates the seam's consumer. DO create
>    `Sources/ContinuumRevived/ContinuumRevived.entitlements` with the two iCloud keys exactly as
>    specified (the SwiftPM build has no Xcode project to reference it; it is the artifact for
>    signed-app packaging — say so in a comment in the file or a sibling note).
> 4. **Headless verification (night-3 amendment):** never instantiate `CKContainer`/`CKDatabase`
>    in any check (unentitled process = crash); `CKRecord`/`CKError` VALUES are headless-safe and
>    are what the logic checks use. The four logic suites (round-trip per Op case, record-name
>    idempotency, malformed-record rejection, injected-sleep retry sequence incl. non-retryable
>    passthrough) live in `ContinuumRevivedSyncChecks` (NOT CoreChecks — the types live in the Sync
>    module) and are wired into `scripts/run-matrix.sh`. The gated
>    `ContinuumRevivedSyncIntegrationChecks` target compiles, skips gracefully without
>    `CLOUDKIT_ENABLED=1` (manifest records `cloudkit_available=false`), and the real-CK leg is
>    tagged `device-gate-owed` for the morning checklist. Do NOT fake a green CK integration.
> 5. **ComponentLab:** pure transport, no user-visible surface → exempt per the night-3 rule,
>    unless the diff adds a desktop-visible component (then a lab card is required in-commit).
>
> **REV.2 (orchestrator adjudication, 2026-07-05, post round-3 dual review — supersedes point 1's
> subscription/zone mechanics):**
>
> - **RATIFIED: custom zone + zone subscription.** The round-1–3 implementation writes all records
>   to a custom `CKRecordZone` (`ContinuumSyncZone`) and registers a `CKRecordZoneSubscription`
>   (subscription ID stays `"continuum-sync-ops"`) instead of the breadcrumbs' default-zone
>   `CKQuerySubscription`. The Claude reviewer confirmed the deviation is technically REQUIRED:
>   the private-DB default zone does not support `CKFetchRecordZoneChangesOperation` change
>   tokens, so the breadcrumbs' query-subscription + zone-changes-fetch pairing is internally
>   contradictory and could never deliver a tail; the custom-zone pairing matches the ticket's own
>   "unblocks" description of the iOS observer. C-023 was an ORCHESTRATOR ruling (not Dylan's) and
>   is hereby amended; the real-device confirmation (silent push on the zone subscription →
>   `fetchChanges` → SyncOp delivered ≤10 s) is `device-gate-owed` on the morning checklist,
>   flagged for Dylan's explicit ratification there.
> - **BINDING FIXES (from the round-3 review; each must land before commit):**
>   1. `ensureSubscription()` duplicate handling (`CloudKitSyncTransport.swift:448-471`): on
>      `serverRejectedRequest`, fetch the existing `"continuum-sync-ops"` subscription and verify
>      it is a `CKRecordZoneSubscription` for `cloudKitSyncZoneID` with
>      `shouldSendContentAvailable` — if it is anything else (e.g. a stale `CKQuerySubscription`),
>      delete and recreate it; never treat a wrong-shaped subscription as success.
>   2. Integration check honesty (`ContinuumRevivedSyncIntegrationChecks/main.swift:92-108`): the
>      gated check exercises the catch-up path, not silent-push delivery — rename the manifest key
>      `subscription_delivered` → `subscription_catchup_delivered`, and add a server-side
>      verification that the fetched subscription's type/zone/notificationInfo match the expected
>      shape. Real silent-push delivery remains `device-gate-owed`; the manifest must not imply
>      otherwise.
>   3. Outbound integer safety (`CloudKitSyncTransport.swift:136, :351`): outgoing `UInt64`
>      Lamport/activity sequence values must use CHECKED conversion to `Int64` — values above
>      `Int64.max` throw a typed `TransportError` (or encode losslessly some other way), never
>      trap. Add a logic check covering outbound overflow alongside the existing negative-inbound
>      case.

## What this delivers

After this ticket, the `SyncTransport` seam has a real, production-grade implementation
backed by CloudKit's private database. Every `LoggedOp` the op-log core produces is
durably stored as a `CKRecord` in the user's own iCloud — idempotently upserted by its
`OpId`, so replay and retry are always safe. A second record type holds the live activity
projection snapshot. A `CKSubscription` delivers change notifications to the Mac over
silent APNS pushes, so the transport tail is live and the client does not poll.

From the system's perspective the payoff is this: spatial state and the activity projection
can now move between a user's Apple devices — Mac to iOS observer, or Mac to Mac — at
zero operating cost, with Apple supplying the offline queue, the conflict-free upsert
semantics, and the identity layer. The implementation is entirely behind the
`SyncTransport` protocol seam, so the `FakeSyncTransport` used by the convergence fuzz
and every earlier test remains the test substrate; no test ever touches a real CloudKit
container. The relay-on-VPS upgrade path documented in the locked decisions remains one
refactor away from this seam.

## How it fits

This ticket sits at the end of the sync foundations chain and requires all of the earlier
op-log work to exist and be passing before it begins. The store-protocol seam gives the
injection point where a `CloudKitSyncTransport` can be swapped in for the
`FakeSyncTransport` at app startup. The op enum and logged-op envelope define the
`LoggedOp` type that maps to `CKRecord` fields. The op-log apply and compaction engine
produces the `CompactedSnapshot` that seeds the activity record type. The convergence fuzz
has already proven — RED→GREEN — that the op-log converges correctly under any delivery
order, which is the guarantee that makes CloudKit's eventual-delivery model acceptable.
The injectable substrates ticket defined the `SyncTransport` protocol shape that this
implementation conforms to; the `FakeSyncTransport` from that ticket becomes the test
double that this ticket's logic tests are written against.

What this ticket unblocks: the iOS observer can now receive a live tail of the spatial
and activity projections over the same CloudKit container. The APNS push path (which fires
on `needsAttention` state entries) depends on a device token registered on the iOS side
and the container identifier known here, both of which this ticket establishes. The
relay-on-VPS upgrade and any future multi-device topology work both start from this seam.

## The approach

The implementation is a concrete struct `CloudKitSyncTransport` conforming to
`SyncTransport`, living in the `ContinuumRevivedSync` target alongside the op-log core.
It holds a reference to `CKContainer` and communicates exclusively with the **private
database** (`container.privateCloudDatabase`). No `CKShare`, no public database, no
shared container — the locked decisions explicitly ruled out the shared-DB surface because
of known 2026 CloudKit sharing bugs.

**Record types.** Two `CKRecord.RecordType` constants define the schema:

- `"SyncOp"` — one record per `LoggedOp`. The record's `CKRecord.ID` is the string
  encoding of `OpId` (`"\(opId.lamport)-\(opId.replica.uuidString)"`), which is the
  idempotency key. Fields: `lamport: Int64`, `replica: String` (UUID), `opPayload: Data`
  (the op's canonical JSON, `makeOpLogEncoder()` with `.sortedKeys`). Upsert semantics:
  `CKModifyRecordsOperation` with `savePolicy: .ifServerRecordUnchanged` for records the
  client has never seen, and `savePolicy: .changedKeys` for re-saves that originate from
  the same replica (same `CKRecord.ID` → server already holds the record). In practice,
  because `OpId` is globally unique per op, every save is a first-time insert; the
  idempotent path only fires on retry after a network failure.
- `"ActivitySnapshot"` — one record per project (keyed by project UUID). Fields:
  `projectId: String`, `snapshotPayload: Data` (JSON-encoded `ActivityTreeSnapshot`),
  `updatedAt: Date`. The host overwrites this record each time the activity tree changes;
  observers fetch it on subscribe and receive delta pushes via subscription. This is a
  last-writer-wins projection, not an op-log — it is never used for spatial convergence.

**Op push path.** `push(_ op: LoggedOp) async throws` constructs a `CKRecord` for the
op, fills the three fields, and saves it with a `CKModifyRecordsOperation`. On
`CKError.serverRecordChanged` (the record already exists with the same ID, meaning a
prior push of this exact op succeeded), treat as success — this is the idempotency
contract. On transient errors (`CKError.networkFailure`, `CKError.serviceUnavailable`,
`CKError.requestRateLimited`), retry with exponential backoff: delays of 1 s, 2 s, 4 s,
8 s, then give up and surface the error. CloudKit's offline queue handles the device-level
enqueue; this retry layer handles transient server errors that occur while online.

**Subscription and tail delivery.** On `subscribe(handler:)`, register a
`CKQuerySubscription` on `"SyncOp"` with a `NSPredicate(value: true)` (all records) and
`CKSubscription.NotificationInfo` with `shouldSendContentAvailable: true` (silent push,
no badge or alert). When the app receives a `CKDatabaseNotification`, call
`fetchChanges()` to pull new records via `CKFetchRecordZoneChangesOperation` from the
default zone. Each new record is decoded back to `LoggedOp` and passed to the registered
handler. The subscription is created once per app launch; if it already exists on the
server (by a stable name `"continuum-sync-ops"`), the create call returns
`CKError.serverRejectedRequest` with `CKErrorCode.duplicateSubscription` — handle by
treating as success and proceeding.

**Activity snapshot push and pull.** `pushActivitySnapshot(_ snapshot: ActivityTreeSnapshot, forProject id: UUID) async throws` saves or overwrites the `"ActivitySnapshot"` record for that project. `fetchActivitySnapshot(forProject id: UUID) async throws -> ActivityTreeSnapshot?` fetches the current snapshot record. Both are straightforward single-record operations with no subscription required — the spatial op subscription fires often enough that the activity snapshot can be refetched on each change batch.

**Container identifier.** The `CKContainer` identifier is
`"iCloud.io.bannockburn.continuum"` — this must match the container provisioned in the
Apple Developer portal under Dylan's team and enabled in the app's entitlements. The
`CloudKitSyncTransport` takes this identifier as an init parameter rather than
hardcoding it, so tests and alternate builds can supply a different container name.

**Threading.** All CloudKit operations are `async throws` and the struct is `Sendable`.
The `CKModifyRecordsOperation` and `CKFetchRecordZoneChangesOperation` callbacks arrive
on arbitrary queues; wrap them with a checked continuation that resumes on a
`Task`-managed executor. No `DispatchQueue` locks; no `@MainActor` pinning on this layer.

## Where it lives

**Primary new file:**

- `Sources/ContinuumRevivedSync/CloudKitSyncTransport.swift` — the
  `CloudKitSyncTransport` struct, its `CKRecord` encoding/decoding helpers, the retry
  wrapper, and the subscription registration logic.

**Seam files this ticket must not modify:**

- `Sources/ContinuumRevivedCore/Substrates/SyncTransport.swift` — the `SyncTransport`
  protocol is already declared here by the injectable substrates ticket. This ticket only
  adds a conforming type; the protocol definition is frozen.
- `Sources/ContinuumRevivedCore/ProjectStore.swift` line 76 (`ProjectStore` struct) and
  `Sources/ContinuumRevivedCore/WorkspaceStore.swift` line 29 (`WorkspaceStore` struct) —
  these are the persistence seams this transport sits alongside, not inside. The transport
  is injected at the same site as the store — app startup — and the two are independent.

**Package.swift changes:**

The `ContinuumRevivedSync` target (added by ticket 06) gains no new dependencies for this
ticket — CloudKit is a system framework, not a Swift package, and is linked via
`linkerSettings: [.linkedFramework("CloudKit")]` on the `ContinuumRevivedSync` target.
The app target (`ContinuumRevived`) already links `CloudKit` via system framework
inheritance; the sync target needs the explicit setting because it is a library target and
does not inherit the app's link phase.

**Entitlement required:**

The app target's `.entitlements` file (create it if it does not yet exist; place it in
`Sources/ContinuumRevived/ContinuumRevived.entitlements`) must include:
`com.apple.developer.icloud-services` = `[CloudKit]` and
`com.apple.developer.icloud-container-identifiers` =
`["iCloud.io.bannockburn.continuum"]`. The Xcode project settings (or the xcconfig)
must reference this entitlements file for the `ContinuumRevived` target under both Debug
and Release configurations.

**App startup injection site:**

Locate the point in `Sources/ContinuumRevived/App/ContinuumApp.swift` where the
`FakeSyncTransport` or `nil`-transport is currently passed to the op-log coordinator
(added by whichever ticket wires the transport into the runtime — this ticket only
provides the implementation; the caller decides when to use it). Swap in
`CloudKitSyncTransport(containerIdentifier: "iCloud.io.bannockburn.continuum")` there.
Guard the swap behind `#if !DEBUG || CLOUDKIT_ENABLED` if the team wants to keep the fake
as the default in local development.

## Implementation breadcrumbs

```swift
// ContinuumRevivedSync/CloudKitSyncTransport.swift

import CloudKit
import Foundation

// Record type names — constants to avoid magic strings throughout.
enum CKRecordTypes {
    static let syncOp = "SyncOp"
    static let activitySnapshot = "ActivitySnapshot"
}

// Field names on SyncOp records.
enum SyncOpField {
    static let lamport    = "lamport"     // Int64
    static let replica    = "replica"     // String (UUID)
    static let opPayload  = "opPayload"   // Data (canonical JSON)
}

public struct CloudKitSyncTransport: SyncTransport, Sendable {
    private let db: CKDatabase
    private let containerIdentifier: String

    public init(containerIdentifier: String) {
        self.containerIdentifier = containerIdentifier
        self.db = CKContainer(identifier: containerIdentifier).privateCloudDatabase
    }

    // MARK: - SyncTransport conformance

    public func push(_ op: LoggedOp) async throws {
        let record = try encodeOpRecord(op)
        try await withRetry(maxAttempts: 5) {
            try await save(record: record)
        }
    }

    public func subscribe(handler: @escaping @Sendable (LoggedOp) -> Void) async throws {
        try await ensureSubscription()
        // The app's CKDatabaseNotification handler calls fetchChanges(handler:).
        // Register the handler in a transport-level store so fetchChanges can call it.
        // (Implementation detail: a SendableBox wrapping the closure, stored as a property.)
    }

    public func fetchChanges(handler: @escaping @Sendable (LoggedOp) -> Void) async throws {
        let op = CKFetchRecordZoneChangesOperation(
            recordZoneIDs: [CKRecordZone.default().zoneID],
            configurationsByRecordZoneID: [:]
        )
        op.recordWasChangedBlock = { _, result in
            if case .success(let record) = result,
               record.recordType == CKRecordTypes.syncOp,
               let loggedOp = try? decodeOpRecord(record) {
                handler(loggedOp)
            }
        }
        try await db.add(op)
    }

    // MARK: - Activity projection

    public func pushActivitySnapshot(
        _ snapshot: ActivityTreeSnapshot,
        forProject projectId: UUID
    ) async throws {
        let recordId = CKRecord.ID(recordName: "activity-\(projectId.uuidString)")
        let record = CKRecord(recordType: CKRecordTypes.activitySnapshot, recordID: recordId)
        record["projectId"]       = projectId.uuidString as CKRecordValue
        record["snapshotPayload"] = try JSONEncoder().encode(snapshot) as CKRecordValue
        record["updatedAt"]       = Date() as CKRecordValue
        try await db.save(record)
    }

    public func fetchActivitySnapshot(
        forProject projectId: UUID
    ) async throws -> ActivityTreeSnapshot? {
        let recordId = CKRecord.ID(recordName: "activity-\(projectId.uuidString)")
        guard let record = try? await db.record(for: recordId) else { return nil }
        guard let data = record["snapshotPayload"] as? Data else { return nil }
        return try JSONDecoder().decode(ActivityTreeSnapshot.self, from: data)
    }

    // MARK: - Encoding helpers

    private func encodeOpRecord(_ op: LoggedOp) throws -> CKRecord {
        let recordName = "\(op.opId.lamport)-\(op.opId.replica.uuidString)"
        let recordId = CKRecord.ID(recordName: recordName)
        let record = CKRecord(recordType: CKRecordTypes.syncOp, recordID: recordId)
        record[SyncOpField.lamport]   = op.opId.lamport as CKRecordValue
        record[SyncOpField.replica]   = op.opId.replica.uuidString as CKRecordValue
        record[SyncOpField.opPayload] = try JSONCodec.makeOpLogEncoder().encode(op.op) as CKRecordValue
        return record
    }

    private func decodeOpRecord(_ record: CKRecord) throws -> LoggedOp {
        guard
            let lamport = record[SyncOpField.lamport] as? Int64,
            let replicaStr = record[SyncOpField.replica] as? String,
            let replica = UUID(uuidString: replicaStr),
            let payloadData = record[SyncOpField.opPayload] as? Data
        else { throw TransportError.malformedRecord }
        let op = try JSONDecoder().decode(Op.self, from: payloadData)
        let opId = OpId(lamport: UInt64(lamport), replica: replica)
        return LoggedOp(opId: opId, op: op)
    }

    // MARK: - Subscription

    private func ensureSubscription() async throws {
        let sub = CKQuerySubscription(
            recordType: CKRecordTypes.syncOp,
            predicate: NSPredicate(value: true),
            subscriptionID: "continuum-sync-ops",
            options: [.firesOnRecordCreation]
        )
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true   // silent push
        sub.notificationInfo = info
        do {
            try await db.save(sub)
        } catch let error as CKError where error.code == .duplicateSubscription {
            // Already registered — treat as success.
        }
    }

    // MARK: - Retry

    private func save(record: CKRecord) async throws {
        do {
            try await db.save(record)
        } catch let error as CKError where error.code == .serverRecordChanged {
            // Record already exists with this ID — idempotency success.
        }
    }

    private func withRetry<T: Sendable>(
        maxAttempts: Int,
        _ body: () async throws -> T
    ) async throws -> T {
        var delay: TimeInterval = 1.0
        var lastError: Error?
        for attempt in 0 ..< maxAttempts {
            do {
                return try await body()
            } catch let error as CKError
                where [.networkFailure, .serviceUnavailable, .requestRateLimited]
                    .contains(error.code)
            {
                lastError = error
                if attempt < maxAttempts - 1 {
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    delay = min(delay * 2, 30)
                }
            }
        }
        throw lastError!
    }
}

enum TransportError: Error {
    case malformedRecord
}
```

The `SyncTransport` protocol (from the injectable substrates ticket) requires at minimum
`push`, `subscribe`, and `fetchChanges`. Match those requirements exactly; if the
protocol carries additional requirements (e.g. an `unsubscribe` for lifecycle cleanup),
implement them by calling `db.delete(withSubscriptionID: "continuum-sync-ops")`.

## How we test it

### Logic (pure Core checks)

All logic checks run in `ContinuumRevivedCoreChecks` using the `FakeSyncTransport` from
the injectable substrates ticket. Because the `CloudKitSyncTransport` requires a live
CloudKit container, **no logic check instantiates it** — that is what needs-substrate
means.

The logic checks for this ticket target the encoding and decoding helpers in isolation,
by making them `internal` (not `private`) and testing them directly, or by extracting
them as free functions in `CloudKitSyncTransport.swift`:

1. **Round-trip encoding.** Construct a `LoggedOp` with a known `OpId` and a
   `createTile` op. Call `encodeOpRecord`, then `decodeOpRecord` on the result. Assert
   the decoded `LoggedOp` equals the original. Assert the `CKRecord.ID.recordName` is
   exactly `"\(lamport)-\(replicaUUID)"`. Repeat for every `Op` case.

2. **Idempotency of record names.** Construct two `LoggedOp` values with the same
   `OpId` (same Lamport, same replica). Assert `encodeOpRecord` produces records with
   identical `CKRecord.ID.recordName` values. This proves that a retry would collide
   correctly on the server rather than creating a duplicate.

3. **Malformed record rejection.** Construct a `CKRecord` of type `"SyncOp"` with a
   missing `opPayload` field. Call `decodeOpRecord` and assert a `TransportError.malformedRecord`
   is thrown.

4. **Retry backoff sequence.** Extract `withRetry` as a `static func` that takes an
   injected `sleep` closure instead of `Task.sleep`. Test that it calls the body
   exactly `maxAttempts` times when every call throws a `CKError.networkFailure`, and
   that the delay sequence is `1, 2, 4, 8` (capped at `30`) between attempts. Assert
   that it stops retrying and surfaces the last error after the final attempt. Assert
   that a non-retryable error (e.g. `CKError.internalError`) is not retried — it
   propagates immediately.

### Backend (real-path integration)

The backend check requires a provisioned iCloud container and a signed app — it cannot
run on an unprovisioned machine or in the standard CI environment. It is gated behind
`CLOUDKIT_ENABLED=1` in the environment and skips gracefully otherwise, recording
`cloudkit_available=false` in the manifest.

When the gate is open: instantiate a `CloudKitSyncTransport` pointed at the real
container. Push a `LoggedOp` with a freshly generated `OpId`. Assert the save completes
without error. Immediately fetch the record by its `CKRecord.ID` via `db.record(for:)`
and assert the fields match the original op. Push the same op a second time (same
`OpId`) and assert no error is returned (idempotency). Register a subscription; push a
new op; call `fetchChanges` and assert the handler receives the new op within a 10-second
timeout. Record `push_latency_ms`, `fetch_latency_ms`, `idempotent_push_succeeded`, and
`subscription_delivered` in the manifest — never `{passed: true}`.

The activity snapshot backend check: call `pushActivitySnapshot` with a synthetic
`ActivityTreeSnapshot`. Immediately call `fetchActivitySnapshot` and assert the returned
value equals the pushed snapshot. Record `snapshot_push_latency_ms` and
`snapshot_fetch_roundtrip_succeeded`.

These checks live in a dedicated `ContinuumRevivedSyncIntegrationChecks` executable
target added to `Package.swift`, depending on `ContinuumRevivedSync`. They are never
run in the overnight matrix; they are run manually by the implementer when a provisioned
environment is available.

### UX (visual gate + dogfood snippet)

The visual gate is a two-device check. Open Continuum on the Mac. Move a tile on the
canvas. Within approximately five seconds (CloudKit's push latency), open the iOS
companion app (once it exists) and confirm the tile's updated position is reflected in the
observer view. The activity projection record for that project should show a
`snapshotPayload` with an `updatedAt` timestamp within five seconds of the Mac-side move.

The dogfood snippet for day-one verification (before the iOS app exists): open Continuum
on the Mac. Move a tile. Open the CloudKit Dashboard at
`https://icloud.developer.apple.com/dashboard` — navigate to the `iCloud.io.bannockburn.continuum`
container → Private Database → `SyncOp` records — and confirm a new record appeared with
the `lamport`, `replica`, and `opPayload` fields populated. The `opPayload` field should
decode as valid JSON matching the `Op` case for the move. This proves end-to-end push
without needing a second device.

## Execution mode

**Needs-substrate.** The production `CloudKitSyncTransport` requires a provisioned
CloudKit container (`iCloud.io.bannockburn.continuum`) enrolled in the Apple Developer
portal, an app signed with an entitlement referencing that container, and an iCloud
account on the test device. None of these can be satisfied by the CI matrix or by an
unsigned build. Logic tests use the `FakeSyncTransport` exclusively and are fully
autonomous; backend and UX verification both require a real account and a signed build.
An overnight agent can write and compile all code, run the logic checks, and push the
commit — but it cannot execute the backend or UX gates. Those gates must be performed by
a human with access to the provisioned environment.

## Done when

- [ ] `CloudKitSyncTransport` compiles in the `ContinuumRevivedSync` target with no
  warnings, conforming fully to the `SyncTransport` protocol
- [ ] `Package.swift` adds `linkedFramework("CloudKit")` to the `ContinuumRevivedSync`
  target's `linkerSettings`
- [ ] The app's `.entitlements` file includes `com.apple.developer.icloud-services` =
  `[CloudKit]` and `com.apple.developer.icloud-container-identifiers` =
  `["iCloud.io.bannockburn.continuum"]`
- [ ] `CKRecord.ID.recordName` for a `SyncOp` record is exactly `"\(lamport)-\(replicaUUID)"`;
  confirmed by the round-trip logic check
- [ ] Save policy for a first-time push is `ifServerRecordUnchanged`; a retry of the
  same `OpId` receives `CKError.serverRecordChanged` and treats it as success; confirmed
  by the idempotency logic check
- [ ] Retry logic fires on `networkFailure`, `serviceUnavailable`, and
  `requestRateLimited` with delays of 1 s, 2 s, 4 s, 8 s; non-retryable errors propagate
  immediately; confirmed by the retry logic check
- [ ] The subscription is named `"continuum-sync-ops"` and uses a silent push
  (`shouldSendContentAvailable: true`, no badge, no alert text)
- [ ] A duplicate-subscription error on `ensureSubscription` is handled as success
- [ ] The `ActivitySnapshot` record is keyed by `"activity-\(projectId.uuidString)"`
  and overwrites on each push (last-writer-wins); confirmed by the round-trip logic check
- [ ] `opPayload` is encoded with `JSONCodec.makeOpLogEncoder()` (sorted keys,
  non-pretty); confirmed by the encoding logic check
- [ ] All four logic check suites pass in the `ContinuumRevivedCoreChecks` binary with
  no regressions against prior checks
- [ ] The full project builds and links without error against the app target
- [ ] Backend integration checks exist in a `ContinuumRevivedSyncIntegrationChecks`
  target, skip gracefully when `CLOUDKIT_ENABLED` is absent, and are documented in the
  runbook as a manual gate

## Depends on / unblocks

This ticket depends on the store-protocol seam for the injection point where the
transport is wired at app startup. It depends on the op enum and logged-op envelope for
the `LoggedOp`, `OpId`, and `Op` types that it maps to `CKRecord` fields. It depends on
the op-log apply and compaction engine for the `ActivityTreeSnapshot` type and the
`JSONCodec.makeOpLogEncoder()` factory. It depends on the injectable substrates ticket
for the `SyncTransport` protocol definition and the `FakeSyncTransport` that remains the
test double throughout.

It unblocks the iOS observer: once this transport exists and the CloudKit container is
provisioned, an iOS app can read from the same private database using the standard
`CKFetchRecordZoneChangesOperation` pattern, receiving the spatial op tail and the
activity projection without any server of our own. It also establishes the container
identifier that the APNS push path will need (the container provisioned here is the same
one under whose umbrella the push certificate is managed). The relay-on-VPS upgrade path
starts from the `SyncTransport` seam and does not require revisiting this implementation
at all.

## Watch out for

**The entitlement must match the provisioned container exactly.** If
`iCloud.io.bannockburn.continuum` is not provisioned in the Apple Developer portal under
Dylan's team, every CloudKit call will return `CKError.notAuthenticated` or
`CKError.permissionFailure` — not a helpful error message. Provision the container and
verify it appears in the portal before writing a single line of CloudKit code. The
container identifier is also case-sensitive; a typo produces a different (unprovision)
container silently.

**`CKRecord.ID` reuse is the idempotency contract.** CloudKit does not deduplicate
records unless the `CKRecord.ID.recordName` matches. If the `recordName` construction
ever changes — for example, switching from `"\(lamport)-\(replicaUUID)"` to a different
format — previously pushed ops become orphans on the server, and a future fetch will see
duplicate records with different IDs for the same logical op. Freeze the record name
format as part of the schema and treat any change as a migration event, not a refactor.

**Save policy must be `ifServerRecordUnchanged` for new records, not `allKeys`.** Using
`.allKeys` on a record whose ID already exists on the server will overwrite it — correct
in this case because two pushes of the same `OpId` should have identical payloads, but
fragile if the client ever reconstructs a record incorrectly. `ifServerRecordUnchanged`
turns a duplicate push into a `serverRecordChanged` error that the retry wrapper already
handles as success. Do not change this policy without revisiting the idempotency contract.

**Silent push delivery is not guaranteed.** `CKSubscription` silent pushes (`shouldSendContentAvailable: true`) are subject to the OS's background-app-refresh budget.
If Continuum is not in the foreground and the device is in Low Power Mode, a push may be
coalesced or dropped. The correct response to a missed push is a catchup
`CKFetchRecordZoneChangesOperation` on next foreground — this is the standard CloudKit
pattern and should be wired at the app-lifecycle layer (not in this ticket, but in
whatever ticket connects the transport to `NSApplication` notifications). The transport
itself is not responsible for the catchup; it only needs to make `fetchChanges` callable.

**CloudKit's private database has no server-side schema migration.** If `SyncOp` or
`ActivitySnapshot` record types are changed — fields added, renamed, or removed — records
written by old clients will coexist with records written by new clients in the same
container. Design the decoder (`decodeOpRecord`) to be forward-tolerant: unknown `Op`
cases should decode as a no-op variant rather than throwing, so a new-format record
received by an old client does not crash the transport. Add an `unknown` case to the `Op`
enum if it does not already have one, or use `@unknown default` in the decode switch.
