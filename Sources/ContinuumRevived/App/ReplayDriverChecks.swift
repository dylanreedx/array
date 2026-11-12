import AppKit
import ContinuumRevivedCore
import Darwin
import Foundation

// Replay benchmark driver (`benchmarks/replay/README.md`). The driver only
// submits the request to a lead in the requested mode, through the production
// send path. Every delegation is the LEAD's: a fake lead calls `array_delegate`
// over the production workspace MCP server, which reaches
// `WorkspaceAPIService.delegate` and `handleSpawnRequest` like a real CLI's call.
// No CLI runner is ever constructed and no provider process is started.

private let replayRepoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
private let replayScript = replayRepoRoot.appendingPathComponent("benchmarks/replay/replay.py")

struct ReplayFailure: Error, CustomStringConvertible {
    let description: String
}

/// The one Swift record writer, over the field list in `manifest.json`.
@MainActor
enum ReplayRecordSchema {
    static func manifest() throws -> (version: Int, fields: [String]) {
        let url = replayRepoRoot.appendingPathComponent("benchmarks/replay/manifest.json")
        guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
              let version = object["v"] as? Int,
              let fields = (object["recordFields"] as? [[String: Any]])?.compactMap({ $0["name"] as? String }) else {
            throw ReplayFailure(description: "manifest has no record field list")
        }
        return (version, fields)
    }

    static func write(_ record: [String: Any], to sink: URL) throws {
        let (_, fields) = try manifest()
        guard Set(record.keys) == Set(fields), record.count == fields.count else {
            throw ReplayFailure(description: "record fields differ from manifest: \(Set(record.keys).symmetricDifference(fields).sorted())")
        }
        guard !ReplaySupervisorDriver.insideOwnedRoot(sink) else {
            throw ReplayFailure(description: "record sink is inside a run directory")
        }
        var line = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .withoutEscapingSlashes])
        line.append(0x0A)
        if !FileManager.default.fileExists(atPath: sink.path) {
            FileManager.default.createFile(atPath: sink.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: sink)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
        try handle.synchronize()
    }
}

/// The frozen task, read from `replay.py make-fixture`; Swift never derives one.
struct ReplayTask {
    let json: URL
    let source: URL
    let base: String
    let request: String
    let task: String
    let fixture: String
    let requestHash: String
    let checksHash: String

    static func load(_ json: URL) throws -> ReplayTask {
        guard let o = try JSONSerialization.jsonObject(with: Data(contentsOf: json)) as? [String: Any],
              let source = o["source"] as? String, let base = o["base"] as? String,
              let request = o["request"] as? String, let task = o["task"] as? String,
              let fixture = o["fixture"] as? String, let requestHash = o["requestHash"] as? String,
              let checksHash = o["checksHash"] as? String else {
            throw ReplayFailure(description: "task.json is incomplete")
        }
        return ReplayTask(json: json, source: URL(fileURLWithPath: source), base: base, request: request,
                          task: task, fixture: fixture, requestHash: requestHash, checksHash: checksHash)
    }
}

/// What the fake lead does. This is the fake AGENT's behaviour, not the
/// driver's: the driver never delegates, never decides a helper count.
enum ReplayLeadScript: String {
    case repairs            // edits the code itself
    case delegatesTwoParts  // calls array_delegate twice, edits nothing
    case triesToDelegate    // a solo lead that asks for a helper anyway
    case crashes            // its process fails on the first turn
}

struct ReplayCondition {
    let harness: AgentHarness
    let managed: Bool
    let lead: ReplayLeadScript
    var codexResets = false
    /// The lead's Codex thread began in an earlier process: its first turn
    /// resumes it, carrying history this process never watched.
    var codexResumed = false
}

/// Recorded provider streams, translated by the PRODUCTION translators so the
/// runner boundary sees exactly what a real runner would publish.
enum ReplayStreams {
    static let claudeFixture = "claude-2.1.291-opus-turn.jsonl"
    static let codexFixture = "codex-appserver-single-agent.jsonl"

    static func lines(_ name: String) throws -> [String] {
        let url = replayRepoRoot.appendingPathComponent("Sources/ContinuumRevivedCoreChecks/Fixtures/\(name)")
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    static func keep(_ event: AgentRuntimeEvent) -> Bool {
        switch event {
        case .sessionStateChanged, .turnStarted, .tokenUsageUpdated, .turnCompleted: return true
        default: return false
        }
    }

    /// One claude process turn. The recorded result carries uuid/session_id;
    /// each turn is a new result, so it gets its own uuid, as the CLI's do.
    static func claudeTurn(session: String) throws -> [AgentRuntimeEvent] {
        var translator = ClaudeEventTranslator()
        var events: [AgentRuntimeEvent] = []
        for line in try lines(claudeFixture) {
            guard var object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if object["session_id"] != nil { object["session_id"] = session }
            if object["type"] as? String == "result" { object["uuid"] = UUID().uuidString.lowercased() }
            let text = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
            events += translator.translate(line: text)
        }
        return events.filter(keep)
    }

    /// The recorded capture's own thread and turn ids.
    static let codexFixtureThread = "00000000-0000-4000-8000-000000000001"
    static let codexFixtureTurn = "00000000-0000-4000-8000-000000000002"

    /// One codex app-server turn on a persistent thread, as the production
    /// runner publishes it: the agent's own thread, a fresh turn id, provider
    /// times after every earlier turn's, and, for a resumed thread, the marker
    /// `CodexAgentRunner` puts on the `thread/started` it synthesizes. The
    /// recorded cumulative totals continue from `carried`.
    static func codexTurn(thread: String, turn: String, carried: [String: Int], resumed: Bool,
                          providerTime: Int) throws -> [AgentRuntimeEvent] {
        var translator = CodexAppServerEventTranslator()
        var events: [AgentRuntimeEvent] = []
        for (index, line) in try lines(codexFixture).enumerated() {
            let renamed = line.replacingOccurrences(of: codexFixtureThread, with: thread)
                .replacingOccurrences(of: codexFixtureTurn, with: turn)
            guard var object = try JSONSerialization.jsonObject(with: Data(renamed.utf8)) as? [String: Any] else { continue }
            if object["emittedAtMs"] != nil { object["emittedAtMs"] = providerTime + index }
            if object["method"] as? String == "thread/started", resumed, var params = object["params"] as? [String: Any] {
                params[CodexAppServerEventTranslator.resumedMarker] = true
                object["params"] = params
            }
            if object["method"] as? String == "thread/tokenUsage/updated",
               var params = object["params"] as? [String: Any],
               var usage = params["tokenUsage"] as? [String: Any],
               var total = usage["total"] as? [String: Any] {
                for (key, value) in carried { total[key] = ((total[key] as? Int) ?? 0) + value }
                usage["total"] = total; params["tokenUsage"] = usage; object["params"] = params
            }
            let text = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
            events += translator.translate(line: text)
        }
        return events.filter(keep)
    }

    /// The recorded thread's last cumulative total, every counter in it.
    static func recordedCodexFinalTotal() throws -> [String: Int] {
        var last: [String: Int]?
        for line in try lines(codexFixture) {
            guard let o = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  o["method"] as? String == "thread/tokenUsage/updated",
                  let total = ((o["params"] as? [String: Any])?["tokenUsage"] as? [String: Any])?["total"] as? [String: Any]
            else { continue }
            last = total.compactMapValues { $0 as? Int }
        }
        guard let last else { throw ReplayFailure(description: "codex fixture has no usage") }
        return last
    }
}

/// Which agents had a failed turn, from production-delivered events. Usage is
/// never counted here: the run ledger records it (`ReplayLedgerRecord`).
struct ReplayTurnOutcomes {
    private(set) var failedTurns: [AgentID: Int] = [:]

    mutating func observe(_ agent: AgentID, _ event: AgentRuntimeEvent) {
        switch event {
        case let .turnCompleted(_, _, outcome, _) where outcome != .completed:
            failedTurns[agent, default: 0] += 1
        case let .sessionStateChanged(state) where state == .error:
            failedTurns[agent, default: 0] += 1
        default:
            break
        }
    }
}

/// The run's task as the production run ledger recorded it, read through the
/// usage page's own reader and derivation (`RunLedgerUsageReader`,
/// `UsageReport.make`), never a second one. Missing is never zero; a kind the
/// harness never reports (Codex cache writes) is "not reported", not missing.
enum ReplayLedgerRecord {
    static let kinds: [(name: String, type: UsageReport.TokenType)] =
        [("uncachedInput", .uncachedInput), ("cacheRead", .cacheRead), ("cacheWrite", .cacheWrite), ("output", .output)]

    /// Fills the ledger fields; returns where the ledger and the production
    /// records disagree (a measurement failure, never papered over).
    static func fill(_ record: inout [String: Any], ledger url: URL, lead: AgentID, managed: Bool,
                     productionHelpers: Int) -> [String] {
        let data = (try? Data(contentsOf: url)) ?? Data()
        let read = RunLedgerUsageReader.read(data)
        // `.plans/116` gap 8: the lead's turns that started after its task closed
        // and that no helper result woke are in no task. Listed apart with their
        // flags, never added to the task's figures.
        let afterClose = read.untasked.filter { $0.agent == lead.rawValue }
        record["leadTurnsAfterClose"] = Set(afterClose.map { $0.turn ?? "" }).count
        record["afterCloseProblems"] = Set(afterClose.flatMap(\.incomplete)).subtracting(["noTask"]).sorted()
        let tasks = read.tasks.filter { $0.lead == lead.rawValue }
        guard tasks.count == 1, let task = tasks.first,
              let line = UsageReport.make(RunLedgerUsageReader.Ledger(tasks: [task]), period: .all).tasks.first else {
            record["usageProblems"] = ["the run ledger holds \(tasks.count) task(s) for the lead"]
            return ["the run ledger holds \(tasks.count) task(s) for the lead, not one"]
        }
        var disagreements: [String] = []
        record["ledgerTask"] = task.id.uuidString.lowercased()
        let mode = managed ? "managed" : "free"
        if task.mode != mode { disagreements.append("the ledger recorded mode \(task.mode ?? "none"), not \(mode)") }
        record["helperCount"] = task.helpers.count
        if managed { record["fannedOut"] = !task.helpers.isEmpty }
        if task.helpers.count != productionHelpers {
            disagreements.append("the ledger delegated \(task.helpers.count) helper(s); the production records hold \(productionHelpers)")
        }

        var tokens: [String: Any] = [:], notReported: [String] = [], problems: [String] = []
        let all = line.tokens[.all] ?? [:]
        for (name, type) in kinds {
            let figure = all[type] ?? UsageReport.Figure(unknown: 1)
            if figure.isNotReported {
                tokens[name] = NSNull(); notReported.append(name)
            } else if figure.isUnknown {
                tokens[name] = NSNull(); problems.append("\(name) unknown")
            } else {
                tokens[name] = figure.known
            }
        }
        if task.state != .closed { problems.append("task \(task.state.rawValue)") }
        problems += Set(task.usage.flatMap(\.incomplete)).subtracting(["reportedByParent"]).sorted()
        let complete = line.fullyCounted && problems.isEmpty
        if !complete && problems.isEmpty { problems.append("usage not fully counted") }
        record["tokens"] = tokens
        record["tokensNotReported"] = notReported
        record["usageComplete"] = complete
        record["usageProblems"] = problems
        record["usageRows"] = task.usage.map { row -> [String: Any] in
            var counts: [String: Any] = [:]
            for (name, type) in kinds {
                counts[name] = row.tokens.flatMap { type == .uncachedInput ? $0.uncachedInput : type == .cacheRead ? $0.cacheRead
                    : type == .cacheWrite ? $0.cacheWrite : $0.output } ?? NSNull()
            }
            return ["agent": row.agent.uuidString.lowercased(), "role": row.agent == lead.rawValue ? "lead" : "helper",
                    "parent": row.parent.map { $0.uuidString.lowercased() as Any } ?? NSNull(),
                    "harness": row.harness ?? NSNull(), "model": row.model ?? NSNull(),
                    "modelSource": row.modelSource ?? NSNull(), "turn": row.turn ?? NSNull(),
                    "tokens": counts, "incomplete": row.incomplete]
        }
        record["wallSeconds"] = line.timeToAnswer.map { $0 as Any } ?? NSNull()
        record["activeSeconds"] = line.activeTime.map { $0 as Any } ?? NSNull()
        return disagreements
    }
}

/// Lock-held facts shared by the fake runners of one run.
final class ReplayRunFacts: @unchecked Sendable {
    private let lock = NSLock()
    private var intervalsStorage: [(Double, Double)] = []
    private var turnsStorage: [AgentID: Int] = [:]
    private var codexCarried: [AgentID: [String: Int]] = [:]
    private var providerClock = Int(Date().timeIntervalSince1970 * 1000)
    private var interceptedStorage = 0
    private var leadToolsStorage: [Bool] = []
    private var leaksStorage: [String] = []
    private var delegateRepliesStorage: [String] = []

    var intervals: [(Double, Double)] { lock.withLock { intervalsStorage } }
    /// Every agent turn the fakes ran, counted by the fakes themselves.
    var turns: Int { lock.withLock { turnsStorage.values.reduce(0, +) } }
    var intercepted: Int { lock.withLock { interceptedStorage } }
    var leadLaunchesWithTools: [Bool] { lock.withLock { leadToolsStorage } }
    var leaks: [String] { lock.withLock { leaksStorage } }
    var delegateReplies: [String] { lock.withLock { delegateRepliesStorage } }

    func interval(_ start: Double, _ end: Double) { lock.withLock { intervalsStorage.append((start, end)) } }
    func nextTurn(_ id: AgentID) -> Int { lock.withLock { turnsStorage[id, default: 0] += 1; return turnsStorage[id]! } }
    func intercept() { lock.withLock { interceptedStorage += 1 } }
    func leadLaunch(hasTools: Bool) { lock.withLock { leadToolsStorage.append(hasTools) } }
    func leak(_ text: String) { lock.withLock { leaksStorage.append(text) } }
    func delegateReply(_ text: String) { lock.withLock { delegateRepliesStorage.append(text) } }
    func carried(_ id: AgentID) -> [String: Int] { lock.withLock { codexCarried[id] ?? [:] } }
    func carry(_ id: AgentID, _ value: [String: Int]) { lock.withLock { codexCarried[id] = value } }
    /// Provider times (ms) for `count` frames, later than every earlier turn's.
    func providerTimes(_ count: Int) -> Int {
        lock.withLock { let start = providerClock; providerClock += count + 1; return start }
    }
}

@MainActor
final class ReplaySupervisorDriver {
    private static var ownedRoots: [String: (UInt64, UInt64)] = [:]

    static func createRoot() throws -> URL {
        let made = FileManager.default.temporaryDirectory.appendingPathComponent("replay-owned-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: made, withIntermediateDirectories: false)
        let root = URL(fileURLWithPath: try realPath(made.path), isDirectory: true)
        var info = stat()
        guard lstat(root.path, &info) == 0 else { throw ReplayFailure(description: "replay root vanished") }
        ownedRoots[root.path] = (UInt64(info.st_dev), UInt64(info.st_ino))
        for folder in ["project", "support", "tmp", "tmux", "home"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: false)
        }
        return root
    }

    /// Created by this process, still the same directory, and not a link.
    static func requireOwned(_ root: URL) throws {
        var info = stat()
        guard lstat(root.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              let owned = ownedRoots[root.path], owned == (UInt64(info.st_dev), UInt64(info.st_ino)),
              (try? realPath(root.path)) == root.path else {
            throw ReplayFailure(description: "refusing unowned replay storage")
        }
    }

    static func insideOwnedRoot(_ url: URL) -> Bool {
        let path = (try? realPath(url.deletingLastPathComponent().path))
            .map { $0 + "/" + url.lastPathComponent } ?? url.path
        return ownedRoots.keys.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    static func removeRoot(_ root: URL) {
        guard ownedRoots.removeValue(forKey: root.path) != nil else { return }
        try? FileManager.default.removeItem(at: root)
    }

    static func realPath(_ path: String) throws -> String {
        guard let resolved = realpath(path, nil) else { throw ReplayFailure(description: "unresolvable path \(path)") }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    @discardableResult
    static func command(_ executable: String, _ args: [String], in cwd: URL, input: Data? = nil,
                        environment: [String: String]? = nil) throws -> Data {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args; p.currentDirectoryURL = cwd
        if let environment { p.environment = environment }
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
        guard p.terminationStatus == 0 else {
            throw ReplayFailure(description: "\(URL(fileURLWithPath: executable).lastPathComponent) \(args.first ?? "") failed")
        }
        return data
    }

    static func git(_ args: [String], in cwd: URL, input: Data? = nil) throws -> String {
        String(decoding: try command("/usr/bin/git", args, in: cwd, input: input), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The base commit's tree and its single commit object; no history after it.
    static func export(_ task: ReplayTask, into project: URL) throws {
        let entries = try git(["ls-tree", "-r", task.base], in: task.source)
        guard !entries.contains("120000 "), !entries.contains("160000 ") else {
            throw ReplayFailure(description: "linked fixture entries are unsupported")
        }
        let archive = try command("/usr/bin/git", ["archive", task.base], in: task.source)
        try command("/usr/bin/tar", ["-xf", "-", "-C", project.path], in: project, input: archive)
        _ = try git(["init", "-q"], in: project)
        _ = try git(["add", "."], in: project)
        _ = try git(["write-tree"], in: project)
        let commit = try command("/usr/bin/git", ["cat-file", "commit", task.base], in: task.source)
        guard try git(["hash-object", "-t", "commit", "-w", "--stdin"], in: project, input: commit) == task.base else {
            throw ReplayFailure(description: "base identity changed")
        }
        _ = try git(["update-ref", "HEAD", task.base], in: project)
    }

    // MARK: - One run

    let task: ReplayTask
    let sink: URL
    var injectedRoot: URL?
    /// Agent turns the fakes ran in the last run, counted by the fakes, never
    /// read from the ledger: what a witness checks the ledger's totals against.
    private(set) var lastRunTurns = 0

    init(task: ReplayTask, sink: URL) {
        self.task = task
        self.sink = sink
    }

    /// Always returns the run's record, written to the sink BEFORE the run's
    /// directory is cleaned, whatever the outcome.
    func run(_ condition: ReplayCondition) async -> [String: Any] {
        var record = blankRecord(condition)
        var root: URL?
        do {
            let made = try injectedRoot ?? Self.createRoot()
            root = made
            try await execute(condition, root: made, record: &record)
        } catch {
            record["outcome"] = "driverFailed"
            record["failure"] = "\(error)"
            record["passed"] = false
        }
        do {
            try ReplayRecordSchema.write(record, to: sink)
        } catch {
            fputs("replay: record write failed: \(error)\n", stderr)
        }
        if let root { Self.removeRoot(root) }
        return record
    }

    private func blankRecord(_ condition: ReplayCondition) -> [String: Any] {
        let version = (try? ReplayRecordSchema.manifest().version) ?? 0
        return ["v": version, "run": UUID().uuidString.lowercased(), "task": task.task, "ledgerTask": NSNull(),
                "fixture": task.fixture, "base": task.base, "requestHash": task.requestHash,
                "checksHash": task.checksHash, "harness": condition.harness == .codex ? "codex" : "claude",
                "mode": condition.managed ? "managed" : "solo", "actualChoice": NSNull(), "simulated": true,
                "outcome": "driverFailed", "failure": NSNull(),
                "fannedOut": condition.managed ? false as Any : NSNull(), "helperCount": 0, "helpers": [Any](),
                "delegationAttempts": 0,
                "tokens": ["uncachedInput": NSNull(), "cacheRead": NSNull(), "cacheWrite": NSNull(), "output": NSNull()],
                "tokensNotReported": [Any](), "usageRows": [Any](),
                "usageComplete": false, "usageProblems": ["no usage observed"], "wallSeconds": NSNull(),
                "activeSeconds": NSNull(), "leadTurnsAfterClose": 0, "afterCloseProblems": [String](), "humanSteps": NSNull(), "diffHash": NSNull(), "changedPaths": [Any](),
                "tampered": [Any](), "checks": [String: Any](), "gradeResult": "notGraded",
                "hiddenPassed": NSNull(), "neighbourPassed": NSNull(), "passed": false]
    }

    private func execute(_ condition: ReplayCondition, root: URL, record: inout [String: Any]) async throws {
        try Self.requireOwned(root)
        let project = root.appendingPathComponent("project")
        try Self.export(task, into: project)
        guard try Self.git(["rev-parse", "HEAD"], in: project) == task.base,
              try Self.git(["status", "--porcelain"], in: project).isEmpty else {
            throw ReplayFailure(description: "fixture base is not clean and pinned")
        }
        let world = try ReplayWorld(project: project, root: root)
        defer { world.tearDown() }
        let facts = ReplayRunFacts()
        let sandbox = ReplaySandbox(root: root, hostRepository: task.source.appendingPathComponent(".git"))
        try sandbox.selfTest()

        let suite = "array.qa.replay.\(UUID().uuidString)"
        guard let policy = QAIsolatedDefaults(isolatedSuiteName: suite) else {
            throw ReplayFailure(description: "isolated defaults unavailable")
        }
        defer { policy.removePersistentDomain(forName: suite) }
        policy.set(condition.managed, forKey: AgentManagedModeConfig.enabledKey)
        AgentModelCatalog.shared.resetForQA(snapshot: AgentCatalogQAFixture.claude)
        AgentModelCatalog.shared.resetForQA(snapshot: AgentCatalogQAFixture.codex)
        guard let model = AgentModelCatalog.shared.snapshot(for: condition.harness).seedModel else {
            throw ReplayFailure(description: "fixture catalog missing")
        }

        let supervisor = AgentSupervisor(store: AgentStore(applicationSupportDirectory: root.appendingPathComponent("support")),
                                         makeRunner: { launch in
            let isLead = launch.record.parentAgentID == nil
            if isLead { facts.leadLaunch(hasTools: launch.workspaceMCP != nil) }
            let agent = ReplayFakeAgent(launch: launch, isLead: isLead, condition: condition, facts: facts, sandbox: sandbox)
            // Solo closes the runner's own spawn channel: an attempt is a fact.
            return ReplaySpawnGate(inner: agent, forbid: !condition.managed && isLead, facts: facts)
        }, warn: { fputs("replay supervisor: " + $0 + "\n", stderr) },
        // Never a provider process, and nothing read from the real home: no
        // titler CLI, no claude session titles, no codex rollout context.
        nameTitlerCommand: { _ in nil },
        claudeSessionTitle: { _, _ in nil },
        submissionRecoveryStore: AgentComposerDraftStore(applicationSupportDirectory: root.appendingPathComponent("support")),
        codexRestoredContextSnapshot: { _ in nil },
        transcriptStore: AgentTranscriptStore(root: root.appendingPathComponent("support/transcripts")),
        // No cap of any kind on the run.
        maximumActiveManagedChildren: { nil })
        try world.mount(supervisor: supervisor)
        supervisor.workspaceToolsPermission = { .free }
        supervisor.configureManagedMode(defaults: policy)
        var approvalsAsked = 0
        world.delegate.qaWorkspaceAPI.approvalHandler = { _ in approvalsAsked += 1; return .allowForSession }
        defer { supervisor.stopAll() }

        var outcomes = ReplayTurnOutcomes()
        let observation = supervisor.addDeliveredEventObserver { agent, event in
            outcomes.observe(agent, event)
        }
        defer { supervisor.removeDeliveredEventObserver(observation) }

        let lead = supervisor.spawn(role: nil, prompt: nil, cwd: project, harness: condition.harness, model: model,
                                    thinking: "low", projectId: world.projectId, projectRoot: project)
        // Solo: no delegation tool on the record, so no MCP server reaches the CLI.
        _ = supervisor.setWorkspaceToolsEnabled(agentID: lead, condition.managed)
        guard supervisor.records[lead]?.workspaceToolsEnabled == condition.managed else {
            throw ReplayFailure(description: "lead workspace tools did not follow the condition")
        }
        guard supervisor.effectiveMode(for: lead) == (condition.managed ? .managed : .free) else {
            throw ReplayFailure(description: "lead is not in the requested mode")
        }
        if !condition.managed {
            let reply = world.delegate.qaWorkspaceAPI.dispatch(
                agentId: lead, requestId: "replay-solo-probe", op: "agent.delegate",
                payload: ["task": "probe", "idempotencyKey": "replay-solo-probe"])
            guard case let .error(error) = reply, error.code == .permissionDenied else {
                throw ReplayFailure(description: "solo lead's workspace API delegation was not refused")
            }
        }

        let started = ProcessInfo.processInfo.systemUptime
        // The composer's human submission: the path that opens the run ledger's task.
        guard await supervisor.accept(.sendPrompt(AgentPrompt(task.request)), for: lead) == .accepted else {
            throw ReplayFailure(description: "production submission refused")
        }
        record["outcome"] = "timeout"
        var settledSince: Double?
        let deadline = started + 30
        while ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
            let ids = Array(supervisor.records.keys)
            let busy = ids.contains { supervisor.isRunning($0) } || supervisor.qaHasPendingHelperResults(for: lead)
            if busy || (facts.intervals.isEmpty) { settledSince = nil; continue }
            await supervisor.flushHelperCompletions()
            let now = ProcessInfo.processInfo.systemUptime
            if let since = settledSince, now - since > 0.3 { record["outcome"] = "completed"; break }
            if settledSince == nil { settledSince = now }
        }
        supervisor.stopAll()
        lastRunTurns = facts.turns

        // Checkouts from the PRODUCTION records, never from the fake.
        let helpers = supervisor.records.values.filter { $0.parentAgentID == lead }
            .sorted { $0.createdAt < $1.createdAt }
        record["helpers"] = helpers.map { helper -> [String: Any] in
            let checkout = helper.checkoutRoot.hasPrefix(root.path + "/")
                ? String(helper.checkoutRoot.dropFirst(root.path.count + 1)) : helper.checkoutRoot
            return ["agent": helper.id.rawValue.uuidString.lowercased(), "checkout": checkout,
                    "isolated": helper.worktreeBranch != nil]
        }
        record["delegationAttempts"] = facts.intercepted
        // Task, mode, helper count, tokens by type, completeness and times from
        // the run's own ledger, in this run's Application Support only.
        supervisor.runLedger.drain()
        let ledger = RunLedgerUsageReader.ledgerURL(applicationSupport: root.appendingPathComponent("support"))
        let disagreements = ReplayLedgerRecord.fill(&record, ledger: ledger, lead: lead, managed: condition.managed,
                                                    productionHelpers: helpers.count)
        if !condition.managed, !helpers.isEmpty || facts.leadLaunchesWithTools.contains(true) {
            record["failure"] = "solo lead had a delegation route"
        }
        if !facts.leaks.isEmpty {
            record["outcome"] = "containmentFailed"
            record["failure"] = facts.leaks.joined(separator: "; ")
        }
        let failed = supervisor.records.keys.contains { (outcomes.failedTurns[$0] ?? 0) > 0 }
        if failed, record["outcome"] as? String == "completed" {
            record["outcome"] = "failed"
            record["failure"] = "an agent's turn failed"
        }
        if approvalsAsked > 0 { record["humanSteps"] = approvalsAsked }

        // Grade the lead's working copy on a pristine export, after termination.
        let data = try Self.command("/usr/bin/python3", ["-I", replayScript.path, "grade", task.json.path, project.path],
                                    in: replayRepoRoot, environment: ["PATH": "/usr/bin:/bin", "PYTHONDONTWRITEBYTECODE": "1"])
        guard let grade = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ReplayFailure(description: "grading produced no result")
        }
        for key in ["checks", "gradeResult", "hiddenPassed", "neighbourPassed", "tampered", "changedPaths", "diffHash"] {
            record[key] = grade[key] ?? NSNull()
        }
        record["passed"] = record["outcome"] as? String == "completed" && grade["gradeResult"] as? String == "passed"
        if !disagreements.isEmpty { throw ReplayFailure(description: disagreements.joined(separator: "; ")) }
    }
}

/// Closes the runner's own spawn channel for a lead whose condition forbids
/// delegation; every request that arrives there is counted, never forwarded.
private final class ReplaySpawnGate: AgentRunning, @unchecked Sendable {
    let inner: AgentRunning
    let forbid: Bool
    let facts: ReplayRunFacts
    init(inner: AgentRunning, forbid: Bool, facts: ReplayRunFacts) {
        self.inner = inner; self.forbid = forbid; self.facts = facts
    }
    func run(prompt: AgentPrompt, onEvent: @escaping @Sendable (AgentRuntimeEvent) -> Void) throws {
        try inner.run(prompt: prompt, onEvent: onEvent)
    }
    func stop() { inner.stop() }
    func observeSpawnRequests(_ handler: @escaping @Sendable (SpawnRequest) -> Void) {
        let forbid = self.forbid, facts = self.facts
        inner.observeSpawnRequests { request in
            if forbid { facts.intercept(); return }
            handler(request)
        }
    }
    func observeRuntimeObservations(_ handler: @escaping @Sendable (AgentRuntimeObservation) -> Void) {
        inner.observeRuntimeObservations(handler)
    }
}

/// Deny-default containment for fake agent processes; the same rules as
/// `replay.py sandbox_profile`, over the shell toolchain the fakes use.
struct ReplaySandbox: Sendable {
    let root: URL
    let hostRepository: URL
    static let toolchain = ["/bin", "/usr/bin", "/usr/lib", "/System/Library", "/System/Cryptexes",
                            "/System/Volumes/Preboot/Cryptexes", "/private/var/db/dyld", "/dev"]

    var profile: String {
        func q(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let readable = Self.toolchain + [root.path]
        var ancestors = Set<String>()
        for path in readable {
            var url = URL(fileURLWithPath: path)
            while url.path != "/" { url = url.deletingLastPathComponent(); ancestors.insert(url.path) }
        }
        ancestors.subtract(readable)
        return "(version 1)(deny default)(allow process-fork)(allow sysctl-read)(allow signal (target same-sandbox))"
            + "(allow process-exec " + Self.toolchain.map { "(subpath \(q($0)))" }.joined(separator: " ") + ")"
            + "(allow file-read* (literal \"/\") (literal \"/private/var/select/sh\") "
            + readable.map { "(subpath \(q($0)))" }.joined(separator: " ") + ")"
            + "(allow file-read-metadata " + ancestors.sorted().map { "(literal \(q($0)))" }.joined(separator: " ") + ")"
            + "(allow file-write* (literal \"/dev/null\") (subpath \(q(root.path))))"
    }

    var environment: [String: String] {
        ["PATH": "/usr/bin:/bin", "HOME": root.appendingPathComponent("home").path,
         "TMPDIR": root.appendingPathComponent("tmp").path, "TMUX_TMPDIR": root.appendingPathComponent("tmux").path,
         "CONTINUUM_APP_SUPPORT": root.appendingPathComponent("support").path]
    }

    /// Runs one fake agent step. Every probe must be refused by the kernel; a
    /// probe that succeeds prints LEAK and the run is a containment failure.
    func run(_ script: String, in cwd: URL) throws -> String {
        let support = (ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()) + "/Library/Application Support"
        let probes = """
        /bin/cat "$1/HEAD" >/dev/null 2>&1 && echo "LEAK: read the host repository"
        /bin/ls "$2" >/dev/null 2>&1 && echo "LEAK: read Application Support"
        /usr/bin/touch "$3" 2>/dev/null && echo "LEAK: wrote outside the run"
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        p.arguments = ["-p", profile, "/bin/sh", "-c", probes + "\n" + script, "replay-agent",
                       hostRepository.path, support, root.deletingLastPathComponent().appendingPathComponent("\(root.lastPathComponent)-outside").path]
        p.currentDirectoryURL = cwd
        p.environment = environment
        let out = Pipe()
        p.standardOutput = out; p.standardError = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    func selfTest() throws {
        let output = try run("printf ok > sandbox-self-test && /bin/rm sandbox-self-test && echo WROTE",
                             in: root.appendingPathComponent("tmp"))
        guard output.contains("WROTE"), !output.contains("LEAK") else {
            throw ReplayFailure(description: "sandbox self-test failed: \(output)")
        }
    }
}

/// A fake agent process at the runner boundary. Its edits run in the kernel
/// sandbox; its usage is the recorded stream through the production translator;
/// its delegation is a `tools/call array_delegate` through the production MCP
/// server named in its own launch configuration.
private final class ReplayFakeAgent: AgentRunning, @unchecked Sendable {
    let launch: AgentRunnerLaunch
    let isLead: Bool
    let condition: ReplayCondition
    let facts: ReplayRunFacts
    let sandbox: ReplaySandbox
    private let lock = NSLock()
    private var spawnHandler: (@Sendable (SpawnRequest) -> Void)?

    init(launch: AgentRunnerLaunch, isLead: Bool, condition: ReplayCondition, facts: ReplayRunFacts, sandbox: ReplaySandbox) {
        self.launch = launch; self.isLead = isLead; self.condition = condition; self.facts = facts; self.sandbox = sandbox
    }

    static let fix = "printf 'def value():\\n    return \"fixed\"\\n' > calc.py"

    func run(prompt: AgentPrompt, onEvent: @escaping @Sendable (AgentRuntimeEvent) -> Void) throws {
        let began = ProcessInfo.processInfo.systemUptime
        defer { facts.interval(began, ProcessInfo.processInfo.systemUptime) }
        let id = launch.record.id
        let turn = facts.nextTurn(id)
        let cwd = URL(fileURLWithPath: launch.record.cwd, isDirectory: true)
        var script = ":"
        if isLead && turn == 1 {
            switch condition.lead {
            case .repairs, .triesToDelegate: script = Self.fix
            case .delegatesTwoParts: script = ":"
            case .crashes: throw ReplayFailure(description: "fake lead process exited 1")
            }
        } else if !isLead && turn == 1 {
            script = prompt.text.contains("Part A") ? "/bin/sleep 0.4; " + Self.fix : "/bin/sleep 0.4; printf 'part b\\n' > notes.txt"
        }
        let output = try sandbox.run(script, in: cwd)
        for line in output.split(separator: "\n") where line.hasPrefix("LEAK") { facts.leak(String(line)) }

        if isLead && turn == 1 && condition.lead == .delegatesTwoParts {
            guard let mcp = launch.workspaceMCP else { throw ReplayFailure(description: "lead has no delegation tool") }
            for part in ["Part A: repair value() in calc.py.", "Part B: write a short note in notes.txt."] {
                let reply = try ReplayMCPClient.call(mcp, tool: "array_delegate",
                    arguments: ["task": part, "title": String(part.prefix(6)), "idempotencyKey": "replay-\(id.rawValue.uuidString)-\(part.prefix(6))"])
                facts.delegateReply(reply)
            }
        }
        if isLead && turn == 1 && condition.lead == .triesToDelegate {
            let handler = lock.withLock { spawnHandler }
            handler?(SpawnRequest(role: nil, prompt: "Part A: repair value() in calc.py.", isolated: false,
                                  sourceItemID: "replay-solo-attempt"))
        }

        let session = id.rawValue.uuidString.lowercased()
        var events: [AgentRuntimeEvent]
        switch condition.harness {
        case .codex:
            let final = try ReplayStreams.recordedCodexFinalTotal()
            // Each turn is a new app-server process: a later turn resumes the
            // agent's thread, as the production runner does. A resumed-from-
            // before lead starts with a whole recorded thread of history.
            let resumedFromBefore = isLead && turn == 1 && condition.codexResumed
            var carried = resumedFromBefore ? final : facts.carried(id)
            if condition.codexResets && turn > 1 { carried = [:] }
            events = try ReplayStreams.codexTurn(thread: session, turn: UUID().uuidString.lowercased(), carried: carried,
                                                 resumed: turn > 1 || resumedFromBefore,
                                                 providerTime: facts.providerTimes(try ReplayStreams.lines(ReplayStreams.codexFixture).count))
            facts.carry(id, final.merging(carried, uniquingKeysWith: +))
        default:
            events = try ReplayStreams.claudeTurn(session: session)
        }
        for event in events {
            onEvent(event)
            // A re-delivered usage report must not be counted twice.
            if case .tokenUsageUpdated = event { onEvent(event) }
        }
    }

    func stop() {}
    func observeSpawnRequests(_ handler: @escaping @Sendable (SpawnRequest) -> Void) {
        lock.withLock { spawnHandler = handler }
    }
    func observeRuntimeObservations(_ handler: @escaping @Sendable (AgentRuntimeObservation) -> Void) {}
}

/// A synchronous MCP client over the production `array-workspace-mcp` server,
/// started exactly as a provider CLI starts it: its command and env.
enum ReplayMCPClient {
    static func call(_ config: WorkspaceMCPConfiguration, tool: String, arguments: [String: Any]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: config.serverExecutable)
        p.environment = ["PATH": "/usr/bin:/bin"].merging(config.environment) { _, new in new }
        let input = Pipe(), output = Pipe()
        p.standardInput = input; p.standardOutput = output; p.standardError = FileHandle.nullDevice
        try p.run()
        defer { if p.isRunning { p.terminate() }; p.waitUntilExit() }
        let request: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                      "params": ["name": tool, "arguments": arguments]]
        var line = try JSONSerialization.data(withJSONObject: request)
        line.append(0x0A)
        try input.fileHandleForWriting.write(contentsOf: line)
        var buffer = Data()
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let body = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any], object["id"] as? Int == 1 {
                    try? input.fileHandleForWriting.close()
                    return String(decoding: body, as: UTF8.self)
                }
            }
        }
        throw ReplayFailure(description: "workspace MCP server gave no reply to \(tool)")
    }
}

/// One project mounted through the production boot mount, so the workspace
/// API has the scene it serves in the app.
@MainActor
final class ReplayWorld {
    let delegate = AppDelegate()
    let projectId = UUID()
    private let project: URL
    private let root: URL
    private let browserEngine = BrowserEngineContext()

    init(project: URL, root: URL) throws {
        self.project = project
        self.root = root
    }

    func mount(supervisor: AgentSupervisor) throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let support = root.appendingPathComponent("support/app", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let workspaceId = UUID(), zoneId = UUID()
        let projectObject = Project(id: projectId, name: "replay", rootPath: project.path, createdAt: now, updatedAt: now,
            defaultLaunchProfileId: "shell", editorPreference: .auto,
            settings: ProjectSettings(restorePolicy: .restoreDescriptors, browserStoragePolicy: .perProject,
                                      terminalClosePolicy: .askWhenRunning))
        let store = ProjectStore(projectRoot: project)
        try store.saveProject(projectObject)
        let canvasState = CanvasState(viewport: CanvasViewport(x: 0, y: 0, zoom: 1), tiles: [], groups: [], lastActiveTileId: nil)
        try store.saveCanvas(canvasState)
        let zone = ZonePlacement(zoneId: zoneId, projectId: projectId, origin: ZonePoint(x: 0, y: 0),
                                 size: ZoneSize(width: 1600, height: 1000), color: "blue", collapsed: false,
                                 hydrationPolicy: .pinnedLive)
        let document = WorkspaceDocument(viewport: CanvasViewport(x: 0, y: 0, zoom: 1), zones: [zone],
                                         zoneZOrder: [zoneId], lastActiveZoneId: zoneId)
        try WorkspaceStore(workspaceId: workspaceId, applicationSupportDirectory: support).save(document)
        var registry = Registry.empty()
        registry.lastActiveWorkspaceId = workspaceId
        registry.workspaces = [WorkspaceEntry(id: workspaceId, name: "replay", projectIds: [projectId], createdAt: now, updatedAt: now)]
        registry.projects = [ProjectEntry(id: projectId, name: "replay", rootPath: project.path, workspaceId: workspaceId,
                                          lastOpenedAt: now, pinned: false, missing: false)]
        let registryStore = RegistryStore(applicationSupportDirectory: support)
        try registryStore.save(registry)
        let projectRoot = project
        let zones = ZoneRuntimeRegistry(closeOnZero: true, makeController: { _ in
            ZoneRuntimeController(projectRoot: projectRoot, projectStore: store, project: projectObject)
        })
        let canvas = CanvasNSView(canvasState: canvasState, activeZone: zone,
            zoneRenderModels: [CanvasNSView.ZoneRenderModel(placement: zone, displayName: "replay")])
        canvas.frame = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        delegate.agentSupervisor = supervisor
        let runtime = WorkspaceRuntime(boot: try zones.acquire(projectId: projectId), workspaceId: workspaceId,
            document: document, registry: zones, focusBroker: delegate.qaFocusBroker, registryStore: registryStore,
            ghostty: nil, browserEngine: browserEngine)
        delegate.qaPrepareForBootMountCheck(canvas: canvas, browserEngine: browserEngine, runtime: runtime, registryStore: registryStore)
        let spawner = TileSpawner(canvasView: canvas, ghostty: nil, browserEngine: browserEngine, projectStore: store, project: projectObject)
        try delegate.mountWorkspaceSceneAtBoot(canvasView: canvas, spawner: spawner, projectStore: store,
                                               canvasState: canvasState, installsGlobalEventMonitors: false)
    }

    func tearDown() { browserEngine.shutdown() }
}

// MARK: - The witness

@MainActor
func runReplayDriverChecks() async throws {
    func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw ReplayFailure(description: message) }
    }
    guard ProcessInfo.processInfo.environment["CONTINUUM_APP_SUPPORT"] != nil else {
        throw ReplayFailure(description: "refusing to run without CONTINUUM_APP_SUPPORT")
    }
    guard Bundle.main.bundleIdentifier != AppChannel.prodBundleIdentifier else {
        throw ReplayFailure(description: "refusing to run from the PROD bundle")
    }
    guard AppDelegate.workspaceMCPExecutablePath() != nil else {
        throw ReplayFailure(description: "array-workspace-mcp is not built; build that product first")
    }
    let fm = FileManager.default
    let host = URL(fileURLWithPath: try ReplaySupervisorDriver.realPath(fm.temporaryDirectory.path))
        .appendingPathComponent("replay-driver-\(UUID().uuidString)")
    try fm.createDirectory(at: host, withIntermediateDirectories: true)
    // The records outlive every run directory; kept on failure for reading.
    let sink = host.appendingPathComponent("records.jsonl")
    var green = false
    defer { if green { try? fm.removeItem(at: host) } else { fputs("replay records kept at \(sink.path)\n", stderr) } }
    let taskJSON = String(decoding: try ReplaySupervisorDriver.command("/usr/bin/python3",
        ["-I", replayScript.path, "make-fixture", host.path], in: replayRepoRoot,
        environment: ["PATH": "/usr/bin:/bin", "PYTHONDONTWRITEBYTECODE": "1"]), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let task = try ReplayTask.load(URL(fileURLWithPath: taskJSON))
    let driver = ReplaySupervisorDriver(task: task, sink: sink)
    var primary: [String: [[String: Any]]] = [:]
    var resumedSolo: [String: Any] = [:]

    func string(_ r: [String: Any], _ k: String) -> String? { r[k] as? String }
    func int(_ r: [String: Any], _ k: String) -> Int? { r[k] as? Int }
    func problems(_ r: [String: Any]) -> [String] { r["usageProblems"] as? [String] ?? [] }
    func tokens(_ r: [String: Any]) -> [String: Any] { r["tokens"] as? [String: Any] ?? [:] }
    // Hand-computed in RequestTelemetryChecks from the same captures: one Claude
    // opus turn is 2 / 10,695 / 11,239 / 124; the whole recorded Codex thread,
    // started here, is 7,652 / 57,344 / not reported / 313.
    func perTurn(_ harness: AgentHarness) -> [String: Int?] {
        harness == .codex ? ["uncachedInput": 7_652, "cacheRead": 57_344, "cacheWrite": nil, "output": 313]
            : ["uncachedInput": 2, "cacheRead": 10_695, "cacheWrite": 11_239, "output": 124]
    }
    /// The record's typed totals equal `turns` whole recorded turns; a kind the
    /// harness never reports is null and listed, never zero.
    func expectTotals(_ r: [String: Any], _ harness: AgentHarness, turns: Int, _ label: String) throws {
        let figures = tokens(r)
        for (kind, each) in perTurn(harness) {
            if let each {
                try expect(figures[kind] as? Int == each * turns,
                           "\(label) tokens are not \(turns) recorded turn(s): \(kind) \(figures[kind] ?? "missing"), expected \(each * turns)")
            } else {
                try expect(figures[kind] is NSNull && (r["tokensNotReported"] as? [String])?.contains(kind) == true,
                           "\(label) \(kind) is not recorded as not reported: \(figures[kind] ?? "missing") \(r["tokensNotReported"] ?? "")")
            }
        }
    }
    func expectLedgerTask(_ r: [String: Any], _ label: String) throws {
        try expect(string(r, "ledgerTask").flatMap(UUID.init(uuidString:)) != nil, "\(label) has no ledger task: \(r["ledgerTask"] ?? "")")
    }

    for harness in [AgentHarness.claudeCode, .codex] {
        let name = harness == .codex ? "codex" : "claude"

        let solo = await driver.run(ReplayCondition(harness: harness, managed: false, lead: .repairs))
        try expect(string(solo, "outcome") == "completed" && solo["passed"] as? Bool == true,
                   "\(name) solo did not complete and pass: \(solo)")
        try expect(int(solo, "helperCount") == 0 && int(solo, "delegationAttempts") == 0 && solo["fannedOut"] is NSNull,
                   "\(name) solo recorded helpers: \(solo)")
        try expectLedgerTask(solo, "\(name) solo")
        try expect(solo["usageComplete"] as? Bool == true && problems(solo).isEmpty,
                   "\(name) solo usage was not complete: \(problems(solo))")
        // One turn, its usage report delivered twice: counted once.
        try expect(driver.lastRunTurns == 1, "\(name) solo ran \(driver.lastRunTurns) turns, not one")
        try expectTotals(solo, harness, turns: 1, "\(name) solo")
        try expect((solo["wallSeconds"] as? Double ?? -1) >= (solo["activeSeconds"] as? Double ?? .infinity)
                   && (solo["activeSeconds"] as? Double ?? 0) > 0, "\(name) solo timing missing: \(solo)")

        let managed = await driver.run(ReplayCondition(harness: harness, managed: true, lead: .delegatesTwoParts))
        let managedTurns = driver.lastRunTurns
        try expect(string(managed, "outcome") == "completed" && managed["passed"] as? Bool == true,
                   "\(name) managed did not complete and pass: \(managed)")
        try expect(managed["fannedOut"] as? Bool == true && int(managed, "helperCount") == 2,
                   "\(name) managed lead's two delegations did not produce two helpers: \(managed)")
        let checkouts = (managed["helpers"] as? [[String: Any]] ?? []).map { ($0["checkout"] as? String ?? "", $0["isolated"] as? Bool ?? false) }
        try expect(checkouts.count == 2 && checkouts[0] == ("project", false)
                   && checkouts[1].0.hasPrefix("project/.worktrees/") && checkouts[1].1,
                   "\(name) concurrent helpers did not get separate checkouts: \(checkouts)")
        try expect(managed["changedPaths"] as? [String] == ["calc.py"],
                   "\(name) grading carried a helper worktree or host state: \(managed["changedPaths"] ?? "")")
        try expectLedgerTask(managed, "\(name) managed")
        try expect(managed["usageComplete"] as? Bool == true && problems(managed).isEmpty,
                   "\(name) managed usage was not complete: \(problems(managed))")
        // Lead's delegating turn, each helper's turn and the lead's wakes, each
        // one whole recorded turn: the lead's and its helpers' rows together.
        // The wake that reads the helpers' results is the task's (`.plans/116`
        // gap 8): every run turn is in it, none after its close.
        try expect(managedTurns >= 3, "\(name) managed ran \(managedTurns) turns")
        let usageRows = managed["usageRows"] as? [[String: Any]] ?? []
        let inTask = Set(usageRows.map { "\($0["agent"] ?? "")|\($0["turn"] ?? "")" }).count
        let leadAfterClose = int(managed, "leadTurnsAfterClose") ?? -1
        try expect(inTask == managedTurns && leadAfterClose == 0,
                   "\(name) managed: \(managedTurns) run turns, \(inTask) in the task, \(leadAfterClose) lead turns after the close")
        print("replay-driver: \(name) managed ran \(managedTurns) turns, \(inTask) in the task, \(leadAfterClose) lead wake after the close")
        try expectTotals(managed, harness, turns: inTask, "\(name) managed")
        let roles = Set((managed["usageRows"] as? [[String: Any]] ?? []).compactMap { $0["role"] as? String })
        try expect(roles == ["lead", "helper"], "\(name) managed usage rows do not name the lead and helpers: \(roles)")

        primary[name] = [solo, managed]
        let lone = await driver.run(ReplayCondition(harness: harness, managed: true, lead: .repairs))
        try expect(lone["fannedOut"] as? Bool == false && int(lone, "helperCount") == 0 && string(lone, "outcome") == "completed",
                   "\(name) a managed lead that delegated nothing was not recorded as not fanning out: \(lone)")

        let attempt = await driver.run(ReplayCondition(harness: harness, managed: false, lead: .triesToDelegate))
        // The production records, not the ledger: a helper started through the
        // runner's own spawn channel has no delegated row.
        let attemptHelpers = (attempt["helpers"] as? [Any])?.count ?? -1
        try expect(attemptHelpers == 0 && int(attempt, "helperCount") == 0,
                   "solo run delegated: the production record has \(attemptHelpers) helper(s)")
        try expect(int(attempt, "delegationAttempts") == 1, "solo delegation attempt not recorded: \(attempt)")
    }

    // A lead whose Codex thread began in an earlier process: the ledger has no
    // baseline, so the turn's figures are partial and the record incomplete.
    resumedSolo = await driver.run(ReplayCondition(harness: .codex, managed: false, lead: .repairs, codexResumed: true))
    try expect(string(resumedSolo, "outcome") == "completed", "a resumed Codex run did not complete: \(resumedSolo)")
    try expect(resumedSolo["usageComplete"] as? Bool == false,
               "a Codex resume without a baseline was recorded complete: \(problems(resumedSolo))")
    try expect(problems(resumedSolo).contains("noBaseline"),
               "a Codex resume's record does not carry the ledger's noBaseline flag: \(problems(resumedSolo))")
    try expect(["uncachedInput", "cacheRead", "output"].allSatisfy { tokens(resumedSolo)[$0] is NSNull },
               "a Codex resume without a baseline produced a total: \(tokens(resumedSolo))")

    // A reset needs a second turn on one thread: the managed lead's wake after
    // its helpers report. The recorded totals restart instead of continuing.
    let reset = await driver.run(ReplayCondition(harness: .codex, managed: true, lead: .delegatesTwoParts, codexResets: true))
    // That wake is the task's (`.plans/116` gap 8), so the reset marks the task.
    try expect(problems(reset).contains("reset") && int(reset, "leadTurnsAfterClose") == 0,
               "a Codex reset was not marked: \(problems(reset)), after the close \(reset["afterCloseProblems"] ?? "")")
    try expect(["uncachedInput", "cacheRead", "output"].allSatisfy { tokens(reset)[$0] is NSNull } && reset["usageComplete"] as? Bool == false,
               "a Codex reset produced a total: \(tokens(reset))")

    let crash = await driver.run(ReplayCondition(harness: .claudeCode, managed: false, lead: .crashes))
    try expect(string(crash, "outcome") == "failed" && crash["passed"] as? Bool == false,
               "a crashed lead was not recorded as failed: \(crash)")
    let stranger = host.appendingPathComponent("stranger")
    try fm.createDirectory(at: stranger, withIntermediateDirectories: false)
    driver.injectedRoot = stranger
    let refused = await driver.run(ReplayCondition(harness: .codex, managed: false, lead: .repairs))
    driver.injectedRoot = nil
    try expect(string(refused, "failure")?.contains("refusing unowned replay storage") == true,
               "unowned storage accepted: \(refused)")

    let saved = try String(contentsOf: sink, encoding: .utf8).split(separator: "\n")
        .compactMap { try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    try expect(saved.contains { $0["run"] as? String == crash["run"] as? String && $0["outcome"] as? String == "failed" },
               "a failed run's record vanished")
    try expect(saved.contains { $0["run"] as? String == refused["run"] as? String },
               "a failed run's record vanished")
    try expect(fm.fileExists(atPath: stranger.path), "a refused root was cleaned")
    func compare(_ file: URL) throws -> String {
        String(decoding: try ReplaySupervisorDriver.command("/usr/bin/python3",
            ["-I", replayScript.path, "compare", file.path], in: replayRepoRoot,
            environment: ["PATH": "/usr/bin:/bin", "PYTHONDONTWRITEBYTECODE": "1"]), as: UTF8.self)
    }
    // Every Swift record parses in the comparison; repeated conditions are unmatched.
    let all = try compare(sink)
    try expect(all.contains("pairs compared 0 of 2 expected") && all.contains("unmatched"),
               "the comparison did not read every Swift record: \(all)")
    // Matched complete pairs: one difference line per harness, by type, the
    // Codex cache write named as not reported.
    let pairs = host.appendingPathComponent("pairs.jsonl")
    for r in (primary["claude"] ?? []) + (primary["codex"] ?? []) { try ReplayRecordSchema.write(r, to: pairs) }
    let compared = try compare(pairs)
    let lines = compared.split(separator: "\n").map(String.init)
    for name in ["claude", "codex"] {
        let pair = primary[name] ?? []
        let difference = pair.count == 2 ? (tokens(pair[1])["uncachedInput"] as? Int ?? 0) - (tokens(pair[0])["uncachedInput"] as? Int ?? 0) : 0
        let line = lines.first { $0.hasPrefix(name + " ") } ?? ""
        try expect(compared.contains("pairs compared 2 of 2 expected") && line.contains(String(format: "uncachedInput %+d", difference)),
                   "the comparison printed no difference for a complete \(name) pair: \(compared)")
    }
    try expect(lines.first { $0.hasPrefix("codex ") }?.contains("cacheWrite not reported") == true,
               "the comparison did not name Codex cache writes as not reported: \(compared)")
    print(compared)
    // An incomplete record refuses its pair: no difference is printed for it.
    let mixed = host.appendingPathComponent("mixed.jsonl")
    for r in (primary["claude"] ?? []) + [resumedSolo] + Array((primary["codex"] ?? []).suffix(1)) { try ReplayRecordSchema.write(r, to: mixed) }
    let refusedPair = try compare(mixed)
    try expect(refusedPair.contains("pairs compared 1 of 2 expected") && refusedPair.contains("excluded 1: usage incomplete")
               && !refusedPair.split(separator: "\n").contains { $0.hasPrefix("codex ") },
               "the comparison printed a difference for an incomplete pair: \(refusedPair)")
    for r in saved {
        print("replay driver: \(r["harness"] ?? "") \(r["mode"] ?? "") outcome=\(r["outcome"] ?? "") passed=\(r["passed"] ?? "") helpers=\(r["helperCount"] ?? "") fannedOut=\(r["fannedOut"] ?? "") attempts=\(r["delegationAttempts"] ?? "") complete=\(r["usageComplete"] ?? "") tokens=\(r["tokens"] ?? "")")
    }
    green = true
}
