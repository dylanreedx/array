import Foundation

/// The performance budget system.
///
/// Array is one window, one main thread, and one display cycle shared by every
/// live tile (docs/internals/performance.md). Historically a regression here was
/// only discovered when the app froze in front of the user, and "is it fast
/// enough?" had no answer anyone could produce on demand — there was no frame
/// instrumentation anywhere in the app.
///
/// This is that answer, in the shape the rest of the repo already uses for
/// correctness: a deterministic gate that reports a NUMBER against a STATED
/// TARGET, offline, on every run of the matrix.
///
/// Two rules it exists to enforce, both learned expensively:
///
/// 1. **Counts are the assertion; time is the guard.** A wall-clock threshold on
///    a laptop drifts with machine load and says nothing about *why*. A count
///    ("a pan writes tile bounds zero times") is deterministic and names the
///    defect. Every scenario should carry at least one count budget; a duration
///    budget alone is a flake generator with generous headroom.
/// 2. **A budget is a published target, not a high-water mark.** The limit is
///    what the product needs (a 120 Hz frame is 8.3 ms), not what the code
///    happens to do today. A budget that is merely "current + 10%" ratchets
///    slowness in and never fails.
public struct PerfBudget: Sendable, Equatable {
    public enum Limit: Sendable, Equatable {
        /// Measured value must be <= limit. The usual case: durations, counts of
        /// work that should be small, memory.
        case atMost(Double)
        /// Measured value must be exactly this. Used for the count assertions
        /// with teeth — "zero re-measurements", not "few re-measurements".
        case exactly(Double)
        /// Measured value must be >= limit. Guards the other direction: proof
        /// that the scenario still does its real work and has not been optimised
        /// into doing nothing at all.
        case atLeast(Double)
    }

    public enum Unit: String, Sendable, Codable {
        case milliseconds = "ms"
        case count = ""
        case fps = "fps"
        case megabytes = "MB"
    }

    /// Dotted identifier, e.g. `canvas.zoom.stepDuration`. Stable across runs —
    /// this is the key a trend is tracked under.
    public let metric: String
    public let limit: Limit
    public let unit: Unit
    /// Why this number. Shown on failure, so a future reader learns the reason
    /// rather than being tempted to relax the limit.
    public let rationale: String

    public init(metric: String, limit: Limit, unit: Unit, rationale: String) {
        self.metric = metric
        self.limit = limit
        self.unit = unit
        self.rationale = rationale
    }

    public func evaluate(_ value: Double) -> PerfMeasurement {
        let passed: Bool
        switch limit {
        case let .atMost(l): passed = value <= l
        case let .exactly(l): passed = value == l
        case let .atLeast(l): passed = value >= l
        }
        return PerfMeasurement(budget: self, value: value, passed: passed)
    }
}

public struct PerfMeasurement: Sendable, Equatable {
    public let budget: PerfBudget
    public let value: Double
    public let passed: Bool

    public var limitValue: Double {
        switch budget.limit {
        case let .atMost(l), let .exactly(l), let .atLeast(l): return l
        }
    }

    /// Fraction of the budget consumed, for `atMost` limits. > 1.0 means over.
    /// Nil where the notion does not apply (`atLeast`, or a zero limit).
    public var utilisation: Double? {
        switch budget.limit {
        case let .atMost(l) where l > 0: return value / l
        case .exactly, .atLeast, .atMost: return nil
        }
    }

    public var limitDescription: String {
        switch budget.limit {
        case let .atMost(l): return "<= \(PerfReport.number(l))"
        case let .exactly(l): return "== \(PerfReport.number(l))"
        case let .atLeast(l): return ">= \(PerfReport.number(l))"
        }
    }
}

/// One measured situation — "panning the canvas", "opening a large Markdown
/// file". A scenario owns several metrics because a single number never
/// explains a regression on its own: the duration says something got slower,
/// the counts say what started happening that should not.
public struct PerfScenarioResult: Sendable {
    public let name: String
    /// One line on what was driven, printed above the metrics so a reader knows
    /// what the numbers describe (tile counts, document size, step counts).
    public let detail: String
    public let measurements: [PerfMeasurement]

    public init(name: String, detail: String, measurements: [PerfMeasurement]) {
        self.name = name
        self.detail = detail
        self.measurements = measurements
    }

    public var passed: Bool { measurements.allSatisfy(\.passed) }
    public var failures: [PerfMeasurement] { measurements.filter { !$0.passed } }
}

/// Renders scenario results as the human table the runner prints and as the
/// machine-readable artifact a trend is built from.
public enum PerfReport {
    public static func number(_ value: Double) -> String {
        if value == value.rounded() && abs(value) < 1e9 {
            return String(Int(value))
        }
        return String(format: "%.3f", value)
    }

    /// The table. Fixed-width so a regression is visible at a glance in a matrix
    /// log, with the budget and the utilisation on every row — a metric at 95%
    /// of budget is passing and is also the next failure, and that must be
    /// visible without failing the run.
    public static func table(_ results: [PerfScenarioResult]) -> String {
        var lines: [String] = []
        for result in results {
            lines.append("")
            lines.append("  \(result.passed ? "PASS" : "FAIL")  \(result.name)")
            lines.append("        \(result.detail)")
            let width = result.measurements.map(\.budget.metric.count).max() ?? 0
            for m in result.measurements {
                let name = m.budget.metric.padding(toLength: max(width, 1), withPad: " ", startingAt: 0)
                let unit = m.budget.unit.rawValue
                let unitSuffix = unit.isEmpty ? "" : " \(unit)"
                var row = "        \(m.passed ? "ok  " : "OVER") \(name)  \(number(m.value))\(unitSuffix)  (budget \(m.limitDescription)\(unitSuffix)"
                if let u = m.utilisation {
                    row += ", \(Int((u * 100).rounded()))% used"
                }
                row += ")"
                lines.append(row)
                if !m.passed {
                    lines.append("             why: \(m.budget.rationale)")
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Flat JSON so a run can be diffed against another run, or appended to a
    /// ledger. Deliberately not nested by scenario: one row per metric is what a
    /// trend query wants.
    public static func json(_ results: [PerfScenarioResult], context: [String: String]) throws -> Data {
        var rows: [[String: Any]] = []
        for result in results {
            for m in result.measurements {
                rows.append([
                    "scenario": result.name,
                    "metric": m.budget.metric,
                    "value": m.value,
                    "limit": m.limitValue,
                    "unit": m.budget.unit.rawValue,
                    "comparison": m.limitDescription,
                    "passed": m.passed
                ])
            }
        }
        let payload: [String: Any] = ["context": context, "metrics": rows]
        return try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    }

    /// The end-of-run summary. Mirrors `run-matrix.sh`'s own reporting habit:
    /// judge a run by an explicit summary, never by an exit code alone.
    public static func summary(_ results: [PerfScenarioResult]) -> String {
        let total = results.reduce(0) { $0 + $1.measurements.count }
        let failed = results.reduce(0) { $0 + $1.failures.count }
        let overHalf = results.flatMap(\.measurements)
            .filter { $0.passed && ($0.utilisation ?? 0) > 0.5 }
        var lines = ["", "  \(results.count) scenarios, \(total) budgets, \(failed) over."]
        if !overHalf.isEmpty {
            lines.append("  Watch (passing, over half their budget): "
                         + overHalf.map(\.budget.metric).joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }
}
