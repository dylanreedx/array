import Darwin
import Foundation

// Ticket: docs/38-tickets/90-agent-ux/P2A.2-agent-store.md
//
// AGENTS ARE LISTABLE ACROSS PROJECTS. `ManagedAgentSessionStore` keeps one JSON
// file per tile under `ProjectStoreLayout.managedSessionsDirectory` — inside the
// project — and only `activeController.managedSessionStore` is reachable at
// runtime, so a cross-project inbox cannot be built on it. `AgentStore` is the
// same store shape (`AtomicWriter`, one JSON file per record, upsert / load /
// delete / loadAll) rooted in APPLICATION SUPPORT instead:
//
//   ~/Library/Application Support/Array/agents/<agentId>.json
//
// The project store is deliberately NOT reused — that root is the mistake being
// fixed, not an implementation detail. No migration of existing managed records
// happens here; P2A.7 owns that, and `ManagedAgentSessionStore` keeps running
// alongside this one until then.
//
// I5 (sync-boundary purity): `AgentRecord` is host-bound and must not cross the
// sync boundary. This store is the reason that holds in practice — it writes to
// a local app-support path and has no publish path of any kind. Recorded as an
// honest limit rather than a proof: nothing here *prevents* another file from
// handing an `AgentRecord` to Sync. `AgentRecordChecks`'s taint witness is the
// backstop for the common case; a source-level rule that Sync may not name the
// type would be the real guard, and it belongs in the hygiene script, which this
// packet does not name.

public struct AgentStoreLayout: Sendable {
    public let applicationSupportDirectory: URL

    public init(applicationSupportDirectory: URL) {
        self.applicationSupportDirectory = applicationSupportDirectory
    }

    public var agentsDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("agents", isDirectory: true)
    }

    /// Backups live *inside* `agents/`, mirroring `ProjectStoreLayout`. `loadAll`
    /// enumerates one level and takes `.json` files only, so this directory is
    /// never read back as a record.
    ///
    /// Up to 0.7.47 every record's backups sat directly in this folder, and each
    /// save listed all of it to number and prune its own three: 6,724 files for
    /// 2,228 agents, 10-21% of the main thread (2026-11-12). Each record now owns
    /// a subfolder, `backups(for:)`, so a save lists only its own backups. Files
    /// still here are moved by `AgentStore.migrateSharedBackups` on every launch.
    public var backupsDirectory: URL {
        agentsDirectory.appendingPathComponent("backups", isDirectory: true)
    }

    /// One record's backups. Named by the agent id, like its record file.
    public func backupsDirectory(for id: AgentID) -> URL {
        backupsDirectory.appendingPathComponent(id.rawValue.uuidString, isDirectory: true)
    }

    /// The deleted-agent tombstone's backups, apart from every record's.
    public var deletedAgentTilesBackupsDirectory: URL {
        backupsDirectory.appendingPathComponent("deleted-agent-tiles", isDirectory: true)
    }

    public func agentFile(id: AgentID) -> URL {
        agentsDirectory.appendingPathComponent("\(id.rawValue.uuidString).json", isDirectory: false)
    }

    /// Old, finished, tile-less records (`AgentRecordArchivePolicy`). Inside
    /// `agents/` like `backups/`, and for the same reason never read by
    /// `loadAll`, which lists one level and takes `.json` files only.
    public var archiveDirectory: URL {
        agentsDirectory.appendingPathComponent("archive", isDirectory: true)
    }

    public func archivedAgentFile(id: AgentID) -> URL {
        archiveDirectory.appendingPathComponent("\(id.rawValue.uuidString).json", isDirectory: false)
    }

    /// Archived files that hold no record: moved here once, never retried at
    /// boot, never deleted. A subdirectory, so nothing that lists the archive's
    /// `.json` files sees it.
    public var archiveQuarantineDirectory: URL {
        archiveDirectory.appendingPathComponent("quarantine", isDirectory: true)
    }

    // Ticket: docs/38-tickets/90-agent-ux/P3.15-wire-destructive-row-actions.md
    /// The tiles whose agent was deliberately deleted.
    ///
    /// OUTSIDE `agents/`, deliberately: `loadAll` enumerates that directory and reads
    /// every `.json` in it as an `AgentRecord`, so a file of tile ids living there
    /// would be warned about on every inbox refresh.
    public var deletedAgentTilesFile: URL {
        applicationSupportDirectory.appendingPathComponent("deleted-agent-tiles.json", isDirectory: false)
    }
}

public final class AgentStore: @unchecked Sendable {
    public let layout: AgentStoreLayout
    private let retainedBackups: Int
    private let warn: (String) -> Void

    /// `applicationSupportDirectory == nil` resolves the root the way the app
    /// does — `CONTINUUM_APP_SUPPORT` first, then the canonical
    /// `Array` directory `RegistryStore` and `WorkspaceStore`
    /// already use. Going straight to the canonical path here would make a
    /// default-constructed store ignore the override the whole matrix runs
    /// under, which is the packet's watch-out with the sign flipped. Checks pass
    /// an explicit temp root, which is what keeps them off the real store.
    public init(
        applicationSupportDirectory: URL? = nil,
        retainedBackups: Int = 3,
        migrationHookForQA: @escaping @Sendable () -> Void = {},
        warn: @escaping (String) -> Void = { fputs($0 + "\n", stderr) }
    ) {
        let baseDir = applicationSupportDirectory
            ?? AgentStore.resolveApplicationSupportDirectory(smokeTest: false)
            ?? RegistryStore.defaultApplicationSupportDirectory()
        self.layout = AgentStoreLayout(applicationSupportDirectory: baseDir)
        self.retainedBackups = retainedBackups
        self.warn = warn
        let layout = self.layout
        migration.enter()
        Self.migrationQueue.async { [migration] in
            migrationHookForQA()
            Self.migrateSharedBackups(layout: layout, warn: warn)
            migration.leave()
        }
    }

    /// One queue for every store in the process, so two stores on one root
    /// never move the same file at once.
    private static let migrationQueue = DispatchQueue(label: "AgentStore.backup-migration", qos: .utility)
    private let migration = DispatchGroup()

    /// Blocks until this store's launch move of shared backups has finished.
    /// Reads call it only when a record fails to decode, since only then can a
    /// backup still in the shared folder matter.
    public func waitForBackupMigration() {
        migration.wait()
    }

    /// Each record's writer keeps its backups in that record's own folder, so
    /// numbering and pruning a save list three files, not every agent's.
    /// `.targetDedicated` stays: the folder holds one target's backups only.
    private func writer(for id: AgentID) -> AtomicWriter {
        writer(backups: layout.backupsDirectory(for: id))
    }

    private func writer(backups: URL) -> AtomicWriter {
        AtomicWriter(
            backupsDirectory: backups,
            retainedBackups: retainedBackups,
            legacyBackupPolicy: .targetDedicated,
            preferBackupTimestampsForRetention: true
        )
    }

    /// Moves each backup 0.7.47 and earlier left in the shared folder into its
    /// record's folder (or the tombstone's), so the restore reader finds it
    /// where that record's writer now looks. Runs on every launch, off the main
    /// thread: 0.7.47 still writes into the shared folder, so a downgrade and
    /// upgrade heals on the next launch. Once the folder holds only the
    /// per-record subfolders this is one listing. A backup whose record no
    /// longer exists stays put; no save lists the shared folder, so it costs
    /// nothing. A name already taken in the destination is never overwritten:
    /// the moved file keeps both, with a `.moved-N` suffix.
    private static func migrateSharedBackups(layout: AgentStoreLayout, warn: (String) -> Void) {
        let shared = layout.backupsDirectory
        let fileManager = FileManager.default
        // The run-once marker an earlier build of this change wrote.
        try? fileManager.removeItem(at: shared.appendingPathComponent(".per-record-backups-v1"))
        guard fileManager.fileExists(atPath: shared.path),
              let names = try? fileManager.contentsOfDirectory(atPath: shared.path),
              let recordFiles = try? fileManager.contentsOfDirectory(atPath: layout.agentsDirectory.path)
        else { return }

        // Owner of each name: v2 names by the target's identity hash, pre-v2
        // names by the target's file stem.
        var byV2Prefix: [String: URL] = [:]
        var byLegacyStem: [String: URL] = [:]
        func own(_ target: URL, into directory: URL) {
            byV2Prefix[AtomicWriter.backupNamePrefix(
                forCanonicalIdentityPath: AtomicWriter.canonicalIdentityPath(for: target))] = directory
            byLegacyStem[target.deletingPathExtension().lastPathComponent + "."] = directory
        }
        for file in recordFiles where file.hasSuffix(".json") {
            guard let uuid = UUID(uuidString: String(file.dropLast(".json".count))) else { continue }
            let id = AgentID(rawValue: uuid)
            own(layout.agentFile(id: id), into: layout.backupsDirectory(for: id))
        }
        own(layout.deletedAgentTilesFile, into: layout.deletedAgentTilesBackupsDirectory)

        let v2Head = "array-backup-v2-"
        let v2PrefixLength = v2Head.count + 64 + 1
        for name in names {
            let destination: URL?
            if name.hasPrefix(v2Head) {
                destination = name.count > v2PrefixLength ? byV2Prefix[String(name.prefix(v2PrefixLength))] : nil
            } else if let dot = name.firstIndex(of: ".") {
                destination = byLegacyStem[String(name[...dot])]
            } else {
                destination = nil
            }
            guard let destination else { continue }
            let source = shared.appendingPathComponent(name)
            do {
                try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
                var target = destination.appendingPathComponent(name)
                var suffix = 1
                while fileManager.fileExists(atPath: target.path) {
                    target = destination.appendingPathComponent("\(name).moved-\(suffix)")
                    suffix += 1
                }
                try fileManager.moveItem(at: source, to: target)
            } catch {
                // Left in place; the next launch tries again.
                if fileManager.fileExists(atPath: source.path) {
                    warn("AgentStore: could not move backup \(name) into its record's folder: \(error)")
                }
            }
        }
    }

    /// The pure half of `AppDelegate.resolveAppSupportDir(smokeTest:)`, in Core
    /// so it is testable: an explicit `CONTINUUM_APP_SUPPORT` override wins, a
    /// smoke test gets a fresh temp directory, and `nil` means "fall through to
    /// the canonical Application Support path" — which is exactly what `init`
    /// above does with a nil root, so the two compose.
    public static func resolveApplicationSupportDirectory(
        smokeTest: Bool,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> URL? {
        if let override = environment["CONTINUUM_APP_SUPPORT"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        if smokeTest {
            let temp = temporaryDirectory
                .appendingPathComponent("continuum-smoke-appsupport-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
            return temp
        }
        return nil
    }

    /// The launch-time spelling: resolve the root from the same inputs the app
    /// has (`smokeTest` is a launch flag Core cannot see for itself) and root a
    /// store there. `smokeTest: true` is what keeps a smoke run out of the real
    /// store.
    public convenience init(
        smokeTest: Bool,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        retainedBackups: Int = 3,
        warn: @escaping (String) -> Void = { fputs($0 + "\n", stderr) }
    ) {
        self.init(
            applicationSupportDirectory: AgentStore.resolveApplicationSupportDirectory(
                smokeTest: smokeTest,
                environment: environment
            ) ?? RegistryStore.defaultApplicationSupportDirectory(),
            retainedBackups: retainedBackups,
            warn: warn
        )
    }

    public func upsert(_ record: AgentRecord) throws {
        try writer(for: record.id).write(record, to: layout.agentFile(id: record.id), retentionTimestamp: { $0.lastActivityAt })
    }

    /// Destructive cleanup must distinguish absence from inaccessible storage.
    /// Existing files (including corrupt files/symlinks) are preserved without
    /// decoding. Only an error-preserving POSIX ENOENT proves absence.
    public enum OwnershipPresence: Equatable, Sendable {
        case absent, present
        case indeterminate(Int32)
    }
    public func ownershipPresence(id: AgentID) -> OwnershipPresence {
        var info = stat()
        if lstat(layout.agentFile(id: id).path, &info) == 0 { return .present }
        let failure = errno
        guard failure == ENOENT else { return .indeterminate(failure) }
        // An archived agent still owns its checkout, and so does one whose
        // archived file was quarantined: nothing proves it gone.
        for file in [layout.archivedAgentFile(id: id),
                     quarantinedAgentFile(id: id)] {
            if lstat(file.path, &info) == 0 { return .present }
            let archiveFailure = errno
            guard archiveFailure == ENOENT else { return .indeterminate(archiveFailure) }
        }
        return .absent
    }

    public func load(id: AgentID) throws -> AgentRecord? {
        let url = layout.agentFile(id: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try writer(for: id).read(at: url, beforeBackup: waitForBackupMigration, recoveryTimestamp: { $0.lastActivityAt })
    }

    public func delete(id: AgentID) throws {
        // Every copy: a quarantined one left behind would bring a deleted
        // agent back on the next lookup by id.
        for copy in [layout.archivedAgentFile(id: id)] + quarantinedCopies(id: id)
            where FileManager.default.fileExists(atPath: copy.path) {
            try FileManager.default.removeItem(at: copy)
        }
        let url = layout.agentFile(id: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    // MARK: - Archive (performance at scale, item 4)

    /// Moves a record out of the set `loadAll` reads. One `rename(2)` on one
    /// volume: at every instant the record is in exactly one of the two
    /// places, so a crash can neither lose it nor leave two copies.
    public func archive(id: AgentID) throws {
        try FileManager.default.createDirectory(at: layout.archiveDirectory, withIntermediateDirectories: true)
        guard Darwin.rename(layout.agentFile(id: id).path, layout.archivedAgentFile(id: id).path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    /// Brings an archived record back into the live set and returns it; nil
    /// when the archive does not hold `id`. The record is decoded BEFORE it
    /// moves, so an unreadable file stays where it was rather than becoming a
    /// live record `loadAll` warns about forever. A live copy, if one exists,
    /// is newer by construction (nothing writes the archive) and wins.
    public func unarchive(id: AgentID) throws -> AgentRecord? {
        let archived = layout.archivedAgentFile(id: id)
        var info = stat()
        guard lstat(archived.path, &info) == 0 else { return nil }
        let live = layout.agentFile(id: id)
        if lstat(live.path, &info) == 0 {
            try FileManager.default.removeItem(at: archived)
            return try load(id: id)
        }
        func read() throws -> AgentRecord {
            try writer(for: id).read(at: archived, beforeBackup: waitForBackupMigration,
                                     recoveryTimestamp: { $0.lastActivityAt })
        }
        let record: AgentRecord
        do {
            record = try read()
        } catch {
            // Read twice before calling it damaged: a transient failure inside
            // the first read must not move a good record out of reach.
            do { record = try read() } catch { throw quarantineIfDamaged(archived, error) }
        }
        guard Darwin.rename(archived.path, live.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return record
    }

    /// The gate's off switch: every archived record goes back to the live set
    /// through `unarchive`, so each is decoded before it moves and a live copy
    /// wins. A file that cannot be read stays where it is and is reported, so
    /// one bad file never blocks the rest. An absent archive costs one lstat.
    public func unarchiveAll() -> (restored: [AgentRecord], unreadable: [(file: URL, error: Error)]) {
        let directory = layout.archiveDirectory
        var info = stat()
        guard lstat(directory.path, &info) == 0 else { return ([], []) }
        let names: [String]
        do { names = try FileManager.default.contentsOfDirectory(atPath: directory.path) } catch { return ([], [(directory, error)]) }
        var restored: [AgentRecord] = []
        var unreadable: [(file: URL, error: Error)] = []
        for name in names.sorted() where name.hasSuffix(".json") && !name.hasPrefix(".") {
            let file = directory.appendingPathComponent(name, isDirectory: false)
            guard let uuid = UUID(uuidString: String(name.dropLast(5))) else {
                // Not a name the archive writes: no lookup can ever reach it.
                unreadable.append((file, quarantine(file, CocoaError(.fileReadCorruptFile))))
                continue
            }
            do {
                if let record = try unarchive(id: AgentID(rawValue: uuid)) { restored.append(record) }
            } catch {
                unreadable.append((file, error))
            }
        }
        return (restored, unreadable)
    }

    /// An archived file read but held no record, and no backup recovered one.
    /// It now sits in `archiveQuarantineDirectory`; the warning that reports
    /// this error is the only one it gets.
    public struct ArchivedRecordQuarantined: Error, CustomStringConvertible {
        public let file: URL
        public let quarantinedAt: URL
        public let underlying: Error
        public var description: String {
            "\(file.lastPathComponent) held no readable record (\(underlying)); moved to \(quarantinedAt.path) and kept. "
                + "Asking for its agent by id reads it again; moving it back into agents/ as <agent id>.json restores it at the next launch"
        }
    }

    public func quarantinedAgentFile(id: AgentID) -> URL {
        layout.archiveQuarantineDirectory.appendingPathComponent("\(id.rawValue.uuidString).json", isDirectory: false)
    }

    /// The way back from the quarantine, by id only, so no boot pays for it: a
    /// record a build could not decode comes back once a build can. Decoded
    /// before it moves; a file that still holds no record stays and throws.
    /// nil when the quarantine does not hold `id`; a live copy wins.
    public func unquarantine(id: AgentID) throws -> AgentRecord? {
        let copies = quarantinedCopies(id: id)
        guard !copies.isEmpty else { return nil }
        var info = stat()
        let live = layout.agentFile(id: id)
        if lstat(live.path, &info) == 0 { return try load(id: id) }
        // The first copy that decodes wins: a damaged first copy must not mask
        // a readable later one. It returns under the canonical name.
        var failure: Error = CocoaError(.fileReadCorruptFile)
        for copy in copies {
            do {
                let record = try JSONCodec.makeDecoder().decode(AgentRecord.self, from: Data(contentsOf: copy))
                guard record.id == id else { throw CocoaError(.fileReadCorruptFile) }
                guard Darwin.rename(copy.path, live.path) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                return record
            } catch { failure = error }
        }
        throw failure
    }

    /// Every quarantined copy of `id`: `<id>.json`, then the suffixed copies
    /// `quarantine` makes when that name is taken.
    public func quarantinedCopies(id: AgentID) -> [URL] {
        let canonical = quarantinedAgentFile(id: id)
        var info = stat()
        var copies = lstat(canonical.path, &info) == 0 ? [canonical] : []
        let prefix = canonical.lastPathComponent + "."
        let names = (try? FileManager.default.contentsOfDirectory(atPath: layout.archiveQuarantineDirectory.path)) ?? []
        copies += names.filter { $0.hasPrefix(prefix) }.sorted()
            .map { layout.archiveQuarantineDirectory.appendingPathComponent($0, isDirectory: false) }
        return copies
    }

    /// Damaged, not unreachable: a file whose bytes cannot be read at all
    /// (permissions, I/O) may read next time, so it stays where it is.
    private func quarantineIfDamaged(_ file: URL, _ error: Error) -> Error {
        guard (try? Data(contentsOf: file)) != nil else { return error }
        return quarantine(file, error)
    }

    /// One move, never a delete. A name already taken in the quarantine (the
    /// same agent damaged twice) gets a suffix rather than replacing it.
    /// Returns the error to report: `ArchivedRecordQuarantined`, or `error`
    /// itself when the move failed and the file stays.
    private func quarantine(_ file: URL, _ error: Error) -> Error {
        let directory = layout.archiveQuarantineDirectory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch { return error }
        var target = directory.appendingPathComponent(file.lastPathComponent, isDirectory: false)
        if renamex_np(file.path, target.path, UInt32(RENAME_EXCL)) != 0 {
            guard errno == EEXIST else { return error }
            target = directory.appendingPathComponent("\(file.lastPathComponent).\(UUID().uuidString)", isDirectory: false)
            guard renamex_np(file.path, target.path, UInt32(RENAME_EXCL)) == 0 else { return error }
        }
        return ArchivedRecordQuarantined(file: file, quarantinedAt: target, underlying: error)
    }

    /// Every archived record, STRICT: one unreadable file throws. Only the
    /// destructive worktree repair reads the whole archive, and an incomplete
    /// known set would make an archived agent's checkout look orphaned.
    public func loadArchived() throws -> [AgentRecord] {
        let dir = layout.archiveDirectory
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
        let decoder = JSONCodec.makeDecoder()
        return try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            .filter { $0.pathExtension == "json" }
            .map { try decoder.decode(AgentRecord.self, from: Data(contentsOf: $0)) }
    }

    // Ticket: docs/38-tickets/90-agent-ux/P3.15-wire-destructive-row-actions.md
    //
    // WHY A TOMBSTONE EXISTS AT ALL. An `AgentRecord` is DERIVED state: a
    // `managedAgent` tile is persisted in its project's canvas, and the app mints a
    // new agent for any such tile it finds no record for. So deleting the record on
    // its own makes the row disappear and the agent come back under a new id on the
    // next launch — measured, three for three, on the owner's machine. The tile is
    // NOT deleted (closing/keeping a tile is P2A.4/P2A.5's decision and not an inbox
    // action's to make), so what is recorded instead is that this tile's agent was
    // deliberately deleted, and the wire-up reads it before spawning.
    //
    // Tile ids only — no name, path, prompt or record — so this file says nothing
    // about the agent that is gone.

    /// The tiles whose agent a person deleted. Empty when the file is missing or
    /// unreadable: a tombstone that cannot be read must not stop the app from
    /// running an agent, it may only fail to suppress one.
    public func loadDeletedAgentTiles() -> Set<UUID> {
        let url = layout.deletedAgentTilesFile
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            let ids: [UUID] = try writer(backups: layout.deletedAgentTilesBackupsDirectory)
                .read(at: url, beforeBackup: waitForBackupMigration, recoveryTimestamp: { (_: [UUID]) in nil })
            return Set(ids)
        } catch {
            warn("AgentStore.loadDeletedAgentTiles: unreadable at \(url.path): \(error)")
            return []
        }
    }

    /// Sorted on write, so the file is stable between two runs that deleted the same
    /// agents in a different order.
    public func setDeletedAgentTiles(_ tiles: Set<UUID>) throws {
        try writer(backups: layout.deletedAgentTilesBackupsDirectory)
            .write(tiles.sorted { $0.uuidString < $1.uuidString }, to: layout.deletedAgentTilesFile, retentionTimestamp: { (_: [UUID]) in nil })
    }

    /// Every agent from every project. One unreadable file is skipped and named
    /// on stderr rather than taking the whole inbox down with it — a store the
    /// sidebar reads on every refresh cannot have a single-file failure mode.
    ///
    /// Order is `createdAt` then id, so a caller that wants the frozen list
    /// order of the locked decisions gets the same sequence on every load; the
    /// directory enumeration order is not stable and must never be relied on.
    public func loadAll() throws -> [AgentRecord] {
        try loadAll(skipping: [])
    }

    /// Record files `loadAll` has decoded since launch, for the delegation-at-
    /// scale witness: a spawn that re-read every record cost 15% of main.
    public static var recordsDecodedForQA: Int { recordsDecoded.value }
    private static let recordsDecoded = QACounter()

    /// `loadAll` without decoding the records whose ids are in `known`: for a
    /// caller that already holds those, it costs one directory listing plus the
    /// records it does not have.
    public func loadAll(skipping known: Set<AgentID>) throws -> [AgentRecord] {
        let dir = layout.agentsDirectory
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
        let entries = try FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        var records: [AgentRecord] = []
        for entry in entries where entry.pathExtension == "json" {
            do {
                // A record file is always `<agent id>.json`; anything else keeps
                // the shared folder its backups were written to.
                let stem = entry.deletingPathExtension().lastPathComponent
                let id = UUID(uuidString: stem).map(AgentID.init(rawValue:))
                if let id, known.contains(id) { continue }
                let reader = id.map { writer(for: $0) } ?? writer(backups: layout.backupsDirectory)
                Self.recordsDecoded.increment()
                let record: AgentRecord = try reader.read(at: entry, beforeBackup: waitForBackupMigration, recoveryTimestamp: { $0.lastActivityAt })
                records.append(record)
            } catch {
                warn("AgentStore.loadAll: skipping unreadable record at \(entry.path): \(error)")
                continue
            }
        }
        return records.sorted(by: AgentStore.isOrderedBefore)
    }

    /// `createdAt` ascending, ties broken by the id's string form. Exposed so a
    /// caller re-sorting an in-memory list cannot invent a second ordering.
    public static func isOrderedBefore(_ lhs: AgentRecord, _ rhs: AgentRecord) -> Bool {
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt < rhs.createdAt
        }
        return lhs.id.rawValue.uuidString < rhs.id.rawValue.uuidString
    }
}
