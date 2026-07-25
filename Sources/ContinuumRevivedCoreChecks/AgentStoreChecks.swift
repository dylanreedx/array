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
        print("AgentStore checks: app-support root, round-trip, cross-project deterministic order, corrupt-file skip, and concurrent upsert passed")
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
// (`<project>/.continuum-revived/managed-sessions/`), which is why a
// cross-project inbox is impossible today; this store must be somewhere no
// project owns. Asserted as a path relationship rather than a string literal, so
// it stays true if the app-support directory name ever moves.
// NEGATIVE TEST (observed red): rooting `agentsDirectory` at
// `ProjectStoreLayout(projectRoot: applicationSupportDirectory).managedSessionsDirectory`
// → "FAIL: AgentStore files are <app-support>/agents/<agentId>.json — got
// …/location/.continuum-revived/managed-sessions/agents/2A200000-…-000000000001.json".
// The exact-path assertion is the one that fires; the `.continuum-revived`
// assertion below is defence in depth for a root this one does not pin.
private func runAgentStoreLocationCheck(root: URL) throws {
    let base = root.appendingPathComponent("location", isDirectory: true)
    let store = AgentStore(applicationSupportDirectory: base)
    let id = agentId("01")
    let file = store.layout.agentFile(id: id)

    expect(file.path == base.appendingPathComponent("agents/\(id.rawValue.uuidString).json").path,
           "AgentStore files are <app-support>/agents/<agentId>.json — got \(file.path)")
    expect(!file.path.contains("/.continuum-revived/"),
           "AgentStore keeps agents outside any project's .continuum-revived directory — \(file.path)")
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
    // rather than the real store — got …/Library/Application Support/continuum-revived/agents".
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
