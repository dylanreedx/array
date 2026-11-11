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
        var modelSource: String?
        var parent: UUID?
        var turn: String?
        var late: Bool?
        var mode: String?
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
    func submission(agent: UUID, project: UUID?, mode: String? = nil) {
        queue.async {
            let task = self.active[agent] ?? UUID()
            if self.active[agent] == nil {
                var opened = Row(kind: "taskOpened", task: task, agent: agent, source: "open/\(task)", previousTask: self.previous[agent], project: project)
                opened.mode = mode
                self.append(opened)
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
    /// Who ran the work, read from the agent's record on the event path.
    struct UsageIdentity {
        var harness: String?
        /// The record's model id: used only where the stream names none.
        var model: String?
        var effort: String?
        var parent: UUID?
        /// A provider-run child whose usage the provider reports only inside
        /// its parent's (Claude in-process subagents).
        var reportedByParent = false
    }
    /// A model id and where it came from (`cli` or `record`); nil is unknown.
    struct UsageModel: Hashable { var id: String?; var source: String? }
    private struct UsageKey: Hashable { var task: UUID; var model: UsageModel }
    private struct UsageBuffer { var tokens: Counts?; var incomplete = Set<String>() }
    private struct OpenTurn {
        var turn: String
        var observed = false
        var identity: UsageIdentity?
        var buffers: [UsageKey: UsageBuffer] = [:]
    }
    /// Per agent, the turn whose end has not been seen and its counters so far.
    /// Memory only; the turn end, a task close or the next turn writes them.
    private var openTurns: [UUID: OpenTurn] = [:]
    /// The task each agent's recent turns ran in, newest last, so a report that
    /// names an ended turn is charged to that turn's task. Bounded per agent.
    private var turnTasks: [UUID: [(turn: String, task: UUID)]] = [:]
    /// Each agent's parent, as its record names it: a helper or provider-run
    /// child at any depth is charged to the task its chain leads to.
    private var usageParents: [UUID: UUID] = [:]
    /// Codex cumulative totals per provider thread, live only: the baseline
    /// each report is differenced against, and its provider time.
    private var codexTotals: [String: (counts: Counts, at: Date?)] = [:]
    private var claudeResults = Set<String>()
    /// The task of usage whose agent has no task in its chain (a top-level
    /// agent no human prompted in this process): recorded, never dropped.
    static let noTask = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    private func usageTask(_ agent: UUID) -> UUID? {
        var current = agent
        for _ in 0..<64 {
            if let task = sessionTasks[current] { return task }
            guard let parent = usageParents[current], parent != current else { return nil }
            current = parent
        }
        return nil
    }

    /// A turn started: later usage that names it (or names no turn) waits for
    /// its end. A turn that started before the previous one's end was seen
    /// writes what the previous one gathered, so nothing waits forever.
    func usageTurnStarted(agent: UUID, turn: String) {
        queue.async {
            if let open = self.openTurns[agent] {
                if open.turn == turn { return }
                self.writeBuffers(agent, open, sourcePrefix: "usage-unended", extra: ["turnEndNotSeen"])
            }
            self.openTurns[agent] = OpenTurn(turn: turn)
            if let task = self.usageTask(agent) {
                var recent = self.turnTasks[agent, default: []]
                recent.append((turn, task))
                self.turnTasks[agent] = Array(recent.suffix(16))
            }
        }
    }
    private func task(of agent: UUID, turn: String?) -> UUID {
        turn.flatMap { turn in turnTasks[agent]?.last(where: { $0.turn == turn })?.task } ?? usageTask(agent) ?? Self.noTask
    }

    /// One usage snapshot, on the event path: one enqueue. `record` false keeps
    /// Codex baselines current and records nothing, so turning recording back
    /// on never charges the off period to a task.
    func usage(agent: UUID, _ identity: UsageIdentity, _ snapshot: TokenUsageSnapshot, record: Bool) {
        queue.async {
            let steps = Self.usageSteps(snapshot, recordModel: identity.model,
                                        codexTotals: &self.codexTotals, claudeResults: &self.claudeResults)
            if let parent = identity.parent { self.usageParents[agent] = parent }
            let turn = snapshot.accountingTurn ?? self.openTurns[agent]?.turn
            let task = self.task(of: agent, turn: turn)
            if let turn, var open = self.openTurns[agent], open.turn == turn {
                open.observed = true
                if record {
                    open.identity = identity
                    for (model, step) in steps {
                        var buffer = open.buffers[UsageKey(task: task, model: model)] ?? UsageBuffer()
                        if Self.fold(step, into: &buffer) { open.buffers[UsageKey(task: task, model: model)] = buffer }
                    }
                }
                self.openTurns[agent] = open
                return
            }
            // Its turn's rows are already written, or it names no turn: a late
            // row for the turn it names, never folded into another turn.
            guard record else { return }
            for (model, step) in steps {
                var buffer = UsageBuffer()
                guard Self.fold(step, into: &buffer) else { continue }
                self.append(self.usageRow(agent, identity, turn: turn, task: task, model: model, buffer,
                                          source: "usage-late/\(agent)/\(UUID().uuidString)", late: true))
            }
        }
    }

    /// The agent's turn ended: its buffered counters become rows. A turn that
    /// reported no usage at all is recorded as unknown.
    func usageTurnEnded(agent: UUID, turn: String, _ identity: UsageIdentity, record: Bool) {
        queue.async {
            guard let open = self.openTurns[agent], open.turn == turn else { return }
            self.openTurns[agent] = nil
            guard record else { return }
            if let parent = identity.parent { self.usageParents[agent] = parent }
            if !open.observed {
                let model = identity.model.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
                let buffer = UsageBuffer(tokens: nil, incomplete: [identity.reportedByParent ? "reportedByParent" : "noUsage"])
                self.append(self.usageRow(agent, identity, turn: turn, task: self.task(of: agent, turn: turn),
                                          model: UsageModel(id: model, source: model == nil ? nil : "record"), buffer,
                                          source: "usage/\(agent)/\(turn)/none", late: false))
            }
            var withIdentity = open
            withIdentity.identity = identity
            self.writeBuffers(agent, withIdentity, sourcePrefix: "usage", extra: [])
        }
    }

    private func writeBuffers(_ agent: UUID, _ open: OpenTurn, sourcePrefix: String, extra: Set<String>, task only: UUID? = nil) {
        let identity = open.identity ?? UsageIdentity()
        let keys = open.buffers.keys.filter { only == nil || $0.task == only }
            .sorted { ($0.task.uuidString, $0.model.id ?? "") < ($1.task.uuidString, $1.model.id ?? "") }
        for key in keys {
            guard var buffer = open.buffers[key] else { continue }
            buffer.incomplete.formUnion(extra)
            self.append(usageRow(agent, identity, turn: open.turn, task: key.task, model: key.model, buffer,
                                 source: "\(sourcePrefix)/\(agent)/\(open.turn)/\(key.task)/\(key.model.id ?? "-")", late: false))
        }
    }

    /// A task closed: what its agents' open turns gathered so far is written
    /// now; anything those turns report later is written at their end.
    private func flushUsage(task: UUID) {
        for (agent, open) in openTurns where open.buffers.keys.contains(where: { $0.task == task }) {
            writeBuffers(agent, open, sourcePrefix: "usage-close", extra: [], task: task)
            var rest = open
            rest.buffers = rest.buffers.filter { $0.key.task != task }
            openTurns[agent] = rest
        }
    }

    private func usageRow(_ agent: UUID, _ identity: UsageIdentity, turn: String?, task: UUID, model: UsageModel,
                          _ buffer: UsageBuffer, source: String, late: Bool) -> Row {
        var row = Row(kind: "usage", task: task, agent: agent, part: parts[agent], source: source)
        (row.harness, row.effort, row.parent, row.turn) = (identity.harness, identity.effort, identity.parent, turn)
        (row.model, row.modelSource) = (model.id, model.id == nil ? nil : model.source)
        (row.tokens, row.late) = (buffer.tokens, late ? true : nil)
        var flags = buffer.incomplete
        if task == Self.noTask { flags.insert("noTask") }
        row.incomplete = flags.isEmpty ? nil : flags.sorted()
        return row
    }

    /// Whether the step leaves anything to record.
    private static func fold(_ step: UsageStep, into buffer: inout UsageBuffer) -> Bool {
        switch step {
        case let .add(counts, reason):
            buffer.tokens = buffer.tokens.map { sum($0, counts) } ?? counts
            if let reason { buffer.incomplete.insert(reason) }
        case let .unknown(reason): buffer.incomplete.insert(reason)
        case .ignore: return false
        }
        return true
    }

    enum UsageStep: Equatable { case add(Counts, String?), unknown(String), ignore }

    /// What one snapshot adds, per model. Claude: the result's share, once per
    /// result id, under the model ids the CLI names. Codex: the cumulative
    /// total differenced per thread, in provider time; a report older than the
    /// newest is already inside it. A thread with no baseline here charges
    /// nothing unless this process saw it start: its first total becomes the
    /// baseline and the turn is marked.
    static func usageSteps(_ snapshot: TokenUsageSnapshot, recordModel: String?,
                           codexTotals: inout [String: (counts: Counts, at: Date?)],
                           claudeResults: inout Set<String>) -> [(UsageModel, UsageStep)] {
        func known(_ id: String?) -> String? { id.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 } }
        let model = known(snapshot.accountingModel).map { UsageModel(id: $0, source: "cli") }
            ?? UsageModel(id: known(recordModel), source: known(recordModel) == nil ? nil : "record")
        if let byModel = snapshot.typedCountsByModel {
            if let id = snapshot.accountingObservationID, !claudeResults.insert(id).inserted { return [(model, .ignore)] }
            if byModel.isEmpty { return [(model, .unknown("untyped"))] }
            let reason = snapshot.accountingReconciled == false ? "unreconciled" : nil
            return byModel.sorted { $0.key < $1.key }.map { entry in
                let id = known(entry.key)
                return (UsageModel(id: id, source: id == nil ? nil : "cli"), .add(entry.value, reason))
            }
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
        flushUsage(task: task)
    }
}
