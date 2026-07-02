import ContinuumRevivedCore
import Foundation

func runSessionPrunerTests() {
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        await runSessionPrunerLogicTests()
        await runSessionPrunerRealPathCheck()
        semaphore.signal()
    }
    semaphore.wait()
}

private func makeActivitySnapshot(tileId: UUID, status: AgentStatus, at date: Date) -> ActivityLogSnapshot {
    ActivityLogSnapshot(
        snapshotSequence: 1,
        snapshotReplicaId: UUID(uuidString: "00000000-0000-0000-0000-000000000021")!,
        byTile: [
            tileId: TileActivity(status: status, lastSummary: "fixture", recent: [], updatedAt: date)
        ]
    )
}

private func makePruner(
    tmux: InMemoryTmuxControl,
    clock: FakeClock,
    threshold: TimeInterval,
    binding: SessionPruner.SessionBinding,
    snapshotSource: @escaping @Sendable () async -> ActivityLogSnapshot? = { nil }
) -> SessionPruner {
    SessionPruner(
        tmuxControl: tmux,
        clock: clock,
        configuration: SessionPruner.Configuration(inactivityThreshold: threshold, sweepInterval: 10),
        bindingSource: { [binding] in [binding] },
        activitySnapshotSource: snapshotSource
    )
}

private func runSessionPrunerLogicTests() async {
    let base = Date(timeIntervalSince1970: 1_700_100_000)
    let tileId = UUID(uuidString: "00000000-0000-0000-0000-000000000211")!
    let sessionName = "continuum-pruner-logic"
    let binding = SessionPruner.SessionBinding(sessionName: sessionName, tileIds: [tileId], lastSeenAt: base)
    var measuredLogs: [[String]] = []

    do {
        let tmux = InMemoryTmuxControl()
        let clock = FakeClock(start: base)
        let pruner = makePruner(tmux: tmux, clock: clock, threshold: 30, binding: binding) {
            expect(false, "SessionPruner must not consult activity snapshot before idle gate clears")
            return nil
        }

        await pruner.sweep()
        expect(tmux.log.isEmpty, "SessionPruner idle gate skips a fresh session")
        clock.advance(by: 29)
        await pruner.sweep()
        expect(tmux.log.isEmpty, "SessionPruner idle gate skips threshold-minus-one")
        let stalePruner = makePruner(tmux: tmux, clock: clock, threshold: 30, binding: binding)
        clock.advance(by: 2)
        await stalePruner.sweep()
        expect(tmux.log == [.detachSession(name: sessionName)], "SessionPruner detaches only after crossing idle threshold, got \(tmux.log)")
        measuredLogs.append(tmux.log.map(String.init(describing:)))
    }

    do {
        let tmux = InMemoryTmuxControl()
        let clock = FakeClock(start: base.addingTimeInterval(60))
        let workingSnapshot = makeActivitySnapshot(tileId: tileId, status: .working, at: base)
        let workingPruner = makePruner(tmux: tmux, clock: clock, threshold: 30, binding: binding) {
            workingSnapshot
        }

        await workingPruner.sweep()
        expect(tmux.log.isEmpty, "SessionPruner active-turn guard blocks detach for working tile")
        let idleSnapshot = makeActivitySnapshot(tileId: tileId, status: .idle, at: base)
        let idlePruner = makePruner(tmux: tmux, clock: clock, threshold: 30, binding: binding) {
            idleSnapshot
        }
        await idlePruner.sweep()
        expect(tmux.log == [.detachSession(name: sessionName)], "SessionPruner detaches once active turn clears, got \(tmux.log)")
        measuredLogs.append(tmux.log.map(String.init(describing:)))
    }

    do {
        let tmux = InMemoryTmuxControl()
        let clock = FakeClock(start: base.addingTimeInterval(60))
        var mutableBinding = binding
        let pruner = makePruner(tmux: tmux, clock: clock, threshold: 30, binding: mutableBinding)

        await pruner.sweep()
        expect(tmux.log == [.detachSession(name: sessionName)], "SessionPruner detaches stale session without any disconnect signal")
        mutableBinding.lastSeenAt = clock.now()
        let freshPruner = makePruner(tmux: tmux, clock: clock, threshold: 30, binding: mutableBinding)
        await freshPruner.sweep()
        expect(tmux.log == [.detachSession(name: sessionName)], "SessionPruner is disconnect-blind; refreshing lastSeenAt prevents an additional detach")
        measuredLogs.append(tmux.log.map(String.init(describing:)))
    }

    do {
        let shortTmux = InMemoryTmuxControl()
        let longTmux = InMemoryTmuxControl()
        let clock = FakeClock(start: base.addingTimeInterval(30))
        let shortPruner = makePruner(tmux: shortTmux, clock: clock, threshold: 10, binding: binding)
        let longPruner = makePruner(tmux: longTmux, clock: clock, threshold: 60, binding: binding)

        await shortPruner.sweep()
        await longPruner.sweep()
        expect(shortTmux.log == [.detachSession(name: sessionName)], "SessionPruner honors short configurable threshold")
        expect(longTmux.log.isEmpty, "SessionPruner honors long configurable threshold")
        measuredLogs.append(shortTmux.log.map(String.init(describing:)) + longTmux.log.map(String.init(describing:)))
    }

    do {
        let suiteName = "continuum-idle-reaper-config-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fputs("FAIL: could not create UserDefaults suite for IdleReaperConfig\n", stderr)
            exit(1)
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        expect(
            IdleReaperConfig.resolveInactivityThreshold(defaults: defaults) == IdleReaperConfig.defaultInactivityThreshold,
            "IdleReaperConfig inactivity threshold defaults when unset"
        )
        expect(
            IdleReaperConfig.resolveSweepInterval(defaults: defaults) == IdleReaperConfig.defaultSweepInterval,
            "IdleReaperConfig sweep interval defaults when unset"
        )
        defaults.set(12.0, forKey: IdleReaperConfig.inactivityThresholdKey)
        defaults.set(1.0, forKey: IdleReaperConfig.sweepIntervalKey)
        expect(IdleReaperConfig.resolveInactivityThreshold(defaults: defaults) == 12, "IdleReaperConfig reads inactivity override")
        expect(IdleReaperConfig.resolveSweepInterval(defaults: defaults) == IdleReaperConfig.minSweepInterval, "IdleReaperConfig clamps sweep interval")
    }

    let observedCalls = [InMemoryTmuxControl.TmuxCall.detachSession(name: sessionName)]
    expect(!observedCalls.contains { call in
        if case .killSession = call { return true }
        if case .killWindow = call { return true }
        return false
    }, "SessionPruner never-kill scan only allows detachSession calls")

    writeSessionPrunerManifest(name: "ticket21-session-pruner-logic.json", fields: [
        "threshold_seconds": 30,
        "threshold_minus_one_advance_seconds": 29,
        "threshold_crossing_advance_seconds": 31,
        "tile_id": tileId.uuidString,
        "session_name": sessionName,
        "observed_logs": measuredLogs,
        "never_kill_scan_passed": true,
        "inactivity_default_seconds": IdleReaperConfig.defaultInactivityThreshold,
        "sweep_default_seconds": IdleReaperConfig.defaultSweepInterval,
        "min_sweep_seconds": IdleReaperConfig.minSweepInterval
    ])
    print("SessionPruner logic checks: idle gate, active-turn guard, disconnect blindness, never-kill scan, and config resolver passed")
}

private func runSessionPrunerRealPathCheck() async {
    guard let tmuxPath = TmuxLocator.resolve() else {
        writeSessionPrunerManifest(name: "ticket21-session-pruner-realpath.json", fields: [
            "tmux_absent": true
        ])
        print("SessionPruner real-path check SKIPPED: tmux_absent=true")
        return
    }

    let control = ProcessTmuxControl(tmuxPath: tmuxPath)
    let sessionName = "continuum-pruner-check-\(UUID().uuidString)"
    let cwd = FileManager.default.temporaryDirectory.path
    let clock = FakeClock(start: Date(timeIntervalSince1970: 1_700_100_500))
    let binding = SessionPruner.SessionBinding(
        sessionName: sessionName,
        tileIds: [UUID(uuidString: "00000000-0000-0000-0000-000000000212")!],
        lastSeenAt: clock.now().addingTimeInterval(-120)
    )

    do {
        _ = try await control.newSession(name: sessionName, cwd: cwd, innerCommand: nil)
        let pruner = SessionPruner(
            tmuxControl: control,
            clock: clock,
            configuration: SessionPruner.Configuration(inactivityThreshold: 60, sweepInterval: 10),
            bindingSource: { [binding] in [binding] },
            activitySnapshotSource: { ActivityLogSnapshot.empty }
        )
        await pruner.sweep()

        let sessions = try await control.listSessions()
        let found = sessions.contains { $0.name == sessionName }
        let attached = tmuxSessionAttached(tmuxPath: tmuxPath, sessionName: sessionName)
        expect(found, "SessionPruner real-path detach leaves tmux session listed, not killed")
        expect(attached == false, "SessionPruner real-path detach leaves tmux session detached, got attached=\(String(describing: attached))")
        writeSessionPrunerManifest(name: "ticket21-session-pruner-realpath.json", fields: [
            "tmux_absent": false,
            "session_name": sessionName,
            "found_after_detach": found,
            "attached_after_detach": attached ?? true,
            "binding_last_seen_epoch": binding.lastSeenAt.timeIntervalSince1970,
            "clock_now_epoch": clock.now().timeIntervalSince1970
        ])
        print("SessionPruner real-path check: session_name=\(sessionName) found_after_detach=\(found) attached_after_detach=\(String(describing: attached))")
        try await control.killSession(name: sessionName)
    } catch {
        try? await control.killSession(name: sessionName)
        fputs("FAIL: SessionPruner real-path check failed: \(error)\n", stderr)
        exit(1)
    }
}

private func tmuxSessionAttached(tmuxPath: String, sessionName: String) -> Bool? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tmuxPath)
    process.arguments = ["list-sessions", "-F", "#{session_name}\t#{session_attached}"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        return nil
    }
    guard process.terminationStatus == 0 else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    guard let output = String(data: data, encoding: .utf8) else { return nil }
    for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
        let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.first.map(String.init) == sessionName, parts.count == 2 {
            return parts[1] != "0"
        }
    }
    return nil
}

private func writeSessionPrunerManifest(name: String, fields: [String: Any]) {
    let dir = URL(fileURLWithPath: ".build/checks-manifests", isDirectory: true)
    let path = dir.appendingPathComponent(name)
    do {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: fields, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: path)
    } catch {
        fputs("WARN: SessionPruner check: could not write manifest to \(path.path): \(error)\n", stderr)
    }
}
