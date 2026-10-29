import Foundation

// `.plans/102-managed-agent-mode` P2a: what an agent says about its OWN work.
//
// `agent.report` (`array_report`): a finished agent hands back a short,
// structured report. A delegated child's report rides its spawn-result courier
// to the parent's `wait_agents`.
//
// `agent.status` (`array_status`): any agent declares what it is doing now.
// Always labelled DECLARED and kept apart from the status Array observes from
// the stream (principle 6: declared vs observed, never merged).
//
// Both are self-only: the caller is the subject, so there is no agentId in the
// request and another agent can never write them. Every field is validated and
// bounded here; a request over a bound is refused, never silently cut.

public enum AgentReportCheckResult: String, Codable, Sendable, CaseIterable {
    case pass, fail, info
}

public enum AgentReportFindingLevel: String, Codable, Sendable, CaseIterable {
    case blocker, issue, minor, note
}

public struct AgentReport: Codable, Equatable, Sendable {
    public struct Check: Codable, Equatable, Sendable {
        public var what: String
        public var result: AgentReportCheckResult

        public init(what: String, result: AgentReportCheckResult) {
            self.what = what
            self.result = result
        }
    }

    public struct Finding: Codable, Equatable, Sendable {
        public var level: AgentReportFindingLevel
        public var text: String
        public var location: String?

        enum CodingKeys: String, CodingKey {
            case level, text
            case location = "where"
        }

        public init(level: AgentReportFindingLevel, text: String, location: String? = nil) {
            self.level = level
            self.text = text
            self.location = location
        }
    }

    public var summary: String
    public var checks: [Check]
    public var findings: [Finding]
    public var next: String?
    public var detailsPath: String?

    public init(summary: String, checks: [Check] = [], findings: [Finding] = [], next: String? = nil, detailsPath: String? = nil) {
        self.summary = summary
        self.checks = checks
        self.findings = findings
        self.next = next
        self.detailsPath = detailsPath
    }

    public static let summaryMaxWords = 60
    public static let summaryMaxCharacters = 600
    public static let maxChecks = 8
    public static let maxFindings = 6
    /// A check's `what`, a finding's `where`, and `next`.
    public static let lineMaxCharacters = 200
    public static let findingTextMaxCharacters = 400
    public static let detailsPathMaxCharacters = 1024

    private struct Wire: Decodable {
        var summary: String?
        var checks: [WireCheck]?
        var findings: [WireFinding]?
        var next: String?
        var detailsPath: String?
    }
    private struct WireCheck: Decodable { var what: String?; var result: String? }
    private struct WireFinding: Decodable {
        var level: String?; var text: String?; var location: String?
        enum CodingKeys: String, CodingKey { case level, text, location = "where" }
    }

    /// The report a request describes, or the reason it is refused. Text is
    /// trimmed; one-line fields have their whitespace runs folded to a space.
    public static func validated(payload: [String: Any]) -> Result<AgentReport, WorkspaceAPIError> {
        func refuse(_ message: String) -> Result<AgentReport, WorkspaceAPIError> {
            .failure(WorkspaceAPIError(code: .invalidRequest, message: message + " Nothing was recorded."))
        }
        let wire: Wire
        do {
            wire = try JSONDecoder().decode(Wire.self, from: JSONSerialization.data(withJSONObject: payload))
        } catch {
            return refuse("array_report takes summary (text), checks [{what, result}], findings [{level, text, where?}], next and detailsPath; a field has the wrong type.")
        }
        guard let summary = wire.summary.map(trimmed), !summary.isEmpty else { return refuse("summary is required.") }
        let words = wordCount(summary)
        guard words <= summaryMaxWords, summary.count <= summaryMaxCharacters else {
            return refuse("summary is \(words) words; keep it to \(summaryMaxWords) words or fewer (put the rest in a file and pass detailsPath).")
        }
        let wireChecks = wire.checks ?? []
        guard wireChecks.count <= maxChecks else { return refuse("checks lists \(wireChecks.count) items; at most \(maxChecks).") }
        var checks: [Check] = []
        for (index, check) in wireChecks.enumerated() {
            guard let what = check.what.map(oneLine), !what.isEmpty, what.count <= lineMaxCharacters else {
                return refuse("checks[\(index)].what must be one line of 1 to \(lineMaxCharacters) characters.")
            }
            guard let result = check.result.flatMap(AgentReportCheckResult.init(rawValue:)) else {
                return refuse("checks[\(index)].result must be pass, fail or info.")
            }
            checks.append(Check(what: what, result: result))
        }
        let wireFindings = wire.findings ?? []
        guard wireFindings.count <= maxFindings else { return refuse("findings lists \(wireFindings.count) items; at most \(maxFindings).") }
        var findings: [Finding] = []
        for (index, finding) in wireFindings.enumerated() {
            guard let level = finding.level.flatMap(AgentReportFindingLevel.init(rawValue:)) else {
                return refuse("findings[\(index)].level must be blocker, issue, minor or note.")
            }
            guard let text = finding.text.map(trimmed), !text.isEmpty, text.count <= findingTextMaxCharacters else {
                return refuse("findings[\(index)].text must be 1 to \(findingTextMaxCharacters) characters.")
            }
            let location = finding.location.map(oneLine).flatMap { $0.isEmpty ? nil : $0 }
            if let location, location.count > lineMaxCharacters {
                return refuse("findings[\(index)].where must be at most \(lineMaxCharacters) characters.")
            }
            findings.append(Finding(level: level, text: text, location: location))
        }
        let next = wire.next.map(oneLine).flatMap { $0.isEmpty ? nil : $0 }
        if let next, next.count > lineMaxCharacters { return refuse("next must be one line of at most \(lineMaxCharacters) characters.") }
        let detailsPath = wire.detailsPath.map(trimmed).flatMap { $0.isEmpty ? nil : $0 }
        if let detailsPath {
            guard detailsPath.count <= detailsPathMaxCharacters,
                  detailsPath.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
                return refuse("detailsPath must be a file path of at most \(detailsPathMaxCharacters) characters.")
            }
        }
        return .success(AgentReport(summary: summary, checks: checks, findings: findings, next: next, detailsPath: detailsPath))
    }

    public static func wordCount(_ text: String) -> Int { text.split(whereSeparator: \.isWhitespace).count }
    static func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    static func oneLine(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
}

/// What an agent declared about itself through `array_status`.
public struct AgentDeclaredStatus: Codable, Equatable, Sendable {
    /// Always `declared`: the agent said it; Array did not observe it.
    public static let provenance = "declared"
    public static let lineMaxCharacters = 140

    public var now: String
    public var next: String?
    public var needsYou: String?
    public var declaredAt: Date
    public var provenance: String

    public init(now: String, next: String? = nil, needsYou: String? = nil, declaredAt: Date) {
        self.now = now
        self.next = next
        self.needsYou = needsYou
        self.declaredAt = declaredAt
        self.provenance = Self.provenance
    }

    private struct Wire: Decodable { var now: String?; var next: String?; var needsYou: String? }

    public static func validated(payload: [String: Any], at date: Date) -> Result<AgentDeclaredStatus, WorkspaceAPIError> {
        func refuse(_ message: String) -> Result<AgentDeclaredStatus, WorkspaceAPIError> {
            .failure(WorkspaceAPIError(code: .invalidRequest, message: message + " Nothing was recorded."))
        }
        let wire: Wire
        do {
            wire = try JSONDecoder().decode(Wire.self, from: JSONSerialization.data(withJSONObject: payload))
        } catch {
            return refuse("array_status takes now, next and needsYou, each one short line of text.")
        }
        func line(_ value: String?, _ name: String) -> Result<String?, WorkspaceAPIError> {
            guard let value else { return .success(nil) }
            let folded = AgentReport.oneLine(value)
            guard folded.count <= lineMaxCharacters else {
                return .failure(WorkspaceAPIError(code: .invalidRequest, message: "\(name) must be one line of at most \(lineMaxCharacters) characters. Nothing was recorded."))
            }
            return .success(folded.isEmpty ? nil : folded)
        }
        let now: String?, next: String?, needsYou: String?
        switch (line(wire.now, "now"), line(wire.next, "next"), line(wire.needsYou, "needsYou")) {
        case let (.success(a), .success(b), .success(c)): (now, next, needsYou) = (a, b, c)
        case let (.failure(error), _, _), let (_, .failure(error), _), let (_, _, .failure(error)): return .failure(error)
        }
        guard let now else { return refuse("now is required.") }
        return .success(AgentDeclaredStatus(now: now, next: next, needsYou: needsYou, declaredAt: date))
    }
}

public struct AgentReportResult: Codable, Equatable, Sendable {
    public var recorded: Bool
    public init(recorded: Bool) { self.recorded = recorded }
}
