import Foundation
import ContinuumRevivedCore
import ContinuumRevivedCollaborationProtocol

private struct UsageCheckFailure: Error { let message: String }
func runSharedAreaUsageChecks() throws {
    func expect(_ value: Bool, _ message: String) throws {
        guard value else { throw UsageCheckFailure(message: message) }
        print("PASS durable usage: \(message)")
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("array-usage-check-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let host = SharedArea.ID<SharedArea.Host>()
    let ledger = try SharedAreaUsageLedger(directory: root, host: host)
    let day = Date(timeIntervalSince1970: 1_900_000_000)
    let freshHost = SharedArea.ID<SharedArea.Host>()
    let fresh = try SharedAreaUsageLedger(directory: root, host: freshHost)
    let waiting = try fresh.snapshot(coveredAgents: 1, runningAgents: 1, partial: true, at: day)
    _ = try fresh.record(.init(counter: "fresh-session", input: 40, output: 8, observedAt: day, initialBelongsToToday: true), at: day)
    let reporting = try fresh.snapshot(coveredAgents: 1, runningAgents: 0, partial: false, at: day)
    try expect(waiting.partial && !reporting.partial && reporting.todayInputTokens == 40,
        "temporary missing reporter clears when coverage becomes complete without erasing historical attribution gaps")
    let first = try ledger.record(.init(counter: "session-stable", input: 100, output: 20, observedAt: day, initialBelongsToToday: false), at: day)
    try expect(first.inputTokens == 100 && first.todayInputTokens == 0 && first.partial,
        "first cumulative session measurement retains reported total without inventing prior day attribution")
    let duplicate = try ledger.record(.init(counter: "session-stable", input: 100, output: 20, observedAt: day, initialBelongsToToday: false), at: day)
    try expect(duplicate.sequence == first.sequence && duplicate.inputTokens == first.inputTokens,
        "duplicate measurements and duplicate views create no new accounting write or tokens")
    let next = day.addingTimeInterval(5)
    _ = try ledger.record(.init(counter: "session-stable", input: 160, output: 45, observedAt: next, initialBelongsToToday: false), at: next)
    let reopened = try SharedAreaUsageLedger(directory: root, host: host)
    let afterRestart = try reopened.snapshot(coveredAgents: 1, runningAgents: 1, at: next)
    try expect(afterRestart.inputTokens == 160 && afterRestart.outputTokens == 45
        && afterRestart.todayInputTokens == 60 && afterRestart.todayOutputTokens == 25,
        "cold restart retains exact cumulative high-water and daily deltas")
    let older = try reopened.record(.init(counter: "session-stable", input: 120, output: 30, observedAt: day, initialBelongsToToday: false), at: next)
    try expect(older.inputTokens == 160 && older.sequence == afterRestart.sequence,
        "reordered older cumulative reports cannot subtract or add usage")
    let turn = try reopened.record(.init(counter: "claude-turn-1", input: 50, output: 9, observedAt: next, initialBelongsToToday: true), at: next)
    let message = try reopened.record(.init(counter: "pi-message-1", input: 25, output: 4, observedAt: next, initialBelongsToToday: true), at: next)
    let corrected = try reopened.record(.init(counter: "pi-message-1", input: 30, output: 5, observedAt: next, initialBelongsToToday: true), at: next)
    try expect(turn.inputTokens == 210 && message.inputTokens == 235 && corrected.inputTokens == 240
        && corrected.todayInputTokens == 140, "distinct turns/messages sum, while corrected message accounting adds only its delta")
    let tomorrow = next.addingTimeInterval(86_400)
    let rollover = try reopened.snapshot(coveredAgents: 1, runningAgents: 0, at: tomorrow)
    try expect(rollover.inputTokens == 240 && rollover.todayInputTokens == 0 && rollover.dayUTC != corrected.dayUTC,
        "UTC day rollover preserves reported lifetime total and resets only current-day observations")
    let repeated = try reopened.snapshot(coveredAgents: 1, runningAgents: 0, at: tomorrow)
    try expect(repeated.sequence == rollover.sequence && repeated.valid, "idle hover reads do not mutate durable accounting")
    let encoded = String(decoding: try JSONEncoder().encode(repeated), as: UTF8.self)
    try expect(!encoded.contains("session-stable") && !encoded.contains("pi-message") && !encoded.contains("rootPath"),
        "portable usage excludes private counter identities, prompts and local paths")
    let directory = root.appendingPathComponent("usage-\(host.rawValue.uuidString)")
    let file = directory.appendingPathComponent("ledger.json")
    let original = try Data(contentsOf: file)
    try Data("not-json".utf8).write(to: file)
    do { _ = try reopened.snapshot(coveredAgents: 1, runningAgents: 0, at: tomorrow); throw UsageCheckFailure(message: "corrupt ledger was overwritten") }
    catch SharedAreaUsageLedger.Failure.corrupt { print("PASS durable usage: corrupt ledger refuses instead of resetting reported totals") }
    try expect(try Data(contentsOf: file) == Data("not-json".utf8), "corruption failure preserves original bytes")
    try original.write(to: file)
    var future = try JSONSerialization.jsonObject(with: original) as! [String: Any]
    future["schema"] = 99
    let bytes = try JSONSerialization.data(withJSONObject: future)
    try bytes.write(to: file)
    do { _ = try reopened.snapshot(coveredAgents: 1, runningAgents: 0, at: tomorrow); throw UsageCheckFailure(message: "future ledger was overwritten") }
    catch SharedAreaUsageLedger.Failure.changedScope { print("PASS durable usage: future accounting schema refuses") }
    try expect(try Data(contentsOf: file) == bytes, "future schema refusal preserves bytes")
}
