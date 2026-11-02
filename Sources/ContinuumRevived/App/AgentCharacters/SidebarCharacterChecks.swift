import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

// Plan: .plans/110-agent-characters/README.md, slice 4.
//
// `--sidebar-character-check`, on the real `AgentInboxView` in Aqua and Dark Aqua:
// the character's slot beside the provider mark, clear of every label; it fades
// with the mark under hover; recycled cells never keep another agent's character;
// a scroll with characters on lays out exactly as often as one with them off;
// occlusion holds them still; and off leaves no sprite. Captures both appearances
// to qa-runs/agent-characters for review.
@MainActor
enum SidebarCharacterChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(description: message) }
    }

    static let now = Date(timeIntervalSinceReferenceDate: 820_000_000)
    static func id(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "1D000000-0000-4000-8000-%012X", value))!
    }

    static func stillsRows() -> [AgentInboxRow] {
        func row(_ n: Int, _ title: String, _ state: InboxState, model: String, branch: String? = nil,
                 action: AgentCharacterLoop? = nil, outcome: AgentTerminalOutcome? = nil, unread: Bool = false,
                 quiet: TimeInterval = 5) -> AgentInboxRow {
            let ended = now.addingTimeInterval(-600)
            return AgentInboxRow(
                id: id(n), title: title, projectName: "Array", directoryName: "Array", state: state, model: model,
                branch: branch, elapsed: state == .working ? 250 : nil,
                elapsedStartedAt: state == .working ? now.addingTimeInterval(-250) : nil,
                lastActiveAt: ended, createdAt: now.addingTimeInterval(-Double(1000 - n)),
                terminalEvent: outcome.map { AgentTerminalEvent(sequence: 1, turnID: "t", outcome: $0, endedAt: ended) },
                terminalIsUnread: unread,
                characterActivity: AgentCharacterActivity(
                    action: action, lastOutputAt: now.addingTimeInterval(-quiet), promptSentAt: now.addingTimeInterval(-300),
                    endedAt: outcome == nil ? nil : ended,
                    outcome: outcome.map { $0 == .succeeded ? .succeeded : .failed }))
        }
        return [
            row(1, "Rework the sign-in screen", .working, model: "claude-opus-5-5", branch: "agent/sign-in", action: .type),
            row(2, "Find every caller of saveCanvas", .working, model: "gpt-5.5", action: .dabble),
            row(3, "Run the release matrix", .working, model: "pi/kimi-k2", action: .run),
            row(4, "Delete the stale benches", .approval, model: "claude-sonnet-5-5"),
            row(5, "Fix the zoom stutter", .failed, model: "gpt-5.5", branch: "agent/zoom", outcome: .failed),
            row(6, "Write the release notes", .ready, model: "claude-opus-5-5", outcome: .succeeded, unread: true),
            row(7, "Audit the notification paths", .working, model: "claude-opus-5-5", quiet: 400),
        ]
    }

    static func run() throws -> String {
        let suite = "ArraySidebarCharacterChecks-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = AgentCharacterController.shared
        controller.reduceMotion = { false }
        var windowsVisible = true
        controller.windowIsVisible = { _ in windowsVisible }
        defaults.set(true, forKey: AgentCharacterConfig.enabledKey)
        controller.adopt(defaults: defaults)
        var windows: [NSWindow] = []
        defer { windows.forEach { $0.orderOut(nil) } }
        let out = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("qa-runs/agent-characters", isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var placed = 0

        func makeInbox(_ rows: [AgentInboxRow], height: CGFloat, appearance: NSAppearance.Name) -> AgentInboxView {
            let inbox = AgentInboxView(frame: NSRect(x: 0, y: 0, width: 300, height: height))
            inbox.clock = { now }
            inbox.onRowAction = { _, _ in }
            inbox.wiredRowActions = [.settle, .snooze]
            let window = NSWindow(contentRect: inbox.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            window.contentView = inbox
            window.orderFrontOffscreenForChecks()
            windows.append(window)
            inbox.reload(rows: rows)
            inbox.layoutForQA()
            return inbox
        }

        // 1. Geometry, clearance, motion and the right character, in both appearances.
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let rows = stillsRows()
            let inbox = makeInbox(rows, height: 760, appearance: appearance)
            let tone: AgentCharacterAtlas.Appearance = appearance == .darkAqua ? .dark : .light
            for row in rows {
                guard let cell = inbox.cellForQA(id: row.id) else { throw Failure(description: "no card for \(row.title)") }
                cell.layoutSubtreeIfNeeded()
                guard let sprite = cell.characterRectForQA, let mark = cell.providerMarkRectForQA else {
                    throw Failure(description: "\(appearance.rawValue) '\(row.title)': no character or no mark")
                }
                try expect(abs(sprite.maxX - (mark.minX - 4)) <= 0.5,
                           "'\(row.title)': the character ends 4 pt left of the mark (\(sprite.maxX) vs \(mark.minX))")
                try expect(abs(sprite.midY - mark.midY) <= 1.5,
                           "'\(row.title)': the character is centred on the mark's line (\(sprite.midY) vs \(mark.midY))")
                try expect(sprite.size == NSSize(width: 20, height: 12), "1 pt per art pixel: \(sprite.size)")
                for neighbour in cell.characterNeighboursForQA where neighbour.frame.intersects(sprite) {
                    throw Failure(description: "'\(row.title)': the character covers the \(neighbour.name) \(neighbour.frame)")
                }
                let layer = cell.characterLayerForQA
                let expected = controller.atlas(for: row.id, appearance: tone)
                try expect((layer.contents as AnyObject?) === expected?.image,
                           "'\(row.title)': shows its own agent's character in the \(tone) atlas")
                let moving = row.state == .working || row.state == .approval
                try expect(layer.isAnimating == moving, "'\(row.title)' \(row.state): animating \(layer.isAnimating), wanted \(moving)")
                placed += 1
            }
            // The quiet one dozes.
            if let quiet = inbox.cellForQA(id: id(7))?.characterLayerForQA.plan {
                try expect(quiet.segments == [.repeating(.asleep)], "a working agent quiet 400 s is asleep: \(quiet.segments)")
            }
            // Hover: the character fades with the mark, and comes back.
            guard inbox.hoverRowForQA(id: id(6)), let hovered = inbox.cellForQA(id: id(6)) else {
                throw Failure(description: "could not hover")
            }
            inbox.layoutForQA()
            try expect(hovered.hoverActionsShownForQA && hovered.characterLayerForQA.opacity == 0,
                       "under hover the character fades with the mark")
            _ = inbox.hoverRowForQA(id: nil)
            inbox.layoutForQA()
            try expect(hovered.characterLayerForQA.opacity == 1, "and returns when the pointer leaves")
            try capture(inbox.window!, to: out.appendingPathComponent("sidebar-\(tone.rawValue).png"))
        }

        // 2. Sixty rows in a short list: recycle every cell twice, scrolling.
        let many = (0..<60).map { n -> AgentInboxRow in
            let state: InboxState = [.working, .ready, .approval, .failed][n % 4]
            return AgentInboxRow(
                id: id(100 + n), title: "Agent \(n)", projectName: "Array", directoryName: "Array", state: state,
                model: ["claude-opus-5-5", "gpt-5.5"][n % 2], createdAt: now.addingTimeInterval(-Double(n)),
                terminalEvent: state == .ready ? AgentTerminalEvent(sequence: 1, turnID: "t", outcome: .succeeded,
                                                                    endedAt: now.addingTimeInterval(-900)) : nil,
                characterActivity: AgentCharacterActivity(action: .read, lastOutputAt: now))
        }
        let byID = Dictionary(uniqueKeysWithValues: many.map { ($0.id, $0) })
        func sweep(_ inbox: AgentInboxView, verify: Bool) throws -> Int {
            let clip = inbox.scrollViewForQA.contentView
            let documentHeight = inbox.scrollViewForQA.documentView?.frame.height ?? 0
            let before = AgentInbox96CellView.qaLayoutPassCount
            var y: CGFloat = 0
            for pass in 0..<2 {
                while y < documentHeight {
                    clip.scroll(to: NSPoint(x: 0, y: y))
                    inbox.scrollViewForQA.reflectScrolledClipView(clip)
                    inbox.layoutForQA()
                    if verify {
                        for cell in inbox.visibleCharacterCellsForQA {
                            guard let row = cell.rowForQA, let want = byID[row.id] else { continue }
                            try expect((cell.characterLayerForQA.contents as AnyObject?)
                                       === controller.atlas(for: want.id, appearance: .dark)?.image,
                                       "a recycled card shows its own agent's character (\(want.title))")
                            try expect(cell.characterLayerForQA.isAnimating == (want.state == .working || want.state == .approval),
                                       "a recycled card animates only for a moving agent (\(want.title), pass \(pass))")
                        }
                    }
                    y += 37
                }
                y = 0
            }
            return AgentInbox96CellView.qaLayoutPassCount - before
        }
        let installsBefore = CharacterSpriteLayer.installCount
        let onInbox = makeInbox(many, height: 360, appearance: .darkAqua)
        let layoutsOn = try sweep(onInbox, verify: true)
        let installsOn = CharacterSpriteLayer.installCount - installsBefore

        // 3. Occlusion holds every visible character still; visibility restores them.
        onInbox.scrollViewForQA.contentView.scroll(to: .zero)
        onInbox.scrollViewForQA.reflectScrolledClipView(onInbox.scrollViewForQA.contentView)
        onInbox.layoutForQA()
        try expect(onInbox.visibleCharacterCellsForQA.contains { $0.characterLayerForQA.isAnimating },
                   "the top of the list has moving characters before the window is covered")
        windowsVisible = false
        NotificationCenter.default.post(name: AgentCharacterController.visibilityDidChangeNotification, object: nil)
        try expect(onInbox.visibleCharacterCellsForQA.allSatisfy { !$0.characterLayerForQA.isAnimating },
                   "an occluded window's characters hold still")
        windowsVisible = true
        NotificationCenter.default.post(name: AgentCharacterController.visibilityDidChangeNotification, object: nil)
        try expect(onInbox.visibleCharacterCellsForQA.contains { $0.characterLayerForQA.isAnimating },
                   "visible again, the working ones move")

        // 4. Off: no sprite anywhere, and the same scroll lays out exactly as often.
        defaults.set(false, forKey: AgentCharacterConfig.enabledKey)
        controller.reload()
        try expect(onInbox.visibleCharacterCellsForQA.allSatisfy {
            $0.characterRectForQA == nil && $0.characterLayerForQA.contents == nil && !$0.characterLayerForQA.isAnimating
        }, "off in Settings leaves no sprite on screen")
        let offInbox = makeInbox(many, height: 360, appearance: .darkAqua)
        let layoutsOff = try sweep(offInbox, verify: false)
        try expect(offInbox.visibleCharacterCellsForQA.allSatisfy { $0.characterLayerForQA.contents == nil },
                   "a list built while off makes no sprite")
        try expect(layoutsOn == layoutsOff,
                   "scrolling 60 rows: \(layoutsOn) card layouts with characters vs \(layoutsOff) without")
        return "Sidebar character checks passed: \(placed) placed cards in Aqua + Dark Aqua (4 pt left of the mark, centred, clear of every label), hover fade, 60 rows recycled twice (\(installsOn) installs, one per re-keyed card), \(layoutsOn) = \(layoutsOff) scroll layouts on vs off, occlusion pause, off leaves none"
    }

    static func capture(_ window: NSWindow, to url: URL) throws {
        CATransaction.flush()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber),
                                                  [.boundsIgnoreFraming, .bestResolution]),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw Failure(description: "capture failed")
        }
        try data.write(to: url)
    }
}
