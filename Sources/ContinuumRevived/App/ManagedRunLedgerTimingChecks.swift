import AppKit
import ContinuumRevivedCore
import Foundation

/// Targeted-only measurement of what the run ledger adds to the request path.
/// Prints numbers and asserts nothing about time: timing asserts are flaky.
///
/// Part 1 times only the statements the ledger added, against the production
/// supervisor and its production ledger with recording enabled:
/// - submission: the gate and hand-off that `AgentSupervisor.accept(_:for:)`
///   runs after an accepted intent, repeated here verbatim (update it with them);
/// - delegation: `supervisor.runLedger.delegated(...)`, the one statement added
///   to `WorkspaceAPIService` delegation;
/// - helper report: `runLedger.reported(...)` as `fileReport` calls it.
/// Each timed hand-off is followed by a pause so the ledger queue is idle at the
/// next one, as it is when a person submits.
///
/// Part 2 times the whole production `accept` with recording on and off,
/// alternating within each pair, and reports the paired differences.
///
/// Storage: `makeBench` refuses unless CONTINUUM_APP_SUPPORT is already a
/// temporary directory, then creates and owns its own temporary support.
@MainActor
enum ManagedRunLedgerTimingChecks {
    static let handOffWarmup = 200
    static let handOffSamples = 5_000
    static let handOffPauseMicroseconds: useconds_t = 2_000
    static let pairWarmup = 20
    static let pairSamples = 1_000

    static func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
    static func micros(_ start: UInt64, _ end: UInt64) -> Double { Double(end - start) / 1000 }

    static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        sorted[max(0, min(sorted.count - 1, Int(ceil(Double(sorted.count) * p)) - 1))]
    }

    static func describe(_ name: String, _ values: [Double]) {
        let s = values.sorted()
        print(String(format: "ledger hand-off %@ n=%d median=%.2f p95=%.2f max=%.2f us",
                     name, s.count, percentile(s, 0.5), percentile(s, 0.95), s.last ?? 0))
    }

    static func run() async throws {
        let b = try ManagedModeChecks.bench("run-ledger-timing")
        defer { b.tearDown() }
        let cli = b.binDir.appendingPathComponent("claude")
        try ManagedRunLedgerChecks.script.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        let supervisor = b.supervisor, lead = b.f.agentId
        try b.f.delegate.reconciledManagedSessionSource.reconcile(
            registry: b.f.delegate.registryStore!.loadOrEmpty(), reason: .continuumRestarted, now: Date())
        try ManagedRunLedgerChecks.expect(supervisor.setProviderSettings(agentID: lead, harness: .claudeCode, model: ManagedModeChecks.model),
                                          "could not select lead harness")
        ManagedSettingChecks.write(AgentManagedModeConfig.enabledKey, true, b)
        try ManagedRunLedgerChecks.expect(supervisor.effectiveMode(for: lead) == .managed, "lead is not a Managed lead")
        let support = AgentStore(smokeTest: false).layout.applicationSupportDirectory
        let ledger = support.appendingPathComponent("run-ledger/ledger.jsonl")
        try ManagedRunLedgerChecks.expect(
            ledger.resolvingSymlinksInPath().path.hasPrefix(b.binDir.resolvingSymlinksInPath().path + "/"),
            "ledger is outside the check-owned temporary directory")
        print("ledger timing storage: \(ledger.path)")

        func idle() async throws {
            try await AgentPresenceChecks.eventually("timing lead idle", timeout: 15) {
                !supervisor.isRunning(lead) && supervisor.turnSnapshot(for: lead)?.capabilities.canSend == true
            }
        }

        // Part 2 first, while the ledger file is small: whole accept, on/off interleaved.
        defer { supervisor.qaRunLedgerRecording = true }
        var on: [Double] = [], off: [Double] = [], diffs: [Double] = []
        for pair in 0..<(pairWarmup + pairSamples) {
            var sample: [Bool: Double] = [:]
            for enabled in (pair % 2 == 0 ? [false, true] : [true, false]) {
                try await idle()
                supervisor.qaRunLedgerRecording = enabled
                let start = now()
                let accepted = await supervisor.accept(.sendPrompt(AgentPrompt("timing")), for: lead)
                let end = now()
                try ManagedRunLedgerChecks.expect(accepted == .accepted, "timing submission refused")
                sample[enabled] = micros(start, end)
            }
            if pair >= pairWarmup {
                on.append(sample[true]!); off.append(sample[false]!); diffs.append(sample[true]! - sample[false]!)
            }
        }
        try await idle()
        supervisor.qaRunLedgerRecording = true

        // Part 1: the added statements only. Inputs are built outside the timed region.
        let intent = AgentComposerIntent.sendPrompt(AgentPrompt("timing"))
        let result = IntentAcceptance.accepted
        let checks: [AgentReport.Check] = [.init(what: "timing", result: .pass), .init(what: "timing", result: .fail)]
        let findings: [AgentReport.Finding] = [.init(level: .issue, text: "timing")]
        var submission: [Double] = [], delegation: [Double] = [], report: [Double] = [], floor: [Double] = []
        var gate: [Double] = [], enqueue: [Double] = []
        var taken = 0
        for iteration in 0..<(handOffWarmup + handOffSamples) {
            let child = UUID(), requestId = UUID().uuidString, filedAt = Date()

            var start = now()
            // Verbatim from `AgentSupervisor.accept(_:for:)`.
            if supervisor.qaRunLedgerRecording, result == .accepted, supervisor.effectiveMode(for: lead) == .managed,
               supervisor.records[lead]?.parentAgentID == nil {
                switch intent {
                case .send, .sendPrompt, .queue:
                    supervisor.runLedger.submission(agent: lead.rawValue, project: supervisor.records[lead]?.projectId)
                    taken += 1
                default: break
                }
            }
            var end = now()
            if iteration >= handOffWarmup { submission.append(micros(start, end)) }
            usleep(handOffPauseMicroseconds)

            start = now()
            supervisor.runLedger.delegated(parent: lead.rawValue, child: child, source: requestId)
            end = now()
            if iteration >= handOffWarmup { delegation.append(micros(start, end)) }
            usleep(handOffPauseMicroseconds)

            start = now()
            if supervisor.qaRunLedgerRecording {
                supervisor.runLedger.reported(agent: child, at: filedAt, checks: checks, findings: findings)
            }
            end = now()
            if iteration >= handOffWarmup { report.append(micros(start, end)) }
            usleep(handOffPauseMicroseconds)

            // The same submission split in two: the gate's reads of main-actor
            // state, then the enqueue alone with its inputs already read.
            start = now()
            let gated = supervisor.qaRunLedgerRecording && result == .accepted
                && supervisor.effectiveMode(for: lead) == .managed && supervisor.records[lead]?.parentAgentID == nil
            let project = supervisor.records[lead]?.projectId
            end = now()
            if iteration >= handOffWarmup { gate.append(micros(start, end)) }
            try ManagedRunLedgerChecks.expect(gated, "submission gate split did not take the recording branch")
            usleep(handOffPauseMicroseconds)
            start = now()
            supervisor.runLedger.submission(agent: lead.rawValue, project: project)
            end = now()
            if iteration >= handOffWarmup { enqueue.append(micros(start, end)) }
            usleep(handOffPauseMicroseconds)

            start = now(); end = now()
            if iteration >= handOffWarmup { floor.append(micros(start, end)) }
        }
        try ManagedRunLedgerChecks.expect(taken == handOffWarmup + handOffSamples, "submission gate did not take the recording branch")

        describe("submission", submission)
        describe("submission-gate-only", gate)
        describe("submission-enqueue-only", enqueue)
        describe("delegation", delegation)
        describe("helper-report", report)
        describe("timer-floor", floor)

        // The hand-offs reached the production ledger: wait for its queue to write them.
        try await AgentPresenceChecks.eventually("ledger did not record the timed hand-offs", timeout: 600) {
            ManagedRunLedgerChecks.rows(ledger, "reported").count >= handOffWarmup + handOffSamples
        }
        try ManagedRunLedgerChecks.expect(ManagedRunLedgerChecks.rows(ledger, "delegated").count >= handOffWarmup + handOffSamples,
                                          "ledger did not record the timed delegations")

        let d = diffs.sorted(), n = d.count
        let half = 0.98 * Double(n).squareRoot()
        let lo = d[max(0, Int((Double(n) / 2 - half).rounded(.down)))]
        let hi = d[min(n - 1, Int((Double(n) / 2 + half).rounded(.up)))]
        print(String(format: "ledger whole submission pairs=%d median off=%.2f on=%.2f us", n,
                     percentile(off.sorted(), 0.5), percentile(on.sorted(), 0.5)))
        print(String(format: "ledger whole submission paired on-off median=%.2f us 95%%CI=[%.2f, %.2f] IQR=[%.2f, %.2f] p5=%.2f p95=%.2f",
                     percentile(d, 0.5), lo, hi, percentile(d, 0.25), percentile(d, 0.75), percentile(d, 0.05), percentile(d, 0.95)))
        print("Managed run ledger timing printed (no timing assertions)")
    }
}
