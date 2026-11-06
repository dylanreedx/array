import AppKit
import ContinuumRevivedCore

@MainActor
enum SpawnFramingChecks {
    struct Failure: Error { let message: String }
    private final class Window: NSWindow { override var canBecomeKey: Bool { true } }
    static func run() throws {
        // Hand-computed competing slots: below is nearer the focused host, but
        // right gives the screen-shaped envelope (1288x520 vs 640x1048).
        // A preferred anchor must never bypass the requested fan-out policy.
        let host = TileFrame(x: 0, y: 0, width: 640, height: 520)
        let sibling = Tile(id: UUID(), kind: .note, title: "host", frame: host,
                           zPosition: .fromLegacyRank(1), runtimeRef: nil, metadata: TileMetadata())
        for (growth, wanted) in [(CanvasGrowthDirection.fan, TileFrame(x: 648,y: 0,width: 640,height: 520)),
                                  (.right, TileFrame(x: 648,y: 0,width: 640,height: 520)),
                                  (.down, TileFrame(x: 0,y: 528,width: 640,height: 520))] {
            let placed = TileSpawnPlacement.automatic(.init(newSize: CGSize(width: 640,height: 520),
                viewport: CanvasViewport(x: -1000,y: -1000,zoom: 1), visibleSize: CGSize(width: 3000,height: 2500),
                siblings: [sibling], gap: 8, fanOut: .init(hosts: [host], targetAspect: 1.6, growth: growth),
                preferredAnchor: CGPoint(x: 320,y: 260)))
            guard placed == wanted else { throw Failure(message: "focused fan-out \(growth): expected \(wanted), got \(placed)") }
        }

        AgentModelCatalog.shared.resetForQA(snapshot: .init(harness: .pi, readiness: .ready, models: AgentCatalogQAFixture.pi))
        let unpin = AgentCatalogQAFixture.pinAmbientSelection(harness: .pi, model: AgentCatalogQAFixture.pi[0])
        defer { unpin(); AgentModelCatalog.shared.resetForQA() }
        let fixture = try WorkspaceInvariantsFixture(label: "spawn-framing")
        defer { fixture.dispose() }
        try fixture.mount()
        let m = try fixture.requireMounted("spawn framing")
        m.canvas.navigationFlightOverrideForQA = false
        func drain() {
            let deadline = Date().addingTimeInterval(0.65)
            while Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        }
        func assertFramed(_ tile: Tile, _ label: String) throws {
            guard let expected = m.canvas.framedViewportForTileJump(tile.id),
                  m.canvas.navigationViewport == expected else { throw Failure(message: "\(label): camera differs from sidebar") }
            let usable = m.canvas.usableVisibleScreenRect
            let screen = CanvasEngine.tileScreenFrame(tile.frame, viewport: m.canvas.navigationViewport)
            if screen.width <= usable.width && screen.height <= usable.height {
                guard usable.insetBy(dx: -0.5, dy: -0.5).contains(screen) else { throw Failure(message: "\(label): world frame falls under chrome or outside view") }
            } else if !usable.contains(screen.origin) { throw Failure(message: "\(label): oversized tile top-left is hidden") }
        }
        m.canvas.spawnOverlayRects = { [weak canvas = m.canvas] in
            guard let canvas else { return [] }
            return [CGRect(x: 0, y: canvas.bounds.height-72, width: canvas.bounds.width, height: 72)]
        }
        for camera in [CanvasViewport(x: 0, y: 0, zoom: 1),
                       CanvasViewport(x: 20000, y: 20000, zoom: 1),
                       CanvasViewport(x: 0, y: 0, zoom: 0.4),
                       CanvasViewport(x: 200, y: 100, zoom: 1),
                       CanvasViewport(x: -15000, y: -15000, zoom: 0.7)] {
            m.canvas.setViewport(camera)
            let before = Set(m.canvas.allTilesInWorldFrames().map(\.id))
            guard m.delegate.qaPerformPaletteAction(.newNote) else { throw Failure(message: "palette refused note") }
            drain()
            guard let tile = m.canvas.allTilesInWorldFrames().first(where: { !before.contains($0.id) }),
                  let expected = m.canvas.framedViewportForTileJump(tile.id) else {
                throw Failure(message: "production palette created no tile")
            }
            guard m.canvas.navigationViewport == expected else {
                throw Failure(message: "spawn camera differs from sidebar framing: \(m.canvas.navigationViewport) expected \(expected)")
            }
            try assertFramed(tile, "camera \(camera)")
            let visible = CanvasEngine.visibleWorldRect(viewport: m.canvas.navigationViewport, visibleSize: m.canvas.bounds.size)
            guard visible.contains(CGPoint(x: tile.frame.x, y: tile.frame.y)) else {
                throw Failure(message: "spawn top-left remains outside camera")
            }
        }
        if let target = m.runtime.document.zones.first(where: {
            $0.projectId != nil && $0.zoneId != m.runtime.document.lastActiveZoneId
        }) {
            let beforePan = m.canvas.navigationViewport
            let x = target.origin.x + target.size.width/2 - Double(m.canvas.bounds.width)/beforePan.zoom/2
            let y = target.origin.y + target.size.height/2 - Double(m.canvas.bounds.height)/beforePan.zoom/2
            m.canvas.cameraDriver.noteScrollPan(dx: (beforePan.x-x)*beforePan.zoom,
                dy: (beforePan.y-y)*beforePan.zoom, location: CGPoint(x: m.canvas.bounds.midX, y: m.canvas.bounds.midY))
            m.canvas.cameraDriver.qaFlushPending()
            let ids = Set(m.canvas.allTilesInWorldFrames().map(\.id))
            guard m.delegate.qaPerformPaletteAction(.newNote),
                  let tile = m.canvas.allTilesInWorldFrames().first(where: { !ids.contains($0.id) }),
                  tile.zoneId == target.zoneId else { throw Failure(message: "spawn before hydration debounce used the previous zone") }
            m.canvas.cameraDriver.qaMarkSettledNow()
            drain()
            if let final = m.canvas.allTilesInWorldFrames().first(where: { $0.id == tile.id }) { try assertFramed(final, "pending pan") }
        }
        for action in [LaunchPaletteAction.newManagedAgent, .newBoard] {
            guard m.delegate.qaPerformPaletteAction(action) else { throw Failure(message: "palette refused \(action)") }
            drain()
        }
        m.delegate.handleFloatingToolbarSelection(.agentHarness(.pi))
        drain()
        let window = Window(contentRect: NSRect(origin: .zero, size: m.canvas.frame.size),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = m.canvas
        window.orderFrontOffscreenForChecks()
        window.makeKey()
        m.delegate.qaAttachWindowInstallingHotkeyMonitor(window)
        defer { window.orderOut(nil); window.contentView = nil }
        func key(_ text: String, code: UInt16, modifiers: NSEvent.ModifierFlags = []) throws {
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code) else { throw Failure(message: "event creation failed") }
            NSApp.sendEvent(event)
        }
        _ = m.delegate.qaFocusBroker.enterScope(.canvas, reason: .userClick)
        window.makeFirstResponder(m.canvas)
        let beforeTyping = Set(m.canvas.allTilesInWorldFrames().map(\.id))
        try key("k", code: 40, modifiers: .command)
        guard m.delegate.qaProfilePalette?.isVisible == true else { throw Failure(message: "Command-K did not open palette") }
        for c in "Note" { try key(String(c), code: 0) }
        try key("\r", code: 36)
        drain()
        guard let typed = m.canvas.allTilesInWorldFrames().first(where: { !beforeTyping.contains($0.id) }) else {
            throw Failure(message: "typed Command-K New Note produced no tile")
        }
        try assertFramed(typed, "typed Command-K")
        let before = Set(m.canvas.allTilesInWorldFrames().map(\.id))
        for _ in 0..<3 { _ = m.delegate.qaPerformPaletteAction(.newNote) }
        drain()
        guard m.canvas.allTilesInWorldFrames().filter({ !before.contains($0.id) }).count == 3 else {
            throw Failure(message: "burst did not create three notes")
        }
        _ = m.delegate.qaPerformPaletteAction(.newNote)
        try fixture.switchTo(WorkspaceInvariantsFixture.workspaceB)
        let switchedCamera = m.canvas.navigationViewport
        drain()
        guard m.canvas.navigationViewport == switchedCamera else { throw Failure(message: "pending spawn moved camera after workspace switch") }
        try ZoneArmingChecks.runSpawnFramingCases()
        print("SpawnFramingChecks passed: mounted palette, offscreen zone, working zoom, three-tile burst")
    }
}
