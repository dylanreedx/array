import Foundation
import ContinuumRevivedCore

/// Host-only facts. All reduction, recovery and disk access share this queue.
/// No prompt, report prose, command text, file contents or diffs cross this
/// boundary; the only paths are checkout-relative paths a helper edited.
final class ManagedRunLedger: @unchecked Sendable {
    struct Row: Codable {
        var v = 1
        var at = Date()
        var kind: String
        var task: UUID
        var agent: UUID
        var part: UUID?
        var source: String
        var previousTask: UUID?
        var project: UUID?
        var origin = "host"
        var outcome: String?
        var checks: [String: Int]?
        var findings: [String: Int]?
        var openParts: [UUID]?
        var evidence: [String: String]?
        var files: [HelperEvidence.FileFact]?
        var harness: String?
        var model: String?
        var effort: String?
        var tokens: TokenUsageSnapshot.TypedCounts?
        var incomplete: [String]?
    }
    // Live only: a helper delegated before this process started has no entry,
    // and its report records that instead of pretending to have watched it.
    private var evidence: [UUID: HelperEvidence] = [:]
    /// A helper's tool call, as its translator reported it. Folded on the queue.
    func observeTool(agent: UUID, _ observation: AgentRuntimeObservation) {
        queue.async { self.evidence[agent]?.observe(observation) }
    }
    /// One hand-off on the report path; the manifest read and the fold run here.
    func helperEvidence(agent: UUID, at: Date, root: String, exitProven: Bool) {
        queue.async {
            guard let task = self.delegatedTask[agent] else { return }
            var row = Row(kind: "helperEvidence", task: task, agent: agent, part: self.parts[agent],
                          source: "evidence/\(agent)/\(at.timeIntervalSinceReferenceDate)")
            if let watched = self.evidence[agent] {
                (row.files, row.evidence) = watched.facts(root: URL(fileURLWithPath: root), exitProven: exitProven)
            } else {
                row.evidence = ["observed": "notSinceDelegation"]
            }
            self.append(row)
        }
    }
    private let queue = DispatchQueue(label: "dev.array.run-ledger", qos: .utility)
    private let url: URL
    private var seen = Set<String>()
    private var active: [UUID: UUID] = [:]
    private var previous: [UUID: UUID] = [:]
    private var owners: [UUID: UUID] = [:]
    private var parts: [UUID: UUID] = [:]
    private var open = Set<UUID>()
    // Indexes over the facts so far, so each new fact costs the same however
    // long the ledger is. Rebuilt once at load by the same `reduce`.
    private var delegatedTask: [UUID: UUID] = [:]
    private var partTasks: [UUID: Set<UUID>] = [:]
    private var openByTask: [UUID: Set<UUID>] = [:]
    private var delegationOrder: [UUID: [UUID]] = [:]
    private var leadBoundary: [UUID: Row] = [:]
    private var needsSeparator = false
    // Replayed transcript events during restore are history, not new run facts.
    // Keep live attribution after closure for wakes, but never rebuild it from disk.
    private var sessionTasks: [UUID: UUID] = [:]
    init(support: URL) {
        url = support.appendingPathComponent("run-ledger/ledger.jsonl")
        queue.async { self.recover() }
    }
    /// Waits for every fact handed off so far to reach disk. Checks only.
    func drain() { queue.sync {} }
    /// The sole append path, including replay and restart facts. Callers supply
    /// stable source identities; duplicates never reach disk or the reducer.
    private func append(_ row: Row) {
        guard seen.insert(row.source).inserted else { return }
        reduce(row)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var data = Data()
            if needsSeparator { data.append(10) }
            data.append(try JSONEncoder().encode(row)); data.append(10)
            if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
            let file = try FileHandle(forWritingTo: url)
            defer { try? file.close() }
            try file.seekToEnd(); try file.write(contentsOf: data)
            needsSeparator = false
        } catch { NSLog("Run ledger write failed: %@", String(describing: error)) }
    }
    /// The one reducer, for live appends and for the load-time rebuild.
    private func reduce(_ row: Row) {
        switch row.kind {
        case "taskOpened": active[row.agent] = row.task; previous[row.agent] = row.task; owners[row.task] = row.agent
        case "delegated":
            parts[row.agent] = row.part; delegatedTask[row.agent] = row.task
            if let part = row.part {
                open.insert(part)
                if partTasks[part, default: []].insert(row.task).inserted { delegationOrder[row.task, default: []].append(part) }
                for task in partTasks[part]! { openByTask[task, default: []].insert(part) }
            }
        case "turnEnded", "reported":
            if let part = row.part {
                open.remove(part)
                for task in partTasks[part] ?? [] { openByTask[task]?.remove(part) }
            }
        case "taskClosed", "taskInterrupted": active[row.agent] = nil
        default: break
        }
        if (row.kind == "working" || row.kind == "turnEnded"), owners[row.task] == row.agent { leadBoundary[row.task] = row }
    }
    private func recover() {
        if let data = try? Data(contentsOf: url) {
            // Preserve all prior bytes, including a torn final append. The sole
            // append path inserts a separator before its next fact.
            let complete = data.lastIndex(of: 10).map { Data(data[...$0]) } ?? Data()
            needsSeparator = complete.count != data.count
            for line in complete.split(separator: 10) {
                guard let row = try? JSONDecoder().decode(Row.self, from: Data(line)), row.v == 1 else { continue }
                guard seen.insert(row.source).inserted else { continue }
                reduce(row)
            }
        }
        for (agent, task) in active {
            let pending = (delegationOrder[task] ?? []).filter { open.contains($0) }
            append(Row(kind: "taskInterrupted", task: task, agent: agent, source: "interrupted/\(task)", openParts: pending))
        }
    }
    func submission(agent: UUID, project: UUID?) {
        queue.async {
            let task = self.active[agent] ?? UUID()
            if self.active[agent] == nil {
                self.append(Row(kind: "taskOpened", task: task, agent: agent, source: "open/\(task)", previousTask: self.previous[agent], project: project))
            }
            self.sessionTasks[agent] = task
            self.append(Row(kind: "submission", task: task, agent: agent, source: UUID().uuidString))
        }
    }
    func delegated(parent: UUID, child: UUID, source: String) {
        queue.async {
            guard let task = self.active[parent] else { return }
            self.sessionTasks[child] = task
            self.evidence[child] = HelperEvidence()
            self.append(Row(kind: "delegated", task: task, agent: child, part: child, source: "delegate/\(source)"))
        }
    }
    /// Typed hand-offs retain the existing value buffers; aggregation and
    /// source formatting happen only on the utility queue.
    func reported(agent: UUID, at: Date, checks: [AgentReport.Check], findings: [AgentReport.Finding]) {
        queue.async {
            self.fact(kind: "reported", agent: agent, source: "report/\(agent)/\(at.timeIntervalSinceReferenceDate)",
                checks: Dictionary(grouping: checks, by: { $0.result.rawValue }).mapValues { $0.count },
                findings: Dictionary(grouping: findings, by: { $0.level.rawValue }).mapValues { $0.count })
        }
    }
    func working(agent: UUID, turn: String) {
        queue.async { self.fact(kind: "working", agent: agent, source: "working/\(agent)/\(turn)") }
    }
    func ended(agent: UUID, turn: String, outcome: TurnOutcome) {
        queue.async { self.fact(kind: "turnEnded", agent: agent, source: "ended/\(agent)/\(turn)", outcome: outcome.rawValue) }
    }

    // MARK: Token usage (`.plans/116` part 14 step 1)

    typealias Counts = TokenUsageSnapshot.TypedCounts
    private struct UsageBuffer { var task: UUID; var tokens: Counts?; var incomplete = Set<String>() }
    /// Per agent that ran the work, per (task, model): counters since its last
    /// turn end. Memory only; a turn end hands them to `append`.
    private var usageBuffers: [UUID: [String: UsageBuffer]] = [:]
    private var usageObserved = Set<UUID>()
    /// Codex cumulative totals per provider thread, live only: the baseline
    /// each report is differenced against, and its provider time.
    private var codexTotals: [String: (counts: Counts, at: Date?)] = [:]
    private var claudeResults = Set<String>()

    /// One usage snapshot, on the event path: one enqueue. `owner` is the agent
    /// that ran the work (a provider-run child's usage is its parent's).
    /// `record` false keeps Codex baselines current and records nothing, so
    /// turning recording back on never charges the off period to a task.
    func usage(owner: UUID, model: String, _ snapshot: TokenUsageSnapshot, record: Bool) {
        queue.async {
            for (model, step) in Self.usageSteps(snapshot, model: model, codexTotals: &self.codexTotals, claudeResults: &self.claudeResults) {
                // An agent with no task (a solo Free agent) has no request id
                // in this ledger yet; its usage stops here.
                guard record, let task = self.sessionTasks[owner] else { continue }
                self.usageObserved.insert(owner)
                var buffer = self.usageBuffers[owner]?["\(task)|\(model)"] ?? UsageBuffer(task: task)
                switch step {
                case let .add(counts, reason):
                    buffer.tokens = buffer.tokens.map { Self.sum($0, counts) } ?? counts
                    if let reason { buffer.incomplete.insert(reason) }
                case let .unknown(reason): buffer.incomplete.insert(reason)
                case .ignore: continue
                }
                self.usageBuffers[owner, default: [:]]["\(task)|\(model)"] = buffer
            }
        }
    }

    /// The agent's turn ended: its buffered counters become rows. A turn of an
    /// agent with a task that reported no usage at all is recorded as unknown.
    func usageTurnEnded(agent: UUID, turn: String, harness: String?, model: String, effort: String?, record: Bool) {
        queue.async {
            let buffers = self.usageBuffers.removeValue(forKey: agent) ?? [:]
            let observed = self.usageObserved.remove(agent) != nil
            guard record else { return }
            func row(_ task: UUID, _ model: String, _ tokens: Counts?, _ incomplete: Set<String>) -> Row {
                var row = Row(kind: "usage", task: task, agent: agent, part: self.parts[agent],
                              source: "usage/\(agent)/\(turn)/\(task)/\(model)")
                (row.harness, row.model, row.effort, row.tokens) = (harness, model, effort, tokens)
                row.incomplete = incomplete.isEmpty ? nil : incomplete.sorted()
                return row
            }
            if buffers.isEmpty, !observed, let task = self.sessionTasks[agent] {
                self.append(row(task, model, nil, ["noUsage"]))
            }
            for (key, buffer) in buffers.sorted(by: { $0.key < $1.key }) {
                self.append(row(buffer.task, String(key.split(separator: "|", maxSplits: 1)[1]), buffer.tokens, buffer.incomplete))
            }
        }
    }

    enum UsageStep: Equatable { case add(Counts, String?), unknown(String), ignore }

    /// What one snapshot adds, per model. Claude: the result's share, once per
    /// result id. Codex: the cumulative total differenced per thread, in
    /// provider time; a report older than the newest is already inside it.
    static func usageSteps(_ snapshot: TokenUsageSnapshot, model: String,
                           codexTotals: inout [String: (counts: Counts, at: Date?)],
                           claudeResults: inout Set<String>) -> [(String, UsageStep)] {
        if let byModel = snapshot.typedCountsByModel {
            if let id = snapshot.accountingObservationID, !claudeResults.insert(id).inserted { return [(model, .ignore)] }
            let reason = snapshot.accountingReconciled == false ? "unreconciled" : nil
            return byModel.sorted { $0.key < $1.key }.map { ($0.key, .add($0.value, reason)) }
        }
        guard let session = snapshot.accountingSession, let current = snapshot.typedCounts else {
            return [(model, .unknown("untyped"))]
        }
        let at = snapshot.observedAt
        guard let previous = codexTotals[session] else {
            codexTotals[session] = (current, at)
            // A fork's or a resumed thread's first total holds history from
            // before this process watched it.
            if snapshot.accountingForkedFrom != nil { return [(model, .unknown("fork"))] }
            return [(model, snapshot.accountingSessionStarted == true ? .add(current, nil) : .unknown("noBaseline"))]
        }
        if let at, let seen = previous.at, at < seen { return [(model, .ignore)] }
        func lower(_ a: Int?, _ b: Int?) -> Bool { a.flatMap { a in b.map { a < $0 } } ?? false }
        let input = { (c: Counts) in c.uncachedInput.flatMap { u in c.cacheRead.map { u + $0 } } }
        codexTotals[session] = (current, at)
        if lower(input(current), input(previous.counts)) || lower(current.cacheRead, previous.counts.cacheRead)
            || lower(current.output, previous.counts.output) {
            return [(model, .unknown("reset"))]
        }
        func minus(_ a: Int?, _ b: Int?) -> Int? { a.flatMap { a in b.map { a - $0 } } }
        return [(model, .add(.init(uncachedInput: minus(current.uncachedInput, previous.counts.uncachedInput),
                                   cacheRead: minus(current.cacheRead, previous.counts.cacheRead),
                                   cacheWrite: minus(current.cacheWrite, previous.counts.cacheWrite),
                                   output: minus(current.output, previous.counts.output)), nil))]
    }

    static func sum(_ a: Counts, _ b: Counts) -> Counts {
        func add(_ x: Int?, _ y: Int?) -> Int? { x.flatMap { x in y.map { x + $0 } } }
        return .init(uncachedInput: add(a.uncachedInput, b.uncachedInput), cacheRead: add(a.cacheRead, b.cacheRead),
                     cacheWrite: add(a.cacheWrite, b.cacheWrite), output: add(a.output, b.output))
    }

    private func fact(kind: String, agent: UUID, source: String, outcome: String? = nil, checks: [String: Int]? = nil, findings: [String: Int]? = nil) {
        let part = parts[agent]
        guard let task = sessionTasks[agent],
              let owner = owners[task] else { return }
        append(Row(kind: kind, task: task, agent: agent, part: part, source: source, outcome: outcome, checks: checks, findings: findings))
        guard active[owner] == task, kind == "turnEnded" || kind == "reported",
              openByTask[task]?.isEmpty ?? true,
              let leadBoundary = leadBoundary[task],
              leadBoundary.kind == "turnEnded" else { return }
        let closing = leadBoundary.outcome == "completed" ? "taskClosed" : "taskInterrupted"
        append(Row(kind: closing, task: task, agent: owner, source: "close/\(task)", openParts: closing == "taskInterrupted" ? [] : nil))
    }
}
