import Foundation

/// A turn the CLI ended because the ACCOUNT ran out of usage — not a failure of
/// the agent, its tools or its conversation.
///
/// Evidence (claude 2.1.325, Dylan's own session logs 2026-11-09…16): when the
/// 5-hour or weekly window is exhausted the CLI writes a synthetic assistant
/// message (`model: "<synthetic>"`, `error: "rate_limit"`) whose only text is
///
///     You've hit your 5-hour limit · resets 1:40am (America/Toronto)
///     You've hit your weekly limit · resets Nov 13 at 1am (America/Toronto)
///
/// and ends the `-p` turn with an `is_error` result carrying that text. None of
/// `AgentFailureText.providerMessage`'s markers match it, so until this type the
/// turn read "Claude Code reported an error without details" and stayed Failed.
///
/// Codex states the same condition structurally: `codex_error_info:
/// "usage_limit_exceeded"` beside "You’ve hit your usage limit. … try again at
/// Nov 19th, 2026 12:27 PM." (16 rollouts in `~/.codex/sessions`, codex-cli
/// 0.167, 2026-11-11…16).
public struct AgentUsageLimitStop: Equatable, Sendable, Codable {
    /// `5-hour`, `weekly`: the CLI's own word for the window, when it said one.
    public var window: String?
    /// When the CLI said the window resets, resolved to an instant.
    public var resetsAt: Date?
    /// The CLI's own sentence, kept for every surface that shows the stop.
    public var message: String?

    public init(window: String?, resetsAt: Date?, message: String? = nil) {
        self.window = window
        self.resetsAt = resetsAt
        self.message = message
    }

    /// The Codex error code for an exhausted account (`codex_error_info`),
    /// and its camel-cased app-server spelling.
    public static let codexErrorCode = "usage_limit_exceeded"
    static let codexErrorCodes: Set<String> = [codexErrorCode, "usageLimitExceeded"]

    /// The line the Claude translator writes when the CLI signalled the stop
    /// structurally (`rate_limit_event.status == "rejected"`, an assistant
    /// frame tagged `error: "rate_limit"`) but its own sentence was not in the
    /// stream. Never "reported an error without details".
    public static let claudeStructuredLine = "You've hit your Claude usage limit"

    /// Classifies a terminal turn's error text. Only the CLI's own terminal
    /// error reaches here (`turnCompleted(.failed, errorMessage:)`), never
    /// assistant prose or tool output.
    public static func classify(errorMessage: String?, now: Date) -> AgentUsageLimitStop? {
        guard let raw = errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if codexErrorCodes.contains(raw) || raw == claudeStructuredLine {
            return AgentUsageLimitStop(window: nil, resetsAt: nil)
        }
        if let codex = codexLimit(raw, now: now) { return codex }
        guard let match = claudeLimitMatch(raw) else { return nil }
        return AgentUsageLimitStop(
            window: match.window,
            resetsAt: match.reset.flatMap { resetInstant($0, timeZoneName: match.timeZone, now: now) })
    }

    /// True for the claude CLI's own limit line. The translator keeps exactly
    /// this line as the turn's error, so the supervisor can classify it.
    public static func isClaudeLimitText(_ text: String?) -> Bool {
        guard let text else { return false }
        return claudeLimitMatch(text.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
    }

    private static let pattern = try! NSRegularExpression(
        pattern: #"^You(?:'|\u2019)ve hit your (?:([A-Za-z0-9 \-]{1,40}?) )?limit(?:\s*[·•\-]\s*resets ([^()]{1,40}?))?\s*(?:\(([A-Za-z_]+(?:/[A-Za-z_\-+0-9]+)*)\))?\s*$"#)

    private static func claudeLimitMatch(_ text: String) -> (window: String?, reset: String?, timeZone: String?)? {
        // One line only: the CLI's message is a single line, and anything
        // longer is not this message.
        guard !text.contains("\n"), text.count <= 160 else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = pattern.firstMatch(in: text, range: range) else { return nil }
        func group(_ i: Int) -> String? {
            guard let r = Range(match.range(at: i), in: text) else { return nil }
            let value = text[r].trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        // "You've hit your limit · resets 1:20 AM (…)" names no window.
        return (group(1), group(2), group(3))
    }

    /// Codex (seen 7 times in the 2026-11-16 failure census):
    /// "You’ve hit your usage limit. Visit https://… or try again at Nov 12th,
    /// 2026 11:05 AM." The clock is the Mac's own zone.
    private static let codexPattern = try! NSRegularExpression(
        pattern: #"^You(?:'|\u2019)ve hit your usage limit\.(?:.*?try again at ([A-Z][a-z]{2}) (\d{1,2})(?:st|nd|rd|th)?, (\d{4}) (\d{1,2}):(\d{2}) ?(AM|PM))?"#)

    private static func codexLimit(_ text: String, now: Date) -> AgentUsageLimitStop? {
        guard !text.contains("\n"), text.count <= 400 else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = codexPattern.firstMatch(in: text, range: range) else { return nil }
        func group(_ i: Int) -> String? {
            guard let r = Range(match.range(at: i), in: text) else { return nil }
            return String(text[r])
        }
        let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        var reset: Date?
        if let monthName = group(1), let month = months.firstIndex(of: monthName.lowercased()).map({ $0 + 1 }),
           let day = group(2).flatMap(Int.init), let year = group(3).flatMap(Int.init),
           var hour = group(4).flatMap(Int.init), let minute = group(5).flatMap(Int.init),
           let meridiem = group(6), (1...12).contains(hour) {
            if hour == 12 { hour = 0 }
            if meridiem == "PM" { hour += 12 }
            reset = Calendar(identifier: .gregorian).date(
                from: DateComponents(timeZone: .current, year: year, month: month, day: day, hour: hour, minute: minute))
                .flatMap { $0 > now ? $0 : nil }
        }
        return AgentUsageLimitStop(window: nil, resetsAt: reset)
    }

    private static let resetPattern = try! NSRegularExpression(
        pattern: #"^(?:([A-Z][a-z]{2})\s+(\d{1,2})\s+at\s+)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)$"#,
        options: [.caseInsensitive])

    /// `1:40am`, `12am`, `Nov 13 at 1am` in the CLI's stated zone → the next
    /// such instant (a bare time is the next occurrence after `now`).
    static func resetInstant(_ text: String, timeZoneName: String?, now: Date) -> Date? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = resetPattern.firstMatch(in: text, range: range) else { return nil }
        func group(_ i: Int) -> String? {
            guard let r = Range(match.range(at: i), in: text) else { return nil }
            return String(text[r])
        }
        guard let hourText = group(3), var hour = Int(hourText), (1...12).contains(hour),
              let meridiem = group(5)?.lowercased() else { return nil }
        let minute = group(4).flatMap(Int.init) ?? 0
        guard (0..<60).contains(minute) else { return nil }
        if hour == 12 { hour = 0 }
        if meridiem == "pm" { hour += 12 }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZoneName.flatMap(TimeZone.init(identifier:)) ?? .current
        if let monthName = group(1), let dayText = group(2), let day = Int(dayText) {
            let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
            guard let month = months.firstIndex(of: monthName.lowercased()).map({ $0 + 1 }) else { return nil }
            let year = calendar.component(.year, from: now)
            for candidateYear in [year, year + 1] {
                let parts = DateComponents(year: candidateYear, month: month, day: day, hour: hour, minute: minute)
                // A stated date already months past is next year's; one just
                // past is stale and says nothing about when room returns.
                guard let date = calendar.date(from: parts) else { continue }
                if date > now { return date }
                if date > now.addingTimeInterval(-86_400 * 180) { return nil }
            }
            return nil
        }
        // To the minute only: a reset minute that has just passed (the line
        // was written at 1:39:59 and read at 1:40:01) is this one, not tomorrow's.
        return calendar.nextDate(
            after: now.addingTimeInterval(-300), matching: DateComponents(hour: hour, minute: minute, second: 0),
            matchingPolicy: .nextTime)
    }
}


/// One agent held because its account ran out of usage: set by the supervisor
/// before the failure, notification and finished paths see the turn, cleared
/// on the first of its reset passing, a later success on the same account, or
/// a usage reading under 100%. Host-owned and in memory.
public struct AgentUsagePause: Equatable, Sendable {
    public var harness: AgentHarness
    /// The account the agent was signed in as when it stopped (the agent's
    /// own login, never "whichever account is active now").
    public var accountId: String?
    public var stop: AgentUsageLimitStop
    public var stoppedAt: Date
    /// When Array resumes it by itself; nil = resume when usage frees up.
    public var resetsAt: Date? { stop.resetsAt }
    /// Off: wait for a person (the tile's "Resume automatically" toggle).
    public var resumesAutomatically: Bool

    /// A window this full counts as used up. The design round read Codex's
    /// bucket at 99% at a stop; the diagnosis (83 stops, 2026-11-18) found the
    /// newest reading at 100% every time. 99% stays the line so a rounded
    /// reading never ends a pause early.
    public static let exhaustedFraction = 0.99
    /// A reading taken this soon after the stop is the stop's own reading.
    public static let readingSettleInterval: TimeInterval = 60

    /// A later reading of this pause's account says there is room again:
    /// taken after the stop settled, and every open window it states is under
    /// `exhaustedFraction`. A reading stating no percentage frees nothing.
    public func readingFreesUsage(_ quota: AgentAccountQuotaSnapshot, now: Date) -> Bool {
        guard quota.observedAt >= stoppedAt.addingTimeInterval(Self.readingSettleInterval) else { return false }
        let open = quota.windows.filter { !$0.isExpired(at: now) }
        let used = open.compactMap(\.utilization)
        guard !used.isEmpty, used.count == open.count else { return false }
        return used.allSatisfy { $0 < Self.exhaustedFraction }
    }

    public init(harness: AgentHarness, accountId: String?, stop: AgentUsageLimitStop,
                stoppedAt: Date, resumesAutomatically: Bool = true) {
        self.harness = harness
        self.accountId = accountId
        self.stop = stop
        self.stoppedAt = stoppedAt
        self.resumesAutomatically = resumesAutomatically
    }

    public var providerName: String {
        switch harness {
        case .claudeCode: return "Claude"
        case .codex: return "Codex"
        case .pi: return "Pi"
        }
    }

    /// "paused for Claude usage, Array resumes it at 10:20 PM": what its lead
    /// is told instead of "failed".
    public func leadStatus(timeZone: TimeZone = .current, now: Date = Date()) -> String {
        guard resumesAutomatically else { return "paused for \(providerName) usage; it resumes when someone resumes it" }
        guard let reset = resetsAt else { return "paused for \(providerName) usage; Array resumes it when usage frees up" }
        return "paused for \(providerName) usage; Array resumes it at \(Self.clock(reset, timeZone: timeZone, now: now))"
    }

    public static func clock(_ date: Date, timeZone: TimeZone = .current, now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        formatter.dateFormat = calendar.isDate(date, inSameDayAs: now) ? "h:mm a" : "MMM d, h:mm a"
        return formatter.string(from: date)
    }
}
