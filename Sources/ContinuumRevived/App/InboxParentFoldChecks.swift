import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Foundation

/// `--inbox-parent-fold-check` — launch polish, item Q.
///
/// Dylan: "maybe sub agents shouldn't be expanded by default... maybe a
/// card-like effect for parent agents holding subagents (subtle drawer/folder
/// UI concept when it's collapsed)."
///
/// Read off the SHIPPED list (`AgentInboxView` with its production 96 cell):
/// a parent nobody has touched draws folded with one card tucked behind it per
/// hidden child (two at most), the tucked cards are decoration that leaves the
/// row's height, card and hit-testing alone, an opened group draws none, each
/// parent's choice round-trips through the host's store and the app's own
/// sidebar wiring, and a child that needs you opens a group you never touched —
/// but never one you folded.
@MainActor
enum InboxParentFoldChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String) throws {
        if !condition() { throw Failure(description: message()) }
    }

    static let epoch = Date(timeIntervalSinceReferenceDate: 810_000_000)
    static func id(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "5C000000-0000-4000-8000-%012X", value))!
    }
    static let oneChildParent = id(1), threeChildParent = id(2), askingParent = id(3), loneRoot = id(4)
    static let onlyChild = id(11)
    static let threeChildren = [id(21), id(22), id(23)]
    static let askingChildren = [id(31), id(32)]

    static func rows(askingChildState: InboxState = .approval) -> [AgentInboxRow] {
        func root(_ id: UUID, _ title: String, _ age: Double) -> AgentInboxRow {
            AgentInboxRow(id: id, title: title, state: .ready,
                          lastActiveAt: epoch.addingTimeInterval(-age), createdAt: epoch.addingTimeInterval(-age))
        }
        func child(_ id: UUID, of parent: UUID, _ title: String, state: InboxState = .ready, _ age: Double) -> AgentInboxRow {
            AgentInboxRow(id: id, title: title, state: state,
                          lastActiveAt: epoch.addingTimeInterval(-age), depth: 1,
                          createdAt: epoch.addingTimeInterval(-age), parentId: parent)
        }
        return [
            root(oneChildParent, "One-child parent", 100),
            child(onlyChild, of: oneChildParent, "Only child", 90),
            root(threeChildParent, "Three-child parent", 200),
        ] + threeChildren.enumerated().map { child($1, of: threeChildParent, "Child \($0)", Double(190 - $0)) } + [
            root(askingParent, "Asking parent", 300),
            child(askingChildren[0], of: askingParent, "Asking child", state: askingChildState, 290),
            child(askingChildren[1], of: askingParent, "Quiet child", 289),
            root(loneRoot, "Lone root", 400),
        ]
    }

    static func makeInbox(_ rows: [AgentInboxRow], appearance: NSAppearance.Name, windows: inout [NSWindow]) -> AgentInboxView {
        let view = AgentInboxView(frame: NSRect(x: 0, y: 0, width: 320, height: 1_100))
        view.clock = { epoch }
        // What the app's sidebar sets (`configureWorkspaceSidebar`); the
        // production-wiring section below asserts it does.
        view.foldsUntouchedGroups = true
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 1_100),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = view
        window.orderFrontOffscreenForChecks()
        windows.append(window)
        view.reload(rows: rows)
        view.layoutForQA()
        return view
    }

    static func run() async throws {
        var windows: [NSWindow] = []
        defer { windows.forEach { $0.orderOut(nil) } }
        var lines: [String] = []
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            lines.append(try checkDefaultsAndDecoration(appearance: appearance, windows: &windows))
        }
        lines.append(try checkPersistence(windows: &windows))
        lines.append(try checkAutoExpandRule(windows: &windows))
        lines.append(try checkProductionWiring())
        for line in lines { print("  \(line)") }
        print("InboxParentFoldChecks passed: untouched parents draw folded with 1 tucked card for one child and 2 for more, none when open, the row's height, card and hit area are those of a childless root, each parent's choice survives a reload through the app's own sidebar wiring, and a child that needs you opens only a group you never folded")
    }

    // MARK: - Default fold and the tucked cards

    static func checkDefaultsAndDecoration(appearance: NSAppearance.Name, windows: inout [NSWindow]) throws -> String {
        let label = "\(appearance.rawValue)"
        let inbox = makeInbox(rows(), appearance: appearance, windows: &windows)
        let shown = inbox.rowIdsForQA
        for hidden in [onlyChild] + threeChildren {
            try expect(!shown.contains(hidden), "\(label): with no fold choice stored, a parent's children must start folded — \(hidden) is drawn")
        }
        try expect(inbox.collapsedParentsForQA.isSuperset(of: [oneChildParent, threeChildParent]),
                   "\(label): the untouched parents are not folded — \(inbox.collapsedParentsForQA)")
        try expect(inbox.disclosureTitleForQA(id: oneChildParent)?.hasPrefix("▸") == true,
                   "\(label): a folded parent's triangle must point right — \(String(describing: inbox.disclosureTitleForQA(id: oneChildParent)))")

        guard let one = inbox.tuckedCardsForQA(id: oneChildParent),
              let three = inbox.tuckedCardsForQA(id: threeChildParent),
              let lone = inbox.tuckedCardsForQA(id: loneRoot) else {
            throw Failure(description: "\(label): a parent or the lone root has no materialized cell")
        }
        try expect(one.count == 1 && one.rects.count == 1,
                   "\(label): one hidden child tucks ONE card behind its parent — got \(one.count)")
        try expect(three.count == 2 && three.rects.count == 2,
                   "\(label): three hidden children tuck TWO cards (the cap) — got \(three.count)")
        try expect(lone.count == 0, "\(label): a root with no children tucks nothing — got \(lone.count)")
        for (name, tucked) in [("one-child", one), ("three-child", three)] {
            for rect in tucked.rects {
                try expect(rect.maxY > tucked.card.maxY + 0.5,
                           "\(label) \(name): a tucked card must peek out BELOW the parent's card — edge \(rect) vs card \(tucked.card)")
                try expect(rect.minX > tucked.card.minX && rect.maxX < tucked.card.maxX,
                           "\(label) \(name): a tucked card sits inset behind the card, not wider — edge \(rect) vs card \(tucked.card)")
                // Decoration only: a point on the peeking edge belongs to the row.
                let peek = NSPoint(x: rect.midX, y: rect.maxY - 1)
                let hit = tucked.cell.hitTest(tucked.cell.convert(peek, to: tucked.cell.superview))
                try expect(!(hit is InboxGroupBackgroundView),
                           "\(label) \(name): the tucked card took a click — \(String(describing: hit))")
            }
            // The fold draws in the row's own end gap: the parent's row and card
            // are exactly a childless root's.
            try expect(tucked.rowFrame.height == lone.rowFrame.height,
                       "\(label) \(name): the folded parent's row is \(tucked.rowFrame.height)pt, a childless root's \(lone.rowFrame.height)pt")
            try expect(tucked.card.size == lone.card.size && tucked.card.minY == lone.card.minY,
                       "\(label) \(name): the folded parent's card is \(tucked.card), a childless root's \(lone.card)")
            try expect(tucked.rects.allSatisfy { $0.maxY <= tucked.rowFrame.height + CGFloat(AgentInboxView.rowSpacing) / 2 + 0.5 },
                       "\(label) \(name): a tucked card reaches past the row's half of the intercell gap")
        }

        // Opened, the group draws its children and no tucked cards.
        try expect(inbox.clickDisclosureForQA(id: threeChildParent), "\(label): the triangle could not be clicked")
        inbox.layoutForQA()
        try expect(threeChildren.allSatisfy(inbox.rowIdsForQA.contains),
                   "\(label): opening the parent did not draw its children")
        try expect(inbox.tuckedCardsForQA(id: threeChildParent)?.count == 0,
                   "\(label): an opened group still draws tucked cards")
        try expect(inbox.disclosureTitleForQA(id: threeChildParent)?.hasPrefix("▾") == true,
                   "\(label): an opened parent's triangle must point down")
        return "\(label): one-child parent tucks \(one.count) at \(one.rects.map(\.maxY)) under card maxY \(one.card.maxY), three-child tucks \(three.count), rows \(one.rowFrame.height)pt = lone \(lone.rowFrame.height)pt"
    }

    // MARK: - Persistence across a reload

    static func checkPersistence(windows: inout [NSWindow]) throws -> String {
        guard let suite = QAIsolatedDefaults(isolatedSuiteName: "array.qa.inbox-parent-fold.\(UUID().uuidString)") else {
            throw Failure(description: "setup: no isolated defaults suite")
        }
        defer { suite.removePersistentDomain(forName: suite.suiteDomainName) }
        let first = makeInbox(rows(), appearance: .darkAqua, windows: &windows)
        var reported: [UUID: Bool]?
        first.onParentFoldChange = { reported = $0 }
        try expect(first.clickDisclosureForQA(id: threeChildParent), "the triangle could not be clicked")
        try expect(reported == [threeChildParent: true],
                   "opening a parent must report that one choice to the host — got \(String(describing: reported))")
        WorkspaceSidebarConfig.setParentFolds(reported ?? [:], defaults: suite)

        let second = makeInbox([], appearance: .darkAqua, windows: &windows)
        second.restoreParentFolds(WorkspaceSidebarConfig.parentFolds(defaults: suite))
        second.reload(rows: rows())
        second.layoutForQA()
        try expect(threeChildren.allSatisfy(second.rowIdsForQA.contains),
                   "the opened parent did not come back open after a reload — \(second.rowIdsForQA)")
        try expect(!second.rowIdsForQA.contains(onlyChild),
                   "a parent nobody touched must still start folded after a reload")
        return "persistence: opened parent restored open, untouched parent folded, stored \(WorkspaceSidebarConfig.parentFolds(defaults: suite))"
    }

    // MARK: - The auto-expand rule

    static func checkAutoExpandRule(windows: inout [NSWindow]) throws -> String {
        // A child that needs you opens a group you never touched…
        let quiet = makeInbox(rows(askingChildState: .ready), appearance: .darkAqua, windows: &windows)
        try expect(!quiet.rowIdsForQA.contains(askingChildren[0]),
                   "control: with every child resting, the asking parent starts folded")
        quiet.reload(rows: rows(askingChildState: .approval))
        quiet.layoutForQA()
        try expect(quiet.rowIdsForQA.contains(askingChildren[0]),
                   "a child waiting on approval must open the group you never touched")
        quiet.reload(rows: rows(askingChildState: .failed))
        quiet.layoutForQA()
        try expect(quiet.rowIdsForQA.contains(askingChildren[0]), "…and so must a failed child")
        // …and never one you folded.
        try expect(quiet.clickDisclosureForQA(id: askingParent), "the asking parent's triangle could not be clicked")
        quiet.layoutForQA()
        try expect(!quiet.rowIdsForQA.contains(askingChildren[0]), "folding the asking parent did not fold it")
        quiet.reload(rows: rows(askingChildState: .input))
        quiet.layoutForQA()
        try expect(!quiet.rowIdsForQA.contains(askingChildren[0]),
                   "a group you folded must stay folded when a child reports in")
        try expect(quiet.tuckedCardsForQA(id: askingParent)?.count == 2,
                   "the folded asking parent shows its two children as tucked cards")
        return "auto-expand: approval and failed children open an untouched group; a folded one stays folded"
    }

    // MARK: - The app's own wiring

    static func checkProductionWiring() throws -> String {
        guard let suite = QAIsolatedDefaults(isolatedSuiteName: "array.qa.inbox-parent-fold-app.\(UUID().uuidString)") else {
            throw Failure(description: "setup: no isolated defaults suite")
        }
        defer { suite.removePersistentDomain(forName: suite.suiteDomainName) }
        WorkspaceSidebarConfig.setParentFolds([oneChildParent: true], defaults: suite)
        let app = AppDelegate()
        app.qaSettingsDefaults = suite
        let sidebar = WorkspaceSidebarView(frame: NSRect(x: 0, y: 0, width: 300, height: 1_000))
        app.qaInstallWorkspaceSidebar(sidebar)
        let inbox = sidebar.inboxForQA
        try expect(inbox.foldsUntouchedGroups, "the app's sidebar must start untouched groups folded")
        try expect(inbox.parentFoldChoicesForQA == [oneChildParent: true],
                   "the app's sidebar did not restore the stored fold choices — \(inbox.parentFoldChoicesForQA)")
        inbox.reload(rows: rows())
        inbox.layoutForQA()
        try expect(!inbox.rowIdsForQA.contains(threeChildren[0]) && inbox.rowIdsForQA.contains(onlyChild),
                   "the app's sidebar must fold the untouched parent and open the stored one — \(inbox.rowIdsForQA)")
        try expect(inbox.clickDisclosureForQA(id: threeChildParent), "the triangle could not be clicked")
        try expect(WorkspaceSidebarConfig.parentFolds(defaults: suite) == [oneChildParent: true, threeChildParent: true],
                   "the app's sidebar did not persist the fold — \(WorkspaceSidebarConfig.parentFolds(defaults: suite))")
        return "production: configureWorkspaceSidebar restored and persisted folds in its settings defaults"
    }
}
