import Foundation

/// The usage page's only view of the managed run ledger
/// (`docs/internals/managed-run-ledger.md`). It reads a snapshot of the file and
/// never takes the writer's queue or lock. When the writer's rows change, this
/// file is the one to change.
///
/// Mapping, by row `kind` (rows with another `v` or an unreadable line are skipped):
/// - `taskOpened`: a task begins at `at`; its `agent` is the lead.
/// - `delegated`: `agent` is a helper of `task`.
/// - `working` / `turnEnded`: `agent` started / ended a turn in `task`. Paired per
///   agent in file order.
/// - `taskClosed`: the task closed at `at`. Only closed tasks are counted.
/// - `taskInterrupted`: the task stopped without closing (a failed or cancelled
///   last turn, or a restart). Listed, never counted.
/// - `usage`: tokens one agent used in `task` for one `model`, with `harness`.
///   A key absent from `tokens` is unknown, never zero; `incomplete` names why a
///   figure is partial. A usage row's `agent` equal to the lead is the lead's;
///   any other agent is a helper's.
/// Every other kind (`submission`, `reported`, `helperEvidence`, …) is not read.
public enum RunLedgerUsageReader {
    public struct Turn: Equatable, Sendable {
        public var start: Date
        public var end: Date?
    }

    public struct Usage: Equatable, Sendable {
        public var agent: UUID
        public var harness: String?
        public var model: String?
        public var tokens: TokenUsageSnapshot.TypedCounts?
        public var incomplete: [String]
    }

    public enum State: String, Codable, Sendable { case open, closed, interrupted }

    public struct Task: Equatable, Sendable {
        public var id: UUID
        public var lead: UUID?
        public var opened: Date?
        public var ended: Date?
        public var state: State = .open
        /// In delegation order.
        public var helpers: [UUID] = []
        public var turns: [UUID: [Turn]] = [:]
        public var usage: [Usage] = []
    }

    /// The row fields this reader uses; everything else in a row is ignored.
    private struct Row: Decodable {
        var v: Int
        var at: Date
        var kind: String
        var task: UUID
        var agent: UUID
        var harness: String?
        var model: String?
        var tokens: TokenUsageSnapshot.TypedCounts?
        var incomplete: [String]?
    }

    public static func ledgerURL(applicationSupport: URL) -> URL {
        applicationSupport.appendingPathComponent("run-ledger/ledger.jsonl")
    }

    /// Tasks in first-seen order. `isCancelled` is polled between rows so a
    /// closed pane stops a long read.
    public static func read(_ data: Data, isCancelled: () -> Bool = { false }) -> [Task] {
        var tasks: [UUID: Task] = [:]
        var order: [UUID] = []
        let decoder = JSONDecoder()
        // A torn final append is not a row yet.
        let complete = data.lastIndex(of: 10).map { data[...$0] } ?? data[data.startIndex..<data.startIndex]
        var count = 0
        for line in complete.split(separator: 10) {
            count += 1
            if count % 2_000 == 0, isCancelled() { return [] }
            guard let row = try? decoder.decode(Row.self, from: line), row.v == 1 else { continue }
            if tasks[row.task] == nil { tasks[row.task] = Task(id: row.task); order.append(row.task) }
            var task = tasks[row.task]!
            switch row.kind {
            case "taskOpened":
                task.lead = row.agent
                task.opened = row.at
            case "delegated":
                if !task.helpers.contains(row.agent) { task.helpers.append(row.agent) }
            case "working":
                task.turns[row.agent, default: []].append(Turn(start: row.at))
            case "turnEnded":
                if let last = task.turns[row.agent]?.indices.last, task.turns[row.agent]![last].end == nil {
                    task.turns[row.agent]![last].end = row.at
                }
            case "taskClosed":
                task.state = .closed
                task.ended = row.at
            case "taskInterrupted":
                task.state = .interrupted
                task.ended = row.at
            case "usage":
                task.usage.append(Usage(agent: row.agent, harness: row.harness, model: row.model,
                                        tokens: row.tokens, incomplete: row.incomplete ?? []))
            default:
                break
            }
            tasks[row.task] = task
        }
        return order.compactMap { tasks[$0] }
    }
}
