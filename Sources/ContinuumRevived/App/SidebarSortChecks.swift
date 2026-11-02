import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

// Plan: .plans/113-sidebar-sort
//
// `--sidebar-sort-check [dir]`: the production `AgentInboxView` over six agents
// in three projects and none. It picks each sort through the header's real sort
// list and asserts the drawn order (Most active, By project with its headings,
// Newest first), the project filter in each, persistence through the app's own
// sidebar wiring in an isolated defaults suite, and that a push which would
// re-sort is held while the pointer is over the list or a row is being renamed,
// then lands, sliding, when the pointer leaves or the rename ends. With a
// directory it writes light and dark stills of the header and the open list.
@MainActor
enum SidebarSortChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }

    static let now = Date(timeIntervalSince1970: 1_900_600_000)
    static let workspaceId = uuid(0x701)
    static func uuid(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012X", n))!
    }

    static let alpha = 0xA, beta = 0xB, gamma = 0xC, delta = 0xD, epsilon = 0xE, helper = 0xE1, foxtrot = 0xF
    static let golf = 0x6

    static func row(_ n: Int, _ title: String, project: String?, state: InboxState = .ready,
                    startedMinutesAgo: Double? = nil, activeMinutesAgo: Double, createdMinutesAgo: Double,
                    parent: Int? = nil) -> AgentInboxRow {
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        return AgentInboxRow(
            id: uuid(n), title: title, projectName: project, projectId: project.map { _ in uuid(0x800 + n) },
            workspaceName: "personal", workspaceId: workspaceId, state: state,
            model: "claude-opus-5-5", elapsed: startedMinutesAgo.map { $0 * 60 },
            elapsedStartedAt: startedMinutesAgo.map(ago), lastActiveAt: ago(activeMinutesAgo),
            createdAt: ago(createdMinutesAgo), parentId: parent.map(uuid), harness: "Claude Code",
            hasTile: parent == nil)
    }

    /// Newest spawned is the quiet one; oldest spawned is working.
    static func fixture() -> [AgentInboxRow] {
        [
            row(alpha, "Alpha idle lead", project: "Array", activeMinutesAgo: 60, createdMinutesAgo: 120),
            row(beta, "Beta working", project: "Film", state: .working, startedMinutesAgo: 5,
                activeMinutesAgo: 0.5, createdMinutesAgo: 200),
            row(gamma, "Gamma asks", project: "Array", state: .approval, activeMinutesAgo: 2, createdMinutesAgo: 30),
            row(delta, "Delta quiet", project: "Site", activeMinutesAgo: 600, createdMinutesAgo: 10),
            row(epsilon, "Epsilon lead", project: "Film", activeMinutesAgo: 20, createdMinutesAgo: 90),
            row(helper, "Epsilon helper", project: "Film", state: .working, startedMinutesAgo: 1,
                activeMinutesAgo: 0.2, createdMinutesAgo: 15, parent: epsilon),
            row(foxtrot, "Foxtrot recent", project: nil, activeMinutesAgo: 3, createdMinutesAgo: 50),
        ]
    }

    final class CheckWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        /// Reads as key without being made key, so nothing takes the user's focus.
        override var isKeyWindow: Bool { true }
    }

    static func build(dark: Bool, rows: [AgentInboxRow] = fixture(), height: CGFloat = 460)
        -> (AgentInboxView, NSWindow)
    {
        let inbox = AgentInboxView(frame: NSRect(x: 0, y: 0, width: 340, height: height))
        inbox.clock = { now }
        inbox.prefersReducedMotion = { false }
        inbox.hoverCardEnabled = false
        inbox.onRevealRow = { _ in }
        inbox.presentsSortOffscreenForQA = true
        let window = CheckWindow(contentRect: inbox.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = inbox
        window.orderFrontOffscreenForChecks()
        inbox.pinScrollerStyleForQA()
        inbox.currentWorkspaceId = workspaceId
        inbox.currentWorkspaceName = "personal"
        inbox.setScope(.all)
        inbox.restoreParentFolds([uuid(epsilon): true])
        inbox.reload(rows: rows)
        inbox.layoutForQA()
        return (inbox, window)
    }

    /// Open the header's sort list and choose, the way a click does.
    static func pick(_ mode: InboxSortMode, in inbox: AgentInboxView) throws {
        inbox.openSortMenuForQA()
        guard inbox.sortPopoverForQA.isPresented, let list = inbox.sortPopoverForQA.listView else {
            throw Failure(description: "the sort button did not open its list")
        }
        let titles = list.qaItems.map(\.title)
        guard titles == ["Most active", "By project", "Newest first"] else {
            throw Failure(description: "the sort list reads \(titles)")
        }
        list.choose(id: mode.rawValue)
        inbox.layoutForQA()
        guard inbox.sortModeForQA == mode else {
            throw Failure(description: "choosing \(mode.title) left the sort on \(inbox.sortModeForQA.title)")
        }
    }

    static func expectSequence(_ inbox: AgentInboxView, _ wanted: [String], _ what: String) throws {
        let got = inbox.drawnSequenceForQA
        guard got == wanted else {
            throw Failure(description: "\(what): wanted \(wanted), drew \(got)")
        }
    }

    static func pump(_ seconds: TimeInterval = 0.05) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    // MARK: Run

    static func run(outputDirectory: URL?) throws -> String {
        var report: [String] = []
        let (inbox, window) = build(dark: false)
        defer { window.orderOut(nil) }

        // 1. The view is born on the frozen order, and the button says so.
        try expectSequence(inbox, ["Delta quiet", "Gamma asks", "Foxtrot recent", "Epsilon lead",
                                   "Epsilon helper", "Alpha idle lead", "Beta working"],
                           "a bare view draws newest spawned first")
        guard inbox.sortButtonForQA.toolTip == "Sort: Newest first", !inbox.sortButtonForQA.isHidden,
              inbox.sortButtonForQA.frame.width == AgentInboxView.headerIconButtonSide else {
            throw Failure(description: "the header's sort button is missing or unlabelled: "
                + "\(inbox.sortButtonForQA.toolTip ?? "nil") \(inbox.sortButtonForQA.frame)")
        }
        guard (inbox.accessibilityChildren() as? [NSView])?.contains(where: { $0 === inbox.sortButtonForQA }) == true,
              inbox.sortButtonForQA.accessibilityLabel() == "Sort agents" else {
            throw Failure(description: "VoiceOver cannot reach the sort button")
        }

        // 2. Most active: working and asking first, newest turn first (a lead
        //    counts its working helper), then the rest by last activity.
        var picked: [InboxSortMode] = []
        inbox.onSortModeChange = { picked.append($0) }
        try pick(.mostActive, in: inbox)
        let mostActive = ["Epsilon lead", "Epsilon helper", "Gamma asks", "Beta working",
                          "Foxtrot recent", "Alpha idle lead", "Delta quiet"]
        try expectSequence(inbox, mostActive, "Most active")
        guard inbox.projectHeadingTitlesForQA.isEmpty else {
            throw Failure(description: "Most active draws project headings: \(inbox.projectHeadingTitlesForQA)")
        }

        // 3. By project: headings A to Z, no project last, most active first in each.
        try pick(.byProject, in: inbox)
        try expectSequence(inbox, ["# Array", "Gamma asks", "Alpha idle lead",
                                   "# Film", "Epsilon lead", "Epsilon helper", "Beta working",
                                   "# Site", "Delta quiet",
                                   "# No project", "Foxtrot recent"], "By project")
        guard inbox.projectHeadingTitlesForQA == ["Array (2)", "Film (2)", "Site (1)", "No project (1)"] else {
            throw Failure(description: "the project headings read \(inbox.projectHeadingTitlesForQA)")
        }

        // 4. The project filter is the scope's `Projects ›` pick, in either sort.
        guard inbox.pickScopeForQA(.project("Film")) else {
            throw Failure(description: "the Film project is not pickable from the scope list")
        }
        inbox.layoutForQA()
        try expectSequence(inbox, ["# Film", "Epsilon lead", "Epsilon helper", "Beta working"],
                           "By project, filtered to Film")
        try pick(.mostActive, in: inbox)
        try expectSequence(inbox, ["Epsilon lead", "Epsilon helper", "Beta working"],
                           "Most active, filtered to Film")
        guard inbox.pickScopeForQA(.all) else { throw Failure(description: "All agents is not pickable") }
        inbox.layoutForQA()
        try expectSequence(inbox, mostActive, "Most active, all projects again")
        guard picked == [.mostActive, .byProject, .mostActive] else {
            throw Failure(description: "each pick is reported once for the host to store: \(picked.map(\.title))")
        }
        report.append("orders: newest, most active, by project with 4 headings; Film filter in both")

        // 5. Held under the pointer. Alpha starts working and a new agent arrives:
        //    rows already drawn stay put, the new one goes on top.
        var pushed = fixture()
        if let index = pushed.firstIndex(where: { $0.id == uuid(alpha) }) {
            pushed[index] = row(alpha, "Alpha idle lead", project: "Array", state: .working,
                                startedMinutesAgo: 0, activeMinutesAgo: 0, createdMinutesAgo: 120)
        }
        pushed.append(row(golf, "Golf new", project: "Array", state: .working, startedMinutesAgo: 0.1,
                          activeMinutesAgo: 0.1, createdMinutesAgo: 0.1))
        inbox.pointerForQA(inside: true)
        inbox.apply(rows: pushed, changed: .init(added: [uuid(golf)], updated: [uuid(alpha)], removed: []))
        inbox.layoutForQA()
        try expectSequence(inbox, ["Golf new"] + mostActive, "a push under the pointer")
        guard inbox.isSortHoldPendingForQA else {
            throw Failure(description: "the held push did not record a pending re-sort")
        }
        let alphaYBefore = inbox.drawnRowMinYForQA(id: uuid(alpha))
        inbox.pointerForQA(inside: false)
        inbox.layoutForQA()
        let resorted = ["Alpha idle lead", "Golf new", "Epsilon lead", "Epsilon helper", "Gamma asks",
                        "Beta working", "Foxtrot recent", "Delta quiet"]
        try expectSequence(inbox, resorted, "the pointer left")
        guard let alphaCell = inbox.ownershipCellForQA(id: uuid(alpha)),
              alphaCell.layer?.animation(forKey: "scopeReflow") != nil,
              let before = alphaYBefore, let after = inbox.drawnRowMinYForQA(id: uuid(alpha)), after < before else {
            throw Failure(description: "the released re-sort did not slide Alpha up into place")
        }
        report.append("pointer hold: push kept 7 rows in place with the new one on top; leaving re-sorted with a slide")

        // 6. Held while renaming, even with the pointer away.
        guard inbox.beginRename(agentId: uuid(delta)) else { throw Failure(description: "could not rename Delta") }
        var renamed = pushed
        if let index = renamed.firstIndex(where: { $0.id == uuid(delta) }) {
            renamed[index] = row(delta, "Delta quiet", project: "Site", state: .working, startedMinutesAgo: 0,
                                 activeMinutesAgo: 0, createdMinutesAgo: 10)
        }
        inbox.apply(rows: renamed, changed: .init(added: [], updated: [uuid(delta)], removed: []))
        inbox.layoutForQA()
        try expectSequence(inbox, resorted, "a push during a rename")
        guard inbox.isRenameEditingForQA else {
            throw Failure(description: "the push during a rename ended the rename")
        }
        _ = inbox.pressKeyInRenameForQA(#selector(NSResponder.cancelOperation(_:)))
        pump()
        inbox.layoutForQA()
        try expectSequence(inbox, ["Delta quiet"] + resorted.filter { $0 != "Delta quiet" }, "the rename ended")
        report.append("rename hold: order kept while the field was open, re-sorted once it closed")

        // 7. Persistence through the app's own sidebar wiring, in an isolated suite.
        let suite = "continuum.sidebar.sort.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw Failure(description: "no suite") }
        defer { defaults.removePersistentDomain(forName: suite) }
        func hostedSidebar() -> (AppDelegate, WorkspaceSidebarView, NSWindow) {
            let app = AppDelegate()
            app.qaSettingsDefaults = defaults
            let sidebar = WorkspaceSidebarView(frame: NSRect(x: 0, y: 0, width: 340, height: 460))
            let hostWindow = CheckWindow(contentRect: sidebar.frame, styleMask: [.borderless],
                                         backing: .buffered, defer: false)
            hostWindow.contentView = sidebar
            hostWindow.orderFrontOffscreenForChecks()
            sidebar.agentInbox.presentsSortOffscreenForQA = true
            app.configureWorkspaceSidebarForQA(sidebar)
            sidebar.agentInbox.reload(rows: fixture())
            sidebar.agentInbox.layoutForQA()
            return (app, sidebar, hostWindow)
        }
        let restoreShelves = WorkspaceSidebarConfig.qaIsolateShelves()
        defer { restoreShelves() }
        let (firstApp, first, firstWindow) = hostedSidebar()
        guard first.agentInbox.sortModeForQA == .mostActive, defaults.string(forKey: WorkspaceSidebarConfig.sortKey) == nil else {
            throw Failure(description: "a first launch opens on \(first.agentInbox.sortModeForQA.title), "
                + "stored \(defaults.string(forKey: WorkspaceSidebarConfig.sortKey) ?? "nothing")")
        }
        try pick(.byProject, in: first.agentInbox)
        guard defaults.string(forKey: WorkspaceSidebarConfig.sortKey) == InboxSortMode.byProject.rawValue else {
            throw Failure(description: "the pick was not stored: \(defaults.string(forKey: WorkspaceSidebarConfig.sortKey) ?? "nil")")
        }
        firstWindow.orderOut(nil)
        _ = firstApp
        let (secondApp, second, secondWindow) = hostedSidebar()
        defer { secondWindow.orderOut(nil); _ = secondApp }
        guard second.agentInbox.sortModeForQA == .byProject,
              second.agentInbox.projectHeadingTitlesForQA.first == "Array (2)" else {
            throw Failure(description: "a relaunch restored \(second.agentInbox.sortModeForQA.title) "
                + "with headings \(second.agentInbox.projectHeadingTitlesForQA)")
        }
        defaults.set("by-mood", forKey: WorkspaceSidebarConfig.sortKey)
        guard WorkspaceSidebarConfig.resolveSortMode(defaults: defaults) == .mostActive else {
            throw Failure(description: "an unreadable stored sort did not fall back to Most active")
        }
        report.append("persistence: first launch Most active, a pick stored and restored by the host, junk reads Most active")

        // 8. Stills.
        if let outputDirectory {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            for dark in [false, true] {
                let label = dark ? "dark" : "light"
                let (still, stillWindow) = build(dark: dark)
                defer { stillWindow.orderOut(nil) }
                still.setSortMode(.mostActive)
                still.layoutForQA()
                try SidebarOwnershipChecks.write(still, to: outputDirectory.appendingPathComponent("most-active-\(label).png"))
                still.setSortMode(.byProject)
                still.layoutForQA()
                try SidebarOwnershipChecks.write(still, to: outputDirectory.appendingPathComponent("by-project-\(label).png"))
                still.openSortMenuForQA()
                pump(0.2)
                guard let surface = still.sortPopoverForQA.panel?.contentView else {
                    throw Failure(description: "\(label): the sort list has no panel to photograph")
                }
                try SidebarOwnershipChecks.write(surface, to: outputDirectory.appendingPathComponent("sort-list-\(label).png"))
                still.sortPopoverForQA.dismiss()
            }
            report.append("stills: \(outputDirectory.path)")
        }
        return "sidebar sort: " + report.joined(separator: "; ")
    }
}
