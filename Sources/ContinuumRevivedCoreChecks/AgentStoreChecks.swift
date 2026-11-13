import ContinuumRevivedCore
import Foundation

// Ticket: docs/38-tickets/90-agent-ux/P2A.2-agent-store.md
//
// Five properties, each with a negative test observed red before the final code
// (quoted at each check):
//   1. The root is APPLICATION SUPPORT, not a project — the whole point of the
//      ticket, so it is asserted as a path, not left to the prose.
//   2. upsert / load / delete round-trip, and upsert overwrites in place.
//   3. `loadAll` returns agents from every project, in a DETERMINISTIC order
//      (createdAt, then id) that is neither the insertion order nor the
//      filename order — both of which a wrong implementation would produce.
//   4. An unreadable file is skipped and named, not thrown; and the skip is not
//      hiding `AtomicWriter`'s backup recovery, which is asserted separately.
//   5. Concurrent `upsert` of many agents loses none.

func runAgentStoreChecks() {
    do {
        let root = try makeAgentStoreTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try runAgentStoreLocationCheck(root: root)
        try runAgentStoreRoundTripCheck(root: root)
        try runAgentStoreCrossProjectOrderingCheck(root: root)
        try runAgentStoreCorruptFileCheck(root: root)
        try runAgentStoreConcurrentUpsertCheck(root: root)
        try runAgentStoreBackupScanCheck(root: root)
        try runAgentStoreBackupScaleCheck(root: root)
        try runAgentStoreDowngradeRoundTripCheck(root: root)
        try runHeldMigrationRecoveryCheck(root: root)
        try runRecoveryOrderingCheck(root: root)
        print("AgentStore checks: app-support root, round-trip, cross-project deterministic order, corrupt-file skip, concurrent upsert, one backup scan per save, save cost independent of agent count, and a 0.7.47 round trip healing passed")
    } catch {
        fputs("FAIL: AgentStore checks failed: \(error)\n", stderr)
        Foundation.exit(1)
    }
}

private struct AgentStoreCheckError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Every check gets its own subdirectory of one temp root, so nothing here can
/// reach the real store even if the default root were resolved by mistake.
private func makeAgentStoreTempRoot() throws -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("continuum-agent-store-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func makeAgentStoreFixture(
    id: AgentID,
    displayName: String = "Agent",
    cwd: String = "/Users/qa/Documents/personal/continuum",
    projectId: UUID? = nil,
    createdAt: Date,
    tileId: UUID? = nil
) -> AgentRecord {
    AgentRecord(
        id: id,
        displayName: displayName,
        role: "implementer",
        model: AgentModelConfig.defaultModel,
        thinking: AgentModelConfig.defaultThinking,
        cwd: cwd,
        projectId: projectId,
        createdAt: createdAt,
        lastActivityAt: createdAt.addingTimeInterval(30),
        tileId: tileId
    )
}

private func agentId(_ suffix: String) -> AgentID {
    AgentID(rawValue: UUID(uuidString: "2A200000-0000-4000-8000-0000000000\(suffix)")!)
}

// 1 · The root. `ManagedAgentSessionStore` writes into the PROJECT
// (`<project>/.array/managed-sessions/`), which is why a
// cross-project inbox is impossible today; this store must be somewhere no
// project owns. Asserted as a path relationship rather than a string literal, so
// it stays true if the app-support directory name ever moves.
// NEGATIVE TEST (observed red): rooting `agentsDirectory` at
// `ProjectStoreLayout(projectRoot: applicationSupportDirectory).managedSessionsDirectory`
// → "FAIL: AgentStore files are <app-support>/agents/<agentId>.json — got
// …/location/.array/managed-sessions/agents/2A200000-…-000000000001.json".
// The exact-path assertion is the one that fires; the `.array`
// assertion below is defence in depth for a root this one does not pin.
private func runAgentStoreLocationCheck(root: URL) throws {
    let base = root.appendingPathComponent("location", isDirectory: true)
    let store = AgentStore(applicationSupportDirectory: base)
    let id = agentId("01")
    let file = store.layout.agentFile(id: id)

    expect(file.path == base.appendingPathComponent("agents/\(id.rawValue.uuidString).json").path,
           "AgentStore files are <app-support>/agents/<agentId>.json — got \(file.path)")
    expect(!file.path.contains("/.array/"),
           "AgentStore keeps agents outside any project's .array directory — \(file.path)")
    expect(store.layout.backupsDirectory.path.hasPrefix(store.layout.agentsDirectory.path),
           "AgentStore backups live under the agents directory — \(store.layout.backupsDirectory.path)")

    // With nothing to resolve from, the root is the shared app-support directory
    // every other Core store already uses — reused, not re-spelled.
    let canonical = AgentStore(smokeTest: false, environment: [:])
    expect(canonical.layout.applicationSupportDirectory.path
            == RegistryStore.defaultApplicationSupportDirectory().path,
           "AgentStore's default root is the canonical app-support directory — got \(canonical.layout.applicationSupportDirectory.path)")

    // …but a store that resolves its own root must honour the override and the
    // smoke-test flag, because THAT is the direction that pollutes the real
    // store: a default-constructed `AgentStore()` in a process launched under
    // `CONTINUUM_APP_SUPPORT` (which every matrix leg is) writing to the user's
    // real agents directory.
    // NEGATIVE TEST (observed red): `init(applicationSupportDirectory:)`'s nil
    // branch going straight to `RegistryStore.defaultApplicationSupportDirectory()`
    // → "FAIL: a default-constructed AgentStore honours CONTINUUM_APP_SUPPORT
    // rather than the real store — got …/Library/Application Support/Array/agents".
    let overrideRoot = root.appendingPathComponent("env-override", isDirectory: true)
    let overridden = AgentStore(smokeTest: false, environment: ["CONTINUUM_APP_SUPPORT": overrideRoot.path])
    expect(overridden.layout.agentsDirectory.path == overrideRoot.appendingPathComponent("agents").path,
           "an AgentStore that resolves its own root honours CONTINUUM_APP_SUPPORT — got \(overridden.layout.agentsDirectory.path)")

    // The same property for the DEFAULT-constructed store, which is the one a
    // future call site will write by accident. This is the only assertion here
    // that has to reach through the real process environment, so it saves and
    // restores whatever the harness set.
    let previousOverride = ProcessInfo.processInfo.environment["CONTINUUM_APP_SUPPORT"]
    setenv("CONTINUUM_APP_SUPPORT", overrideRoot.path, 1)
    let defaulted = AgentStore()
    if let previousOverride {
        setenv("CONTINUUM_APP_SUPPORT", previousOverride, 1)
    } else {
        unsetenv("CONTINUUM_APP_SUPPORT")
    }
    expect(ProcessInfo.processInfo.environment["CONTINUUM_APP_SUPPORT"] == previousOverride,
           "the process environment is left exactly as it was found")
    expect(defaulted.layout.agentsDirectory.path == overrideRoot.appendingPathComponent("agents").path,
           "a default-constructed AgentStore honours CONTINUUM_APP_SUPPORT rather than the real store — got \(defaulted.layout.agentsDirectory.path)")
    let smokeStore = AgentStore(smokeTest: true, environment: [:])
    defer { try? FileManager.default.removeItem(at: smokeStore.layout.applicationSupportDirectory) }
    expect(!smokeStore.layout.agentsDirectory.path
            .hasPrefix(RegistryStore.defaultApplicationSupportDirectory().path),
           "a smoke-test AgentStore never roots in the real store — got \(smokeStore.layout.agentsDirectory.path)")

    // The pure half of `AppDelegate.resolveAppSupportDir(smokeTest:)`: an
    // explicit override wins, a smoke test is ISOLATED in its own temp dir (the
    // packet's watch-out — otherwise checks pollute the real store), and nil
    // means "use the canonical path".
    // NEGATIVE TEST (observed red): deleting the `smokeTest` branch from the
    // resolver → "FAIL: a smoke-test root is an isolated temp directory, never
    // the real store — got nil" (nil means the canonical path, i.e. the real
    // store — exactly the pollution the watch-out names).
    expect(AgentStore.resolveApplicationSupportDirectory(
                smokeTest: false,
                environment: ["CONTINUUM_APP_SUPPORT": overrideRoot.path])?.path == overrideRoot.path,
           "CONTINUUM_APP_SUPPORT overrides the app-support root")
    expect(AgentStore.resolveApplicationSupportDirectory(
                smokeTest: true,
                environment: ["CONTINUUM_APP_SUPPORT": overrideRoot.path])?.path == overrideRoot.path,
           "an explicit CONTINUUM_APP_SUPPORT wins over the smoke-test path")
    let smokeRoot = AgentStore.resolveApplicationSupportDirectory(
        smokeTest: true,
        environment: [:],
        temporaryDirectory: root
    )
    expect(smokeRoot != nil
            && smokeRoot!.path.hasPrefix(root.path)
            && smokeRoot!.path != RegistryStore.defaultApplicationSupportDirectory().path,
           "a smoke-test root is an isolated temp directory, never the real store — got \(String(describing: smokeRoot?.path))")
    expect(smokeRoot.map { FileManager.default.fileExists(atPath: $0.path) } == true,
           "the smoke-test root is created, so a store rooted there can write immediately")
    expect(AgentStore.resolveApplicationSupportDirectory(smokeTest: false, environment: [:]) == nil,
           "with no override and no smoke test the resolver defers to the canonical path")
}

// 2 · The store contract, in `ManagedAgentSessionStore`'s exact shape.
private func runAgentStoreRoundTripCheck(root: URL) throws {
    let store = AgentStore(applicationSupportDirectory: root.appendingPathComponent("round-trip", isDirectory: true))
    let id = agentId("11")
    let record = makeAgentStoreFixture(
        id: id,
        displayName: "Refactor the sidebar",
        createdAt: Date(timeIntervalSinceReferenceDate: 806_000_000.25),
        tileId: UUID(uuidString: "2A200000-0000-4000-8000-0000000000FF")!
    )

    try store.upsert(record)
    guard let loaded = try store.load(id: id) else {
        throw AgentStoreCheckError("round-trip load returned nil")
    }
    expect(loaded == record, "AgentStore round-trip preserves every field")

    // Upsert overwrites the same agent in place rather than appending a second
    // file — and the demoted `tileId` going nil is the case that matters: the
    // agent survives losing its view.
    var headless = record
    headless.tileId = nil
    headless.displayName = "Refactor the sidebar (detached)"
    try store.upsert(headless)
    let reloaded = try store.load(id: id)
    let afterOverwrite = try store.loadAll()
    expect(reloaded == headless, "AgentStore upsert overwrites the same agent in place")
    expect(afterOverwrite.count == 1, "an overwritten agent is one record, not two")

    try store.delete(id: id)
    let afterDelete = try store.load(id: id)
    let unknown = try store.load(id: agentId("99"))
    let emptied = try store.loadAll()
    expect(afterDelete == nil, "AgentStore delete removes the record")
    expect(unknown == nil, "AgentStore load of an unknown agent returns nil")
    expect(emptied.isEmpty, "loadAll of an emptied store is empty, not an error")
    // Deleting an agent that is not there is a no-op, not an error.
    try store.delete(id: agentId("99"))

    let unusedRoot = root.appendingPathComponent("never-written", isDirectory: true)
    let never = try AgentStore(applicationSupportDirectory: unusedRoot).loadAll()
    expect(never.isEmpty,
           "loadAll of a store whose directory does not exist yet is empty, not an error")
}

// 3 · Cross-project listing, which is the ticket's Goal, plus a deterministic
// order. The order assertion is guarded against vacuity twice: the expected
// order must differ from the insertion order AND from the filename order, so an
// implementation that returns either is red rather than coincidentally right.
// NEGATIVE TESTS (both observed red): dropping the `.sorted(by:)` from `loadAll`
// → "FAIL: loadAll is ordered by createdAt then id — got ["alpha-first",
// "beta-late", "beta-tied", "alpha-tied"]" — which is also the evidence that the
// directory enumeration order really is neither sorted nor insertion order;
// sorting by id alone → "FAIL: loadAll is ordered by createdAt then id — got
// ["alpha-tied", "beta-tied", "beta-late", "alpha-first"]".
private func runAgentStoreCrossProjectOrderingCheck(root: URL) throws {
    let store = AgentStore(applicationSupportDirectory: root.appendingPathComponent("ordering", isDirectory: true))

    let alpha = UUID(uuidString: "2A200000-0000-4000-8000-0000000000A1")!
    let beta = UUID(uuidString: "2A200000-0000-4000-8000-0000000000B2")!
    let base = Date(timeIntervalSinceReferenceDate: 806_000_000)

    // Two agents in project alpha, two in project beta — one of each headless.
    // The ids are deliberately NOT in createdAt order, and the two agents that
    // share a createdAt are what exercises the id tiebreak.
    let records = [
        makeAgentStoreFixture(id: agentId("24"), displayName: "beta-late",
                              cwd: "/Users/qa/beta", projectId: beta,
                              createdAt: base.addingTimeInterval(300)),
        makeAgentStoreFixture(id: agentId("29"), displayName: "alpha-first",
                              cwd: "/Users/qa/alpha", projectId: alpha,
                              createdAt: base, tileId: UUID()),
        makeAgentStoreFixture(id: agentId("23"), displayName: "beta-tied",
                              cwd: "/Users/qa/beta", projectId: beta,
                              createdAt: base.addingTimeInterval(100)),
        makeAgentStoreFixture(id: agentId("22"), displayName: "alpha-tied",
                              cwd: "/Users/qa/alpha", projectId: alpha,
                              createdAt: base.addingTimeInterval(100), tileId: UUID()),
    ]
    for record in records {
        try store.upsert(record)
    }

    let expectedNames = ["alpha-first", "alpha-tied", "beta-tied", "beta-late"]
    let insertionNames = records.map(\.displayName)
    let filenameNames = records
        .sorted { $0.id.rawValue.uuidString < $1.id.rawValue.uuidString }
        .map(\.displayName)
    // Vacuity guards: if the fixture ever degenerates so that all three orders
    // agree, this check would pass for an unsorted `loadAll`, and it says so
    // instead of going quietly green.
    expect(expectedNames != insertionNames,
           "the ordering fixture still discriminates against insertion order")
    expect(expectedNames != filenameNames,
           "the ordering fixture still discriminates against filename order")

    let loaded = try store.loadAll()
    expect(loaded.count == 4, "loadAll returns every agent from every project — got \(loaded.count)")
    expect(Set(loaded.compactMap(\.projectId)) == [alpha, beta],
           "loadAll spans both projects, which is what the project-rooted store cannot do")
    expect(loaded.filter { $0.tileId == nil }.count == 2,
           "headless agents (tileId == nil) are listed exactly like attached ones")
    expect(loaded.map(\.displayName) == expectedNames,
           "loadAll is ordered by createdAt then id — got \(loaded.map(\.displayName))")
    let reloadedOrder = try store.loadAll().map(\.id)
    expect(reloadedOrder == loaded.map(\.id),
           "loadAll's order is stable across calls")

    // Backups are a subdirectory of `agents/`; re-upserting produces one and it
    // must not read back as an extra record.
    try store.upsert(records[0])
    expect(FileManager.default.fileExists(atPath: store.layout.backupsDirectory.path),
           "re-upserting an agent writes a backup, so the backups directory is really present here")
    let afterBackup = try store.loadAll()
    expect(afterBackup.count == 4, "the backups directory is not enumerated as a record")
}

// 4 · A corrupt file is skipped, named, and does not take the inbox down.
// Two shapes are used because they fail differently: garbage bytes fail to
// parse as JSON at all, a truncated-but-valid JSON object fails to decode as an
// `AgentRecord`.
// NEGATIVE TEST (observed red): letting `writer.read` throw out of `loadAll`
// (removing the do/catch) → "FAIL: AgentStore checks failed: noValidBackup(path:
// "…/corrupt/agents/truncated.json")" — the whole listing lost to one bad file,
// which is the failure mode the skip exists to prevent.
private func runAgentStoreCorruptFileCheck(root: URL) throws {
    final class WarningLog: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func append(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
    }
    let warnings = WarningLog()
    let store = AgentStore(
        applicationSupportDirectory: root.appendingPathComponent("corrupt", isDirectory: true),
        warn: { warnings.append($0) }
    )

    let healthy = makeAgentStoreFixture(id: agentId("31"), displayName: "healthy",
                                        createdAt: Date(timeIntervalSinceReferenceDate: 806_000_000))
    try store.upsert(healthy)

    try "{not-json".write(to: store.layout.agentsDirectory.appendingPathComponent("garbage.json"),
                          atomically: true, encoding: .utf8)
    try #"{"schemaVersion":1,"displayName":"truncated"}"#
        .write(to: store.layout.agentsDirectory.appendingPathComponent("truncated.json"),
               atomically: true, encoding: .utf8)
    // A non-JSON file in the same directory is not a record and must not even be
    // reported as a skip.
    try "notes".write(to: store.layout.agentsDirectory.appendingPathComponent("README.txt"),
                      atomically: true, encoding: .utf8)

    let loaded = try store.loadAll()
    expect(loaded.map(\.displayName) == ["healthy"],
           "loadAll skips unreadable records and keeps going — got \(loaded.map(\.displayName))")
    expect(warnings.all.count == 2,
           "each skipped record is logged exactly once — got \(warnings.all)")
    expect(warnings.all.allSatisfy { $0.contains("AgentStore.loadAll") }
            && warnings.all.contains { $0.contains("garbage.json") }
            && warnings.all.contains { $0.contains("truncated.json") },
           "the skip names the file it dropped — got \(warnings.all)")
    let byId = try store.load(id: agentId("31"))
    expect(byId == healthy,
           "a corrupt sibling does not affect loading a healthy agent by id")

    // The skip above is a real skip, not `AtomicWriter`'s backup recovery
    // silently covering for it: an agent WITH a backup is recovered when its
    // main file is clobbered, and that is asserted here so the two behaviours
    // are not confused for one another.
    var revised = healthy
    revised.displayName = "healthy (revised)"
    try store.upsert(revised)
    try "{not-json".write(to: store.layout.agentFile(id: healthy.id), atomically: true, encoding: .utf8)
    let recovered = try store.loadAll()
    expect(recovered.map(\.displayName) == ["healthy"],
           "a clobbered record with a backup is recovered from it, not skipped — got \(recovered.map(\.displayName))")
}

// 5 · Concurrency. Two agents are two files, so `AtomicWriter`'s rename(2) is
// what makes this safe; the check exists because a store that shared one index
// file — the obvious "improvement" — would lose writes here.
// NEGATIVE TEST (observed red): keying every file on a constant name
// (`agents/agent.json`) instead of the agent id → "FAIL: concurrent upserts lose
// no agent — got 1 of 32". Recorded honestly: that edit is caught by check 1
// FIRST ("AgentStore files are <app-support>/agents/<agentId>.json — got
// …/agents/agent.json"), so the quoted line was observed with checks 1–4
// temporarily unrun — the witness is that check 5 discriminates on its own, not
// that this is the only gate that sees the edit.
private func runAgentStoreConcurrentUpsertCheck(root: URL) throws {
    let store = AgentStore(applicationSupportDirectory: root.appendingPathComponent("concurrent", isDirectory: true))
    let count = 32
    let base = Date(timeIntervalSinceReferenceDate: 806_000_000)
    let records = (0..<count).map { index in
        makeAgentStoreFixture(
            id: AgentID(rawValue: UUID(uuidString: String(format: "2A200000-0000-4000-8000-4%011d", index))!),
            displayName: "concurrent-\(index)",
            cwd: "/Users/qa/project-\(index % 4)",
            projectId: UUID(uuidString: String(format: "2A200000-0000-4000-8000-5%011d", index % 4))!,
            createdAt: base.addingTimeInterval(TimeInterval(index))
        )
    }

    final class FailureBox: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var errors: [Error] = []
        func record(_ error: Error) { lock.lock(); errors.append(error); lock.unlock() }
    }
    let failures = FailureBox()
    DispatchQueue.concurrentPerform(iterations: count) { index in
        do {
            try store.upsert(records[index])
        } catch {
            failures.record(error)
        }
    }
    expect(failures.errors.isEmpty, "no concurrent upsert threw — got \(failures.errors)")

    let loaded = try store.loadAll()
    expect(loaded.count == count, "concurrent upserts lose no agent — got \(loaded.count) of \(count)")
    expect(loaded == records, "every concurrently written agent round-trips, in createdAt order")
}

// 6 · One scan per save (.plans/81-live-performance). Every agent shares one
// backups directory (1,898 files for 625 agents on one machine), and a save
// scanned it twice on the main thread: once to number the new backup, once to
// prune. Pruning must reuse the first scan and still keep exactly
// `retainedBackups` of this agent's backups, leaving every other agent's alone.
private func runAgentStoreBackupScanCheck(root: URL) throws {
    let directory = root.appendingPathComponent("backup-scans", isDirectory: true)
    let store = AgentStore(applicationSupportDirectory: directory, retainedBackups: 3)
    let created = Date(timeIntervalSinceReferenceDate: 806_100_000)
    for index in 0..<20 {
        var neighbour = makeAgentStoreFixture(
            id: agentId(String(format: "%02X", 0x40 + index)), createdAt: created)
        try store.upsert(neighbour)
        neighbour.displayName = "Neighbour \(index)"
        try store.upsert(neighbour)
    }

    var record = makeAgentStoreFixture(id: agentId("7F"), createdAt: created)
    for revision in 0..<6 {
        record.displayName = "Revision \(revision)"
        let scansBefore = AtomicWriter.backupScanCountForQA
        try store.upsert(record)
        let scans = AtomicWriter.backupScanCountForQA - scansBefore
        guard revision == 0 || scans == 1 else {
            throw AgentStoreCheckError("save \(revision) scanned the shared backups directory \(scans) times; one scan must serve both the backup and the prune")
        }
    }
    guard try store.load(id: record.id)?.displayName == "Revision 5" else {
        throw AgentStoreCheckError("the last save did not land")
    }
    let ownCount = try FileManager.default.contentsOfDirectory(
        atPath: store.layout.backupsDirectory(for: record.id).path).count
    guard ownCount == 3 else {
        throw AgentStoreCheckError("this agent keeps \(ownCount) backups after 6 saves; retention is 3")
    }
    for index in 0..<20 {
        let neighbour = agentId(String(format: "%02X", 0x40 + index))
        let kept = try FileManager.default.contentsOfDirectory(
            atPath: store.layout.backupsDirectory(for: neighbour).path).count
        guard kept == 1 else {
            throw AgentStoreCheckError("neighbour \(index) keeps \(kept) backups after this agent's saves; it wrote 1")
        }
    }
}

// 7 · A save's cost does not depend on how many agents exist (2026-11-12,
// .plans/110 "Live usage profile"). Dylan's 0.7.47 had 2,228 agents and 6,724
// backups in ONE `agents/backups` folder, and every record save listed all of
// it on the main thread: 10-21% of the main thread in every active sample.
//
// The store is seeded in the exact on-disk layout 0.7.47 wrote (v2 and legacy
// names, all in the shared folder), then opened by the current store. Each save
// must read the same number of directory entries with 20 neighbours as with
// 2,000; retention stays 3; no neighbour backup is lost; and the restore reader
// (`load` over a corrupt record) still finds migrated v2 and legacy backups.
private func runAgentStoreBackupScaleCheck(root: URL) throws {
    var perSave: [Int: [Int]] = [:]
    for neighbours in [20, 2_000] {
        perSave[neighbours] = try runAgentStoreBackupScale(
            root: root.appendingPathComponent("backup-scale-\(neighbours)", isDirectory: true),
            neighbours: neighbours)
    }
    let small = perSave[20]!, large = perSave[2_000]!
    guard small == large else {
        throw AgentStoreCheckError("directory entries read per save grow with the agent count: \(small) with 20 neighbours, \(large) with 2,000")
    }
}

/// Returns the directory entries each of six saves read.
private func runAgentStoreBackupScale(root: URL, neighbours: Int) throws -> [Int] {
    let layout = AgentStoreLayout(applicationSupportDirectory: root)
    let shared = layout.backupsDirectory
    try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
    let encoder = JSONCodec.makeEncoder(prettyPrinted: true)
    let created = Date(timeIntervalSinceReferenceDate: 806_100_000)
    func prefix(_ id: AgentID) -> String {
        AtomicWriter.backupNamePrefix(
            forCanonicalIdentityPath: AtomicWriter.canonicalIdentityPath(for: layout.agentFile(id: id)))
    }
    func v2Name(_ id: AgentID, generation: Int) -> String {
        prefix(id) + String(format: "%020d", generation) + "-2026-11-12T08-00-00.000Z"
    }
    func scaleId(_ index: Int) -> AgentID {
        AgentID(rawValue: UUID(uuidString: String(format: "2A300000-0000-4000-8000-%012X", index))!)
    }

    // The 0.7.47 layout: every record's backups in the one shared folder.
    for index in 0..<neighbours {
        var record = makeAgentStoreFixture(id: scaleId(index), createdAt: created)
        record.displayName = "Neighbour \(index)"
        let data = try encoder.encode(record)
        try data.write(to: layout.agentFile(id: record.id))
        try data.write(to: shared.appendingPathComponent(v2Name(record.id, generation: 1)))
    }
    let target = makeAgentStoreFixture(id: scaleId(0xFFFF), createdAt: created)
    try encoder.encode(target).write(to: layout.agentFile(id: target.id))
    for generation in 1...3 {
        var old = target
        old.displayName = "Seeded \(generation)"
        try encoder.encode(old).write(to: shared.appendingPathComponent(v2Name(target.id, generation: generation)))
    }
    // A record whose only backup carries the pre-v2 name, and a corrupt primary.
    var legacy = makeAgentStoreFixture(id: scaleId(0xFFFE), createdAt: created)
    legacy.displayName = "Legacy backup"
    try encoder.encode(legacy).write(to: shared.appendingPathComponent(
        "\(legacy.id.rawValue.uuidString).2026-08-20T10-00-00.000Z.000000.json"))
    try Data("{".utf8).write(to: layout.agentFile(id: legacy.id))

    let openStarted = Date()
    let store = AgentStore(applicationSupportDirectory: root, retainedBackups: 3, warn: { _ in })
    let openSeconds = Date().timeIntervalSince(openStarted)
    // The move runs off the caller's thread; measure saves once it is done.
    store.waitForBackupMigration()

    var record = target
    var entries: [Int] = []
    let savesStarted = Date()
    for revision in 0..<6 {
        record.displayName = "Revision \(revision)"
        let before = AtomicWriter.backupEntriesScannedForQA
        try store.upsert(record)
        entries.append(AtomicWriter.backupEntriesScannedForQA - before)
    }
    let perSaveMs = Date().timeIntervalSince(savesStarted) * 1000 / 6
    let tilesBefore = AtomicWriter.backupEntriesScannedForQA
    try store.setDeletedAgentTiles([UUID(uuidString: "2A300000-0000-4000-8000-00000000AAAA")!])
    try store.setDeletedAgentTiles([UUID(uuidString: "2A300000-0000-4000-8000-00000000BBBB")!])
    let tileEntries = AtomicWriter.backupEntriesScannedForQA - tilesBefore
    print("  agent-store scale: \(neighbours) neighbours: open \(String(format: "%.1f", openSeconds * 1000)) ms, entries read per save \(entries), \(String(format: "%.2f", perSaveMs)) ms per save, tombstone saves read \(tileEntries)")

    // Every backup file under agents/backups, wherever the store keeps it.
    var backupNames: [String] = []
    if let walker = FileManager.default.enumerator(atPath: shared.path) {
        for case let path as String in walker where !path.hasSuffix("/") {
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: shared.appendingPathComponent(path).path, isDirectory: &isDirectory)
            if !isDirectory.boolValue { backupNames.append((path as NSString).lastPathComponent) }
        }
    }
    let own = backupNames.filter { $0.hasPrefix(prefix(target.id)) }.count
    guard own == 3 else {
        throw AgentStoreCheckError("\(neighbours) neighbours: the saved agent keeps \(own) backups; retention is 3")
    }
    let neighbourBackups = (0..<neighbours).filter { index in
        backupNames.contains(v2Name(scaleId(index), generation: 1))
    }.count
    guard neighbourBackups == neighbours else {
        throw AgentStoreCheckError("\(neighbours) neighbours: \(neighbours - neighbourBackups) neighbour backups are gone")
    }

    // The restore reader: a corrupt record falls back to its newest backup.
    try Data("{".utf8).write(to: layout.agentFile(id: target.id))
    guard try store.load(id: target.id)?.displayName == "Revision 4" else {
        throw AgentStoreCheckError("\(neighbours) neighbours: a corrupt record did not restore from its newest backup")
    }
    let neighbourId = scaleId(neighbours / 2)
    try Data("{".utf8).write(to: layout.agentFile(id: neighbourId))
    guard try store.load(id: neighbourId)?.displayName == "Neighbour \(neighbours / 2)" else {
        throw AgentStoreCheckError("\(neighbours) neighbours: a corrupt neighbour did not restore from the backup 0.7.47 wrote")
    }
    guard try store.load(id: legacy.id)?.displayName == "Legacy backup" else {
        throw AgentStoreCheckError("\(neighbours) neighbours: a record whose only backup has the pre-v2 name did not restore")
    }
    guard store.loadDeletedAgentTiles() == [UUID(uuidString: "2A300000-0000-4000-8000-00000000BBBB")!] else {
        throw AgentStoreCheckError("\(neighbours) neighbours: the deleted-agent tombstone did not round-trip")
    }
    let all = try store.loadAll()
    guard all.count == neighbours + 2 else {
        throw AgentStoreCheckError("\(neighbours) neighbours: loadAll returned \(all.count) records, expected \(neighbours + 2)")
    }
    return entries
}

// 8 · A 0.7.47 round trip heals (2026-11-12). The move into per-record folders
// runs on every launch, so backups 0.7.47 writes into the shared folder after a
// downgrade reach their record's folder on the next upgrade. Nothing is lost, a
// same-named file already there is kept beside the moved one, and a save still
// reads only its own folder.
private func runAgentStoreDowngradeRoundTripCheck(root: URL) throws {
    let base = root.appendingPathComponent("downgrade-round-trip", isDirectory: true)
    let layout = AgentStoreLayout(applicationSupportDirectory: base)
    let shared = layout.backupsDirectory
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: shared, withIntermediateDirectories: true)
    let encoder = JSONCodec.makeEncoder(prettyPrinted: true)
    let created = Date(timeIntervalSinceReferenceDate: 806_100_000)
    func id(_ index: Int) -> AgentID {
        AgentID(rawValue: UUID(uuidString: String(format: "2A400000-0000-4000-8000-%012X", index))!)
    }
    func v2Name(_ agent: AgentID, generation: Int) -> String {
        AtomicWriter.backupNamePrefix(
            forCanonicalIdentityPath: AtomicWriter.canonicalIdentityPath(for: layout.agentFile(id: agent)))
            + String(format: "%020d", generation) + "-2026-11-12T08-00-00.000Z"
    }
    func record(_ agent: AgentID, _ name: String) throws -> Data {
        var value = makeAgentStoreFixture(id: agent, createdAt: created)
        value.displayName = name
        return try encoder.encode(value)
    }
    func sharedFiles() throws -> [String] {
        // Dot-files are bookkeeping (an earlier build's marker), not backups.
        try fileManager.contentsOfDirectory(atPath: shared.path).filter { name in
            guard !name.hasPrefix(".") else { return false }
            var isDirectory: ObjCBool = false
            fileManager.fileExists(atPath: shared.appendingPathComponent(name).path, isDirectory: &isDirectory)
            return !isDirectory.boolValue
        }
    }
    func allBackups() -> [String: Data] {
        var files: [String: Data] = [:]
        for case let path as String in fileManager.enumerator(atPath: shared.path) ?? NSEnumerator() {
            let url = shared.appendingPathComponent(path)
            guard !url.lastPathComponent.hasPrefix(".") else { continue }
            var isDirectory: ObjCBool = false
            fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            if !isDirectory.boolValue { files[path] = fileManager.contents(atPath: url.path) }
        }
        return files
    }

    // The 0.7.47 layout: 20 records, three backups each, all in the shared folder.
    for index in 0..<20 {
        try record(id(index), "Agent \(index)").write(to: layout.agentFile(id: id(index)))
        for generation in 1...3 {
            try record(id(index), "Agent \(index) g\(generation)")
                .write(to: shared.appendingPathComponent(v2Name(id(index), generation: generation)))
        }
    }
    let first = AgentStore(applicationSupportDirectory: base, retainedBackups: 3, warn: { _ in })
    first.waitForBackupMigration()
    guard try sharedFiles().isEmpty else {
        throw AgentStoreCheckError("round trip: the first launch left \(try sharedFiles().count) backups in the shared folder")
    }
    let afterUpgrade = allBackups()
    guard afterUpgrade.count == 60 else {
        throw AgentStoreCheckError("round trip: \(afterUpgrade.count) backups after the first launch, expected 60")
    }

    // Downgraded to 0.7.47: it writes a newer backup of agent 0 into the shared
    // folder, and one of agent 1 whose name is already taken in its own folder.
    let a = id(0), b = id(1)
    try record(a, "Agent 0 written by 0.7.47").write(to: shared.appendingPathComponent(v2Name(a, generation: 4)))
    let collidingName = v2Name(b, generation: 1)
    let collidingData = try record(b, "Agent 1 collision from 0.7.47")
    try collidingData.write(to: shared.appendingPathComponent(collidingName))

    // Upgraded again.
    let second = AgentStore(applicationSupportDirectory: base, retainedBackups: 3, warn: { _ in })
    second.waitForBackupMigration()
    guard try sharedFiles().isEmpty else {
        throw AgentStoreCheckError("round trip: backups 0.7.47 wrote stayed in the shared folder: \(try sharedFiles())")
    }
    let healed = allBackups()
    guard healed.count == 62 else {
        throw AgentStoreCheckError("round trip: \(healed.count) backups after the second launch, expected 62; something was lost or overwritten")
    }
    for (path, data) in afterUpgrade where healed[path] != data {
        throw AgentStoreCheckError("round trip: the backup at \(path) changed; a move must never overwrite")
    }
    let aDir = a.rawValue.uuidString, bDir = b.rawValue.uuidString
    guard healed["\(aDir)/\(v2Name(a, generation: 4))"] != nil else {
        throw AgentStoreCheckError("round trip: the backup 0.7.47 wrote did not reach its record's folder")
    }
    guard healed["\(bDir)/\(collidingName).moved-1"] == collidingData else {
        throw AgentStoreCheckError("round trip: a same-named backup was not kept beside the one already there")
    }

    // The restore reader finds the healed backup: agent 0's newest is 0.7.47's.
    try Data("{".utf8).write(to: layout.agentFile(id: a))
    guard try second.load(id: a)?.displayName == "Agent 0 written by 0.7.47" else {
        throw AgentStoreCheckError("round trip: a corrupt record did not restore from the backup 0.7.47 wrote")
    }

    // And a save still reads only its own folder.
    var saved = makeAgentStoreFixture(id: id(2), createdAt: created)
    saved.displayName = "Saved after the round trip"
    let before = AtomicWriter.backupEntriesScannedForQA
    try second.upsert(saved)
    let read = AtomicWriter.backupEntriesScannedForQA - before
    guard read == 3 else {
        throw AgentStoreCheckError("round trip: a save read \(read) directory entries, expected its own 3")
    }
    print("  agent-store round trip: 60 backups moved, 0.7.47's 2 later writes healed (1 kept beside a same-named file), save reads \(read) entries")
}

// A corrupt primary with a valid old dedicated backup must not recover before
// the newer downgrade backup has moved from the shared directory.
private func runHeldMigrationRecoveryCheck(root: URL) throws {
    let base = root.appendingPathComponent("held-migration")
    let layout = AgentStoreLayout(applicationSupportDirectory: base)
    let id = AgentID(rawValue: UUID())
    let date = Date(timeIntervalSinceReferenceDate: 806_100_000)
    func record(_ name: String) -> AgentRecord {
        var value = makeAgentStoreFixture(id: id, displayName: name, createdAt: date)
        if name == "newer-backup" { value.lastActivityAt = date.addingTimeInterval(60) }
        return value
    }
    let dedicated = AtomicWriter(backupsDirectory: layout.backupsDirectory(for: id), backupDate: { date }, legacyBackupPolicy: .targetDedicated)
    let shared = AtomicWriter(backupsDirectory: layout.backupsDirectory, backupDate: { date.addingTimeInterval(60) }, legacyBackupPolicy: .targetDedicated)
    try dedicated.write(record("old-backup"), to: layout.agentFile(id: id))
    try dedicated.write(record("old-backup"), to: layout.agentFile(id: id))
    try dedicated.write(record("old-backup"), to: layout.agentFile(id: id))
    try dedicated.write(record("newer-backup"), to: layout.agentFile(id: id))
    try shared.write(record("primary"), to: layout.agentFile(id: id))
    try Data("corrupt".utf8).write(to: layout.agentFile(id: id))
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    let store = AgentStore(applicationSupportDirectory: base, migrationHookForQA: {
        entered.signal()
        release.wait()
    })
    entered.wait()
    DispatchQueue.global().asyncAfter(deadline: .now() + 1) { release.signal() }
    let recovered = try store.load(id: id)?.displayName
    store.waitForBackupMigration()
    guard recovered == "newer-backup" else {
        throw AgentStoreCheckError("held migration: recovered \(String(describing: recovered)), expected newer-backup")
    }
    // A subsequent save must retain the newer, independently numbered backup.
    try store.upsert(record("replacement"))
    try Data("corrupt".utf8).write(to: layout.agentFile(id: id))
    guard try store.load(id: id)?.displayName == "newer-backup" else {
        throw AgentStoreCheckError("held migration: newer downgrade backup was pruned by a save")
    }
    print("  agent-store held migration: newest downgrade backup recovered and retained")
}

// Downgrade restarts generations and filenames carry backup wall-clock time,
// neither of which establishes which decoded agent state is newer.
private func runRecoveryOrderingCheck(root: URL) throws {
    let base = root.appendingPathComponent("recovery-ordering")
    let layout = AgentStoreLayout(applicationSupportDirectory: base)
    let id = AgentID(rawValue: UUID())
    let baseDate = Date(timeIntervalSinceReferenceDate: 806_100_000)
    func record(_ name: String, activity: TimeInterval) -> AgentRecord {
        var value = makeAgentStoreFixture(id: id, displayName: name, createdAt: baseDate)
        value.lastActivityAt = baseDate.addingTimeInterval(activity)
        return value
    }
    let dedicated = AtomicWriter(backupsDirectory: layout.backupsDirectory(for: id), backupDate: { baseDate.addingTimeInterval(100) }, legacyBackupPolicy: .targetDedicated)
    let shared = AtomicWriter(backupsDirectory: layout.backupsDirectory, backupDate: { baseDate }, legacyBackupPolicy: .targetDedicated)
    let target = layout.agentFile(id: id)
    try dedicated.write(record("older", activity: 10), to: target)
    try dedicated.write(record("newer", activity: 20), to: target)
    try shared.write(record("primary", activity: 30), to: target)
    let fm = FileManager.default
    let olderBackup = try fm.contentsOfDirectory(at: layout.backupsDirectory(for: id), includingPropertiesForKeys: nil).first!
    let newerBackup = try fm.contentsOfDirectory(at: layout.backupsDirectory, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix("array-backup-v2-") }!
    try fm.setAttributes([.modificationDate: baseDate.addingTimeInterval(120)], ofItemAtPath: olderBackup.path)
    try fm.setAttributes([.modificationDate: baseDate], ofItemAtPath: newerBackup.path)
    let prefix = AtomicWriter.backupNamePrefix(forCanonicalIdentityPath: AtomicWriter.canonicalIdentityPath(for: target))
    let invalidBackup = layout.backupsDirectory(for: id).appendingPathComponent(prefix + "00000000000000000999-2030-01-01T00-00-00.000Z")
    try Data("corrupt".utf8).write(to: invalidBackup)
    try fm.setAttributes([.modificationDate: baseDate.addingTimeInterval(180)], ofItemAtPath: invalidBackup.path)
    try Data("corrupt".utf8).write(to: target)
    let store = AgentStore(applicationSupportDirectory: base)
    store.waitForBackupMigration()
    let recovered = try store.load(id: id)?.displayName
    guard recovered == "newer" else {
        throw AgentStoreCheckError("content ordering: recovered \(String(describing: recovered)), expected newer activity")
    }
    guard try store.loadAll().first?.displayName == "newer" else {
        throw AgentStoreCheckError("content ordering: loadAll did not recover the newest activity")
    }

    // Tombstones have no content timestamp. Invert filename and file mtime so
    // recovery has to choose the actual modification time instead.
    let tombRoot = root.appendingPathComponent("recovery-tombstone")
    let tombLayout = AgentStoreLayout(applicationSupportDirectory: tombRoot)
    let oldID = UUID(), newID = UUID()
    let oldWriter = AtomicWriter(backupsDirectory: tombLayout.deletedAgentTilesBackupsDirectory, backupDate: { baseDate.addingTimeInterval(100) }, legacyBackupPolicy: .targetDedicated)
    let newWriter = AtomicWriter(backupsDirectory: tombLayout.backupsDirectory, backupDate: { baseDate }, legacyBackupPolicy: .targetDedicated)
    let tomb = tombLayout.deletedAgentTilesFile
    try oldWriter.write([oldID], to: tomb)
    try oldWriter.write([newID], to: tomb)
    try newWriter.write([UUID()], to: tomb)
    let oldName = try fm.contentsOfDirectory(at: tombLayout.deletedAgentTilesBackupsDirectory, includingPropertiesForKeys: nil).first!
    let newName = try fm.contentsOfDirectory(at: tombLayout.backupsDirectory, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix("array-backup-v2-") }!
    try fm.setAttributes([.modificationDate: baseDate], ofItemAtPath: oldName.path)
    try fm.setAttributes([.modificationDate: baseDate.addingTimeInterval(60)], ofItemAtPath: newName.path)
    try Data("corrupt".utf8).write(to: tomb)
    let tombStore = AgentStore(applicationSupportDirectory: tombRoot)
    tombStore.waitForBackupMigration()
    guard tombStore.loadDeletedAgentTiles() == [newID] else {
        throw AgentStoreCheckError("tombstone ordering: did not recover the newest modification time")
    }
    // Identical filenames can collide when a downgraded writer restarts its
    // generation and clock. The migrated copy remains a valid candidate.
    let collisionRoot = root.appendingPathComponent("recovery-collision")
    let collisionLayout = AgentStoreLayout(applicationSupportDirectory: collisionRoot)
    let collisionID = AgentID(rawValue: UUID())
    let collisionTarget = collisionLayout.agentFile(id: collisionID)
    func collisionRecord(_ name: String, activity: TimeInterval) -> AgentRecord {
        var value = makeAgentStoreFixture(id: collisionID, displayName: name, createdAt: baseDate)
        value.lastActivityAt = baseDate.addingTimeInterval(activity)
        return value
    }
    let collisionOld = AtomicWriter(backupsDirectory: collisionLayout.backupsDirectory(for: collisionID), backupDate: { baseDate }, legacyBackupPolicy: .targetDedicated)
    let collisionNew = AtomicWriter(backupsDirectory: collisionLayout.backupsDirectory, backupDate: { baseDate }, legacyBackupPolicy: .targetDedicated)
    try collisionOld.write(collisionRecord("older", activity: 10), to: collisionTarget)
    try collisionOld.write(collisionRecord("newer collision", activity: 20), to: collisionTarget)
    try collisionNew.write(collisionRecord("primary", activity: 30), to: collisionTarget)
    try Data("corrupt".utf8).write(to: collisionTarget)
    let collisionStore = AgentStore(applicationSupportDirectory: collisionRoot)
    collisionStore.waitForBackupMigration()
    guard try collisionStore.load(id: collisionID)?.displayName == "newer collision" else {
        throw AgentStoreCheckError("collision ordering: newer migrated backup is not recoverable")
    }
    print("  agent-store recovery ordering: activity time, tombstone modification time, and collision recovery")
}
