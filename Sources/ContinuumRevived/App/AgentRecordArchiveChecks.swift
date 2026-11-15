import AppKit
import Darwin
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

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
    static func boot(_ store: AgentStore, settings: QAIsolatedDefaults) throws -> (AgentSupervisor, AppDelegate, Int, Double) {
        let supervisor = AgentSupervisor(store: store, makeRunner: { _ in ScriptedAgentRunner(script: []) },
            warn: { _ in }, nameTitlerCommand: { _ in nil })
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
        return (supervisor, app, AgentStore.recordsDecodedForQA - decoded, seconds)
    }

    static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

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

        let (first, firstApp, firstDecoded, firstSeconds) = try boot(store, settings: settings)
        try expect(firstDecoded == all.count, "first boot reads every record: \(firstDecoded)/\(all.count)")
        if !gate {
            try expect(Set(first.records.keys) == all, "gate off: boot adopts every record")
            try expect(!exists(store.layout.archiveDirectory), "gate off: nothing is archived")
            first.stopAll()
            let (second, _, decoded, seconds) = try boot(store, settings: settings)
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
        let (second, secondApp, secondDecoded, secondSeconds) = try boot(store, settings: settings)
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
        second.stopAll()
        // Turning the gate off strands nothing: a later boot without it still adopts by id.
        let off = gateSuite(false)
        defer { off.removePersistentDomain(forName: off.suiteDomainName) }
        let (third, _, thirdDecoded, _) = try boot(store, settings: off)
        try expect(thirdDecoded == liveAfterAdoption, "gate off later: boot reads live records only, read \(thirdDecoded)/\(liveAfterAdoption)")
        try expect(third.adoptArchivedAgent(edges.archivedInWorktree), "gate off later: archived agents still come back by id")
        third.stopAll()
    }

    /// The workspace API, through the production mount and dispatch: an
    /// archived agent is inspectable and findable by id.
    static func apiWitness() throws {
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
        let store = AgentStore(smokeTest: false)
        for id in archivedIDs {
            try expect(supervisor.records[id] == nil && exists(store.layout.archivedAgentFile(id: id)), "fixture helper archived at boot")
        }
        supervisor.setWorkspaceToolsEnabled(agentID: f.agentId, true)
        let inspected = f.api.dispatch(agentId: f.agentId, requestId: "archive-inspect", op: "agent.inspect",
            payload: ["agentId": archivedIDs[0].rawValue.uuidString])
        guard case let .result(value) = inspected else { throw Failure(message: "agent.inspect of an archived agent: \(inspected)") }
        try expect(value["agent"]?.object?["agentId"]?.string?.lowercased() == archivedIDs[0].rawValue.uuidString.lowercased()
                   || "\(value)".lowercased().contains(archivedIDs[0].rawValue.uuidString.lowercased()), "inspect answers for the archived agent")
        try expect(supervisor.records[archivedIDs[0]] != nil, "inspect adopted it")
        let found = f.api.dispatch(agentId: f.agentId, requestId: "archive-find", op: "agent.find",
            payload: ["query": archivedIDs[1].rawValue.uuidString])
        try expect("\(found)".lowercased().contains(archivedIDs[1].rawValue.uuidString.lowercased()), "agent.find by id finds an archived agent: \(found)")
    }

    static func run() async throws {
        if let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--agent-record-archive-measure=") }) {
            try measure(variant: String(arg.dropFirst("--agent-record-archive-measure=".count)))
            return
        }
        guard ProcessInfo.processInfo.environment["CONTINUUM_APP_SUPPORT"] != nil,
              Bundle.main.bundleIdentifier != AppChannel.prodBundleIdentifier else {
            throw Failure(message: "agent-record-archive check requires isolated CONTINUUM_APP_SUPPORT and a dev binary")
        }
        try await bootWitness(gate: false)
        try await bootWitness(gate: true)
        try apiWitness()
        print("PASS agent record archive: gate off unchanged; gate on archives only old finished tile-less records nothing holds, next boot skips them, and id lookups bring them back")
        print("MATRIX-NOTE: --agent-record-archive-check passed: 2,484-record store; gate off reads all on every boot; gate on archives the idle set, boot 2 decodes only the kept set; companion, reveal, agent.inspect and agent.find adopt by id; worktree repair and checkout cleanup treat archived agents as owners.")
    }
}
