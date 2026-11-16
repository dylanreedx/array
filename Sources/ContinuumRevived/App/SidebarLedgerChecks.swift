import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

// Sidebar round (array/sidebar-next): `--sidebar-ledger-check [dir]`.
//
// The production `AgentInboxView` in the Ledger layout, both appearances, with
// an 18-helper release lead (nested sub-leads) and one top-level agent per
// failure class. Every press goes through `NSApp.sendEvent` on the control
// itself. Asserts, from what the list DRAWS (cells, their text and AX):
//   1. the lead's chip says "18 helpers · 12 paused · 1 failed", its AX help
//      carries the full partition, and shown helper rows + the drawn fold
//      numbers = 18; "failed" is drawn once on the card;
//   2. each failure class draws its label and one action, and pressing the
//      action reaches the host with that incident;
//   3. Clear N acts on exactly the clearable rows: the rows leave, blocked rows
//      stay, Undo brings them back;
//   4. switching Settings > Sidebar > Layout re-renders the list live;
//   5. a tile-less helper draws as a normal row beside a tiled sibling.
// Persistence through a store reload is asserted on a real AgentSupervisor and
// AgentStore: a settled (cleared) record stays settled for a second supervisor
// on the same root, and new activity clears it.
@MainActor
enum SidebarLedgerChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }

    static let now = Date(timeIntervalSinceReferenceDate: 806_400_000)
    static let workspaceId = uuid(0x900)
    static func uuid(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012X", n))!
    }

    static let usage = "You've hit your 5-hour limit · resets 1:20 AM"
    static let lead = 1

    static func row(
        _ n: Int, _ title: String, parent: Int? = nil, state: InboxState = .ready,
        outcome: AgentTerminalOutcome? = .succeeded, detail: String? = nil, harness: String = "claude",
        lifecycle: InboxLifecycle = .active, minutesAgo: Double = 2_000, hasTile: Bool? = nil,
        cleared: Bool = false
    ) -> AgentInboxRow {
        let ended = now.addingTimeInterval(-minutesAgo * 60)
        var row = AgentInboxRow(
            id: uuid(n), title: title, projectName: "Array", projectId: uuid(0x901),
            workspaceName: "personal", workspaceId: workspaceId, state: state, lifecycle: lifecycle,
            model: "claude-opus-5-5", branch: "array/integration",
            lastActiveAt: ended, depth: 0, createdAt: now.addingTimeInterval(Double(-200_000 + n)),
            parentId: parent.map(uuid), harness: harness,
            terminalEvent: outcome.map { AgentTerminalEvent(sequence: UInt64(n), turnID: nil, outcome: $0, endedAt: ended) },
            terminalIsUnread: false, identityColor: parent == nil ? "blue" : nil,
            hasTile: hasTile ?? (parent == nil), isPinned: false)
        row.failureDetail = detail
        row.isCleared = cleared
        return row
    }

    /// 18 helpers under lead 1: 12 paused (11 Claude, 1 Codex), 1 failed
    /// (Codex could not start), 2 stopped, 3 done. Plus one top-level agent per
    /// other class, a finished family, and an agent that needs you.
    static func rows(cleared: Set<Int> = [], settled: Set<Int> = []) -> [AgentInboxRow] {
        func life(_ n: Int) -> InboxLifecycle { settled.contains(n) ? .settled(at: now) : .active }
        var out = [row(lead, "Array release lead")]
        out.append(row(2, "Monitor overnight runs", parent: 1))
        for n in 3...6 { out.append(row(n, "Overnight helper \(n)", parent: 2, outcome: .failed, detail: usage)) }
        out.append(row(7, "Further sidebar improvements", parent: 1, outcome: .failed, detail: usage))
        for n in 8...11 { out.append(row(n, "Sidebar helper \(n)", parent: 7, outcome: .failed, detail: usage)) }
        out.append(row(12, "Sidebar helper 12", parent: 7, outcome: .interrupted, cleared: cleared.contains(12)))
        out.append(row(14, "Recover review fixes", parent: 1, outcome: .failed, detail: usage))
        out.append(row(15, "Build combined preview", parent: 1, outcome: .failed, detail: usage))
        out.append(row(16, "Codex usage helper", parent: 1, outcome: .failed,
                       detail: "You've hit your usage limit. Try again at 3:00 AM.", harness: "codex"))
        out.append(row(17, "Implement permission approval", parent: 1, outcome: .failed,
                       detail: "Codex could not start: could not launch codex: No such file or directory (2)",
                       harness: "codex"))
        // Two recent finished helpers stay inline: one with a tile, one without.
        out.append(row(18, "Interrupted helper", parent: 1, outcome: .interrupted, minutesAgo: 5,
                       cleared: cleared.contains(18)))
        out.append(row(19, "Finished helper (no tile)", parent: 1, minutesAgo: 3, hasTile: false,
                       cleared: cleared.contains(19)))
        out.append(row(20, "Finished helper (tile)", parent: 1, minutesAgo: 4, hasTile: true,
                       cleared: cleared.contains(20)))
        // Top-level agents, one per remaining class.
        out.append(row(30, "Review canvas changes", lifecycle: life(30)))
        out.append(row(31, "Canvas review helper", parent: 30))
        out.append(row(32, "Fix CRLF check in release script", outcome: .failed,
                       detail: "Failed to authenticate: OAuth session expired and could not be refreshed"))
        out.append(row(33, "Audit collaborator access", outcome: .failed, detail: "serverOverloaded",
                       harness: "codex", lifecycle: life(33)))
        out.append(row(34, "Speed up Array agent sidebar", outcome: .interrupted,
                       detail: "Array restarted while this helper was working, so its turn did not finish.",
                       lifecycle: life(34)))
        out.append(row(35, "Redesign tile agent bubble", state: .approval, outcome: nil))
        out.append(row(36, "Explain integral fields", outcome: .failed,
                       detail: "Claude Code reported an error without details.", lifecycle: life(36)))
        return out
    }

    /// Helpers 18, 19, 20 under the lead; 12 under sub-lead 7; leads 30,
    /// 33, 34, 36 at the top. Paused, setup, sign-in and needs-you refuse.
    static let expectedClear: Set<Int> = [12, 18, 19, 20, 30, 33, 34, 36]

    static func defaults(_ layout: SidebarLayout) -> UserDefaults {
        let suite = "array.sidebar-ledger-check.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(layout.rawValue, forKey: SidebarLayout.defaultsKey)
        return defaults
    }

    static func mouse(_ type: NSEvent.EventType, at point: NSPoint, window: NSWindow) throws -> NSEvent {
        guard let event = NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
            pressure: type == .leftMouseUp ? 0 : 1)
        else { throw Failure(description: "could not synthesise \(type)") }
        return event
    }

    /// A real press on a control: hit-tested in the window, mouse-up queued
    /// first so the control's tracking loop ends.
    static func press(_ control: NSView, in window: NSWindow, _ what: String) throws {
        let point = control.convert(NSPoint(x: control.bounds.midX, y: control.bounds.midY), to: nil)
        guard let hit = window.contentView?.hitTest(point), hit === control || hit.isDescendant(of: control) else {
            throw Failure(description: "\(what): the window does not hit the control at \(point)")
        }
        NSApp.postEvent(try mouse(.leftMouseUp, at: point, window: window), atStart: false)
        NSApp.sendEvent(try mouse(.leftMouseDown, at: point, window: window))
        while let pending = NSApp.nextEvent(matching: [.leftMouseUp], until: Date(), inMode: .default, dequeue: true) {
            NSApp.sendEvent(pending)
        }
    }

    static func run(outputDirectory: URL?) throws -> String {
        QuickHideChecks.acceptFirstMouseEverywhere()
        var report: [String] = []
        for dark in [true, false] {
            report.append(try checkLedger(dark: dark, outputDirectory: outputDirectory))
        }
        report.append(try checkPersistence())
        return "SidebarLedgerChecks passed:\n" + report.joined(separator: "\n")
    }

    // MARK: - The drawn list

    static func checkLedger(dark: Bool, outputDirectory: URL?) throws -> String {
        let label = dark ? "dark" : "light"
        func fail(_ message: String) -> Failure { Failure(description: "\(label): \(message)") }
        let defaults = Self.defaults(.ledger)
        let inbox = AgentInboxView(frame: NSRect(x: 0, y: 0, width: 420, height: 2_400), indicatorDefaults: defaults)
        inbox.clock = { now }
        inbox.foldsUntouchedGroups = false
        inbox.prefersReducedMotion = { true }
        inbox.onRevealRow = { _ in }
        inbox.hoverCardEnabled = false
        inbox.wiredRowActions = AppDelegate.wiredInboxRowActions
        // The host: records actions; its store is `cleared`/`settled` below.
        var actions: [(InboxRowAction, [UUID])] = []
        var pressed: [SidebarIncident] = []
        var cleared: Set<Int> = []
        var settled: Set<Int> = []
        func number(_ id: UUID) -> Int { Int(id.uuidString.suffix(12), radix: 16) ?? -1 }
        func lifecycleSnapshot(_ id: UUID) -> InboxLifecycleSnapshot? {
            let n = number(id)
            let parked = cleared.contains(n) || settled.contains(n)
            return InboxLifecycleSnapshot(
                settledOverride: parked ? .settled : .neutral, settledAt: parked ? now : nil,
                snoozedUntil: nil, snoozedAt: nil)
        }
        inbox.lifecycleFacts = lifecycleSnapshot
        inbox.onRowAction = { action, ids in
            actions.append((action, ids))
            guard action == .settle else { return }
            for id in ids {
                let n = number(id)
                // The supervisor's settle: a top-level agent goes to History; a
                // helper stays in its lead's family, cleared.
                if inbox.allRowsForQA.first(where: { $0.id == id })?.parentId == nil { settled.insert(n) } else { cleared.insert(n) }
            }
            inbox.reload(rows: rows(cleared: cleared, settled: settled))
        }
        inbox.onUndoLifecycle = { restoring in
            for id in restoring.keys {
                cleared.remove(number(id))
                settled.remove(number(id))
            }
            inbox.reload(rows: rows(cleared: cleared, settled: settled))
        }
        inbox.onIncidentAction = { pressed.append($0) }
        let window = SidebarOwnershipChecks.KeyWindow(contentRect: inbox.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = inbox
        window.orderFrontOffscreenForChecks()
        window.makeKey()
        defer { window.orderOut(nil) }
        inbox.pinScrollerStyleForQA()
        inbox.currentWorkspaceId = workspaceId
        inbox.currentWorkspaceName = "personal"
        inbox.setScope(.all)
        inbox.restoreParentFolds([uuid(lead): true, uuid(7): true, uuid(2): true])
        inbox.reload(rows: rows())
        inbox.layoutForQA()
        inbox.scrollToTopForQA()
        inbox.layoutForQA()

        func drawn() -> [(index: Int, item: InboxListItem, view: NSView?)] {
            inbox.itemsForQA.enumerated().map { ($0.offset, $0.element, inbox.cellForQA(atItem: $0.offset)) }
        }
        func settle() {
            inbox.layoutForQA()
            window.contentView?.layoutSubtreeIfNeeded()
        }
        if let dir = outputDirectory {
            try still(window: window, inbox: inbox, to: dir.appendingPathComponent("ledger-fixture-\(label).png"))
        }

        // 1. Counts, from the drawn rows.
        guard inbox.sidebarLayout == .ledger else { throw fail("layout is \(inbox.sidebarLayout)") }
        guard let leadIndex = inbox.itemsForQA.firstIndex(where: { $0.agentRow?.id == uuid(lead) }),
              let leadCell = inbox.cellForQA(atItem: leadIndex) as? AgentInbox96CellView else {
            throw fail("the lead's card is not drawn")
        }
        let chip = leadCell.branchLaneTextForQA
        guard chip.contains("18 helpers · 12 paused · 1 failed") else {
            throw fail("lead line 2 reads '\(chip)'")
        }
        guard chip.components(separatedBy: "failed").count == 2 else {
            throw fail("the card says failed more than once: '\(chip)'")
        }
        guard let help = leadCell.accessibilityHelp(),
              help.contains("18 helpers · 12 paused · 1 failed · 2 stopped · 3 done") else {
            throw fail("lead AX help reads '\(leadCell.accessibilityHelp() ?? "nil")'")
        }
        // Shown helpers under the lead + every drawn fold number = 18.
        var familyRows = 0
        var foldNumbers: [Int] = []
        var foldTitles: [String] = []
        var index = leadIndex + 1
        let items = inbox.itemsForQA
        while index < items.count {
            if case .agent(let row) = items[index] {
                if row.depth == 0 { break }
                familyRows += 1
            } else if case .fanoutRemainder = items[index] {
                guard let cell = inbox.cellForQA(atItem: index) as? AgentInboxRemainderView else {
                    throw fail("fold line \(index) has no remainder cell")
                }
                let title = cell.titleForQA
                foldTitles.append(title)
                guard title.contains(" folded"), let n = Int(title.prefix { $0.isNumber }) else {
                    throw fail("fold line reads '\(title)' (expected E's 'N folded' grammar)")
                }
                if title.contains("failed") { throw fail("fold line repeats failed: '\(title)'") }
                foldNumbers.append(n)
            } else {
                break
            }
            index += 1
        }
        let sum = familyRows + foldNumbers.reduce(0, +)
        guard sum == 18 else {
            throw fail("drawn helpers \(familyRows) + folds \(foldNumbers) = \(sum), not 18 (\(foldTitles))")
        }

        // 5. A tile-less helper is a normal row beside its tiled sibling.
        guard let noTile = items.firstIndex(where: { $0.agentRow?.id == uuid(19) }),
              let tiled = items.firstIndex(where: { $0.agentRow?.id == uuid(20) }),
              let noTileCell = inbox.cellForQA(atItem: noTile) as? AgentInbox96CellView,
              let tiledCell = inbox.cellForQA(atItem: tiled) as? AgentInbox96CellView else {
            throw fail("the two recent helpers are not drawn as cards")
        }
        guard noTileCell.frame.height == tiledCell.frame.height,
              noTileCell.ledgerStatusSymbolForQA == tiledCell.ledgerStatusSymbolForQA,
              noTileCell.ledgerStatusSymbolForQA == "checkmark.circle" else {
            throw fail("tile-less helper differs: \(noTileCell.frame.height)/\(noTileCell.ledgerStatusSymbolForQA ?? "nil") vs \(tiledCell.frame.height)/\(tiledCell.ledgerStatusSymbolForQA ?? "nil")")
        }

        // 2. Each failure class: its label and its one action, pressed.
        let expected: [(String, String, SidebarIncident.Kind)] = [
            ("Redesign tile agent bubble", "Respond", .needsYou),
            ("Claude usage ran out", "Switch & resume…", .cause(.usageLimit)),
            ("Codex usage ran out", "Switch & resume…", .cause(.usageLimit)),
            ("Claude sign-in expired", "Sign in…", .cause(.signInExpired)),
            ("Codex couldn't start", "Repair setup…", .cause(.couldNotStart)),
            ("Codex was busy", "Retry", .cause(.providerBusy)),
            ("Interrupted by restart", "Resume", .cause(.interruptedByRestart)),
            ("Failed", "Open", .cause(.taskError)),
        ]
        for (title, action, kind) in expected {
            guard let at = inbox.itemsForQA.firstIndex(where: {
                if case .incident(let incident) = $0 { return incident.title == title } else { return false }
            }) else {
                throw fail("no incident '\(title)'; drawn: \(inbox.drawnSequenceForQA.filter { $0.hasPrefix("!") })")
            }
            inbox.scrollItemToVisibleForQA(at)
            settle()
            guard let cell = inbox.cellForQA(atItem: at) as? SidebarIncidentCellView else {
                throw fail("incident '\(title)' has no incident cell")
            }
            guard cell.titleForQA == title, cell.actionButton.title == action,
                  cell.incident?.kind == kind else {
                throw fail("incident '\(title)' draws '\(cell.titleForQA)' / '\(cell.actionButton.title)'")
            }
            let before = pressed.count
            try press(cell.actionButton, in: window, "\(title) → \(action)")
            guard pressed.count == before + 1, pressed.last?.kind == kind, pressed.last?.title == title else {
                throw fail("pressing \(action) on '\(title)' reached the host as \(pressed.last.map { "\($0.title)" } ?? "nothing")")
            }
        }
        // The usage incident counts owners: 11 Claude agents, 11 can resume.
        if let claude = inbox.sidebarIncidents.first(where: { $0.title == "Claude usage ran out" }),
           claude.detail != "11 agents paused in 1 family · 11 can resume" {
            throw fail("usage detail reads '\(claude.detail)'")
        }

        // 3. Clear N, through its button.
        inbox.scrollToTopForQA()
        settle()
        guard let labelIndex = inbox.itemsForQA.firstIndex(where: {
            if case .sectionLabel(let section) = $0 { return section.clearCount > 0 } else { return false }
        }), let labelCell = inbox.cellForQA(atItem: labelIndex) as? SidebarSectionLabelView else {
            throw fail("no heading carries Clear N")
        }
        let clearTitle = labelCell.clearButton.title
        guard clearTitle == "Clear \(expectedClear.count)" else {
            throw fail("Clear reads '\(clearTitle)', expected Clear \(expectedClear.count)")
        }
        try press(labelCell.clearButton, in: window, "Clear")
        guard let clearAction = actions.last, clearAction.0 == .settle,
              Set(clearAction.1.map(number)) == expectedClear else {
            throw fail("Clear sent \(actions.last.map { "\($0.0) \($0.1.map(number).sorted())" } ?? "nothing")")
        }
        settle()
        let liveIDs = Set(inbox.itemsForQA.compactMap(\.agentRow).filter { $0.lifecycle == .active }.map { number($0.id) })
        for gone in [18, 19, 20, 30, 33, 34, 36] where liveIDs.contains(gone) {
            throw fail("cleared row \(gone) is still drawn in the live list")
        }
        for stays in [32, 35, lead] where !liveIDs.contains(stays) {
            throw fail("blocked row \(stays) left the list on Clear")
        }
        for paused in [14, 15, 16, 17] where !inbox.allRowsForQA.contains(where: { number($0.id) == paused && !$0.isCleared }) {
            throw fail("paused or setup helper \(paused) was cleared")
        }
        guard inbox.sidebarTallies[uuid(lead)]?.total == 18, inbox.sidebarTallies[uuid(lead)]?.reconciles == true else {
            throw fail("Clear changed the lead's total: \(String(describing: inbox.sidebarTallies[uuid(lead)]))")
        }
        let toast = inbox.undoToastTextForQA
        guard toast.hasPrefix("Cleared \(expectedClear.count)"), toast.contains("Undo") else {
            throw fail("toast reads '\(toast)'")
        }
        guard inbox.clickUndoForQA() else { throw fail("Undo did not press") }
        settle()
        let restored = Set(inbox.itemsForQA.compactMap(\.agentRow).filter { $0.lifecycle == .active }.map { number($0.id) })
        for back in [18, 19, 20, 30, 33, 34, 36] where !restored.contains(back) {
            throw fail("Undo did not bring back \(back)")
        }

        // 4. The setting re-renders live.
        let renders = inbox.sidebarLayoutRenderCountForQA
        defaults.set(SidebarLayout.quietInbox.rawValue, forKey: SidebarLayout.defaultsKey)
        SettingChangeEvent.post(SettingID(rawValue: SidebarLayout.defaultsKey))
        settle()
        let quietHasLedgerHead = inbox.itemsForQA.contains {
            if case .sectionLabel(let s) = $0 { return s.kind == .forYou } else { return false }
        }
        guard inbox.sidebarLayout == .quietInbox, inbox.sidebarLayoutRenderCountForQA == renders + 1,
              !quietHasLedgerHead else {
            throw fail("switching to Quiet inbox did not re-render (layout \(inbox.sidebarLayout))")
        }
        if let quietLead = inbox.itemsForQA.firstIndex(where: { $0.agentRow?.id == uuid(lead) }),
           let cell = inbox.cellForQA(atItem: quietLead) as? AgentInbox96CellView, cell.ledgerChipTextForQA != nil {
            throw fail("the Quiet inbox still draws the Ledger chip")
        }
        defaults.set(SidebarLayout.ledger.rawValue, forKey: SidebarLayout.defaultsKey)
        SettingChangeEvent.post(SettingID(rawValue: SidebarLayout.defaultsKey))
        settle()
        guard inbox.sidebarLayout == .ledger, inbox.sidebarLayoutRenderCountForQA == renders + 2,
              inbox.itemsForQA.contains(where: { if case .incident = $0 { return true } else { return false } }) else {
            throw fail("switching back to Ledger did not re-render")
        }
        return "  \(label): chip '18 helpers · 12 paused · 1 failed', \(familyRows) drawn + folds \(foldNumbers) = 18 (\(foldTitles.joined(separator: " / "))); "
            + "\(expected.count) incident actions pressed to the host; Clear \(expectedClear.count) left blockers, Undo restored; layout switch re-rendered twice; tile-less helper drawn like its sibling"
    }

    // MARK: - Persistence through a store reload

    static func checkPersistence() throws -> String {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("array-sidebar-ledger-check-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cwd = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        let first = AgentSupervisor(store: AgentStore(applicationSupportDirectory: root))
        let done = first.spawn(role: "reviewer", prompt: nil, cwd: cwd, model: "claude-opus-5-5", thinking: "medium")
        guard first.settle(agentID: done) else {
            throw Failure(description: "persistence: the supervisor refused to clear an idle agent")
        }
        let second = AgentSupervisor(store: AgentStore(applicationSupportDirectory: root))
        _ = second.restore()
        guard second.records[done]?.settledOverride == .settled else {
            throw Failure(description: "persistence: a reloaded store lost the clear (\(String(describing: second.records[done]?.settledOverride)))")
        }
        // New activity brings it back.
        second.qaDeliver(.turnStarted(threadId: AgentSupervisor.threadId(for: done), turnId: "again"), to: done, now: now)
        guard second.records[done]?.settledOverride == .neutral else {
            throw Failure(description: "persistence: new activity did not un-clear the agent")
        }
        return "  persistence: a cleared record stays cleared through a store reload; new activity un-clears it"
    }

    static func still(window: NSWindow, inbox: AgentInboxView, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        inbox.layoutForQA()
        guard let rep = inbox.bitmapImageRepForCachingDisplay(in: inbox.bounds) else { return }
        inbox.cacheDisplay(in: inbox.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
