import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Foundation

// `--sidebar-stuck-rows-check`. Dylan, 0.7.56: two failed Codex helpers
// ("review files", "review terminal") stayed under a lead's "299 folded" line,
// and Clear and Archive did not remove them. They were not those agents' rows.
// A fold lends a newly visible helper the cached card of a helper that just
// left the list; when the newcomer's own card had been evicted from the
// 128-entry cell cache while its model stayed cached, the borrowed card kept
// the other agent's content, and every later push skipped it as unchanged.
// This replays that sequence with anonymised copies of the real rows, through
// pushes and real clicks, and asserts each drawn card shows its own agent.
enum SidebarStuckRowsChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String) throws {
        if !condition() { throw Failure(description: message()) }
    }

    static let epoch = Date(timeIntervalSinceReferenceDate: 816_832_000)
    static let lead = UUID(uuidString: "5E000000-0000-0000-0000-000000000001")!
    static let leadHelper = UUID(uuidString: "5E000000-0000-0000-0000-000000000002")!
    static let otherLead = UUID(uuidString: "5E000000-0000-0000-0000-000000000003")!
    /// Stands in for "review files": the card that is lent.
    static let donor = UUID(uuidString: "5E000000-0000-0000-0000-000000000004")!
    static let fillerCount = 64

    static func root(_ id: UUID, _ title: String, age: Double) -> AgentInboxRow {
        AgentInboxRow(id: id, title: title, state: .ready,
                      lastActiveAt: epoch.addingTimeInterval(-age), createdAt: epoch.addingTimeInterval(-age),
                      harness: "Codex")
    }

    static func helper(_ id: UUID, of parent: UUID, _ title: String, state: InboxState, age: Double) -> AgentInboxRow {
        AgentInboxRow(id: id, title: title, state: state,
                      lastActiveAt: epoch.addingTimeInterval(-age), depth: 1,
                      createdAt: epoch.addingTimeInterval(-age), parentId: parent,
                      harness: "Codex", terminalIsUnread: state == .failed)
    }

    static func fillers(snoozed: Bool) -> [AgentInboxRow] {
        (0..<fillerCount).map { index in
            let id = UUID(uuidString: String(format: "5E000000-0000-0000-0001-%012d", index))!
            return AgentInboxRow(
                id: id, title: "Filler \(index)", state: .ready,
                lifecycle: snoozed ? .snoozed(until: epoch.addingTimeInterval(86_400)) : .active,
                lastActiveAt: epoch.addingTimeInterval(-Double(1_000 + index)),
                createdAt: epoch.addingTimeInterval(-Double(1_000 + index)))
        }
    }

    @MainActor
    static func run() throws -> String {
        QuickHideChecks.acceptFirstMouseEverywhere()
        let suiteName = "sidebar-stuck-rows-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }
        let height: CGFloat = 9_000
        let inbox = AgentInboxView(frame: NSRect(x: 0, y: 0, width: 420, height: height), indicatorDefaults: suite)
        inbox.clock = { epoch }
        inbox.prefersReducedMotion = { true }
        inbox.hoverCardEnabled = false
        let window = SidebarOwnershipChecks.KeyWindow(
            contentRect: inbox.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.reportsKey = true
        window.contentView = inbox
        window.orderFrontOffscreenForChecks()
        defer { window.orderOut(nil) }
        inbox.setScope(.all)

        let leadRows = [
            root(lead, "Stabilize native refresh", age: 30),
            helper(leadHelper, of: lead, "transcript review", state: .ready, age: 60),
        ]
        let otherRows = [
            root(otherLead, "fixed check review", age: 40),
            helper(donor, of: otherLead, "review files", state: .failed, age: 90),
        ]
        func push(_ rows: [AgentInboxRow]) {
            inbox.apply(rows: rows, changed: .empty)
            inbox.flushOffMainApplyForQA()
            inbox.layoutForQA()
        }
        /// A press on the card's own fold control, through the application.
        func clickFold(_ id: UUID, _ label: String) throws {
            guard let card = inbox.onScreenCardForQA(id: id), let frame = card.qaDisclosureFrameForQA else {
                throw Failure(description: "\(label): no fold control on the card")
            }
            try QuickHideChecks.click(card, at: NSPoint(x: frame.midX, y: frame.midY))
            inbox.layoutForQA()
        }
        /// Every card the table draws shows the agent in its row.
        func assertCardsShowTheirRows(_ label: String) throws {
            for id in inbox.rowIdsForQA {
                guard let card = inbox.onScreenCardForQA(id: id) else { continue }
                try expect(card.qaAgentID == id,
                           "\(label): the card in agent …\(id.uuidString.suffix(4))'s row shows agent "
                           + "…\(card.qaAgentID?.uuidString.suffix(4) ?? "none") titled '\(card.qaTitle)'")
            }
        }

        // 1. The lead and its helper are drawn; the helper's card is cached.
        push(leadRows)
        try expect(inbox.onScreenCardForQA(id: leadHelper) != nil, "setup: the lead's helper was not drawn")
        // 2. Fold the lead. The helper's model stays cached; its card is idle.
        try clickFold(lead, "fold the lead")
        try expect(inbox.onScreenCardForQA(id: leadHelper) == nil, "fold: the helper is still drawn")
        // 3. A long list turns over: 64 agents drawn as cards, then snoozed and
        // drawn slim in the open shelf. 128 new cells evict the helper's cached
        // card; the model cache holds 66 agents and keeps the helper's model.
        push(leadRows + fillers(snoozed: false))
        push(leadRows + fillers(snoozed: true))
        if !inbox.isShelfExpandedForQA { inbox.toggleShelf() }
        inbox.layoutForQA()
        // 4. Another lead's failed helper is drawn, then folded away: its card
        // is now the only spare helper card in the cache.
        push(leadRows + otherRows + fillers(snoozed: true))
        try expect(inbox.onScreenCardForQA(id: donor) != nil, "setup: 'review files' was not drawn")
        try clickFold(otherLead, "fold the other lead")
        try expect(inbox.onScreenCardForQA(id: donor) == nil, "fold: 'review files' is still drawn")
        // 5. Unfold the lead. Its helper is newly visible and borrows the spare.
        try clickFold(lead, "unfold the lead")
        try expect(inbox.onScreenCardForQA(id: leadHelper) != nil, "unfold: the helper was not drawn")
        try assertCardsShowTheirRows("unfold")
        // 6. And a later push repaints nothing stale.
        push(leadRows + otherRows + fillers(snoozed: true))
        try assertCardsShowTheirRows("next push")
        return "sidebar-stuck-rows: after a long list evicted a folded helper's card, unfolding its lead "
            + "lent it another helper's card, and the card showed its own agent, on the fold and the next push"
    }

    // MARK: - The pin on a standing lead

    /// `--sidebar-pinned-lead-check [stills dir]`. Pinned (standing) leads sit
    /// above every other row with no heading, so the row itself must say so: a
    /// pin beside the clock on the pinned lead's header line, none on the other.
    @MainActor
    static func runPinnedLead(stills: URL?) throws -> String {
        let pinned = UUID(uuidString: "5E000000-0000-0000-0002-000000000001")!
        let plain = UUID(uuidString: "5E000000-0000-0000-0002-000000000002")!
        var lines: [String] = []
        for dark in [false, true] {
            let suiteName = "sidebar-pinned-lead-\(UUID().uuidString)"
            let suite = UserDefaults(suiteName: suiteName)!
            defer { suite.removePersistentDomain(forName: suiteName) }
            SidebarStandingLeads.save([pinned], to: suite)
            let inbox = AgentInboxView(frame: NSRect(x: 0, y: 0, width: 420, height: 420), indicatorDefaults: suite)
            inbox.clock = { epoch }
            inbox.prefersReducedMotion = { true }
            inbox.hoverCardEnabled = false
            let window = SidebarOwnershipChecks.KeyWindow(
                contentRect: inbox.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = inbox
            window.orderFrontOffscreenForChecks()
            defer { window.orderOut(nil) }
            inbox.setScope(.all)
            func finished(_ id: UUID, _ title: String, hours: Double) -> AgentInboxRow {
                let ended = epoch.addingTimeInterval(-hours * 3_600)
                return AgentInboxRow(id: id, title: title, state: .ready, lastActiveAt: ended, createdAt: ended,
                                     harness: "Claude Code",
                                     terminalEvent: AgentTerminalEvent(sequence: 1, turnID: nil, outcome: .succeeded, endedAt: ended))
            }
            inbox.apply(rows: [
                finished(pinned, "HR Agent + Workflows", hours: 3),
                finished(plain, "Plan visual mapper tool redesign", hours: 4),
            ], changed: .empty)
            inbox.layoutForQA()
            let name = dark ? "dark" : "light"
            guard let pinnedCard = inbox.onScreenCardForQA(id: pinned),
                  let plainCard = inbox.onScreenCardForQA(id: plain) else {
                throw Failure(description: "\(name): a lead was not drawn")
            }
            guard let pin = pinnedCard.pinFrameForQA else {
                throw Failure(description: "\(name): the pinned lead draws no pin")
            }
            try expect(plainCard.pinFrameForQA == nil, "\(name): an unpinned lead draws a pin")
            let clock = pinnedCard.qaStatusFrame
            try expect(pinnedCard.clockTextForQA?.isEmpty == false,
                       "\(name): the pinned lead draws no clock (\(String(describing: pinnedCard.clockTextForQA)))")
            try expect(pin.maxX <= clock.minX && clock.minX - pin.maxX < 8 && abs(pin.midY - clock.midY) < 3,
                       "\(name): the pin \(pin) is not beside the clock '\(pinnedCard.clockTextForQA ?? "")' \(clock)")
            if let stills {
                try FileManager.default.createDirectory(at: stills, withIntermediateDirectories: true)
                let height = min(inbox.bounds.height, 260)
                let rect = NSRect(x: 0, y: inbox.isFlipped ? 0 : inbox.bounds.maxY - height,
                                  width: inbox.bounds.width, height: height)
                guard let image = InboxFoldMotion.image(of: inbox, in: rect), let tiff = image.tiffRepresentation,
                      let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
                    throw Failure(description: "\(name): could not render the still")
                }
                try png.write(to: stills.appendingPathComponent("pinned-lead-\(name).png"))
            }
            lines.append("\(name): pin \(Int(pin.width))pt beside the clock")
        }
        return "sidebar-pinned-lead: only the pinned lead draws a pin beside its clock — " + lines.joined(separator: "; ")
    }
}
