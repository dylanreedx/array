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
        /// The four kinds together: a table row, never a ledger field.
        case total
        public static let kinds: [TokenType] = [.uncachedInput, .cacheRead, .cacheWrite, .output]
        public var title: String {
            switch self {
            case .uncachedInput: return "Input, not cached"
            case .cacheRead: return "Read from cache"
            case .cacheWrite: return "Written to cache"
            case .output: return "Output"
            case .total: return "Total"
            }
        }
        func value(_ counts: TokenUsageSnapshot.TypedCounts) -> Int? {
            switch self {
            case .uncachedInput: return counts.uncachedInput
            case .cacheRead: return counts.cacheRead
            case .cacheWrite: return counts.cacheWrite
            case .output: return counts.output
            case .total: return nil
            }
        }
    }

    /// Kinds a harness never reports (`docs/internals/managed-run-ledger.md`):
    /// absent from every one of its rows by design, so "not reported", never a
    /// missing figure.
    public static let notReported: [String: Set<TokenType>] = [AgentHarness.codex.rawValue: [.cacheWrite]]

    /// A sum that knows whether part of it is missing. Each count is of tasks.
    public struct Figure: Equatable, Codable, Sendable {
        public var known = 0
        /// Tasks whose share is missing: the sum is a lower bound.
        public var unknown = 0
        /// Tasks where some harness reported this kind.
        public var reported = 0
        /// Tasks where the work ran only on harnesses that never report it.
        public var notReported = 0
        public init(known: Int = 0, unknown: Int = 0, reported: Int = 0, notReported: Int = 0) {
            (self.known, self.unknown, self.reported, self.notReported) = (known, unknown, reported, notReported)
        }
        public var isUnknown: Bool { unknown > 0 }
        /// Nothing to show but "not reported".
        public var isNotReported: Bool { unknown == 0 && reported == 0 && notReported > 0 }
        mutating func add(_ other: Figure) {
            known += other.known; unknown += other.unknown
            reported += other.reported; notReported += other.notReported
        }
        /// Two shares of ONE task: each flag counts the task once.
        mutating func merge(_ other: Figure) {
            known += other.known
            unknown = max(unknown, other.unknown)
            reported = max(reported, other.reported)
            notReported = max(notReported, other.notReported)
        }
    }

    public enum Role: String, CaseIterable, Codable, Sendable { case lead, helpers }
    /// The table's columns: each role, and both together.
    public enum Column: String, CaseIterable, Codable, CodingKeyRepresentable, Sendable { case lead, helpers, all }

    public typealias Table = [Column: [TokenType: Figure]]

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
        /// Exact figures; inside one task each count is 0 or 1.
        public var tokens: Table
        /// Every turn counted, every kind its harness reports known.
        public var fullyCounted: Bool
        public var models: [Model]
        public var total: Figure { tokens[.all]?[.total] ?? Figure() }
    }

    public var period: Period
    /// Tasks closed in the period: the only tasks in any figure.
    public var closed: Int = 0
    public var fullyCounted: Int = 0
    /// Closed tasks with any figure missing: every total is a lower bound.
    public var missing: Int = 0
    public var solo: Int = 0
    public var oneHelper: Int = 0
    public var twoOrMoreHelpers: Int = 0
    /// Opened in the period and not closed: listed, in no figure.
    public var open: Int = 0
    public var interrupted: Int = 0
    /// Over closed tasks.
    public var tokens: Table = [:]
    /// Harness and kind pairs not reported by a harness in the period's tasks.
    public var notReportedKinds: [String: [TokenType]] = [:]
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
            if line.total.isUnknown { report.missing += 1 }
            switch line.helpers {
            case 0: report.solo += 1
            case 1: report.oneHelper += 1
            default: report.twoOrMoreHelpers += 1
            }
            for (column, row) in line.tokens {
                for (type, figure) in row { report.tokens[column, default: [:]][type, default: Figure()].add(figure) }
            }
            for usage in task.usage {
                guard let harness = usage.harness, let kinds = notReported[harness] else { continue }
                report.notReportedKinds[harness] = TokenType.kinds.filter(kinds.contains)
            }
        }
        report.tasks.sort { ($0.ended ?? $0.opened ?? .distantPast) > ($1.ended ?? $1.opened ?? .distantPast) }
        return report
    }

    static func summarize(_ task: RunLedgerUsageReader.Task) -> TaskLine {
        var tokens: Table = [:]
        var models: [Model] = []
        for role in Role.allCases {
            let column: Column = role == .lead ? .lead : .helpers
            let rows = task.usage.filter { ($0.agent == task.lead) == (role == .lead) }
            // An agent of this role that ran a turn but left no usage row, or a
            // lead with no row at all: everything of this role is missing.
            let ran = task.turns.keys.filter { ($0 == task.lead) == (role == .lead) }
            let silent = ran.contains { agent in !rows.contains { $0.agent == agent } } || (role == .lead && rows.isEmpty)
            var total = Figure()
            for type in TokenType.kinds {
                let reporting = rows.filter { !(notReported[$0.harness ?? ""]?.contains(type) ?? false) }
                var figure = Figure()
                for row in reporting { figure.known += row.tokens.flatMap(type.value) ?? 0 }
                let partial = silent || rows.contains { !$0.incomplete.isEmpty || $0.tokens == nil }
                    || reporting.contains { $0.tokens.flatMap(type.value) == nil }
                figure.unknown = partial ? 1 : 0
                figure.reported = reporting.isEmpty ? 0 : 1
                figure.notReported = !partial && reporting.isEmpty && !rows.isEmpty ? 1 : 0
                tokens[column, default: [:]][type] = figure
                total.merge(Figure(known: figure.known, unknown: figure.unknown, reported: figure.reported))
            }
            tokens[column, default: [:]][.total] = total
            for row in rows {
                let model = Model(role: role, harness: row.harness, model: row.model)
                if !models.contains(model) { models.append(model) }
            }
        }
        for type in TokenType.allCases {
            var both = Figure()
            for column in [Column.lead, .helpers] { both.merge(tokens[column]?[type] ?? Figure()) }
            if both.reported > 0 { both.notReported = 0 }
            tokens[.all, default: [:]][type] = both
        }
        let fully = task.state == .closed && !task.usage.isEmpty && !(tokens[.all]?[.total]?.isUnknown ?? true)
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
