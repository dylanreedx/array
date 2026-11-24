import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

/// `--sidebar-lead-tally-live-check`: the lead's summary line counts every
/// helper by its real live state. A helper still running must be counted as
/// working whatever its lifecycle says, so "All N helpers done" is never drawn
/// over running helpers. Drives the production `AgentInboxView.reload` and
/// reads the tally the sidebar actually draws from.
@MainActor
enum SidebarLeadTallyLiveChecks {
    static func run() throws -> String {
        struct Failure: Error, CustomStringConvertible { let description: String }
        func expect(_ ok: @autoclosure () -> Bool, _ message: String) throws {
            if !ok() { throw Failure(description: "lead tally: " + message) }
        }
        let now = SidebarHelperHoverChecks.now
        func uuid(_ n: Int) -> UUID { SidebarHelperHoverChecks.uuid(0x900 + n) }
        func row(_ n: Int, _ state: InboxState, lifecycle: InboxLifecycle, parent: Int?,
                 selfReport: InboxSelfReport? = nil) -> AgentInboxRow {
            let at = now.addingTimeInterval(-Double(60 * (n + 1)))
            return AgentInboxRow(
                id: uuid(n), title: parent == nil ? "Lead" : "h\(n)", projectName: "array-scratch",
                projectId: uuid(0xF0), workspaceName: "personal", workspaceId: uuid(0xF1),
                state: state, lifecycle: lifecycle, model: "claude-opus-5-5", branch: nil,
                elapsed: state == .working ? 30 : nil,
                elapsedStartedAt: state == .working ? now.addingTimeInterval(-30) : nil,
                lastActiveAt: at, depth: parent == nil ? 0 : 1, createdAt: at.addingTimeInterval(-300),
                parentId: parent.map(uuid), harness: "Claude Code",
                terminalEvent: state == .ready
                    ? AgentTerminalEvent(sequence: 1, turnID: nil, outcome: .succeeded, endedAt: at) : nil,
                terminalIsUnread: false, identityColor: nil, selfReport: selfReport,
                hasTile: parent == nil, isPinned: false)
        }
        // Six helpers finished; three are still running but carry a settled
        // lifecycle (a cleared or settled family keeps its helpers' lifecycle).
        var rows = [row(0, .working, lifecycle: .active, parent: nil)]
        for n in 1...6 { rows.append(row(n, .ready, lifecycle: .active, parent: 0)) }
        for n in 7...9 { rows.append(row(n, .working, lifecycle: .settled(at: now.addingTimeInterval(-600)), parent: 0)) }

        // The report a finished helper filed, through the production builder.
        var record = AgentRecord(id: AgentID(rawValue: uuid(1)), displayName: "h1", harness: .claudeCode,
                                 model: "claude-opus-5-5", thinking: "medium", cwd: "/tmp",
                                 createdAt: now.addingTimeInterval(-900), lastActivityAt: now)
        record.parentAgentID = AgentID(rawValue: uuid(0))
        record.latestTurnAt = now.addingTimeInterval(-600)
        record.lastReport = AgentFiledReport(
            report: AgentReport(summary: "s", checks: [.init(what: "build", result: .fail)]),
            filedAt: now.addingTimeInterval(-300))
        let built = AgentInboxRowBuilder.selfReport(for: record, now: now)
        try expect(built?.reportedFailure == true, "a failed report must reach the row as a reported failure")
        record.lastReport = AgentFiledReport(report: AgentReport(summary: "s"), filedAt: now.addingTimeInterval(-300))
        try expect(AgentInboxRowBuilder.selfReport(for: record, now: now)?.reportedFailure != true,
                   "a clean report must not read as a failure")

        // Nine helpers, six clean and three whose reports failed: the line says
        // "3 need you", as the helper drawer does, never "All 9 helpers done".
        var failedRows = [row(0, .ready, lifecycle: .active, parent: nil)]
        for n in 1...6 { failedRows.append(row(n, .ready, lifecycle: .active, parent: 0)) }
        for n in 7...9 {
            failedRows.append(row(n, .ready, lifecycle: .active, parent: 0, selfReport: built))
        }

        for dark in [false, true] {
            let tag = dark ? "dark" : "light"
            let f = try SidebarHelperHoverChecks.fixture(style: "duplex", dark: dark)
            defer { f.close() }
            f.inbox.restoreParentFolds([uuid(0): true])
            f.inbox.reload(rows: rows)
            f.inbox.layoutForQA()
            if let dir = ProcessInfo.processInfo.environment["ARRAY_STILLS_DIR"] {
                try SidebarParityCapture.capture(
                    f.inbox, to: URL(fileURLWithPath: dir).appendingPathComponent("lead-tally-\(tag).png"))
            }
            guard let tally = f.inbox.sidebarTallies[uuid(0)] else {
                throw Failure(description: "lead tally: \(tag): the lead has no tally")
            }
            try expect(tally.total == 9, "\(tag): nine helpers expected, counted \(tally.total)")
            try expect(tally.count(.working) == 3,
                       "\(tag): three helpers are running, tally says \(tally.count(.working)) working")
            try expect(tally.liveLine == "3 working",
                       "\(tag): the line must say 3 working, it says \"\(tally.liveLine)\"")
            f.inbox.reload(rows: failedRows)
            f.inbox.layoutForQA()
            if let dir = ProcessInfo.processInfo.environment["ARRAY_STILLS_DIR"] {
                try SidebarParityCapture.capture(
                    f.inbox, to: URL(fileURLWithPath: dir).appendingPathComponent("lead-failed-\(tag).png"))
            }
            let failedTally = f.inbox.sidebarTallies[uuid(0)]
            try expect(failedTally?.liveLine == "3 need you",
                       "\(tag): three failed helpers must read \"3 need you\", it says \"\(failedTally?.liveLine ?? "nil")\"")
        }
        return "lead tally: running helpers are counted working whatever their lifecycle; never \"All N helpers done\" over them"
    }
}
