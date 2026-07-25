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
//   ~/Library/Application Support/continuum-revived/agents/<agentId>.json
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
    public var backupsDirectory: URL {
        agentsDirectory.appendingPathComponent("backups", isDirectory: true)
    }

    public func agentFile(id: AgentID) -> URL {
        agentsDirectory.appendingPathComponent("\(id.rawValue.uuidString).json", isDirectory: false)
    }
}

public final class AgentStore: @unchecked Sendable {
    public let layout: AgentStoreLayout
    private let writer: AtomicWriter
    private let warn: (String) -> Void

    /// `applicationSupportDirectory == nil` resolves the root the way the app
    /// does — `CONTINUUM_APP_SUPPORT` first, then the canonical
    /// `continuum-revived` directory `RegistryStore` and `WorkspaceStore`
    /// already use. Going straight to the canonical path here would make a
    /// default-constructed store ignore the override the whole matrix runs
    /// under, which is the packet's watch-out with the sign flipped. Checks pass
    /// an explicit temp root, which is what keeps them off the real store.
    public init(
        applicationSupportDirectory: URL? = nil,
        retainedBackups: Int = 3,
        warn: @escaping (String) -> Void = { fputs($0 + "\n", stderr) }
    ) {
        let baseDir = applicationSupportDirectory
            ?? AgentStore.resolveApplicationSupportDirectory(smokeTest: false)
            ?? RegistryStore.defaultApplicationSupportDirectory()
        self.layout = AgentStoreLayout(applicationSupportDirectory: baseDir)
        self.writer = AtomicWriter(
            backupsDirectory: layout.backupsDirectory,
            retainedBackups: retainedBackups
        )
        self.warn = warn
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
        try writer.write(record, to: layout.agentFile(id: record.id))
    }

    public func load(id: AgentID) throws -> AgentRecord? {
        let url = layout.agentFile(id: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try writer.read(at: url)
    }

    public func delete(id: AgentID) throws {
        let url = layout.agentFile(id: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    /// Every agent from every project. One unreadable file is skipped and named
    /// on stderr rather than taking the whole inbox down with it — a store the
    /// sidebar reads on every refresh cannot have a single-file failure mode.
    ///
    /// Order is `createdAt` then id, so a caller that wants the frozen list
    /// order of the locked decisions gets the same sequence on every load; the
    /// directory enumeration order is not stable and must never be relied on.
    public func loadAll() throws -> [AgentRecord] {
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
                let record: AgentRecord = try writer.read(at: entry)
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
