import AppKit
import ContinuumRevivedCore
import Foundation

/// Targeted-only measurement of Managed launch time: from the request to the
/// CLI session process starting. Prints numbers and asserts nothing about time.
///
/// - Lead: a new top-level Managed Claude agent; the request is the composer's
///   production entry, `AgentSupervisor.accept(.sendPrompt)`.
/// - Helper: `agent.delegate` through the production workspace API dispatch
///   from a Managed Claude lead.
///
/// "Started" is the birth time of a marker the disposable `claude` wrapper
/// creates before it execs the fixture CLI, and only for a session launch
/// (`--session-id` or `--resume`, never a `--tools` probe or titler run), so
/// version and hook probes on the way count as launch cost. The wrapper's own shell start (about a millisecond) is in
/// every sample alike. The file compiles unchanged on origin/array/integration,
/// so the same leg measures both sides.
@MainActor
enum ManagedLaunchTimingChecks {
    static let warmup = 3
    static let samples = 20

    static func realtimeNanos() -> Int64 {
        var ts = timespec(); clock_gettime(CLOCK_REALTIME, &ts)
        return Int64(ts.tv_sec) * 1_000_000_000 + Int64(ts.tv_nsec)
    }

    /// Birth time of `agent`'s launch marker in `dir`, once one exists. Markers
    /// carry the launching agent's id, so a lead woken in a helper's shared
    /// checkout is never read as the helper's launch.
    static func markerBirth(in dir: URL, agent: AgentID) -> Int64? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return nil }
        let tag = "launch-mark-" + agent.rawValue.uuidString.lowercased() + "-"
        for name in names where name.lowercased().hasPrefix(tag) {
            var st = stat()
            if stat(dir.appendingPathComponent(name).path, &st) == 0 {
                return Int64(st.st_birthtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_birthtimespec.tv_nsec)
            }
        }
        return nil
    }

    /// Every marker in `dir` with its offset from `t0`, so a reader can see
    /// which launches a sample contained.
    static func printMarkers(_ dir: URL, since t0: Int64) {
        for name in ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted() where name.hasPrefix("launch-mark-") {
            var st = stat(); _ = stat(dir.appendingPathComponent(name).path, &st)
            let birth = Int64(st.st_birthtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_birthtimespec.tv_nsec)
            print(String(format: "managed launch marker %@ +%.1f ms", name, Double(birth - t0) / 1_000_000))
        }
    }

    static func describe(_ name: String, _ values: [Double]) {
        let s = values.sorted()
        func p(_ q: Double) -> Double { s[max(0, min(s.count - 1, Int(ceil(Double(s.count) * q)) - 1))] }
        print(String(format: "managed launch %@ n=%d median=%.1f p95=%.1f min=%.1f max=%.1f ms",
                     name, s.count, p(0.5), p(0.95), s.first ?? 0, s.last ?? 0))
    }

    static func run() async throws {
        let b = try ManagedModeChecks.bench("launch-timing")
        defer { b.tearDown() }
        let fm = FileManager.default
        let real = b.binDir.appendingPathComponent("claude-fixture.py")
        try ManagedModeChecks.fakeClaude.write(to: real, atomically: true, encoding: .utf8)
        let wrapper = """
        #!/bin/sh
        case " $* " in *" --tools "*) ;; *" --session-id "*|*" --resume "*) : > "launch-mark-${ARRAY_AGENT_ID:-none}-$$" ;; esac
        exec /usr/bin/env python3 '\(real.path)' "$@"
        """
        let cli = b.binDir.appendingPathComponent("claude")
        try wrapper.write(to: cli, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        let supervisor = b.supervisor
        ManagedSettingChecks.write(AgentManagedModeConfig.enabledKey, true, b)

        func waitStarted(_ dir: URL, _ agent: AgentID, _ what: String) async throws -> Int64 {
            try await AgentPresenceChecks.eventually("\(what) CLI never started", timeout: 20) { markerBirth(in: dir, agent: agent) != nil }
            return markerBirth(in: dir, agent: agent)!
        }
        func settle(_ id: AgentID) async throws {
            try await AgentPresenceChecks.eventually("agent did not settle", timeout: 20) {
                supervisor.records[id]?.latestTurnAt != nil && !supervisor.isRunning(id)
            }
            supervisor.stop(id)
        }

        // Leads: a fresh Managed agent per sample, request at the composer entry.
        var lead: [Double] = []
        for i in 0..<(warmup + samples) {
            let cwd = b.binDir.appendingPathComponent("lead-\(i)", isDirectory: true)
            try fm.createDirectory(at: cwd, withIntermediateDirectories: true)
            let id = supervisor.spawn(role: nil, prompt: nil, cwd: cwd, harness: .claudeCode,
                                      model: ManagedModeChecks.model, thinking: AgentModelConfig.defaultThinking)
            _ = supervisor.setMode(.managed, for: id)
            let t0 = realtimeNanos()
            let accepted = await supervisor.accept(.sendPrompt(AgentPrompt("launch timing")), for: id)
            try ManagedModeChecks.expect(accepted == .accepted, "lead submission refused")
            let t1 = try await waitStarted(cwd, id, "lead")
            if i >= warmup { lead.append(Double(t1 - t0) / 1_000_000) }
            try await settle(id)
            if i == warmup { printMarkers(cwd, since: t0) }
        }
        describe("lead", lead)

        // Helpers: delegated from the fixture's Managed Claude lead.
        let parent = b.f.agentId
        try b.f.delegate.reconciledManagedSessionSource.reconcile(
            registry: b.f.delegate.registryStore!.loadOrEmpty(), reason: .continuumRestarted, now: Date())
        try ManagedModeChecks.expect(supervisor.setProviderSettings(agentID: parent, harness: .claudeCode, model: ManagedModeChecks.model),
                                     "could not select the lead's harness")
        _ = supervisor.setMode(.managed, for: parent)
        try ManagedModeChecks.expect(supervisor.effectiveMode(for: parent) == .managed, "the fixture agent is not a Managed lead")
        var helper: [Double] = []
        for i in 0..<(warmup + samples) {
            let t0 = realtimeNanos()
            let reply = b.f.api.dispatch(agentId: parent, requestId: "launch-\(i)", op: "agent.delegate",
                                         payload: ["task": "launch timing \(i)", "title": "Launch \(i)",
                                                   "harness": "Claude Code", "model": "\(ManagedModeChecks.model)",
                                                   "idempotencyKey": "launch-key-\(i)-\(UUID().uuidString)"])
            guard case let .result(result) = reply,
                  let child = result["childAgentId"]?.string.flatMap(UUID.init(uuidString:)).map(AgentID.init(rawValue:)),
                  let childCwd = supervisor.records[child]?.cwd else {
                throw WorkspaceAgentReportChecks.Failure(description: "managed-launch: delegation failed: \(reply)")
            }
            let t1 = try await waitStarted(URL(fileURLWithPath: childCwd, isDirectory: true), child, "helper")
            if i >= warmup { helper.append(Double(t1 - t0) / 1_000_000) }
            try await settle(child)
        }
        describe("helper", helper)
        print("Managed launch timing printed (no timing assertions)")
    }
}
