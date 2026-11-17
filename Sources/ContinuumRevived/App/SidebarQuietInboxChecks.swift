import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

// Sidebar round, Quiet inbox (variants/A). `--sidebar-quiet-inbox-check [dir]`.
//
// Boots the production fixture, installs the sidebar the way boot does (its
// layout read from a throwaway suite, never the standard domain), makes real
// agents through the supervisor and finishes their turns through its own
// delivery path. Then, through `NSApp.sendEvent` on the drawn controls:
//
//  1. the setting re-renders the list live, Ledger <-> Quiet;
//  2. the head is "Inbox · Clear N", the "Needs you" box (blocking only) and
//     one cause chip with one action per family;
//  3. the counts add up from what is drawn: chip count = the lead's paused
//     tally, and the family's rendered rows + folded = its total;
//  4. each action reaches the host with that family's agents only;
//  5. Clear takes the clearable rows (never the paused ones) and ⌘Z puts them
//     back;
//  6. once nothing blocks, there is no box at all, never an empty-state row.
@MainActor
enum SidebarQuietInboxChecks {
    nonisolated static let flag = "--sidebar-quiet-inbox-check"
    typealias Q = QuickHideChecks
    struct Failure: Error, CustomStringConvertible { let description: String }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String) throws {
        if !condition() { throw Failure(description: message()) }
    }

    static let usageWords = "You've hit your 5-hour limit · resets 1:20 AM"
    static let taskWords = "Tests failed: 3 of 40 in RunLedgerChecks"

    /// Stills of a COPY of real records: `ARRAY_QUIET_STILLS_SUPPORT` names a
    /// /tmp copy of an app-support dir (agents + agent-transcripts); the PNGs
    /// go to the folder after the flag (`quiet-light.png`, `quiet-dark.png`). Never pass the real directory.
    static func runStills(support: URL) throws -> String {
        guard support.path.hasPrefix("/tmp/") || support.path.hasPrefix("/private/tmp/") else {
            throw Failure(description: "stills read a /tmp copy only — got \(support.path)")
        }
        guard let suite = QAIsolatedDefaults(isolatedSuiteName: "dev.arrayapp.qa.quiet-stills.\(UUID().uuidString)") else {
            throw Failure(description: "no isolated defaults suite")
        }
        suite.set(SidebarLayout.quietInbox.rawValue, forKey: SidebarLayout.defaultsKey)
        let delegate = AppDelegate()
        // The copy's registry and workspace documents, so a tile some document
        // holds is reachable (a nil store would derive every tile closed).
        delegate.registryStore = RegistryStore(applicationSupportDirectory: support)
        let supervisor = AgentSupervisor(
            store: AgentStore(applicationSupportDirectory: support),
            makeRunner: { _ in ScriptedAgentRunner(script: []) },
            transcriptStore: AgentTranscriptStore(root: support.appendingPathComponent("agent-transcripts", isDirectory: true)))
        delegate.agentSupervisor = supervisor
        _ = supervisor.restore()
        let height: CGFloat = 2_000
        let window = Q.KeyWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: height),
                                 styleMask: [.borderless], backing: .buffered, defer: false)
        let sidebar = WorkspaceSidebarView(frame: NSRect(x: 0, y: 0, width: 360, height: height), inboxDefaults: suite)
        window.contentView = sidebar
        window.orderFrontOffscreenForChecks()
        defer { window.orderOut(nil) }
        try delegate.reconciledManagedSessionSource.reconcile(
            registry: try RegistryStore(applicationSupportDirectory: support).loadOrEmpty(),
            reason: .continuumRestarted, now: Date())
        delegate.qaInstallWorkspaceSidebar(sidebar)
        supervisor.onFailureDetailsLoaded = { delegate.qaRefreshAgentSurfaces() }
        let inbox = sidebar.inboxForQA
        inbox.pinScrollerStyleForQA()
        inbox.prefersReducedMotion = { true }
        inbox.hoverCardEnabled = false
        inbox.setScope(.all)
        delegate.qaRefreshAgentSurfaces()
        // The failure words load from the transcripts off the main thread.
        for _ in 0..<10 {
            RunLoop.main.run(until: Date().addingTimeInterval(1.5))
            delegate.qaRefreshAgentSurfaces()
        }
        inbox.layoutForQA()
        if let scroll = inbox.tableForQA.enclosingScrollView {
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        inbox.layoutForQA()
        Q.photograph(sidebar, "quiet")
        // A cheap cost reading on the real-state copy: one full sidebar rebuild
        // (core, items, every row's cell), the median of five.
        var rebuilds: [Double] = []
        for _ in 0..<5 {
            let start = CFAbsoluteTimeGetCurrent()
            inbox.reload(rows: inbox.allRowsForQuietCheck)
            inbox.layoutForQA()
            rebuilds.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
        }
        let rebuildMs = rebuilds.sorted()[2]
        let head = inbox.itemsForQuietCheck.prefix(12).map { item -> String in
            switch item {
            case .sectionLabel(let label): return "[\(label.title)\(label.clearCount > 0 ? " · Clear \(label.clearCount)" : "")]"
            case .quietNeedsYou(let lines): return "{Needs you: " + lines.map { "\($0.title) — \($0.detail) → \($0.actionTitle)" }.joined(separator: "; ") + "}"
            case .incident(let incident): return "<\(incident.title): \(incident.detail) → \(incident.actionTitle)>"
            case .agent(let row): return row.displayTitle
            default: return "·\(String(describing: item).prefix(30))"
            }
        }
        return "Quiet stills from \(supervisor.records.count) records, rebuild \(String(format: "%.1f", rebuildMs)) ms median of 5, \(inbox.allRowsForQuietCheck.count) rows, layout \(inbox.sidebarLayout), incidents \(inbox.sidebarIncidents.count), clear \(inbox.sidebarClearIDs.count), active \(inbox.allRowsForQuietCheck.filter { $0.lifecycle == .active }.count), lifecycles \(Dictionary(grouping: inbox.allRowsForQuietCheck, by: { String(describing: $0.lifecycle).prefix(8) }).mapValues(\.count)), failed+detail \(inbox.allRowsForQuietCheck.filter { $0.lifecycle == .active && $0.failureDetail != nil }.count): " + head.joined(separator: " | ")
    }

    static func run() throws -> String {
        if let support = ProcessInfo.processInfo.environment["ARRAY_QUIET_STILLS_SUPPORT"] {
            return try runStills(support: URL(fileURLWithPath: support))
        }
        Q.acceptFirstMouseEverywhere()
        guard let suite = QAIsolatedDefaults(isolatedSuiteName: "dev.arrayapp.qa.quiet-inbox.\(UUID().uuidString)") else {
            throw Failure(description: "no isolated defaults suite")
        }
        let fixture = try WorkspaceAPIChecks.makeFixture(settings: suite)
        let delegate = fixture.delegate
        let supervisor = delegate.qaAgentSupervisor
        let window = Q.KeyWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 1_100),
                                 styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        let sidebar = WorkspaceSidebarView(frame: NSRect(x: 0, y: 0, width: 380, height: 1_100), inboxDefaults: suite)
        window.contentView = sidebar
        window.orderFrontOffscreenForChecks()
        window.makeKey()
        defer { window.orderOut(nil); try? FileManager.default.removeItem(at: fixture.tempRoot) }
        // As boot does (QuickHideChecks.makeHarness): the managed-session source
        // reconciles before the sidebar is installed.
        let appSupport = fixture.tempRoot.appendingPathComponent("AppSupport", isDirectory: true)
        try delegate.reconciledManagedSessionSource.reconcile(
            registry: try RegistryStore(applicationSupportDirectory: appSupport).loadOrEmpty(),
            reason: .continuumRestarted, now: Date())
        delegate.qaInstallWorkspaceSidebar(sidebar)
        let inbox = sidebar.inboxForQA
        inbox.pinScrollerStyleForQA()
        inbox.prefersReducedMotion = { true }
        inbox.hoverCardEnabled = false
        inbox.setScope(.all)

        // The agents: a release lead with two usage pauses, one failed and one
        // finished helper; a finished family whose helper failed; a finished
        // top-level agent. (A provider-busy failure is retried by the
        // supervisor, so it would read as working here.)
        func spawn(_ name: String, parent: AgentID? = nil) -> AgentID {
            supervisor.spawn(role: nil, prompt: nil, cwd: fixture.pbRoot, harness: .pi,
                             model: "openai-codex/gpt-5.6-sol", thinking: "high",
                             projectId: fixture.projectPb, projectRoot: fixture.pbRoot,
                             parentAgentID: parent, displayName: name)
        }
        var turn = 0
        func finish(_ id: AgentID, failed words: String? = nil) {
            turn += 1
            let thread = AgentSupervisor.threadId(for: id)
            supervisor.qaDeliver(.turnStarted(threadId: thread, turnId: "t\(turn)"), to: id)
            supervisor.qaDeliver(.turnCompleted(threadId: thread, turnId: "t\(turn)",
                                                outcome: words == nil ? .completed : .failed,
                                                errorMessage: words), to: id)
        }
        let lead = spawn("Release lead")
        let paused1 = spawn("Overnight helper", parent: lead)
        let paused2 = spawn("Sidebar helper", parent: lead)
        let failedHelper = spawn("Retry the bench", parent: lead)
        let doneHelper = spawn("Write the ledger row", parent: lead)
        let family = spawn("Assess app progress")
        let familyHelper = spawn("Count the launch blockers", parent: family)
        let solo = spawn("Draft the release notes")
        for id in [lead, doneHelper, family, solo] { finish(id) }
        finish(paused1, failed: usageWords)
        finish(paused2, failed: usageWords)
        finish(failedHelper, failed: taskWords)
        finish(familyHelper, failed: taskWords)
        // The fixture's own source agent has never run: settle it so the head
        // is only about the agents above.
        _ = supervisor.settle(agentID: fixture.agentId)
        delegate.qaRefreshAgentSurfaces()
        inbox.layoutForQA()

        func settings(_ layout: SidebarLayout) {
            suite.set(layout.rawValue, forKey: SidebarLayout.defaultsKey)
            SettingChangeEvent.post(SettingID(rawValue: SidebarLayout.defaultsKey))
            inbox.layoutForQA()
        }
        func needsYouBox() -> SidebarQuietNeedsYouView? {
            Q.views(in: inbox) { $0 is SidebarQuietNeedsYouView && !$0.isHiddenOrHasHiddenAncestor }.first
                as? SidebarQuietNeedsYouView
        }
        func boxItems() -> Int {
            inbox.itemsForQuietCheck.filter { if case .quietNeedsYou = $0 { return true } else { return false } }.count
        }
        func sectionCell(_ title: String) -> SidebarSectionLabelView? {
            Q.views(in: inbox) {
                ($0 as? SidebarSectionLabelView)?.titleForQA.hasPrefix(title) == true && !$0.isHiddenOrHasHiddenAncestor
            }.first as? SidebarSectionLabelView
        }
        func chipCells() -> [SidebarIncidentCellView] {
            Q.views(in: inbox) {
                ($0 as? SidebarIncidentCellView)?.incident?.id.hasPrefix("family:") == true && !$0.isHiddenOrHasHiddenAncestor
            }.compactMap { $0 as? SidebarIncidentCellView }
        }
        func causeLines() -> [AgentInboxRemainderView] {
            Q.views(in: inbox) {
                ($0 as? AgentInboxRemainderView)?.causeIncidentForQA != nil && !$0.isHiddenOrHasHiddenAncestor
            }.compactMap { $0 as? AgentInboxRemainderView }
        }
        /// What Dylan asked of the Quiet sidebar (sidebar night fixes), read from
        /// the drawn tree: the head and every family action are plain words
        /// (no fill or capsule at rest or under the pointer); Clear's glyph is
        /// the checkmark; no hand symbol and no emoji anywhere; and a card says
        /// "N failed" at most once across its lead, its cause line and its fold.
        func expectMinimalChrome(_ step: String) throws {
            inbox.layoutForQA()
            var actions: [InboxSettleNudgeButton] = []
            if let clear = sectionCell("Inbox")?.clearButton, !clear.isHidden { actions.append(clear) }
            actions += needsYouBox()?.lines.map(\.actionButton) ?? []
            actions += causeLines().compactMap(\.causeActionForQA)
            try expect(!actions.isEmpty, "\(step): there are head and family actions to read")
            for action in actions {
                for hovered in [false, true] {
                    action.isPointerInside = hovered
                    action.layoutSubtreeIfNeeded()
                    try expect(action.isPlain && action.layer?.backgroundColor == nil && (action.layer?.cornerRadius ?? 0) == 0
                               && !action.isBordered,
                               "\(step): '\(action.title)' draws as a capsule or pill (hovered \(hovered)): fill \(String(describing: action.layer?.backgroundColor)), radius \(action.layer?.cornerRadius ?? 0)")
                }
                action.isPointerInside = false
            }
            try expect(SidebarSectionLabelView.clearSymbol == "checkmark" && sectionCell("Inbox")?.clearButton.image != nil,
                       "\(step): Clear's glyph is the plain checkmark")
            var symbols = inbox.sidebarIncidents.map(\.symbol) + causeLines().compactMap { $0.causeIncidentForQA?.symbol }
            symbols += needsYouBox()?.lines.compactMap { $0.incident?.symbol } ?? []
            symbols += inbox.qaMaterializedRowCells.compactMap { ($0 as? AgentInbox96CellView)?.qaGlyph }
            symbols += SidebarTallyState.allCases.map(\.symbol) + AgentInbox96CellView.statusSymbolsInUse
            try expect(!symbols.contains { $0.contains("hand") }, "\(step): a hand symbol is drawn — \(symbols.filter { $0.contains("hand") })")
            let words = Q.views(in: inbox) { $0 is NSTextField && !$0.isHiddenOrHasHiddenAncestor }
                .compactMap { ($0 as? NSTextField)?.stringValue }
                + actions.map(\.title)
            let emoji = words.filter { $0.unicodeScalars.contains { $0.properties.isEmojiPresentation } }
            try expect(emoji.isEmpty, "\(step): emoji drawn in \(emoji)")
            let failedCount = try NSRegularExpression(pattern: "\\d+ failed")
            func failures(_ text: String) -> Int {
                failedCount.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
            }
            for leadRow in inbox.allRowsForQuietCheck where leadRow.depth == 0 && leadRow.parentId == nil {
                guard let cell = inbox.cellForQA(id: leadRow.id) as? AgentInbox96CellView else { continue }
                var card = (cell.visibleTextForQA + [inbox.countLineTextForQA(id: leadRow.id) ?? ""]).joined(separator: " | ")
                card += causeLines().filter { $0.causeIncidentForQA?.familyIDs == [leadRow.id] }.map { " | " + $0.titleForQA }.joined()
                card += inbox.ownershipRemaindersForQA.filter { $0.qaParentID == leadRow.id }.map { " | " + $0.qaTitle }.joined()
                try expect(failures(card) <= 1, "\(step): '\(leadRow.displayTitle)' says failed \(failures(card)) times: \(card)")
                // One word per state: an interrupted helper is never "stopped", and
                // the fold names no state, so each number is said once.
                try expect(!card.localizedCaseInsensitiveContains("stopped"),
                           "\(step): '\(leadRow.displayTitle)' names a state with a second word: \(card)")
                for fold in inbox.ownershipRemaindersForQA where fold.qaParentID == leadRow.id {
                    let title = fold.qaTitle
                    try expect(title == "Show less" || title.range(of: "^\\d+ folded$", options: .regularExpression) != nil,
                               "\(step): '\(leadRow.displayTitle)''s fold says more than what it folds: '\(title)'")
                }
            }
        }
        func drawnAgentIDs() -> Set<UUID> {
            inbox.layoutForQA()
            return Set(inbox.qaMaterializedRowCells.compactMap { cell -> UUID? in
                guard let view = cell as? NSView, !view.isHiddenOrHasHiddenAncestor else { return nil }
                return cell.qaAgentID
            })
        }

        // 1. Live switching: Ledger draws no box; the setting brings Quiet in
        // without any reload of the rows.
        settings(.ledger)
        try expect(inbox.sidebarLayout == .ledger && boxItems() == 0 && needsYouBox() == nil,
                   "Ledger draws no Quiet box")
        let rendersBefore = inbox.sidebarLayoutRenderCountForQA
        settings(.quietInbox)
        try expect(inbox.sidebarLayout == .quietInbox && inbox.sidebarLayoutRenderCountForQA == rendersBefore + 1,
                   "the Layout setting re-renders the list live")

        // 2. The head.
        guard let box = needsYouBox() else {
            throw Failure(description: "Quiet draws the Needs you box while usage blocks — items \(inbox.itemsForQuietCheck.count), rows \(inbox.allRowsForQuietCheck.map { "\($0.displayTitle):\($0.state):\($0.lifecycle):\($0.failureDetail ?? "-")" }), incidents \(inbox.sidebarIncidents.map(\.title))")
        }
        try expect(box.accessibilityLabel() == "Needs you, 1" && box.lines.count == 1,
                   "one blocking incident, one line — got \(box.accessibilityLabel() ?? "nil"), \(box.lines.count) lines")
        let usageLine = box.lines[0]
        try expect(usageLine.incident?.kind == .cause(.usageLimit) && usageLine.actionButton.title == "Switch & resume…",
                   "the box's line is the usage pause with its one action — got \(usageLine.accessibilityLabel() ?? "")")
        guard let inboxLabel = sectionCell("Inbox") else { throw Failure(description: "no Inbox heading") }
        let clearIDs = inbox.sidebarClearIDs
        try expect(!inboxLabel.clearButton.isHidden && inboxLabel.clearButton.title == "Clear \(clearIDs.count)",
                   "Inbox carries Clear N — got '\(inboxLabel.clearButton.title)'")
        let expectedClear: Set<UUID> = [family.rawValue, solo.rawValue, failedHelper.rawValue, doneHelper.rawValue]
        try expect(Set(clearIDs) == expectedClear,
                   "Clear takes the finished family, the finished agent and the lead's settled helpers, never the paused — got \(clearIDs.map { id in inbox.allRowsForQuietCheck.first { $0.id == id }?.displayTitle ?? "?" }); rows \(inbox.allRowsForQuietCheck.map { "\($0.displayTitle):\($0.state):\($0.lifecycle):\($0.terminalEvent.map { "\($0.outcome)" } ?? "-"):blocked=\($0.settlementBlocked)" })")

        // Family causes sit inside their own cards, never stacked under the box.
        try expect(chipCells().isEmpty, "no family rows stack under the Needs you box — got \(chipCells().map(\.detailForQA))")
        let causes = causeLines()
        let leadCause = causes.first { $0.causeIncidentForQA?.familyIDs == [lead.rawValue] }
        let familyCause = causes.first { $0.causeIncidentForQA?.familyIDs == [family.rawValue] }
        try expect(causes.count == 2, "one cause line per family with a cause — got \(causes.map(\.titleForQA))")
        try expect(leadCause?.titleForQA.hasSuffix("2 paused · usage") == true
                   && leadCause?.causeActionForQA?.title == "Switch & resume…",
                   "the release family's ONE cause line is its usage pause — got \(leadCause?.titleForQA ?? "nil")")
        try expect(familyCause?.titleForQA.hasSuffix(taskWords) == true && familyCause?.causeActionForQA?.title == "Open",
                   "the failed family's cause line names its reason and one action — got \(familyCause?.titleForQA ?? "nil")")
        // Each card, as variants/A: the lead (project and branch on line 2),
        // its count line, its cause line, each drawn right under the one before.
        for (line, leadID) in [(leadCause, lead.rawValue), (familyCause, family.rawValue)] {
            let items = inbox.itemsForQuietCheck
            guard let line, let at = items.firstIndex(where: { $0.agentRow?.id == leadID }), at + 2 < items.count,
                  case .leadCount(let tally) = items[at + 1], tally.leadId == leadID,
                  case .familyCause = items[at + 2],
                  let countRow = inbox.familyCauseCells["count:\(leadID.uuidString)"],
                  let leadCell = inbox.cellForQA(id: leadID) as? NSView else {
                throw Failure(description: "a card is not lead, count line, cause line in order")
            }
            let leadFrame = leadCell.convert(leadCell.bounds, to: nil)
            let countFrame = countRow.convert(countRow.bounds, to: nil), lineFrame = line.convert(line.bounds, to: nil)
            let spacing = CGFloat(AgentInboxView.rowSpacing)
            try expect(abs(leadFrame.minY - countFrame.maxY - spacing) < 0.5 && abs(countFrame.minY - lineFrame.maxY - spacing) < 0.5,
                       "the count and cause lines are drawn under their lead, in its card — lead \(leadFrame), count \(countFrame), cause \(lineFrame)")
        }
        try expectMinimalChrome("head")
        var spoken: [String] = []
        inbox.accessibilityAnnouncementSink = { _, message in spoken.append(message) }
        finish(paused1)
        delegate.qaRefreshAgentSurfaces()
        inbox.layoutForQA()
        finish(paused1, failed: usageWords)
        delegate.qaRefreshAgentSurfaces()
        inbox.layoutForQA()
        try expect(spoken.contains { $0.hasPrefix("Overnight helper:") && $0.hasSuffix("Paused · usage") },
                   "known usage announcement must say Paused · usage, got \(spoken)")
        inbox.accessibilityAnnouncementSink = nil
        for id in [paused1, paused2] {
            guard let cell = inbox.cellForQA(id: id.rawValue) else {
                throw Failure(description: "usage helper is not a normal rendered row")
            }
            try expect(cell.qaStateLabel == "Paused · usage",
                       "known usage row must say Paused · usage, got '\(cell.qaStateLabel)'")
            try expect(cell.accessibilityLabel()?.contains("Paused · usage") == true,
                       "known usage row's AX must also say Paused · usage")
        }
        try expect(inbox.countLineTextForQA(id: lead.rawValue)?.contains("4 helpers · 2 paused · 1 failed") == true,
                   "Quiet's rendered lead must reconcile paused and failed in one count line")
        Q.photograph(sidebar, "quiet-1-head")

        // 3. Counts add up, read from what is drawn.
        guard let tally = inbox.sidebarTallies[lead.rawValue] else { throw Failure(description: "no tally for the lead") }
        try expect(tally.total == 4 && tally.reconciles, "the lead counts 4 helpers and reconciles — got \(tally.fullLine)")
        let causeWords = leadCause?.titleForQA.drop { !$0.isNumber } ?? ""
        let chipPaused = Int(causeWords.prefix { $0.isNumber }) ?? -1
        try expect(chipPaused == tally.count(.paused), "the cause line's paused count is the lead's tally — \(chipPaused) vs \(tally.count(.paused))")
        let members: Set<UUID> = [paused1, paused2, failedHelper, doneHelper].map(\.rawValue).reduce(into: []) { $0.insert($1) }
        let drawnMembers = drawnAgentIDs().intersection(members).count
        try expect(drawnMembers + tally.folded == tally.total && drawnMembers == tally.shown,
                   "drawn helper rows + folded = total — \(drawnMembers) + \(tally.folded) vs \(tally.total)")
        // One count function: every lead draws the same partition in both
        // layouts, read from the drawn line, and a cause line's number is that
        // lead's tally for its state.
        func drawnCountLines() throws -> [UUID: String] {
            inbox.layoutForQA()
            var lines: [UUID: String] = [:]
            for (id, tally) in inbox.sidebarTallies {
                guard let text = inbox.countLineTextForQA(id: id) else { continue }
                try expect(text.contains(tally.countLine),
                           "\(inbox.sidebarLayout.title): a lead's drawn line carries its tally — '\(text)' vs '\(tally.countLine)'")
                // The Ledger's line 2 leads with its separator; the words are the same.
                lines[id] = text.trimmingCharacters(in: CharacterSet(charactersIn: " ·"))
            }
            return lines
        }
        let quietCounts = try drawnCountLines()
        settings(.ledger)
        let ledgerCounts = try drawnCountLines()
        settings(.quietInbox)
        try expect(!quietCounts.isEmpty && quietCounts == ledgerCounts,
                   "Quiet and Ledger draw the same partition per lead — Quiet \(quietCounts.values.sorted()), Ledger \(ledgerCounts.values.sorted())")
        for line in causeLines() {
            guard let incident = line.causeIncidentForQA, let leadID = incident.familyIDs.first,
                  let leadTally = inbox.sidebarTallies[leadID], case .cause(let cause) = incident.kind else { continue }
            let state: SidebarTallyState = cause == .usageLimit ? .paused : cause == .interruptedByRestart ? .stopped : .failed
            // One icon, then the words; a failure's line carries its reason, no count.
            try expect(line.titleForQA.filter { $0 == "\u{FFFC}" }.count == 1,
                       "a cause line draws exactly one icon — '\(line.titleForQA)'")
            guard state != .failed else { continue }
            let words = line.titleForQA.drop { !$0.isNumber }
            if let number = Int(words.prefix { $0.isNumber }) {
                try expect(number <= leadTally.count(state) && (cause == .interruptedByRestart || number == leadTally.count(state)),
                           "a cause line's count is its lead's tally — '\(line.titleForQA)' vs \(leadTally.fullLine)")
            }
        }
        try expect(usageLine.accessibilityLabel()?.contains("2 agents paused") == true,
                   "the box's AX says the same 2 paused — got \(usageLine.accessibilityLabel() ?? "")")

        // 4. Actions reach the host with that family's agents only.
        var pressed: [SidebarIncident] = []
        inbox.onIncidentAction = { pressed.append($0) }
        inbox.reload(rows: inbox.allRowsForQuietCheck)
        inbox.layoutForQA()
        guard let liveBox = needsYouBox(), liveBox.lines.first?.actionButton.isEnabled == true,
              let liveFamilyAction = causeLines().first(where: { $0.causeIncidentForQA?.familyIDs == [family.rawValue] })?.causeActionForQA,
              let liveLeadAction = causeLines().first(where: { $0.causeIncidentForQA?.familyIDs == [lead.rawValue] })?.causeActionForQA,
              liveLeadAction.isEnabled else {
            throw Failure(description: "with a host, the usage actions are enabled")
        }
        try Q.click(liveBox.lines[0].actionButton)
        try Q.click(liveFamilyAction)
        try expect(pressed.count == 1 && !liveFamilyAction.isEnabled,
                   "only usage acts; Open stays disabled — got \(pressed.count) calls")
        try expect(Set(pressed[0].agentIDs) == [paused1.rawValue, paused2.rawValue] && pressed[0].kind == .cause(.usageLimit),
                   "the box's usage action carries the paused agents")
        // The in-card usage action, pressed through the window, reaches the same entry point.
        try Q.click(liveLeadAction)
        try expect(pressed.count == 2 && pressed[1].kind == .cause(.usageLimit)
                   && Set(pressed[1].agentIDs) == [paused1.rawValue, paused2.rawValue],
                   "the card's Switch & resume… carries that family's paused agents — got \(pressed.count) calls")

        // 5. Clear through the drawn control, refusing the paused; ⌘Z returns them.
        guard let clearButton = sectionCell("Inbox")?.clearButton else { throw Failure(description: "no Clear") }
        try Q.click(clearButton)
        inbox.layoutForQA()
        try expect(supervisor.records[lead] != nil && [family, solo, failedHelper, doneHelper].allSatisfy { supervisor.records[$0] != nil },
                   "Clear deletes nothing (never archive)")
        try expect(Set(inbox.sidebarClearIDs).isDisjoint(with: expectedClear),
                   "the cleared rows are no longer offered to Clear")
        let afterClear = drawnAgentIDs()
        try expect(!afterClear.contains(family.rawValue) && !afterClear.contains(solo.rawValue)
                   && afterClear.contains(paused1.rawValue) && afterClear.contains(paused2.rawValue),
                   "cleared rows leave the live list; paused rows stay")
        try expect(inbox.undoToastTextForQA.hasPrefix("Cleared 4"), "one Undo for the batch — got '\(inbox.undoToastTextForQA)'")
        try expect(sectionCell(AgentInboxView.quietHistoryNote) != nil, "the History footnote sits under the shelf")
        Q.photograph(sidebar, "quiet-2-cleared")
        // The toast's drawn Undo, pressed through the window's real event path.
        let undo = inbox.undoButtonForQA
        let undoPoint = undo.convert(NSPoint(x: undo.bounds.midX, y: undo.bounds.midY), to: nil)
        guard let undoHit = window.contentView?.hitTest(undoPoint), undoHit === undo || undoHit.isDescendant(of: undo) else {
            throw Failure(description: "the window does not hit the drawn Undo button")
        }
        try Q.click(undo)
        inbox.layoutForQA()
        try expect(Set(inbox.sidebarClearIDs) == expectedClear, "the Undo button brings every cleared row back to Clear's reach")
        try expect(drawnAgentIDs().isSuperset(of: [family.rawValue, solo.rawValue]), "the rows return to the list")
        // ⌘Z undoes the same batch.
        guard let clearAgain = sectionCell("Inbox")?.clearButton else { throw Failure(description: "no Clear after Undo") }
        try Q.click(clearAgain)
        inbox.layoutForQA()
        try expect(!drawnAgentIDs().contains(family.rawValue), "a second Clear leaves the live list")
        try Q.pressUndo(inbox)
        try expect(Set(inbox.sidebarClearIDs) == expectedClear, "⌘Z brings every cleared row back to Clear's reach")
        try expect(drawnAgentIDs().isSuperset(of: [family.rawValue, solo.rawValue]), "the rows return to the list")

        // 6. Nothing blocks: no box, not an empty one. New activity on the
        // paused helpers finishes them.
        finish(paused1)
        finish(paused2)
        delegate.qaRefreshAgentSurfaces()
        inbox.layoutForQA()
        try expect(boxItems() == 0 && needsYouBox() == nil, "with nothing blocking there is no Needs you box at all")
        try expect(!Q.views(in: inbox, where: { ($0.accessibilityLabel() ?? "").hasPrefix("Needs you") }).contains { !$0.isHiddenOrHasHiddenAncestor },
                   "and no 'Needs you' row of any kind")

        // And back to Ledger, live.
        settings(.ledger)
        try expect(chipCells().isEmpty && sectionCell(AgentInboxView.quietHistoryNote) == nil,
                   "switching to Ledger takes the Quiet head away live")

        return "Quiet inbox: the Layout setting re-renders live both ways; the head is Inbox · Clear \(clearIDs.count), "
            + "a Needs you box with one usage line, and one cause line inside each family's card (2 paused · usage / its reason); "
            + "head and family actions are plain words, Clear's glyph is the checkmark, no hand or emoji, a card says failed once; "
            + "the cause line's count is the lead's tally and drawn helpers + folded = \(tally.total); actions carry their family; "
            + "Clear takes 4 off the list and refuses the paused, ⌘Z restores; with nothing blocking there is no box"
    }
}
