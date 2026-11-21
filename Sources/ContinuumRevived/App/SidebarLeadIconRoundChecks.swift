import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

/// DESIGN ROUND ONLY: `--sidebar-lead-icon-round`. Renders the production
/// `AgentInboxView` with the lead-icon variants (`InboxLeadIconVariant`) into
/// `ARRAY_LEAD_ICON_OUT`: stills per variant x plate style x appearance, and
/// frame sequences of the fold motion. Asserts nothing about taste.
@MainActor
enum SidebarLeadIconRoundChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static let now = Date(timeIntervalSinceReferenceDate: 820_000_000)
    static func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "1E000000-0000-4000-8000-%012X", n))! }

    static func rows() -> [AgentInboxRow] {
        func row(_ n: Int, _ title: String, _ state: InboxState, model: String, parent: Int? = nil, colour: String? = nil,
                 branch: String? = nil, action: AgentCharacterLoop? = nil, outcome: AgentTerminalOutcome? = nil,
                 unread: Bool = false, pinned: Bool = false, age: Double = 0) -> AgentInboxRow {
            let ended = now.addingTimeInterval(-600 - age)
            return AgentInboxRow(
                id: id(n), title: title, projectName: "Array", directoryName: "Array", state: state, model: model,
                branch: branch, elapsed: state == .working ? 250 : nil,
                elapsedStartedAt: state == .working ? now.addingTimeInterval(-250) : nil,
                lastActiveAt: ended, depth: parent == nil ? 0 : 1, createdAt: now.addingTimeInterval(-Double(1000 - n)),
                parentId: parent.map(id),
                terminalEvent: outcome.map { AgentTerminalEvent(sequence: 1, turnID: "t", outcome: $0, endedAt: ended) },
                terminalIsUnread: unread, identityColor: colour, isPinned: pinned,
                characterActivity: AgentCharacterActivity(
                    action: action, lastOutputAt: now.addingTimeInterval(-5), promptSentAt: now.addingTimeInterval(-300),
                    endedAt: outcome == nil ? nil : ended,
                    outcome: outcome.map { $0 == .succeeded ? .succeeded : .failed }))
        }
        return [
            row(1, "Rework the sign-in screen", .working, model: "claude-opus-5-5", colour: "teal", branch: "agent/sign-in", action: .type, pinned: true),
            row(11, "Audit the token usage", .working, model: "claude-sonnet-5-5", parent: 1, action: .read),
            row(12, "Write the sign-in tests", .ready, model: "gpt-5.5", parent: 1, outcome: .succeeded, unread: true),
            row(13, "Migrate the keychain wrapper", .failed, model: "claude-sonnet-5-5", parent: 1, outcome: .failed, unread: true),
            row(2, "Run the release matrix", .ready, model: "claude-opus-5-5", colour: "purple", outcome: .succeeded, unread: true),
            row(21, "Build the iOS legs", .ready, model: "claude-sonnet-5-5", parent: 2, outcome: .succeeded),
            row(22, "Bundle probe", .ready, model: "claude-sonnet-5-5", parent: 2, outcome: .succeeded),
            row(23, "UI baselines", .ready, model: "gpt-5.5", parent: 2, outcome: .succeeded),
            row(3, "Fix the zoom stutter", .failed, model: "gpt-5.5", colour: "orange", branch: "agent/zoom", outcome: .failed),
            row(31, "Profile the pinch gesture", .failed, model: "gpt-5.5", parent: 3, outcome: .failed),
            row(32, "Bisect the regression", .working, model: "gpt-5.5", parent: 3, action: .run),
            row(4, "Draft the release notes", .approval, model: "claude-opus-5-5", colour: "blue"),
            row(5, "Delete the stale benches", .working, model: "claude-sonnet-5-5", colour: "pink", action: .dabble),
        ]
    }

    static func run() throws -> String {
        guard let outPath = ProcessInfo.processInfo.environment["ARRAY_LEAD_ICON_OUT"], !outPath.isEmpty else {
            throw Failure(description: "set ARRAY_LEAD_ICON_OUT")
        }
        let out = URL(fileURLWithPath: outPath, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let suite = "ArrayLeadIconRound-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = AgentCharacterController.shared
        controller.reduceMotion = { false }
        controller.windowIsVisible = { _ in true }
        func configure(enabled: Bool, style: AgentCharacterConfig.BubbleStyle) {
            defaults.set(enabled, forKey: AgentCharacterConfig.enabledKey)
            defaults.set(style.rawValue, forKey: AgentCharacterConfig.bubbleStyleKey)
            controller.adopt(defaults: defaults)
            controller.reload()
        }
        var windows: [NSWindow] = []
        defer { windows.forEach { $0.orderOut(nil) } }
        func makeInbox(_ appearance: NSAppearance.Name) -> AgentInboxView {
            let inbox = AgentInboxView(frame: NSRect(x: 0, y: 0, width: 300, height: 620))
            inbox.clock = { now }
            inbox.onRowAction = { _, _ in }
            inbox.wiredRowActions = [.settle, .snooze, .popOut, .stopAgent]
            inbox.hoverCardEnabled = false
            let window = NSWindow(contentRect: inbox.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.acceptsMouseMovedEvents = true
            window.appearance = NSAppearance(named: appearance)
            window.contentView = inbox
            window.orderFrontOffscreenForChecks()
            windows.append(window)
            inbox.reload(rows: rows())
            inbox.layoutForQA()
            return inbox
        }
        func snap(_ window: NSWindow, to url: URL, settle: TimeInterval = 0.25) throws {
            CATransaction.flush()
            RunLoop.current.run(until: Date().addingTimeInterval(settle))
            try write(window, to: url)
        }
        func write(_ window: NSWindow, to url: URL) throws {
            guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber),
                                                      [.boundsIgnoreFraming, .bestResolution]),
                  let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                throw Failure(description: "capture failed \(url.lastPathComponent)")
            }
            try data.write(to: url)
        }
        // ARRAY_LEAD_ICON_ONLY=halo refreshes that variant's files and leaves the rest.
        let only = ProcessInfo.processInfo.environment["ARRAY_LEAD_ICON_ONLY"].flatMap(InboxLeadIconVariant.init(rawValue:))
        let tones: [(NSAppearance.Name, String)] = [(.aqua, "light"), (.darkAqua, "dark")]
        let styles: [AgentCharacterConfig.BubbleStyle] = [.orb, .squircle, .inline]
        var count = 0
        let stills = out.appendingPathComponent("stills", isDirectory: true)
        try FileManager.default.createDirectory(at: stills, withIntermediateDirectories: true)
        // Stills. `today` = characters on, classic fold control, character at the right.
        for (appearance, tone) in tones {
            if only == nil {
                configure(enabled: false, style: .orb)
                InboxLeadIconVariant.current = .off
                let offInbox = makeInbox(appearance)
                try snap(windows.last!, to: stills.appendingPathComponent("icons-off-\(tone).png"))
                _ = offInbox
            }
            for style in styles {
                for variant in [InboxLeadIconVariant.off, .settle, .halo, .lift] {
                    if variant == .settle && style != .orb { continue }
                    if let only, variant != only { continue }
                    configure(enabled: true, style: style)
                    InboxLeadIconVariant.current = variant
                    let inbox = makeInbox(appearance)
                    // Collapse the matrix lead so one family is folded, as in use.
                    if let cell = inbox.cellForQA(id: id(2)) { _ = cell.clickDisclosureForQA() }
                    inbox.layoutForQA()
                    if let c = inbox.cellForQA(id: id(1)) {
                        fputs("DBG \(variant) \(style) enabled=\(controller.isEnabled) atlas=\(controller.atlas(for: id(1), appearance: .dark) != nil) rect=\(String(describing: c.characterRectForQA)) plate=\(c.leadPlateStateForQA)\n", stderr)
                    }
                    let name = variant == .off ? "today" : variant.rawValue
                    try snap(windows.last!, to: stills.appendingPathComponent("\(name)-\(style.rawValue)-\(tone).png"), settle: 0.6)
                    count += 1
                }
            }
        }
        // Hover witness (halo): a helper's left icon must stay visible while the
        // pointer is over its row, for a working, a resting and a failed helper.
        if only == nil || only == .halo {
            for (appearance, tone) in tones {
                configure(enabled: true, style: .orb)
                InboxLeadIconVariant.current = .halo
                let inbox = makeInbox(appearance)
                let window = windows.last!
                window.makeKey()
                if let cell = inbox.cellForQA(id: id(2)) { _ = cell.clickDisclosureForQA() }
                inbox.layoutForQA()
                inbox.updateTrackingAreas()
                for (n, label) in [(11, "working"), (12, "resting"), (13, "failed")] {
                    let point = try SidebarHelperHoverChecks.windowPoint(inbox, id: id(n))
                    try SidebarHelperHoverChecks.crossing(.mouseEntered, at: point, inbox: inbox, window: window)
                    try SidebarHelperHoverChecks.move(to: point, in: window)
                    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
                    CATransaction.flush()
                    guard inbox.hoveredAgentIdForQA == id(n) else {
                        throw Failure(description: "hover \(label) \(tone): the pointer never reached the row")
                    }
                    guard let cell = inbox.cellForQA(id: id(n)) else { throw Failure(description: "no cell \(label)") }
                    let layer = cell.characterLayerForQA
                    let alpha = layer.presentation()?.opacity ?? layer.opacity
                    guard !layer.isHidden, alpha > 0.3, layer.frame.width > 4, layer.frame.height > 4 else {
                        throw Failure(description: "hover \(label) \(tone): helper icon gone (hidden=\(layer.isHidden) alpha=\(alpha) frame=\(layer.frame))")
                    }
                    if n == 11 { try snap(window, to: stills.appendingPathComponent("halo-helpers-hover-\(tone).png"), settle: 0.2) }
                    fputs("HOVER-OK \(label) \(tone) alpha=\(alpha) frame=\(layer.frame)\n", stderr)
                    try SidebarHelperHoverChecks.crossing(.mouseExited, at: NSPoint(x: -20, y: point.y), inbox: inbox, window: window)
                    RunLoop.current.run(until: Date().addingTimeInterval(0.4))
                    inbox.layoutForQA()
                }
            }
        }
        // Working-loop frames (halo helper bob), light and dark, ~40 ms apart.
        if only == nil || only == .halo {
            for (appearance, tone) in tones {
                configure(enabled: true, style: .orb)
                InboxLeadIconVariant.current = .halo
                let inbox = makeInbox(appearance)
                let window = windows.last!
                if let cell = inbox.cellForQA(id: id(2)) { _ = cell.clickDisclosureForQA() }
                inbox.layoutForQA()
                let dir = out.appendingPathComponent("frames/helper-working-\(tone)", isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                RunLoop.current.run(until: Date().addingTimeInterval(0.3))
                let start = Date()
                for n in 0..<46 {
                    RunLoop.current.run(until: start.addingTimeInterval(Double(n) * 0.04))
                    try write(window, to: dir.appendingPathComponent(String(format: "f%02d.png", n)))
                }
            }
        }
        // Motion: collapse then expand the first lead, one frame every ~30 ms.
        let frames = out.appendingPathComponent("frames", isDirectory: true)
        try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
        for variant in [InboxLeadIconVariant.settle, .halo, .lift] where only == nil || only == variant {
            for (appearance, tone) in tones {
                configure(enabled: true, style: .orb)
                InboxLeadIconVariant.current = variant
                let inbox = makeInbox(appearance)
                let window = windows.last!
                for phase in ["collapse", "expand"] {
                    let dir = frames.appendingPathComponent("\(variant.rawValue)-\(tone)-\(phase)", isDirectory: true)
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    try snap(window, to: dir.appendingPathComponent("f00.png"), settle: 0.5)
                    guard let cell = inbox.cellForQA(id: id(1)), cell.clickDisclosureForQA() else {
                        throw Failure(description: "no lead fold")
                    }
                    let start = Date()
                    for n in 1...24 {
                        RunLoop.current.run(until: start.addingTimeInterval(Double(n) * 0.028))
                        try write(window, to: dir.appendingPathComponent(String(format: "f%02d.png", n)))
                    }
                    RunLoop.current.run(until: Date().addingTimeInterval(0.4))
                }
            }
        }
        return "lead icon round: \(count) variant stills + frame sequences in \(out.path)"
    }
}
