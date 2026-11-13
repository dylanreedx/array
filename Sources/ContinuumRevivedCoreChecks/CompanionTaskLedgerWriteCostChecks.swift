import Foundation
import ContinuumRevivedCore

private struct LedgerWriteCostFailure: Error, CustomStringConvertible { let description: String }
private func writeCostExpect(_ condition: Bool, _ message: String) throws {
    if !condition { throw LedgerWriteCostFailure(description: message) }
}

/// Live-usage profile, 2026-11-11 (.plans/110-native-refresh-inventory/MORNING.md):
/// every agent turn start and finish rewrote the whole phone-task ledger on the
/// main thread — encode, write, decode to verify — and the ledger in Dylan's app
/// was 4.5 MB (2,821 tasks, 6,945 runs). A turn event changes one run.
///
/// The witness seeds a ledger of that size, drives turn events through the
/// public API production calls, and asserts the base file is not rewritten while
/// every change still survives a reopen, including a torn journal tail.
func runCompanionTaskLedgerWriteCostChecks() throws -> String {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("array-task-ledger-cost-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appendingPathComponent("companion-tasks", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let base = directory.appendingPathComponent("ledger.json")
    try seededLedger(tasks: 2_800, runsPerTask: 2).write(to: base)
    let seededBytes = try Data(contentsOf: base).count

    let ledger = try CompanionTaskLedger(applicationSupportDirectory: root)
    let before = try Data(contentsOf: base)
    let agents = (0..<10).map { _ in UUID() }
    var changes = 0
    let started = Date()
    for (index, agent) in agents.enumerated() {
        let run = try ledger.begin(agentID: agent)
        try ledger.observe(.turnStarted(threadId: "t", turnId: "turn-\(index)"), run: run)
        try ledger.observe(.turnCompleted(threadId: "t", turnId: "turn-\(index)", outcome: .completed, errorMessage: nil), run: run)
        changes += 3
    }
    let perChange = Date().timeIntervalSince(started) * 1_000 / Double(changes)
    let after = try Data(contentsOf: base)
    try writeCostExpect(after == before,
        "\(changes) turn changes rewrote the \(seededBytes / 1024) KB ledger (\(String(format: "%.1f", perChange)) ms per change) — a turn event must commit only what it changed")

    // Durability: a reopen sees exactly what the live ledger publishes.
    let live = try ledger.snapshot()
    let reopened = try CompanionTaskLedger(applicationSupportDirectory: root).snapshot()
    try writeCostExpect(reopened == live, "a reopened ledger lost journaled turn changes")
    try writeCostExpect(live.tasks.contains { task in task.members.contains { $0.agentID == agents[9] && $0.state == .succeeded } },
        "the last journaled completion is missing from the published batch")

    // A torn tail (a crash mid-append) is a change that never committed.
    let second = try CompanionTaskLedger(applicationSupportDirectory: root)
    let survivor = try second.begin(agentID: UUID())
    try second.observe(.turnStarted(threadId: "t", turnId: "survivor"), run: survivor)
    // Settled, because a reopen rightly turns a still-running run into unknown.
    try second.observe(.turnCompleted(threadId: "t", turnId: "survivor", outcome: .completed, errorMessage: nil), run: survivor)
    let expected = try second.snapshot()
    let journal = directory.appendingPathComponent("ledger.journal")
    let handle = try FileHandle(forWritingTo: journal)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("{\"revision\":99999999,\"publisherID\":\"".utf8))
    try handle.close()
    let afterTear = try CompanionTaskLedger(applicationSupportDirectory: root).snapshot()
    try writeCostExpect(afterTear == expected, "a torn journal tail changed the restored ledger")

    return String(format: "CompanionTaskLedgerWriteCostChecks passed: %d turn changes on a %d KB ledger left the base file untouched (%.2f ms per change); reopen and torn-tail restore match the live batch",
                  changes, seededBytes / 1024, perChange)
}

/// A settled history in the ledger's own on-disk shape (UUID-keyed dictionaries
/// encode as alternating key/value arrays).
private func seededLedger(tasks: Int, runsPerTask: Int) throws -> Data {
    var taskEntries: [Any] = []
    var runEntries: [Any] = []
    var current: [Any] = []
    let touched = Date().timeIntervalSince1970 - 2 * 24 * 3600
    for index in 0..<tasks {
        let task = UUID(), agent = UUID()
        var root: UUID?
        for runIndex in 0..<runsPerTask {
            let run = UUID()
            if root == nil { root = run }
            runEntries.append(run.uuidString)
            runEntries.append([
                "task": task.uuidString,
                "member": ["agentID": agent.uuidString, "runID": run.uuidString, "state": "succeeded"],
                "providerTurn": "\(agent.uuidString.lowercased())#\(runIndex)-t1",
                "pendingRequests": [String: String](),
                "observed": false, "queued": false, "appliedToParent": false,
            ] as [String: Any])
            if runIndex == runsPerTask - 1 { current.append(agent.uuidString); current.append(run.uuidString) }
        }
        taskEntries.append(task.uuidString)
        taskEntries.append([
            "root": root!.uuidString, "complete": true, "createdRevision": index,
            "admissions": [String](), "unknownBackground": [String](), "unknownProviderRuns": [String](),
            "touchedAt": touched,
        ] as [String: Any])
    }
    let file: [String: Any] = [
        "version": 1, "publisherID": UUID().uuidString, "revision": tasks * 3,
        "tasks": taskEntries, "runs": runEntries, "current": current, "observations": [String: String](),
    ]
    return try JSONSerialization.data(withJSONObject: file, options: [.prettyPrinted])
}
