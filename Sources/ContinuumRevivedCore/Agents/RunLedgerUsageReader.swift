import Foundation

/// The usage page's only view of the managed run ledger
/// (`docs/internals/managed-run-ledger.md`). It reads a snapshot of the file and
/// never takes the writer's queue or lock. When the writer's rows change, this
/// file is the one to change.
///
/// Mapping, by row `kind` (rows with another `v` or an unreadable line are skipped):
/// - `taskOpened`: a task begins at `at`; its `agent` is the lead; `mode` is
///   `managed` or `free` (absent on rows from before modes were recorded).
/// - `delegated`: `agent` is a helper of `task`: a direct one, a helper's own
///   helper (`parent` names it), or a child the CLI started itself
///   (`via: harness`). Helpers also appear through their usage rows (below).
/// - `working` / `turnEnded`: `agent` started / ended a turn in `task`. Paired per
///   agent in file order. A turn may end after the close; active time is cut there.
/// - `taskClosed`: the task closed at `at`. Only closed tasks are counted.
/// - `taskInterrupted`: the task stopped without closing (a failed or cancelled
///   last turn, or a restart). Listed, never counted.
/// - `usage`: tokens one agent used in `task` for one `model` (nil when blank),
///   with `harness`, `modelSource` and `parent`. A key absent from `tokens` is
///   unknown, never zero; `incomplete` names why a figure is partial. A usage
///   row's `agent` equal to the lead is the lead's; any other agent, at any
///   depth, is a helper's. One turn may have several rows (a `late` row arrives
///   after its turn ended): all are summed, each `source` once, and a turn's
///   `noUsage` row is dropped once a row with tokens names the same turn.
/// - The all-zero `task` holds usage no human-prompted task owns: returned as
///   `untasked`, never as a task.
/// Every other kind (`submission`, `reported`, `helperEvidence`, …) is not read.
public enum RunLedgerUsageReader {
    public struct Turn: Equatable, Sendable {
        public var start: Date
        public var end: Date?
    }

    public struct Usage: Equatable, Sendable {
        public var at: Date
        public var agent: UUID
        public var parent: UUID?
        public var turn: String?
        public var harness: String?
        public var model: String?
        /// `cli` when the stream named the model, `record` when the agent's record did.
        public var modelSource: String?
        public var tokens: TokenUsageSnapshot.TypedCounts?
        public var incomplete: [String]
    }

    public struct Ledger: Equatable, Sendable {
        public var tasks: [Task] = []
        /// Usage under the all-zero task id: no human-prompted task owns it.
        public var untasked: [Usage] = []
        public init(tasks: [Task] = [], untasked: [Usage] = []) { (self.tasks, self.untasked) = (tasks, untasked) }
    }

    public static let noTask = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    public enum State: String, Codable, Sendable { case open, closed, interrupted }

    public struct Task: Equatable, Sendable {
        public var id: UUID
        public var lead: UUID?
        /// `managed` or `free`; nil when not recorded.
        public var mode: String?
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
        var source: String?
        var mode: String?
        var parent: UUID?
        var turn: String?
        var harness: String?
        var model: String?
        var modelSource: String?
        var tokens: TokenUsageSnapshot.TypedCounts?
        var incomplete: [String]?
    }

    public static func ledgerURL(applicationSupport: URL) -> URL {
        applicationSupport.appendingPathComponent("run-ledger/ledger.jsonl")
    }

    /// Tasks in first-seen order. `isCancelled` is polled between rows so a
    /// closed pane stops a long read.
    public static func read(_ data: Data, isCancelled: () -> Bool = { false }) -> Ledger {
        var tasks: [UUID: Task] = [:]
        var order: [UUID] = []
        var ledger = Ledger()
        var sources = Set<String>()
        let decoder = JSONDecoder()
        // A torn final append is not a row yet.
        let complete = data.lastIndex(of: 10).map { data[...$0] } ?? data[data.startIndex..<data.startIndex]
        var count = 0
        for line in complete.split(separator: 10) {
            count += 1
            if count % 2_000 == 0, isCancelled() { return Ledger() }
            guard let row = try? decoder.decode(Row.self, from: line), row.v == 1 else { continue }
            if let source = row.source, !sources.insert(source).inserted { continue }
            let usage = row.kind == "usage" ? Usage(at: row.at, agent: row.agent, parent: row.parent, turn: row.turn, harness: row.harness,
                                                    model: row.model, modelSource: row.modelSource, tokens: row.tokens,
                                                    incomplete: row.incomplete ?? []) : nil
            if row.task == noTask {
                if let usage { ledger.untasked.append(usage) }
                continue
            }
            if tasks[row.task] == nil { tasks[row.task] = Task(id: row.task); order.append(row.task) }
            var task = tasks[row.task]!
            switch row.kind {
            case "taskOpened":
                task.lead = row.agent
                task.mode = row.mode
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
                if let usage { task.usage.append(usage) }
            default:
                break
            }
            tasks[row.task] = task
        }
        ledger.tasks = order.compactMap { tasks[$0] }.map { task in
            var task = task
            let counted = Set(task.usage.filter { $0.tokens != nil }.compactMap { u in u.turn.map { "\(u.agent)|\($0)" } })
            task.usage.removeAll { usage in
                usage.incomplete == ["noUsage"] && usage.turn.map { counted.contains("\(usage.agent)|\($0)") } == true
            }
            return task
        }
        return ledger
    }
}
