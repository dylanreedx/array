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

    static func makeInbox(_ rows: [AgentInboxRow], appearance: NSAppearance.Name, height: CGFloat = 1_100,
                          windows: inout [NSWindow]) -> AgentInboxView {
        let view = AgentInboxView(frame: NSRect(x: 0, y: 0, width: 320, height: height))
        view.clock = { epoch }
        // What the app's sidebar sets (`configureWorkspaceSidebar`); the
        // production-wiring section below asserts it does.
        view.foldsUntouchedGroups = true
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: height),
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
        lines.append(try checkFoldMotion(windows: &windows))
        lines.append(try checkFoldLatency(windows: &windows))
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            lines.append(try checkDefaultsAndDecoration(appearance: appearance, windows: &windows))
        }
        lines.append(try checkTuckedCards(windows: &windows))
        lines.append(try checkHoverInPlace(windows: &windows))
        lines.append(try checkDeckBreathe(windows: &windows))
        lines.append(try checkPersistence(windows: &windows))
        lines.append(try checkAutoExpandRule(windows: &windows))
        lines.append(try checkProductionWiring())
        for line in lines { print("  \(line)") }
        print("InboxParentFoldChecks passed: untouched parents draw folded with 1 tucked card for one child and 2 for more, none when open, the row's height, card and hit area are those of a childless root, each parent's choice survives a reload through the app's own sidebar wiring, and a child that needs you opens only a group you never folded")
    }

    // MARK: - Default fold and the tucked cards

    static func checkFoldMotion(windows: inout [NSWindow]) throws -> String {
        let inbox = makeInbox(rows(), appearance: .darkAqua, windows: &windows)
        inbox.prefersReducedMotion = { false }
        func capture(_ name: String) throws {
            guard let path = ProcessInfo.processInfo.environment["CONTINUUM_QA_CAPTURE"] else { return }
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let height = min(inbox.bounds.height, 760)
            let rect = NSRect(x: 0, y: inbox.isFlipped ? 0 : inbox.bounds.maxY - height,
                              width: inbox.bounds.width, height: height)
            guard let image = InboxFoldMotion.image(of: inbox, in: rect),
                  let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else {
                throw Failure(description: "motion: could not render \(name)")
            }
            try png.write(to: directory.appendingPathComponent("sidebar-fold-\(name).png"))
        }
        try capture("closed")
        try expect(inbox.clickDisclosureForQA(id: threeChildParent), "motion: parent disclosure was unavailable")
        let motion = inbox.foldMotionForQA
        try expect(motion.isAnimating, "motion: opening a parent must unfold its children instead of only fading their final positions")
        try expect(motion.duration == 0.18, "motion: expanding must take exactly 180 ms")
        let parentKey = "agent:\(threeChildParent.uuidString)"
        let childKey = "agent:\(threeChildren[0].uuidString)"
        let followingKey = "agent:\(askingParent.uuidString)"
        guard let child = motion.poses[childKey], let path = motion.endpointsForQA[childKey] else {
            throw Failure(description: "motion: the visible child must participate")
        }
        // The parent stays LIVE: never photographed, never covered, so its fold
        // control's morph is what the screen shows.
        try expect(motion.poses[parentKey] == nil
                   && !motion.coveredViewsForQA.contains { ($0 as? AgentInbox96CellView)?.qaAgentID == threeChildParent },
                   "motion: the clicked parent must stay live, not a photograph")
        // The frame committed with the click is already one frame of travel in:
        // a first frame at fraction 0 repeats the old layout and reads as lag.
        let firstFrame = motion.elapsed
        let travelled = (child.frame.minY - path.from.minY) / (path.to.minY - path.from.minY)
        try expect(firstFrame > 0 && firstFrame <= 1.0 / 60 + 1e-9,
                   "motion: the first presented frame must be exactly one frame in, not \(firstFrame)s")
        try expect(travelled >= 0.10,
                   "motion: one 1/60 s frame must carry the child at least 10% of its path — it moved \(Int(travelled * 100))%")
        let following = motion.poses[followingKey]?.frame
        let coveredViews = motion.coveredViewsForQA
        try expect(!coveredViews.isEmpty && motion.overlayPassesHitTestingForQA,
                   "motion: presentation must cover the live rows without taking their clicks")
        let builds = inbox.cellBuildCountForQA
        motion.advance(by: 0.04)
        try capture("unfold-40ms")
        guard let movingChild = motion.poses[childKey] else {
            throw Failure(description: "motion: the child disappeared before the transition finished")
        }
        try expect(movingChild.frame.minY > child.frame.minY && movingChild.opacity > child.opacity,
                   "motion: the child must travel out of its stack while its text appears")
        try expect((motion.poses[followingKey]?.frame.minY ?? 0) > (following?.minY ?? .greatestFiniteMagnitude),
                   "motion: following chats must move down with the unfolding cards")
        try expect(inbox.cellBuildCountForQA == builds, "motion: a frame tick must not rebuild the native table cells")
        var streamed = rows()
        let changedIndex = streamed.firstIndex { $0.id == threeChildren[0] }!
        let previousChild = streamed[changedIndex]
        streamed[changedIndex] = AgentInboxRow(
            id: previousChild.id, title: "Updated while unfolding", state: previousChild.state,
            lastActiveAt: previousChild.lastActiveAt, depth: previousChild.depth,
            createdAt: previousChild.createdAt, parentId: previousChild.parentId)
        inbox.apply(rows: streamed, changed: AgentsBoardChangeSet(added: [], updated: [threeChildren[0]], removed: []))
        try expect(motion.isAnimating && motion.poses[childKey]?.frame == movingChild.frame
                    && abs(motion.elapsed - (firstFrame + 0.04)) < 1e-9,
                   "motion: streamed content must neither interrupt nor restart an unfold")
        try expect(inbox.titlesForQA.contains("Updated while unfolding"),
                   "motion: streamed content must still update the native list immediately")
        try expect(inbox.clickDisclosureForQA(id: threeChildParent), "motion: the moving group could not be reversed")
        try expect(motion.duration == 0.15, "motion: collapsing must take exactly 150 ms")
        try expect(motion.endpointsForQA[childKey]?.from == movingChild.frame,
                   "motion: a reversal must begin at the current position, without a jump")
        try expect(!inbox.rowIdsForQA.contains(threeChildren[0]), "motion: folded children must leave the semantic list immediately")
        // The tail under 0.5% of travel is invisible, and the real rows stay
        // hidden for as long as it runs: the overlay retires where it starts.
        let settle = motion.settleTime
        try expect(settle < motion.duration && abs(1 - InboxFoldMotion.progress(at: InboxFoldMotion.settleFraction)) < 0.005,
                   "motion: the overlay must retire once under 0.5% of travel remains (\(settle)s of \(motion.duration)s)")
        motion.advance(by: settle - motion.elapsed - 0.001)
        try expect(motion.isAnimating, "motion: the overlay retired before the spring settled")
        motion.advance(by: 0.002)
        try expect(!motion.isAnimating && motion.poses.isEmpty, "motion: the overlay must retire at the settle point")
        try expect(coveredViews.allSatisfy { ($0.layer?.opacity ?? 0) > 0 },
                   "motion: completion must restore the native rows' visibility")
        let peak = (0...200).map { InboxFoldMotion.progress(at: CGFloat($0) / 200) }.max() ?? 0
        try expect(peak > 1.001 && peak < 1.008, "motion: the softened spring should have barely perceptible overshoot (\(peak))")
        let earlyProgress = InboxFoldMotion.progress(at: 0.25)
        try expect(earlyProgress > 0.60 && earlyProgress < 0.75,
                   "motion: the unfold must spread its travel out instead of snapping almost to the end (\(earlyProgress))")
        try expect(InboxFoldMotion.progress(at: 0) == 0 && InboxFoldMotion.progress(at: 1) == 1,
                   "motion: the spring must start and land exactly")
        inbox.prefersReducedMotion = { true }
        _ = inbox.clickDisclosureForQA(id: threeChildParent)
        try expect(!motion.isAnimating && inbox.qaLastRowMotion.entering.isEmpty,
                   "motion: Reduce Motion must bypass both unfolding and the generic row fade")
        try expect(threeChildren.allSatisfy(inbox.rowIdsForQA.contains), "motion: Reduce Motion must still reveal every child")
        try capture("open")
        inbox.prefersReducedMotion = { false }
        _ = inbox.clickDisclosureForQA(id: threeChildParent)
        try expect(motion.isAnimating, "motion: the group must animate again when motion is enabled")
        inbox.prefersReducedMotion = { true }
        inbox.reapplyDisplayPreferencesForQA()
        try expect(!motion.isAnimating, "motion: changing Reduce Motion mid-flight must settle immediately")
        inbox.prefersReducedMotion = { false }
        _ = inbox.clickDisclosureForQA(id: threeChildParent)
        inbox.reload(rows: rows())
        try expect(!motion.isAnimating, "motion: a new native list must retire stale presentation")
        _ = inbox.clickDisclosureForQA(id: threeChildParent)
        inbox.removeFromSuperview()
        try expect(!motion.isAnimating, "motion: detaching the sidebar must stop its display link and restore its rows")
        return "motion: 180/150 ms soft unfold retiring at \(Int(InboxFoldMotion.settleFraction * 100))% (under 0.5% travel left), first frame \(Int(travelled * 100))% in, softened toolbar spring peak \(peak), anchored parent, continuous reversal, uninterrupted stream updates, no per-frame cell builds, reduced motion and cleanup"
    }

    /// Dylan: "it feels delayed and almost unresponsive." The delay is the work
    /// before the first frame, so measure exactly that: the wall time of one
    /// fold with a full screen of cards, and how far the first frame moves.
    /// Held against the FASTEST of ten folds — the fold's own cost, which a
    /// shared machine's load can only add to. Debug build, load average ~20:
    /// 158–211 ms median before the incremental fold, 52–92 ms after.
    static let foldLatencyBudget: TimeInterval = 0.1

    static func checkFoldLatency(windows: inout [NSWindow]) throws -> String {
        let parent = id(100)
        let children = (0..<3).map { id(110 + $0) }
        func root(_ id: UUID, _ title: String, _ age: Double) -> AgentInboxRow {
            AgentInboxRow(id: id, title: title, state: .ready,
                          lastActiveAt: epoch.addingTimeInterval(-age), createdAt: epoch.addingTimeInterval(-age))
        }
        var list = [root(parent, "Busy parent", 10)]
        list += children.enumerated().map { index, child in
            AgentInboxRow(id: child, title: "Child \(index)", state: .ready,
                          lastActiveAt: epoch.addingTimeInterval(-Double(9 - index)), depth: 1,
                          createdAt: epoch.addingTimeInterval(-Double(9 - index)), parentId: parent)
        }
        list += (0..<19).map { root(id(200 + $0), "Root \($0)", Double(20 + $0)) }
        let inbox = makeInbox(list, appearance: .darkAqua, height: 1_900, windows: &windows)
        inbox.prefersReducedMotion = { false }
        let motion = inbox.foldMotionForQA
        // The first display pass a real window makes, which settles the list's
        // initial height revalidation before anyone can click.
        inbox.needsLayout = true
        inbox.layoutSubtreeIfNeeded()
        let visible = inbox.qaMaterializedRowCells.count
        var samples: [TimeInterval] = []
        var builds: [Int] = []
        for _ in 0..<10 {
            let built = inbox.cellBuildCountForQA
            let start = CACurrentMediaTime()
            try expect(inbox.clickDisclosureForQA(id: parent), "latency: the parent's disclosure was unavailable")
            samples.append(CACurrentMediaTime() - start)
            builds.append(inbox.cellBuildCountForQA - built)
            try expect(motion.isAnimating, "latency: the fold did not animate")
            // The next display cycle lands on the fold's first frames: it must
            // not rebuild the list under the presentation.
            let settled = inbox.cellBuildCountForQA
            inbox.needsLayout = true
            inbox.layoutSubtreeIfNeeded()
            try expect(inbox.cellBuildCountForQA == settled,
                       "latency: the layout pass after a fold rebuilt \(inbox.cellBuildCountForQA - settled) cells")
            motion.cancel()
            inbox.layoutViewportForQA()
        }
        // Only the parent, its children and the rows whose place in the tree
        // moved are rebuilt — never the screenful of cards around them.
        try expect(builds.allSatisfy { $0 <= children.count + 2 },
                   "latency: a fold rebuilt \(builds) cells; at most the parent, its \(children.count) children and one neighbour")
        let sorted = samples.sorted()
        let fastest = sorted.first ?? 0, median = sorted[sorted.count / 2], worst = sorted.last ?? 0
        try expect(fastest < foldLatencyBudget,
                   String(format: "latency: a fold with %d cards took at least %.1f ms before its first frame (budget %.0f ms)",
                          visible, fastest * 1000, foldLatencyBudget * 1000))
        return String(format: "latency: fold with %d cards in %.1f ms fastest, %.1f ms median, %.1f ms worst, %@ cells built, none on the next layout",
                      visible, fastest * 1000, median * 1000, worst * 1000, builds.description)
    }

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
        // Plan 106: the fold glyph and its count say what a folded lead holds;
        // no cards are tucked behind it. Its row is a childless root's.
        if SidebarDensityProposal.production.isTwoLine {
            try expect(one.count == 0 && three.count == 0 && lone.count == 0,
                       "\(label): a folded lead tucks cards behind it — got \(one.count), \(three.count)")
            try expect(one.rowFrame.height == lone.rowFrame.height && three.rowFrame.height == lone.rowFrame.height,
                       "\(label): a folded lead's row is not a childless root's")
            try expect(inbox.clickDisclosureForQA(id: threeChildParent), "\(label): the fold glyph could not be clicked")
            inbox.layoutForQA()
            try expect(threeChildren.allSatisfy(inbox.rowIdsForQA.contains),
                       "\(label): opening the lead did not draw its subagents")
            return "\(label): folded leads tuck nothing, rows \(one.rowFrame.height)pt = lone \(lone.rowFrame.height)pt; opened draws its subagents"
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

    // MARK: - The wash IS the card

    /// At rest a folded parent's visible sheet is the group wash, not the card,
    /// whose fill is nil until hovered. If the two rects differ, hover swaps one
    /// sheet for another of a different shape: the reported "weird inset at the
    /// top of a card when hovering", and an off-centre card at rest.
    static func checkTuckedCards(windows: inout [NSWindow]) throws -> String {
        let inbox = makeInbox(rows(), appearance: .darkAqua, windows: &windows)
        inbox.prefersReducedMotion = { true }
        try expect(inbox.clickDisclosureForQA(id: askingParent), "wash: the asking parent's triangle could not be clicked")
        inbox.layoutForQA()
        func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) <= 0.5 }
        // Plan 106: every lead is a solid card and its strip IS the card, folded or
        // open, at rest or hovered; nothing is tucked behind a folded one.
        if SidebarDensityProposal.production.isTwoLine {
            var notes: [String] = []
            for (name, id) in [("one-child", oneChildParent), ("three-child", threeChildParent)] {
                guard let cell = inbox.onScreenCardForQA(id: id), let wash = cell.qaWashRectForQA else {
                    throw Failure(description: "wash \(name): no folded lead with a card strip")
                }
                let card = cell.qaCardFrameForQA
                try expect(near(wash.minY, card.minY) && near(wash.maxY, card.maxY),
                           "wash \(name): the folded lead's strip \(wash) is not its card \(card) — hover will swap sheets")
                try expect(cell.qaTuckedCardsForQA.count == 0, "wash \(name): cards are tucked behind a folded lead")
                notes.append("\(name) strip = card \(card.minY)–\(card.maxY)")
            }
            guard let open = inbox.onScreenCardForQA(id: askingParent), let openWash = open.qaWashRectForQA else {
                throw Failure(description: "wash: the opened lead drew no card strip")
            }
            try expect(near(openWash.minY, open.qaCardFrameForQA.minY),
                       "wash open: an open lead's strip starts at \(openWash.minY), its card at \(open.qaCardFrameForQA.minY)")
            try expect(inbox.hoverRowForQA(id: threeChildParent), "wash: could not hover the folded lead")
            inbox.layoutForQA()
            guard let hovered = inbox.onScreenCardForQA(id: threeChildParent), let hoveredWash = hovered.qaWashRectForQA,
                  near(hoveredWash.minY, hovered.qaCardFrameForQA.minY), near(hoveredWash.maxY, hovered.qaCardFrameForQA.maxY) else {
                throw Failure(description: "wash: hovered, the lead's plate is not its card strip")
            }
            return "wash: " + notes.joined(separator: "; ") + "; open lead strip top = card top; hovered plate = strip"
        }
        let peek = InboxGroupBackgroundView.tuckedPeek
        var notes: [String] = []
        for (name, id, depths) in [("one-child", oneChildParent, 1), ("three-child", threeChildParent, 2)] {
            guard let tucked = inbox.tuckedCardsForQA(id: id),
                  let cell = tucked.cell as? AgentInbox96CellView,
                  let wash = cell.qaWashRectForQA else {
                throw Failure(description: "wash \(name): no materialized folded parent with a wash")
            }
            let card = tucked.card
            try expect(near(wash.minY, card.minY),
                       "wash \(name): the folded parent's wash starts at \(wash.minY), its card at \(card.minY) — hover will swap sheets")
            try expect(near(wash.maxY, card.maxY),
                       "wash \(name): the folded parent's wash ends at \(wash.maxY), its card at \(card.maxY)")
            try expect(tucked.rects.count == depths, "wash \(name): \(tucked.rects.count) tucked cards, wanted \(depths)")
            let bottoms = tucked.rects.map(\.maxY).sorted()
            for (index, bottom) in bottoms.enumerated() {
                let wanted = card.maxY + peek * CGFloat(index + 1)
                try expect(near(bottom, wanted),
                           "wash \(name): tucked card \(index + 1) ends at \(bottom), wanted card bottom + \(peek)×\(index + 1) = \(wanted)")
            }
            notes.append("\(name) wash \(wash.minY)–\(wash.maxY) = card \(card.minY)–\(card.maxY), tucked \(bottoms)")
        }
        guard let open = inbox.qaMaterializedRowCells.first(where: { $0.qaAgentID == askingParent }) as? AgentInbox96CellView,
              let openWash = open.qaWashRectForQA else {
            throw Failure(description: "wash: the opened parent drew no wash")
        }
        try expect(near(openWash.minY, open.qaCardFrameForQA.minY),
                   "wash open: an open parent's wash starts at \(openWash.minY), its card at \(open.qaCardFrameForQA.minY)")
        // Hovered, the card's own plate is the sheet: its text must sit centred.
        try expect(inbox.hoverRowForQA(id: threeChildParent), "wash: could not hover the folded parent")
        inbox.layoutForQA()
        guard let hovered = inbox.qaMaterializedRowCells.first(where: { $0.qaAgentID == threeChildParent }) as? AgentInbox96CellView else {
            throw Failure(description: "wash: the hovered parent has no cell")
        }
        let frames = hovered.qaGeometry.elementFrames
        guard let sheet = frames["card"], let project = frames["project"], let detail = frames["branch"] else {
            throw Failure(description: "wash: the hovered card reported no project or detail line")
        }
        let above = project.minY - sheet.minY, below = sheet.maxY - detail.maxY
        try expect(near(above, below),
                   "wash: hovered, the plate shows \(above)pt above the project line and \(below)pt below the detail line")
        // And at rest, where the sheet you see is the wash.
        guard let restingWash = hovered.qaWashRectForQA else {
            throw Failure(description: "wash: the hovered parent lost its wash")
        }
        let restAbove = project.minY - restingWash.minY, restBelow = restingWash.maxY - detail.maxY
        try expect(near(restAbove, restBelow),
                   "wash: at rest the sheet shows \(restAbove)pt above the project line and \(restBelow)pt below the detail line")
        return "wash: " + notes.joined(separator: "; ") + "; open parent wash top = card top; hovered text \(above)pt above / \(below)pt below"
    }

    // MARK: - Hover updates the card on screen

    /// Hover used to reload the row, which vends a NEW cell: the fill snapped,
    /// the 150 ms hover-action crossfade never ran (the new cell had no window),
    /// the settle nudge replayed its arrival and a running fold was cancelled.
    static func checkHoverInPlace(windows: inout [NSWindow]) throws -> String {
        let inbox = makeInbox(rows(), appearance: .darkAqua, windows: &windows)
        inbox.prefersReducedMotion = { false }
        inbox.hoverCardEnabled = false
        inbox.onRowAction = { _, _ in }
        inbox.wiredRowActions = [.snooze, .settle]
        inbox.rebuildRowsForQA()
        let sweep = [oneChildParent, threeChildParent, askingParent, loneRoot]
        let before = Dictionary(uniqueKeysWithValues: sweep.map { ($0, inbox.onScreenCardForQA(id: $0)) })
        let builds = inbox.cellBuildCountForQA
        var fades = 0
        for id in sweep + [nil] {
            try expect(inbox.hoverRowForQA(id: id), "hover: could not hover \(String(describing: id))")
            if let id, inbox.onScreenCardForQA(id: id)?.qaHoverFadeInFlightForQA == true { fades += 1 }
            inbox.layoutViewportForQA()
            if let id {
                guard let cell = inbox.onScreenCardForQA(id: id) else {
                    throw Failure(description: "hover: \(id) has no cell on screen")
                }
                try expect(cell === before[id] ?? nil,
                           "hover: hovering \(id) replaced its on-screen cell instead of updating it")
                try expect(cell.qaGeometry.surfaceRole == .hover,
                           "hover: the hovered card paints \(cell.qaGeometry.surfaceRole), not hover")
                try expect(cell.qaTextAlpha == 1, "hover: the hovered card's words stayed receded (\(cell.qaTextAlpha))")
                try expect(cell.qaStatusAlphasForQA.allSatisfy { $0 > 0.99 },
                           "hover: hovering hid the card's status (\(cell.qaStatusAlphasForQA))")
            }
        }
        try expect(inbox.cellBuildCountForQA == builds,
                   "hover: a sweep over \(sweep.count) rows built \(inbox.cellBuildCountForQA - builds) cells")
        try expect(sweep.allSatisfy { inbox.onScreenCardForQA(id: $0)?.qaGeometry.surfaceRole == .resting },
                   "hover: leaving the list left a card lit")
        try expect(fades == sweep.count,
                   "hover: the fill and hover-action crossfade ran on \(fades) of \(sweep.count) hovered cards")
        // A hover in the middle of a fold must not cut the fold short.
        try expect(inbox.clickDisclosureForQA(id: threeChildParent), "hover: parent disclosure was unavailable")
        let motion = inbox.foldMotionForQA
        try expect(motion.isAnimating, "hover: the fold did not start")
        motion.advance(by: 0.04)
        let elapsed = motion.elapsed
        try expect(inbox.hoverRowForQA(id: loneRoot), "hover: could not hover mid-fold")
        try expect(motion.isAnimating && motion.elapsed == elapsed,
                   "hover: pointing at a row mid-fold cancelled the fold")
        motion.cancel()
        return "hover: \(sweep.count)-row sweep updated the cards on screen with 0 builds, fill and action crossfade on each, a fold kept running through a hover"
    }

    // MARK: - Deck breathe

    /// Hovering a folded parent lifts its card a point and fans the cards
    /// tucked behind it — per agent, inside the gap, without touching the tree
    /// lines — and Reduce Motion, a fold and a scroll each land it flat.
    static func checkDeckBreathe(windows: inout [NSWindow]) throws -> String {
        let inbox = makeInbox(rows(), appearance: .darkAqua, windows: &windows)
        inbox.prefersReducedMotion = { false }
        inbox.hoverCardEnabled = false
        func card(_ id: UUID) throws -> AgentInbox96CellView {
            guard let cell = inbox.onScreenCardForQA(id: id) else { throw Failure(description: "deck: \(id) is not on screen") }
            return cell
        }
        func angle(_ t: CATransform3D) -> CGFloat { atan2(t.m12, t.m11) * 180 / .pi }
        func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.01 }
        func isIdentity(_ t: CATransform3D) -> Bool { CATransform3DIsIdentity(t) }
        let deck = InboxGroupBackgroundView.Deck.self

        let three = try card(threeChildParent)
        // Plan 106: the lead's card is one flat surface with its subagents and
        // nothing is tucked behind it, so hover lifts nothing.
        if SidebarDensityProposal.production.isTwoLine {
            try expect(inbox.hoverRowForQA(id: threeChildParent), "deck: could not hover")
            let posed = three.qaDeckForQA
            try expect(near(posed.card.m42, 0) && posed.sheets.allSatisfy(isIdentity),
                       "deck: a hovered lead must not lift — card \(posed.card.m42)")
            _ = inbox.hoverRowForQA(id: nil)
            return "deck: a hovered lead stays flat on its card"
        }
        let spine = three.qaSpineSegmentsForQA
        try expect(inbox.hoverRowForQA(id: threeChildParent), "deck: could not hover")
        let posed = three.qaDeckForQA
        try expect(near(posed.card.m42, -deck.lift) && near(posed.sheets[0].m42, -deck.lift),
                   "deck: the hovered card and its front sheet must rise \(deck.lift)pt — card \(posed.card.m42), sheet \(posed.sheets[0].m42)")
        try expect(posed.sheets.count == 3, "deck: the three-child parent posed \(posed.sheets.count - 1) tucked cards, not 2")
        let back = Array(posed.sheets.dropFirst())
        // The specified fan, shrunk evenly to fit the gap when it must; never
        // so far that it stops reading as a fan.
        let scale = three.qaDeckScaleForQA
        try expect(scale > 0.4 && scale <= 1, "deck: the fan was scaled to \(scale) of the spec to fit its gap")
        for (index, t) in back.enumerated() {
            try expect(near(t.m42, deck.drops[index] * scale),
                       "deck: tucked card \(index + 1) drops \(t.m42)pt, not \(deck.drops[index])×\(scale)")
            try expect(abs(abs(angle(t)) - deck.angles[index] * scale) <= (deck.angleJitter + 0.01) * scale,
                       "deck: tucked card \(index + 1) turns \(angle(t))°, outside (\(deck.angles[index])±\(deck.angleJitter)°)×\(scale)")
            try expect(abs(t.m41) <= (deck.lateralJitter + 0.01) * scale, "deck: tucked card \(index + 1) slides \(t.m41)pt sideways")
        }
        try expect(angle(back[0]) * angle(back[1]) < 0, "deck: the two tucked cards must turn opposite ways")
        try expect(posed.springs == 4, "deck: \(posed.springs) of 4 layers sprang — the pose must animate in")
        try expect(three.qaSpineSegmentsForQA == spine, "deck: hovering moved the row's tree lines")
        // Inside the gap: nothing reaches the next card or leaves the row's width.
        guard let next = inbox.onScreenCardForQA(id: askingParent) else { throw Failure(description: "deck: no next row") }
        let nextTop = next.qaCardFrameForQA.minY
        var clearance = CGFloat.greatestFiniteMagnitude
        for box in posed.tuckedBoxes {
            let inNext = three.convert(box, to: next)
            clearance = min(clearance, nextTop - inNext.maxY)
            try expect(inNext.maxY <= nextTop && box.minX >= 0 && box.maxX <= three.bounds.width,
                       "deck: a fanned card \(inNext) crosses the next card at \(nextTop) or the row's width")
        }

        // Per agent: another agent fans differently, the same one identically.
        try expect(inbox.hoverRowForQA(id: askingParent), "deck: could not move hover")
        try expect(isIdentity(three.qaDeckForQA.card) && three.qaDeckForQA.sheets.allSatisfy(isIdentity),
                   "deck: leaving the row must land it at rest")
        try expect(inbox.clickDisclosureForQA(id: askingParent), "deck: could not fold the asking parent")
        inbox.foldMotionForQA.cancel()
        inbox.layoutForQA()
        try expect(inbox.hoverRowForQA(id: askingParent), "deck: could not hover the folded asking parent")
        let other = try card(askingParent).qaDeckForQA.sheets.dropFirst()
        try expect(!(near(other.first!.m41, back[0].m41) && near(angle(other.first!), angle(back[0]))),
                   "deck: two agents fanned identically — the pose is not per agent")
        try expect(inbox.hoverRowForQA(id: threeChildParent), "deck: could not hover back")
        let again = try card(threeChildParent).qaDeckForQA.sheets
        try expect(zip(again, posed.sheets).allSatisfy { CATransform3DEqualToTransform($0, $1) },
                   "deck: the same agent fanned differently the second time")

        // A card with nothing tucked behind it only lifts.
        try expect(inbox.hoverRowForQA(id: loneRoot), "deck: could not hover the lone root")
        let lone = try card(loneRoot).qaDeckForQA
        try expect(near(lone.card.m42, -deck.lift) && lone.sheets.allSatisfy(isIdentity),
                   "deck: a card with nothing tucked must lift \(deck.lift)pt and pose nothing else")

        // Reduce Motion, re-read live: flat at once, and the fill still fades.
        try expect(inbox.hoverRowForQA(id: threeChildParent), "deck: could not hover")
        inbox.prefersReducedMotion = { true }
        inbox.reapplyDisplayPreferencesForQA()
        let flat = three.qaDeckForQA
        try expect(isIdentity(flat.card) && flat.sheets.allSatisfy(isIdentity) && flat.springs == 0,
                   "deck: turning on Reduce Motion must land the hovered deck flat")
        try expect(inbox.hoverRowForQA(id: oneChildParent), "deck: could not hover under Reduce Motion")
        let reduced = try card(oneChildParent)
        try expect(isIdentity(reduced.qaDeckForQA.card) && reduced.qaDeckForQA.sheets.allSatisfy(isIdentity),
                   "deck: under Reduce Motion hover must not move or turn anything")
        try expect(reduced.qaFillFadeInFlightForQA, "deck: under Reduce Motion the fill must still cross-fade")
        inbox.prefersReducedMotion = { false }

        // A fold photographs the resting deck.
        try expect(inbox.hoverRowForQA(id: threeChildParent), "deck: could not hover")
        try expect(three.qaDeckIsPosedForQA, "deck: the hover did not pose the deck")
        let posedPhotos = inbox.qaPosedDecksPhotographed
        try expect(inbox.clickDisclosureForQA(id: threeChildParent), "deck: could not fold")
        try expect(inbox.qaPosedDecksPhotographed == posedPhotos,
                   "deck: the fold photographed \(inbox.qaPosedDecksPhotographed - posedPhotos) card(s) mid-pose instead of at rest")
        inbox.foldMotionForQA.cancel()

        // The hover card leaves by fading, not by vanishing.
        inbox.hoverCardEnabled = true
        inbox.hoverCardScheduler = { _, work in work(); return {} }
        try expect(inbox.hoverRowForQA(id: loneRoot) && inbox.isHoverCardVisibleForQA, "deck: the hover card did not open")
        inbox.hoverRowForQA(id: nil)
        try expect(!inbox.isHoverCardVisibleForQA && inbox.isHoverCardFadingOutForQA,
                   "deck: the hover card must fade out over \(AgentInboxView.hoverCardFadeOut)s, not vanish")
        inbox.hoverCardEnabled = false
        inbox.hoverCardScheduler = nil

        // Scrolling removes the springs: a short list in a short window.
        let short = makeInbox(rows(), appearance: .darkAqua, height: 300, windows: &windows)
        short.prefersReducedMotion = { false }
        short.hoverCardEnabled = false
        try expect(short.hoverRowForQA(id: oneChildParent), "deck: could not hover in the short list")
        guard let scrolled = short.onScreenCardForQA(id: oneChildParent) else { throw Failure(description: "deck: no card") }
        try expect(scrolled.qaDeckForQA.springs > 0, "deck: the short list's hover did not spring")
        short.scrollListForQA(by: 20)
        try expect(scrolled.qaDeckForQA.springs == 0, "deck: scrolling must remove the deck's springs")

        let fan = back.map { String(format: "%.1fpt/%.2f°", $0.m42, angle($0)) }.joined(separator: ", ")
            + String(format: " (%.0f%% of the spec)", scale * 100)
        return "deck: hovered folded parent lifts \(deck.lift)pt and fans \(fan) with \(String(format: "%.1f", clearance))pt to the next card, per agent and stable, tree lines unmoved; Reduce Motion, a fold and a scroll land it flat; the hover card fades out"
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
        if SidebarDensityProposal.production.isTwoLine {
            // Plan 106: no tucked cards; the folded lead raises the ask itself.
            try expect(quiet.onScreenCardForQA(id: askingParent)?.selfReportTextForQA?.string.hasPrefix("Needs you") == true,
                       "the folded asking lead does not raise its subagent's ask")
        } else {
        try expect(quiet.tuckedCardsForQA(id: askingParent)?.count == 2,
                   "the folded asking parent shows its two children as tucked cards")
        }
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
