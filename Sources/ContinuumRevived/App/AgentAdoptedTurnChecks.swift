import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Foundation

// `.plans/102` — the PARENT's side of a background subagent's hand-back.
//
// A managed claude agent runs one long-lived `claude -p --input-format
// stream-json` process. When a turn launches a BACKGROUND subagent, claude ends
// that turn with its first `result`; when the child reports back, claude opens
// its OWN next turn with a fresh `system`/`init` and a second `result` carrying
// the answer. `ClaudeAgentRunner.handleLine` buffers that init as an unsolicited
// turn and `AgentSupervisor.adoptUnsolicitedTurn` binds it like any other turn.
//
// The child's lifetime across this is witnessed elsewhere
// (`AgentPresenceChecks.checkMirroredBackgroundChildLifetime`). This watches the
// parent: the production runner and supervisor against the fake claude
// replaying a REAL claude 2.1.312 stream
// (`Fixtures/claude-background-result-turn.jsonl`, from
// `.plans/102-managed-agent-mode/p0-claude-evidence/p7-persistent-background`),
// with a real tile attached.
@MainActor
func runAgentAdoptedTurnChecks() async throws -> String {
    struct Failure: Error, CustomStringConvertible { let description: String }
    func expect(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        if !condition { throw Failure(description: "adopted-turn: " + message()) }
    }

    let launched = "LAUNCHED"
    let answer = "The background agent finished. The three words in notes.txt are **alpha, bravo, charlie**.\n\nThe agent first ran the sleep and the read in parallel, so that first read may have happened before the 20 seconds were up. It then re-read the file after the sleep and got the same contents, so the result should hold."
    // The child's own last message: it belongs to the child, never the parent.
    let childPhrase = "I first ran the sleep"

    let originalPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
    defer { setenv("PATH", originalPath, 1) }
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("ContinuumRevivedCoreChecks/Fixtures/claude-background-result-turn.jsonl")
    let bench = try AgentPresenceChecks.Bench(.claude, originalPath: originalPath)
    defer { bench.tearDown() }
    try FileManager.default.copyItem(at: fixture, to: bench.bin.appendingPathComponent("replay.jsonl"))
    let supervisor = bench.supervisor
    let parent = bench.id

    // Sampled as each parent event is delivered, on the main actor, after the
    // supervisor has applied it: the status every surface derives, and at each
    // completion the final text that completion carries.
    var statuses: [AgentStatus] = []
    var completions: [(turnID: String, outcome: TurnOutcome, finalText: String?, sequence: UInt64?)] = []
    var starts: [String] = []
    let observer = supervisor.addDeliveredEventObserver { id, event in
        guard id == parent else { return }
        let status = supervisor.derivedStreamStatus(for: parent)
        if statuses.last != status { statuses.append(status) }
        switch event {
        case let .turnStarted(_, turnID):
            starts.append(turnID)
        case let .turnCompleted(_, turnID, outcome, _):
            completions.append((turnID, outcome, supervisor.qaFinalAssistantText(for: parent),
                                supervisor.records[parent]?.latestTerminalEvent?.sequence))
        default:
            break
        }
    }
    defer { supervisor.removeDeliveredEventObserver(observer) }

    try expect(supervisor.send("REPLAY", to: parent), "the parent refused the prompt")
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline, completions.count < 2 || supervisor.isRunning(parent) {
        try await Task.sleep(for: .milliseconds(20))
    }
    // Long enough for a doubled turn or a stray re-completion to show.
    try await Task.sleep(for: .milliseconds(800))

    let completionSummary = completions.map { "\($0.turnID):\($0.outcome)" }
    try expect(completions.count == 2,
        "claude's own second turn (the background child's hand-back) was not adopted as a second turn: \(completions.count) completion(s) \(completionSummary), statuses \(statuses)")
    try expect(starts.count == 2, "expected two turn starts on the parent, got \(starts)")
    try expect(completions.allSatisfy { $0.outcome == .completed },
        "a parent turn did not complete cleanly: \(completionSummary)")
    try expect(Set(completions.map(\.turnID)).count == 2,
        "the two completions share a turn id — one turn reported twice: \(completionSummary)")
    try expect(statuses.filter { $0 == .working || $0 == .done } == [.working, .done, .working, .done],
        "the parent's status did not read working → done → working → done: \(statuses)")
    try expect(statuses.last == .done, "the parent did not end Done: \(statuses)")
    try expect(completions[0].finalText == launched,
        "the first completion carried \(String(describing: completions[0].finalText)), not the launching turn's \(launched)")
    try expect(completions[1].finalText == answer,
        "the second completion did not carry the background child's answer: \(String(describing: completions[1].finalText))")
    if let first = completions[0].sequence, let second = completions[1].sequence {
        try expect(second > first, "the second turn's terminal event did not advance past the first (\(first) → \(second))")
    } else {
        throw Failure(description: "adopted-turn: a completion left no terminal event on the parent's record")
    }
    try expect(!supervisor.isRunning(parent) && supervisor.turnSnapshot(for: parent)?.state == .ready,
        "the parent did not settle Ready after the adopted turn (running \(supervisor.isRunning(parent)), state \(String(describing: supervisor.turnSnapshot(for: parent)?.state)))")
    try expect(bench.spawns == 1, "the adopted turn restarted claude: \(bench.spawns) spawns for one session")

    // What the user reads: the tile's own transcript, each answer exactly once,
    // in order, and none of the child's words on the parent.
    let assistant = bench.entryTexts(role: .assistant)
    let launchedEntries = assistant.indices.filter { assistant[$0].contains(launched) }
    let answerEntries = assistant.indices.filter { assistant[$0].contains("The background agent finished") }
    try expect(launchedEntries.count == 1,
        "the tile shows the first answer \(launchedEntries.count) times: \(assistant)")
    try expect(answerEntries.count == 1,
        "the tile shows the background answer \(answerEntries.count) times: \(assistant)")
    try expect(launchedEntries[0] < answerEntries[0], "the tile shows the answers out of order: \(assistant)")
    try expect(!assistant.contains { $0.contains(childPhrase) },
        "the child's own message leaked into the parent's transcript: \(assistant)")
    // The tile header presents the supervisor's settled Ready snapshot as idle
    // (`AgentTileStatePresenter`); "done" is the stream's status above. What
    // must not happen is the header left Working after the adopted turn ended.
    try await AgentPresenceChecks.eventually("the tile header did not settle after the adopted turn (\(bench.tile.currentAgentStatus))") {
        bench.tile.currentAgentStatus == .idle
    }

    return "a background child's hand-back is adopted as the parent's own second turn: working → done → working → done, two completions, the second carrying the new answer, the first unchanged, nothing doubled (stream statuses \(statuses))"
}
