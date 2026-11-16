import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Foundation

/// `--agent-jump-composer-check` — jumping to an agent lands on its composer.
///
/// Dylan, 2026-11-15: "when clicking on an agent tile, it might be too big ...
/// when jumping to a tile, go to the composer as cleanly as possible AND show the
/// head of the tile (similar to code editors and having a sticky function def)".
///
/// Drives production only: the boot mount (`WorkspaceAPIChecks.makeFixture`), the
/// sidebar as `configureWorkspaceSidebar` wires it, real clicks through
/// `NSApp.sendEvent` in a key window that holds the sidebar AND the canvas with
/// the app's tile-focus monitor installed, and the workspace API's own
/// `agent.reveal`. Asserts what the person sees — where the composer and the
/// tile's edges are on screen, who holds the keyboard, whether a pinned head is
/// showing and what it says — never which method ran.
///
/// - A tile TALLER than the screen: the composer is wholly on screen, its text
///   view holds the keyboard, the zoom did not drop, and the pinned head shows
///   the tile's title at the top edge. From a far-out camera and a close one,
///   snapped and flown, by sidebar click and by API reveal.
/// - A pinned head is pressed like a header: a click on it focuses the tile and
///   moves nothing.
/// - A tile that FITS: framed whole, composer focused, no pinned head.
/// - The setting OFF: today's jump — the tile's top framed, no pinned head.
///
/// `CONTINUUM_STICKY_HEAD_STILLS=<dir>` also writes in-situ stills of the head,
/// light and dark, for the design review.
@MainActor
enum AgentJumpComposerChecks {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private final class KeyWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var isKeyWindow: Bool { true }
    }

    static func run() throws -> String {
        guard ProcessInfo.processInfo.environment["CONTINUUM_APP_SUPPORT"] != nil,
              Bundle.main.bundleIdentifier != AppChannel.prodBundleIdentifier else {
            throw Failure(description: "agent-jump-composer requires isolated CONTINUUM_APP_SUPPORT and a dev binary")
        }
        AgentModelCatalog.shared.resetForQA(snapshot: AgentCatalogQAFixture.codex)
        guard let settings = QAIsolatedDefaults(isolatedSuiteName: "array.qa.agent-jump-composer.\(UUID().uuidString)") else {
            throw Failure(description: "no isolated defaults suite")
        }
        defer { settings.removePersistentDomain(forName: settings.suiteDomainName) }
        settings.set(false, forKey: CanvasAutoLayoutConfig.enabledKey)

        let tallTile = UUID(), shortTile = UUID()
        var tallAgent: AgentID?, shortAgent: AgentID?
        let f = try WorkspaceAPIChecks.makeFixture(settings: settings, beforeMount: { delegate, root in
            let project = UUID(uuidString: "00000000-0000-0000-0000-0000000CA104")!
            let zone = UUID(uuidString: "00000000-0000-0000-0000-0000000CA107")!
            let cwd = root.appendingPathComponent("Pb")
            let store = ProjectStore(projectRoot: cwd)
            var state = try store.loadCanvas()
            for (id, title, frame) in [(tallTile, "Tall agent", TileFrame(x: 4600, y: 440, width: 640, height: 2200)),
                                       (shortTile, "Short agent", TileFrame(x: 5400, y: 440, width: 560, height: 520))] {
                let agent = delegate.qaAgentSupervisor.spawn(
                    role: nil, prompt: nil, cwd: cwd, harness: .codex, mode: .managed,
                    model: AgentCatalogQAFixture.codex.models[0], thinking: "medium",
                    projectId: project, projectRoot: cwd, tileId: id)
                _ = delegate.qaAgentSupervisor.rename(agentID: agent, to: title)
                if id == tallTile { tallAgent = agent } else { shortAgent = agent }
                var tile = Tile(id: id, kind: .managedAgent, title: title, frame: frame,
                                zPosition: .fromLegacyRank(20), runtimeRef: nil,
                                metadata: TileMetadata(launchProfileId: "managed"))
                tile.zoneId = zone
                state.tiles.append(tile)
            }
            try store.saveCanvas(state)
        })
        defer { f.delegate.qaAgentSupervisor.stopAll(); f.tearDown() }
        guard let tallAgent, let shortAgent else { throw Failure(description: "precondition: agents were not spawned") }
        let delegate = f.delegate
        let canvas = f.canvas
        canvas.agentJumpDefaults = settings
        guard let tall = canvas.tileView(for: tallTile) as? ManagedAgentTileNSView,
              let short = canvas.tileView(for: shortTile) as? ManagedAgentTileNSView else {
            throw Failure(description: "precondition: the boot mount did not hydrate both agent tiles")
        }

        try delegate.reconciledManagedSessionSource.reconcile(
            registry: delegate.registryStore!.loadOrEmpty(), reason: .continuumRestarted, now: Date())
        let sidebar = WorkspaceSidebarView(frame: NSRect(x: 0, y: 0, width: WorkspaceSidebarConfig.defaultWidth, height: 900))
        delegate.qaInstallWorkspaceSidebar(sidebar)
        let canvasSize = NSSize(width: 1200, height: 900)
        let window = KeyWindow(
            contentRect: NSRect(x: 0, y: 0, width: sidebar.frame.width + canvasSize.width, height: 900),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: window.contentRect(forFrameRect: window.frame))
        container.addSubview(sidebar)
        canvas.frame = NSRect(origin: NSPoint(x: sidebar.frame.maxX, y: 0), size: canvasSize)
        container.addSubview(canvas)
        window.contentView = container
        window.orderFrontOffscreenForChecks()
        window.makeKey()
        defer { window.orderOut(nil) }
        delegate.qaInstallTileFocusMonitor()
        defer { delegate.qaRemoveTileFocusMonitor() }
        delegate.qaRefreshAgentSurfaces()
        spin(0.3)

        guard let tallWorld = canvas.navigationTileSnapshot(for: tallTile)?.worldFrame,
              tallWorld.height * CameraFraming.editableTargetZoom(for: .managedAgent) > Double(canvasSize.height) else {
            throw Failure(description: "precondition: the tall tile must be taller than the screen at working zoom")
        }

        var report: [String] = []
        var failures: [String] = []

        /// Where the person sees things, in canvas coordinates with y DOWN.
        func onScreen(_ rect: NSRect, of view: NSView) -> NSRect {
            var r = view.convert(rect, to: canvas)
            if !canvas.isFlipped { r.origin.y = canvas.bounds.height - r.maxY }
            return r
        }
        func tileOnScreen(_ view: TileNSView) -> NSRect { onScreen(view.bounds, of: view) }
        let screen = NSRect(origin: .zero, size: canvasSize).insetBy(dx: -0.5, dy: -0.5)
        func composerFacts(_ view: ManagedAgentTileNSView) -> (rect: NSRect, focused: Bool)? {
            guard let composer = view.qaChromeViews.composer else { return nil }
            let rect = onScreen(composer.bounds, of: composer)
            let responder = window.firstResponder as? NSView
            return (rect, responder.map { $0 === composer.textView || $0.isDescendant(of: composer.textView) } ?? false)
        }

        func jump(_ label: String, tile view: ManagedAgentTileNSView, start: CanvasViewport, flies: Bool,
                  how: () throws -> Void, expect: (CanvasViewport) -> [String]) {
            canvas.navigationFlightOverrideForQA = flies
            canvas.setViewport(start)
            _ = delegate.qaFocusBroker.enterScope(.canvas, reason: .userClick)
            spin(0.2)
            do {
                try how()
                spin(flies ? 2.0 : 0.3)
                let problems = expect(canvas.viewport)
                if problems.isEmpty {
                    report.append("  \(label): ok (zoom \(String(format: "%.2f", start.zoom)) → \(String(format: "%.2f", canvas.viewport.zoom)))")
                } else {
                    failures += problems.map { "[\(label)] \($0)" }
                }
            } catch {
                failures.append("[\(label)] \(error)")
            }
        }

        func composerFirstOutcome(_ view: ManagedAgentTileNSView, startZoom: Double, takesKeyboard: Bool = true) -> (CanvasViewport) -> [String] {
            { camera in
                var problems: [String] = []
                let tileRect = tileOnScreen(view)
                if camera.zoom < startZoom - 0.0001 { problems.append("zoom dropped from \(startZoom) to \(camera.zoom)") }
                if let composer = composerFacts(view) {
                    if !screen.contains(composer.rect) { problems.append("composer not wholly on screen: \(composer.rect) in \(canvasSize)") }
                    if takesKeyboard, !composer.focused { problems.append("composer text view is not first responder (\(String(describing: window.firstResponder)))") }
                    if !takesKeyboard, composer.focused { problems.append("an agent's API reveal took the keyboard, which its grant ceiling forbids") }
                } else {
                    problems.append("the tile has no composer")
                }
                if tileRect.maxY > canvasSize.height { problems.append("the tile's bottom is below the screen: \(tileRect)") }
                if tileRect.minY >= 0 { problems.append("precondition: the tile's top is on screen, so this tile fit: \(tileRect)") }
                if let head = view.qaStickyHead, let headView = view.qaStickyHeadView {
                    let headRect = onScreen(headView.bounds, of: headView)
                    if abs(headRect.minY) > 1 { problems.append("pinned head is not at the top edge: \(headRect)") }
                    if head.title != view.tile.title { problems.append("pinned head says \(head.title), the tile is \(view.tile.title)") }
                } else {
                    problems.append("no pinned head while the tile's header is above the screen")
                }
                return problems
            }
        }

        let far = CanvasViewport(x: -40_000, y: -40_000, zoom: 0.5)
        let close = CanvasViewport(x: -40_000, y: -40_000, zoom: 1.5)
        func clickRow(_ agent: AgentID) throws {
            try SidebarRowRevealChecks.click(row: agent.rawValue, in: sidebar, window: window)
        }

        // A tile taller than the screen.
        for (start, flies) in [(far, false), (close, false), (far, true)] {
            jump("sidebar, tall tile, from zoom \(start.zoom)\(flies ? ", flown" : "")", tile: tall, start: start, flies: flies,
                 how: { try clickRow(tallAgent) }, expect: composerFirstOutcome(tall, startZoom: start.zoom))
        }

        // The workspace API's reveal, as an agent asks for it: the agent reveals
        // itself, into its zone the person armed. Same composer framing and head;
        // the keyboard stays put, because an agent's session ceiling never lets
        // it take keyboard focus (CX-01 §16) — asking for it is preserved.
        _ = f.runtime.setActiveZone(f.zoneB, reason: .click)
        jump("API agent.reveal, tall tile", tile: tall, start: CanvasViewport(x: 3000, y: 400, zoom: 0.5), flies: false, how: {
            _ = f.runtime.setActiveZone(f.zoneB, reason: .click)
            // The sidebar clicks above engaged the user; the API defers to that
            // for 3 s by design. The agent asks once the person is idle.
            let idleUptime = ProcessInfo.processInfo.systemUptime + 4
            f.runtime.engagementClock = { idleUptime }
            defer { f.runtime.engagementClock = { ProcessInfo.processInfo.systemUptime } }
            let reply = f.api.dispatch(agentId: tallAgent, requestId: "jump-reveal-\(UUID().uuidString)", op: "agent.reveal", payload: [
                "agentId": tallAgent.rawValue.uuidString,
                "presentation": ["camera": "revealResult", "keyboardFocus": "enterResult", "selection": "selectResult"],
            ])
            guard case let .result(object) = reply, object["presentationEffects"]?.object?["camera"]?.string == "changed" else {
                throw Failure(description: "the reveal did not move the camera: \(reply)")
            }
        }, expect: composerFirstOutcome(tall, startZoom: 0.5, takesKeyboard: false))

        // The pinned head is pressed like a header: focus, and nothing moves.
        do {
            let label = "click on the pinned head"
            canvas.navigationFlightOverrideForQA = false
            try clickRow(tallAgent)
            spin(0.3)
            _ = delegate.qaFocusBroker.enterScope(.canvas, reason: .userClick)
            spin(0.1)
            let before = tall.tile.frame
            let camera = canvas.viewport
            if let headView = tall.qaStickyHeadView {
                let point = headView.convert(NSPoint(x: headView.bounds.midX, y: headView.bounds.midY), to: nil)
                try press(at: point, in: window)
                spin(0.3)
                if delegate.qaFocusBroker.activeSurface != .tile(tallTile) {
                    failures.append("[\(label)] the tile did not take focus: \(String(describing: delegate.qaFocusBroker.activeSurface))")
                } else if tall.tile.frame != before || canvas.viewport != camera {
                    failures.append("[\(label)] a click moved something: tile \(before) → \(tall.tile.frame), camera \(camera) → \(canvas.viewport)")
                } else {
                    report.append("  \(label): the tile took focus, nothing moved")
                }
            } else {
                failures.append("[\(label)] precondition: no pinned head to press")
            }
        }

        // A tile that fits: framed whole, focused, no head.
        jump("sidebar, tile that fits", tile: short, start: far, flies: false, how: { try clickRow(shortAgent) }) { camera in
            var problems: [String] = []
            let rect = tileOnScreen(short)
            if !screen.contains(rect) { problems.append("tile not wholly on screen: \(rect)") }
            if composerFacts(short)?.focused != true { problems.append("composer text view is not first responder") }
            if short.qaStickyHead != nil { problems.append("a pinned head shows on a tile whose header is on screen") }
            if camera.zoom < far.zoom { problems.append("zoom dropped") }
            return problems
        }

        // The stills, while the setting is on and the tall tile is pinned.
        if let directory = ProcessInfo.processInfo.environment["CONTINUUM_STICKY_HEAD_STILLS"] {
            canvas.navigationFlightOverrideForQA = false
            // A working agent, so the head carries its status pill as the header does.
            let supervisor = delegate.qaAgentSupervisor
            supervisor.qaBindRunnerForCapabilities(ScriptedAgentRunner(script: []), for: tallAgent)
            supervisor.qaDeliver(.turnStarted(threadId: AgentSupervisor.threadId(for: tallAgent), turnId: "stills"), to: tallAgent)
            delegate.qaRefreshAgentSurfaces()
            try clickRow(tallAgent)
            spin(0.4)
            try writeStills(tile: tall, canvas: canvas, window: window, to: URL(fileURLWithPath: directory))
            report.append("  stills written to \(directory)")
        }

        // The setting off: today's jump.
        settings.set(false, forKey: AgentJumpConfig.composerFirstKey)
        jump("setting off, tall tile", tile: tall, start: far, flies: false, how: { try clickRow(tallAgent) }) { camera in
            var problems: [String] = []
            let rect = tileOnScreen(tall)
            if rect.minY < 0 || rect.minY > canvasSize.height { problems.append("the tile's top is not on screen: \(rect)") }
            if let composer = composerFacts(tall) {
                if screen.contains(composer.rect) { problems.append("the composer is on screen, so the old (top) framing did not apply") }
                if !composer.focused { problems.append("composer text view is not first responder") }
            }
            if tall.qaStickyHead != nil { problems.append("a pinned head shows with the setting off") }
            return problems
        }
        settings.removeObject(forKey: AgentJumpConfig.composerFirstKey)

        guard failures.isEmpty else {
            throw Failure(description: "agent-jump-composer: \(failures.count) failing:\n  " + failures.joined(separator: "\n  ") + "\n passing:\n" + report.joined(separator: "\n"))
        }
        return report.joined(separator: "\n")
    }

    private static func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// A real click through the window: mouse-up queued first, mouse-down sent.
    private static func press(at point: NSPoint, in window: NSWindow) throws {
        func mouse(_ type: NSEvent.EventType) throws -> NSEvent {
            guard let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                pressure: type == .leftMouseUp ? 0 : 1) else { throw Failure(description: "could not synthesise \(type)") }
            return event
        }
        NSApp.postEvent(try mouse(.leftMouseUp), atStart: false)
        NSApp.sendEvent(try mouse(.leftMouseDown))
        while let pending = NSApp.nextEvent(matching: [.leftMouseUp, .leftMouseDragged], until: Date(), inMode: .default, dequeue: true) {
            NSApp.sendEvent(pending)
        }
    }

    /// The head as it sits on the canvas, light and dark: a crop of the top of
    /// the canvas around the tile, from the window server's own picture. Three
    /// looks for the design review: `flush` is the head as built; `card` and
    /// `lifted` are the alternatives, dressed on the same live view here only.
    private static func writeStills(tile: ManagedAgentTileNSView, canvas: CanvasNSView, window: NSWindow, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let head = tile.qaStickyHeadView, let layer = head.layer else { throw Failure(description: "stills: no pinned head") }
        let built = head.frame
        for style in ["flush", "card", "lifted"] {
            head.frame = built
            layer.cornerRadius = 0; layer.borderWidth = 0; layer.masksToBounds = false
            layer.shadowOpacity = 0
            switch style {
            case "card":
                head.frame = built.insetBy(dx: 6, dy: 0).offsetBy(dx: 0, dy: 6)
                layer.cornerRadius = 7
                layer.masksToBounds = true
                layer.borderWidth = 1
                layer.borderColor = LineToken.separator.color.nsColor(for: head.effectiveTokenTheme).cgColor
            case "lifted":
                layer.shadowColor = NSColor.black.cgColor
                layer.shadowOpacity = 0.22
                layer.shadowRadius = 6
                layer.shadowOffset = CGSize(width: 0, height: -2)
            default: break
            }
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                window.appearance = NSAppearance(named: appearance)
                if style == "card" { layer.borderColor = LineToken.separator.color.nsColor(for: appearance == .aqua ? .light : .dark).cgColor }
                spin(0.4)
                window.displayIfNeeded()
                spin(0.2)
                guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming]) else {
                    throw Failure(description: "no window image")
                }
                let scale = CGFloat(image.width) / window.frame.width
                let visible = tile.convert(tile.bounds, to: nil).intersection(canvas.convert(canvas.bounds, to: nil))
                let crop = NSRect(x: visible.minX - 40, y: visible.maxY - 220, width: visible.width + 80, height: 220)
                let pixels = CGRect(x: crop.minX * scale, y: (window.frame.height - crop.maxY) * scale,
                                    width: crop.width * scale, height: crop.height * scale)
                guard let cropped = image.cropping(to: pixels),
                      let data = NSBitmapImageRep(cgImage: cropped).representation(using: .png, properties: [:]) else {
                    throw Failure(description: "could not crop the still")
                }
                try data.write(to: directory.appendingPathComponent("sticky-head-\(style)-\(name).png"))
            }
        }
        head.frame = built
        layer.cornerRadius = 0; layer.borderWidth = 0; layer.masksToBounds = false; layer.shadowOpacity = 0
        window.appearance = nil
    }
}
