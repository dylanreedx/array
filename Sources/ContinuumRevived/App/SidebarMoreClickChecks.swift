import AppKit
import ContinuumRevivedAgentUI

/// `--sidebar-more-click-check`: a lead whose helpers are all folded draws
/// "N more", and pressing it, through `NSApp.sendEvent` as a user's click
/// arrives, opens the helpers. Pressed on its words, and on the empty part of
/// the same row to their right, because a reviewer reached for either.
@MainActor
enum SidebarMoreClickChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }

    static func run() throws -> String {
        QuickHideChecks.acceptFirstMouseEverywhere()
        var report: [String] = []
        for dark in [false, true] {
            for spot in ["words", "right of the words"] {
                report.append(try check(dark: dark, spot: spot))
            }
        }
        return "SidebarMoreClickChecks passed:\n" + report.joined(separator: "\n")
    }

    static func check(dark: Bool, spot: String) throws -> String {
        let label = "\(dark ? "dark" : "light") more click (\(spot))"
        func fail(_ message: String) -> Failure { Failure(description: "\(label): \(message)") }
        let uuid = SidebarOwnershipChecks.uuid
        let now = SidebarOwnershipChecks.now
        let lead = uuid(0xE00)
        func row(_ id: UUID, parent: UUID?) -> AgentInboxRow {
            AgentInboxRow(
                id: id, title: parent == nil ? "Run three sequential helper agents" : "h\(id.uuidString.suffix(2))",
                state: .ready, createdAt: now.addingTimeInterval(-3_600), parentId: parent)
        }
        let rows = [row(lead, parent: nil)] + (1...12).map { row(uuid(0xE00 + $0), parent: lead) }
        let (inbox, window) = SidebarOwnershipChecks.build(
            dark: dark, height: 720, rows: rows, folds: [lead: true]) { _, _ in }
        defer { window.orderOut(nil) }
        inbox.prefersReducedMotion = { true }
        (window as? SidebarOwnershipChecks.KeyWindow)?.reportsKey = true
        func line() throws -> AgentInboxRemainderView {
            guard inbox.scrollToFanoutRemainderForQA(parentId: lead),
                  let line = inbox.ownershipRemaindersForQA.first(where: { $0.qaParentID == lead }) else {
                throw fail("the lead's \"N more\" line is not on screen")
            }
            line.layoutSubtreeIfNeeded()
            return line
        }
        let helperIDs = Set(rows.dropFirst().map(\.id))
        func shown() -> Int { inbox.rowIdsForQA.filter(helperIDs.contains).count }
        let closed = try line()
        guard closed.qaTitle.hasSuffix("more") else { throw fail("the line reads \"\(closed.qaTitle)\", not \"N more\"") }
        let before = shown()
        let words = closed.qaLabelFrameInWindow
        let point = spot == "words"
            ? NSPoint(x: words.midX, y: words.midY)
            : NSPoint(x: min(words.maxX + 60, closed.convert(closed.bounds, to: nil).maxX - 30), y: words.midY)
        guard let hit = window.contentView?.hitTest(point), hit === closed || hit.isDescendant(of: closed) else {
            throw fail("the point \(point) does not reach the \"\(closed.qaTitle)\" line")
        }
        NSApp.postEvent(try SidebarOwnershipChecks.mouse(.leftMouseUp, at: point, window: window), atStart: false)
        NSApp.sendEvent(try SidebarOwnershipChecks.mouse(.leftMouseDown, at: point, window: window))
        while let up = NSApp.nextEvent(matching: [.leftMouseUp], until: Date(), inMode: .default, dequeue: true) {
            NSApp.sendEvent(up)
        }
        inbox.layoutViewportForQA()
        guard inbox.expandedFanoutParentsForQA.contains(lead), shown() > before else {
            throw fail("pressing \"\(closed.qaTitle)\" left \(shown()) helpers drawn (was \(before))")
        }
        return "\(label): \"\(closed.qaTitle)\" opened \(before) → \(shown()) helper rows"
    }
}
