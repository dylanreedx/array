import Foundation
import Darwin
import AppKit
import ContinuumRevivedCore

/// Offline adapter over the production send and child-creation funnels. Never
/// constructs a CLI runner. WorkspaceAPIService.delegate uses handleSpawnRequest
/// too; this driver deliberately exercises that headless seam without a canvas.
@MainActor
struct ReplaySupervisorDriver {
    private static var ownedRoots: Set<String> = []
    static func createRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("replay-owned-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        ownedRoots.insert(root.resolvingSymlinksInPath().path)
        return root
    }
    static func removeRoot(_ root: URL) {
        ownedRoots.remove(root.resolvingSymlinksInPath().path)
        try? FileManager.default.removeItem(at: root)
    }
    static func command(_ args: [String], in cwd: URL, input: Data? = nil) throws -> Data {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args; p.currentDirectoryURL = cwd
        let output = Pipe()
        p.standardOutput = output; p.standardError = FileHandle.nullDevice
        let incoming = Pipe()
        if input != nil { p.standardInput = incoming }
        try p.run()
        if let input {
            try incoming.fileHandleForWriting.write(contentsOf: input)
            try incoming.fileHandleForWriting.close()
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw Failure(description: "fixture git command failed") }
        return data
    }
    static func prepare(source: URL, base: String, request: String) throws -> (TaskFixture, URL) {
        let root = try createRoot()
        do {
            let project = root.appendingPathComponent("project")
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
            let entries = String(decoding: try command(["ls-tree", "-r", base], in: source), as: UTF8.self)
            guard !entries.contains("120000 "), !entries.contains("160000 ") else {
                throw Failure(description: "linked fixture entries are unsupported")
            }
            let archive = try command(["archive", base], in: source)
            let archiveURL = root.appendingPathComponent("base.tar")
            try archive.write(to: archiveURL)
            let tar = Process()
            tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            tar.arguments = ["-xf", archiveURL.path, "-C", project.path]
            try tar.run(); tar.waitUntilExit()
            guard tar.terminationStatus == 0 else { throw Failure(description: "fixture export failed") }
            _ = try command(["init", "-q"], in: project)
            _ = try command(["add", "."], in: project)
            _ = try command(["write-tree"], in: project)
            let commit = try command(["cat-file", "commit", base], in: source)
            let reconstructed = String(decoding: try command(["hash-object", "-t", "commit", "-w", "--stdin"], in: project, input: commit), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard reconstructed == base else { throw Failure(description: "base identity changed") }
            _ = try command(["update-ref", "HEAD", base], in: project)
            return (TaskFixture(id: "synthetic-value", request: request, project: project, base: base), root)
        } catch {
            removeRoot(root)
            throw error
        }
    }
    struct TaskFixture {
        let id: String
        let request: String
        let project: URL
        let base: String
    }
    struct Receipt {
        let fixture: String
        let harness: AgentHarness
        let managed: Bool
        let prompts: [String]
        let children: Int
    }
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    func run(_ fixture: TaskFixture, harness: AgentHarness, managed: Bool,
             root: URL) async throws -> Receipt {
        do {
            return try await execute(fixture, harness: harness, managed: managed, root: root)
        } catch {
            if Self.ownedRoots.contains(root.resolvingSymlinksInPath().path) {
                let record: [String: Any] = ["v": 1, "fixture": fixture.id, "base": fixture.base,
                    "run": UUID().uuidString, "condition": ["harness": harness.rawValue, "mode": managed ? "managed" : "solo"],
                    "outcome": "failed", "passed": false, "usageComplete": false, "simulated": true,
                    "tokens": ["input": NSNull(), "output": NSNull(), "cacheRead": NSNull(), "cacheWrite": NSNull()],
                    "wallSeconds": NSNull(), "activeSeconds": NSNull(), "checkResult": "driverFailed"]
                try JSONSerialization.data(withJSONObject: record).write(to: root.appendingPathComponent("result.json"), options: .atomic)
            }
            throw error
        }
    }
    private func execute(_ fixture: TaskFixture, harness: AgentHarness, managed: Bool,
                         root: URL) async throws -> Receipt {
        let fm = FileManager.default
        let owned = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        let temporary = fm.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard Self.ownedRoots.contains(root.resolvingSymlinksInPath().path), owned.hasPrefix(temporary),
              fixture.project.resolvingSymlinksInPath().path.hasPrefix(owned) else {
            throw Failure(description: "refusing unowned replay storage")
        }
        let head = String(decoding: try Self.command(["rev-parse", "HEAD"], in: fixture.project), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let dirty = try Self.command(["status", "--porcelain"], in: fixture.project)
        guard head == fixture.base, dirty.isEmpty else { throw Failure(description: "fixture base is not clean and pinned") }
        let store = AgentStore(applicationSupportDirectory: root.appendingPathComponent("support"))
        let suite = "array.qa.replay.\(UUID().uuidString)"
        guard let policy = QAIsolatedDefaults(isolatedSuiteName: suite) else {
            throw Failure(description: "isolated defaults unavailable")
        }
        defer { policy.removePersistentDomain(forName: suite) }
        policy.set(managed, forKey: AgentManagedModeConfig.enabledKey)
        AgentModelCatalog.shared.resetForQA(snapshot: AgentCatalogQAFixture.claude)
        AgentModelCatalog.shared.resetForQA(snapshot: AgentCatalogQAFixture.codex)
        guard let model = AgentModelCatalog.shared.snapshot(for: harness).seedModel else {
            throw Failure(description: "fixture catalog missing")
        }
        let outside = root.appendingPathComponent("outside-worker")
        try Data("unchanged".utf8).write(to: outside)
        var runners: [ScriptedAgentRunner] = []
        var containedRunners: [ReplayContainedScriptedRunner] = []
        let supervisor = AgentSupervisor(store: store, makeRunner: { _ in
            let usage = TokenUsageSnapshot(inputTokens: 7, outputTokens: 2, totalCostUsd: nil,
                accountingObservationID: "replay-message", accountingInputTokens: 7)
            let runner = ScriptedAgentRunner(script: [.sessionStateChanged(.ready),
                .tokenUsageUpdated(threadId: "replay", snapshot: usage),
                .tokenUsageUpdated(threadId: "replay", snapshot: usage)], holdUntilStopped: true)
            runners.append(runner)
            let contained = ReplayContainedScriptedRunner(scripted: runner, project: fixture.project, outside: outside)
            containedRunners.append(contained)
            return contained
        }, warn: { _ in })
        var usageByIdentity: [String: TokenUsageSnapshot] = [:]
        let observation = supervisor.addDeliveredEventObserver { agent, event in
            if case let .tokenUsageUpdated(_, snapshot) = event,
               let identity = snapshot.accountingObservationID {
                usageByIdentity[agent.rawValue.uuidString + ":" + identity] = snapshot
            }
        }
        defer { supervisor.removeDeliveredEventObserver(observation) }
        supervisor.configureManagedMode(defaults: policy)
        supervisor.workspaceToolsPermission = { .free }
        defer { supervisor.stopAll() }
        let lead = supervisor.spawn(role: nil, prompt: nil, cwd: fixture.project,
                                    harness: harness, model: model, thinking: "low")
        let started = ProcessInfo.processInfo.systemUptime
        guard supervisor.send(fixture.request, to: lead) else {
            throw Failure(description: "production submission refused")
        }
        for _ in 0..<500 {
            if runners.first?.runCount == 1 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard runners.first?.prompts == [fixture.request] else {
            throw Failure(description: "production runner did not receive exact request")
        }
        if managed {
            guard supervisor.effectiveMode(for: lead) == .managed,
                  supervisor.handleSpawnRequest(SpawnRequest(role: nil, prompt: fixture.request,
                    isolated: false, sourceItemID: "replay-helper"), from: lead) != nil else {
                throw Failure(description: "production delegation refused")
            }
            for _ in 0..<500 {
                if runners.count == 2 && runners[1].runCount == 1 { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            guard runners.count == 2, runners[1].runCount == 1 else {
                throw Failure(description: "production helper never ran")
            }
        }
        for _ in 0..<500 {
            if usageByIdentity.count == (managed ? 2 : 1) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard try String(contentsOf: outside, encoding: .utf8) == "unchanged" else {
            throw Failure(description: "contained runner changed outside sentinel")
        }
        let children = supervisor.children(of: lead).count
        guard children == (managed ? 1 : 0) else {
            throw Failure(description: "condition produced wrong child count")
        }
        let prompts = runners.flatMap(\.prompts)
        supervisor.stopAll()
        for _ in 0..<500 {
            if runners.allSatisfy({ $0.completedRuns == 1 }) && containedRunners.allSatisfy({ $0.interval != nil }) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard runners.allSatisfy({ $0.completedRuns == 1 }) else {
            throw Failure(description: "fake runner failed to terminate")
        }
        let input = usageByIdentity.values.reduce(0) { $0 + ($1.accountingInputTokens ?? $1.inputTokens) }
        let output = usageByIdentity.values.reduce(0) { $0 + $1.outputTokens }
        guard input == (managed ? 14 : 7), output == (managed ? 4 : 2) else {
            throw Failure(description: "production usage observation lost or doubled tokens: input=\(input) output=\(output)")
        }
        let wall = ProcessInfo.processInfo.systemUptime - started
        var active = 0.0
        var end = 0.0
        for interval in containedRunners.compactMap(\.interval).sorted(by: { $0.0 < $1.0 }) {
            active += max(0, interval.1 - max(end, interval.0))
            end = max(end, interval.1)
        }
        let tokens: [String: Any] = ["input": input, "output": output, "cacheRead": NSNull(), "cacheWrite": NSNull()]
        let record: [String: Any] = ["v": 1, "fixture": fixture.id, "base": fixture.base, "run": UUID().uuidString,
            "condition": ["harness": harness.rawValue, "mode": managed ? "managed" : "solo"],
            "tokens": tokens,
            "usageComplete": false, "wallSeconds": wall, "activeSeconds": active,
            "outcome": "interrupted", "checkResult": "driverPassed", "passed": false, "simulated": true]
        try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]).write(
            to: root.appendingPathComponent("result.json"), options: .atomic)
        return Receipt(fixture: fixture.id, harness: harness, managed: managed,
                       prompts: prompts, children: children)
    }
}

@MainActor
func runReplayDriverChecks() async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("replay-driver-\(UUID().uuidString)")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let source = root.appendingPathComponent("source")
    try fm.createDirectory(at: source, withIntermediateDirectories: true)
    try Data("broken".utf8).write(to: source.appendingPathComponent("value"))
    for args in [["init", "-q"], ["add", "."], ["commit", "-qm", "fixture: seed replay"]] {
        _ = try ReplaySupervisorDriver.command(args, in: source)
    }
    let base = String(decoding: try ReplaySupervisorDriver.command(["rev-parse", "HEAD"], in: source), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    for harness in [AgentHarness.claudeCode, .codex] {
        for managed in [false, true] {
            let (fixture, runRoot) = try ReplaySupervisorDriver.prepare(source: source, base: base, request: "Repair the value.")
            defer { ReplaySupervisorDriver.removeRoot(runRoot) }
            let receipt = try await ReplaySupervisorDriver().run(fixture, harness: harness, managed: managed, root: runRoot)
            let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: runRoot.appendingPathComponent("result.json"))) as? [String: Any]
            guard saved?["base"] as? String == base, saved?["outcome"] as? String == "interrupted",
                  saved?["passed"] as? Bool == false,
                  let wall = saved?["wallSeconds"] as? Double, let active = saved?["activeSeconds"] as? Double,
                  active > 0, active <= wall else {
                throw ReplaySupervisorDriver.Failure(description: "run receipt lost identity, timing or interruption")
            }
            print("replay driver: \(receipt.harness) managed=\(receipt.managed) children=\(receipt.children)")
        }
    }
    let invalid = URL(fileURLWithPath: "/")
    do {
        _ = try await ReplaySupervisorDriver().run(.init(id: "invalid", request: "x", project: invalid, base: ""),
            harness: .codex, managed: false, root: invalid)
        throw ReplaySupervisorDriver.Failure(description: "unowned storage accepted")
    } catch let failure as ReplaySupervisorDriver.Failure {
        guard failure.description == "refusing unowned replay storage" else { throw failure }
    }
}

/// A process fake at the runner boundary, so production submission/delegation
/// actually starts a kernel-contained child. No provider executable is involved.
private final class ReplayContainedScriptedRunner: AgentRunning, @unchecked Sendable {
    let scripted: ScriptedAgentRunner
    let project: URL
    let outside: URL
    private let lock = NSLock()
    private var began: Double?
    private var ended: Double?
    var interval: (Double, Double)? {
        lock.withLock {
            guard let began, let ended else { return nil }
            return (began, ended)
        }
    }
    init(scripted: ScriptedAgentRunner, project: URL, outside: URL) {
        self.scripted = scripted; self.project = project; self.outside = outside
    }
    func run(prompt: AgentPrompt, onEvent: @escaping @Sendable (AgentRuntimeEvent) -> Void) throws {
        lock.withLock { began = ProcessInfo.processInfo.systemUptime }
        defer { lock.withLock { ended = ProcessInfo.processInfo.systemUptime } }
        guard let resolved = realpath(project.path, nil) else {
            throw NSError(domain: "ReplayContainment", code: 2)
        }
        defer { free(resolved) }
        let pathData = try JSONSerialization.data(withJSONObject: [String(cString: resolved)], options: [.withoutEscapingSlashes])
        let arrayString = String(decoding: pathData, as: UTF8.self)
        let quoted = String(arrayString.dropFirst().dropLast())
        let profile = "(version 1)(allow default)(deny network*)(deny file-write*)(allow file-write* (subpath " + quoted + "))"
        func touch(_ target: URL) throws -> Int32 {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
            p.arguments = ["-p", profile, "/usr/bin/touch", target.path]
            p.currentDirectoryURL = project
            var env = ProcessInfo.processInfo.environment
            env.removeValue(forKey: "TMUX"); env.removeValue(forKey: "TMUX_PANE")
            p.environment = env
            let errors = Pipe()
            p.standardError = errors
            try p.run()
            let stderrData = errors.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            if p.terminationStatus != 0 {
                fputs("replay worker: " + String(decoding: stderrData, as: UTF8.self), stderr)
            }
            return p.terminationStatus
        }
        let allowed = try touch(project.appendingPathComponent("worker-allowed"))
        let denied = try touch(outside)
        guard allowed == 0, denied != 0 else {
            throw NSError(domain: "ReplayContainment", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "worker containment probe failed: allowed=\(allowed) denied=\(denied) profile=\(profile)"])
        }
        try scripted.run(prompt: prompt, onEvent: onEvent)
    }
    func stop() { scripted.stop() }
    func observeSpawnRequests(_ handler: @escaping @Sendable (SpawnRequest) -> Void) {
        scripted.observeSpawnRequests(handler)
    }
    func observeRuntimeObservations(_ handler: @escaping @Sendable (AgentRuntimeObservation) -> Void) {
        scripted.observeRuntimeObservations(handler)
    }
}
