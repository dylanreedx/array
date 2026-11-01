import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

// Plan: .plans/110-agent-characters/README.md, slice 5.
//
// `--tile-character-check`: a real agent tile on a real canvas, attached to a real
// supervisor. Runtime events go through the supervisor's own `deliver` path and
// reach the header the way production's do. Asserts the slot at every chrome
// scale bucket, the title starting after it and never under the status pill, far
// parking and leaving the window holding it still (and coming back restoring it),
// and a ⌘-scroll zoom dispatched through the window costing the bar no extra
// layout or draw with characters on. Captures light and dark headers.
@MainActor
enum TileCharacterChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(description: message) }
    }

    static func pump(until condition: () -> Bool, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    static func run() throws -> String {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("array-tile-character-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "ArrayTileCharacterChecks-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = AgentCharacterController.shared
        controller.reduceMotion = { false }
        controller.windowIsVisible = { _ in true }
        defaults.set(true, forKey: AgentCharacterConfig.enabledKey)
        controller.adopt(defaults: defaults)

        AgentModelCatalog.shared.resetForQA(snapshot: AgentCatalogQAFixture.claude)
        let support = root.appendingPathComponent("support", isDirectory: true)
        let supervisor = AgentSupervisor(
            store: AgentStore(applicationSupportDirectory: support),
            makeRunner: AgentSupervisor.productionRunner,
            submissionRecoveryStore: AgentComposerDraftStore(applicationSupportDirectory: support, debounceInterval: 0),
            transcriptStore: AgentTranscriptStore(root: root.appendingPathComponent("transcripts", isDirectory: true)))
        defer { supervisor.stopAll() }
        let agentID = supervisor.spawn(
            role: nil, prompt: nil, cwd: work, harness: .claudeCode,
            model: "anthropic/claude-haiku-4-5-20251001", thinking: "low", displayName: "Rework the sign-in screen")

        let canvas = CanvasNSView(canvasState: CanvasState(
            viewport: CanvasViewport(x: 0, y: 0, zoom: 1), tiles: [], groups: [], lastActiveTileId: nil))
        canvas.focusBroker = FocusBroker()
        canvas.frame = NSRect(x: 0, y: 0, width: 1400, height: 900)
        let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = canvas
        window.orderFrontOffscreenForChecks()
        defer { window.orderOut(nil) }
        let tile = Tile(id: UUID(), kind: .managedAgent, title: "Rework the sign-in screen",
                        frame: TileFrame(x: 40, y: 40, width: 520, height: 360),
                        zPosition: .fromLegacyRank(1), runtimeRef: nil,
                        metadata: TileMetadata(launchProfileId: "managed"))
        let view = ManagedAgentTileNSView(tile: tile)
        canvas.install(tileView: view, for: tile)
        view.attach(agentID: agentID, supervisor: supervisor)
        canvas.layoutSubtreeIfNeeded()

        // 1. A fresh agent: a still character, between the mark and the title.
        try expect(pump(until: { view.qaCharacterRect != nil }), "the header shows a character for an attached agent")
        try expect(view.qaCharacterLayer?.isAnimating == false, "an agent that has not started holds still")

        // 2. Through the supervisor: a turn starts and the agent edits a file.
        supervisor.qaDeliver(.turnStarted(threadId: "t", turnId: "u1"), to: agentID)
        supervisor.qaDeliver(.itemStarted(threadId: "t", itemId: "e1", kind: .fileChange, title: "Sources/App.swift"), to: agentID)
        try expect(pump(until: { view.qaCharacterLayer?.plan?.segments == [.loop(.type, slow: false)] }),
                   "an edit reaches the header as the typing loop: \(String(describing: view.qaCharacterLayer?.plan?.segments))")
        try expect(view.qaCharacterLayer?.isAnimating == true, "a working agent's character moves")
        try expect(controller.pendingRevisitsForQA >= 1, "the 40 s slow-down is scheduled on the shared deadline timer")

        // 3. The slot at every chrome scale bucket.
        var buckets: [Double] = []
        for zoom in [1.0, 0.75, 0.5, 0.35, 0.2, 0.12] {
            canvas.setViewport(CanvasViewport(x: 0, y: 0, zoom: zoom))
            canvas.layoutSubtreeIfNeeded()
            view.layoutSubtreeIfNeeded()
            guard let rect = view.qaCharacterRect, let mark = view.qaProviderMarkRect,
                  let title = view.qaTitleRectInBar() else {
                throw Failure(description: "zoom \(zoom): no character, mark or title")
            }
            let scale = rect.height / 12
            buckets.append(Double(scale))
            try expect(abs(rect.width - 20 * scale) < 0.01, "zoom \(zoom): 20 x 12 art at chrome scale \(scale)")
            try expect(abs(rect.minX - (mark.maxX + 4 * scale)) < 0.01, "zoom \(zoom): 4 pt (scaled) right of the mark")
            try expect(abs(rect.midY - mark.midY) < 0.51, "zoom \(zoom): centred with the mark")
            if title.width > 0 {
                try expect(title.minX >= rect.maxX + CGFloat(Space.s) * scale - 0.01,
                           "zoom \(zoom): the title starts after the character (\(title.minX) vs \(rect.maxX))")
            }
            if let pill = view.qaStatusPillRectInBar(), title.width > 0 {
                try expect(!title.intersects(pill), "zoom \(zoom): the title never runs under the status pill")
                try expect(!rect.intersects(pill), "zoom \(zoom): the character never sits under the pill")
            }
        }
        try expect(Set(buckets).count >= 3, "the sweep crossed several chrome scale buckets: \(buckets)")
        canvas.setViewport(CanvasViewport(x: 0, y: 0, zoom: 1))
        canvas.layoutSubtreeIfNeeded()

        // 4. Far parking holds it still; coming back restores it. So does leaving the window.
        let park = NSView(frame: .zero)
        try expect(view.parkBodyFarOffscreen(park: park), "the real far-park seam parks the tile")
        try expect(view.qaCharacterLayer?.isAnimating == false, "a far-parked tile's character holds still")
        view.promoteBodyToNative()
        try expect(view.qaCharacterLayer?.isAnimating == true, "back on screen it moves again")
        let plane = view.superview
        view.removeFromSuperview()
        try expect(view.qaCharacterLayer?.isAnimating == false, "a tile out of the window (parked workspace) holds still")
        plane?.addSubview(view)
        try expect(view.qaCharacterLayer?.isAnimating == true, "re-installed, it moves again")

        // 5. A zoom gesture through the window's real event dispatch: equal bar
        // layouts and draws with characters on and off, and no sprite install.
        func zoomGesture() throws -> (layouts: Int, draws: Int, installs: Int) {
            // Let the supervisor's event stream and any status refresh settle first,
            // so both runs start equally quiet and only the gesture is counted.
            _ = pump(until: { false }, timeout: 1)
            canvas.setViewport(CanvasViewport(x: 0, y: 0, zoom: 1))
            canvas.layoutSubtreeIfNeeded()
            canvas.displayIfNeeded()
            let layouts = view.qaTitleBarLayoutPasses
            let draws = view.qaTitleBarDrawCount
            let installs = CharacterSpriteLayer.installCount
            let screenHeight = NSScreen.screens.first?.frame.height ?? 900
            for step in 0..<24 {
                guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                       wheel1: step < 12 ? -6 : 6, wheel2: 0, wheel3: 0) else {
                    throw Failure(description: "could not make a scroll event")
                }
                cg.flags = .maskCommand
                // With no window on the event, AppKit reads its location as the
                // window point: an empty patch of canvas right of the tile.
                cg.location = CGPoint(x: 1000, y: screenHeight - 700)
                guard let event = NSEvent(cgEvent: cg) else { throw Failure(description: "no NSEvent") }
                window.sendEvent(event)
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
                canvas.layoutSubtreeIfNeeded()
                canvas.displayIfNeeded()
            }
            _ = pump(until: { false }, timeout: 0.4)
            canvas.layoutSubtreeIfNeeded()
            canvas.displayIfNeeded()
            return (view.qaTitleBarLayoutPasses - layouts, view.qaTitleBarDrawCount - draws,
                    CharacterSpriteLayer.installCount - installs)
        }
        let appliesBefore = canvas.qaViewportApplyCount
        let on = try zoomGesture()
        try expect(canvas.qaViewportApplyCount > appliesBefore + 4, "the ⌘-scroll events reached the canvas zoom")
        try expect(on.installs == 0, "zooming installs no sprite animation (\(on.installs))")
        try expect(view.qaCharacterLayer?.isAnimating == true, "the character keeps moving through a gesture (rule 7)")
        try captureHeaders(view: view, window: window, label: "tile")
        defaults.set(false, forKey: AgentCharacterConfig.enabledKey)
        controller.reload()
        canvas.layoutSubtreeIfNeeded()
        try expect(view.qaCharacterRect == nil && view.qaCharacterLayer?.contents == nil, "off removes the header character")
        let off = try zoomGesture()
        try expect(on.layouts == off.layouts && on.draws == off.draws,
                   "a zoom gesture: bar layouts \(on.layouts) on vs \(off.layouts) off, draws \(on.draws) vs \(off.draws)")
        return "Tile character checks passed: supervisor events drive the header (edit → typing loop), \(Set(buckets).count) chrome scale buckets placed, title clear of the pill, far park / out-of-window hold still and restore, ⌘-scroll zoom through window dispatch: \(on.layouts) bar layouts and \(on.draws) draws on = off, 0 installs"
    }

    /// Light and dark captures of the header for review.
    static func captureHeaders(view: ManagedAgentTileNSView, window: NSWindow, label: String) throws {
        let out = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("qa-runs/agent-characters", isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            window.contentView?.layoutSubtreeIfNeeded()
            window.contentView?.displayIfNeeded()
            try SidebarCharacterChecks.capture(window, to: out.appendingPathComponent(
                "\(label)-\(appearance == .aqua ? "light" : "dark").png"))
        }
        window.appearance = nil
    }
}
