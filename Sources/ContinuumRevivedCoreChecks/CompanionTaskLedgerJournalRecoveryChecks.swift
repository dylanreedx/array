import Darwin
import Foundation
import ContinuumRevivedCore

private struct LedgerJournalRecoveryFailure: Error, CustomStringConvertible { let description: String }
private func recoveryExpect(_ condition: Bool, _ message: String) throws {
    if !condition { throw LedgerJournalRecoveryFailure(description: message) }
}

/// Release review for 0.7.48: launch replays the last session's journal into
/// memory, then commits its restart changes (running → unknown) before the base
/// holds the replayed state. A failed or short startup append used to trim the
/// journal back to this session's byte count — zero — erasing every committed
/// line, so the next launch lost those tasks and runs.
///
/// The fault is real, not a hook: RLIMIT_FSIZE caps how far this process may
/// write into any file, so the startup append comes up short as it would on a
/// full disk.
/// Each arm leaves a populated journal, opens the ledger under the cap (which may
/// throw), lifts the cap, reopens, and asserts every committed task and run.
func runCompanionTaskLedgerJournalRecoveryChecks() throws -> String {
    var outcomes: [String] = []
    // Arm 1: the whole history lives in the journal.
    outcomes.append(try recoveryArm(name: "journal-only history", compactFirst: false))
    // Arm 2: a compacted base plus a small journal.
    outcomes.append(try recoveryArm(name: "base plus journal", compactFirst: true))
    outcomes.append(try inSessionArm())
    outcomes.append(try damagedLineArm())
    outcomes.append(try unreadableJournalArm())
    return "CompanionTaskLedgerJournalRecoveryChecks passed: " + outcomes.joined(separator: "; ")
}

private func recoveryArm(name: String, compactFirst: Bool) throws -> String {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("array-task-ledger-recovery-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let journal = root.appendingPathComponent("companion-tasks/ledger.journal")
    var ledger = try CompanionTaskLedger(applicationSupportDirectory: root)
    try settle(ledger, count: 12, tag: "early")
    if compactFirst {
        // Launch folds the journal into the base; this session journals only the rest.
        ledger = try CompanionTaskLedger(applicationSupportDirectory: root)
        try settle(ledger, count: 2, tag: "late")
    }
    // A run still going at quit: the next launch must commit it as unknown, so
    // the startup path has a change to write.
    let live = try ledger.begin(agentID: UUID())
    try ledger.observe(.turnStarted(threadId: "t", turnId: "live"), run: live)
    let committed = try ledger.snapshot()
    let journalBefore = try Data(contentsOf: journal)
    try recoveryExpect(!journalBefore.isEmpty, "\(name): the arm needs a populated journal to test")

    // macOS measures an O_APPEND write on a fresh descriptor from offset zero,
    // so a cap shorter than one journal line makes the startup append short
    // (64 bytes land, the rest do not) however long the journal already is.
    let threw = try withFileSizeCap(64) {
        do { _ = try CompanionTaskLedger(applicationSupportDirectory: root); return false } catch { return true }
    }

    let reopened = try CompanionTaskLedger(applicationSupportDirectory: root).snapshot()
    let wantTasks = Set(committed.tasks.map(\.taskID)), haveTasks = Set(reopened.tasks.map(\.taskID))
    let wantRuns = Set(committed.tasks.flatMap { $0.members.map(\.runID) })
    let haveRuns = Set(reopened.tasks.flatMap { $0.members.map(\.runID) })
    try recoveryExpect(wantTasks.isSubset(of: haveTasks) && wantRuns.isSubset(of: haveRuns),
        "\(name): a failed startup write lost \(wantTasks.subtracting(haveTasks).count) of \(wantTasks.count) committed tasks and \(wantRuns.subtracting(haveRuns).count) of \(wantRuns.count) runs (startup \(threw ? "threw" : "succeeded"))")
    let settledBefore = committed.tasks.flatMap(\.members).filter { $0.state == .succeeded }.map(\.runID)
    let settledAfter = Set(reopened.tasks.flatMap(\.members).filter { $0.state == .succeeded }.map(\.runID))
    try recoveryExpect(settledAfter.isSuperset(of: settledBefore), "\(name): a committed completion did not survive the failed startup write")
    try recoveryExpect(reopened.tasks.flatMap(\.members).first { $0.runID == live.runID }?.state == .unknown,
        "\(name): the run live at quit must restore as unknown, never as finished")
    return "\(name) — startup \(threw ? "threw" : "succeeded"), \(wantTasks.count) tasks and \(wantRuns.count) runs restored"
}

/// A short append in a running session fails its change and keeps every
/// committed byte. Under the cap the kernel also refuses the trim back, as a
/// failing disk can, so the torn tail stays; the next change must still commit
/// and survive a reopen rather than glue itself to that tail.
private func inSessionArm() throws -> String {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("array-task-ledger-recovery-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let journal = root.appendingPathComponent("companion-tasks/ledger.journal")
    let ledger = try CompanionTaskLedger(applicationSupportDirectory: root)
    try settle(ledger, count: 6, tag: "session")
    let committed = try ledger.snapshot()
    let journalBefore = try Data(contentsOf: journal)
    let threw = try withFileSizeCap(64) {
        do { _ = try ledger.begin(agentID: UUID()); return false } catch { return true }
    }
    try recoveryExpect(threw, "in-session: a short append must fail its change")
    try recoveryExpect(try ledger.snapshot() == committed, "in-session: a failed append changed in-memory task truth")
    try recoveryExpect(try Data(contentsOf: journal).starts(with: journalBefore), "in-session: a failed append cut committed journal bytes")
    try settle(ledger, count: 1, tag: "after")
    let live = try ledger.snapshot()
    let reopened = try CompanionTaskLedger(applicationSupportDirectory: root).snapshot()
    try recoveryExpect(reopened == live, "in-session: the change after a failed append did not survive a reopen")
    return "in-session short append — committed bytes kept, next change restored"
}

/// Review of the fix: a line holds only the keys it changed, so replaying past a
/// damaged line rebuilds runs and tasks half-way over the gap. A damaged line in
/// the middle stops replay there and the journal is set aside, never deleted; a
/// torn last line (a crash mid-append) is dropped quietly.
private func damagedLineArm() throws -> String {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("array-task-ledger-recovery-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appendingPathComponent("companion-tasks")
    let journal = directory.appendingPathComponent("ledger.journal")
    func setAside() throws -> [Data] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("ledger.journal.damaged-") }
            .map { try Data(contentsOf: directory.appendingPathComponent($0)) }
    }
    func runIDs(_ batch: CompanionTaskSnapshotBatch) -> [UUID: CompanionTaskRunState] {
        Dictionary(batch.tasks.flatMap(\.members).map { ($0.runID, $0.state) }, uniquingKeysWith: { $1 })
    }

    let ledger = try CompanionTaskLedger(applicationSupportDirectory: root)
    let a = try ledger.begin(agentID: UUID())
    try ledger.observe(.turnStarted(threadId: "t", turnId: "a"), run: a)
    try ledger.observe(.turnCompleted(threadId: "t", turnId: "a", outcome: .completed, errorMessage: nil), run: a)
    let damagedIndex = try Data(contentsOf: journal).split(separator: UInt8(ascii: "\n")).count
    let b = try ledger.begin(agentID: UUID())
    try ledger.observe(.turnStarted(threadId: "t", turnId: "b"), run: b)
    try ledger.observe(.turnCompleted(threadId: "t", turnId: "b", outcome: .completed, errorMessage: nil), run: b)
    let c = try ledger.begin(agentID: UUID())
    try ledger.observe(.turnStarted(threadId: "t", turnId: "c"), run: c)
    var lines = try Data(contentsOf: journal).split(separator: UInt8(ascii: "\n")).map { Data($0) }
    try recoveryExpect(lines.count > damagedIndex + 2, "damaged line: the arm needs lines after the one it damages")
    lines[damagedIndex] = Data("{\"revision\":".utf8)
    var damaged = Data(lines.joined(separator: [UInt8(ascii: "\n")]))
    damaged.append(UInt8(ascii: "\n"))
    try damaged.write(to: journal)

    let reopened: CompanionTaskLedger
    do { reopened = try CompanionTaskLedger(applicationSupportDirectory: root) }
    catch { throw LedgerJournalRecoveryFailure(description: "damaged line: launch must go on past a damaged journal, but threw \(error)") }
    let runs = runIDs(try reopened.snapshot())
    try recoveryExpect(runs[a.runID] == .succeeded, "damaged line: a change before the damage did not survive")
    try recoveryExpect(runs[b.runID] == nil && runs[c.runID] == nil,
        "damaged line: replay applied changes over the damaged line (rebuilt \([b.runID, c.runID].filter { runs[$0] != nil }.count) of 2 runs past the gap)")
    try recoveryExpect(try setAside() == [damaged], "damaged line: the damaged journal was not set aside byte for byte")

    // A torn last line is the normal crash shape: dropped quietly, nothing set aside.
    let d = try reopened.begin(agentID: UUID())
    try reopened.observe(.turnStarted(threadId: "t", turnId: "d"), run: d)
    try reopened.observe(.turnCompleted(threadId: "t", turnId: "d", outcome: .completed, errorMessage: nil), run: d)
    let handle = try FileHandle(forWritingTo: journal)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("{\"revision\":".utf8))
    try handle.close()
    let afterTear = runIDs(try CompanionTaskLedger(applicationSupportDirectory: root).snapshot())
    try recoveryExpect(afterTear[d.runID] == .succeeded && afterTear[a.runID] == .succeeded, "torn tail: a committed change did not survive")
    try recoveryExpect(try setAside().count == 1, "torn tail: a crash mid-append must not be set aside as damage")
    return "damaged middle line — replay stopped before it, journal set aside; torn tail dropped quietly"
}

/// Review of de478381: replay read the journal with `try?`, so a journal it could
/// not read looked empty, and launch then folded nothing into the base and
/// emptied the file. Only a missing journal is empty; any other read failure
/// must stop launch with the journal untouched.
private func unreadableJournalArm() throws -> String {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("array-task-ledger-recovery-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let journal = root.appendingPathComponent("companion-tasks/ledger.journal")
    // A missing journal is the ordinary empty case: a ledger reopened before
    // its first change has none.
    _ = try CompanionTaskLedger(applicationSupportDirectory: root)
    try recoveryExpect(!FileManager.default.fileExists(atPath: journal.path), "unreadable journal: the arm expects no journal before the first change")
    let ledger = try CompanionTaskLedger(applicationSupportDirectory: root)
    try settle(ledger, count: 3, tag: "unread")
    let committed = Set(try ledger.snapshot().tasks.flatMap(\.members).map(\.runID))
    let journalBefore = try Data(contentsOf: journal)

    try FileManager.default.setAttributes([.posixPermissions: 0o200], ofItemAtPath: journal.path)
    let readDenied = (try? Data(contentsOf: journal)) == nil
    var threw = false
    if readDenied {
        do { _ = try CompanionTaskLedger(applicationSupportDirectory: root) } catch { threw = true }
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: journal.path)
    try recoveryExpect(readDenied, "unreadable journal: chmod 0200 did not deny the read, so the arm proves nothing")
    try recoveryExpect(try Data(contentsOf: journal) == journalBefore,
        "unreadable journal: launch changed a journal it could not read (\(journalBefore.count) bytes → \((try? Data(contentsOf: journal).count) ?? -1))")
    try recoveryExpect(threw, "unreadable journal: launch went on without reading the journal")
    let restored = Set(try CompanionTaskLedger(applicationSupportDirectory: root).snapshot().tasks.flatMap(\.members).map(\.runID))
    try recoveryExpect(committed.isSubset(of: restored), "unreadable journal: committed runs missing once the journal was readable again")
    return "unreadable journal — launch threw, journal untouched, \(committed.count) runs restored once readable; missing journal opens clean"
}

private func settle(_ ledger: CompanionTaskLedger, count: Int, tag: String) throws {
    for index in 0..<count {
        let run = try ledger.begin(agentID: UUID())
        try ledger.observe(.turnStarted(threadId: "t", turnId: "\(tag)-\(index)"), run: run)
        try ledger.observe(.turnCompleted(threadId: "t", turnId: "\(tag)-\(index)", outcome: .completed, errorMessage: nil), run: run)
    }
}

/// Caps every file this process writes at `bytes` for the duration of `body`.
/// SIGXFSZ is ignored meanwhile, so a write past the cap is cut short or fails
/// with EFBIG instead of killing the process.
private func withFileSizeCap<T>(_ bytes: Int, _ body: () throws -> T) throws -> T {
    var original = rlimit()
    guard getrlimit(RLIMIT_FSIZE, &original) == 0 else { throw POSIXError(.EPERM) }
    var capped = original
    capped.rlim_cur = rlim_t(bytes)
    let previousHandler = signal(SIGXFSZ, SIG_IGN)
    guard setrlimit(RLIMIT_FSIZE, &capped) == 0 else { signal(SIGXFSZ, previousHandler); throw POSIXError(.EPERM) }
    defer {
        _ = setrlimit(RLIMIT_FSIZE, &original)
        signal(SIGXFSZ, previousHandler)
    }
    return try body()
}
