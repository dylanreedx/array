import Foundation

public final class ManagedAgentSessionStore: @unchecked Sendable {
    private let writer: AtomicWriter
    private let layout: ProjectStoreLayout

    public init(projectRoot: URL, retainedBackups: Int = 3) {
        self.layout = ProjectStoreLayout(projectRoot: projectRoot)
        self.writer = AtomicWriter(
            backupsDirectory: layout.backupsDirectory,
            retainedBackups: retainedBackups
        )
    }

    public func upsert(_ record: ManagedAgentSessionRecord) throws {
        try writer.write(record, to: layout.managedSessionFile(tileId: record.tileId))
    }

    /// ONE TILE, and deliberately NOT gated behind the sweep (P3.2, design §5.8).
    /// Six callers key by tile and are boot-critical — the tmux window-target
    /// lookups in `ZoneRuntimeController`, `TileSpawner`'s respawn guard and
    /// `AppDelegate.managedSessionRecord(forTileId:)` — and a tmux window
    /// restore that had to wait for a reconciliation would break at boot. What
    /// they read (`runtimePayload`, `resumeCursor`) is preserved verbatim by the
    /// sweep; only the LISTING ("which agents exist, and what were they doing")
    /// is gated, because that is what a surface answers a human with.
    public func load(tileId: UUID) throws -> ManagedAgentSessionRecord? {
        let url = layout.managedSessionFile(tileId: tileId)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try writer.read(at: url)
    }

    public func delete(tileId: UUID) throws {
        let url = layout.managedSessionFile(tileId: tileId)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    /// The raw listing. Core's own reader (the sweep, the cross-project walk) and
    /// the store's round-trip check; NOT for a surface — see
    /// `reconciledRecords(_:)`, which is the gated door, and
    /// `checkManagedSessionReadGateSources` in the app target, which fails if any
    /// App file lists records through this one.
    public func loadAll() throws -> [ManagedAgentSessionRecord] {
        let dir = layout.managedSessionsDirectory
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
        let entries = try FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        var records: [ManagedAgentSessionRecord] = []
        for entry in entries where entry.pathExtension == "json" {
            do {
                records.append(try writer.read(at: entry))
            } catch {
                continue
            }
        }
        return records
    }

    /// The whole listing, readable only by a caller holding the sweep's `Proof`.
    /// Structural, not advisory: `Proof.init` is internal to this module, so a
    /// reader outside Core cannot compile a listing read that skipped
    /// reconciliation. The behavioural half — which call sites must move onto
    /// this and stop swallowing errors — belongs to P3.2.
    public func reconciledRecords(_ proof: ManagedSessionReconciliation.Proof) throws -> [ManagedAgentSessionRecord] {
        try loadAll()
    }
}

/// The launch sweep. A record proves something happened, never that something is
/// happening: at launch (and again on a graceful quit) every persisted record
/// whose status still claims liveness is terminalized with a stated reason,
/// before any surface can read it.
///
/// Deliberately an explicit call and never an initializer side effect — an
/// observer-wiring fixture that constructs a store must not have its records
/// swept out from under it mid-check.
public struct ManagedSessionReconciliation {
    /// What one sweep did, in ids so a check can name the record it means.
    /// Both id lists are sorted, because `loadAll()` walks a directory.
    public struct Report: Equatable, Sendable {
        public let scanned: Int
        public let terminalized: [UUID]
        public let alreadyTerminal: [UUID]

        public init(scanned: Int, terminalized: [UUID], alreadyTerminal: [UUID]) {
            self.scanned = scanned
            self.terminalized = terminalized
            self.alreadyTerminal = alreadyTerminal
        }
    }

    /// Evidence that a store was reconciled in this process. Carries nothing —
    /// its only property is that it cannot be minted outside Core, so a reader
    /// cannot pretend the sweep ran.
    public struct Proof: Sendable {
        internal init() {}
    }

    /// Terminalize every non-terminal record in `store`.
    ///
    /// - A record that is ALREADY terminal is reported and NOT written. That skip
    ///   is the idempotency guarantee: a second sweep produces identical bytes
    ///   and no new backup, because `AtomicWriter` backs up on every write.
    /// - A non-terminal record is rebuilt through `init(...)` rather than mutated,
    ///   because `schemaVersion` is a `let` and the rebuild is what stamps the
    ///   current version — the migration marker.
    /// - `lastSeenAt` is CARRIED OVER, never restamped to `now`. It is the anchor
    ///   an elapsed reading is measured from; stamping it here would make every
    ///   restored agent look like it was last seen at launch. `now` is a
    ///   parameter so the sweep's clock is always the caller's — Core never reads
    ///   the wall clock here — and so no field added later can quietly reach for
    ///   `Date()` instead.
    @discardableResult
    public static func reconcile(
        store: ManagedAgentSessionStore,
        reason: ManagedSessionEndReason,
        now: Date
    ) throws -> (report: Report, proof: Proof) {
        let records = try store.loadAll()
        var terminalized: [UUID] = []
        var alreadyTerminal: [UUID] = []
        for record in records {
            guard !record.status.isTerminal else {
                alreadyTerminal.append(record.tileId)
                continue
            }
            // Rebuilt, not mutated: `schemaVersion` is a `let`, so going through
            // `init` is what stamps the current version, and that stamp is the
            // migration marker the byte assertion looks for. A reader that merely
            // reinterpreted a stale status on the way out would satisfy every
            // decoded assertion and leave the file still claiming liveness — which
            // is why this WRITES.
            try store.upsert(ManagedAgentSessionRecord(
                tileId: record.tileId,
                agentKind: record.agentKind,
                status: .cancelled,
                endedReason: reason,
                lastSeenAt: record.lastSeenAt,
                resumeCursor: record.resumeCursor,
                runtimePayload: record.runtimePayload
            ))
            terminalized.append(record.tileId)
        }
        let report = Report(
            scanned: records.count,
            terminalized: terminalized.sorted { $0.uuidString < $1.uuidString },
            alreadyTerminal: alreadyTerminal.sorted { $0.uuidString < $1.uuidString }
        )
        return (report, Proof())
    }
}
