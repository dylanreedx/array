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
        case "turnEnded": if let part = row.part { open.remove(part) }
        case "taskClosed", "taskInterrupted": active[row.agent] = nil
        default: break
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var data = try JSONEncoder().encode(row); data.append(10)
            if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
            let file = try FileHandle(forWritingTo: url)
            defer { try? file.close() }
            try file.seekToEnd(); try file.write(contentsOf: data)
        } catch { NSLog("Run ledger write failed: %@", String(describing: error)) }
    }
    private func recover() {
        if let data = try? Data(contentsOf: url) {
            // A crash may leave a torn last append. Keep only whole rows before
            // appending recovery facts, so the next event stays decodable.
            let complete = data.lastIndex(of: 10).map { Data(data[...$0]) } ?? Data()
            if complete.count != data.count { try? complete.write(to: url, options: .atomic) }
            for line in complete.split(separator: 10) {
                guard let row = try? JSONDecoder().decode(Row.self, from: Data(line)), row.v == 1 else { continue }
                guard seen.insert(row.source).inserted else { continue }
                rows.append(row)
                if row.kind == "taskOpened" { active[row.agent] = row.task; previous[row.agent] = row.task; owners[row.task] = row.agent }
                if row.kind == "delegated", let part = row.part { parts[row.agent] = part; open.insert(part) }
                if row.kind == "turnEnded", let part = row.part { open.remove(part) }
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
            self.append(Row(kind: "submission", task: task, agent: agent, source: UUID().uuidString))
        }
    }
    func delegated(parent: UUID, child: UUID, source: String) {
        queue.async {
            guard let task = self.active[parent] else { return }
            self.append(Row(kind: "delegated", task: task, agent: child, part: child, source: "delegate/\(source)"))
        }
    }
    func fact(kind: String, agent: UUID, source: String, outcome: String? = nil, checks: [String: Int]? = nil, findings: [String: Int]? = nil) {
        queue.async {
            let part = self.parts[agent]
            guard let task = self.active[agent] ?? self.rows.last(where: { $0.agent == agent && $0.kind == "delegated" })?.task,
                  let owner = self.owners[task], self.active[owner] == task else { return }
            self.append(Row(kind: kind, task: task, agent: agent, part: part, source: source, outcome: outcome, checks: checks, findings: findings))
            if kind == "turnEnded", agent == owner,
               !self.rows.contains(where: { $0.task == task && $0.kind == "delegated" && $0.part.map(self.open.contains) == true }) {
                let closing = outcome == "completed" ? "taskClosed" : "taskInterrupted"
                self.append(Row(kind: closing, task: task, agent: owner, source: "close/\(task)", openParts: closing == "taskInterrupted" ? [] : nil))
            }
        }
    }
}
