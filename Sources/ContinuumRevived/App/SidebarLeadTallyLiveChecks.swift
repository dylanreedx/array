import AppKit
import ContinuumRevivedAgentUI

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
        func row(_ n: Int, _ state: InboxState, lifecycle: InboxLifecycle, parent: Int?) -> AgentInboxRow {
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
                terminalIsUnread: false, identityColor: nil, selfReport: nil,
                hasTile: parent == nil, isPinned: false)
        }
        // Six helpers finished; three are still running but carry a settled
        // lifecycle (a cleared or settled family keeps its helpers' lifecycle).
        var rows = [row(0, .working, lifecycle: .active, parent: nil)]
        for n in 1...6 { rows.append(row(n, .ready, lifecycle: .active, parent: 0)) }
        for n in 7...9 { rows.append(row(n, .working, lifecycle: .settled(at: now.addingTimeInterval(-600)), parent: 0)) }

        for dark in [false, true] {
            let tag = dark ? "dark" : "light"
            let f = try SidebarHelperHoverChecks.fixture(style: "duplex", dark: dark)
            defer { f.close() }
            f.inbox.restoreParentFolds([uuid(0): true])
            f.inbox.reload(rows: rows)
            f.inbox.layoutForQA()
            guard let tally = f.inbox.sidebarTallies[uuid(0)] else {
                throw Failure(description: "lead tally: \(tag): the lead has no tally")
            }
            try expect(tally.total == 9, "\(tag): nine helpers expected, counted \(tally.total)")
            try expect(tally.count(.working) == 3,
                       "\(tag): three helpers are running, tally says \(tally.count(.working)) working")
            try expect(tally.liveLine == "3 working",
                       "\(tag): the line must say 3 working, it says \"\(tally.liveLine)\"")
        }
        return "lead tally: running helpers are counted working whatever their lifecycle; never \"All N helpers done\" over them"
    }
}
