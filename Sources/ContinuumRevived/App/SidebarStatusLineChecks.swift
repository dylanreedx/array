import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Foundation

// Plan: .plans/102-managed-agent-mode (P2b, the sidebar status line)
/// `--sidebar-agent-status-line-check`: the line under an agent's name in the
/// SHIPPED sidebar, from real records on a real supervisor.
///
/// The world is `SidebarTruthChecks.makeWorld()`: the scene mounted through
/// `mountWorkspaceSceneAtBoot`, the sidebar installed as boot installs it, and a
/// supervisor whose runners start a real turn and hold it. Statuses and reports
/// go through the contract's own validation and the supervisor's `declareStatus`
/// / `fileReport` — what `array_status` / `array_report` call — and NOTHING in
/// the check refreshes the sidebar after them: the row must change because the
/// supervisor told the host to push it.
///
/// Asserts: a working agent's declared `now` in the secondary ink; its
/// `needsYou` as "Needs you: …" painted in the asking amber, in light and dark;
/// once the turn ends the declared status is gone; a report with a failed check
/// reads "Done · 1 of 4 checks failed" with the failure painted red, an all-pass
/// one "Done · all 3 checks passed"; a new turn hides the last turn's report and
/// status; an over-long ask stays one truncated line; and the card height never
/// moves, equal to a row that never said anything.
///
/// `--render-dir <dir>` also writes the four states, light and dark, as
/// `sidebar-line-built-light.png` / `-dark.png`.
@MainActor
enum SidebarStatusLineChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
    }

    static let agent = SidebarTruthChecks.busyAgent
    static let quietAgent = SidebarTruthChecks.secondIdleAgent

    static func run(renderDirectory: URL?) async throws {
        let world = try SidebarTruthChecks.makeWorld()
        defer { SidebarTruthChecks.tearDown(world) }
        world.window.appearance = NSAppearance(named: .aqua)
        world.window.orderFrontOffscreenForChecks()
        defer { world.window.orderOut(nil) }
        let inbox = world.inbox
        let supervisor = world.supervisor
        var shots: [(state: String, light: NSBitmapImageRep, dark: NSBitmapImageRep)] = []

        func card(_ id: AgentID) throws -> AgentInbox96CellView {
            inbox.layoutForQA()
            guard let cell = inbox.onScreenCardForQA(id: id.rawValue) else {
                throw Failure(description: "the sidebar shows no card for \(id.rawValue)")
            }
            cell.layoutSubtreeIfNeeded()
            return cell
        }
        func line(_ id: AgentID) -> String? {
            inbox.layoutForQA()
            return inbox.onScreenCardForQA(id: id.rawValue)?.selfReportTextForQA?.string
        }
        /// Waits for the supervisor's own push to redraw the row — no refresh here.
        func waitForLine(_ expected: String?, _ what: String) async throws {
            let drawn = await waitUntil(timeout: 5, pollInterval: 0.02) { line(agent) == expected }
            try expect(drawn, "\(what): the row must read \(expected.map { "\"\($0)\"" } ?? "nothing extra") by itself — it reads \(line(agent).map { "\"\($0)\"" } ?? "nothing extra")")
        }
        func colour(of text: NSAttributedString, at substring: String) -> NSColor? {
            let range = (text.string as NSString).range(of: substring)
            guard range.location != NSNotFound else { return nil }
            return text.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor
        }
        func same(_ a: NSColor?, _ b: NSColor) -> Bool {
            guard let a = a?.usingColorSpace(.sRGB), let b = b.usingColorSpace(.sRGB) else { return false }
            return abs(a.redComponent - b.redComponent) < 0.01 && abs(a.greenComponent - b.greenComponent) < 0.01
                && abs(a.blueComponent - b.blueComponent) < 0.01
        }
        /// Pixels of the row's line band, as the window draws them, in `ink`'s hue.
        func paints(_ ink: NSColor, in cell: AgentInbox96CellView) -> Bool {
            guard let frame = cell.selfReportFrameForQA, let ink = ink.usingColorSpace(.sRGB),
                  let rep = cell.bitmapImageRepForCachingDisplay(in: frame) else { return false }
            cell.cacheDisplay(in: frame, to: rep)
            // Glyph edges blend, so match the ink's HUE on saturated pixels: the
            // secondary grey has none, and amber and red are 30 degrees apart.
            func hueDistance(_ a: CGFloat, _ b: CGFloat) -> CGFloat { min(abs(a - b), 1 - abs(a - b)) }
            var hits = 0
            for x in 0..<rep.pixelsWide { for y in 0..<rep.pixelsHigh {
                guard let pixel = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), pixel.alphaComponent > 0.4,
                      pixel.saturationComponent > 0.4 else { continue }
                if hueDistance(pixel.hueComponent, ink.hueComponent) < 0.035 { hits += 1 }
            } }
            return hits >= 8
        }
        func shoot(_ state: String) throws {
            guard renderDirectory != nil else { return }
            var pair: [NSBitmapImageRep] = []
            for name in [NSAppearance.Name.aqua, .darkAqua] {
                world.window.appearance = NSAppearance(named: name)
                let cell = try card(agent)
                let rect = cell.convert(cell.bounds, to: world.sidebar)
                world.sidebar.layoutSubtreeIfNeeded()
                world.sidebar.displayIfNeeded()
                guard let rep = world.sidebar.bitmapImageRepForCachingDisplay(in: rect) else {
                    throw Failure(description: "could not render the \(state) row")
                }
                world.sidebar.cacheDisplay(in: rect, to: rep)
                pair.append(rep)
            }
            world.window.appearance = NSAppearance(named: .aqua)
            shots.append((state, pair[0], pair[1]))
        }

        // The control: a row that never said anything has no line, and its height
        // is the height every card in this list has.
        let quiet = try card(quietAgent)
        let restingHeight = quiet.frame.height
        try expect(quiet.selfReportTextForQA == nil, "an agent that declared nothing must draw no status line")
        try expect(line(agent) == nil, "setup: the agent has said nothing yet")
        try shoot("Nothing said")

        // A working agent declares what it is doing.
        try expect(supervisor.send("build the sign-in screens", to: agent), "setup: the agent must accept a prompt")
        let running = await waitUntil(timeout: 10, pollInterval: 0.02) {
            supervisor.isRunning(agent) && world.runners.byAgent[agent] != nil
        }
        try expect(running, "setup: the agent's turn never started")
        world.app.qaRefreshAgentSurfaces()
        let working = await waitUntil(timeout: 5, pollInterval: 0.02) {
            inbox.drawnRowForQA(id: agent.rawValue)?.state == .working
        }
        try expect(working, "setup: the agent's row must be working — it is \(String(describing: inbox.drawnRowForQA(id: agent.rawValue)?.state)), turn \(String(describing: supervisor.turnSnapshot(for: agent)?.state))")
        func declare(_ payload: [String: Any]) throws {
            guard case let .success(status) = AgentDeclaredStatus.validated(payload: payload, at: Date()) else {
                throw Failure(description: "the contract refused \(payload)")
            }
            try expect(supervisor.declareStatus(status, for: agent), "declareStatus must record \(payload)")
        }
        func file(_ payload: [String: Any]) throws {
            guard case let .success(report) = AgentReport.validated(payload: payload) else {
                throw Failure(description: "the contract refused \(payload)")
            }
            try expect(supervisor.fileReport(report, for: agent), "fileReport must record \(payload)")
        }

        try declare(["now": "Running the iOS build", "next": "Compare screenshots"])
        try await waitForLine("Running the iOS build", "a working agent's declared now")
        var cell = try card(agent)
        try expect(same(colour(of: cell.selfReportTextForQA!, at: "Running"), TextToken.textSecondary.color.nsColor(in: cell)),
                   "the declared now must be in the row's secondary ink")
        try expect(cell.frame.height == restingHeight, "the status line must not change the card's height: \(cell.frame.height) vs \(restingHeight)")
        try expect(cell.accessibilityLabel()?.contains("Running the iOS build") == true,
                   "the line must be read out with the row: \(cell.accessibilityLabel() ?? "")")
        try shoot("Working: now")

        try declare(["now": "Running the iOS build", "needsYou": "Approve the simulator build"])
        try await waitForLine("Needs you: Approve the simulator build", "a declared needsYou")
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            world.window.appearance = NSAppearance(named: name)
            cell = try card(agent)
            let amber = AccentToken.accentApproval.color.nsColor(in: cell)
            try expect(same(colour(of: cell.selfReportTextForQA!, at: "Approve"), amber),
                       "\(name.rawValue): the ask must be in the asking amber")
            try expect(paints(amber, in: cell), "\(name.rawValue): the ask's amber must reach the drawn pixels")
        }
        world.window.appearance = NSAppearance(named: .aqua)
        try expect(cell.frame.height == restingHeight, "a needs-you line must not change the card's height")
        try shoot("Working: needs you")

        // One line, truncated, never wrapped.
        try declare(["now": "x", "needsYou": String(repeating: "Approve the very long simulator build ", count: 3)
            .trimmingCharacters(in: .whitespaces)])
        let longDrawn = await waitUntil(timeout: 5, pollInterval: 0.02) { line(agent)?.hasPrefix("Needs you: Approve the very long") == true }
        try expect(longDrawn, "the long ask must reach the row")
        cell = try card(agent)
        guard let lineFrame = cell.selfReportFrameForQA, let cardFrame = cell.qaGeometry.elementFrames["card"],
              let text = cell.selfReportTextForQA else { throw Failure(description: "the long ask is not drawn") }
        try expect(cardFrame.contains(lineFrame), "the long ask must stay inside the card: \(lineFrame) in \(cardFrame)")
        try expect(text.size().width > lineFrame.width, "fixture: the ask must be longer than the lane")
        try expect(lineFrame.height <= text.size().height * 1.5, "the long ask must be one line, never wrapped: \(lineFrame.height)")
        let paragraph = text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        try expect(paragraph?.lineBreakMode == .byTruncatingTail, "the long ask must truncate with an ellipsis at its end")
        try expect(cell.frame.height == restingHeight, "a long ask must not change the card's height")

        // The turn ends with no report: the declared status is gone.
        guard let runner = world.runners.byAgent[agent] else { throw Failure(description: "setup: no runner") }
        _ = runner.emit(.turnCompleted(threadId: "truth", turnId: "t1", outcome: .completed, errorMessage: nil))
        runner.releaseRunAfterStop()
        let ended = await waitUntil(timeout: 5, pollInterval: 0.02) {
            !supervisor.isRunning(agent) && inbox.drawnRowForQA(id: agent.rawValue)?.state == .ready
        }
        try expect(ended, "setup: the turn must end and the row read ready")
        try expect(supervisor.records[agent]?.declaredStatus != nil, "setup: the record still holds the declared status")
        try await waitForLine(nil, "a finished agent's declared status")

        // A report with a failed check.
        try file(["summary": "Built and compared", "checks": [
            ["what": "swift build", "result": "pass"], ["what": "matrix leg", "result": "fail"],
            ["what": "screenshots", "result": "pass"], ["what": "lint", "result": "pass"],
            ["what": "read the ledger", "result": "info"],
        ]])
        try await waitForLine("Done · 1 of 4 checks failed", "a finished agent's report with a failure")
        cell = try card(agent)
        let red = AccentToken.accentFailed.color.nsColor(in: cell)
        try expect(same(colour(of: cell.selfReportTextForQA!, at: "1 of 4"), red), "the failure count must be in the failure red")
        try expect(same(colour(of: cell.selfReportTextForQA!, at: "Done"), TextToken.textSecondary.color.nsColor(in: cell)),
                   "Done must be in the secondary ink")
        try expect(paints(red, in: cell), "the failure red must reach the drawn pixels")
        try expect(cell.frame.height == restingHeight, "a report line must not change the card's height")
        try shoot("Done: a check failed")

        try file(["summary": "All green", "checks": [
            ["what": "swift build", "result": "pass"], ["what": "matrix leg", "result": "pass"],
            ["what": "screenshots", "result": "pass"],
        ]])
        try await waitForLine("Done · all 3 checks passed", "a finished agent's all-pass report")
        cell = try card(agent)
        try expect(!paints(red, in: cell), "an all-pass line must paint no failure red")
        try shoot("Done: all passed")

        try file(["summary": "Nothing to check"])
        try await waitForLine(nil, "a report with no checks")

        // A new turn: last turn's report and status are history, not news.
        try file(["summary": "All green", "checks": [["what": "swift build", "result": "pass"]]])
        try await waitForLine("Done · 1 check passed", "a one-check report")
        try expect(supervisor.send("now the dark mode", to: agent), "the agent must accept a second prompt")
        let secondTurn = await waitUntil(timeout: 10, pollInterval: 0.02) {
            supervisor.isRunning(agent) && inbox.drawnRowForQA(id: agent.rawValue)?.state == .working
        }
        try expect(secondTurn, "setup: the second turn must start and the row read working")
        try expect(line(agent) == nil, "a new turn must not show the last turn's report or status — it reads \(line(agent) ?? "")")
        try declare(["now": "Checking dark mode"])
        try await waitForLine("Checking dark mode", "the new turn's own status")

        let quietAfter = try card(quietAgent)
        try expect(quietAfter.selfReportTextForQA == nil && quietAfter.frame.height == restingHeight,
                   "the quiet agent's row must be untouched throughout")

        if let renderDirectory {
            try FileManager.default.createDirectory(at: renderDirectory, withIntermediateDirectories: true)
            for (index, name) in ["light", "dark"].enumerated() {
                let sheet = try Self.sheet(shots.map { ($0.state, index == 0 ? $0.light : $0.dark) },
                                           dark: index == 1)
                let url = renderDirectory.appendingPathComponent("sidebar-line-built-\(name).png")
                guard let data = sheet.representation(using: .png, properties: [:]) else {
                    throw Failure(description: "could not encode \(url.lastPathComponent)")
                }
                try data.write(to: url)
                print("wrote \(url.path)")
            }
        }
    }

    /// The states stacked, each under a small caption, on the sidebar's own
    /// panel colour for that appearance.
    static func sheet(_ cells: [(String, NSBitmapImageRep)], dark: Bool) throws -> NSBitmapImageRep {
        let scale: CGFloat = 2, caption: CGFloat = 22, pad: CGFloat = 12
        let width = (cells.map { $0.1.size.width }.max() ?? 0) + pad * 2
        let height = cells.reduce(pad) { $0 + caption + $1.1.size.height + pad }
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            throw Failure(description: "could not allocate the sheet")
        }
        rep.size = NSSize(width: width, height: height)
        let theme: TokenTheme = dark ? .dark : .light
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        SurfaceToken.panel.color.nsColor(for: theme).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        var top = height - pad
        for (title, image) in cells {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.token(.caption),
                .foregroundColor: TextToken.textSecondary.color.nsColor(for: theme),
            ]
            (title as NSString).draw(at: NSPoint(x: pad, y: top - caption + 6), withAttributes: attributes)
            top -= caption
            image.draw(in: NSRect(x: pad, y: top - image.size.height, width: image.size.width, height: image.size.height))
            top -= image.size.height + pad
        }
        return rep
    }
}
