import AppKit
import Darwin
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import ContinuumRevivedCollaborationProtocol

/// Performance item 4: what old, tile-less, finished agent records cost the
/// production boot mount. Drives `AppDelegate.mountWorkspaceSceneAtBoot` (which
/// runs `AgentSupervisor.restore()` → `AgentStore.loadAll()`), never a
/// re-derived loop.
@MainActor
enum AgentRecordArchiveChecks {
    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }
    static func expect(_ value: Bool, _ message: String) throws {
        if !value { throw Failure(message: message) }
    }
    static var emptyCanvas: CanvasState {
        .init(viewport: .init(x: 0, y: 0, zoom: 1), tiles: [], groups: [], lastActiveTileId: nil)
    }

    /// The shape of Dylan's store on 2026-11-15: 2,478 records, 1,816 finished
    /// children, 496 closed, 2,149 idle more than three days.
    struct Fixture {
        var records: [AgentRecord] = []
        /// Records an archive tier would move out of the boot set.
        var archivable: Set<AgentID> = []
    }

    static let now = Date(timeIntervalSince1970: 1_794_700_800) // 2026-11-15
    static let day: TimeInterval = 86_400

    static func makeFixture(cwd: String, total: Int = 2478) -> Fixture {
        var fixture = Fixture()
        let project = UUID()
        let leadCount = 60
        let childCount = 1816
        let closedTopLevel = 496
        let brief = String(repeating: "Investigate the seam, measure before changing it, and report the numbers. ", count: 32)
        let summary = String(repeating: "Measured and fixed; witness RED before, GREEN after. ", count: 10)
        var leads: [AgentID] = []
        for i in 0..<total {
            let id = AgentID(rawValue: UUID())
            let idleDays: Double = i % 15 == 0 ? 1 : Double(4 + i % 40) // 2,313 idle > 3 days
            let last = now.addingTimeInterval(-idleDays * day)
            let created = last.addingTimeInterval(-3600)
            var record: AgentRecord
            if i < leadCount {
                record = AgentRecord(id: id, displayName: "Lead \(i)", harness: .claudeCode, model: AgentCatalogQAFixture.pi[0],
                    thinking: "none", cwd: cwd, projectId: project, createdAt: created, lastActivityAt: last)
                record.tileId = UUID()
                leads.append(id)
            } else if i < leadCount + childCount {
                record = AgentRecord(id: id, displayName: "Helper \(i)", harness: .claudeCode, model: AgentCatalogQAFixture.pi[0],
                    thinking: "none", cwd: cwd, projectId: project, parentAgentID: leads[i % leadCount],
                    createdAt: created, lastActivityAt: last)
                record.delegationContext = AgentDelegationContext(brief: brief, baseHead: "2e280397", retryOf: nil,
                    createdWorktree: true, checkoutNotice: nil)
                record.lastReport = AgentFiledReport(report: AgentReport(summary: summary,
                    checks: [.init(what: "targeted leg", result: .pass)]), filedAt: last)
                record.spawnResultHandle = "spawn-\(i)"
            } else {
                record = AgentRecord(id: id, displayName: "Closed \(i)", harness: .pi, model: AgentCatalogQAFixture.pi[0],
                    thinking: "none", cwd: cwd, projectId: project, createdAt: created, lastActivityAt: last)
                if i < leadCount + childCount + closedTopLevel {
                    record.archivedAt = last
                    record.closeRequestedAt = last
                } else {
                    record.tileId = UUID()
                }
            }
            if i >= leadCount {
                record.latestPromptAt = created
                record.latestTurnAt = created
                record.runCompletedAt = last
                record.latestTerminalEvent = AgentTerminalEvent(sequence: 1, turnID: "t\(i)", outcome: .succeeded, endedAt: last)
                record.acknowledgedTerminalSequence = 1
            }
            // Steady state: a previous launch already gave every root its slot,
            // so boot does not pay the one-time character migration.
            if record.parentAgentID == nil { record.automaticCharacterIndex = i % 8 }
            fixture.records.append(record)
            if i >= leadCount, record.tileId == nil, idleDays * day > AgentRecordArchiveConfig.idleThreshold {
                fixture.archivable.insert(id)
            }
        }
        return fixture
    }

    static func write(_ records: [AgentRecord], to store: AgentStore) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: store.layout.agentsDirectory, withIntermediateDirectories: true)
        let encoder = JSONCodec.makeEncoder()
        for record in records {
            try encoder.encode(record).write(to: store.layout.agentFile(id: record.id))
        }
    }

    static func footprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    static func mallocInUse() -> Int {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return stats.size_in_use
    }

    /// One boot over one store; returns seconds and bytes the mount retained.
    static func measureBoot(store: AgentStore, expectAdopted: Int) throws -> (seconds: Double, mallocBytes: Int, footprint: Int64, decoded: Int, rowBuildMs: Double, rows: Int) {
        let supervisor = AgentSupervisor(store: store, makeRunner: { _ in ScriptedAgentRunner(script: []) },
            warn: { _ in }, nameTitlerCommand: { _ in nil })
        supervisor.codexRestoreHomeForQA = store.layout.applicationSupportDirectory.appendingPathComponent("codex-empty")
        let app = AppDelegate()
        app.agentSupervisor = supervisor
        let canvas = CanvasNSView(canvasState: emptyCanvas)
        let mallocBefore = mallocInUse()
        let footprintBefore = footprintBytes()
        let decodedBefore = AgentStore.recordsDecodedForQA
        let start = ContinuousClock.now
        try app.mountWorkspaceSceneAtBoot(canvasView: canvas, spawner: nil, projectStore: nil,
            canvasState: emptyCanvas, installsGlobalEventMonitors: false)
        let elapsed = ContinuousClock.now - start
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let malloc = mallocInUse() - mallocBefore
        let footprint = Int64(footprintBytes()) - Int64(footprintBefore)
        let decoded = AgentStore.recordsDecodedForQA - decodedBefore
        try expect(supervisor.records.count == expectAdopted, "boot adopted \(supervisor.records.count), expected \(expectAdopted)")
        // The sidebar's row build walks every record on each rebuild.
        var rowTimes: [Double] = []
        var rows = 0
        for _ in 0..<7 {
            let rowStart = ContinuousClock.now
            rows = app.agentInboxRowsForQA().count
            let d = ContinuousClock.now - rowStart
            rowTimes.append((Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18) * 1000)
        }
        withExtendedLifetime((supervisor, app, canvas)) {}
        supervisor.stopAll()
        return (seconds, malloc, footprint, decoded, rowTimes.sorted()[3], rows)
    }

    /// `--agent-record-archive-measure=full|kept`: one process per variant so
    /// neither run inherits the other's warmed allocator.
    static func measure(variant: String) throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("agent-record-archive-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let fixture = makeFixture(cwd: root.path)
        let kept = fixture.records.filter { !fixture.archivable.contains($0.id) }
        let records = variant == "kept" ? kept : fixture.records
        let store = AgentStore(applicationSupportDirectory: root.appendingPathComponent("support"))
        try write(records, to: store)
        store.waitForBackupMigration()
        let bytes = records.reduce(0) { total, record in
            total + ((try? Data(contentsOf: store.layout.agentFile(id: record.id)).count) ?? 0)
        }
        let result = try measureBoot(store: store, expectAdopted: records.count)
        print(String(format: "METRIC agent-record-archive variant=%@ records=%d archivable=%d onDiskBytes=%d decoded=%d bootSeconds=%.4f mallocRetainedMB=%.2f footprintDeltaMB=%.2f inboxRows=%d inboxRowBuildMedianMs=%.2f",
            variant, records.count, fixture.archivable.count, bytes, result.decoded, result.seconds,
            Double(result.mallocBytes) / 1_048_576, Double(result.footprint) / 1_048_576, result.rows, result.rowBuildMs))
    }

    /// The measure mode moves records, so it refuses every store under
    /// `~/Library/Application Support` — prod "Array" as well as this
    /// binary's own channel — after resolving symlinks and `..`.
    static func isOutsideRealStores(_ root: String) -> Bool {
        func resolved(_ path: String) -> String {
            URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        }
        let real = resolved(RegistryStore.defaultApplicationSupportDirectory().deletingLastPathComponent().path)
        let candidate = resolved(root)
        return !root.isEmpty && candidate != real && !candidate.hasPrefix(real + "/")
    }

    /// The guard above, driven over the paths that must be refused.
    static func measureStoreGuardWitness() throws {
        let real = RegistryStore.defaultApplicationSupportDirectory().deletingLastPathComponent()
        let prod = real.appendingPathComponent("Array").path
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("archive-guard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let link = tmp.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: prod)
        for refused in [prod, real.appendingPathComponent("Array Dev").path, real.path,
                        tmp.path + "/../../../../../../../../" + String(prod.dropFirst()), link.path, ""] {
            try expect(!isOutsideRealStores(refused), "measure-store guard accepted a real store: \(refused)")
        }
        try expect(isOutsideRealStores(tmp.appendingPathComponent("copy").path), "measure-store guard refused a copy outside Application Support")
    }

    /// `--agent-record-archive-measure-store=off|on`: one production boot over
    /// the store `CONTINUUM_APP_SUPPORT` names — a COPY of a real one, never
    /// the original — with the gate as given. Prints the mount's time and the
    /// footprint it left, then the archive pass's moves. One process per run.
    /// Never stops the agents it restored: they may name real processes.
    static func measureStore(gate: Bool) async throws {
        guard let root = ProcessInfo.processInfo.environment["CONTINUUM_APP_SUPPORT"],
              isOutsideRealStores(root) else {
            throw Failure(message: "measure-store needs CONTINUUM_APP_SUPPORT pointing at a copy of a store, outside ~/Library/Application Support")
        }
        let store = AgentStore()
        store.waitForBackupMigration()
        func jsonCount(_ dir: URL) -> Int {
            ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".json") }.count
        }
        let liveBefore = jsonCount(store.layout.agentsDirectory), archivedBefore = jsonCount(store.layout.archiveDirectory)
        let settings = gateSuite(gate)
        defer { settings.removePersistentDomain(forName: settings.suiteDomainName) }
        let supervisor = AgentSupervisor(store: store, makeRunner: { _ in ScriptedAgentRunner(script: []) },
            warn: { _ in }, nameTitlerCommand: { _ in nil })
        supervisor.codexRestoreHomeForQA = URL(fileURLWithPath: root).appendingPathComponent("codex-empty")
        let app = AppDelegate()
        app.agentSupervisor = supervisor
        app.qaSettingsDefaults = settings
        let canvas = CanvasNSView(canvasState: emptyCanvas)
        let footprintBefore = footprintBytes(), mallocBefore = mallocInUse(), decodedBefore = AgentStore.recordsDecodedForQA
        let start = ContinuousClock.now
        try app.mountWorkspaceSceneAtBoot(canvasView: canvas, spawner: nil, projectStore: nil,
            canvasState: emptyCanvas, installsGlobalEventMonitors: false)
        func ms(_ d: Duration) -> Double { (Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18) * 1000 }
        let mountMs = ms(ContinuousClock.now - start)
        let decoded = AgentStore.recordsDecodedForQA - decodedBefore
        let adopted = supervisor.records.count
        let footprintMount = footprintBytes(), mallocMount = mallocInUse()
        let passStart = ContinuousClock.now
        await supervisor.recordArchivePassForQA?.value
        let passMs = ms(ContinuousClock.now - passStart)
        // Both gates settle alike: the boot's other main-actor work (helper
        // flushes, rehydration) runs here whether or not a pass was awaited.
        let settle = Double(ProcessInfo.processInfo.environment["ARCHIVE_MEASURE_SETTLE_SECONDS"] ?? "") ?? 0
        if settle > 0 { try await Task.sleep(for: .seconds(settle)) }
        let cost = supervisor.recordArchivePassCostForQA
        var rowTimes: [Double] = []
        var rows = 0
        for _ in 0..<7 {
            let rowStart = ContinuousClock.now
            rows = app.agentInboxRowsForQA().count
            rowTimes.append(ms(ContinuousClock.now - rowStart))
        }
        let mb = 1_048_576.0
        print(String(format: "METRIC agent-record-archive-store gate=%@ liveFilesBefore=%d archivedFilesBefore=%d decoded=%d adopted=%d mountMs=%.1f passMs=%.1f moved=%d liveAfter=%d archivedFilesAfter=%d footprintMB=%.1f footprintMountDeltaMB=%.1f mallocMountDeltaMB=%.1f footprintAfterPassMB=%.1f inboxRows=%d inboxRowBuildMedianMs=%.2f passScanMs=%.1f passMainMs=%.1f settleS=%.0f footprintSettledMB=%.1f",
            gate ? "on" : "off", liveBefore, archivedBefore, decoded, adopted, mountMs, passMs,
            adopted - supervisor.records.count, supervisor.records.count, jsonCount(store.layout.archiveDirectory),
            Double(footprintMount) / mb, (Double(footprintMount) - Double(footprintBefore)) / mb,
            Double(mallocMount - mallocBefore) / mb, Double(footprintBytes()) / mb, rows, rowTimes.sorted()[3],
            cost?.scanMs ?? -1, cost?.mainMs ?? -1, settle, Double(footprintBytes()) / mb))
        withExtendedLifetime((app, canvas, supervisor)) {}
    }

    // MARK: - Witness

    struct Edges {
        var keptRecentChild: AgentID
        var keptParentOfRecentChild: AgentID
        var keptUnfinishedTurn: AgentID
        var keptUndelivered: AgentID
        var keptSnoozed: AgentID
        var archivedInWorktree: AgentID
        var archivedChild: AgentID
        var archivedClosed: AgentID
        var worktree: URL
        var repo: URL
    }

    static func git(_ args: [String], in dir: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", dir.path] + args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try expect(process.terminationStatus == 0, "git \(args.joined(separator: " ")) failed")
    }

    /// The cases the rules exist for, on top of the scale fixture.
    static func addEdges(_ fixture: inout Fixture, root: URL) throws -> Edges {
        let cwd = root.path
        let old = now.addingTimeInterval(-30 * day)
        func record(_ name: String, parent: AgentID?, at: Date, cwd: String = cwd) -> AgentRecord {
            var r = AgentRecord(id: AgentID(rawValue: UUID()), displayName: name, harness: .claudeCode,
                model: AgentCatalogQAFixture.pi[0], thinking: "none", cwd: cwd, parentAgentID: parent,
                createdAt: at.addingTimeInterval(-60), lastActivityAt: at)
            r.latestTurnAt = at.addingTimeInterval(-30)
            r.runCompletedAt = at
            r.latestTerminalEvent = AgentTerminalEvent(sequence: 1, turnID: "t", outcome: .succeeded, endedAt: at)
            r.acknowledgedTerminalSequence = 1
            if parent == nil { r.automaticCharacterIndex = 0 }
            return r
        }
        let lead = fixture.records[0].id // has a tile: always kept
        // A tile-less old lead whose child worked yesterday: the child stays, so it does.
        let parent = record("Old lead", parent: nil, at: old)
        let recent = record("Recent child", parent: parent.id, at: now.addingTimeInterval(-day))
        // A turn that started and never ended (the restart cut it off).
        var unfinished = record("Cut off", parent: lead, at: old)
        unfinished.latestTurnAt = old.addingTimeInterval(60)
        // A completion its lead has not been handed yet.
        let undelivered = record("Undelivered", parent: lead, at: old)
        try SpawnResultFile.saveDelivery(SpawnResultFile.Delivery(helper: undelivered.id.rawValue, turn: "t",
            recipient: lead.rawValue, wakeID: UUID(), text: "done", now: old), parentCwd: cwd)
        var snoozed = record("Snoozed", parent: nil, at: old)
        snoozed.snoozedUntil = now.addingTimeInterval(day)
        snoozed.snoozedAt = old
        // An archived helper still owns its checkout; repair must not call it an orphan.
        let repo = root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git(["init", "-q"], in: repo)
        try git(["-c", "user.name=fixture", "-c", "user.email=fixture@example.invalid", "commit", "-q", "--allow-empty", "-m", "base"], in: repo)
        let worktree = repo.appendingPathComponent(".worktrees/old-helper", isDirectory: true)
        try git(["worktree", "add", "-q", "-b", "old-helper", worktree.path], in: repo)
        let inWorktree = record("Worktree helper", parent: lead, at: old, cwd: worktree.path)
        fixture.records += [parent, recent, unfinished, undelivered, snoozed, inWorktree]
        fixture.archivable.insert(inWorktree.id)
        let archivedChild = fixture.records.first { $0.parentAgentID != nil && fixture.archivable.contains($0.id) }!.id
        let archivedClosed = fixture.records.first { $0.archivedAt != nil && fixture.archivable.contains($0.id) }!.id
        return Edges(keptRecentChild: recent.id, keptParentOfRecentChild: parent.id, keptUnfinishedTurn: unfinished.id,
            keptUndelivered: undelivered.id, keptSnoozed: snoozed.id, archivedInWorktree: inWorktree.id,
            archivedChild: archivedChild, archivedClosed: archivedClosed, worktree: worktree, repo: repo)
    }

    static func gateSuite(_ on: Bool?) -> QAIsolatedDefaults {
        let name = "array.check.recordArchive.\(UUID().uuidString)"
        let suite = QAIsolatedDefaults(isolatedSuiteName: name)!
        var domain: [String: Any] = [:]
        if let on { domain[AgentRecordArchiveConfig.enabledKey] = on }
        suite.setPersistentDomain(domain, forName: name)
        return suite
    }

    /// One production boot: the mount wires the gate from Settings.
    final class Warnings { var lines: [String] = [] }

    static func boot(_ store: AgentStore, settings: QAIsolatedDefaults, warnings: Warnings? = nil) async throws -> (AgentSupervisor, AppDelegate, Int, Double) {
        let supervisor = AgentSupervisor(store: store, makeRunner: { _ in ScriptedAgentRunner(script: []) },
            warn: { line in warnings?.lines.append(line) }, nameTitlerCommand: { _ in nil })
        supervisor.codexRestoreHomeForQA = store.layout.applicationSupportDirectory.appendingPathComponent("codex-empty")
        supervisor.recordArchiveNow = { now }
        let app = AppDelegate()
        app.agentSupervisor = supervisor
        app.qaSettingsDefaults = settings
        let decoded = AgentStore.recordsDecodedForQA
        let start = ContinuousClock.now
        try app.mountWorkspaceSceneAtBoot(canvasView: CanvasNSView(canvasState: emptyCanvas), spawner: nil,
            projectStore: nil, canvasState: emptyCanvas, installsGlobalEventMonitors: false)
        let elapsed = ContinuousClock.now - start
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        await settleArchivePass(supervisor)
        return (supervisor, app, AgentStore.recordsDecodedForQA - decoded, seconds)
    }

    static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    /// The archive pass runs after restore, once the shared-area bindings are
    /// read off the main thread.
    static func settleArchivePass(_ supervisor: AgentSupervisor) async {
        await supervisor.recordArchivePassForQA?.value
    }

    static func bootWitness(gate: Bool) async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("agent-record-archive-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        var fixture = makeFixture(cwd: root.path)
        let edges = try addEdges(&fixture, root: root)
        let store = AgentStore(applicationSupportDirectory: root.appendingPathComponent("support"))
        try write(fixture.records, to: store)
        store.waitForBackupMigration()
        let all = Set(fixture.records.map(\.id))
        let kept = all.subtracting(fixture.archivable)
        let settings = gateSuite(gate ? true : nil)
        defer { settings.removePersistentDomain(forName: settings.suiteDomainName) }

        let (first, firstApp, firstDecoded, firstSeconds) = try await boot(store, settings: settings)
        try expect(firstDecoded == all.count, "first boot reads every record: \(firstDecoded)/\(all.count)")
        if !gate {
            try expect(Set(first.records.keys) == all, "gate off: boot adopts every record")
            try expect(!exists(store.layout.archiveDirectory), "gate off: nothing is archived")
            first.stopAll()
            let (second, _, decoded, seconds) = try await boot(store, settings: settings)
            try expect(decoded == all.count && second.records.count == all.count, "gate off: the next boot still reads \(all.count), read \(decoded)")
            print(String(format: "METRIC agent-record-archive gate=off records=%d boot1=%.3fs boot2=%.3fs decoded2=%d", all.count, firstSeconds, seconds, decoded))
            second.stopAll()
            withExtendedLifetime(firstApp) {}
            return
        }
        // Archived exactly the old, finished, tile-less records nothing holds.
        let live = Set(first.records.keys)
        for id in [edges.keptRecentChild, edges.keptParentOfRecentChild, edges.keptUnfinishedTurn, edges.keptUndelivered, edges.keptSnoozed] {
            try expect(live.contains(id), "kept edge \(fixture.records.first { $0.id == id }!.displayName) must stay live")
        }
        try expect(live == kept, "gate on: live set is the \(kept.count) kept records, got \(live.count)")
        // Crash-safe: every record is in exactly one place.
        for id in all {
            let inLive = exists(store.layout.agentFile(id: id)), inArchive = exists(store.layout.archivedAgentFile(id: id))
            try expect(inLive != inArchive, "record \(id.rawValue) must be in exactly one place (live=\(inLive) archive=\(inArchive))")
            try expect(inArchive == fixture.archivable.contains(id), "record \(id.rawValue) archive placement")
        }
        // Destructive paths see an archived agent as owned.
        try expect(store.ownershipPresence(id: edges.archivedInWorktree) == .present, "archived agent still owns its checkout")
        let orphans = try first.orphanWorktrees(repo: edges.repo).map { URL(fileURLWithPath: $0.path.path).resolvingSymlinksInPath().path }
        try expect(!orphans.contains(edges.worktree.resolvingSymlinksInPath().path), "repair must not call an archived helper's checkout an orphan: \(orphans)")
        first.stopAll()
        withExtendedLifetime(firstApp) {}

        // The gain: the next boot never reads the archive.
        let (second, secondApp, secondDecoded, secondSeconds) = try await boot(store, settings: settings)
        try expect(secondDecoded == kept.count, "second boot decodes \(kept.count) records, decoded \(secondDecoded)")
        // A boot may archive more (a completion delivered since), never bring one back.
        try expect(Set(second.records.keys).isSubset(of: kept) && !second.records.isEmpty, "second boot adopts within the kept set")
        print(String(format: "METRIC agent-record-archive gate=on records=%d archived=%d boot1=%.3fs boot2=%.3fs decoded2=%d",
            all.count, fixture.archivable.count, firstSeconds, secondSeconds, secondDecoded))

        // Lazy load on miss through a production entry: the phone's Stop.
        let outcome = await CompanionCommandActions.stop(edges.archivedChild.rawValue, supervisor: second)
        try expect(outcome != .notFound, "an archived agent named by id comes back (got \(outcome))")
        try expect(second.records[edges.archivedChild] != nil, "adopted into the live set")
        try expect(exists(store.layout.agentFile(id: edges.archivedChild)) && !exists(store.layout.archivedAgentFile(id: edges.archivedChild)),
                   "adopted record moved back, one copy")
        // A transcript chip names it.
        _ = secondApp.revealAgentFromInbox(edges.archivedClosed.rawValue)
        try expect(second.records[edges.archivedClosed] != nil, "a reveal by id brings an archived agent back")
        let liveAfterAdoption = second.records.count
        try expect(liveAfterAdoption < all.count, "fixture: the archive holds records before the gate goes off")
        // Follow-up (a) at scale: the gate goes off while this session runs.
        // What the first workspace API request after it pays, on the main thread.
        settings.set(false, forKey: AgentRecordArchiveConfig.enabledKey)
        let restoreStart = ContinuousClock.now
        second.restoreArchivedRecordsIfGateOff()
        let restoreElapsed = ContinuousClock.now - restoreStart
        let restoreMs = (Double(restoreElapsed.components.seconds) + Double(restoreElapsed.components.attoseconds) / 1e18) * 1000
        try expect(Set(second.records.keys) == all && archivedFiles(store).isEmpty,
                   "gate off at runtime: the whole archive is live again, live \(second.records.count)/\(all.count), archive \(archivedFiles(store).count)")
        print(String(format: "METRIC agent-record-archive runtime-gate-off restored=%d restoredMs=%.1f",
            second.records.count - liveAfterAdoption, restoreMs))
        second.stopAll()
        // Turning the gate off reverts it: the next boot decodes every record.
        let off = gateSuite(false)
        defer { off.removePersistentDomain(forName: off.suiteDomainName) }
        let (third, _, thirdDecoded, _) = try await boot(store, settings: off)
        try expect(liveAfterAdoption < all.count && thirdDecoded == all.count && Set(third.records.keys) == all,
                   "gate off later: boot restores all \(all.count) records, decoded \(thirdDecoded), live \(third.records.count)")
        try expect(archivedFiles(store).isEmpty, "gate off later: the archive is empty")
        third.stopAll()
    }

    /// An old, finished, tile-less record the policy alone would archive.
    static func idleRecord(_ name: String, cwd: String, idleFor days: Double) -> AgentRecord {
        let at = Date().addingTimeInterval(-days * day)
        var r = AgentRecord(id: AgentID(rawValue: UUID()), displayName: name, harness: .claudeCode,
            model: "anthropic/claude-haiku-4-5-20251001", thinking: "low", cwd: cwd, projectId: UUID(),
            createdAt: at.addingTimeInterval(-60), lastActivityAt: at)
        r.latestTurnAt = at.addingTimeInterval(-30)
        r.runCompletedAt = at
        r.latestTerminalEvent = AgentTerminalEvent(sequence: 1, turnID: "t", outcome: .succeeded, endedAt: at)
        r.acknowledgedTerminalSequence = 1
        r.automaticCharacterIndex = 0
        r.workspaceToolsEnabled = true
        return r
    }

    final class Prompts { var texts: [String] = [] }
    final class PromptRunner: AgentRunning, @unchecked Sendable {
        let prompts: Prompts
        init(_ prompts: Prompts) { self.prompts = prompts }
        var commandCapabilities: AgentSessionCommandCapabilities { .oneShotProse }
        func run(prompt: AgentPrompt, onEvent: @escaping @Sendable (AgentRuntimeEvent) -> Void) throws {
            let text = prompt.text
            Task { @MainActor in self.prompts.texts.append(text) }
            onEvent(.turnStarted(threadId: "archive", turnId: "wake"))
            onEvent(.turnCompleted(threadId: "archive", turnId: "wake", outcome: .completed, errorMessage: nil))
        }
        func stop() {}
        func observeSpawnRequests(_ handler: @escaping @Sendable (SpawnRequest) -> Void) {}
        func observeRuntimeObservations(_ handler: @escaping @Sendable (AgentRuntimeObservation) -> Void) {}
    }

    static func eventually(_ label: String, _ condition: @MainActor () async -> Bool) async throws {
        for _ in 0..<300 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw Failure(message: label)
    }

    /// Review blocker 1: a durable wakeup finds its agent by id when it fires.
    /// Drives the production restore and the production scheduler tick.
    static func wakeupWitness() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("agent-record-archive-wakeup-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let support = root.appendingPathComponent("support")
        let store = AgentStore(applicationSupportDirectory: support)
        let held = idleRecord("Ten-day check-in", cwd: root.path, idleFor: 8)
        let later = idleRecord("Scheduled after archiving", cwd: root.path, idleFor: 8)
        try write([held, later], to: store)
        store.waitForBackupMigration()
        let due = Date().addingTimeInterval(2 * day)
        let schedules = try AgentWakeupScheduleStore(applicationSupportDirectory: support)
        try schedules.replace([AgentWakeupSchedule(id: UUID(), agent: held.id, key: "check-in", prompt: "held check-in",
            startsAt: due, nextFireAt: due, intervalSeconds: nil)])
        let settings = gateSuite(true)
        defer { settings.removePersistentDomain(forName: settings.suiteDomainName) }
        let prompts = Prompts()
        let supervisor = AgentSupervisor(store: store, makeRunner: { _ in PromptRunner(prompts) }, warn: { _ in },
            nameTitlerCommand: { _ in nil }, submissionRecoveryStore: AgentComposerDraftStore(applicationSupportDirectory: support))
        defer { supervisor.stopAll() }
        supervisor.codexRestoreHomeForQA = support.appendingPathComponent("codex-empty")
        supervisor.recordArchiveDefaults = settings
        _ = supervisor.restore()
        await settleArchivePass(supervisor)
        try expect(supervisor.records[later.id] == nil && exists(store.layout.archivedAgentFile(id: later.id)),
                   "control: an unscheduled idle agent is archived")
        try expect(supervisor.records[held.id] != nil && !exists(store.layout.archivedAgentFile(id: held.id)),
                   "an agent with a durable wakeup stays out of the archive")
        // A schedule written after the agent was archived.
        _ = try supervisor.wakeupRequest(["op": "create", "idempotencyKey": "later", "prompt": "later check-in",
            "runAt": ISO8601DateFormatter().string(from: due)], for: later.id)
        let fire = due.addingTimeInterval(60)
        do {
            try await eventually("") {
                try? await supervisor.qaTickWakeups(now: fire)
                return Set(prompts.texts) == ["held check-in", "later check-in"]
            }
        } catch { throw Failure(message: "both due wakeups run: prompts \(prompts.texts)") }
        try expect(supervisor.records[later.id] != nil, "the tick brought the archived agent back")
        print("PASS agent record archive: a scheduled agent stays live; a wakeup added after archiving brings its agent back when due")
    }

    final class NullProjectionSink: SharedAgentProjectionSink {
        func publish(_ batch: Collaboration.AgentProjection.Batch) async throws {}
    }

    /// Review issue 2: a shared area names its agent by id. The hold is read by
    /// the production mount from the real shared-area cache; the adoption is
    /// driven through the production projector.
    static func sharedWitness() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("agent-record-archive-shared-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let store = AgentStore(applicationSupportDirectory: root.appendingPathComponent("support"))
        let shared = idleRecord("Shared helper", cwd: root.path, idleFor: 8)
        let unshared = idleRecord("Unshared helper", cwd: root.path, idleFor: 8)
        try write([shared, unshared], to: store)
        store.waitForBackupMigration()
        // The cache a shared area keeps, where the app keeps it.
        let document = SharedArea.Document()
        let endpoint = try CollaborationServiceEndpoint(URL(string: "https://archive-check.example.test")!)
        let area = try SharedAreaLocalStore(applicationSupportRoot: AppDelegate().collaborationSupportRoot, endpoint: endpoint,
            person: .init(), area: document.id)
        defer { try? fm.removeItem(at: area.layout.areaDirectory) }
        try area.save(.init(scope: area.scope, document: document, observedMembershipEpoch: 1, sourceBindings: [
            SharedAreaLocalSourceBinding(object: .init(), binding: .init(), host: .init(), projectID: shared.projectId!, agentID: shared.id)]))
        let settings = gateSuite(true)
        defer { settings.removePersistentDomain(forName: settings.suiteDomainName) }
        let (booted, app, _, _) = try await boot(store, settings: settings)
        try expect(booted.records[unshared.id] == nil && exists(store.layout.archivedAgentFile(id: unshared.id)),
                   "control: an unbound idle agent is archived")
        try expect(booted.records[shared.id] != nil && !exists(store.layout.archivedAgentFile(id: shared.id)),
                   "an agent a shared area binds stays out of the archive")
        booted.stopAll()
        withExtendedLifetime(app) {}

        // Bound after it was archived: re-attaching the projection brings it back.
        let projecting = AgentSupervisor(store: store, makeRunner: { _ in ScriptedAgentRunner(script: []) }, warn: { _ in },
            nameTitlerCommand: { _ in nil },
            transcriptStore: AgentTranscriptStore(root: root.appendingPathComponent("transcripts", isDirectory: true)))
        defer { projecting.stopAll() }
        projecting.recordArchiveDefaults = settings
        _ = projecting.restore()
        await settleArchivePass(projecting)
        try expect(projecting.records[unshared.id] == nil, "fixture: the unbound agent is still archived")
        let projector: SharedAgentProjector
        do {
            projector = try SharedAgentProjector(supervisor: projecting, agent: unshared.id, host: .init(), object: .init(),
                generation: 1, sink: NullProjectionSink())
        } catch { throw Failure(message: "projecting an archived shared agent: \(error)") }
        projector.stop()
        try expect(projecting.records[unshared.id] != nil && !exists(store.layout.archivedAgentFile(id: unshared.id)),
                   "the projector brought the archived agent back")
        print("PASS agent record archive: a shared-bound agent stays live; projecting an archived agent brings it back")
    }

    /// The workspace API, through the production mount and dispatch: an
    /// archived agent is inspectable and findable by id.
    static func apiWitness() async throws {
        let settings = gateSuite(true)
        defer { settings.removePersistentDomain(forName: settings.suiteDomainName) }
        var archivedIDs: [AgentID] = []
        let f = try WorkspaceAPIChecks.makeFixture(settings: settings, beforeMount: { delegate, _ in
            delegate.qaAgentSupervisor.recordArchiveNow = { Date() }
            let store = AgentStore(smokeTest: false)
            let old = Date().addingTimeInterval(-30 * day)
            for name in ["Archived inspect", "Archived find"] {
                guard let parent = delegate.qaAgentSupervisor.records.keys.first else { throw Failure(message: "fixture lead missing") }
                var r = AgentRecord(id: AgentID(rawValue: UUID()), displayName: name, harness: .pi,
                    model: "openai-codex/gpt-5.6-sol", thinking: "high", cwd: delegate.qaAgentSupervisor.records[parent]!.cwd,
                    projectId: delegate.qaAgentSupervisor.records[parent]!.projectId, parentAgentID: parent,
                    createdAt: old.addingTimeInterval(-60), lastActivityAt: old)
                r.runCompletedAt = old
                r.latestTerminalEvent = AgentTerminalEvent(sequence: 1, turnID: "t", outcome: .succeeded, endedAt: old)
                r.acknowledgedTerminalSequence = 1
                try store.upsert(r)
                archivedIDs.append(r.id)
            }
        })
        defer { f.tearDown() }
        let supervisor = f.delegate.qaAgentSupervisor
        await settleArchivePass(supervisor)
        let store = AgentStore(smokeTest: false)
        for id in archivedIDs {
            try expect(supervisor.records[id] == nil && exists(store.layout.archivedAgentFile(id: id)), "fixture helper archived at boot")
        }
        supervisor.setWorkspaceToolsEnabled(agentID: f.agentId, true)
        // The gate off walks no payload: `runtimeGateOffWitness`.
        let scans = WorkspaceAPIService.archivedAgentScansForQA
        let inspected = f.api.dispatch(agentId: f.agentId, requestId: "archive-inspect", op: "agent.inspect",
            payload: ["agentId": archivedIDs[0].rawValue.uuidString])
        guard case let .result(value) = inspected else { throw Failure(message: "agent.inspect of an archived agent: \(inspected)") }
        try expect(value["agent"]?.object?["agentId"]?.string?.lowercased() == archivedIDs[0].rawValue.uuidString.lowercased()
                   || "\(value)".lowercased().contains(archivedIDs[0].rawValue.uuidString.lowercased()), "inspect answers for the archived agent")
        try expect(supervisor.records[archivedIDs[0]] != nil && WorkspaceAPIService.archivedAgentScansForQA > scans,
                   "inspect adopted it")
        let found = f.api.dispatch(agentId: f.agentId, requestId: "archive-find", op: "agent.find",
            payload: ["query": archivedIDs[1].rawValue.uuidString])
        try expect("\(found)".lowercased().contains(archivedIDs[1].rawValue.uuidString.lowercased()), "agent.find by id finds an archived agent: \(found)")
    }

    /// Follow-up (a): the gate goes off while Array runs. With it off the
    /// workspace API adopts nothing by id, so what this session archived
    /// answered not_found until the next launch. Production mount (gate on)
    /// archives two helpers; the gate flips off in Settings; the first
    /// request through the real dispatch answers for both, walks no payload,
    /// and leaves the archive empty.
    static func runtimeGateOffWitness() async throws {
        let settings = gateSuite(true)
        defer { settings.removePersistentDomain(forName: settings.suiteDomainName) }
        var helpers: [AgentID] = []
        let f = try WorkspaceAPIChecks.makeFixture(settings: settings, beforeMount: { delegate, _ in
            delegate.qaAgentSupervisor.recordArchiveNow = { Date() }
            guard let lead = delegate.qaAgentSupervisor.records.values.first(where: { $0.tileId != nil }) else {
                throw Failure(message: "fixture lead missing")
            }
            var records: [AgentRecord] = []
            for name in ["Runtime off inspect", "Runtime off find"] {
                var r = idleRecord(name, cwd: lead.cwd, idleFor: 30)
                r.parentAgentID = lead.id
                r.projectId = lead.projectId
                records.append(r)
            }
            try write(records, to: AgentStore(smokeTest: false))
            helpers = records.map(\.id)
        })
        defer { f.tearDown() }
        let supervisor = f.delegate.qaAgentSupervisor
        await settleArchivePass(supervisor)
        let store = AgentStore(smokeTest: false)
        for id in helpers {
            try expect(supervisor.records[id] == nil && exists(store.layout.archivedAgentFile(id: id)),
                       "fixture: the mount archived helper \(id.rawValue)")
        }
        supervisor.setWorkspaceToolsEnabled(agentID: f.agentId, true)
        settings.set(false, forKey: AgentRecordArchiveConfig.enabledKey)
        let scans = WorkspaceAPIService.archivedAgentScansForQA
        let inspected = f.api.dispatch(agentId: f.agentId, requestId: "runtime-off-inspect", op: "agent.inspect",
            payload: ["agentId": helpers[0].rawValue.uuidString])
        guard case .result = inspected else {
            throw Failure(message: "gate turned off at runtime: agent.inspect of an archived agent answered \(inspected)")
        }
        try expect("\(inspected)".lowercased().contains(helpers[0].rawValue.uuidString.lowercased()),
                   "gate turned off at runtime: inspect answers for the archived agent")
        // Not named by any request: the whole archive came back with the first.
        let found = f.api.dispatch(agentId: f.agentId, requestId: "runtime-off-find", op: "agent.find",
            payload: ["query": "Runtime off find"])
        try expect("\(found)".lowercased().contains(helpers[1].rawValue.uuidString.lowercased()),
                   "gate turned off at runtime: agent.find by name finds the other archived agent: \(found)")
        for id in helpers {
            try expect(supervisor.records[id] != nil && exists(store.layout.agentFile(id: id)) && !exists(store.layout.archivedAgentFile(id: id)),
                       "gate turned off at runtime: helper \(id.rawValue) is live, one copy")
        }
        try expect(archivedFiles(store).isEmpty, "gate turned off at runtime: the archive is empty, holds \(archivedFiles(store))")
        try expect(WorkspaceAPIService.archivedAgentScansForQA == scans, "gate turned off at runtime: the workspace API walked a payload")
        // Done once: a record archived since stays put through the next request.
        try store.archive(id: helpers[1])
        _ = f.api.dispatch(agentId: f.agentId, requestId: "runtime-off-again", op: "agent.inspect",
            payload: ["agentId": helpers[0].rawValue.uuidString])
        try expect(exists(store.layout.archivedAgentFile(id: helpers[1])), "gate off at runtime: the archive is restored once, not on every request")
        _ = try store.unarchive(id: helpers[1])
        print("PASS agent record archive: the gate turned off while Array runs brings every archived agent back on the next workspace API request, without walking its payload")
    }

    /// Follow-up (c): a damaged archived file was retried, and warned about,
    /// on every boot. Production boots with the gate off over an archive
    /// holding a corrupt record, a file with no agent id and a record whose
    /// bytes cannot be read: the first boot warns once per damaged file and
    /// quarantines both, the second says nothing about them, and the
    /// unreadable one stays archived until it reads. Quarantine moves, never
    /// deletes, keeps the destructive paths closed, and gives a record back
    /// by id once it decodes.
    static func quarantineWitness() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("agent-record-archive-quarantine-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let store = AgentStore(applicationSupportDirectory: root.appendingPathComponent("support"))
        let quarantine = store.layout.archiveQuarantineDirectory
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: quarantine.path)
            try? fm.removeItem(at: root)
        }
        let good = idleRecord("Readable archived", cwd: root.path, idleFor: 30)
        let locked = idleRecord("Unreadable for now", cwd: root.path, idleFor: 30)
        try write([good, locked], to: store)
        store.waitForBackupMigration()
        try fm.createDirectory(at: store.layout.archiveDirectory, withIntermediateDirectories: true)
        for id in [good.id, locked.id] {
            try fm.moveItem(at: store.layout.agentFile(id: id), to: store.layout.archivedAgentFile(id: id))
        }
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: store.layout.archivedAgentFile(id: locked.id).path)
        let damagedID = AgentID(rawValue: UUID())
        let damaged = "\(damagedID.rawValue.uuidString).json", stray = "not-an-agent.json"
        let lockedName = "\(locked.id.rawValue.uuidString).json"
        try Data("{ not a record".utf8).write(to: store.layout.archiveDirectory.appendingPathComponent(damaged))
        try Data("{}".utf8).write(to: store.layout.archiveDirectory.appendingPathComponent(stray))
        let off = gateSuite(false)
        defer { off.removePersistentDomain(forName: off.suiteDomainName) }
        func mentions(_ warnings: Warnings, _ name: String) -> Int { warnings.lines.filter { $0.contains(name) }.count }

        let firstWarnings = Warnings()
        let (first, firstApp, _, _) = try await boot(store, settings: off, warnings: firstWarnings)
        try expect(first.records[good.id] != nil, "control: the readable archived record is restored")
        try expect(mentions(firstWarnings, damaged) == 1 && mentions(firstWarnings, stray) == 1,
                   "first boot warns once per damaged file: \(firstWarnings.lines)")
        try expect(mentions(firstWarnings, lockedName) == 1, "first boot warns about the unreadable file: \(firstWarnings.lines)")
        first.stopAll()
        withExtendedLifetime(firstApp) {}

        let secondWarnings = Warnings()
        let (second, secondApp, _, _) = try await boot(store, settings: off, warnings: secondWarnings)
        try expect(mentions(secondWarnings, damaged) == 0 && mentions(secondWarnings, stray) == 0,
                   "the next boot neither retries nor warns about a damaged archived file: \(secondWarnings.lines)")
        try expect(archivedFiles(store) == [lockedName] && !exists(quarantine.appendingPathComponent(lockedName)),
                   "a file whose bytes cannot be read stays archived, not quarantined: archive \(archivedFiles(store))")
        try expect(exists(quarantine.appendingPathComponent(damaged)) && exists(quarantine.appendingPathComponent(stray)),
                   "quarantine moves the damaged files, never deletes them")
        try expect(store.ownershipPresence(id: damagedID) == .present, "a quarantined agent still owns its checkout")
        do {
            _ = try second.orphanWorktrees(repo: root)
            throw Failure(message: "worktree repair ran past a quarantined archived record")
        } catch is AgentSupervisor.CleanupRefusal {}
        second.stopAll()
        withExtendedLifetime(secondApp) {}

        // The unreadable file reads now; the same agent is damaged a second time.
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: store.layout.archivedAgentFile(id: locked.id).path)
        try Data("{ damaged again".utf8).write(to: store.layout.archiveDirectory.appendingPathComponent(damaged))
        let (third, thirdApp, _, _) = try await boot(store, settings: off)
        try expect(third.records[locked.id] != nil, "a file that stayed archived is restored once it reads")
        let held = (try? fm.contentsOfDirectory(atPath: quarantine.path)) ?? []
        try expect(held.filter { $0.hasPrefix(damaged) }.count == 2, "a second quarantine of one name keeps both copies: \(held)")

        // Gate on, by id: a damaged file is quarantined with one warning, and
        // comes back from the quarantine by id once it decodes.
        let adoptWarnings = Warnings()
        let on = gateSuite(true)
        defer { on.removePersistentDomain(forName: on.suiteDomainName) }
        let (adopting, adoptingApp, _, _) = try await boot(store, settings: on, warnings: adoptWarnings)
        let later = idleRecord("Damaged then repaired", cwd: root.path, idleFor: 30)
        let laterName = "\(later.id.rawValue.uuidString).json"
        try Data("{ not yet".utf8).write(to: store.layout.archivedAgentFile(id: later.id))
        try expect(!adopting.adoptArchivedAgent(later.id) && exists(quarantine.appendingPathComponent(laterName))
                   && mentions(adoptWarnings, laterName) == 1, "a damaged file named by id is quarantined with one warning: \(adoptWarnings.lines)")
        try JSONCodec.makeEncoder().encode(later).write(to: quarantine.appendingPathComponent(laterName))
        try expect(adopting.adoptArchivedAgent(later.id) && !exists(quarantine.appendingPathComponent(laterName))
                   && exists(store.layout.agentFile(id: later.id)), "a quarantined record that decodes comes back by id")

        // Repair is fail-closed on the quarantine listing itself: an empty,
        // readable quarantine lets it run (control); an unlistable one refuses.
        try fm.removeItem(at: quarantine)
        let repo = root.appendingPathComponent("repo", isDirectory: true)
        try fm.createDirectory(at: repo, withIntermediateDirectories: true)
        try git(["init", "-q"], in: repo)
        do { _ = try adopting.orphanWorktrees(repo: repo) } catch {
            throw Failure(message: "control: worktree repair with no quarantine refused: \(error)")
        }
        try fm.createDirectory(at: quarantine, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: quarantine.path)
        var refused = false
        do { _ = try adopting.orphanWorktrees(repo: repo) } catch { refused = true }
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: quarantine.path)
        try expect(refused, "worktree repair ran with an unlistable quarantine")
        adopting.stopAll()
        third.stopAll()
        withExtendedLifetime((thirdApp, adoptingApp)) {}
        print("PASS agent record archive: a damaged archived file is quarantined once, warned about once and kept; an unreadable one stays archived; a quarantined record comes back by id; worktree repair stays closed")
    }

    /// Follow-up (b): the shared-area scan read every cached area's
    /// `state.json` on the main thread at boot, and a file it could not read
    /// skipped the archive with a warning that named no file. Through the
    /// production mount, with one damaged `state.json` (a decode error carries
    /// no path of its own): the scan runs, never on the main thread, the
    /// record stays live, and the warning names the file.
    static func sharedScanOffMainWitness() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("agent-record-archive-scan-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let store = AgentStore(applicationSupportDirectory: root.appendingPathComponent("support"))
        let idle = idleRecord("Idle beside a damaged shared area", cwd: root.path, idleFor: 8)
        try write([idle], to: store)
        store.waitForBackupMigration()
        let endpoint = try CollaborationServiceEndpoint(URL(string: "https://archive-scan-check.example.test")!)
        let area = try SharedAreaLocalStore(applicationSupportRoot: AppDelegate().collaborationSupportRoot, endpoint: endpoint,
            person: .init(), area: SharedArea.Document().id)
        defer { try? fm.removeItem(at: area.layout.areaDirectory) }
        try fm.createDirectory(at: area.layout.areaDirectory, withIntermediateDirectories: true)
        let state = area.layout.stateFile
        try Data(#"{"sourceBindings": "damaged"}"#.utf8).write(to: state)
        let settings = gateSuite(true)
        defer { settings.removePersistentDomain(forName: settings.suiteDomainName) }
        let warnings = Warnings()
        let scans = SharedAreaLocalStore.bindingScansForQA
        let (supervisor, app, _, _) = try await boot(store, settings: settings, warnings: warnings)
        defer { supervisor.stopAll() }
        let after = SharedAreaLocalStore.bindingScansForQA
        try expect(after.total > scans.total, "the boot never scanned the shared areas")
        try expect(after.onMain == scans.onMain, "the boot read shared-area files on the main thread (\(after.onMain - scans.onMain) scan(s))")
        try expect(supervisor.records[idle.id] != nil && !exists(store.layout.archivedAgentFile(id: idle.id)),
                   "an unreadable shared area skips the archive pass")
        try expect(warnings.lines.contains { $0.contains("archive skipped") && $0.contains(state.path) },
                   "the warning names the shared-area file: \(warnings.lines)")
        withExtendedLifetime(app) {}
        print("PASS agent record archive: the boot scans shared areas off the main thread; an unreadable area skips the archive and the warning names its file")
    }

    /// The pass runs after boot, against live state. Two things change in
    /// the window between restore and the pass, through production entries:
    /// a child of an idle parent comes live (adoption by id), and the gate goes
    /// off and on again while the workspace API restores the archive. The
    /// parent must stay with its child, and what the pass then archives must
    /// still come back when the gate goes off once more.
    static func windowWitness() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("agent-record-archive-window-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let store = AgentStore(applicationSupportDirectory: root.appendingPathComponent("support"))
        let parent = idleRecord("Idle parent", cwd: root.path, idleFor: 8)
        let unrelated = idleRecord("Idle unrelated", cwd: root.path, idleFor: 8)
        var child = idleRecord("Child live after boot", cwd: root.path, idleFor: 0)
        child.parentAgentID = parent.id
        try write([parent, unrelated, child], to: store)
        store.waitForBackupMigration()
        try fm.createDirectory(at: store.layout.archiveDirectory, withIntermediateDirectories: true)
        try fm.moveItem(at: store.layout.agentFile(id: child.id), to: store.layout.archivedAgentFile(id: child.id))
        let settings = gateSuite(true)
        defer { settings.removePersistentDomain(forName: settings.suiteDomainName) }
        let supervisor = AgentSupervisor(store: store, makeRunner: { _ in ScriptedAgentRunner(script: []) },
            warn: { _ in }, nameTitlerCommand: { _ in nil })
        defer { supervisor.stopAll() }
        supervisor.codexRestoreHomeForQA = store.layout.applicationSupportDirectory.appendingPathComponent("codex-empty")
        let app = AppDelegate()
        app.agentSupervisor = supervisor
        app.qaSettingsDefaults = settings
        try app.mountWorkspaceSceneAtBoot(canvasView: CanvasNSView(canvasState: emptyCanvas), spawner: nil,
            projectStore: nil, canvasState: emptyCanvas, installsGlobalEventMonitors: false)
        // The window: the pass cannot run until this check awaits.
        try expect(supervisor.adoptArchivedAgent(child.id), "fixture: the child comes live by id")
        settings.set(false, forKey: AgentRecordArchiveConfig.enabledKey)
        supervisor.restoreArchivedRecordsIfGateOff() // what a workspace API request runs
        settings.set(true, forKey: AgentRecordArchiveConfig.enabledKey)
        await supervisor.recordArchivePassForQA?.value
        try expect(supervisor.records[unrelated.id] == nil && exists(store.layout.archivedAgentFile(id: unrelated.id)),
                   "control: the pass archived the unrelated idle agent")
        try expect(supervisor.records[parent.id] != nil && !exists(store.layout.archivedAgentFile(id: parent.id)),
                   "a parent whose child came live after restore stays live")
        settings.set(false, forKey: AgentRecordArchiveConfig.enabledKey)
        supervisor.restoreArchivedRecordsIfGateOff()
        try expect(supervisor.records[unrelated.id] != nil && archivedFiles(store).isEmpty,
                   "what the pass archived comes back when the gate goes off again")
        withExtendedLifetime(app) {}
        print("PASS agent record archive: a child that comes live after restore keeps its parent; what the late pass archives still comes back when the gate goes off")
    }

    static func archivedFiles(_ store: AgentStore) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: store.layout.archiveDirectory.path)) ?? [])
            .filter { $0.hasSuffix(".json") }.sorted()
    }

    /// The kill switch: a boot with the gate on archives, the next boot with it
    /// off makes every archived record live again — decoded by restore and
    /// answered by the workspace API, whose gate-off path adopts nothing.
    /// Both boots are the production mount. A corrupt archived file stays and
    /// does not block boot; an archived copy of a live record loses to it.
    static func gateOffRevertWitness() async throws {
        let off = gateSuite(false)
        defer { off.removePersistentDomain(forName: off.suiteDomainName) }
        var helpers: [AgentID] = []
        var fixtureAgent: AgentRecord?
        let corrupt = UUID().uuidString + ".json"
        let f = try WorkspaceAPIChecks.makeFixture(settings: off, beforeMount: { delegate, _ in
            let store = AgentStore(smokeTest: false)
            let supervisor = delegate.qaAgentSupervisor
            guard let lead = supervisor.records.values.first(where: { $0.tileId != nil }) else { throw Failure(message: "fixture lead missing") }
            fixtureAgent = lead
            var records: [AgentRecord] = []
            for name in ["Revert inspect", "Revert find"] {
                var r = idleRecord(name, cwd: lead.cwd, idleFor: 30)
                r.parentAgentID = lead.id
                r.projectId = lead.projectId
                records.append(r)
            }
            try write(records, to: store)
            helpers = records.map(\.id)
            // Archived as a gate-on launch archives them (`bootWitness` drives
            // that launch; this closure cannot await its pass).
            for id in helpers { try store.archive(id: id) }
            for id in helpers {
                try expect(exists(store.layout.archivedAgentFile(id: id)) && !exists(store.layout.agentFile(id: id)),
                           "boot with the gate on archived the helper")
            }
            // An archived copy of a live record (live wins) and a corrupt file.
            var stale = lead
            stale.displayName = "Stale archived copy"
            try JSONCodec.makeEncoder().encode(stale).write(to: store.layout.archivedAgentFile(id: lead.id))
            try Data("{ not a record".utf8).write(to: store.layout.archiveDirectory.appendingPathComponent(corrupt))
        })
        defer { f.tearDown() }
        let supervisor = f.delegate.qaAgentSupervisor
        let store = AgentStore(smokeTest: false)
        // Boot 2, gate off: live before anything asks for them by id.
        for id in helpers {
            try expect(supervisor.records[id] != nil && exists(store.layout.agentFile(id: id)) && !exists(store.layout.archivedAgentFile(id: id)),
                       "gate off: restore brought archived helper \(id.rawValue) back")
        }
        try expect(try store.load(id: fixtureAgent!.id)?.displayName == fixtureAgent!.displayName,
                   "gate off: the live record wins over its archived copy")
        try expect(archivedFiles(store).isEmpty && exists(store.layout.archiveQuarantineDirectory.appendingPathComponent(corrupt)),
                   "gate off: the corrupt file is quarantined and the archive is empty, holds \(archivedFiles(store))")
        // Through the real workspace API, which with the gate off adopts nothing.
        supervisor.setWorkspaceToolsEnabled(agentID: f.agentId, true)
        let scans = WorkspaceAPIService.archivedAgentScansForQA
        for id in helpers {
            let reply = f.api.dispatch(agentId: f.agentId, requestId: "revert-\(id.rawValue)", op: "agent.inspect",
                payload: ["agentId": id.rawValue.uuidString])
            guard case .result = reply else { throw Failure(message: "gate off: agent.inspect of a formerly archived agent: \(reply)") }
            try expect("\(reply)".lowercased().contains(id.rawValue.uuidString.lowercased()), "gate off: inspect answers for \(id.rawValue)")
        }
        try expect(WorkspaceAPIService.archivedAgentScansForQA == scans, "gate off: the workspace API scanned a payload")
        // A session that never ran with the gate on never restores the archive
        // at runtime: its boot already did.
        try store.archive(id: helpers[0])
        _ = f.api.dispatch(agentId: f.agentId, requestId: "revert-never-on", op: "agent.inspect",
            payload: ["agentId": helpers[1].rawValue.uuidString])
        try expect(exists(store.layout.archivedAgentFile(id: helpers[0])), "gate never on this session: a request restored the archive")
        _ = try store.unarchive(id: helpers[0])
        try? FileManager.default.removeItem(at: store.layout.archiveQuarantineDirectory)
        print("PASS agent record archive: gate off restores every archived record at boot (live copy wins, a corrupt file is quarantined without blocking boot) and agent.inspect answers for them")
    }

    static func run() async throws {
        if let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--agent-record-archive-measure=") }) {
            try measure(variant: String(arg.dropFirst("--agent-record-archive-measure=".count)))
            return
        }
        if let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--agent-record-archive-measure-store=") }) {
            try await measureStore(gate: arg.hasSuffix("=on"))
            return
        }
        guard ProcessInfo.processInfo.environment["CONTINUUM_APP_SUPPORT"] != nil,
              Bundle.main.bundleIdentifier != AppChannel.prodBundleIdentifier else {
            throw Failure(message: "agent-record-archive check requires isolated CONTINUUM_APP_SUPPORT and a dev binary")
        }
        try measureStoreGuardWitness()
        try await bootWitness(gate: false)
        try await bootWitness(gate: true)
        try await sharedScanOffMainWitness()
        try await windowWitness()
        try await wakeupWitness()
        try await sharedWitness()
        try await apiWitness()
        try await gateOffRevertWitness()
        try await runtimeGateOffWitness()
        try await quarantineWitness()
        print("PASS agent record archive: gate off unchanged; gate on archives only old finished tile-less records nothing holds, next boot skips them, and id lookups bring them back")
        print("MATRIX-NOTE: --agent-record-archive-check passed: 2,484-record store; gate off reads all on every boot; gate on archives the idle set, boot 2 decodes only the kept set; companion, reveal, agent.inspect, agent.find, a due wakeup and a shared projection adopt by id; scheduled and shared-bound agents stay live; the shared-area scan runs off the main thread and a skip names the file; gate off scans no API payload and restores every archived record at boot, or on the next API request when it goes off at runtime; a damaged archived file is quarantined once; worktree repair and checkout cleanup treat archived agents as owners; the real-store measure mode refuses every store under Application Support.")
    }
}
