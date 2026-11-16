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
//   2. each failure class draws its label and one action; "Switch & resume…"
//      reaches the host when pressed, the others draw disabled this release;
//   3. Clear N acts on exactly the clearable rows without telling the host: the
//      rows leave, blocked rows stay, Undo brings them back;
//   4. switching Settings > Sidebar > Layout re-renders the list live;
//   5. a tile-less helper draws as a normal row beside a tiled sibling.
// Clear is sidebar-only: it reaches no host action, its marks survive a second
// list on the same defaults (a store reload), and new activity releases them.
@MainActor
enum SidebarLedgerChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }

    /// Focus a negative-control run on one layout; the registered legs run both.
    static var layoutsUnderTest: [SidebarLayout] {
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--sidebar-check-layout"), args.indices.contains(index + 1),
           let layout = SidebarLayout(rawValue: args[index + 1]) { return [layout] }
        return SidebarLayout.allCases
    }

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
            let acts = kind == .cause(.usageLimit)
            guard cell.actionButton.isEnabled == acts else {
                throw fail("'\(action)' on '\(title)' is \(cell.actionButton.isEnabled ? "enabled" : "disabled")")
            }
            if acts {
                try press(cell.actionButton, in: window, "\(title) → \(action)")
                guard pressed.count == before + 1, pressed.last?.kind == kind, pressed.last?.title == title else {
                    throw fail("pressing \(action) on '\(title)' reached the host as \(pressed.last.map { "\($0.title)" } ?? "nothing")")
                }
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
        let hostActionsBefore = actions.count
        try press(labelCell.clearButton, in: window, "Clear")
        // Sidebar-only: Clear sends the host nothing (no Settle, no tile close).
        guard actions.count == hostActionsBefore else {
            throw fail("Clear reached the host: \(actions.suffix(actions.count - hostActionsBefore).map(\.0))")
        }
        guard Set(inbox.clearMarks.keys.map(number)) == expectedClear else {
            throw fail("Clear marked \(inbox.clearMarks.keys.map(number).sorted())")
        }
        settle()
        let liveIDs = Set(inbox.itemsForQA.compactMap(\.agentRow).filter { $0.lifecycle == .active }.map { number($0.id) })
        for gone in [18, 19, 20, 30, 33, 34, 36] where liveIDs.contains(gone) {
            throw fail("cleared row \(gone) is still drawn in the live list")
        }
        for stays in [32, 35, lead] where !liveIDs.contains(stays) {
            throw fail("blocked row \(stays) left the list on Clear")
        }
        for paused in [14, 15, 16, 17] where inbox.clearMarks[uuid(paused)] != nil {
            throw fail("paused or setup helper \(paused) was cleared")
        }
        // A store reload: a second list on the same defaults draws the same.
        let reloaded = AgentInboxView(frame: inbox.frame, indicatorDefaults: defaults)
        reloaded.clock = { now }
        reloaded.foldsUntouchedGroups = false
        reloaded.setScope(.all)
        reloaded.reload(rows: rows())
        let reloadedLive = Set(reloaded.itemsForQA.compactMap(\.agentRow).filter { $0.lifecycle == .active }.map { number($0.id) })
        for gone in [30, 33, 34, 36] where reloadedLive.contains(gone) {
            throw fail("after a reload, cleared \(gone) is back without new activity")
        }
        // New activity releases a mark: a newer terminal event on 36.
        let active = rows().map { row -> AgentInboxRow in
            guard row.id == uuid(36) else { return row }
            return row.withTerminalEventForQA(AgentTerminalEvent(sequence: 99, turnID: "again", outcome: .failed, endedAt: now))
        }
        reloaded.reload(rows: active)
        guard reloaded.itemsForQA.contains(where: { $0.agentRow?.id == uuid(36) && $0.agentRow?.lifecycle == .active }),
              reloaded.clearMarks[uuid(36)] == nil else {
            throw fail("new activity on a cleared agent did not bring it back")
        }
        guard inbox.sidebarTallies[uuid(lead)]?.total == 18, inbox.sidebarTallies[uuid(lead)]?.reconciles == true else {
            throw fail("Clear changed the lead's total: \(String(describing: inbox.sidebarTallies[uuid(lead)]))")
        }
        let toast = inbox.undoToastTextForQA
        guard toast.hasPrefix("Cleared \(expectedClear.count)"), toast.contains("Undo") else {
            throw fail("toast reads '\(toast)'")
        }
        try press(inbox.undoButtonForQA, in: window, "Undo")
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
        // A lead whose own turn also failed still says the failure word
        // once on its card. Its icon/age retain the lead's own outcome.
        let failedLead = rows().map { r -> AgentInboxRow in
            guard r.id == uuid(lead) else { return r }
            return row(lead, "Array release lead", outcome: .failed, detail: "Task exited with an error")
        }
        inbox.reload(rows: failedLead)
        settle()
        guard let failedCard = inbox.cellForQA(id: uuid(lead)) else { throw fail("failed lead has no card") }
        let said = failedCard.visibleTextForQA.joined(separator: " ").lowercased()
        guard said.components(separatedBy: "failed").count == 2 else {
            throw fail("failed is repeated on the lead card: '\(said)'")
        }
        return "  \(label): chip '18 helpers · 12 paused · 1 failed', \(familyRows) drawn + folds \(foldNumbers) = 18 (\(foldTitles.joined(separator: " / "))); "
            + "\(expected.count) incidents drawn with their actions, Switch & resume pressed to the host and the rest disabled; Clear \(expectedClear.count) left blockers, Undo restored; layout switch re-rendered twice; tile-less helper drawn like its sibling"
    }

    static func still(window: NSWindow, inbox: AgentInboxView, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        inbox.layoutForQA()
        guard let rep = inbox.bitmapImageRepForCachingDisplay(in: inbox.bounds) else { return }
        inbox.cacheDisplay(in: inbox.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}

// MARK: - Clear leaves every tile (`--sidebar-clear-tiles-check`)

extension SidebarLedgerChecks {
    /// The production app (WorkspaceAPIChecks fixture: real delegate, canvas,
    /// supervisor, store) with its real sidebar in a window. A finished lead
    /// with a tile and a finished helper; Clear pressed on its button through
    /// `NSApp.sendEvent`. Clear is an acknowledgement in the sidebar only: every
    /// tile stays on the canvas, no record is settled, the lead leaves the
    /// live list, and Undo brings it back.
    static func runClearTiles() throws -> String {
        try layoutsUnderTest.map { try checkClearTiles(layout: $0) }.joined(separator: "\n")
    }

    static func checkClearTiles(layout: SidebarLayout) throws -> String {
        guard let settings = QAIsolatedDefaults(isolatedSuiteName: "array.qa.sidebar-clear-tiles.\(UUID().uuidString)") else {
            throw Failure(description: "no isolated defaults suite")
        }
        defer { settings.removePersistentDomain(forName: settings.suiteDomainName) }
        var leadID: AgentID?
        let f = try WorkspaceAPIChecks.makeFixture(settings: settings, beforeMount: { delegate, _ in
            let store = AgentStore(smokeTest: false)
            let supervisor = delegate.qaAgentSupervisor
            guard var lead = supervisor.records.values.first(where: { $0.tileId != nil }) else {
                throw Failure(description: "fixture lead with a tile missing")
            }
            let ended = Date().addingTimeInterval(-3_600)
            lead.latestTerminalEvent = AgentTerminalEvent(sequence: 1, turnID: "t", outcome: .succeeded, endedAt: ended)
            lead.acknowledgedTerminalSequence = 1
            lead.runCompletedAt = ended
            try store.upsert(lead)
            var helper = AgentRecord(id: AgentID(rawValue: UUID()), displayName: "Finished helper", harness: .pi,
                model: lead.model, thinking: lead.thinking, cwd: lead.cwd, projectId: lead.projectId,
                parentAgentID: lead.id, createdAt: ended.addingTimeInterval(-60), lastActivityAt: ended)
            helper.latestTerminalEvent = AgentTerminalEvent(sequence: 1, turnID: "t", outcome: .succeeded, endedAt: ended)
            helper.acknowledgedTerminalSequence = 1
            helper.runCompletedAt = ended
            try store.upsert(helper)
            leadID = lead.id
        })
        defer { f.tearDown() }
        guard let leadID, let tileID = f.delegate.qaAgentSupervisor.records[leadID]?.tileId else {
            throw Failure(description: "the fixture lead has no tile after boot")
        }
        f.delegate.wireCanvasCallbacks(f.canvas)
        try f.delegate.reconciledManagedSessionSource.reconcile(
            registry: f.delegate.registryStore!.loadOrEmpty(), reason: .continuumRestarted, now: Date())
        let sidebar = WorkspaceSidebarView(frame: NSRect(x: 0, y: 0, width: 360, height: 1_000), inboxDefaults: settings)
        let window = SidebarOwnershipChecks.KeyWindow(contentRect: sidebar.frame, styleMask: [.borderless],
                                                      backing: .buffered, defer: false)
        window.contentView = sidebar
        window.orderFrontOffscreenForChecks()
        window.makeKey()
        defer { window.orderOut(nil) }
        f.delegate.qaInstallWorkspaceSidebar(sidebar)
        let inbox = sidebar.agentInbox
        inbox.setSidebarLayoutForQA(layout)
        inbox.setScope(.all)
        f.delegate.qaRefreshAgentSurfaces()
        inbox.layoutForQA()
        let tilesBefore = Set(f.canvas.allTilesInWorldFrames().map(\.id))
        guard f.canvas.tileView(for: tileID) != nil, tilesBefore.contains(tileID) else {
            throw Failure(description: "the lead's tile is not on the canvas before Clear")
        }
        guard inbox.sidebarClearIDs.contains(leadID.rawValue) else {
            let row = inbox.allRowsForQA.first { $0.id == leadID.rawValue }
            let why = row.map { "state \($0.state) lifecycle \($0.lifecycle) blocked \($0.settlementBlocked) refusal \(String(describing: SidebarClear.refusal(for: $0, standing: [])))" } ?? "no row"
            throw Failure(description: "the finished lead is not clearable (\(why)); rows \(inbox.allRowsForQA.count)")
        }
        guard let at = inbox.itemsForQA.firstIndex(where: {
            if case .sectionLabel(let s) = $0 { return s.clearCount > 0 } else { return false }
        }), let label = inbox.cellForQA(atItem: at) as? SidebarSectionLabelView else {
            throw Failure(description: "no Clear button drawn: \(inbox.drawnSequenceForQA)")
        }
        inbox.layoutForQA()
        window.contentView?.layoutSubtreeIfNeeded()
        try press(label.clearButton, in: window, "Clear")
        f.delegate.qaRefreshAgentSurfaces()
        inbox.layoutForQA()
        let tilesAfter = Set(f.canvas.allTilesInWorldFrames().map(\.id))
        guard f.canvas.tileView(for: tileID) != nil, tilesAfter == tilesBefore else {
            throw Failure(description: "Clear closed tiles: \(tilesBefore.subtracting(tilesAfter).count) gone (lead tile present: \(f.canvas.tileView(for: tileID) != nil))")
        }
        guard f.delegate.qaAgentSupervisor.records[leadID]?.settledOverride == .neutral else {
            throw Failure(description: "Clear settled the record (\(String(describing: f.delegate.qaAgentSupervisor.records[leadID]?.settledOverride)))")
        }
        let live = { inbox.itemsForQA.compactMap(\.agentRow).filter { $0.lifecycle == .active }.map(\.id) }
        guard !live().contains(leadID.rawValue) else {
            throw Failure(description: "the cleared lead is still in the live list")
        }
        guard inbox.undoToastTextForQA.hasPrefix("Cleared") else {
            throw Failure(description: "no Undo after Clear ('\(inbox.undoToastTextForQA)')")
        }
        try press(inbox.undoButtonForQA, in: window, "Undo")
        f.delegate.qaRefreshAgentSurfaces()
        inbox.layoutForQA()
        guard live().contains(leadID.rawValue), f.canvas.tileView(for: tileID) != nil else {
            throw Failure(description: "Undo did not bring the lead back")
        }
        // "Switch & resume…": a live usage stop on the helper, its incident's
        // button pressed through the window, Settings opens on Agents.
        f.delegate.qaAttachWindowForOfflineCheck(window)
        let supervisor = f.delegate.qaAgentSupervisor
        guard let helperID = supervisor.records.values.first(where: { $0.parentAgentID == leadID })?.id else {
            throw Failure(description: "the fixture helper is missing")
        }
        let thread = AgentSupervisor.threadId(for: helperID)
        supervisor.qaDeliver(.turnStarted(threadId: thread, turnId: "usage"), to: helperID)
        supervisor.qaDeliver(.turnCompleted(threadId: thread, turnId: "usage", outcome: .failed,
                                            errorMessage: "You've hit your 5-hour limit · resets 4:00 AM"), to: helperID)
        f.delegate.qaRefreshAgentSurfaces()
        inbox.layoutForQA()
        guard let usageAt = inbox.itemsForQA.firstIndex(where: {
            if case .incident(let i) = $0 { return i.kind == .cause(.usageLimit) } else { return false }
        }), let usageCell = inbox.cellForQA(atItem: usageAt) as? SidebarIncidentCellView else {
            let helperRow = inbox.allRowsForQA.first { $0.id == helperID.rawValue }
            throw Failure(description: "no usage incident drawn (helper state \(String(describing: helperRow?.state)), detail \(helperRow?.failureDetail ?? "nil"))")
        }
        window.contentView?.layoutSubtreeIfNeeded()
        guard usageCell.actionButton.title == "Switch & resume…", usageCell.actionButton.isEnabled else {
            throw Failure(description: "usage action reads '\(usageCell.actionButton.title)', enabled \(usageCell.actionButton.isEnabled)")
        }
        try press(usageCell.actionButton, in: window, "Switch & resume…")
        guard let modal = f.delegate.qaSettingsModal, modal.isVisible, modal.model.selectedPaneID == "agents" else {
            throw Failure(description: "Switch & resume did not open Settings > Agents (modal \(f.delegate.qaSettingsModal?.isVisible == true), pane \(f.delegate.qaSettingsModal?.model.selectedPaneID ?? "nil"))")
        }
        return "SidebarClearTilesChecks passed (\(layout.title)): Switch & resume… pressed through the window opened Settings > Agents (accounts); Clear through the real button left all \(tilesBefore.count) tiles on the canvas, settled no record, moved the lead out of the live list, and Undo brought it back"
    }
}

extension AgentInboxRow {
    /// The same row with a newer terminal event, for the release witness.
    func withTerminalEventForQA(_ event: AgentTerminalEvent) -> AgentInboxRow {
        var row = AgentInboxRow(
            id: id, title: title, projectName: projectName, projectId: projectId, directoryName: directoryName,
            workspaceName: workspaceName, workspaceId: workspaceId, state: state, attention: attention,
            lifecycle: lifecycle, model: model, role: role, branch: branch, isIsolated: isIsolated,
            elapsed: elapsed, elapsedStartedAt: elapsedStartedAt, lastActiveAt: event.endedAt, depth: depth,
            createdAt: createdAt, parentId: parentId, settlementBlocked: settlementBlocked, zoneName: zoneName,
            harness: harness, checkedOutBranch: checkedOutBranch, terminalEvent: event,
            terminalIsUnread: true, identityColor: identityColor, hasTile: hasTile, isPinned: isPinned)
        row.failureDetail = failureDetail
        return row
    }
}

// The combined branch's shared contract, driven through the real controls in
// both layouts. The Quiet fixture is intentionally the same nested 18 as Ledger.
extension SidebarLedgerChecks {
    static func runLayouts() throws -> String {
        QuickHideChecks.acceptFirstMouseEverywhere()
        var reports: [String] = []
        for layout in layoutsUnderTest {
            let name = "array.sidebar-layouts.\(UUID().uuidString)"
            let defaults = QAIsolatedDefaults(isolatedSuiteName: name)!
            defer { defaults.removePersistentDomain(forName: name) }
            defaults.set(layout.rawValue, forKey: SidebarLayout.defaultsKey)
            let inbox = AgentInboxView(frame: NSRect(x: 0, y: 0, width: 494, height: 2600), indicatorDefaults: defaults)
            inbox.clock = { now }
            inbox.foldsUntouchedGroups = false
            inbox.prefersReducedMotion = { true }
            inbox.hoverCardEnabled = false
            inbox.onIncidentAction = { _ in }
            var hostActions = 0
            inbox.onRowAction = { _, _ in hostActions += 1 }
            inbox.wiredRowActions = AppDelegate.wiredInboxRowActions
            let window = SidebarOwnershipChecks.KeyWindow(contentRect: inbox.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = inbox
            window.orderFrontOffscreenForChecks()
            window.makeKey()
            defer { window.orderOut(nil) }
            inbox.setScope(.all)
            inbox.restoreParentFolds([uuid(lead): true, uuid(7): true, uuid(2): true])
            inbox.reload(rows: rows())
            inbox.layoutForQA()

            func expect(_ value: Bool, _ message: String) throws {
                if !value { throw Failure(description: "\(layout.title): \(message)") }
            }
            func liveIDs() -> Set<UUID> {
                Set(inbox.itemsForQA.compactMap(\.agentRow).filter { $0.lifecycle == .active }.map(\.id))
            }
            func familyCounts() throws -> (shown: Int, folded: Int) {
                guard let start = inbox.itemsForQA.firstIndex(where: { $0.agentRow?.id == uuid(lead) }),
                      let card = inbox.cellForQA(atItem: start) as? AgentInbox96CellView else {
                    throw Failure(description: "\(layout.title): no rendered lead")
                }
                let ax = card.accessibilityHelp() ?? ""
                try expect(ax.contains("18 helpers · 12 paused · 1 failed · 2 stopped · 3 done"), "rendered AX partition: '\(ax)'")
                try expect(card.visibleTextForQA.contains("18"), "rendered disclosure does not count 18: \(card.visibleTextForQA)")
                var shown = 0, folded = 0
                for index in (start + 1)..<inbox.itemsForQA.count {
                    switch inbox.itemsForQA[index] {
                    case .agent(let row):
                        if row.depth == 0 { return (shown, folded) }
                        try expect(inbox.cellForQA(atItem: index) is AgentInbox96CellView, "helper is not a normal rendered row")
                        shown += 1
                    case .fanoutRemainder:
                        guard let line = inbox.cellForQA(atItem: index) as? AgentInboxRemainderView,
                              let number = Int(line.titleForQA.prefix(while: { $0.isNumber })) else {
                            throw Failure(description: "\(layout.title): no rendered fold number")
                        }
                        folded += number
                    default: return (shown, folded)
                    }
                }
                return (shown, folded)
            }
            // Open and re-fold the actual remainder control before reading the
            // drawn rows and AX; this is the production event/render path.
            for _ in 0..<2 {
                guard let index = inbox.itemsForQA.firstIndex(where: {
                    if case .fanoutRemainder(let r) = $0 { return r.parentId == uuid(lead) }; return false
                }), let line = inbox.cellForQA(atItem: index) as? AgentInboxRemainderView else {
                    throw Failure(description: "\(layout.title): missing lead fold control")
                }
                inbox.scrollItemToVisibleForQA(index)
                inbox.layoutForQA()
                try press(line.buttonForQA, in: window, "fold")
                inbox.layoutForQA()
            }
            let count = try familyCounts()
            try expect(count.shown + count.folded == 18, "rendered \(count.shown) shown + \(count.folded) folded != 18")
            let countAX = inbox.cellForQA(id: uuid(lead))?.accessibilityHelp() ?? ""
            try expect(countAX.contains("\(count.shown) shown, \(count.folded) folded"), "rendered rows and AX disagree: \(countAX)")

            // Settings' real ChoiceButton -> defaults -> event -> existing list.
            let model = SettingsModel(defaults: defaults, navKeymap: .resolve(defaults: defaults, warn: { _ in }), initialPaneID: "appearance")
            let settings = SettingsFixtureWindow(model: model, size: NSSize(width: 1100, height: 1100), appearance: NSAppearance(named: .darkAqua))
            defer { settings.tearDown() }
            settings.show(paneID: "appearance")
            if let entry = model.entries().first(where: { $0.field?.key == SidebarLayout.defaultsKey }) {
                model.reveal(entry)
                settings.settle()
            }
            let renderCount = inbox.sidebarLayoutRenderCountForQA
            for next in [layout == .ledger ? SidebarLayout.quietInbox : .ledger, layout] {
                guard let button = settings.descendants(ChoiceButton.self).first(where: { $0.accessibilityIdentifier() == "settings.sidebarLayout" }) else {
                    throw Failure(description: "Settings has no Layout choice")
                }
                button.presentsOffscreenForQA = true
                button.scrollToVisible(button.bounds.insetBy(dx: 0, dy: -80))
                settings.settle()
                try QuickHideChecks.click(button)
                settings.settle()
                guard let option = button.qaPresentedList?.rowView(id: next.rawValue) else {
                    throw Failure(description: "Layout choice has no \(next.title)")
                }
                button.qaPresentedPanel?.makeKey()
                try QuickHideChecks.click(option)
                settings.settle()
                inbox.layoutForQA()
                try expect(inbox.sidebarLayout == next, "real Settings choice did not reach the live list")
                let hasLedger = inbox.itemsForQA.contains { if case .sectionLabel(let s) = $0 { return s.kind == .forYou }; return false }
                try expect(hasLedger == (next == .ledger), "real Settings choice left the previous rendered head")
            }
            try expect(inbox.sidebarLayoutRenderCountForQA == renderCount + 2, "Layout did not re-render twice")

            // Clear and its actual Undo button; blockers refuse, marks reload,
            // and a newly working helper releases its cleared family's mark.
            window.makeKey()
            inbox.scrollToTopForQA()
            inbox.layoutForQA()
            guard let index = inbox.itemsForQA.firstIndex(where: {
                if case .sectionLabel(let s) = $0 { return s.clearCount > 0 }; return false
            }), let heading = inbox.cellForQA(atItem: index) as? SidebarSectionLabelView else {
                throw Failure(description: "\(layout.title): missing Clear control")
            }
            let before = liveIDs()
            try press(heading.clearButton, in: window, "Clear")
            inbox.layoutForQA()
            try expect(hostActions == 0, "Clear called a host lifecycle action")
            try expect(!liveIDs().contains(uuid(30)) && !liveIDs().contains(uuid(19)), "Clear left clearable rows drawn")
            try expect(liveIDs().contains(uuid(32)) && liveIDs().contains(uuid(35)), "Clear hid a blocker")
            let loaded = AgentInboxView(frame: inbox.frame, indicatorDefaults: defaults)
            loaded.clock = { now }
            loaded.setScope(.all)
            loaded.reload(rows: rows())
            try expect(loaded.clearMarks == inbox.clearMarks && loaded.clearMarks[uuid(30)] != nil, "Clear marks did not survive store reload")
            let activeChild = rows().map { r in
                r.id == uuid(31) ? row(31, "Canvas review helper", parent: 30, state: .working, outcome: nil) : r
            }
            inbox.reload(rows: activeChild)
            inbox.layoutForQA()
            try expect(liveIDs().contains(uuid(30)) && inbox.clearMarks[uuid(30)] == nil, "helper activity left its cleared family in History")
            try press(inbox.undoButtonForQA, in: window, "Undo")
            inbox.layoutForQA()
            try expect(liveIDs().isSuperset(of: before), "Undo did not restore the live rows")
            reports.append("\(layout.title): 18 = 12 paused + 1 failed + 2 stopped + 3 done = \(count.shown) shown + \(count.folded) folded from rendered rows/AX; fold, Settings Layout, Clear and Undo used NSApp.sendEvent; blockers stayed, marks reloaded, helper activity restored its family")
        }
        return "SidebarLayoutsChecks passed:\n" + reports.joined(separator: "\n")
    }
}

// MARK: - Stills of a copied real store (`--sidebar-real-stills-check <store> <out>`)

extension SidebarLedgerChecks {
    /// Renders Ledger and Quiet inbox, dark and light, from a COPY of an Array
    /// application-support folder (agents + agent-transcripts). Reads the copy
    /// only; writes only the PNGs. Rows come from the production builder;
    /// each failed record's words come from its transcript's last error, the
    /// rule `AgentSupervisor.sidebarFailureDetail` applies.
    static func runRealStills(store root: URL, output: URL) async throws -> String {
        let records = try AgentStore(applicationSupportDirectory: root).loadAll()
        let transcripts = AgentTranscriptStore(root: root.appendingPathComponent("agent-transcripts", isDirectory: true))
        var details: [UUID: String] = [:]
        for record in records {
            guard let outcome = record.latestTerminalEvent?.outcome,
                  [.failed, .runtimeError, .interrupted].contains(outcome) else { continue }
            if let document = try? await transcripts.load(
                agentID: record.id, sessionID: AgentTranscriptStore.canonicalSessionID(for: record.id)),
               let message = AgentSupervisor.lastErrorMessage(in: document) {
                details[record.id.rawValue] = message
            }
        }
        let now = Date()
        let context = AgentContextIndex.build(
            registry: .empty(), documents: [:], projectCanvases: [:], terminalDescriptors: [], agents: records)
        let snapshot = AgentInventory.snapshot(
            terminalDescriptors: [], liveStatuses: [:], agents: records, activityByAgent: [:],
            replicaId: UUID(), now: now)
        let rows = AgentInboxRowBuilder.rows(
            from: snapshot, context: context,
            records: Dictionary(uniqueKeysWithValues: records.map { ($0.id.rawValue, $0) }),
            failureDetails: details, now: now)
        var written: [String] = []
        try await MainActor.run {
            for layout in SidebarLayout.allCases {
                for dark in [true, false] {
                    let inbox = AgentInboxView(frame: NSRect(x: 0, y: 0, width: 494, height: 1_110),
                                               indicatorDefaults: defaults(layout))
                    inbox.clock = { now }
                    inbox.prefersReducedMotion = { true }
                    inbox.hoverCardEnabled = false
                    inbox.onIncidentAction = { _ in }
                    let window = SidebarOwnershipChecks.KeyWindow(contentRect: inbox.frame, styleMask: [.borderless],
                                                                  backing: .buffered, defer: false)
                    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    window.contentView = inbox
                    window.orderFrontOffscreenForChecks()
                    inbox.setScope(.all)
                    inbox.foldsHistoryIntoShelf = true
                    inbox.reload(rows: rows)
                    inbox.layoutForQA()
                    inbox.scrollToTopForQA()
                    inbox.layoutForQA()
                    let name = "real-\(layout.rawValue)-\(dark ? "dark" : "light").png"
                    try still(window: window, inbox: inbox, to: output.appendingPathComponent(name))
                    window.orderOut(nil)
                    written.append(name)
                }
            }
        }
        let failed = rows.filter { SidebarRecovery.cause(for: $0) != nil }.count
        return "SidebarRealStills: \(records.count) copied records, \(details.count) failure details read, \(failed) rows with a cause; wrote \(written.joined(separator: ", "))"
    }
}
