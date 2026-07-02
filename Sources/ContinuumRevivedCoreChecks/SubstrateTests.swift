import ContinuumRevivedCore
import Foundation

// Ticket: docs/38-tickets/12-injectable-substrates.md
// Logic (pure Core) checks for the four injectable substrates: TmuxControl,
// Clock, Host, SyncTransport. All in-process, no daemon, no network, no wall
// clock — except the real-path check, which is gated on a local tmux install.
//
// This project has no XCTest target — `run-matrix.sh` never runs `swift test`
// — so these checks live here, printing PASS/FAIL via `expect` (defined in
// main.swift) and exiting non-zero on failure, matching the convention used by
// SpatialOpTests.swift / ActivityStoreTests.swift. The async substrate
// protocols are driven from a single synchronous entry point the same way
// ActivityStoreTests.swift does: one `Task { await ...; semaphore.signal() }`
// wrapping an `async` suite function.

func runSubstrateTests() {
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        await runAsyncSubstrateSuites()
        semaphore.signal()
    }
    semaphore.wait()

    runFakeClockSuite()
    runFakeHostSuite()
    runSubstrateWallClockGuard()
}

private func runAsyncSubstrateSuites() async {
    await runTmuxControlSuite()
    await runFakeSyncTransportSuite()
}

// MARK: - TmuxControl suite

private func runTmuxControlSuite() async {
    let fake = InMemoryTmuxControl()

    let paneId1 = try! await fake.newSession(name: "s1", cwd: "/tmp/a", innerCommand: nil)
    let existsAfterSession = try! await fake.sessionExists(name: "s1")
    expect(existsAfterSession, "sessionExists is true after newSession")
    let paneId2 = try! await fake.newWindow(inSession: "s1", cwd: "/tmp/b", innerCommand: ["zsh"])

    expect(fake.log == [
        .newSession(name: "s1", cwd: "/tmp/a"),
        .sessionExists(name: "s1"),
        .newWindow(session: "s1", cwd: "/tmp/b")
    ], "TmuxControl fake records newSession/newWindow calls in order")

    expect(fake.sessions["s1"] == [paneId1, paneId2], "TmuxControl fake tracks window count per session")

    let aliveBeforeKill = try! await fake.isAlive(paneTarget: paneId2)
    expect(aliveBeforeKill, "a freshly created pane reports alive")

    let cwd2 = try! await fake.paneCurrentPath(paneTarget: paneId2)
    expect(cwd2 == "/tmp/b", "paneCurrentPath returns the pane's recorded cwd")
    expect(fake.log.contains(.paneCurrentPath(target: paneId2)), "paneCurrentPath calls are logged")
    do {
        _ = try await fake.paneCurrentPath(paneTarget: "%does-not-exist")
        expect(false, "paneCurrentPath on an unknown target should throw")
    } catch let error as InMemoryTmuxControlError {
        expect(error == .paneNotFound("%does-not-exist"), "paneCurrentPath throws paneNotFound with the exact target")
    } catch {
        expect(false, "paneCurrentPath on an unknown target threw the wrong error type: \(error)")
    }

    try! await fake.killWindow(target: paneId2)
    let aliveAfterKill = try! await fake.isAlive(paneTarget: paneId2)
    expect(!aliveAfterKill, "isAlive is false after killWindow")
    expect(fake.livePanes[paneId2]?.isAlive == false, "killed pane stays in livePanes marked dead, not removed")
    expect(fake.sessions["s1"] == [paneId1], "killWindow removes only the killed pane from the session's window list")

    // Killing the session's last remaining window destroys the session itself,
    // mirroring real tmux (a session cannot exist with zero windows).
    try! await fake.killWindow(target: paneId1)
    expect(fake.sessions["s1"] == nil, "killing a session's last window removes the session entry")
    expect(fake.livePanes[paneId1]?.isAlive == false, "the last-killed pane also stays recorded as dead")

    expect(fake.log.contains(.killWindow(target: paneId2)), "killWindow calls are logged")
    expect(fake.log.contains(.killWindow(target: paneId1)), "killWindow calls are logged (second call)")

    let paneId3 = try! await fake.newSession(name: "s2", cwd: "/tmp/c", innerCommand: nil)
    let sessionsBeforeKill = try! await fake.listSessions()
    expect(sessionsBeforeKill == [TmuxSessionInfo(name: "s2", windowCount: 1, paneTargets: [paneId3])],
           "listSessions returns exactly the pre-programmed sessions")
    expect(fake.log.contains(.listSessions), "listSessions calls are logged")

    // detachSession must never kill — a detached session stays alive, unlike killSession.
    try! await fake.detachSession(name: "s2")
    expect(fake.log.contains(.detachSession(name: "s2")), "detachSession calls are logged")
    expect(fake.sessions["s2"] == [paneId3], "detachSession leaves the session and its panes untouched")
    let aliveAfterDetach = try! await fake.isAlive(paneTarget: paneId3)
    expect(aliveAfterDetach, "detachSession does not kill the pane")

    try! await fake.killSession(name: "s2")
    expect(fake.sessions["s2"] == nil, "killSession removes the session from `sessions`")
    let existsAfterSessionKill = try! await fake.sessionExists(name: "s2")
    expect(!existsAfterSessionKill, "sessionExists is false after killSession")
    let aliveAfterSessionKill = try! await fake.isAlive(paneTarget: paneId3)
    expect(!aliveAfterSessionKill, "killSession marks its panes dead")
    expect(fake.log.contains(.killSession(name: "s2")), "killSession calls are logged")

    // newWindow against a session that was never created (or already killed)
    // has no in-memory analogue — the fake fails typed-and-loud rather than
    // silently fabricating a session.
    do {
        _ = try await fake.newWindow(inSession: "ghost", cwd: "/tmp", innerCommand: nil)
        expect(false, "newWindow into an unknown session should throw")
    } catch let error as InMemoryTmuxControlError {
        expect(error == .sessionNotFound("ghost"), "newWindow throws sessionNotFound with the exact session name")
    } catch {
        expect(false, "newWindow into an unknown session threw the wrong error type: \(error)")
    }

    print("TmuxControl suite: newSession/newWindow/killWindow/killSession/isAlive/listSessions all match expected fake semantics")
}

// MARK: - FakeClock suite

private func runFakeClockSuite() {
    let clock = FakeClock(start: Date(timeIntervalSince1970: 1_700_000_000))
    let configuration = AgentStatusEngine.Configuration()
    var engine = AgentStatusEngine(initialStatus: .configuring, now: clock.now(), configuration: configuration)

    let status1 = engine.tick(at: clock.now())
    expect(status1 == .configuring, "engine stays .configuring before any signal or timeout")

    let status2 = engine.tick(at: clock.now())
    expect(status2 == .configuring, "repeated tick() with no clock advance produces no state change")

    clock.advance(by: configuration.staleTimeout + 1)
    let status3 = engine.tick(at: clock.now())
    expect(status3 == .stale, "advancing the fake clock past staleTimeout flips status to .stale")

    let status4 = engine.tick(at: clock.now())
    expect(status4 == .stale, "repeated tick() at the same (advanced) time produces no further state change")

    print("FakeClock suite: AgentStatusEngine driven purely by clock.advance(by:), no hidden Date() short-circuit")
}

// MARK: - FakeHost suite

private func runFakeHostSuite() {
    let host = FakeHost()
    let localControl = InMemoryTmuxControl()
    host.register(localControl, for: .localhost)

    guard let resolved = try? host.control(for: .localhost) as? InMemoryTmuxControl else {
        expect(false, "FakeHost.control(for: .localhost) should resolve to an InMemoryTmuxControl")
        return
    }
    expect(resolved === localControl, "FakeHost.control(for:) returns the exact registered instance (identity)")

    do {
        _ = try host.control(for: .sshForward(host: "vps-1"))
        expect(false, "control(for:) on an unregistered host should throw")
    } catch let error as HostError {
        expect(error == .unknownHost(.sshForward(host: "vps-1")),
               "control(for:) throws unknownHost with the exact identity, not merely some error")
    } catch {
        expect(false, "control(for:) threw the wrong error type: \(error)")
    }

    print("FakeHost suite: routes to the exact registered TmuxControl; unregistered identities throw HostError.unknownHost(_:) with the exact identity")
}

// MARK: - FakeSyncTransport suite

private func makeOp(lamport: UInt64, replica: UUID, byte: UInt8) -> TransportLoggedOp {
    TransportLoggedOp(opId: OpId(lamport: lamport, replica: replica), payload: Data([byte]))
}

/// Recording sink for `SyncTransport.subscribe(_:)` closures. Delivery happens
/// synchronously inside `deliver()` on the calling thread, but the `@Sendable`
/// closure type still requires a reference type here rather than a captured
/// `var [TransportLoggedOp]`.
private final class OpRecorder: @unchecked Sendable {
    private(set) var items: [TransportLoggedOp] = []
    func record(_ op: TransportLoggedOp) { items.append(op) }
}

private func runFakeSyncTransportSuite() async {
    let replica = UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")!
    let transport = FakeSyncTransport()
    let receivedBySubscriber = OpRecorder()
    transport.subscribe { op in receivedBySubscriber.record(op) }

    // .reliable: three ops, ascending OpId, delivered in emission order.
    let ops1 = (1...3).map { makeOp(lamport: UInt64($0), replica: replica, byte: UInt8($0)) }
    for op in ops1 { try! await transport.push(op) }
    transport.deliver()
    expect(transport.delivered == ops1, "reliable mode delivers all pushed ops in emission order")
    expect(receivedBySubscriber.items == ops1, "subscriber receives the same ops in the same order")

    // .partition: pushed ops never reach `delivered` or the subscriber.
    transport.mode = .partition
    let ops2 = (4...5).map { makeOp(lamport: UInt64($0), replica: replica, byte: UInt8($0)) }
    for op in ops2 { try! await transport.push(op) }
    transport.deliver()
    expect(transport.delivered == ops1, "partition mode delivers nothing new")
    expect(receivedBySubscriber.items == ops1, "subscriber sees nothing new under partition")

    // .reorder(seed:): all five ops eventually appear, order not guaranteed —
    // sort both emitted and delivered by opId and assert set equality.
    let reorderTransport = FakeSyncTransport()
    let reorderReceived = OpRecorder()
    reorderTransport.subscribe { op in reorderReceived.record(op) }
    reorderTransport.mode = .reorder(seed: 42)
    let ops3 = (1...5).map { makeOp(lamport: UInt64($0), replica: replica, byte: UInt8($0)) }
    for op in ops3 { try! await reorderTransport.push(op) }
    reorderTransport.deliver()
    expect(reorderTransport.delivered.count == ops3.count, "reorder mode drops nothing")
    expect(reorderTransport.delivered.sorted(by: { $0.opId < $1.opId }) == ops3.sorted(by: { $0.opId < $1.opId }),
           "reorder mode: emitted and delivered sets are equal once sorted by opId")
    expect(reorderTransport.delivered == reorderReceived.items, "subscriber sees exactly what `delivered` recorded")
    // Determinism: same seed, same five ops in the same push order -> identical permutation.
    let reorderTransport2 = FakeSyncTransport()
    reorderTransport2.mode = .reorder(seed: 42)
    for op in ops3 { try! await reorderTransport2.push(op) }
    reorderTransport2.deliver()
    expect(reorderTransport2.delivered == reorderTransport.delivered,
           "reorder(seed:) is deterministic — same seed and input yield the same permutation")

    // .lossy(dropRate: 1.0): drops everything.
    let lossyAllTransport = FakeSyncTransport()
    lossyAllTransport.mode = .lossy(dropRate: 1.0)
    let ops4 = (1...4).map { makeOp(lamport: UInt64($0), replica: replica, byte: UInt8($0)) }
    for op in ops4 { try! await lossyAllTransport.push(op) }
    lossyAllTransport.deliver()
    expect(lossyAllTransport.delivered.isEmpty, "lossy(dropRate: 1.0) delivers nothing")
    expect(lossyAllTransport.emitted == ops4, "emitted still records every pushed op even when all are dropped")

    // .lossy(dropRate: 0.5) with enough ops that an always-drop or always-keep
    // implementation would fail this: some survive, some don't, and the
    // fixed default lossySeed makes the exact split deterministic.
    let lossyPartialTransport = FakeSyncTransport()
    lossyPartialTransport.mode = .lossy(dropRate: 0.5)
    let replica2 = UUID(uuidString: "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB")!
    let ops5 = (1...40).map { makeOp(lamport: UInt64($0), replica: replica2, byte: UInt8($0 % 256)) }
    for op in ops5 { try! await lossyPartialTransport.push(op) }
    lossyPartialTransport.deliver()
    expect(!lossyPartialTransport.delivered.isEmpty && lossyPartialTransport.delivered.count < ops5.count,
           "lossy(dropRate: 0.5) over 40 ops keeps some and drops some (not all-or-nothing)")
    expect(Set(lossyPartialTransport.delivered.map(\.opId)).isSubset(of: Set(ops5.map(\.opId))),
           "every delivered op under lossy mode was one of the pushed ops")
    // Determinism: a fresh transport with the same default seed and the same
    // push sequence drops exactly the same ops.
    let lossyPartialTransport2 = FakeSyncTransport()
    lossyPartialTransport2.mode = .lossy(dropRate: 0.5)
    for op in ops5 { try! await lossyPartialTransport2.push(op) }
    lossyPartialTransport2.deliver()
    expect(lossyPartialTransport2.delivered == lossyPartialTransport.delivered,
           "lossy(dropRate:) is deterministic across independent transports given the same default seed")

    print("FakeSyncTransport suite: reliable/partition/reorder(seed:)/lossy(dropRate:) all deterministic and match the opId-sorted equivalence contract")
}

// MARK: - Wall-clock guard (mechanical, matches the SpatialOp.swift precedent)

private func runSubstrateWallClockGuard() {
    let root = "Sources/ContinuumRevivedCore/Substrates"
    let bannedTokens = ["Date.now", "CFAbsoluteTime", "clock()", "DispatchTime.now()", "ContinuousClock"]
    guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root) else {
        fputs("FAIL: wall-clock guard: could not list \(root) from cwd \(FileManager.default.currentDirectoryPath)\n", stderr)
        Foundation.exit(1)
    }
    var scanned = 0
    for entry in entries.sorted() where entry.hasSuffix(".swift") {
        let path = "\(root)/\(entry)"
        guard let source = try? String(contentsOfFile: path, encoding: .utf8) else {
            fputs("FAIL: wall-clock guard: could not read \(path)\n", stderr)
            Foundation.exit(1)
        }
        scanned += 1
        // Clock.swift is the one file allowed to say `Date(` — it's the blessed
        // SystemClock implementation the wall-clock ban routes everyone else through.
        if entry != "Clock.swift" {
            expect(!source.contains("Date("), "wall-clock guard: \(entry) must not call Date() directly (route through Clock)")
        }
        for token in bannedTokens {
            expect(!source.contains(token), "wall-clock guard: \(entry) must not reference '\(token)'")
        }
    }
    expect(scanned >= 5, "wall-clock guard: expected to scan at least 5 Substrates files, scanned \(scanned)")
    print("wall-clock guard: scanned \(scanned) files under \(root), only Clock.swift calls Date()")
}

// MARK: - Real-path check: ProcessTmuxControl against a real tmux subprocess

func runTmuxRealPathCheck() {
    guard let tmuxPath = TmuxLocator.resolve() else {
        writeTmuxRealPathManifest(["tmux_absent": true])
        print("tmux real-path check: SKIPPED — tmux not found on this machine (tmux_absent=true)")
        return
    }

    let semaphore = DispatchSemaphore(value: 0)
    Task {
        await runTmuxRealPathCheckAsync(tmuxPath: tmuxPath)
        semaphore.signal()
    }
    semaphore.wait()
}

private func runTmuxRealPathCheckAsync(tmuxPath: String) async {
    let control = ProcessTmuxControl(tmuxPath: tmuxPath)
    let sessionName = "continuum-substrate-check"
    let start = Date()

    do {
        // Best-effort cleanup from a prior interrupted run.
        try? await control.killSession(name: sessionName)

        let existsBefore = try await control.sessionExists(name: sessionName)
        expect(!existsBefore, "ProcessTmuxControl.sessionExists is false before newSession")

        let paneId = try await control.newSession(name: sessionName, cwd: "/tmp", innerCommand: nil)
        expect(!paneId.isEmpty, "ProcessTmuxControl.newSession returns a non-empty pane id")

        let existsAfter = try await control.sessionExists(name: sessionName)
        expect(existsAfter, "ProcessTmuxControl.sessionExists is true after newSession")

        let paneId2 = try await control.newWindow(inSession: sessionName, cwd: "/tmp", innerCommand: nil)
        expect(!paneId2.isEmpty && paneId2 != paneId, "ProcessTmuxControl.newWindow returns a second distinct pane id")

        let aliveBefore = try await control.isAlive(paneTarget: paneId)
        expect(aliveBefore, "ProcessTmuxControl.isAlive is true immediately after newSession")
        let aliveBefore2 = try await control.isAlive(paneTarget: paneId2)
        expect(aliveBefore2, "ProcessTmuxControl.isAlive is true immediately after newWindow")

        let cwdBefore = try await control.paneCurrentPath(paneTarget: paneId)
        expect(cwdBefore == "/tmp" || cwdBefore == "/private/tmp",
               "ProcessTmuxControl.paneCurrentPath reports the cwd newSession was given, got \(cwdBefore)")

        struct MissingSessionError: Error { let sessionName: String }
        let sessionsAfterWindow = try await control.listSessions()
        guard let sessionInfo = sessionsAfterWindow.first(where: { $0.name == sessionName }) else {
            throw MissingSessionError(sessionName: sessionName)
        }
        expect(sessionInfo.windowCount == 2, "listSessions().windowCount reflects two project windows, got \(sessionInfo.windowCount)")
        expect(Set(sessionInfo.paneTargets).isSuperset(of: [paneId, paneId2]), "listSessions().paneTargets includes both created panes, got \(sessionInfo.paneTargets)")

        try await control.killSession(name: sessionName)

        let aliveAfter = try await control.isAlive(paneTarget: paneId)
        expect(!aliveAfter, "ProcessTmuxControl.isAlive is false after killSession")

        let elapsed = Date().timeIntervalSince(start)
        writeTmuxRealPathManifest([
            "tmux_absent": false,
            "tmux_path": tmuxPath,
            "exists_before": existsBefore,
            "exists_after": existsAfter,
            "pane1": paneId,
            "pane2": paneId2,
            "isAlive_before": aliveBefore,
            "isAlive_before_2": aliveBefore2,
            "isAlive_after": aliveAfter,
            "cwd_before": cwdBefore,
            "session_window_count": sessionInfo.windowCount,
            "session_pane_targets": sessionInfo.paneTargets,
            "elapsed_seconds": elapsed
        ])
        print("tmux real-path check: exists_before=\(existsBefore) exists_after=\(existsAfter) pane1=\(paneId) pane2=\(paneId2) session_window_count=\(sessionInfo.windowCount) isAlive_after=\(aliveAfter) elapsed=\(String(format: "%.3f", elapsed))s")
    } catch {
        fputs("FAIL: tmux real-path check threw: \(error)\n", stderr)
        Foundation.exit(1)
    }
}

private func writeTmuxRealPathManifest(_ fields: [String: Any]) {
    let dir = URL(fileURLWithPath: ".build/checks-manifests", isDirectory: true)
    let path = dir.appendingPathComponent("ticket12-tmux-realpath.json")
    do {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: fields, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: path)
    } catch {
        fputs("WARN: tmux real-path check: could not write manifest to \(path.path): \(error)\n", stderr)
    }
}
