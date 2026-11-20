import ContinuumRevivedCore
import Foundation

/// Restore replays every finished run through the companion ledger. The witness:
/// a batch of changes is ONE commit, and it leaves the same ledger (in memory and
/// after a reopen from disk) as committing each change alone.
/// RED with `CONTINUUM_LEGACY_LEDGER_BATCH=1`, GREEN without.
enum LedgerBatchChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }

    private static func states(_ ledger: CompanionTaskLedger) throws -> [String] {
        try ledger.snapshot().tasks.flatMap(\.members).map { "\($0.agentID)=\($0.state.rawValue)" }.sorted()
    }

    /// Returns (commits used by the replay, final states, states after reopening).
    private static func scenario(agents: [UUID], batched: Bool) throws -> (Int, [String], [String]) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-batch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = try CompanionTaskLedger(applicationSupportDirectory: root)
        var runs: [UUID: CompanionTaskRunHandle] = [:]
        for agent in agents { runs[agent] = try ledger.begin(agentID: agent) }
        let before = ledger.commitsForQA
        func replay() {
            for (index, agent) in agents.enumerated() {
                guard let run = ledger.currentRun(agentID: agent) ?? runs[agent] else { continue }
                let outcome: TurnOutcome = index % 3 == 0 ? .interrupted : .completed
                try? ledger.observe(.turnStarted(threadId: "t", turnId: "u\(index)"), run: run)
                try? ledger.observe(.turnCompleted(threadId: "t", turnId: "u\(index)", outcome: outcome, errorMessage: nil), run: run)
            }
        }
        if batched { try ledger.batch(replay) } else { replay() }
        let used = ledger.commitsForQA - before
        let live = try states(ledger)
        let reopened = try states(try CompanionTaskLedger(applicationSupportDirectory: root))
        return (used, live, reopened)
    }

    static func run() throws {
        let agents = (0..<150).map { _ in UUID() }
        let (commits, live, reopened) = try scenario(agents: agents, batched: true)
        print("commits for a 300-event replay: \(commits)")
        let (_, plainLive, plainReopened) = try scenario(agents: agents, batched: false)
        // Agent ids differ between scenarios only by position, so compare the multiset of states.
        func shape(_ rows: [String]) -> [String] { rows.map { String($0.split(separator: "=").last ?? "") }.sorted() }
        guard shape(live) == shape(plainLive) else { throw Failure(description: "a batch left a different ledger than one commit per change") }
        guard shape(reopened) == shape(live), shape(plainReopened) == shape(plainLive) else {
            throw Failure(description: "a ledger reopened from disk differs from the one that wrote it")
        }
        guard commits <= 1 else { throw Failure(description: "\(commits) commits for one batch of changes") }
    }
}
