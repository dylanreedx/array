import AppKit
import ContinuumRevivedCore
import ContinuumRevivedAgentUI

/// Selection-parity A/B capture. The same source compiles against 0.7.47 and
/// later builds, so it reaches only APIs both have; settings that 0.7.47 does
/// not know are written by key and ignored there. It drives production seams:
/// clicks and arrow keys arrive through `NSApp.sendEvent`, quick jump through
/// `AgentInboxView.jump(keyCode:modifiers:)` (what `handleInboxJump` calls),
/// canvas focus as `openAgentId` (what `setInboxOpenAgent` writes), and a
/// reveal sets `openAgentId` the way the host does after focusing the tile.
///
/// `--sidebar-parity-capture-check <outDir>` writes one PNG per step, style and
/// appearance into `outDir`.
@MainActor
enum SidebarParityCapture {
    struct Failure: Error, CustomStringConvertible { let description: String }

    final class KeyWindow: NSWindow {
        var keyed = true
        override var canBecomeKey: Bool { true }
        override var isKeyWindow: Bool { keyed }
        override var isMainWindow: Bool { keyed }
    }

    /// Stands in for the canvas: a click here takes first responder away from the
    /// sidebar, as clicking a tile does.
    final class CanvasStandIn: NSView {
        override var acceptsFirstResponder: Bool { true }
        override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }
    }

    static let now = Date(timeIntervalSince1970: 1_900_600_000)
    static func uuid(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012X", n))!
    }
    static let lead = 0x100
    static let other = 0x200
    static let single = 0x300
    static let arrival = 0x1F0

    static func rows(withArrival: Bool) -> [AgentInboxRow] {
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        var out: [AgentInboxRow] = []
        func add(_ n: Int, _ title: String, state: InboxState, parent: Int? = nil, colour: String? = nil,
                 minutes: Double, elapsed: TimeInterval? = nil) {
            let finished = state == .ready
            out.append(AgentInboxRow(
                id: uuid(n), title: title, projectName: "array-scratch", projectId: uuid(0x800),
                workspaceName: "personal", workspaceId: uuid(0x701), state: state, lifecycle: .active,
                model: "claude-opus-5-5", branch: nil,
                elapsed: elapsed, elapsedStartedAt: elapsed.map { now.addingTimeInterval(-$0) },
                lastActiveAt: ago(minutes), depth: 0, createdAt: ago(minutes + 5 + Double(n % 7)),
                parentId: parent.map(uuid), harness: "Claude Code",
                terminalEvent: finished
                    ? AgentTerminalEvent(sequence: 1, turnID: nil, outcome: .succeeded, endedAt: ago(minutes)) : nil,
                terminalIsUnread: false, identityColor: colour, selfReport: nil,
                hasTile: parent == nil, isPinned: false))
        }
        add(lead, "Weekend sports news roundup", state: .working, colour: "red", minutes: 0, elapsed: 4)
        add(lead + 1, "UFC events Dec 16-31 2026", state: .working, parent: lead, minutes: 0.2, elapsed: 14)
        add(lead + 2, "UFC events Dec 1-15 2026", state: .working, parent: lead, minutes: 0.3, elapsed: 18)
        for i in 0..<9 {
            add(lead + 3 + i, "Finished helper \(i + 1)", state: .ready, parent: lead, minutes: 2 + Double(i))
        }
        if withArrival {
            add(arrival, "UFC events Nov 2026", state: .working, parent: lead, minutes: 0.1, elapsed: 2)
        }
        add(other, "Draft the release notes", state: .ready, colour: "blue", minutes: 6)
        add(single, "Fix the flaky build", state: .working, colour: "mint", minutes: 1, elapsed: 40)
        return out
    }

    static func pump() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.06))
        CATransaction.flush()
    }

    static func capture(_ inbox: AgentInboxView, to url: URL) throws {
        inbox.layoutForQA()
        inbox.layoutSubtreeIfNeeded()
        pump()
        let crop = NSRect(x: 0, y: max(0, inbox.bounds.height - 420), width: inbox.bounds.width, height: min(420, inbox.bounds.height))
        guard let rep = inbox.bitmapImageRepForCachingDisplay(in: crop) else {
            throw Failure(description: "no bitmap for \(url.lastPathComponent)")
        }
        inbox.cacheDisplay(in: crop, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw Failure(description: "no PNG for \(url.lastPathComponent)")
        }
        try png.write(to: url)
    }

    static func mouse(_ type: NSEvent.EventType, at point: NSPoint, window: NSWindow) throws -> NSEvent {
        guard let event = NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
            pressure: type == .leftMouseUp ? 0 : 1) else { throw Failure(description: "no \(type) event") }
        return event
    }

    /// A press through the application, mouse-up queued first so tracking ends.
    static func click(at point: NSPoint, window: NSWindow) throws {
        NSApp.postEvent(try mouse(.leftMouseUp, at: point, window: window), atStart: false)
        NSApp.sendEvent(try mouse(.leftMouseDown, at: point, window: window))
        pump()
    }

    static func click(_ inbox: AgentInboxView, window: NSWindow, id: UUID) throws {
        guard let cell = inbox.cellForQA(id: id) else { throw Failure(description: "no row to click") }
        let y = cell.isFlipped ? 9 : cell.bounds.height - 9
        try click(at: cell.convert(NSPoint(x: cell.bounds.width * 0.55, y: y), to: nil), window: window)
    }

    static func key(_ code: UInt16, _ character: Int, window: NSWindow) throws {
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            characters: String(UnicodeScalar(character)!), charactersIgnoringModifiers: String(UnicodeScalar(character)!),
            isARepeat: false, keyCode: code) else { throw Failure(description: "no key event") }
        NSApp.sendEvent(event)
        pump()
    }

    static func hover(_ inbox: AgentInboxView, window: NSWindow, id: UUID) throws {
        guard let cell = inbox.cellForQA(id: id) else { throw Failure(description: "no row to hover") }
        let y = cell.isFlipped ? 9 : cell.bounds.height - 9
        let point = cell.convert(NSPoint(x: cell.bounds.width * 0.55, y: y), to: nil)
        guard let move = NSEvent.mouseEvent(
            with: .mouseMoved, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) else {
            throw Failure(description: "no mouse-moved event")
        }
        inbox.mouseMoved(with: move)
        pump()
    }

    static func setKey(_ keyed: Bool, window: KeyWindow) {
        window.keyed = keyed
        let names: [Notification.Name] = keyed
            ? [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification]
            : [NSWindow.didResignKeyNotification, NSWindow.didResignMainNotification]
        for name in names { NotificationCenter.default.post(name: name, object: window) }
        func mark(_ view: NSView) { view.needsDisplay = true; view.subviews.forEach(mark) }
        if let content = window.contentView { mark(content) }
        pump()
    }

    static func table(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for child in view.subviews { if let table = table(in: child) { return table } }
        return nil
    }

    static func run(outputDirectory: URL) throws -> String {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        var written = 0
        for style in ["duplex", "current"] {
            for dark in [true, false] {
                let suite = "array.sidebar.parity-capture.\(UUID().uuidString)"
                guard let defaults = UserDefaults(suiteName: suite) else { throw Failure(description: "no suite") }
                defer { defaults.removePersistentDomain(forName: suite) }
                defaults.set(style, forKey: SidebarActiveIndicatorStyle.defaultsKey)
                let inbox = AgentInboxView(frame: NSRect(x: 0, y: 0, width: 300, height: 520), indicatorDefaults: defaults)
                inbox.clock = { now }
                inbox.prefersReducedMotion = { false }
                inbox.hoverCardEnabled = false
                inbox.foldsUntouchedGroups = false
                inbox.onRevealRow = { [weak inbox] id in inbox?.openAgentId = id }
                let container = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 520))
                let canvas = CanvasStandIn(frame: NSRect(x: 300, y: 0, width: 300, height: 520))
                container.addSubview(inbox)
                container.addSubview(canvas)
                let window = KeyWindow(contentRect: container.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentView = container
                window.orderFrontOffscreenForChecks()
                window.makeKey()
                defer { window.orderOut(nil); window.contentView = nil }
                inbox.pinScrollerStyleForQA()
                inbox.currentWorkspaceId = uuid(0x701)
                inbox.currentWorkspaceName = "personal"
                inbox.setScope(.all)
                inbox.restoreParentFolds([uuid(lead): false])
                inbox.reload(rows: rows(withArrival: false))
                inbox.scrollToTopForQA()
                guard let tableView = table(in: inbox) else { throw Failure(description: "no table") }
                var step = 0
                func shot(_ name: String) throws {
                    let file = String(format: "%@-%@-%02d-%@.png", style == "current" ? "classic" : style,
                                      dark ? "dark" : "light", step, name)
                    try capture(inbox, to: outputDirectory.appendingPathComponent(file))
                    step += 1
                    written += 1
                }
                func disclosure() throws {
                    guard inbox.clickDisclosureForQA(id: uuid(lead)) else { throw Failure(description: "no disclosure") }
                    inbox.foldMotionForQA.cancel()
                }
                try shot("rest")
                try click(inbox, window: window, id: uuid(lead))
                try shot("sidebar-click-lead")
                try disclosure()
                try shot("expand-selected-lead")
                try click(inbox, window: window, id: uuid(lead + 1))
                try shot("sidebar-click-helper")
                inbox.openAgentId = uuid(lead)
                try shot("canvas-focus-lead")
                window.makeFirstResponder(tableView)
                try key(125, NSDownArrowFunctionKey, window: window)
                try shot("arrow-down")
                try key(126, NSUpArrowFunctionKey, window: window)
                try key(126, NSUpArrowFunctionKey, window: window)
                try shot("arrow-up")
                guard inbox.jump(keyCode: 19, modifiers: .command) else { throw Failure(description: "⌘2 did not jump") }
                pump()
                try shot("quick-jump")
                try hover(inbox, window: window, id: uuid(lead))
                try shot("hover-lead")
                try click(at: canvas.convert(NSPoint(x: 150, y: 260), to: nil), window: window)
                inbox.openAgentId = nil
                try shot("canvas-click")
                try click(inbox, window: window, id: uuid(lead))
                try shot("back-to-sidebar")
                setKey(false, window: window)
                try shot("window-resigns-key")
                setKey(true, window: window)
                try shot("window-regains-key")
                try click(inbox, window: window, id: uuid(single))
                try shot("select-other-group")
                inbox.openAgentId = uuid(lead)
                try shot("canvas-focus-back")
                try disclosure()
                try shot("collapse")
                try disclosure()
                try shot("expand")
                inbox.apply(rows: rows(withArrival: true),
                            changed: AgentsBoardChangeSet(added: [uuid(arrival)], updated: [uuid(lead)], removed: []))
                pump()
                try shot("helper-arrives")
                try hover(inbox, window: window, id: uuid(other))
                defaults.set("working", forKey: "continuum.sidebar.activeAgentScope")
                NotificationCenter.default.post(
                    name: Notification.Name("array.setting.changed.continuum.sidebar.activeAgentScope"), object: nil)
                try shot("scope-all")
                inbox.openAgentId = uuid(lead + 1)
                try shot("canvas-focus-helper")
            }
        }
        return "SidebarParityCapture: \(written) captures in \(outputDirectory.path)"
    }
}
