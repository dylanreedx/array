import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

// Plan: .plans/106-sidebar-ownership (helper priority)
//
// `--sidebar-fold-expand-check [dir]`: a lead with 3 recent subagents and 40
// finished ones folded into "40 more, all done", on the production
// `AgentInboxView`, in both appearances. Every click goes through
// `NSApp.sendEvent`, on the words of the line itself. It asserts the line
// lights and presses like a subagent row, opens to all 43 in the visible rows'
// style and order, keeps "Show less" open through a sidebar refresh and live
// pushes — a folded subagent's change rebuilds nothing, a new subagent builds
// only what is on screen and leaves the row being read in place — reveals a
// formerly folded subagent on click, and folds back with the line under the
// pointer. It also clicks the words of the "Snoozed (1)" and "History (40)"
// headings and of History's "Show 25 more" footer, and asserts each opens or
// pages its rows. With a directory it writes the stills.
extension SidebarOwnershipChecks {
    static let foldLead = 0xA00
    static let foldRecent = [0xA01, 0xA02, 0xA03]
    static let foldFolded = Array(0xA10..<0xA38)
    static let foldArrival = 0xA40
    static let foldNeighbours = Array(0xB00..<0xB10)

    /// `arrival`: a 44th subagent, working (or, `arrivalDone`, just finished).
    /// `foldedFailure`: the 21st folded subagent's last turn failed.
    static func foldRows(arrival: Bool = false, arrivalDone: Bool = false,
                         foldedFailure: Bool = false) -> [AgentInboxRow] {
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        func row(_ n: Int, _ title: String, state: InboxState, parent: Int? = nil, spawned: Double,
                 ended: Double? = nil, outcome: AgentTerminalOutcome = .succeeded) -> AgentInboxRow {
            AgentInboxRow(
                id: uuid(n), title: title, projectName: "Array", projectId: uuid(0x805),
                workspaceName: "personal", workspaceId: workspaceId, state: state, lifecycle: .active,
                model: "claude-opus-5-5", branch: "array/integration",
                elapsed: state == .working ? 300 : nil,
                elapsedStartedAt: state == .working ? ago(5) : nil,
                lastActiveAt: ago(ended ?? 0), depth: 0, createdAt: ago(spawned),
                parentId: parent.map(uuid), harness: "Claude Code",
                terminalEvent: ended.map {
                    AgentTerminalEvent(sequence: 1, turnID: nil, outcome: outcome, endedAt: ago($0))
                },
                terminalIsUnread: false, identityColor: parent == nil ? "purple" : nil, selfReport: nil,
                hasTile: parent == nil, isPinned: false)
        }
        let topics = ["Read the relay diff", "Map the pairing seam", "List stale benches", "Draft the notes",
                      "Trace the board query", "Audit tile frames", "Probe the canvas ops", "Check the drag ghost"]
        var out = [row(foldLead, "Ship the sidebar release", state: .working, spawned: 400)]
        for (i, n) in foldRecent.enumerated() {
            out.append(row(n, "\(topics[i]) (recent)", state: .ready, parent: foldLead,
                           spawned: 60 + Double(i), ended: 2 + Double(i) * 2))
        }
        for (i, n) in foldFolded.enumerated() {
            let failed = foldedFailure && i == 20
            out.append(row(n, "\(topics[i % topics.count]) #\(i + 1)", state: failed ? .failed : .ready,
                           parent: foldLead, spawned: 390 - Double(i), ended: 40 + Double(i),
                           outcome: failed ? .failed : .succeeded))
        }
        if arrival {
            out.append(row(foldArrival, "Run the iOS build", state: arrivalDone ? .ready : .working,
                           parent: foldLead, spawned: 1, ended: arrivalDone ? 0 : nil))
        }
        // Newer leads above, so the open group runs far below the fold of the list.
        for (i, n) in foldNeighbours.enumerated() {
            out.append(row(n, "Review lead \(i + 1)", state: .ready, spawned: 30 - Double(i), ended: 20))
        }
        return out
    }

    static func runFoldExpansion(outputDirectory: URL?) throws -> String {
        // The user's app is active when they click; this one never is, and an
        // inactive app swallows a press on a row as an activation click.
        QuickHideChecks.acceptFirstMouseEverywhere()
        var report: [String] = []
        for dark in [true, false] {
            report.append(try checkFoldExpansion(dark: dark, outputDirectory: outputDirectory))
            report.append(try checkHistoryFooter(dark: dark))
        }
        return "SidebarFoldExpandChecks passed:\n" + report.joined(separator: "\n")
    }

    static let historyLead = 0xC00
    static let historyClosed = Array(0xC01..<0xC29)
    static let historySnoozed = 0xC80

    /// One live lead, one snoozed agent and forty settled agents in History.
    static func historyRows() -> [AgentInboxRow] {
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        func row(_ n: Int, _ title: String, lifecycle: InboxLifecycle, spawned: Double) -> AgentInboxRow {
            AgentInboxRow(
                id: uuid(n), title: title, projectName: "Array", projectId: uuid(0x805),
                workspaceName: "personal", workspaceId: workspaceId, state: .ready, lifecycle: lifecycle,
                model: "claude-opus-5-5", branch: "array/integration", elapsed: nil, elapsedStartedAt: nil,
                lastActiveAt: ago(spawned - 5), depth: 0, createdAt: ago(spawned), parentId: nil,
                harness: "Claude Code", terminalEvent: nil, terminalIsUnread: false, identityColor: "blue",
                selfReport: nil, hasTile: false, isPinned: false)
        }
        return [row(historyLead, "Ship the sidebar release", lifecycle: .active, spawned: 30),
                row(historySnoozed, "Wait for the relay deploy", lifecycle: .snoozed(until: now.addingTimeInterval(3600)),
                    spawned: 40)]
            + historyClosed.enumerated().map { i, n in
                row(n, "Closed review \(i + 1)", lifecycle: .settled(at: ago(60 + Double(i))), spawned: 120 + Double(i))
            }
    }

    /// The shelf headings and History's "Show 25 more" footer, each clicked on
    /// its words through the window: "Snoozed (1)" opens its shelf, "History (40)"
    /// opens History, and the footer pages 25 more closed agents in.
    static func checkHistoryFooter(dark: Bool) throws -> String {
        let label = "\(dark ? "dark" : "light") shelves"
        func fail(_ message: String) -> Failure { Failure(description: "\(label): \(message)") }
        let (inbox, window) = build(dark: dark, height: 720, rows: historyRows(), folds: [:]) { _, _ in }
        defer { window.orderOut(nil) }
        // The app's sidebar layout: History is a folded shelf at the bottom.
        inbox.foldsHistoryIntoShelf = true
        inbox.layoutViewportForQA()
        func clickWords(_ view: NSView, _ words: NSRect, _ what: String) throws {
            let point = NSPoint(x: words.midX, y: words.midY)
            guard let hit = window.contentView?.hitTest(point), hit === view || hit.isDescendant(of: view) else {
                throw fail("the words of \(what) are not on screen to click")
            }
            NSApp.postEvent(try mouse(.leftMouseUp, at: point, window: window), atStart: false)
            NSApp.sendEvent(try mouse(.leftMouseDown, at: point, window: window))
            while let pending = NSApp.nextEvent(matching: [.leftMouseUp], until: Date(), inMode: .default, dequeue: true) {
                NSApp.sendEvent(pending)
            }
            inbox.layoutViewportForQA()
        }
        let closed = Set(historyClosed.map(uuid))
        func shownClosed() -> Int { inbox.rowIdsForQA.filter(closed.contains).count }

        // "Snoozed (1)": its words open the shelf.
        guard let snoozed = inbox.snoozedHeaderViewForQA, !inbox.rowIdsForQA.contains(uuid(historySnoozed)) else {
            throw fail("no closed Snoozed heading")
        }
        try clickWords(snoozed, snoozed.qaLabelFrameInWindow, "\"\(snoozed.qaTitle)\"")
        guard inbox.rowIdsForQA.contains(uuid(historySnoozed)) else {
            throw fail("clicking \"\(snoozed.qaTitle)\" did not open the Snoozed shelf")
        }

        // "History (40)": its words open History, showing the first page.
        guard let history = inbox.historyHeaderViewForQA, shownClosed() == 0 else {
            throw fail("no closed History heading (\(shownClosed()) closed agents shown)")
        }
        try clickWords(history, history.qaLabelFrameInWindow, "\"\(history.qaTitle)\"")
        let first = InboxSort.settledPageSize
        guard shownClosed() == first else {
            throw fail("clicking \"\(history.qaTitle)\" showed \(shownClosed()) closed agents, wanted \(first)")
        }
        inbox.scrollToBottomForQA(materializeAll: false)
        guard let footer = inbox.settledMoreViewForQA,
              footer.qaTitle == AgentInboxSettledMoreView.title(hidden: historyClosed.count - first) else {
            throw fail("open History shows \(shownClosed()) closed agents, footer \(inbox.settledMoreTitleForQA ?? "none")")
        }
        try clickWords(footer, footer.qaLabelFrameInWindow, "the footer")
        let paged = first + InboxSort.settledPageStep
        guard shownClosed() == paged, inbox.settledLimitForQA == paged else {
            throw fail("clicking \"\(footer.qaTitle)\" left \(shownClosed()) closed agents shown, wanted \(paged)")
        }
        return "\(label): clicking the words \"Snoozed (1)\" opens its shelf, \"History (\(historyClosed.count))\" "
            + "shows \(first) closed agents, and \"\(AgentInboxSettledMoreView.title(hidden: historyClosed.count - first))\" "
            + "pages \(first) → \(paged)"
    }

    static func checkFoldExpansion(dark: Bool, outputDirectory: URL?) throws -> String {
        let label = "\(dark ? "dark" : "light") fold expansion"
        func fail(_ message: String) -> Failure { Failure(description: "\(label): \(message)") }
        var pushed = foldRows()
        let (inbox, window) = build(dark: dark, height: 720, rows: pushed, folds: [uuid(foldLead): true]) { _, _ in }
        // An untouched lead opens, but its helpers stay under the eight-row cap
        // until the remainder is pressed (P6.5); never all of them at once.
        guard !inbox.expandedFanoutParentsForQA.contains(uuid(foldLead)),
              !inbox.rowIdsForQA.contains(uuid(foldFolded.last!)),
              inbox.fanoutRemaindersByParentForQA[uuid(foldLead)] != nil else {
            throw fail("untouched helpers must start under the eight-row cap with a remainder")
        }
        inbox.toggleCollapse(parentId: uuid(foldLead))
        inbox.toggleCollapse(parentId: uuid(foldLead))
        guard inbox.retainsOverlayScrollerForQA else {
            throw fail("a system legacy-style rewrite replaced the sidebar overlay")
        }
        let reloadsBeforeFocus = inbox.qaFullReloadCount
        let buildsBeforeFocus = inbox.cellBuildCountForQA
        inbox.openAgentId = uuid(foldLead)
        inbox.openAgentId = nil
        guard inbox.qaFullReloadCount == reloadsBeforeFocus,
              inbox.cellBuildCountForQA == buildsBeforeFocus else {
            throw fail("focus changes rebuilt sidebar cards")
        }
        defer { window.orderOut(nil) }
        var revealed: [UUID] = []
        inbox.onRevealRow = { revealed.append($0) }
        func push(_ rows: [AgentInboxRow], added: [Int] = [], updated: [Int] = []) {
            pushed = rows
            inbox.apply(rows: rows, changed: AgentsBoardChangeSet(
                added: Set(added.map(uuid)), updated: Set(updated.map(uuid)), removed: []))
            // The viewport only: what a push builds is what is on screen, and
            // `layoutForQA` would build every offscreen row on the witness's behalf.
            inbox.layoutViewportForQA()
        }
        push(pushed)
        let helperIDs = Set((foldRecent + foldFolded + [foldArrival]).map(uuid))
        func helpers() -> [UUID] { inbox.rowIdsForQA.filter(helperIDs.contains) }
        func name(_ id: UUID) -> String { pushed.first { $0.id == id }?.title ?? id.uuidString }
        // Only rows a user could see are read. Forcing offscreen rows into being
        // (`layoutForQA`) in an offscreen window repositions row views on its own
        // and would make the geometry below describe the harness, not the list.
        // What the list's fold line says, on screen or not.
        func lineTitles() -> [String] { inbox.fanoutRemainderTitlesForQA }
        func fold() throws -> AgentInboxRemainderView {
            inbox.layoutViewportForQA()
            guard let row = inbox.ownershipRemaindersForQA.first(where: { $0.qaParentID == uuid(foldLead) }) else {
                throw fail("the lead's fold line is not on screen")
            }
            row.layoutSubtreeIfNeeded()
            return row
        }
        func cell(_ n: Int) throws -> AgentInbox96CellView {
            guard inbox.visibleAgentIdsForQA.contains(uuid(n)), let cell = inbox.ownershipCellForQA(id: uuid(n)) else {
                throw fail("\(name(uuid(n))) is not on screen")
            }
            cell.layoutSubtreeIfNeeded()
            return cell
        }
        func windowY(_ view: NSView) -> CGFloat { view.convert(view.bounds, to: nil).maxY }
        // A real pointer at the row's centre lands in it: on screen and in the
        // list's viewport, not under its header or past its end.
        func isOnScreen(_ view: NSView) -> Bool {
            let centre = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
            guard let hit = window.contentView?.hitTest(centre) else { return false }
            return hit === view || hit.isDescendant(of: view)
        }
        // Through the window, the way a click arrives: on the words themselves.
        func click(at point: NSPoint) throws {
            NSApp.postEvent(try mouse(.leftMouseUp, at: point, window: window), atStart: false)
            NSApp.sendEvent(try mouse(.leftMouseDown, at: point, window: window))
            while let pending = NSApp.nextEvent(matching: [.leftMouseUp], until: Date(), inMode: .default, dequeue: true) {
                NSApp.sendEvent(pending)
            }
            inbox.layoutViewportForQA()
        }
        func clickFold() throws -> AgentInboxRemainderView {
            let line = try fold()
            guard isOnScreen(line) else { throw fail("the line is not on screen to click") }
            let words = line.qaLabelFrameInWindow
            try click(at: NSPoint(x: words.midX, y: words.midY))
            return line
        }
        func still(_ name: String) throws {
            guard let outputDirectory else { return }
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            try write(inbox, to: outputDirectory.appendingPathComponent("fold-expand-\(name)-\(dark ? "dark" : "light").png"))
        }

        // 1. At rest: three recent subagents, then one line for the other forty.
        let resting = foldRecent.map(uuid)
        guard helpers() == resting else { throw fail("at rest the card shows \(helpers().map(name))") }
        guard lineTitles() == ["40 more, all done"] else { throw fail("the line reads \(lineTitles())") }
        // The card is the list's last: its foot, the line, sits at the viewport's bottom.
        inbox.scrollToBottomForQA(materializeAll: false)
        guard try isOnScreen(fold()), try fold().qaTitle == "40 more, all done", try isOnScreen(cell(foldRecent[2])) else {
            throw fail("the card's foot is not on screen to point at")
        }

        // 2. It lights like a subagent row: the same fill, on the same footprint.
        let neighbour = try cell(foldRecent[2])
        let neighbourCentre = neighbour.convert(NSPoint(x: neighbour.bounds.midX, y: neighbour.bounds.midY), to: nil)
        inbox.mouseMoved(with: try mouse(.mouseMoved, at: neighbourCentre, window: window))
        let rowHover = neighbour.qaGeometry.resolvedFill
        let rowCard = neighbour.qaCardFrameForQA
        let lineWords = try fold().qaLabelFrameInWindow
        inbox.mouseMoved(with: try mouse(.mouseMoved, at: NSPoint(x: lineWords.midX, y: lineWords.midY), window: window))
        let lit = try fold()
        guard lit.qaFillRole == .hover, let lineHover = lit.qaFillColor, let rowHover,
              NSColor(cgColor: lineHover) == NSColor(cgColor: rowHover) else {
            throw fail("the pointer on the line paints \(lit.qaFillRole) \(String(describing: lit.qaFillColor)), a subagent row \(String(describing: rowHover))")
        }
        guard abs(lit.qaFillFrame.minX - rowCard.minX) < 0.5, abs(lit.qaFillFrame.width - rowCard.width) < 0.5 else {
            throw fail("the line's fill \(lit.qaFillFrame) is not a subagent row's \(rowCard)")
        }
        try still("hover")

        // 3. Clicking the words opens all 43, recent first, then the folded newest
        // first, as the same rows. The table rebuilds what is on screen, never the
        // whole list.
        let builtBefore = inbox.cellBuildCountForQA
        let pressed = try clickFold()
        let openedBuilt = inbox.cellBuildCountForQA - builtBefore
        let onScreen = inbox.visibleAgentIdsForQA.count
        guard pressed.qaPressCount == 1, pressed.qaPressedRole == .selected else {
            throw fail("the click did not press the line (presses \(pressed.qaPressCount), fill \(String(describing: pressed.qaPressedRole)))")
        }
        let open = resting + foldFolded.map(uuid)
        guard helpers() == open else {
            throw fail("open, the card shows \(helpers().count) subagents: \(helpers().prefix(6).map(name))…")
        }
        guard lineTitles() == ["Show less"],
              inbox.fanoutRemaindersByParentForQA[uuid(foldLead)]?.afterRowID == uuid(foldFolded.last!) else {
            throw fail("open, the line reads \(lineTitles()) and does not end the card")
        }
        guard openedBuilt <= onScreen + 1, openedBuilt < inbox.rowIdsForQA.count / 2 else {
            throw fail("opening built \(openedBuilt) rows with \(onScreen) on screen of \(inbox.rowIdsForQA.count)")
        }
        let visibleStyle = try cell(foldRecent[1])
        let styleCard = visibleStyle.qaCardFrameForQA
        let styleHeight = visibleStyle.frame.height
        try still("open")
        for n in [foldFolded[0], foldFolded[20], foldFolded[39]] {
            // Through the table's own scroll, as a user reaches them.
            guard inbox.scrollToAgentForQA(id: uuid(n)) else { throw fail("could not scroll to \(name(uuid(n)))") }
            let opened = try cell(n)
            guard opened.isSubagentRow, opened.frame.height == styleHeight,
                  abs(opened.qaCardFrameForQA.minX - styleCard.minX) < 0.5,
                  abs(opened.qaCardFrameForQA.width - styleCard.width) < 0.5 else {
                throw fail("\(name(uuid(n))) is not drawn as a subagent row (\(opened.frame.height) vs \(styleHeight))")
            }
        }

        // 4. A sidebar refresh keeps it open.
        inbox.reload(rows: pushed)
        inbox.layoutViewportForQA()
        guard helpers() == open, lineTitles() == ["Show less"] else {
            throw fail("a refresh folded the card (\(helpers().count) subagents)")
        }

        // 5. Live pushes while open. Measured as the user sees the list: straight
        // after the push and once the run loop has settled.
        inbox.scrollToBottomForQA(materializeAll: false)
        func readerY() throws -> CGFloat { windowY(try cell(foldFolded[30])) }

        // 5a. A folded subagent fails: one row changes, nothing is rebuilt. Its
        // count used to be part of the open line's identity, so this reloaded
        // the whole list.
        let failReloads = inbox.qaFullReloadCount
        let failBuilt = inbox.cellBuildCountForQA
        push(foldRows(foldedFailure: true), updated: [foldFolded[20]])
        let failedBuilt = inbox.cellBuildCountForQA - failBuilt
        guard helpers() == open, lineTitles() == ["Show less"],
              inbox.qaFullReloadCount == failReloads, failedBuilt <= 1 else {
            throw fail("a folded subagent failing rebuilt the open card (\(inbox.qaFullReloadCount - failReloads) "
                + "full reloads, \(failedBuilt) rows built, line \(lineTitles()))")
        }

        // 5b. A new live subagent at the top of the card: still open, the row
        // being read stays put, and only what is on screen is built.
        let before = try readerY()
        let liveBuilt = inbox.cellBuildCountForQA
        push(foldRows(arrival: true, foldedFailure: true), added: [foldArrival])
        let arrivalBuilt = inbox.cellBuildCountForQA - liveBuilt
        let arrivalOnScreen = inbox.visibleAgentIdsForQA.count
        let arrivalTotal = inbox.rowIdsForQA.count
        let afterPush = try readerY()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        inbox.layoutViewportForQA()
        let settled = try readerY()
        guard abs(afterPush - before) < 0.5, abs(settled - before) < 0.5 else {
            throw fail("a new subagent moved the row being read from y \(before) to \(afterPush) (settled \(settled))")
        }
        guard helpers() == [uuid(foldArrival)] + open, lineTitles() == ["Show less"],
              inbox.expandedFanoutParentsForQA.contains(uuid(foldLead)) else {
            throw fail("a new subagent left \(helpers().count) rows, line \(lineTitles())")
        }
        guard arrivalBuilt <= arrivalOnScreen + 1 else {
            throw fail("a new subagent built \(arrivalBuilt) rows with \(arrivalOnScreen) on screen of \(inbox.rowIdsForQA.count)")
        }

        // 5c. ...and it finishing changes one row.
        let finishReloads = inbox.qaFullReloadCount
        let finishBuilt = inbox.cellBuildCountForQA
        push(foldRows(arrival: true, arrivalDone: true, foldedFailure: true), updated: [foldArrival])
        let finished = inbox.cellBuildCountForQA - finishBuilt
        guard helpers() == [uuid(foldArrival)] + open, lineTitles() == ["Show less"],
              inbox.qaFullReloadCount == finishReloads, finished <= 1, abs(try readerY() - before) < 0.5 else {
            throw fail("a subagent finishing folded, rebuilt or moved the open card (\(helpers().count) rows, "
                + "\(finished) built)")
        }
        try still("live")

        // 6. A formerly folded subagent reveals its agent like any other row.
        (window as? KeyWindow)?.reportsKey = true
        let target = try cell(foldFolded[25])
        guard isOnScreen(target) else { throw fail("\(name(uuid(foldFolded[25]))) is not on screen to click") }
        let targetCentre = target.convert(NSPoint(x: target.bounds.midX, y: target.bounds.midY), to: nil)
        try click(at: targetCentre)
        guard revealed.last == uuid(foldFolded[25]) else {
            throw fail("clicking \(name(uuid(foldFolded[25]))) revealed \(revealed.map(name))")
        }
        (window as? KeyWindow)?.reportsKey = false
        inbox.clearSelectionForQA()

        // 7. "Show less", at the foot of the card, folds back under the same pointer.
        inbox.scrollToBottomForQA(materializeAll: false)
        guard try fold().qaTitle == "Show less" else { throw fail("the open card's foot reads \(try fold().qaTitle)") }
        let lineY = windowY(try fold())
        _ = try clickFold()
        let folded = [foldArrival] + foldRecent
        guard helpers() == folded.map(uuid), try fold().qaTitle.hasPrefix("40 more"),
              !inbox.expandedFanoutParentsForQA.contains(uuid(foldLead)) else {
            throw fail("Show less left \(helpers().map(name)), line \(try fold().qaTitle)")
        }
        guard abs(windowY(try fold()) - lineY) < 0.5, try isOnScreen(cell(foldLead)) else {
            throw fail("folding back moved the line from y \(lineY) to \(windowY(try fold())) or hid its lead")
        }
        try still("folded")
        return "\(label): \"40 more, all done\" lights and presses like a subagent row; clicking its words opens "
            + "43 rows in the visible rows' style and order (\(openedBuilt) rows built, \(onScreen) on screen); "
            + "\"Show less\" holds through a refresh; a folded subagent failing rebuilds nothing (\(failedBuilt) built); "
            + "a new live subagent keeps the read row still (\(arrivalBuilt) built, \(arrivalOnScreen) on screen of \(arrivalTotal)); its "
            + "finish rebuilds \(finished); a folded subagent reveals on click; Show less folds back under the pointer"
    }
}
