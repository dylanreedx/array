import ContinuumRevivedCore
import Foundation

/// Usage stops, step 1 of the usage-resume build plan
/// (`~/array-scratch/sidebar-round/status-redesign/README.md`).
///
/// Before this, Claude's usage stop ("You've hit your 5-hour limit · resets
/// 6:20pm (America/Toronto)") matched none of `AgentFailureText`'s markers, so
/// every such turn read "Claude Code reported an error without details", and a
/// lead was told its helper failed. The `rejected` rate-limit reading stated
/// no percentage, so the account never read 100%.
///
/// Drives the production translators over `Fixtures/claude-usage-limit-rejected.jsonl`
/// (INFERRED — see the `.md` beside it) and Codex's real app-server stop shape.
func runAgentUsageLimitChecks() {
    let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures", isDirectory: true)
    guard let text = try? String(contentsOf: fixtures.appendingPathComponent("claude-usage-limit-rejected.jsonl"), encoding: .utf8) else {
        fputs("FAIL: usage-limit fixture missing\n", stderr); Foundation.exit(1)
    }
    let frames = text.split(separator: "\n").map(String.init)
    let line = "You've hit your 5-hour limit · resets 6:20pm (America/Toronto)"
    // 2026-11-18 15:00 Toronto: the stop happened earlier today.
    let now = Date(timeIntervalSince1970: 1_795_032_000)
    var toronto = Calendar(identifier: .gregorian)
    toronto.timeZone = TimeZone(identifier: "America/Toronto")!

    final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [AgentAccountQuotaSnapshot] = []
        func append(_ o: AgentRuntimeObservation) {
            guard case let .accountQuota(s) = o else { return }
            lock.lock(); values.append(s); lock.unlock()
        }
        var all: [AgentAccountQuotaSnapshot] { lock.lock(); defer { lock.unlock() }; return values }
    }
    func terminal(_ events: [AgentRuntimeEvent]) -> (TurnOutcome, String?)? {
        for event in events.reversed() {
            if case let .turnCompleted(_, _, outcome, message) = event { return (outcome, message) }
        }
        return nil
    }

    // 1. The whole stop: the CLI's own line survives as the turn's error.
    let sink = Sink()
    var translator = ClaudeEventTranslator(runToken: "usage-limit", now: { now })
    translator.onRuntimeObservation = { sink.append($0) }
    let ended = terminal(translator.translate(stream: frames))
    expect(ended?.0 == .failed && ended?.1 == line,
           "usage-limit: a Claude usage stop must end with the CLI's own line, got \(String(describing: ended))")
    expect(ended?.1?.contains("without details") != true, "usage-limit: never 'reported an error without details'")
    let stop = AgentUsageLimitStop.classify(errorMessage: ended?.1, now: now)
    expect(stop?.window == "5-hour", "usage-limit: the line names the 5-hour window, got \(String(describing: stop))")
    expect(stop?.resetsAt.map { toronto.dateComponents([.hour, .minute], from: $0) == DateComponents(hour: 18, minute: 20) && $0 > now } == true,
           "usage-limit: the line resets at the next 6:20 pm Toronto, got \(String(describing: stop?.resetsAt))")
    // The rejected reading IS 100% of its window, with the CLI's reset.
    let rejected = sink.all.last?.windows.first
    expect(rejected?.kind == .fiveHour && rejected?.utilization == 1.0
           && rejected?.resetsAt == Date(timeIntervalSince1970: 1_794_957_600),
           "usage-limit: a rejected rate_limit_event must read 100% of five_hour with its resetsAt, got \(String(describing: rejected))")

    // 2. Structured signal only: an empty result after a rejected event and an
    //    error-tagged frame with no sentence still reads as a usage stop.
    var bare = ClaudeEventTranslator(runToken: "usage-bare", now: { now })
    let bareFrames = [frames[0], frames[1],
        #"{"type":"assistant","message":{"id":"m2","model":"<synthetic>","role":"assistant","content":[]},"parent_tool_use_id":null,"session_id":"s","error":"rate_limit"}"#,
        #"{"type":"result","subtype":"success","is_error":true,"result":"","session_id":"s"}"#]
    let bareEnd = terminal(bare.translate(stream: bareFrames))
    expect(bareEnd?.1 == AgentUsageLimitStop.claudeStructuredLine
           && AgentUsageLimitStop.classify(errorMessage: bareEnd?.1, now: now) != nil,
           "usage-limit: a rejected stop with no sentence must still be a usage stop, got \(String(describing: bareEnd))")
    var eventOnly = ClaudeEventTranslator(runToken: "usage-event", now: { now })
    let eventEnd = terminal(eventOnly.translate(stream: [frames[0], frames[1],
        #"{"type":"result","subtype":"success","is_error":true,"session_id":"s"}"#]))
    expect(eventEnd?.1 == AgentUsageLimitStop.claudeStructuredLine,
           "usage-limit: rate_limit_event status rejected alone must classify the stop, got \(String(describing: eventEnd))")

    // 3. A stop from an earlier run never names the next run's failure.
    var reused = ClaudeEventTranslator(runToken: "usage-reuse", now: { now })
    _ = reused.translate(stream: [frames[0], frames[1], frames[2]])
    let nextEnd = terminal(reused.translate(stream: [frames[0],
        #"{"type":"result","subtype":"error_max_turns","is_error":true,"session_id":"s"}"#]))
    expect(nextEnd?.1 == "error_max_turns", "usage-limit: a stale stop leaked into the next run, got \(String(describing: nextEnd))")

    // 4. The weekly line, and the failure-text recogniser keeps every form.
    for weekly in ["You've hit your weekly limit · resets Nov 13 at 1am (America/Toronto)",
                   "You’ve hit your session limit · resets 3:40am (America/Toronto)",
                   "You've hit your limit · resets 1:20 AM (America/Toronto)"] {
        // Kept (bounded and redacted like every provider line), never dropped.
        expect(AgentFailureText.providerMessage(weekly)?.contains("limit") == true, "usage-limit: providerMessage dropped \(weekly)")
        expect(AgentUsageLimitStop.classify(errorMessage: weekly, now: Date(timeIntervalSince1970: 1_794_000_000)) != nil,
               "usage-limit: \(weekly) is a usage stop")
    }

    // 5. Codex: the real `task_complete` stop (rollout 2026-11-16T14:38:47Z),
    //    on the app-server transport Array runs.
    let codexLine = "You’ve hit your usage limit. Visit https://chatgpt.com/settings/usage to purchase more credits or try again at Nov 19th, 2026 12:27 PM."
    func codexEnd(_ error: [String: Any]) -> (TurnOutcome, String?)? {
        var codex = CodexAppServerEventTranslator(now: { now })
        let frame: [String: Any] = ["method": "turn/completed", "params": [
            "threadId": "t1", "turn": ["id": "turn-1", "status": "failed", "error": error]]]
        let data = try! JSONSerialization.data(withJSONObject: frame)
        return terminal(codex.translate(line: String(decoding: data, as: UTF8.self)))
    }
    let codexStop = codexEnd(["message": codexLine, "codexErrorInfo": "usageLimitExceeded"])
    let codexClassified = AgentUsageLimitStop.classify(errorMessage: codexStop?.1, now: now)
    expect(codexStop?.1 == codexLine && codexClassified?.resetsAt.map {
        Calendar.current.dateComponents([.month, .day, .hour, .minute], from: $0) == DateComponents(month: 11, day: 19, hour: 12, minute: 27)
    } == true, "usage-limit: Codex's stop keeps its sentence and its retry time, got \(String(describing: codexStop))")
    for info in ["usage_limit_exceeded", "usageLimitExceeded"] as [Any] {
        let codeOnly = codexEnd(["codexErrorInfo": info])
        expect(AgentUsageLimitStop.classify(errorMessage: codeOnly?.1, now: now) != nil,
               "usage-limit: Codex codexErrorInfo \(info) alone is a usage stop, got \(String(describing: codeOnly))")
    }
    let objectInfo = codexEnd(["codexErrorInfo": ["usageLimitExceeded": [:] as [String: Any]]])
    expect(AgentUsageLimitStop.classify(errorMessage: objectInfo?.1, now: now) != nil,
           "usage-limit: Codex's keyed codexErrorInfo is a usage stop, got \(String(describing: objectInfo))")

    // 6. Counting: Codex's `premium` bucket is not the account's reading
    //    (real frame from the rollouts, camel-cased as app-server sends it),
    //    and a reading with no windows never blanks the windows before it.
    let premium: [String: Any] = ["limitId": "premium", "limitName": NSNull(), "primary": NSNull(), "secondary": NSNull(),
                                  "credits": ["hasCredits": false, "unlimited": false, "balance": "0"]]
    expect(AgentAccountQuota.codexSnapshot(rateLimits: premium, observedAt: now) == nil,
           "usage-limit: Codex's premium bucket must not read as the account's allowance")
    let spent: [String: Any] = ["limitId": "codex", "primary": ["usedPercent": 100, "windowDurationMins": 10080, "resetsAt": 1_795_400_000]]
    let codexReading = AgentAccountQuota.codexSnapshot(rateLimits: spent, observedAt: now)
    expect(codexReading?.windows.first?.utilization == 1.0, "usage-limit: the codex bucket still reads, got \(String(describing: codexReading))")
    let creditsOnly = AgentAccountQuotaSnapshot(harness: .codex, windows: [],
        credits: AgentQuotaCredits(balance: "0", hasCredits: false), observedAt: now.addingTimeInterval(5), source: .codexAccountRateLimits)
    let kept = creditsOnly.replacing(codexReading)
    expect(kept.windows == codexReading?.windows && kept.credits?.balance == "0",
           "usage-limit: a credits-only reading must keep the spent window, got \(kept)")

    // 7. Not usage stops.
    for other in ["API Error: 429 rate limited", "Claude Code reported an error without details.",
                  "I think you've hit your limit · resets 1am", "error_max_turns", "serverOverloaded"] {
        expect(AgentUsageLimitStop.classify(errorMessage: other, now: now) == nil, "usage-limit: \(other) is not a usage stop")
    }
    print("agent-usage-limit-check: PASS")
}
