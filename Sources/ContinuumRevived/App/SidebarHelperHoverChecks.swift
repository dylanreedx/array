import AppKit
import QuartzCore
import ContinuumRevivedCore
import ContinuumRevivedAgentUI

/// Helper-row hover. Hover on a helper (subagent) row, and on its group's
/// "N more" line, draws a pill — `textPrimary` at the hover step's strength,
/// translucent, the row's own 18 pt height — in place of the full-width fill.
///
/// `--sidebar-helper-hover-check` drives the pointer through `NSApp.sendEvent`
/// (entered, moved, exited) in an offscreen window over all four styles and
/// both appearances, and asserts the pill is on exactly the hovered row, clears
/// on exit, never rebuilds or re-lays out a row per move, and leaves the
/// selection and style truth table where it was.
///
/// `--sidebar-helper-hover-capture <dir>` writes the frames a reviewer reads:
/// one sheet per appearance, and a film of entering A, moving to B, exiting
/// and hovering the open row, mid-fade frames included.
@MainActor
enum SidebarHelperHoverChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }

    static let now = Date(timeIntervalSince1970: 1_900_600_000)
    static func uuid(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012X", n))!
    }
    static let busyLead = 0x100
    static let idleLead = 0x200
    static let sweepLead = 0x300
    static let styles = ["duplex", "gradient", "sheen", "current"]

    static func label(_ style: String) -> String { style == "current" ? "Classic" : style.capitalized }

    static func rows() -> [AgentInboxRow] {
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        var out: [AgentInboxRow] = []
        func add(_ n: Int, _ title: String, state: InboxState, parent: Int? = nil, colour: String? = nil,
                 minutes: Double, elapsed: TimeInterval? = nil) {
            out.append(AgentInboxRow(
                id: uuid(n), title: title, projectName: "array-scratch", projectId: uuid(0x800),
                workspaceName: "personal", workspaceId: uuid(0x701), state: state, lifecycle: .active,
                model: "claude-opus-5-5", branch: nil,
                elapsed: elapsed, elapsedStartedAt: elapsed.map { now.addingTimeInterval(-$0) },
                lastActiveAt: ago(minutes), depth: parent == nil ? 0 : 1,
                createdAt: ago(minutes + 5 + Double(n % 7)),
                parentId: parent.map(uuid), harness: "Claude Code",
                terminalEvent: state == .ready
                    ? AgentTerminalEvent(sequence: 1, turnID: nil, outcome: .succeeded, endedAt: ago(minutes)) : nil,
                terminalIsUnread: false, identityColor: colour, selfReport: nil,
                hasTile: parent == nil, isPinned: false))
        }
        add(busyLead, "Audit the sidebar hover states", state: .working, colour: "blue", minutes: 0, elapsed: 64)
        add(busyLead + 1, "Read the row and card views", state: .working, parent: busyLead, minutes: 0.2, elapsed: 21)
        add(busyLead + 2, "Measure the token census", state: .working, parent: busyLead, minutes: 0.3, elapsed: 48)
        add(busyLead + 3, "List the hover call sites", state: .ready, parent: busyLead, minutes: 3)
        add(busyLead + 4, "Check light and dark parity", state: .ready, parent: busyLead, minutes: 4)
        add(idleLead, "Draft the release notes", state: .ready, colour: "mint", minutes: 6)
        add(idleLead + 1, "Collect merged changes", state: .ready, parent: idleLead, minutes: 7)
        add(idleLead + 2, "Summarise the fixes", state: .ready, parent: idleLead, minutes: 8)
        add(idleLead + 3, "Proofread the draft", state: .ready, parent: idleLead, minutes: 9)
        // More helpers than the fan-out shows, so the group ends in "N more".
        add(sweepLead, "Sweep the old benches", state: .ready, colour: "orange", minutes: 12)
        for i in 1...10 {
            add(sweepLead + i, "Return bench \(i)", state: .ready, parent: sweepLead, minutes: 12 + Double(i))
        }
        return out
    }

    // MARK: Fixture

    final class Fixture {
        let inbox: AgentInboxView
        let window: SidebarParityCapture.KeyWindow
        let defaults: UserDefaults
        let suite: String
        init(inbox: AgentInboxView, window: SidebarParityCapture.KeyWindow, defaults: UserDefaults, suite: String) {
            self.inbox = inbox; self.window = window; self.defaults = defaults; self.suite = suite
        }
        func close() {
            window.orderOut(nil)
            window.contentView = nil
            defaults.removePersistentDomain(forName: suite)
        }
    }

    static func fixture(style: String, dark: Bool, height: CGFloat = 900) throws -> Fixture {
        let suite = "array.sidebar.helper-hover.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw Failure(description: "no defaults suite") }
        defaults.set(style, forKey: SidebarActiveIndicatorStyle.defaultsKey)
        let inbox = AgentInboxView(frame: NSRect(x: 0, y: 0, width: 300, height: height), indicatorDefaults: defaults)
        inbox.clock = { now }
        inbox.prefersReducedMotion = { false }
        inbox.hoverCardEnabled = false
        inbox.foldsUntouchedGroups = false
        inbox.onRevealRow = { [weak inbox] id in inbox?.openAgentId = id }
        let window = SidebarParityCapture.KeyWindow(
            contentRect: inbox.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = true
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = inbox
        window.orderFrontOffscreenForChecks()
        window.makeKey()
        inbox.pinScrollerStyleForQA()
        inbox.currentWorkspaceId = uuid(0x701)
        inbox.currentWorkspaceName = "personal"
        inbox.setScope(.all)
        inbox.restoreParentFolds([uuid(busyLead): true, uuid(idleLead): true, uuid(sweepLead): true])
        inbox.reload(rows: rows())
        inbox.scrollToTopForQA()
        inbox.layoutForQA()
        SidebarParityCapture.pump()
        return Fixture(inbox: inbox, window: window, defaults: defaults, suite: suite)
    }

    // MARK: Pointer, through the application

    static func windowPoint(_ inbox: AgentInboxView, id: UUID, x fraction: CGFloat = 0.55) throws -> NSPoint {
        guard let cell = inbox.cellForQA(id: id) else { throw Failure(description: "no row \(id)") }
        let y = cell.isFlipped ? 9 : cell.bounds.height - 9
        return cell.convert(NSPoint(x: cell.bounds.width * fraction, y: y), to: nil)
    }

    static func move(to point: NSPoint, in window: NSWindow) throws {
        guard let event = NSEvent.mouseEvent(
            with: .mouseMoved, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) else {
            throw Failure(description: "no mouse-moved event")
        }
        NSApp.sendEvent(event)
    }

    /// How many entered/exited events reached the list only through its owner,
    /// because the application dropped them (see `crossing`).
    static var crossingsHandedToOwner = 0

    /// An entered or exited event, sent through the application first. AppKit
    /// routes a crossing by the tracking area the WINDOW SERVER minted it for;
    /// a synthetic one carries no such area, reads as a legacy tracking rect
    /// and is dropped (measured: the list never saw it). When that happens it
    /// is handed to the area's owner — the one call the window makes for a
    /// real crossing — and counted, so the report says which path ran.
    static func crossing(_ type: NSEvent.EventType, at point: NSPoint, inbox: AgentInboxView, window: NSWindow) throws {
        guard let area = inbox.trackingAreaForQA,
              let event = NSEvent.enterExitEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                trackingNumber: unsafeBitCast(area, to: Int.self), userData: nil) else {
            throw Failure(description: "no \(type) event")
        }
        let before = inbox.pointerCrossingCountForQA
        NSApp.sendEvent(event)
        guard inbox.pointerCrossingCountForQA == before else { return }
        guard let owner = area.owner as? NSResponder else { throw Failure(description: "tracking area has no owner") }
        if type == .mouseEntered { owner.mouseEntered(with: event) } else { owner.mouseExited(with: event) }
        guard inbox.pointerCrossingCountForQA == before + 1 else {
            throw Failure(description: "the list did not take the \(type) event")
        }
        crossingsHandedToOwner += 1
    }

    // MARK: Capture

    static func capture(_ inbox: AgentInboxView, crop: NSRect) throws -> NSBitmapImageRep {
        inbox.layoutSubtreeIfNeeded()
        guard let rep = inbox.bitmapImageRepForCachingDisplay(in: crop) else {
            throw Failure(description: "no bitmap")
        }
        inbox.cacheDisplay(in: crop, to: rep)
        return rep
    }

    /// Render what Core Animation is PRESENTING: every animated layer has its
    /// in-flight values copied onto the model for the one render, then put back.
    /// `cacheDisplay` reads the model tree, so without this a mid-fade frame
    /// would show the fade's end state.
    static func capturePresented(_ inbox: AgentInboxView, crop: NSRect) throws -> NSBitmapImageRep {
        var restore: [() -> Void] = []
        func visit(_ layer: CALayer) {
            if let keys = layer.animationKeys(), !keys.isEmpty, let shown = layer.presentation() {
                let opacity = layer.opacity, background = layer.backgroundColor, transform = layer.transform
                restore.append {
                    layer.opacity = opacity; layer.backgroundColor = background; layer.transform = transform
                }
                layer.opacity = shown.opacity
                layer.backgroundColor = shown.backgroundColor
                layer.transform = shown.transform
            }
            layer.sublayers?.forEach(visit)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let root = inbox.layer { visit(root) }
        CATransaction.commit()
        defer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            restore.forEach { $0() }
            CATransaction.commit()
        }
        return try capture(inbox, crop: crop)
    }

    /// The region from the top of the busy group to the end of the idle one.
    static func groupsCrop(_ inbox: AgentInboxView) throws -> NSRect {
        guard let top = inbox.cellForQA(id: uuid(busyLead)),
              let bottom = inbox.cellForQA(id: uuid(idleLead + 3)) else { throw Failure(description: "no group rows") }
        let a = top.convert(top.bounds, to: inbox), b = bottom.convert(bottom.bounds, to: inbox)
        let union = a.union(b).insetBy(dx: 0, dy: -8)
        return NSRect(x: 0, y: max(0, union.minY), width: inbox.bounds.width,
                      height: min(inbox.bounds.height, union.maxY) - max(0, union.minY))
    }

    struct Tile { let caption: String; let image: NSBitmapImageRep }

    /// One labelled grid, `columns` wide, drawn in Swift so the sheet needs no tool.
    static func sheet(_ tiles: [Tile], columns: Int, title: String, dark: Bool, to url: URL) throws {
        guard let first = tiles.first else { return }
        let w = CGFloat(first.image.pixelsWide), h = CGFloat(first.image.pixelsHigh)
        let caption: CGFloat = 44, pad: CGFloat = 24, head: CGFloat = 70
        let rows = (tiles.count + columns - 1) / columns
        let size = NSSize(width: pad + CGFloat(columns) * (w + pad), height: head + CGFloat(rows) * (h + caption + pad))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
            bitsPerPixel: 0) else { throw Failure(description: "no sheet bitmap") }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        (dark ? NSColor(white: 0.08, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
        NSRect(origin: .zero, size: size).fill()
        let ink = dark ? NSColor.white : NSColor.black
        (title as NSString).draw(at: NSPoint(x: pad, y: size.height - head + 18), withAttributes: [
            .font: NSFont.systemFont(ofSize: 28, weight: .semibold), .foregroundColor: ink])
        for (index, tile) in tiles.enumerated() {
            let column = index % columns, row = index / columns
            let x = pad + CGFloat(column) * (w + pad)
            let top = size.height - head - CGFloat(row) * (h + caption + pad)
            (tile.caption as NSString).draw(at: NSPoint(x: x, y: top - caption + 10), withAttributes: [
                .font: NSFont.systemFont(ofSize: 20, weight: .medium), .foregroundColor: ink])
            // Fit, never stretch: a tile cropped smaller keeps its proportions.
            let iw = CGFloat(tile.image.pixelsWide), ih = CGFloat(tile.image.pixelsHigh)
            let scale = min(1, w / iw, h / ih)
            tile.image.draw(in: NSRect(x: x, y: top - caption - ih * scale, width: iw * scale, height: ih * scale))
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { throw Failure(description: "no PNG") }
        try png.write(to: url)
    }

    static func write(_ rep: NSBitmapImageRep, to url: URL) throws {
        guard let png = rep.representation(using: .png, properties: [:]) else { throw Failure(description: "no PNG") }
        try png.write(to: url)
    }

    /// The shipped pill: one sheet per appearance. Rows: style; columns: rest,
    /// a working helper hovered, an idle helper hovered, the "N more" line hovered.
    static func captureSheets(into directory: URL) throws -> [String] {
        var written: [String] = []
        for dark in [false, true] {
            var tiles: [Tile] = []
            for style in styles {
                for name in ["rest", "working", "idle", "more"] {
                    let fixture = try fixture(style: style, dark: dark)
                    defer { fixture.close() }
                    let inbox = fixture.inbox
                    switch name {
                    case "working": try move(to: try windowPoint(inbox, id: uuid(busyLead + 2)), in: fixture.window)
                    case "idle": try move(to: try windowPoint(inbox, id: uuid(idleLead + 2)), in: fixture.window)
                    case "more":
                        guard let more = inbox.ownershipRemaindersForQA.first(where: { $0.qaParentID == uuid(sweepLead) })
                        else { throw Failure(description: "no N more line") }
                        let frame = more.qaLabelFrameInWindow
                        try move(to: NSPoint(x: frame.midX, y: frame.midY), in: fixture.window)
                    default: break
                    }
                    SidebarParityCapture.pump()
                    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
                    let crop = name == "more" ? try sweepCrop(inbox) : try groupsCrop(inbox)
                    tiles.append(Tile(caption: "\(label(style)) · \(name)", image: try capture(inbox, crop: crop)))
                }
            }
            let url = directory.appendingPathComponent("pill-\(dark ? "dark" : "light").png")
            try sheet(tiles, columns: 4, title: "Helper hover pill — \(dark ? "dark" : "light")", dark: dark, to: url)
            written.append(url.path)
        }
        return written
    }

    /// The last rows of the sweep group, its "N more" line included.
    static func sweepCrop(_ inbox: AgentInboxView) throws -> NSRect {
        guard let more = inbox.ownershipRemaindersForQA.first(where: { $0.qaParentID == uuid(sweepLead) }),
              let above = inbox.cellForQA(id: uuid(sweepLead + 6)) else { throw Failure(description: "no sweep rows") }
        let union = above.convert(above.bounds, to: inbox).union(more.convert(more.bounds, to: inbox)).insetBy(dx: 0, dy: -8)
        return NSRect(x: 0, y: max(0, union.minY), width: inbox.bounds.width, height: union.height)
    }

    /// The film: enter A, move to B, exit, then hover the open row. Frames
    /// every 20 ms through each fade, rendered from the presentation tree.
    static func captureFilm(into directory: URL) throws -> [String] {
        var written: [String] = []
        for dark in [false, true] {
            for style in ["duplex", "current"] {
                let fixture = try fixture(style: style, dark: dark)
                defer { fixture.close() }
                let inbox = fixture.inbox, window = fixture.window
                let crop = try groupsCrop(inbox)
                var tiles: [Tile] = []
                func frames(_ step: String, count: Int = 8) throws {
                    let start = CACurrentMediaTime()
                    for _ in 0..<count {
                        let t = Int(((CACurrentMediaTime() - start) * 1000).rounded())
                        tiles.append(Tile(caption: "\(step) +\(t)ms", image: try capturePresented(inbox, crop: crop)))
                        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
                    }
                }
                let a = try windowPoint(inbox, id: uuid(busyLead + 1))
                let b = try windowPoint(inbox, id: uuid(busyLead + 2))
                try frames("rest", count: 1)
                try crossing(.mouseEntered, at: a, inbox: inbox, window: window)
                try move(to: a, in: window)
                try frames("enter A")
                try move(to: b, in: window)
                try frames("A to B")
                try crossing(.mouseExited, at: NSPoint(x: -20, y: b.y), inbox: inbox, window: window)
                try frames("exit")
                inbox.openAgentId = uuid(busyLead + 3)
                SidebarParityCapture.pump()
                RunLoop.main.run(until: Date().addingTimeInterval(0.2))
                let open = try windowPoint(inbox, id: uuid(busyLead + 3))
                try crossing(.mouseEntered, at: open, inbox: inbox, window: window)
                try move(to: open, in: window)
                try frames("hover open row")
                let url = directory.appendingPathComponent("film-\(label(style).lowercased())-\(dark ? "dark" : "light").png")
                try sheet(tiles, columns: 8, title: "Helper hover film — \(label(style)), \(dark ? "dark" : "light")",
                          dark: dark, to: url)
                written.append(url.path)
            }
        }
        return written
    }

    // MARK: Witness

    static func run() throws -> String {
        var lines: [String] = []
        for style in styles {
            for dark in [false, true] {
                lines.append(try witness(style: style, dark: dark))
            }
        }
        return lines.joined(separator: "\n")
            + "\nentered/exited: \(crossingsHandedToOwner) handed to the tracking area's owner after NSApp.sendEvent dropped them; moves all through NSApp.sendEvent"
            + "\nSidebarHelperHoverChecks passed"
    }

    private static func witness(style: String, dark: Bool) throws -> String {
        let tag = "\(label(style)) \(dark ? "dark" : "light")"
        func fail(_ message: String) -> Failure { Failure(description: "\(tag): \(message)") }
        let fixture = try fixture(style: style, dark: dark)
        defer { fixture.close() }
        let inbox = fixture.inbox, window = fixture.window
        // The rows on screen: the sweep group's fan-out hides two behind "N more".
        let ids = rows().map(\.id).filter { inbox.cellForQA(id: $0) != nil }
        let helpers = rows().filter { $0.parentId != nil && ids.contains($0.id) }.map(\.id)
        guard helpers.count == 15, let more = inbox.ownershipRemaindersForQA.first(where: { $0.qaParentID == uuid(sweepLead) })
        else { throw fail("the fixture did not show 15 helpers and an N more line") }
        let moreFill = more.qaFillColor
        let lead = uuid(busyLead), a = uuid(busyLead + 1), b = uuid(busyLead + 2)
        let idle = uuid(idleLead + 2), open = uuid(idleLead + 1)

        // A real selection and an open agent, through the click path.
        try SidebarParityCapture.click(inbox, window: window, id: open)
        guard inbox.openAgentId == open else { throw fail("the click did not open the helper") }
        try crossing(.mouseExited, at: NSPoint(x: -20, y: 20), inbox: inbox, window: window)
        SidebarParityCapture.pump()
        guard inbox.hoveredAgentIdForQA == nil else { throw fail("hover survived the exit after the click") }

        func cell(_ id: UUID) throws -> AgentInbox96CellView {
            guard let cell = inbox.cellForQA(id: id) else { throw fail("no cell for \(id)") }
            return cell
        }
        func truth() throws -> [String] {
            try ids.map { "\($0): \(try cell($0).qaStyleTruth)" } + ["selection: \(inbox.selectedRowIdsForQA)"]
        }
        let restTruth = try truth()
        let restFills = try Dictionary(uniqueKeysWithValues: ids.map { ($0, try cell($0).qaCardFill) })
        let restRoles = try Dictionary(uniqueKeysWithValues: ids.map { ($0, try cell($0).qaCardSurfaceRole) })
        guard try cell(open).qaCardSurfaceRole == .active else { throw fail("the open helper is not on the active step") }

        /// The pill is on `id` alone (nil: on no row), the hovered card paints
        /// the fill it had at rest, and every other card's fill is untouched.
        func expectPill(on id: UUID?, _ step: String) throws {
            guard inbox.hoveredAgentIdForQA == id else {
                throw fail("\(step): hover is on \(String(describing: inbox.hoveredAgentIdForQA)), expected \(String(describing: id))")
            }
            for other in helpers {
                let row = try cell(other)
                let lit = row.qaHoverMarkOpacity > 0.5
                let expected = other == id && other != open
                guard lit == expected else {
                    throw fail("\(step): pill \(lit ? "shows" : "missing") on \(row.qaTitle)")
                }
                guard row.qaHoverMarkFrame != nil else { throw fail("\(step): \(row.qaTitle) has no pill to show") }
                guard row.qaCardFill == restFills[other] ?? nil, row.qaCardSurfaceRole == restRoles[other] else {
                    throw fail("\(step): \(row.qaTitle) changed its fill on hover")
                }
            }
        }

        let builds = inbox.cellBuildCountForQA
        let start = try windowPoint(inbox, id: a)
        try crossing(.mouseEntered, at: start, inbox: inbox, window: window)
        try move(to: start, in: window)
        SidebarParityCapture.pump()
        try expectPill(on: a, "enter A")
        guard let pill = try cell(a).qaHoverMarkFrame, abs(pill.height - InboxOwnershipChrome.subagentHeight) < 0.5
        else { throw fail("the pill is not the helper row's own height") }

        // Moves inside one row: no rebuild and no layout, anywhere.
        let layouts = AgentInbox96CellView.qaLayoutPassCount
        for step in 1...12 {
            try move(to: try windowPoint(inbox, id: a, x: 0.3 + CGFloat(step) * 0.04), in: window)
        }
        SidebarParityCapture.pump()
        guard AgentInbox96CellView.qaLayoutPassCount == layouts else {
            throw fail("\(AgentInbox96CellView.qaLayoutPassCount - layouts) row layouts during 12 moves in one row")
        }
        try expectPill(on: a, "moves within A")

        try move(to: try windowPoint(inbox, id: b), in: window)
        SidebarParityCapture.pump()
        try expectPill(on: b, "A to B")
        try move(to: try windowPoint(inbox, id: idle), in: window)
        SidebarParityCapture.pump()
        try expectPill(on: idle, "B to the idle group")

        // A lead keeps its own full-width hover step and draws no pill.
        try move(to: try windowPoint(inbox, id: lead), in: window)
        SidebarParityCapture.pump()
        try expectPill(on: lead, "onto the lead")
        guard try cell(lead).qaHoverMarkFrame == nil else { throw fail("a lead row carries a pill") }

        // The open helper: hover adds nothing over its active step.
        try move(to: try windowPoint(inbox, id: open), in: window)
        SidebarParityCapture.pump()
        try expectPill(on: open, "onto the open helper")
        guard try cell(open).qaCardSurfaceRole == .active else { throw fail("hover lowered the open helper") }

        // The "N more" line is one more strip of the card: the same pill, alone.
        let words = more.qaLabelFrameInWindow
        try move(to: NSPoint(x: words.midX, y: words.midY), in: window)
        SidebarParityCapture.pump()
        try expectPill(on: nil, "onto N more")
        guard more.qaHoverMarkOpacity > 0.5, more.qaFillColor == moreFill,
              let morePill = more.qaHoverMarkFrame,
              morePill.contains(more.convert(NSPoint(x: words.midX, y: words.midY), from: nil))
        else { throw fail("the N more line did not draw its pill around its words") }

        try crossing(.mouseExited, at: NSPoint(x: -20, y: start.y), inbox: inbox, window: window)
        SidebarParityCapture.pump()
        try expectPill(on: nil, "exit")
        guard more.qaHoverMarkOpacity == 0 else { throw fail("the N more pill survived the exit") }
        guard inbox.cellBuildCountForQA == builds else {
            throw fail("\(inbox.cellBuildCountForQA - builds) row rebuilds while hovering")
        }
        let after = try truth()
        guard after == restTruth else {
            let changed = zip(restTruth, after).filter { $0 != $1 }.map { "\($0.0) → \($0.1)" }
            throw fail("hover moved the selection or style truth:\n" + changed.joined(separator: "\n"))
        }
        return "SidebarHelperHover \(tag): pill on exactly the hovered helper, cleared on exit; "
            + "0 rebuilds, 0 layouts per in-row move; truth table unchanged over \(ids.count) rows"
    }

    static func runCapture(outputDirectory: URL) throws -> String {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let written = try captureSheets(into: outputDirectory) + captureFilm(into: outputDirectory)
        return "SidebarHelperHover: wrote\n" + written.joined(separator: "\n")
    }
}
