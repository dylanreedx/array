import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

// Plan: .plans/106-sidebar-ownership (LOCKED: T2 + N1)
//
// `--sidebar-ownership-check [dir]`: the production `AgentInboxView`, in both
// appearances, over a list shaped like Dylan's — a 53-subagent lead open with
// helpers of helpers, a lead whose subagent asks, folded working leads. It
// asserts what the redesign is for: each count is drawn once, a subagent repeats
// none of its lead's project or branch, a subagent's ask is raised on its lead,
// line 2 says the right thing per state, and Pop out / Stop on hover and the
// right-click verbs go through real events to the row actions. With a directory
// it writes the two pictures.
@MainActor
enum SidebarOwnershipChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }

    private final class KeyWindow: NSWindow {
        override var canBecomeKey: Bool { true }
    }

    static let now = Date(timeIntervalSince1970: 1_900_600_000)
    static let workspaceId = uuid(0x701)
    static func uuid(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012X", n))!
    }

    static let quality = 0x400
    static let verify = 0x300
    static let collab = 0x200
    static let asker = quality + 5
    static let pinnedOut = quality + 3
    static let reporter = quality + 6

    // MARK: Fixture

    static func rows() -> [AgentInboxRow] {
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        var out: [AgentInboxRow] = []
        func add(_ n: Int, _ title: String, project: String = "Array", state: InboxState = .ready,
                 codex: Bool = false, elapsed: TimeInterval? = nil, parent: Int? = nil,
                 colour: String? = nil, minutes: Double, read: Bool = true,
                 branch: String? = "array/integration", report: InboxSelfReport? = nil,
                 hasTile: Bool? = nil, pinned: Bool = false) {
            let finished = state == .ready
            out.append(AgentInboxRow(
                id: uuid(n), title: title, projectName: project, projectId: uuid(0x800 + project.count),
                workspaceName: "personal", workspaceId: workspaceId, state: state, lifecycle: .active,
                model: codex ? "gpt-6.1-sol" : "claude-opus-5-5", branch: branch,
                elapsed: elapsed, elapsedStartedAt: elapsed.map { now.addingTimeInterval(-$0) },
                lastActiveAt: ago(minutes), depth: 0, createdAt: ago(minutes + 5 + Double(n % 7)),
                parentId: parent.map(uuid), harness: codex ? "Codex" : "Claude Code",
                terminalEvent: finished
                    ? AgentTerminalEvent(sequence: 1, turnID: nil, outcome: .succeeded, endedAt: ago(minutes)) : nil,
                terminalIsUnread: finished && !read, identityColor: colour, selfReport: report,
                hasTile: hasTile ?? (parent == nil), isPinned: pinned))
        }
        let helpers = [
            "Map the zone placement seam", "Read the spawn follows camera bench", "Audit tile frame persistence",
            "Trace the board query path", "Check the drag ghost on zoom", "Draft the board navigation note",
            "Review the merged witness legs", "Probe the canvas query ops", "List tiles without owners",
        ]
        // A lead running with 24 subagents, three still working; folded.
        add(collab, "Explore collaborative agent workspace concepts", state: .working, codex: true,
            elapsed: 630, colour: "blue", minutes: 1)
        for i in 0..<24 {
            add(collab + 1 + i, helpers[i % helpers.count], state: i < 3 ? .working : .ready, codex: true,
                elapsed: i < 3 ? Double(200 + i * 60) : nil, parent: collab, minutes: 3 + Double(i))
        }
        // A lead running with two working subagents; open.
        add(verify, "Verify Claude Code personal account usage", state: .working, elapsed: 16,
            colour: "mint", minutes: 0)
        for (i, title) in ["Probe usage", "Capture the Work Team row", "Read the accounts card",
                           "Compare Max and Team limits", "Check the 5-hour window"].enumerated() {
            add(verify + 1 + i, title, state: i < 2 ? .working : .ready, elapsed: i < 2 ? Double(40 - i * 28) : nil,
                parent: verify, minutes: 2 + Double(i),
                report: i == 0 ? InboxSelfReport(now: "Calling /usage") : nil)
        }
        // The big one: done itself, 53 subagents, one asking, helpers of helpers.
        add(quality, "Explore Array quality and orchestration", colour: "purple", minutes: 30, read: false)
        let named = ["Build one-line sidebar status", "Render report card design sheet",
                     "Witness parent's adopted second turn", "Keep reports across relaunch",
                     "Fix the subscription account card", "Land the hook bridge"]
        for i in 0..<51 {
            let n = quality + 1 + i
            let asking = n == asker
            add(n, i < named.count ? named[i] : helpers[i % helpers.count] + " #\(i)",
                state: asking ? .approval : (i == 2 ? .working : .ready), codex: i == 3,
                elapsed: i == 2 ? 380 : nil, parent: quality, minutes: 32 + Double(i),
                report: asking ? InboxSelfReport(needsYou: "allow git push")
                    : n == reporter ? InboxSelfReport(checksPassed: 5, checksFailed: 1) : nil,
                hasTile: n == pinnedOut ? true : false, pinned: n == pinnedOut)
            if i == 0 {
                add(0x480, "Read the status line diff", parent: n, minutes: 33)
                add(0x481, "Measure lane width", state: .working, elapsed: 95, parent: n, minutes: 0,
                    report: InboxSelfReport(now: "iOS build"))
            }
        }
        add(0x250, "Enable cross-provider child agent delegation", codex: true, minutes: 60)
        return out
    }

    // MARK: Harness

    struct Built {
        let inbox: AgentInboxView
        let window: NSWindow
        var actions: [(InboxRowAction, [UUID])]
    }

    static func build(dark: Bool, width: CGFloat = 380, height: CGFloat = 1400,
                      record: @escaping (InboxRowAction, [UUID]) -> Void) -> (AgentInboxView, NSWindow) {
        let inbox = AgentInboxView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        inbox.clock = { now }
        inbox.foldsUntouchedGroups = true
        inbox.prefersReducedMotion = { false }
        inbox.onRevealRow = { _ in }
        inbox.hoverCardEnabled = false
        inbox.onRowAction = record
        inbox.wiredRowActions = AppDelegate.wiredInboxRowActions
        let window = KeyWindow(contentRect: inbox.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = inbox
        window.orderFrontOffscreenForChecks()
        window.makeKey()
        inbox.pinScrollerStyleForQA()
        inbox.currentWorkspaceId = workspaceId
        inbox.currentWorkspaceName = "personal"
        inbox.setScope(.all)
        inbox.restoreParentFolds([uuid(quality): true, uuid(verify): true, uuid(quality + 1): true])
        inbox.reload(rows: rows())
        inbox.layoutForQA()
        inbox.scrollToTopForQA()
        inbox.layoutForQA()
        return (inbox, window)
    }

    private static func mouse(_ type: NSEvent.EventType, at point: NSPoint, window: NSWindow) throws -> NSEvent {
        guard let event = NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
            pressure: type == .leftMouseUp || type == .rightMouseUp ? 0 : 1)
        else { throw Failure(description: "could not synthesise \(type)") }
        return event
    }

    // MARK: Run

    static func run(outputDirectory: URL?) throws -> String {
        var report: [String] = []
        for dark in [true, false] {
            var actions: [(InboxRowAction, [UUID])] = []
            let (inbox, window) = build(dark: dark) { actions.append(($0, $1)) }
            defer { window.orderOut(nil) }
            let label = dark ? "dark" : "light"
            func cell(_ n: Int) throws -> AgentInbox96CellView {
                guard let cell = inbox.ownershipCellForQA(id: uuid(n)) else {
                    throw Failure(description: "\(label): no row for \(String(n, radix: 16))")
                }
                cell.layoutSubtreeIfNeeded()
                return cell
            }

            // 1. Each count once, no rollup words, no "Done ·".
            let lead = try cell(quality)
            let leadText = lead.visibleTextForQA
            guard leadText.filter({ $0 == "53" }).count == 1 else {
                throw Failure(description: "\(label): the 53-subagent count is not drawn exactly once: \(leadText)")
            }
            let everything = (inbox.ownershipRemaindersForQA.map(\.qaTitle)
                + [quality, verify, collab, quality + 1, asker].flatMap { (try? cell($0).visibleTextForQA) ?? [] })
                .joined(separator: " | ")
            for banned in ["children", "child agents", "Done ·"] where everything.contains(banned) {
                throw Failure(description: "\(label): duplicate copy \"\(banned)\" is drawn: \(everything)")
            }

            // 2. A subagent repeats none of its lead's project or branch.
            for n in [quality + 1, asker, reporter, 0x481] {
                let text = try cell(n).visibleTextForQA
                if text.contains("Array") || text.contains("array/integration") {
                    throw Failure(description: "\(label): subagent \(String(n, radix: 16)) repeats its lead's place: \(text)")
                }
            }

            // 3. Needs you is raised on the lead; the asking subagent waits quietly.
            guard lead.tailTextForQA?.contains("Needs you: allow git push") == true else {
                throw Failure(description: "\(label): the lead does not raise its subagent's ask: \(lead.tailTextForQA ?? "nil")")
            }
            let askingRow = try cell(asker)
            guard askingRow.clockTextForQA == "waiting", askingRow.tailTextForQA?.contains("Needs you") != true else {
                throw Failure(description: "\(label): the asking subagent reads \(askingRow.clockTextForQA ?? "nil") / \(askingRow.tailTextForQA ?? "nil")")
            }
            guard !lead.isSweepingForQA else {
                throw Failure(description: "\(label): a card that asks must not run its light")
            }

            // 4. Line 2 per state: folded facts, an open lead's branch, a report pill.
            let folded = try cell(collab)
            guard folded.tailTextForQA?.contains("3 working") == true else {
                throw Failure(description: "\(label): the folded lead does not speak for its subagents: \(folded.tailTextForQA ?? "nil")")
            }
            let open = try cell(verify)
            guard open.tailTextForQA == nil, open.visibleTextForQA.contains("array/integration") else {
                throw Failure(description: "\(label): the open running lead should show its branch: \(open.visibleTextForQA)")
            }
            guard try cell(reporter).reportPillForQA == "1/6 failed" else {
                throw Failure(description: "\(label): the report result is not the small pill")
            }
            let probe = try cell(verify + 1)
            guard probe.visibleTextForQA.contains(where: { $0.contains("Calling /usage") }) else {
                throw Failure(description: "\(label): a status that fits is not drawn after the title: \(probe.visibleTextForQA)")
            }

            // 5. Motion: the running card's light runs through every slice; working
            // text shimmers; a working subagent pulses.
            guard open.isSweepingForQA, probe.isSweepingForQA, folded.isSweepingForQA else {
                throw Failure(description: "\(label): a running card's light is not running in every slice")
            }
            guard open.isTitleShimmeringForQA, probe.isTitleShimmeringForQA, probe.isPulsingForQA else {
                throw Failure(description: "\(label): working text does not shimmer or a working subagent does not pulse")
            }
            guard !(try cell(verify + 3)).isPulsingForQA else {
                throw Failure(description: "\(label): a finished subagent pulses")
            }

            // 6. The stem: one lane from the lead, a foot at its last direct row.
            let slices = [verify, verify + 1, verify + 5].compactMap { inbox.ownershipSliceForQA(id: uuid($0)) }
            guard slices.map(\.leadLane) == [.start, .through, .foot] else {
                throw Failure(description: "\(label): the stem lanes read \(slices.map(\.leadLane))")
            }
            guard inbox.ownershipSliceForQA(id: uuid(quality + 1))?.helperLane == .start,
                  Set([0x480, 0x481].compactMap { inbox.ownershipSliceForQA(id: uuid($0))?.helperLane })
                    == [.through, .foot] else {
                throw Failure(description: "\(label): a subagent's helpers do not get their own short stem: "
                    + "\(String(describing: inbox.ownershipSliceForQA(id: uuid(quality + 1)))) / "
                    + "\(String(describing: inbox.ownershipSliceForQA(id: uuid(0x481)))) / "
                    + "\(String(describing: inbox.ownershipSliceForQA(id: uuid(0x480))))")
            }

            // 7. Hover through the list's own pointer handling: Pop out and Stop.
            let target = try cell(verify + 1)
            let centre = target.convert(NSPoint(x: target.bounds.midX, y: target.bounds.height / 2), to: nil)
            inbox.mouseMoved(with: try mouse(.mouseMoved, at: centre, window: window))
            inbox.layoutForQA()
            target.layoutSubtreeIfNeeded()
            guard target.subagentActionTitlesForQA == ["Stop", "Pop out"] else {
                throw Failure(description: "\(label): hover offers \(target.subagentActionTitlesForQA)")
            }
            guard let popOut = target.subagentActionButtonForQA("Pop out") else {
                throw Failure(description: "\(label): no Pop out button")
            }
            let point = popOut.convert(NSPoint(x: popOut.bounds.midX, y: popOut.bounds.midY), to: nil)
            NSApp.postEvent(try mouse(.leftMouseUp, at: point, window: window), atStart: false)
            NSApp.sendEvent(try mouse(.leftMouseDown, at: point, window: window))
            while let pending = NSApp.nextEvent(matching: [.leftMouseUp], until: Date(), inMode: .default, dequeue: true) {
                NSApp.sendEvent(pending)
            }
            guard actions.last.map({ $0.0 == .popOut && $0.1 == [uuid(verify + 1)] }) == true else {
                throw Failure(description: "\(label): clicking Pop out performed \(actions.map(\.0))")
            }

            // 8. Right-click through the table: a folded subagent offers Pop Out; a
            // popped-out pinned one offers Unpin and Fold Back.
            func menu(_ n: Int) throws -> [String] {
                let row = try cell(n)
                let point = row.convert(NSPoint(x: row.bounds.midX, y: row.bounds.height / 2), to: nil)
                NSApp.sendEvent(try mouse(.rightMouseDown, at: point, window: window))
                NSApp.sendEvent(try mouse(.rightMouseUp, at: point, window: window))
                defer { inbox.dismissRowMenuForQA() }
                return inbox.rowMenuTitlesForQA
            }
            let tileless = try menu(quality + 1)
            guard tileless.contains("Pop Out"), !tileless.contains("Pin"), !tileless.contains("Fold Back") else {
                throw Failure(description: "\(label): a tile-less subagent's menu is \(tileless)")
            }
            let pinned = try menu(pinnedOut)
            guard pinned.contains("Unpin"), pinned.contains("Fold Back"), !pinned.contains("Pop Out") else {
                throw Failure(description: "\(label): a pinned popped-out subagent's menu is \(pinned)")
            }
            let leadMenu = try menu(quality)
            guard !leadMenu.contains("Pop Out"), !leadMenu.contains("Fold Back") else {
                throw Failure(description: "\(label): a lead offers subagent tile verbs: \(leadMenu)")
            }
            inbox.mouseExited(with: try mouse(.mouseMoved, at: .zero, window: window))
            inbox.clearSelectionForQA()
            inbox.layoutForQA()

            if let outputDirectory {
                try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
                let url = outputDirectory.appendingPathComponent("sidebar-\(label).png")
                try write(inbox, to: url)
                report.append(url.path)
            }
            report.append("\(label): counts once, subagents carry no project or branch, ask raised on the lead, "
                + "line 2 per state, light/shimmer/dots, stem lanes, hover Pop out + Stop, right-click verbs")
        }
        for dark in [true, false] {
            for width in [260, 380] as [CGFloat] {
                report.append(try checkIndent(dark: dark, width: width, outputDirectory: outputDirectory))
            }
        }
        return "SidebarOwnershipChecks passed:\n" + report.joined(separator: "\n")
    }

    /// Subagent rows sit just right of the stem, whatever their lead's count and
    /// dot, and a helper steps in by one small, fixed amount — at a narrow and a
    /// wide sidebar. The stem's foot stops short of the row, and hover's Stop and
    /// Pop out and the title's truncation keep clear of each other.
    static func checkIndent(dark: Bool, width: CGFloat, outputDirectory: URL?) throws -> String {
        let (inbox, window) = build(dark: dark, width: width, height: 1400) { _, _ in }
        defer { window.orderOut(nil) }
        let label = "\(dark ? "dark" : "light") \(Int(width))pt"
        func cell(_ n: Int) throws -> AgentInbox96CellView {
            guard let cell = inbox.ownershipCellForQA(id: uuid(n)) else {
                throw Failure(description: "\(label): no row for \(String(n, radix: 16))")
            }
            cell.layoutSubtreeIfNeeded()
            return cell
        }
        let lane = CGFloat(AgentInbox96CellView.outerGutter) + InboxOwnershipChrome.laneX
        let underFive = try cell(verify + 1), underFiftyThree = try cell(quality + 2), helper = try cell(0x481)
        let first = underFive.qaTitleFrameForQA.minX, second = underFiftyThree.qaTitleFrameForQA.minX
        guard abs(first - second) <= 0.5 else {
            throw Failure(description: "\(label): subagent rows start at \(first) under one lead and \(second) under another — the indent follows the lead's count")
        }
        guard first - lane <= 26 else {
            throw Failure(description: "\(label): a subagent's words start \(first - lane)pt right of the stem, wanted 26pt or less")
        }
        let step = helper.qaTitleFrameForQA.minX - second
        guard abs(step - InboxOwnershipChrome.helperIndent) <= 0.5, step <= 12.5 else {
            throw Failure(description: "\(label): a helper steps in \(step)pt, wanted \(InboxOwnershipChrome.helperIndent)pt")
        }
        // The foot reaches toward the row and stops short of its dots.
        let last = try cell(verify + 5)
        guard let foot = last.stemLanesForQA.first(where: { $0.kind == .foot }),
              foot.x + max(InboxOwnershipStemView.footRadius + 1, foot.reach) < last.subagentContentFrameForQA.minX,
              foot.x < last.qaCardFrameForQA.minX else {
            throw Failure(description: "\(label): the stem's foot runs into its last row — lanes \(last.stemLanesForQA), row content at \(last.subagentContentFrameForQA.minX)")
        }
        // Hover: Stop and Pop out inside the row, the truncated title clear of them.
        let target = underFive
        let centre = target.convert(NSPoint(x: target.bounds.midX, y: target.bounds.height / 2), to: nil)
        inbox.mouseMoved(with: try mouse(.mouseMoved, at: centre, window: window))
        inbox.layoutForQA()
        target.layoutSubtreeIfNeeded()
        guard target.subagentActionTitlesForQA == ["Stop", "Pop out"],
              let stop = target.subagentActionButtonForQA("Stop"),
              let popOut = target.subagentActionButtonForQA("Pop out") else {
            throw Failure(description: "\(label): hover offers \(target.subagentActionTitlesForQA)")
        }
        let stopFrame = stop.convert(stop.bounds, to: target), popFrame = popOut.convert(popOut.bounds, to: target)
        guard popFrame.maxX <= target.bounds.width - CGFloat(AgentInbox96CellView.outerGutter) + 0.5,
              target.qaTitleFrameForQA.maxX <= min(stopFrame.minX, popFrame.minX) + 0.5 else {
            throw Failure(description: "\(label): hovered, the title \(target.qaTitleFrameForQA) meets Stop \(stopFrame) / Pop out \(popFrame)")
        }
        inbox.mouseExited(with: try mouse(.mouseMoved, at: .zero, window: window))
        inbox.layoutForQA()
        if let outputDirectory {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            try write(inbox, to: outputDirectory.appendingPathComponent(
                "indent-\(dark ? "dark" : "light")-\(Int(width)).png"))
        }
        return "\(label): subagents \(first - lane)pt right of the stem under every lead, helpers +\(step)pt, foot short of the row, hover clear"
    }

    /// The view as composited, sublayers and masks included.
    static func write(_ view: NSView, to url: URL) throws {
        view.layoutSubtreeIfNeeded()
        // Rows rebuilt by the gestures above have not drawn yet.
        view.window?.displayIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let scale: CGFloat = 2
        let size = view.bounds.size
        guard let layer = view.layer,
              let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw Failure(description: "could not make a context for \(url.lastPathComponent)") }
        context.scaleBy(x: scale, y: scale)
        if layer.isGeometryFlipped || view.isFlipped {
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: 1, y: -1)
        }
        NSAppearance.current = view.effectiveAppearance
        layer.render(in: context)
        guard let image = context.makeImage(),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else { throw Failure(description: "could not encode \(url.lastPathComponent)") }
        try data.write(to: url)
    }
}
