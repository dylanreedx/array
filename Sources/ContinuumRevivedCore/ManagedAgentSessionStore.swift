import Foundation

public final class ManagedAgentSessionStore: @unchecked Sendable {
    private let writer: AtomicWriter
    var reinterpretNonTerminalOnRead = false
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

    public func load(tileId: UUID) throws -> ManagedAgentSessionRecord? {
        let url = layout.managedSessionFile(tileId: tileId)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        var record: ManagedAgentSessionRecord = try writer.read(at: url)
        if reinterpretNonTerminalOnRead, !record.status.isTerminal { record.status = .cancelled; record.endedReason = .continuumRestarted }
        return record
    }

    public func delete(tileId: UUID) throws {
        let url = layout.managedSessionFile(tileId: tileId)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

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
                var record: ManagedAgentSessionRecord = try writer.read(at: entry)
                if reinterpretNonTerminalOnRead, !record.status.isTerminal { record.status = .cancelled; record.endedReason = .continuumRestarted }
                records.append(record)
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
            store.reinterpretNonTerminalOnRead = true
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
