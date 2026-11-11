import Foundation

/// How Array did the work on this Mac, from the run ledger (`.plans/116` part 21,
/// first slice). A reader: it records nothing. Missing data is unknown, never
/// zero, and every figure carries how many tasks it covers. No averages, no
/// money, no comparison between solo and fanned-out tasks.
public struct UsageReport: Equatable, Encodable, Sendable {
    public enum Period: String, CaseIterable, Codable, Sendable {
        case week, month, all
        public var title: String {
            switch self {
            case .week: return "Last 7 days"
            case .month: return "Last 30 days"
            case .all: return "All time"
            }
        }
        public func start(now: Date) -> Date? {
            switch self {
            case .week: return now.addingTimeInterval(-7 * 86_400)
            case .month: return now.addingTimeInterval(-30 * 86_400)
            case .all: return nil
            }
        }
    }

    public enum TokenType: String, CaseIterable, Codable, CodingKeyRepresentable, Sendable {
        case uncachedInput, cacheRead, cacheWrite, output
        public var title: String {
            switch self {
            case .uncachedInput: return "Input, not cached"
            case .cacheRead: return "Read from cache"
            case .cacheWrite: return "Written to cache"
            case .output: return "Output"
            }
        }
        func value(_ counts: TokenUsageSnapshot.TypedCounts) -> Int? {
            switch self {
            case .uncachedInput: return counts.uncachedInput
            case .cacheRead: return counts.cacheRead
            case .cacheWrite: return counts.cacheWrite
            case .output: return counts.output
            }
        }
    }

    /// A sum that knows whether part of it is missing.
    public struct Figure: Equatable, Codable, Sendable {
        public var known = 0
        /// Tasks (or, inside one task, rows) whose share is unknown.
        public var unknown = 0
        public init(known: Int = 0, unknown: Int = 0) { self.known = known; self.unknown = unknown }
        public var isUnknown: Bool { unknown > 0 }
        mutating func add(_ other: Figure) { known += other.known; unknown += other.unknown }
    }

    public enum Role: String, CaseIterable, Codable, CodingKeyRepresentable, Sendable { case lead, helpers }

    public struct Model: Equatable, Codable, Sendable {
        public var role: Role
        public var harness: String?
        public var model: String?
    }

    public struct TaskLine: Equatable, Codable, Sendable {
        public var task: UUID
        public var state: RunLedgerUsageReader.State
        public var opened: Date?
        public var ended: Date?
        /// First submission to close. Nil unless closed.
        public var timeToAnswer: TimeInterval?
        /// The union of every agent's turns. Nil unless closed with every turn ended.
        public var activeTime: TimeInterval?
        public var helpers: Int
        /// Per role, per type. Inside one task `unknown` is 0 or 1.
        public var tokens: [Role: [TokenType: Figure]]
        /// Every turn counted, every type known.
        public var fullyCounted: Bool
        public var models: [Model]
    }

    public var period: Period
    /// Tasks closed in the period: the only tasks in any figure.
    public var closed: Int = 0
    public var fullyCounted: Int = 0
    public var solo: Int = 0
    public var oneHelper: Int = 0
    public var twoOrMoreHelpers: Int = 0
    /// Opened in the period and not closed: listed, in no figure.
    public var open: Int = 0
    public var interrupted: Int = 0
    /// Over closed tasks; `unknown` counts tasks.
    public var tokens: [Role: [TokenType: Figure]] = [:]
    /// Lead and helpers together; a task with either part unknown counts once.
    public var all: [TokenType: Figure] = [:]
    /// Newest first: closed, open and interrupted tasks of the period.
    public var tasks: [TaskLine] = []

    /// Export: ids, model ids, fixed words and numbers only; no names or text.
    public func exportJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    /// The one report function: the page and any scorecard command call this.
    public static func make(_ ledger: [RunLedgerUsageReader.Task], period: Period, now: Date = Date()) -> UsageReport {
        var report = UsageReport(period: period)
        let start = period.start(now: now)
        for task in ledger {
            let when = task.state == .open ? task.opened : task.ended
            if let start, (when ?? .distantPast) < start { continue }
            let line = summarize(task)
            report.tasks.append(line)
            switch task.state {
            case .open: report.open += 1; continue
            case .interrupted: report.interrupted += 1; continue
            case .closed: break
            }
            report.closed += 1
            if line.fullyCounted { report.fullyCounted += 1 }
            switch line.helpers {
            case 0: report.solo += 1
            case 1: report.oneHelper += 1
            default: report.twoOrMoreHelpers += 1
            }
            for type in TokenType.allCases {
                var both = Figure()
                for role in Role.allCases {
                    let figure = line.tokens[role]?[type] ?? Figure()
                    report.tokens[role, default: [:]][type, default: Figure()].add(figure)
                    both.known += figure.known
                    both.unknown = max(both.unknown, figure.unknown)
                }
                report.all[type, default: Figure()].add(both)
            }
        }
        report.tasks.sort { ($0.ended ?? $0.opened ?? .distantPast) > ($1.ended ?? $1.opened ?? .distantPast) }
        return report
    }

    static func summarize(_ task: RunLedgerUsageReader.Task) -> TaskLine {
        var tokens: [Role: [TokenType: Figure]] = [:]
        var models: [Model] = []
        var fully = task.state == .closed && !task.usage.isEmpty
        for role in Role.allCases {
            let rows = task.usage.filter { ($0.agent == task.lead) == (role == .lead) }
            // An agent of this role that ran a turn but left no usage row.
            let ran = task.turns.keys.filter { ($0 == task.lead) == (role == .lead) }
            let silent = ran.contains { agent in !rows.contains { $0.agent == agent } }
            let leadMissing = role == .lead && rows.isEmpty
            for type in TokenType.allCases {
                var figure = Figure()
                for row in rows { figure.known += row.tokens.flatMap(type.value) ?? 0 }
                let partial = silent || leadMissing
                    || rows.contains { !$0.incomplete.isEmpty || $0.tokens.flatMap(type.value) == nil }
                figure.unknown = partial ? 1 : 0
                if partial { fully = false }
                tokens[role, default: [:]][type] = figure
            }
            for row in rows {
                let model = Model(role: role, harness: row.harness, model: row.model)
                if !models.contains(model) { models.append(model) }
            }
        }
        var timeToAnswer: TimeInterval?
        var active: TimeInterval?
        if task.state == .closed, let opened = task.opened, let ended = task.ended {
            timeToAnswer = ended.timeIntervalSince(opened)
            let turns = task.turns.values.flatMap { $0 }
            if !turns.isEmpty, turns.allSatisfy({ $0.end != nil }) {
                active = union(turns.map { ($0.start, $0.end!) })
            }
        }
        return TaskLine(task: task.id, state: task.state, opened: task.opened, ended: task.ended,
                        timeToAnswer: timeToAnswer, activeTime: active, helpers: task.helpers.count,
                        tokens: tokens, fullyCounted: fully, models: models)
    }

    /// Overlapping turns count once.
    static func union(_ intervals: [(Date, Date)]) -> TimeInterval {
        var total: TimeInterval = 0
        var current: (Date, Date)?
        for (start, end) in intervals.sorted(by: { $0.0 < $1.0 }) {
            if let open = current, start <= open.1 {
                current = (open.0, max(open.1, end))
            } else {
                if let open = current { total += open.1.timeIntervalSince(open.0) }
                current = (start, end)
            }
        }
        if let open = current { total += open.1.timeIntervalSince(open.0) }
        return total
    }
}
