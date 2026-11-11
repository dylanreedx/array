import Foundation
import ContinuumRevivedCore

/// Host-only facts. All reduction, recovery and disk access share this queue.
/// No prompt, report prose, paths or diffs cross this boundary.
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
    }
    private let queue = DispatchQueue(label: "dev.array.run-ledger", qos: .utility)
    private let url: URL
    private var rows: [Row] = []
    private var seen = Set<String>()
    private var active: [UUID: UUID] = [:]
    private var previous: [UUID: UUID] = [:]
    private var owners: [UUID: UUID] = [:]
    private var parts: [UUID: UUID] = [:]
    private var open = Set<UUID>()
    private var needsSeparator = false
    // Replayed transcript events during restore are history, not new run facts.
    // Keep live attribution after closure for wakes, but never rebuild it from disk.
    private var sessionTasks: [UUID: UUID] = [:]
    init(support: URL) {
        url = support.appendingPathComponent("run-ledger/ledger.jsonl")
        queue.async { self.recover() }
    }
    /// The sole append path, including replay and restart facts. Callers supply
    /// stable source identities; duplicates never reach disk or the reducer.
    private func append(_ row: Row) {
        guard seen.insert(row.source).inserted else { return }
        rows.append(row)
        switch row.kind {
        case "taskOpened": active[row.agent] = row.task; previous[row.agent] = row.task; owners[row.task] = row.agent
        case "delegated": parts[row.agent] = row.part; if let part = row.part { open.insert(part) }
        case "turnEnded", "reported": if let part = row.part { open.remove(part) }
        case "taskClosed", "taskInterrupted": active[row.agent] = nil
        default: break
        }
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
    private func recover() {
        if let data = try? Data(contentsOf: url) {
            // Preserve all prior bytes, including a torn final append. The sole
            // append path inserts a separator before its next fact.
            let complete = data.lastIndex(of: 10).map { Data(data[...$0]) } ?? Data()
            needsSeparator = complete.count != data.count
            for line in complete.split(separator: 10) {
                guard let row = try? JSONDecoder().decode(Row.self, from: Data(line)), row.v == 1 else { continue }
                guard seen.insert(row.source).inserted else { continue }
                rows.append(row)
                if row.kind == "taskOpened" { active[row.agent] = row.task; previous[row.agent] = row.task; owners[row.task] = row.agent }
                if row.kind == "delegated", let part = row.part { parts[row.agent] = part; open.insert(part) }
                if (row.kind == "turnEnded" || row.kind == "reported"), let part = row.part { open.remove(part) }
                if row.kind == "taskClosed" || row.kind == "taskInterrupted" { active[row.agent] = nil }
            }
        }
        for (agent, task) in active {
            let pending = rows.filter { $0.task == task && $0.kind == "delegated" }.compactMap(\.part).filter { open.contains($0) }
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
    private func fact(kind: String, agent: UUID, source: String, outcome: String? = nil, checks: [String: Int]? = nil, findings: [String: Int]? = nil) {
        let part = parts[agent]
        guard let task = sessionTasks[agent],
              let owner = owners[task] else { return }
        append(Row(kind: kind, task: task, agent: agent, part: part, source: source, outcome: outcome, checks: checks, findings: findings))
        guard active[owner] == task, kind == "turnEnded" || kind == "reported",
              !rows.contains(where: { $0.task == task && $0.kind == "delegated" && $0.part.map(open.contains) == true }),
              let leadBoundary = rows.last(where: { $0.task == task && $0.agent == owner && ($0.kind == "working" || $0.kind == "turnEnded") }),
              leadBoundary.kind == "turnEnded" else { return }
        let closing = leadBoundary.outcome == "completed" ? "taskClosed" : "taskInterrupted"
        append(Row(kind: closing, task: task, agent: owner, source: "close/\(task)", openParts: closing == "taskInterrupted" ? [] : nil))
    }
}
