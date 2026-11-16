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
        settings.set(false, forKey: DragMagnetizeConfig.enabledKey)
        settings.set(true, forKey: AgentCharacterConfig.enabledKey)
        let characters = AgentCharacterController.shared
        characters.reduceMotion = { true }
        characters.windowIsVisible = { _ in true }
        characters.adopt(defaults: settings)

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
        canvas.dragMagnetizeDefaults = settings
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
                let margin = Double(canvasSize.height - tileRect.maxY)
                if abs(margin - CameraFraming.tilePaddingScreenPx) > 1 {
                    problems.append("the tile's bottom sits \(margin) pt above the screen's edge, not \(CameraFraming.tilePaddingScreenPx)")
                }
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

        // The pinned head is pressed like a header, through the window.
        func landOnTall() throws {
            canvas.navigationFlightOverrideForQA = false
            try clickRow(tallAgent)
            spin(0.3)
            _ = delegate.qaFocusBroker.enterScope(.canvas, reason: .userClick)
            spin(0.1)
        }
        func headPoint(_ fractionX: CGFloat) -> NSPoint? {
            guard let headView = tall.qaStickyHeadView else { return nil }
            return headView.convert(NSPoint(x: headView.bounds.width * fractionX, y: headView.bounds.midY), to: nil)
        }
        func hitsHead(_ point: NSPoint) -> Bool {
            guard let headView = tall.qaStickyHeadView, let content = window.contentView else { return false }
            return content.hitTest(content.superview?.convert(point, from: nil) ?? point) === headView
        }
        do {
            let label = "click on the pinned head"
            try landOnTall()
            let before = tall.tile.frame, camera = canvas.viewport, forwarded = tall.qaStickyHeadForwardedPresses
            if let point = headPoint(0.5) {
                let hit = hitsHead(point)
                try press(at: point, in: window)
                spin(0.3)
                if !hit {
                    failures.append("[\(label)] the window's hit test does not land on the pinned head")
                } else if tall.qaStickyHeadForwardedPresses != forwarded + 1 {
                    failures.append("[\(label)] the head did not hand the press to the tile as a header press")
                } else if delegate.qaFocusBroker.activeSurface != .tile(tallTile) {
                    failures.append("[\(label)] the tile did not take focus: \(String(describing: delegate.qaFocusBroker.activeSurface))")
                } else if tall.tile.frame != before || canvas.viewport != camera {
                    failures.append("[\(label)] a click moved something: tile \(before) → \(tall.tile.frame), camera \(camera) → \(canvas.viewport)")
                } else {
                    report.append("  \(label): hit the head, forwarded as a header press, the tile took focus, nothing moved")
                }
            } else {
                failures.append("[\(label)] precondition: no pinned head to press")
            }
        }

        // While the head takes over from a real bar still partly on screen, the
        // bar's close button sits under the head's blank right side. A press
        // there is the head's, never a close.
        do {
            let label = "press over the covered close button"
            try landOnTall()
            var camera = canvas.viewport
            camera.y = tallWorld.y + 10 / camera.zoom
            canvas.setViewport(camera)
            spin(0.2)
            // The close button's own centre, inside the band where the head
            // overlaps the still-visible bar.
            tall.wakeChrome()
            spin(0.1)
            let close = tall.qaCloseButtonFrame
            let headTop = tall.qaStickyHead?.frame.minY ?? 0
            let inBand = NSPoint(x: close.midX, y: (max(close.minY, headTop) + close.maxY) / 2)
            let point = tall.convert(inBand, to: nil)
            if !close.isEmpty, close.maxY > headTop, hitsHead(point) {
                let forwarded = tall.qaStickyHeadForwardedPresses
                try press(at: point, in: window)
                spin(0.3)
                if canvas.tileView(for: tallTile) == nil || delegate.qaAgentSupervisor.records[tallAgent]?.tileId != tallTile {
                    failures.append("[\(label)] the press closed or detached the tile")
                } else if tall.qaStickyHeadForwardedPresses != forwarded + 1 {
                    failures.append("[\(label)] the press did not reach the head")
                } else {
                    report.append("  \(label): the head took it; the tile stayed")
                }
            } else {
                failures.append("[\(label)] the close button \(close) under the head (top \(headTop)) is not hit-tested to the head while the real bar is 10 pt on screen")
            }
        }

        // A drag on the head moves the tile by exactly the pointer's travel.
        do {
            let label = "drag the pinned head"
            try landOnTall()
            // WORLD frames: a drop can change the tile's zone, and with it the
            // space its stored frame is written in.
            func world() -> TileFrame? { canvas.navigationTileSnapshot(for: tallTile)?.worldFrame }
            let zoom = canvas.viewport.zoom
            if let start = headPoint(0.5), let before = world() {
                try drag(from: start, by: NSPoint(x: 90, y: 0), in: window)
                spin(0.3)
                let after = world() ?? before
                let moved = after.x - before.x
                if abs(moved - 90 / zoom) > 1 || abs(after.y - before.y) > 0.5 {
                    failures.append("[\(label)] the tile moved (\(moved), \(after.y - before.y)) world for a 90 pt drag at zoom \(zoom)")
                } else {
                    report.append("  \(label): moved \(String(format: "%.1f", moved)) world for 90 pt at zoom \(zoom)")
                }
            } else {
                failures.append("[\(label)] precondition: no pinned head")
            }
        }

        // A right-click opens the header's menu.
        do {
            let label = "right-click on the pinned head"
            try landOnTall()
            var presented: NSMenu?
            TileNSView.qaMenuPresenter = { presented = $0 }
            defer { TileNSView.qaMenuPresenter = nil }
            if let point = headPoint(0.5),
               let down = NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                NSApp.sendEvent(down)
                spin(0.1)
                if presented?.items.isEmpty == false {
                    report.append("  \(label): the tile menu (\(presented!.items.count) items)")
                } else {
                    failures.append("[\(label)] no tile menu")
                }
            } else {
                failures.append("[\(label)] precondition: no pinned head")
            }
        }

        // The icon is the header's OWN view and layer, re-anchored beside the
        // pinned label. Style changes use the live character setting; no second
        // renderer, snapshot, timer, or sprite is involved.
        do {
            let label = "the header's icon follows the pinned head"
            guard let iconView = tall.agentBubbleView, let iconLayer = tall.qaAgentBubble else {
                throw Failure(description: "[\(label)] attached agent has no icon view/layer")
            }
            for style in AgentCharacterConfig.BubbleStyle.allCases {
                try landOnTall()
                settings.set(style.rawValue, forKey: AgentCharacterConfig.bubbleStyleKey)
                SettingChangeEvent.post(SettingID(rawValue: AgentCharacterConfig.bubbleStyleKey))
                spin(0.1)
                if tall.qaStickyHead == nil || iconLayer.bubbleStyle != style {
                    failures.append("[\(label), \(style.rawValue)] changing the setting did not update the already-pinned icon")
                }
                guard let world = canvas.navigationTileSnapshot(for: tallTile)?.worldFrame else {
                    throw Failure(description: "[\(label)] missing world frame")
                }
                let zoom = 0.8
                canvas.setViewport(CanvasViewport(x: world.x - 120 / zoom, y: world.y - 100 / zoom, zoom: zoom))
                canvas.layoutSubtreeIfNeeded()
                spin(0.1)
                guard tall.qaStickyHead == nil, let atHeader = tall.agentBubbleFrame else {
                    failures.append("[\(label), \(style.rawValue)] icon missing at the real header")
                    continue
                }
                canvas.setViewport(CanvasViewport(x: world.x - 120 / zoom, y: world.y + 400, zoom: zoom))
                canvas.layoutSubtreeIfNeeded()
                spin(0.1)
                if tall.agentBubbleView !== iconView || tall.qaAgentBubble !== iconLayer {
                    failures.append("[\(label), \(style.rawValue)] pinning replaced the header's icon view or layer")
                }
                if iconLayer.bubbleStyle != style || iconLayer.isHidden {
                    failures.append("[\(label), \(style.rawValue)] pinned icon does not show the live style")
                }
                if let head = tall.qaStickyHead, let pinned = tall.agentBubbleFrame {
                    let rect = onScreen(iconView.bounds, of: iconView)
                    if abs(pinned.minX - atHeader.minX) > 0.01 || pinned.size != atHeader.size {
                        failures.append("[\(label), \(style.rawValue)] pinned icon changed its header size or leading alignment")
                    }
                    if pinned.minY < head.frame.minY - 0.5 || pinned.minY > head.frame.maxY || rect.minY < -0.5 || rect.maxY > canvasSize.height {
                        failures.append("[\(label), \(style.rawValue)] icon is not wholly visible beside the pinned head: \(pinned), screen \(rect)")
                    }
                    if !tall.agentBubbleContains(NSPoint(x: pinned.midX, y: pinned.midY)) {
                        failures.append("[\(label), \(style.rawValue)] icon's hit shape stayed at the real header")
                    }
                    let point = iconView.convert(NSPoint(x: iconView.bounds.midX, y: iconView.bounds.midY), to: nil)
                    let before = tall.tile.frame
                    _ = delegate.qaFocusBroker.enterScope(.canvas, reason: .userClick)
                    spin(0.1)
                    try press(at: point, in: window)
                    spin(0.1)
                    if delegate.qaFocusBroker.activeSurface != .tile(tallTile) || tall.tile.frame != before {
                        failures.append("[\(label), \(style.rawValue)] clicking the pinned icon did not focus its tile without moving it")
                    }
                    var presented: NSMenu?
                    TileNSView.qaMenuPresenter = { presented = $0 }
                    if let event = NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                        NSApp.sendEvent(event)
                    }
                    TileNSView.qaMenuPresenter = nil
                    if presented?.items.isEmpty != false {
                        failures.append("[\(label), \(style.rawValue)] right-clicking the pinned icon did not open its header menu")
                    }
                } else {
                    failures.append("[\(label), \(style.rawValue)] no icon beside the pinned head")
                }
                canvas.setViewport(CanvasViewport(x: world.x - 120 / zoom, y: world.y - 100 / zoom, zoom: zoom))
                canvas.layoutSubtreeIfNeeded()
                spin(0.1)
                if tall.agentBubbleView !== iconView || tall.qaAgentBubble !== iconLayer || tall.agentBubbleFrame != atHeader {
                    failures.append("[\(label), \(style.rawValue)] unpinning did not restore the same icon to its real header")
                }
            }
            report.append("  \(label): same view/layer, live Inline/Orb/Squircle, fully visible, clickable, restored on unpin")
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
            try writeStills(tile: tall, canvas: canvas, window: window, settings: settings, to: URL(fileURLWithPath: directory))
            report.append("  stills written to \(directory)")
        }

        // The setting off: today's jump.
        settings.set(false, forKey: AgentJumpConfig.composerFirstKey)
        canvas.setViewport(far)
        let tallNow = canvas.navigationTileSnapshot(for: tallTile)?.worldFrame ?? tallWorld
        let tallRect = CGRect(x: tallNow.x, y: tallNow.y, width: tallNow.width, height: tallNow.height)
        let oldJump = canvas.framedWorkViewport(for: tallRect, kind: .managedAgent)
        jump("setting off, tall tile", tile: tall, start: far, flies: false, how: { try clickRow(tallAgent) }) { camera in
            var problems: [String] = []
            if abs(camera.x - oldJump.x) > 0.5 || abs(camera.y - oldJump.y) > 0.5 || abs(camera.zoom - oldJump.zoom) > 0.0001 {
                problems.append("camera \(camera) is not the old jump's \(oldJump)")
            }
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

    /// A real drag through the window: drags and the release queued, then the press.
    private static func drag(from start: NSPoint, by delta: NSPoint, in window: NSWindow) throws {
        func mouse(_ type: NSEvent.EventType, _ point: NSPoint) throws -> NSEvent {
            guard let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                pressure: type == .leftMouseUp ? 0 : 1) else { throw Failure(description: "could not synthesise \(type)") }
            return event
        }
        let end = NSPoint(x: start.x + delta.x, y: start.y + delta.y)
        for step in 1...6 {
            let t = CGFloat(step) / 6
            NSApp.postEvent(try mouse(.leftMouseDragged, NSPoint(x: start.x + delta.x * t, y: start.y + delta.y * t)), atStart: false)
        }
        NSApp.postEvent(try mouse(.leftMouseUp, end), atStart: false)
        NSApp.sendEvent(try mouse(.leftMouseDown, start))
        while let pending = NSApp.nextEvent(matching: [.leftMouseUp, .leftMouseDragged], until: Date(), inMode: .default, dequeue: true) {
            NSApp.sendEvent(pending)
        }
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

    /// In-situ review stills, using the real icon setting at every requested
    /// zoom in both appearances. Captures the window server's own rendered
    /// canvas, including the icon's unclipped world-plane sibling view.
    private static func writeStills(tile: ManagedAgentTileNSView, canvas: CanvasNSView, window: NSWindow,
                                    settings: UserDefaults, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let originalCamera = canvas.viewport
        let originalStyle = settings.string(forKey: AgentCharacterConfig.bubbleStyleKey)
        let originalAppearance = window.appearance
        defer {
            if let originalStyle { settings.set(originalStyle, forKey: AgentCharacterConfig.bubbleStyleKey) }
            else { settings.removeObject(forKey: AgentCharacterConfig.bubbleStyleKey) }
            SettingChangeEvent.post(SettingID(rawValue: AgentCharacterConfig.bubbleStyleKey))
            canvas.setViewport(originalCamera)
            window.appearance = originalAppearance
        }
        guard let world = canvas.navigationTileSnapshot(for: tile.tile.id)?.worldFrame else {
            throw Failure(description: "stills: missing tile world frame")
        }
        for style in AgentCharacterConfig.BubbleStyle.allCases {
            settings.set(style.rawValue, forKey: AgentCharacterConfig.bubbleStyleKey)
            SettingChangeEvent.post(SettingID(rawValue: AgentCharacterConfig.bubbleStyleKey))
            for zoom in [0.30, 0.80, 1.25] {
                // Deliberately pan inside the tile even at 30%, where a whole
                // 2200-world tile could fit. This exercises the pinned state at
                // the requested zoom rather than letting jump framing alter it.
                canvas.setViewport(CanvasViewport(x: world.x - 100 / zoom, y: world.y + 400, zoom: zoom))
                canvas.layoutSubtreeIfNeeded()
                for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                    window.appearance = NSAppearance(named: appearance)
                    spin(0.4)
                    window.displayIfNeeded()
                    spin(0.2)
                    guard let head = tile.qaStickyHeadView, let icon = tile.agentBubbleView,
                          tile.qaAgentBubble?.bubbleStyle == style else {
                        throw Failure(description: "stills: missing pinned head/icon at \(zoom), \(style.rawValue)")
                    }
                    guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow,
                        CGWindowID(window.windowNumber), [.boundsIgnoreFraming]) else {
                        throw Failure(description: "no window image")
                    }
                    let scale = CGFloat(image.width) / window.frame.width
                    let header = head.convert(head.bounds, to: nil)
                    let plate = icon.convert(icon.bounds, to: nil)
                    let canvasRect = canvas.convert(canvas.bounds, to: nil)
                    let leading = min(header.minX, plate.minX) - 36
                    let trailing = min(canvasRect.maxX, header.maxX + 36)
                    let crop = NSRect(x: max(canvasRect.minX, leading), y: canvasRect.maxY - 180,
                                      width: trailing - max(canvasRect.minX, leading), height: 180)
                    let pixels = CGRect(x: crop.minX * scale, y: (window.frame.height - crop.maxY) * scale,
                                        width: crop.width * scale, height: crop.height * scale)
                    guard let cropped = image.cropping(to: pixels),
                          let data = NSBitmapImageRep(cgImage: cropped).representation(using: .png, properties: [:]) else {
                        throw Failure(description: "could not crop the still")
                    }
                    let percent = Int((zoom * 100).rounded())
                    try data.write(to: directory.appendingPathComponent("sticky-head-\(style.rawValue)-\(percent)-\(name).png"))
                }
            }
        }
    }
}
