import AppKit
import ContinuumRevivedAgentUI
import Foundation

/// Part of `--inbox-parent-fold-check`: the fold BUTTON on a parent card.
///
/// Dylan wanted the card to stay "go to agent" and the fold to be a clear
/// button. Read off the SHIPPED list, for each of the three temporary glyph
/// variants: the control spans the card's height across the lane and count at a
/// width fixed by the count's digits; a mouse DOWN folds (the rows change before
/// the button is released) and paints the pressed step; only the control has a
/// pointing hand; hover paints its own step and moves the glyph; ←/→ fold the
/// selected parent and keep it selected; the glyph holds its pose under the fold
/// photographs and morphs after they retire; working children twinkle one dot at
/// a time on the 2 s rhythm and not while the window is not key; and the seeded
/// constellation is stable per parent and differs between parents. It also
/// renders the contact sheet of every variant x state x appearance x scale.
@MainActor
enum SidebarSwarmGlyphChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String) throws {
        if !condition() { throw Failure(description: message()) }
    }

    static let epoch = Date(timeIntervalSinceReferenceDate: 812_500_000)
    static func id(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "5A000000-0000-4000-8000-%012X", value))!
    }
    static let parent = id(1), bigParent = id(2)
    static let children = [id(11), id(12), id(13)]

    static func rows() -> [AgentInboxRow] {
        func row(_ id: UUID, _ title: String, state: InboxState = .ready, parent: UUID? = nil, age: Double) -> AgentInboxRow {
            AgentInboxRow(id: id, title: title, projectName: "roast-web", state: state,
                          lastActiveAt: epoch.addingTimeInterval(-age), depth: parent == nil ? 0 : 1,
                          createdAt: epoch.addingTimeInterval(-age), parentId: parent)
        }
        return [row(parent, "orchestrating the sweep", age: 100)]
            + children.enumerated().map { row($1, "worker \($0)", state: $0 == 0 ? .working : .ready, parent: parent, age: Double(90 - $0)) }
            + [row(bigParent, "a wide fan-out", age: 300)]
            + (0..<12).map { row(id(100 + $0), "fan \($0)", parent: bigParent, age: Double(290 - $0)) }
    }

    static func run() async throws -> String {
        var lines: [String] = []
        let original = SwarmGlyphVariant.current
        defer { SwarmGlyphVariant.current = original }
        for variant in SwarmGlyphVariant.allCases {
            SwarmGlyphVariant.current = variant
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                lines.append(try await checkControl(variant: variant, appearance: appearance))
            }
        }
        lines.append(try checkSeededConstellation())
        lines.append("contact sheet: " + (try writeContactSheet()))
        return lines.map { "  " + $0 }.joined(separator: "\n")
    }

    // MARK: - The control in the shipped list

    private static func control(_ inbox: AgentInboxView, _ id: UUID) -> (AgentInbox96CellView, InboxSwarmFoldControl)? {
        for case let cell as AgentInbox96CellView in inbox.qaMaterializedRowCells where cell.qaAgentID == id {
            if let control = cell.qaFoldControlForQA { return (cell, control) }
        }
        return nil
    }

    static func checkControl(variant: SwarmGlyphVariant, appearance: NSAppearance.Name) async throws -> String {
        let label = "\(variant.rawValue)/\(appearance.rawValue)"
        let inbox = AgentInboxView(frame: NSRect(x: 0, y: 0, width: 320, height: 1_000))
        inbox.clock = { epoch }
        inbox.foldsUntouchedGroups = true
        inbox.prefersReducedMotion = { false }
        var revealed: [UUID] = []
        inbox.onRevealRow = { revealed.append($0) }
        let window = NSWindow(contentRect: inbox.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = inbox
        window.orderFrontOffscreenForChecks()
        defer { window.orderOut(nil) }
        inbox.reload(rows: rows())
        inbox.layoutForQA()

        guard let (cell, fold) = control(inbox, parent), let (_, wide) = control(inbox, bigParent) else {
            throw Failure(description: "\(label): a folded parent drew no fold control")
        }
        // Geometry: the full card height, across the lane and the count, at a
        // width the digits fix.
        let card = cell.qaCardFrameForQA
        let frame = fold.convert(fold.bounds, to: cell)
        try expect(abs(frame.height - card.height) < 0.5 && abs(frame.minY - card.minY) < 0.5,
                   "\(label): the fold target \(frame) must span the card's height \(card)")
        try expect(abs(frame.width - InboxSwarmFoldControl.width(childCount: 3)) < 0.01
                   && abs(wide.bounds.width - InboxSwarmFoldControl.width(childCount: 12)) < 0.01
                   && wide.bounds.width > fold.bounds.width && fold.bounds.width >= 22,
                   "\(label): widths \(fold.bounds.width)/\(wide.bounds.width) are not the digit-fixed widths")
        try expect(cell.qaTitleFrameForQA.minX >= frame.maxX + 3.5,
                   "\(label): the title \(cell.qaTitleFrameForQA) crowds the fold control \(frame)")
        try expect(fold.countTextForQA == "3" && wide.countTextForQA == "12",
                   "\(label): counts read '\(fold.countTextForQA)'/'\(wide.countTextForQA)'")

        // Accessibility.
        try expect(fold.accessibilityRole() == .button && fold.accessibilityLabel() == "Expand 3 subagents"
                   && fold.isAccessibilityExpanded() == false,
                   "\(label): folded control reads \(String(describing: fold.accessibilityRole())) '\(fold.accessibilityLabel() ?? "")'")

        // Cursors: the control has the hand over its whole bounds; the card body
        // registers none and is not the control.
        fold.resetCursorRects()
        try expect(fold.registeredCursorsForQA.contains { $0.cursor == .pointingHand && $0.rect == fold.bounds },
                   "\(label): the fold control registers no pointing hand over its bounds")
        try expect(!inbox.rowCursorsForQA().contains(.pointingHand), "\(label): the list registered a pointing hand")
        let title = cell.qaTitleFrameForQA
        let body = cell.hitTest(cell.convert(NSPoint(x: title.midX, y: title.midY), to: cell.superview))
        try expect(body.map { $0 !== fold && !$0.isDescendant(of: fold) } ?? true,
                   "\(label): a click on the title lands on the fold control")

        // Resting paints no chip; hover paints the hover step and spreads.
        let theme: TokenTheme = appearance == .darkAqua ? .dark : .light
        try expect(fold.chipFillForQA == nil, "\(label): a resting fold control paints a chip")
        let rest = fold.modelDotOffsetsForQA
        fold.mouseEntered(with: try mouseEvent(.mouseMoved, fold, window))
        let hoverExpected = SwarmPose.pose(variant, seed: parent, children: 3, expanded: false, hovered: true)
        try expect(fold.chipFillForQA.map { hex($0) } == hex(SidebarControlRole.hover.color.cgColor(for: theme)),
                   "\(label): hover painted \(String(describing: fold.chipFillForQA))")
        // Triad and seeded spread their dots; the chart draws its strokes in.
        try expect(close(fold.modelDotOffsetsForQA, hoverExpected.dots)
                   && (variant == .chart ? fold.strokeEndForQA == 1 : fold.modelDotOffsetsForQA != rest),
                   "\(label): hover did not move the glyph — rest \(rest), hover \(fold.modelDotOffsetsForQA)")
        fold.mouseExited(with: try mouseEvent(.mouseMoved, fold, window))
        try expect(fold.chipFillForQA == nil && close(fold.modelDotOffsetsForQA, rest),
                   "\(label): leaving did not restore the resting glyph")

        // Mouse DOWN folds: the rows change before the release, nothing reveals.
        let hidden = children.filter { !inbox.rowIdsForQA.contains($0) }
        try expect(hidden.count == 3, "\(label): the group did not start folded")
        window.sendEvent(try mouseEvent(.leftMouseDown, fold, window))
        try expect(children.allSatisfy(inbox.rowIdsForQA.contains),
                   "\(label): a mouse DOWN on the fold control did not unfold the group")
        try expect(revealed.isEmpty, "\(label): folding also revealed an agent: \(revealed)")
        // The reload can bind the parent to another cell: read whichever holds it.
        guard let (_, held) = control(inbox, parent) else { throw Failure(description: "\(label): the parent lost its control") }
        try expect(held.isPressed && held.chipFillForQA.map { hex($0) } == hex(SidebarControlRole.pressed.color.cgColor(for: theme)),
                   "\(label): the press painted \(String(describing: held.chipFillForQA)), not the pressed step")
        // The pointer has not moved: it is over the control now holding the parent.
        // Through the application's event queue, the way a real release arrives:
        // the window drops it, because the view that took the press was
        // detached by the reload the press caused.
        NSApp.postEvent(try mouseEvent(.leftMouseUp, held, window), atStart: true)
        if let release = NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) {
            NSApp.sendEvent(release)
        }
        try expect(!held.isPressed && !fold.isPressed && held.chipFillForQA == nil,
                   "\(label): the pressed step outlived the release")

        // The glyph holds its pose under the fold photographs, then morphs.
        guard let (_, open) = control(inbox, parent) else { throw Failure(description: "\(label): the unfolded parent lost its control") }
        let motion = inbox.foldMotionForQA
        let systemReduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if motion.isAnimating, !systemReduce {
            try expect(!open.shownExpanded && close(open.modelDotOffsetsForQA, SwarmPose.pose(variant, seed: parent, children: 3, expanded: false, hovered: false).dots),
                       "\(label): the glyph changed pose under the fold photographs")
            motion.advance(by: 1)
            try await Task.sleep(nanoseconds: UInt64((InboxFoldMotion.expandDuration + 0.25) * 1e9))
        }
        let expandedPose = SwarmPose.pose(variant, seed: parent, children: 3, expanded: true, hovered: false)
        try expect(open.shownExpanded && close(open.modelDotOffsetsForQA, expandedPose.dots)
                   && Set(expandedPose.dots.map(\.x)) == [0],
                   "\(label): after the fold the glyph is not the lane line — \(open.modelDotOffsetsForQA)")
        try expect(open.accessibilityLabel() == "Collapse 3 subagents" && open.isAccessibilityExpanded() == true,
                   "\(label): unfolded control reads '\(open.accessibilityLabel() ?? "")'")

        // ← folds the selected parent, → unfolds it; the selection stays.
        let left = try key(123), right = try key(124)
        try expect(inbox.selectRowForQA(id: parent), "\(label): could not select the parent")
        try expect(inbox.handleTableActivationKey(left), "\(label): ← was not handled on an open parent")
        try expect(children.allSatisfy { !inbox.rowIdsForQA.contains($0) }, "\(label): ← did not fold")
        try expect(inbox.selectedRowIdsForQA == [parent], "\(label): ← lost the selection: \(inbox.selectedRowIdsForQA)")
        try expect(!inbox.handleTableActivationKey(left), "\(label): ← on a folded parent must fall through")
        try expect(inbox.handleTableActivationKey(right) && children.allSatisfy(inbox.rowIdsForQA.contains),
                   "\(label): → did not unfold")
        motion.advance(by: 1)

        // Working children: never twinkles in a window that is not key; the
        // twinkle itself is one dot at a time on the 2 s rhythm, floor 40%.
        guard let (_, working) = control(inbox, parent) else { throw Failure(description: "\(label): lost the control") }
        try expect(working.workingChildren == 1 && !window.isKeyWindow && !working.isTwinkling,
                   "\(label): twinkling in a window that is not key")
        working.setTwinkling(true)
        try expect(working.twinklePeriodForQA == 2.0, "\(label): twinkle period \(String(describing: working.twinklePeriodForQA))")
        working.setTwinkling(false)
        return "\(label): \(Int(fold.bounds.width))/\(Int(wide.bounds.width))pt wide for 1/2 digits, \(Int(frame.height))pt tall; mouse-down folded with the pressed step; hover step + glyph spread; hand on the control only; ←/→ fold with selection kept; pose held under the photographs then morphed to the lane line"
    }

    static func checkSeededConstellation() throws -> String {
        let a = SwarmPose.pose(.seeded, seed: parent, children: 5, expanded: false, hovered: false)
        let again = SwarmPose.pose(.seeded, seed: parent, children: 5, expanded: false, hovered: false)
        let b = SwarmPose.pose(.seeded, seed: bigParent, children: 5, expanded: false, hovered: false)
        try expect(a == again, "seeded: one parent's constellation changed between calls")
        try expect(a != b, "seeded: two parents drew the same constellation")
        try expect(a.dots.count == 5 && SwarmPose.pose(.seeded, seed: parent, children: 9, expanded: false, hovered: false).dots.count == 5,
                   "seeded: draws min(count, 5) dots")
        let half = SwarmPose.side / 2 - SwarmPose.dotDiameter(.seeded) / 2
        try expect(a.dots.allSatisfy { abs($0.x) <= half && abs($0.y) <= half },
                   "seeded: a dot leaves the glyph's square: \(a.dots)")
        return "seeded: stable per parent, distinct between parents, min(count,5) dots inside the square"
    }

    // MARK: - Contact sheet

    static func writeContactSheet() throws -> String {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("qa-runs/sidebar-swarm-glyph", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let states: [(String, RowDisclosure, Bool, Int)] = [
            ("rest", .collapsed, false, 0), ("hover", .collapsed, true, 0),
            ("expanded", .expanded, false, 0), ("working", .collapsed, false, 1),
        ]
        let scales: [CGFloat] = [1, 2]
        let appearances: [NSAppearance.Name] = [.aqua, .darkAqua]
        let tileSize = NSSize(width: InboxSwarmFoldControl.width(childCount: 3) + 6, height: 28)
        let magnify: CGFloat = 6
        let cellW = tileSize.width * magnify, cellH = tileSize.height * magnify
        let left: CGFloat = 150, top: CGFloat = 60, gap: CGFloat = 12
        let columns = states.count * scales.count
        let rowsCount = SwarmGlyphVariant.allCases.count * appearances.count
        let size = NSSize(width: left + CGFloat(columns) * (cellW + gap),
                          height: top + CGFloat(rowsCount) * (cellH + gap))
        guard let sheet = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: sheet) else {
            throw Failure(description: "contact sheet: no bitmap")
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor(white: 0.5, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        let text: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15, weight: .medium),
                                                   .foregroundColor: NSColor.white]
        for (column, (state, scale)) in states.flatMap({ s in scales.map { (s, $0) } }).enumerated() {
            let x = left + CGFloat(column) * (cellW + gap)
            ("\(state.0) @\(Int(scale))x" as NSString).draw(at: NSPoint(x: x, y: size.height - top + 20), withAttributes: text)
        }
        var row = 0
        for variant in SwarmGlyphVariant.allCases {
            for appearance in appearances {
                let y = size.height - top - CGFloat(row + 1) * (cellH + gap) + gap
                ("\(variant.rawValue)\n\(appearance == .aqua ? "light" : "dark")" as NSString)
                    .draw(at: NSPoint(x: 12, y: y + cellH / 2 - 20), withAttributes: text)
                let theme: TokenTheme = appearance == .darkAqua ? .dark : .light
                for (column, (state, scale)) in states.flatMap({ s in scales.map { (s, $0) } }).enumerated() {
                    let x = left + CGFloat(column) * (cellW + gap)
                    let control = InboxSwarmFoldControl(frame: NSRect(origin: .zero, size: tileSize))
                    control.appearance = NSAppearance(named: appearance)
                    control.glyphCentreY = tileSize.height / 2
                    control.configureForStill(variant: variant, disclosure: state.1, childCount: 3,
                                              workingChildren: state.3, seed: parent, hovered: state.2, scale: scale)
                    guard let rep = control.bitmapImageRepForCachingDisplay(in: control.bounds) else { continue }
                    rep.pixelsWide = Int(tileSize.width * scale)
                    rep.pixelsHigh = Int(tileSize.height * scale)
                    control.cacheDisplay(in: control.bounds, to: rep)
                    let tile = NSRect(x: x, y: y, width: cellW, height: cellH)
                    NSColor(cgColor: SidebarSurfaceRole.rowBase.color.cgColor(for: theme))?.setFill()
                    tile.fill()
                    context.imageInterpolation = .none
                    rep.draw(in: tile, from: .zero, operation: .sourceOver, fraction: 1,
                             respectFlipped: false, hints: [.interpolation: NSNumber(value: NSImageInterpolation.none.rawValue)])
                }
                row += 1
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let png = sheet.representation(using: .png, properties: [:]) else {
            throw Failure(description: "contact sheet: no PNG")
        }
        let url = directory.appendingPathComponent("contact-sheet.png")
        try png.write(to: url)
        return url.path
    }

    // MARK: - Helpers

    private static func close(_ a: [CGPoint], _ b: [CGPoint]) -> Bool {
        // Within the half pixel the backing-grid snap may move a dot.
        a.count == b.count && zip(a, b).allSatisfy { abs($0.x - $1.x) <= 0.5 && abs($0.y - $1.y) <= 0.5 }
    }

    private static func hex(_ color: CGColor) -> String {
        guard let rgb = color.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil),
              let parts = rgb.components, parts.count >= 3 else { return "?" }
        return parts.map { String(format: "%02X", Int(($0 * 255).rounded())) }.joined()
    }

    private static func mouseEvent(_ type: NSEvent.EventType, _ view: NSView, _ window: NSWindow) throws -> NSEvent {
        let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        guard let event = NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        else { throw Failure(description: "could not synthesise \(type)") }
        return event
    }

    private static func key(_ code: UInt16) throws -> NSEvent {
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: code)
        else { throw Failure(description: "could not synthesise key \(code)") }
        return event
    }
}
