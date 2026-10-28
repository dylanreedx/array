import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Foundation
import GhosttyKit

/// Session handoff (`.plans/79-session-handoff`), stream D — the witnesses for
/// one agent tile with two faces.
///
/// `--agent-face-switch-check`: the band's controls on a real agent tile in a
/// real canvas, clicked with real mouse events through the window at every
/// width, canvas zoom and page zoom the design names.
///
/// `--agent-face-flip-check`: the production flip, with a stand-in claude on
/// PATH and an isolated tmux server.
@MainActor
enum AgentFaceChecks {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String) throws {
        if !condition() { throw Failure(description: message()) }
    }

    static func runDirectory(_ name: String) throws -> URL {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("qa-runs", isDirectory: true)
            .appendingPathComponent("\(stamp)-\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // MARK: - Fixture

    /// A supervisor with one Claude Code agent and a real canvas in an
    /// off-screen window. Nothing here reads or writes `UserDefaults.standard`
    /// beyond what the canvas itself reads.
    @MainActor
    final class Fixture {
        let root: URL
        let work: URL
        let claudeHome: URL
        let bin: URL
        let supervisor: AgentSupervisor
        let agentID: AgentID
        let canvas: CanvasNSView
        let window: NSWindow
        let ghostty: GhosttyRuntimeContext
        let defaults: UserDefaults
        let suiteName: String
        var closeRequests: [UUID] = []

        init(windowSize: NSSize, ghostty: GhosttyRuntimeContext) throws {
            root = URL(fileURLWithPath: "/tmp", isDirectory: true)
                .appendingPathComponent("arr-face-\(UUID().uuidString.prefix(8))", isDirectory: true)
            work = root.appendingPathComponent("work", isDirectory: true)
            claudeHome = root.appendingPathComponent("home", isDirectory: true)
            bin = root.appendingPathComponent("bin", isDirectory: true)
            for directory in [work, claudeHome, bin] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            suiteName = "array.qa.agent-face.\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suiteName)!
            self.ghostty = ghostty
            AgentModelCatalog.shared.resetForQA(snapshot: AgentCatalogQAFixture.claude)
            supervisor = AgentSupervisor(
                store: AgentStore(applicationSupportDirectory: root.appendingPathComponent("support", isDirectory: true)),
                makeRunner: AgentSupervisor.productionRunner,
                submissionRecoveryStore: AgentComposerDraftStore(
                    applicationSupportDirectory: root.appendingPathComponent("support", isDirectory: true),
                    debounceInterval: 0),
                // The saved transcript a reopened tile reads its history from.
                transcriptStore: AgentTranscriptStore(root: root.appendingPathComponent("transcripts", isDirectory: true)))
            agentID = supervisor.spawn(
                role: nil, prompt: nil, cwd: work, harness: .claudeCode,
                model: "anthropic/claude-haiku-4-5-20251001", thinking: "low", displayName: "Fix login redirect")
            canvas = CanvasNSView(canvasState: CanvasState(
                viewport: CanvasViewport(x: 0, y: 0, zoom: 1), tiles: [], groups: [], lastActiveTileId: nil))
            canvas.focusBroker = FocusBroker()
            canvas.frame = NSRect(origin: .zero, size: windowSize)
            window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = canvas
            window.orderFrontOffscreenForChecks()
            canvas.onTileCloseRequested = { [weak self] id in self?.closeRequests.append(id) }
        }

        func environment(tmuxPath: String?, command: PiAgentRunner.ResolvedCommand) -> AgentTerminalFaceEnvironment {
            var environment = AgentTerminalFaceEnvironment(
                ghostty: ghostty, tmuxPath: tmuxPath, defaults: defaults, claudeHome: claudeHome)
            environment.claudeCommand = { command }
            environment.pollInterval = 0.3
            environment.confirm = { _, _ in true }
            return environment
        }

        /// A tile installed the way the canvas installs every tile view, and
        /// attached to the agent the way `wireManagedAgentTile` attaches it.
        func makeTile(width: Double, height: Double = 520, metadata: TileMetadata = TileMetadata(launchProfileId: "managed"),
                      id: UUID = UUID(), environment: AgentTerminalFaceEnvironment?) -> ManagedAgentTileNSView {
            let tile = Tile(
                id: id, kind: .managedAgent, title: "Fix login redirect",
                frame: TileFrame(x: 40, y: 40, width: width, height: height),
                zPosition: .fromLegacyRank(1), runtimeRef: nil, metadata: metadata)
            let view = ManagedAgentTileNSView(tile: tile)
            canvas.install(tileView: view, for: tile)
            view.terminalFaceEnvironment = environment
            view.attach(agentID: agentID, supervisor: supervisor)
            return view
        }

        func pump(_ seconds: TimeInterval) {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                if let app = try? ghostty.app { ghostty_app_tick(app) }
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }
        }

        @discardableResult
        func pump(until condition: () -> Bool, timeout: TimeInterval) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if condition() { return true }
                if let app = try? ghostty.app { ghostty_app_tick(app) }
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }
            return condition()
        }

        func tearDown() {
            supervisor.stopAll()
            window.orderOut(nil)
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// A real click: down and up through the window, so `hitTest`, the band's
    /// own routing and each control's tracking loop all run.
    static func click(_ windowPoint: NSPoint, in window: NSWindow, right: Bool = false) throws {
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            guard let event = NSEvent.mouseEvent(
                with: type, location: windowPoint, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
            else { throw Failure(description: "could not create \(type)") }
            return event
        }
        if right {
            window.sendEvent(try event(.rightMouseDown))
            window.sendEvent(try event(.rightMouseUp))
            return
        }
        // Controls track their own mouse-up with `nextEvent`: queue it first.
        NSApplication.shared.postEvent(try event(.leftMouseUp), atStart: false)
        window.sendEvent(try event(.leftMouseDown))
        // A control that acts on mouse-down (⋯) leaves the up queued; deliver
        // it now, as the system would, so it cannot satisfy the next click's
        // tracking loop at the wrong place.
        while let pending = NSApplication.shared.nextEvent(
            matching: [.leftMouseUp], until: Date(), inMode: .default, dequeue: true) {
            window.sendEvent(pending)
        }
    }

    static func windowPoint(of rect: NSRect, in view: NSView) -> NSPoint {
        view.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
    }

    /// A stand-in claude that just waits: the switch check only needs a live
    /// surface to flip into and out of.
    static func installWaitingClaude(in bin: URL) throws -> PiAgentRunner.ResolvedCommand {
        let script = bin.appendingPathComponent("claude")
        try "#!/bin/sh\nexec /bin/sleep 600\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return PiAgentRunner.ResolvedCommand(executable: script.path, prefixArgs: [])
    }

    static func savePNG(of view: NSView, rect: NSRect, to url: URL) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: rect) else { return }
        view.cacheDisplay(in: rect, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// The window's own pixels, compositor included — a Ghostty surface draws
    /// through Metal, which `cacheDisplay` cannot see. Own-window capture
    /// needs no Screen Recording grant.
    static func saveWindowPNG(_ window: NSWindow, to url: URL) {
        guard let image = CGWindowListCreateImage(
            .null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution])
        else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    // MARK: - --agent-face-switch-check

    static func runSwitch() throws -> String {
        let ghostty = try GhosttyRuntimeContext()
        defer { ghostty.shutdown() }
        let fixture = try Fixture(windowSize: NSSize(width: 2200, height: 1400), ghostty: ghostty)
        defer { fixture.tearDown() }
        let command = try installWaitingClaude(in: fixture.bin)
        let environment = fixture.environment(tmuxPath: nil, command: command)
        let directory = try runDirectory("agent-face-switch")
        var presented: [NSMenu] = []
        TileNSView.qaMenuPresenter = { presented.append($0) }
        defer { TileNSView.qaMenuPresenter = nil }

        var rows: [[String: Any]] = []
        var lines: [String] = []
        var liveViews: [ManagedAgentTileNSView] = []
        defer {
            // Every surface detached before the Ghostty context is freed.
            for view in liveViews where view.face == .terminal { view.prepareForRemovalFromScene() }
        }
        guard let toggleField = SettingsSchema.sections().first(where: { $0.id == "agents" })?.fields.first(where: {
            $0.key == AgentTerminalFaceConfig.showToggleKey
        }) else { throw Failure(description: "Agents settings must offer a way to hide the Terminal toggle") }
        let settings = SettingsModel(defaults: fixture.defaults, navKeymap: .default)
        do {
            let view = fixture.makeTile(width: 900, environment: environment)
            liveViews.append(view)
            try expect(view.face == .array, "a new tile must start in chat")
            try expect(settings.value(of: toggleField) == .bool(true), "the compact toggle is discoverable by default")
            settings.write(.bool(false), to: toggleField)
            view.layoutSubtreeIfNeeded()
            try expect(view.qaFaceSwitchMode == "hidden" && view.face == .array,
                       "hiding the toggle must update an existing tile without switching faces")
            let reopened = fixture.makeTile(width: 900, environment: environment)
            liveViews.append(reopened)
            reopened.layoutSubtreeIfNeeded()
            try expect(reopened.qaFaceSwitchMode == "hidden", "new tiles must honor the saved hide preference")
            fixture.canvas.removeTile(id: reopened.tile.id)
            // The same action used by the keyboard shortcut remains available.
            try expect(view.toggleFace() && view.face == .terminal, "hiding the icon must preserve the face action")
            view.layoutSubtreeIfNeeded()
            try expect(view.qaFaceSwitchMode == "icon", "the active Terminal view must retain its return toggle")
            try expect(view.toggleFace() && fixture.pump(until: { view.face == .array }, timeout: 3),
                       "the hidden-toggle preference must still allow returning to chat")
            view.layoutSubtreeIfNeeded()
            try expect(view.qaFaceSwitchMode == "hidden", "returning to chat must restore the hidden preference")
            settings.reset(toggleField)
            view.layoutSubtreeIfNeeded()
            try expect(view.qaFaceSwitchMode == "icon", "resetting the preference must restore the icon immediately")
            fixture.canvas.removeTile(id: view.tile.id)
            lines.append("toggle preference: live hide, saved hide, action still available, active return, reset")
        }
        for width in [320.0, 480.0, 900.0] {
            for zoom in [0.1, 0.3, 1.0, 2.0] {
                for page in [80, 150] {
                    let label = "w\(Int(width)) z\(zoom) p\(page)"
                    let view = fixture.makeTile(width: width, environment: environment)
                    liveViews.append(view)
                    view.setPageZoom(AgentPageZoom(percent: page))
                    view.agentStatus = .working
                    fixture.canvas.setViewport(CanvasViewport(x: 0, y: 0, zoom: zoom))
                    fixture.window.contentView?.layoutSubtreeIfNeeded()
                    view.layoutSubtreeIfNeeded()
                    fixture.pump(0.02)

                    let controls = view.qaBandControlFrames
                    let names = controls.map(\.name)
                    try expect(names.contains("close"), "\(label): × must always be in the band; got \(names)")
                    // No two controls overlap, and every one keeps its floor.
                    for (index, a) in controls.enumerated() {
                        for b in controls.dropFirst(index + 1) {
                            try expect(!a.frame.intersects(b.frame),
                                       "\(label): \(a.name) \(a.frame) overlaps \(b.name) \(b.frame)")
                        }
                        try expect(a.frame.minX >= -0.5 && a.frame.maxX <= width + 0.5,
                                   "\(label): \(a.name) \(a.frame) leaves the band")
                        try expect(a.frame.height * zoom >= TileNSView.minScreenCloseButtonPx - 0.5
                                   && a.frame.width * zoom >= TileNSView.minScreenCloseButtonPx - 0.5,
                                   "\(label): \(a.name) is \(a.frame.size) world = \(a.frame.width * zoom)×\(a.frame.height * zoom)px on screen, under the 22px floor")
                    }
                    let mode = view.qaFaceSwitchMode
                    try expect(mode != "labels", "\(label): the face switch must never reserve room for text labels")
                    let faceControls = controls.filter { $0.name.hasPrefix("face.") }
                    try expect(faceControls.count <= 1, "\(label): switching faces must use a single icon toggle, got \(faceControls.map(\.name))")
                    if let toggle = faceControls.first {
                        try expect(abs(toggle.frame.width - toggle.frame.height) < 0.5,
                                   "\(label): the face toggle must take one square button slot")
                    }
                    try expect(view.face == .array, "\(label): new tiles must start in chat")
                    var outcome: [String: String] = [:]

                    // × closes.
                    let closesBefore = fixture.closeRequests.count
                    let close = controls.first { $0.name == "close" }!.frame
                    try click(windowPoint(of: close, in: view), in: fixture.window)
                    let closePoint = windowPoint(of: close, in: view)
                    try expect(fixture.closeRequests.count == closesBefore + 1,
                               "\(label): a click on × did not close the tile; hit \(String(describing: fixture.window.contentView?.hitTest(closePoint))) at \(closePoint), × \(close), controls \(controls)")
                    outcome["close"] = "closed"

                    // ⋯ opens the tile menu, which offers the switch.
                    func switchItem(in menu: NSMenu) -> NSMenuItem? {
                        menu.items.first { $0.identifier?.rawValue == "agentTile.switchFace" }
                    }
                    let presentedBefore = presented.count
                    if let actions = controls.first(where: { $0.name == "actions" })?.frame {
                        try click(windowPoint(of: actions, in: view), in: fixture.window)
                        try expect(presented.count == presentedBefore + 1, "\(label): a click on ⋯ opened no menu")
                        outcome["actions"] = "menu"
                    } else {
                        // ⋯ left the band; the band's context menu is the same menu.
                        let bar = view.qaTitleBarFrame
                        // Left of every control: the band's own grab strip.
                        let leftmost = controls.map(\.frame.minX).min() ?? bar.width
                        let bandPoint = NSRect(x: min(bar.width * 0.3, leftmost / 2), y: bar.midY, width: 0, height: 0)
                        try click(windowPoint(of: bandPoint, in: view), in: fixture.window, right: true)
                        try expect(presented.count == presentedBefore + 1, "\(label): right-clicking the band opened no menu")
                        outcome["actions"] = "band menu"
                    }
                    try expect(presented.last.flatMap(switchItem)?.title == "Switch to Terminal",
                               "\(label): the tile menu must offer Switch to Terminal; got \(presented.last?.items.map(\.title) ?? [])")

                    if mode == "hidden" {
                        // Reachable all the same: the menu item flips the tile.
                        guard let menu = presented.last, let item = switchItem(in: menu) else { throw Failure(description: "\(label): no switch item") }
                        menu.performActionForItem(at: menu.index(of: item))
                        try expect(view.face == .terminal, "\(label): Switch to Terminal from the menu did not flip the tile")
                        let back = view.titleBarContextMenuForQA()
                        guard let backItem = switchItem(in: back), backItem.title == "Switch to Array" else {
                            throw Failure(description: "\(label): in the Terminal face the menu must offer Switch to Array")
                        }
                        back.performActionForItem(at: back.index(of: backItem))
                        try expect(fixture.pump(until: { view.face == .array }, timeout: 3),
                                   "\(label): Switch to Array from the menu did not flip back")
                        outcome["switch"] = "menu only"
                    } else {
                        let toggle = controls.first { $0.name == "face.toggle" }!.frame
                        try click(windowPoint(of: toggle, in: view), in: fixture.window)
                        try expect(view.face == .terminal, "\(label): a click on the Terminal toggle did not flip the tile (mode \(mode))")
                        fixture.pump(0.05)
                        let terminalControls = view.qaBandControlFrames
                        try expect(terminalControls.map(\.name) == names,
                                   "\(label): the band changed shape in the Terminal face: \(terminalControls.map(\.name))")
                        try click(windowPoint(of: toggle, in: view), in: fixture.window)
                        try expect(fixture.pump(until: { view.face == .array }, timeout: 3),
                                   "\(label): a click on the chat toggle did not flip back")
                        outcome["switch"] = "toggled in and out"
                    }
                    if zoom == 1, page == 80 {
                        let band = NSRect(x: 0, y: 0, width: width, height: 28)
                        savePNG(of: view, rect: band, to: directory.appendingPathComponent("band-\(Int(width)).png"))
                    }
                    rows.append(["width": width, "zoom": zoom, "page": page, "mode": mode,
                                 "pill": view.qaBandShowsStatusPill,
                                 "controls": controls.map { "\($0.name)=\(NSStringFromRect($0.frame))" },
                                 "outcome": outcome])
                    lines.append("\(label): \(mode)\(view.qaBandShowsStatusPill ? "+pill" : "") \(names.joined(separator: ",")) \(outcome.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
                    fixture.canvas.removeTile(id: view.tile.id)
                }
            }
        }
        // performance.md: no measurement inside `layout()`. The band lays out
        // on every zoom frame; its labels' widths are measured once, ever.
        do {
            let view = fixture.makeTile(width: 900, environment: environment)
            liveViews.append(view)
            view.agentStatus = .working
            fixture.canvas.setViewport(CanvasViewport(x: 0, y: 0, zoom: 1))
            fixture.window.contentView?.layoutSubtreeIfNeeded()
            view.layoutSubtreeIfNeeded()
            let measured = BandTextWidth.qaMeasurements
            let passes = view.qaTitleBarLayoutPasses
            for zoom in stride(from: 0.4, through: 1.9, by: 0.05) {
                fixture.canvas.setViewport(CanvasViewport(x: 0, y: 0, zoom: zoom))
                fixture.window.contentView?.layoutSubtreeIfNeeded()
                view.layoutSubtreeIfNeeded()
            }
            let laidOut = view.qaTitleBarLayoutPasses - passes
            let remeasured = BandTextWidth.qaMeasurements - measured
            try expect(view.qaFaceSwitchMode == "icon" && laidOut >= 5 && remeasured == 0,
                       "a pinch must lay the band out without measuring its labels: \(laidOut) layouts measured \(remeasured) times (mode \(view.qaFaceSwitchMode))")
            lines.append("band layout: \(laidOut) zoom-frame layouts, \(remeasured) label measurements")
            fixture.canvas.removeTile(id: view.tile.id)
        }
        // Codex and Pi have no Terminal face: no switch, no menu item.
        for (harness, model) in [(AgentHarness.codex, "openai-codex/gpt-5.6-sol"), (.pi, "openai-codex/gpt-5.6-sol")] {
            let other = fixture.supervisor.spawn(role: nil, prompt: nil, cwd: fixture.work, harness: harness, model: model, thinking: "low")
            let tile = Tile(id: UUID(), kind: .managedAgent, title: "other", frame: TileFrame(x: 40, y: 40, width: 900, height: 520),
                            zPosition: .fromLegacyRank(1), runtimeRef: nil, metadata: TileMetadata(launchProfileId: "managed"))
            let view = ManagedAgentTileNSView(tile: tile)
            fixture.canvas.install(tileView: view, for: tile)
            view.terminalFaceEnvironment = environment
            view.attach(agentID: other, supervisor: fixture.supervisor)
            fixture.canvas.setViewport(CanvasViewport(x: 0, y: 0, zoom: 1))
            view.layoutSubtreeIfNeeded()
            try expect(view.qaBandControlFrames.allSatisfy { !$0.name.hasPrefix("face.") } && !view.toggleFace()
                       && !view.titleBarContextMenuForQA().items.contains { $0.identifier?.rawValue == "agentTile.switchFace" },
                       "a \(harness.rawValue) agent must show no Terminal face switch")
            lines.append("\(harness.rawValue): no switch")
            fixture.canvas.removeTile(id: tile.id)
        }
        // Every supported width uses the same compact icon at normal zoom.
        func modeAt(_ width: Double) -> String? {
            rows.first { ($0["width"] as? Double) == width && ($0["zoom"] as? Double) == 1 }?["mode"] as? String
        }
        try expect([900.0, 480.0, 320.0].allSatisfy { modeAt($0) == "icon" },
                   "at zoom 1 every supported width must show one icon; got \(modeAt(900) ?? "-"), \(modeAt(480) ?? "-"), \(modeAt(320) ?? "-")")
        // Live status labels can wrap a delegation onto several lines. Native
        // hitTest points are in the receiver's SUPERview coordinates, including
        // a nonzero row origin and each wrapped capsule's origin.
        let chipRoot = NSView(frame: fixture.canvas.bounds)
        fixture.window.contentView = chipRoot
        defer { fixture.window.contentView = fixture.canvas }
        let chipRow = AgentReferenceChipRowView(frame: NSRect(x: 130, y: 180, width: 220, height: 120))
        chipRoot.addSubview(chipRow)
        let parentID = UUID()
        let chipIDs = (0..<3).map { _ in UUID() }
        var revealed: [UUID] = []
        let chipContext = AgentRenderContext(actions: AgentRenderActions { action in
            if case let .revealAgent(_, id, _) = action { revealed.append(id) }
        }, tokens: .transcript, appearance: .dark)
        let references = chipIDs.enumerated().map { index, id in
            AgentReferenceChipRowView.Reference(blockID: AgentNodeID(rawValue: "wrapped-chip-\(index)")!,
                payload: AgentReferencePayload(agentID: id, parentAgentID: parentID,
                    displayNameAtSpawn: "Working helper number \(index)", spawnedAt: Date(), provider: "Claude Code"))
        }
        chipRow.apply(leaderID: references[0].blockID, references: references, context: chipContext)
        chipRow.layoutSubtreeIfNeeded()
        try expect(Set(chipRow.chips.map { $0.frame.minY }).count == 3, "the fixture must wrap its chips onto three lines")
        for chip in chipRow.chips {
            let point = chip.convert(NSPoint(x: chip.bounds.midX, y: chip.bounds.midY), to: nil)
            let rootPoint = chipRoot.convert(point, from: nil)
            try expect(chipRoot.hitTest(rootPoint) === chip, "a wrapped chip's centre must hit that chip")
            try click(point, in: fixture.window)
        }
        try expect(revealed == chipIDs, "each wrapped chip must reveal its own child exactly once; got \(revealed)")
        lines.append("wrapped child chips: three native clicks revealed the matching children")

        let data = try JSONSerialization.data(withJSONObject: ["rows": rows], options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent("manifest.json"))
        return (lines + ["agent face switch: \(rows.count) configurations clicked, artifacts \(directory.path)"])
            .joined(separator: "\n")
    }
}

// MARK: - --agent-face-flip-check

extension AgentFaceChecks {
    /// The stand-in claude for the flip. `-p` (the managed runner's argv) runs
    /// the reactive stream fake; anything else is the interactive TUI: it
    /// records how it was launched, keeps `~/.claude/sessions/<pid>.json` the
    /// way claude does, and writes each turn typed at it into the session file.
    /// `/model X`, `/clear` and `/exit` behave as claude's do; a line holding
    /// "slow" keeps the turn busy for 3s.
    static let interactiveClaude = #"""
    #!/usr/bin/env python3
    import json, os, sys, time, uuid
    HERE = os.path.dirname(os.path.abspath(__file__))
    argv = sys.argv[1:]
    if "-p" in argv:
        stream = os.path.join(HERE, "claude-stream")
        os.execv(stream, [stream] + argv)
    def value(flag):
        return argv[argv.index(flag) + 1] if flag in argv else None
    sid = value("--resume") or value("--session-id")
    model = value("--model")
    home = open(os.path.join(HERE, "home.txt")).read().strip()
    session_dir = open(os.path.join(HERE, "session-dir.txt")).read().strip()
    stream_pid = None
    try:
        stream_pid = int(open(os.path.join(HERE, "pid.txt")).read().strip())
    except Exception:
        pass
    def alive(pid):
        try:
            os.kill(pid, 0)
            return True
        except Exception:
            return False
    launches = os.path.join(HERE, "terminal-launches.jsonl")
    with open(launches, "a") as f:
        f.write(json.dumps({"argv": argv, "pid": os.getpid(), "cwd": os.getcwd(),
            "ARRAY_AGENT_ID": os.environ.get("ARRAY_AGENT_ID"),
            "ARRAY_AGENT_FACE": os.environ.get("ARRAY_AGENT_FACE"),
            "CONTINUUM_ARRAY_MANAGED_AGENT": os.environ.get("CONTINUUM_ARRAY_MANAGED_AGENT"),
            "stream_pid": stream_pid, "stream_alive": alive(stream_pid) if stream_pid else False}) + "\n")
    sessions = os.path.join(home, ".claude", "sessions")
    os.makedirs(sessions, exist_ok=True)
    os.makedirs(session_dir, exist_ok=True)
    me = os.path.join(sessions, "%d.json" % os.getpid())
    def status(state):
        with open(me + ".tmp", "w") as f:
            json.dump({"pid": os.getpid(), "sessionId": sid, "cwd": os.getcwd(), "status": state,
                       "kind": "interactive", "entrypoint": "cli"}, f)
        os.replace(me + ".tmp", me)
    def append(obj):
        with open(os.path.join(session_dir, sid + ".jsonl"), "a") as f:
            f.write(json.dumps(obj) + "\n")
    if "--fork-session" in argv:
        # A fork: a new session, starting as a copy of the one it resumed. The
        # source file is never written.
        source = os.path.join(session_dir, sid + ".jsonl")
        sid = str(uuid.uuid4())
        if os.path.exists(source):
            for line in open(source):
                if line.strip():
                    obj = json.loads(line)
                    obj["sessionId"] = sid
                    append(obj)
    status("idle")
    print("FAKE CLAUDE resumed %s on %s" % (sid, model), flush=True)
    while True:
        line = sys.stdin.readline()
        if not line:
            break
        text = line.strip()
        if not text:
            continue
        if text == "/exit":
            break
        if text == "/clear":
            sid = str(uuid.uuid4())
            status("idle")
            print("cleared, now %s" % sid, flush=True)
            continue
        if text.startswith("/model "):
            model = text.split(" ", 1)[1]
            print("model %s" % model, flush=True)
            continue
        status("busy")
        append({"type": "user", "isSidechain": False, "uuid": str(uuid.uuid4()), "sessionId": sid,
                "message": {"role": "user", "content": text}})
        time.sleep(3 if "slow" in text else 0.6)
        append({"type": "assistant", "isSidechain": False, "uuid": str(uuid.uuid4()), "sessionId": sid,
                "message": {"role": "assistant", "model": model,
                            "content": [{"type": "text", "text": "terminal: " + text}]}})
        status("idle")
        print("done: %s" % text, flush=True)
    try:
        os.remove(me)
    except Exception:
        pass
    """#

    static func runFlip() throws -> String {
        guard case let .ready(tmuxPath, socketDir, socketPath) = TmuxIsolation.resolve() else {
            throw Failure(description: "tmux is not isolated: run with TMUX_TMPDIR set to a fresh dir under /tmp and TMUX unset")
        }
        let ghostty = try GhosttyRuntimeContext()
        defer { ghostty.shutdown() }
        let fixture = try Fixture(windowSize: NSSize(width: 1000, height: 760), ghostty: ghostty)
        defer { fixture.tearDown() }
        let directory = try runDirectory("agent-face-flip")
        var log: [String] = ["tmux socket \(socketPath) (namespace \(socketDir))"]

        // The fakes: the managed runner and the Terminal face both resolve
        // `claude` from PATH, exactly as production does.
        let stream = try AgentSteeringQAFakes.install(.claude, in: fixture.bin)
        try FileManager.default.moveItem(at: stream, to: fixture.bin.appendingPathComponent("claude-stream"))
        let claude = fixture.bin.appendingPathComponent("claude")
        try interactiveClaude.write(to: claude, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude.path)
        let originalPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        setenv("PATH", "\(fixture.bin.path):\(originalPath)", 1)
        defer { setenv("PATH", originalPath, 1) }
        try expect(ClaudeAgentRunner.liveResolvedCommand().executable == claude.path,
                   "the fake claude must be the one production resolves; got \(ClaudeAgentRunner.liveResolvedCommand())")

        let supervisor = fixture.supervisor
        let agentID = fixture.agentID
        let sessionId = AgentSupervisor.claudeSessionId(for: agentID)
        guard let record = supervisor.records[agentID] else { throw Failure(description: "no agent record") }
        let sessionURL = ClaudeTerminalFace.sessionFileURL(
            claudeHome: fixture.claudeHome, cwd: record.lastObservedWhere, sessionId: sessionId)
        try fixture.claudeHome.path.write(to: fixture.bin.appendingPathComponent("home.txt"), atomically: true, encoding: .utf8)
        try sessionURL.deletingLastPathComponent().path.write(
            to: fixture.bin.appendingPathComponent("session-dir.txt"), atomically: true, encoding: .utf8)
        func launches() -> [[String: Any]] {
            let text = (try? String(contentsOf: fixture.bin.appendingPathComponent("terminal-launches.jsonl"), encoding: .utf8)) ?? ""
            return text.split(separator: "\n").compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
        }
        func tmuxSessionAlive(_ tileId: UUID) -> Bool {
            (try? ProcessTmuxControl(tmuxPath: tmuxPath, defaults: fixture.defaults)
                .run(["has-session", "-t", TmuxSession.sessionName(tileId: tileId)])) != nil
        }

        var environment = AgentTerminalFaceEnvironment(
            ghostty: ghostty, tmuxPath: tmuxPath, defaults: fixture.defaults, claudeHome: fixture.claudeHome)
        environment.pollInterval = 0.25
        var confirmations: [String] = []
        var confirmAnswer = false
        environment.confirm = { message, _ in confirmations.append(message); return confirmAnswer }
        let view = fixture.makeTile(width: 760, height: 560, environment: environment)
        var liveViews = [view]
        defer { for v in liveViews where v.face == .terminal { v.prepareForRemovalFromScene() } }
        fixture.window.contentView?.layoutSubtreeIfNeeded()
        view.layoutSubtreeIfNeeded()
        func segment(_ name: String, of tile: ManagedAgentTileNSView) throws -> NSPoint {
            guard let frame = tile.qaBandControlFrames.first(where: { $0.name == name })?.frame else {
                throw Failure(description: "the band shows no \(name); controls \(tile.qaBandControlFrames.map(\.name))")
            }
            return windowPoint(of: frame, in: tile)
        }
        /// A real click on a band control, at the band's current layout.
        func clickSegment(_ name: String, of tile: ManagedAgentTileNSView) throws {
            // Several fixture tiles share the same frame; click the intended one.
            fixture.canvas.bringToFront(tileId: tile.tile.id)
            fixture.window.contentView?.layoutSubtreeIfNeeded()
            tile.layoutSubtreeIfNeeded()
            try click(try segment(name, of: tile), in: fixture.window)
        }
        func entriesText(_ tile: ManagedAgentTileNSView) -> [String] {
            tile.qaDocumentForChecks.entries.map { AgentTranscriptCopyController.plainText(for: $0.blocks) }
        }

        // 1. A turn in the Array face, on the managed runner. Claude wrote it
        //    to the session file, as the real CLI does.
        try expect(supervisor.send("PLAIN first question", to: agentID), "the Array-face turn was refused")
        try expect(fixture.pump(until: { !supervisor.isRunning(agentID) && supervisor.qaHasIdleSession(agentID) }, timeout: 15),
                   "the Array-face turn must finish and leave its claude pooled")
        guard let streamPid = AgentSteeringQAFakes.latestPid(in: fixture.bin), kill(streamPid, 0) == 0 else {
            throw Failure(description: "the pooled managed claude must be alive before the flip")
        }
        let prior = [
            #"{"type":"user","isSidechain":false,"uuid":"u-1","message":{"role":"user","content":"PLAIN first question"}}"#,
            #"{"type":"assistant","isSidechain":false,"uuid":"a-1","message":{"role":"assistant","model":"claude-haiku-4-5-20251001","content":[{"type":"text","text":"ok"}]}}"#,
        ]
        try FileManager.default.createDirectory(at: sessionURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (prior.joined(separator: "\n") + "\n").write(to: sessionURL, atomically: true, encoding: .utf8)
        view.qaSetComposerDraftForChecks("a draft that stays")
        let draftBefore = view.qaComposerDraftText

        // 2. Busy: a queued message blocks the flip; then the flip waits for the
        //    turn, Cancel drops it, and Stop now ends the turn and flips.
        try expect(supervisor.send("LONG second", to: agentID), "the long turn was refused")
        try expect(fixture.pump(until: { supervisor.isRunning(agentID) }, timeout: 5), "the long turn never started")
        var queued: IntentAcceptance?
        Task { @MainActor in queued = await supervisor.accept(.queue(AgentPrompt("queued one")), for: agentID) }
        try expect(fixture.pump(until: { queued != nil }, timeout: 3) && queued == .accepted, "queueing failed: \(String(describing: queued))")
        try click(try segment("face.toggle", of: view), in: fixture.window)
        try expect(view.face == .array && !view.pendingTerminalFlip,
                   "a queued message must block the flip, not wait on it")
        // The refusal is news about the click: the banner slot, for a few
        // seconds, and never an entry in the transcript or its saved copy.
        let refusal = "Send or clear the queued messages first."
        try expect(view.qaFaceFlipBannerVisible && view.qaFaceFlipBanner.content == .refusal(refusal),
                   "the refusal must show in the banner slot; banner \(String(describing: view.qaFaceFlipBanner.content))")
        func mentionsRefusal(_ document: AgentDocument?) -> Bool {
            (document?.entries ?? []).contains { AgentTranscriptCopyController.plainText(for: $0.blocks).contains(refusal) }
        }
        try expect(!mentionsRefusal(view.qaDocumentForChecks) && !mentionsRefusal(supervisor.transcriptDocumentProjection(for: agentID)),
                   "a refused flip must not write the refusal into the transcript")
        try expect(fixture.pump(until: { !view.qaFaceFlipBannerVisible }, timeout: AgentFaceFlipBanner.refusalDuration + 2),
                   "the refusal must go by itself")
        log.append("refusal: banner for a few seconds, never in the transcript")
        supervisor.clearQueuedMessages(for: agentID)
        try click(try segment("face.toggle", of: view), in: fixture.window)
        try expect(view.pendingTerminalFlip && view.qaFaceFlipBannerVisible && view.face == .array,
                   "a flip mid-turn must wait, with the banner up")
        try click(try segment("face.toggle", of: view), in: fixture.window)
        try expect(!view.pendingTerminalFlip && !view.qaFaceFlipBannerVisible,
                   "clicking the pending toggle again must cancel the switch")
        try click(try segment("face.toggle", of: view), in: fixture.window)
        try expect(view.pendingTerminalFlip, "the toggle must request Terminal again after cancellation")
        fixture.window.contentView?.layoutSubtreeIfNeeded()
        saveWindowPNG(fixture.window, to: directory.appendingPathComponent("face-array-flip-waiting.png"))
        fixture.pump(1.0)
        try expect(view.face == .array && launches().isEmpty && !tmuxSessionAlive(view.tile.id),
                   "while the turn runs, no terminal may start")
        let banner = view.qaFaceFlipBanner
        // Where the buttons are DRAWN: an idle tile rests, its body (banner
        // included) drawn from a hidden host window, and a press there wakes it.
        func drawnPoint(_ button: NSView) throws -> NSPoint {
            guard let rect = view.qaPresentedRect(of: button) else {
                throw Failure(description: "the tile does not present the banner's \(button)")
            }
            return windowPoint(of: rect, in: view)
        }
        try click(try drawnPoint(banner.cancelButton), in: fixture.window)
        try expect(!view.pendingTerminalFlip && !view.qaFaceFlipBannerVisible, "Cancel must drop the waiting flip")
        try click(try segment("face.toggle", of: view), in: fixture.window)
        try expect(view.pendingTerminalFlip, "the flip must wait again")
        try click(try drawnPoint(banner.stopButton), in: fixture.window)
        try expect(fixture.pump(until: { view.face == .terminal }, timeout: 15),
                   "Stop now must end the turn and flip to the Terminal face")
        log.append("busy flip: waited, cancelled, stopped, flipped")

        // 3. One writer: the managed claude was gone before the TUI started,
        //    and the TUI carries the agent's tags and the record's model.
        try expect(fixture.pump(until: { !launches().isEmpty }, timeout: 10), "the Terminal face never launched claude")
        let launch = launches()[0]
        try expect(launch["stream_alive"] as? Bool == false && kill(streamPid, 0) != 0,
                   "the managed claude (pid \(streamPid)) must be stopped before the Terminal face starts; launch \(launch)")
        try expect(!supervisor.qaHasIdleSession(agentID) && supervisor.isInTerminalFace(agentID),
                   "the supervisor must have released its runner and hold the session for the Terminal face")
        try expect(launch["ARRAY_AGENT_ID"] as? String == AgentProcessAttribution.ownerTag(for: agentID)
                   && launch["ARRAY_AGENT_FACE"] as? String == "terminal"
                   && launch["CONTINUUM_ARRAY_MANAGED_AGENT"] as? String == "1",
                   "the terminal claude must carry ARRAY_AGENT_ID, ARRAY_AGENT_FACE=terminal and the managed marker; got \(launch)")
        let argv = launch["argv"] as? [String] ?? []
        try expect(argv.starts(with: ["--resume", sessionId]) && argv.contains("claude-haiku-4-5-20251001"),
                   "the terminal claude must resume the agent's session on its model; argv \(argv)")
        try expect(supervisor.sendRefusal(for: agentID) != nil, "the supervisor must refuse sends while the Terminal face holds the session")
        try expect(fixture.canvas.tileRecord(for: view.tile.id)?.metadata.agentTerminalFace?.sessionId == sessionId,
                   "the canvas must persist the Terminal face")
        let before = entriesText(view)
        log.append("terminal launched: argv \(argv.joined(separator: " "))")

        // 4. Work in the terminal: a busy turn, /model, /clear, another turn.
        guard let session = view.terminalFaceSession else { throw Failure(description: "no terminal session") }
        func type(_ text: String) {
            _ = session.runtime.dispatchInsertedText(text)
            session.runtime.sendReturn()
        }
        try expect(fixture.pump(until: { session.claudePid != nil }, timeout: 8), "the face never found claude's pid")
        type("/model claude-sonnet-5-5")
        type("slow third")
        try expect(fixture.pump(until: { session.isBusy }, timeout: 6), "the face must read claude's busy status")
        // The band's pill and the sidebar row read the turn snapshot, which the
        // face's poll keeps from claude's own status file.
        try expect(fixture.pump(until: { supervisor.turnSnapshot(for: agentID)?.state == .working && view.agentStatus == .working },
                                timeout: 3),
                   "while claude is busy the pill must say Working; snapshot \(String(describing: supervisor.turnSnapshot(for: agentID)?.state)), pill \(String(describing: view.agentStatus))")
        let pillWorking = view.qaBandShowsStatusPill
        // × on a busy terminal asks first; refusing keeps everything.
        try click(try segment("close", of: view), in: fixture.window)
        try expect(confirmations.count == 1 && view.face == .terminal && fixture.closeRequests.isEmpty,
                   "× on a busy terminal must ask, and Cancel must keep the tile and claude; asked \(confirmations)")
        try expect(fixture.pump(until: { !session.isBusy }, timeout: 8), "the slow turn never ended")
        try expect(fixture.pump(until: { view.agentStatus != .working && supervisor.turnSnapshot(for: agentID)?.state != .working }, timeout: 3),
                   "once claude is idle the pill must stop saying Working; pill \(String(describing: view.agentStatus))")
        log.append("terminal pill: working while claude was busy (pill in band: \(pillWorking)), idle after")
        type("/clear")
        try expect(fixture.pump(until: { session.sessionIds.count == 2 }, timeout: 8),
                   "/clear must move the face to claude's new session; ids \(session.sessionIds)")
        let clearedId = session.currentSessionId
        type("fourth")
        fixture.pump(1.5)
        saveWindowPNG(fixture.window, to: directory.appendingPathComponent("face-terminal.png"))

        // 5. /exit flips back, never closes; the terminal's turns append once,
        //    read off the main thread (review #12).
        let readsBeforeExit = QAMainThreadIO.fileReads
        type("/exit")
        try expect(fixture.pump(until: { view.face == .array }, timeout: 10), "/exit must flip the tile back to the Array face")
        try expect(fixture.closeRequests.isEmpty && fixture.canvas.tileView(for: view.tile.id) === view,
                   "/exit must never close the tile")
        try expect(QAMainThreadIO.fileReads == readsBeforeExit,
                   "the flip back must read the session file off the main thread; \(QAMainThreadIO.fileReads - readsBeforeExit) reads on main")
        try expect(!tmuxSessionAlive(view.tile.id), "claude's tmux session must be gone after /exit")
        let after = entriesText(view)
        try expect(Array(after.prefix(before.count)) == before,
                   "the transcript from before the flip must be unchanged")
        let added = Array(after.dropFirst(before.count))
        let joined = added.joined(separator: "\n")
        try expect(added.first?.contains("In Terminal · 2 turns") == true,
                   "the terminal's turns must follow an 'In Terminal · 2 turns' divider; got \(added)")
        let dividerEntry = view.qaDocumentForChecks.entries[before.count]
        try expect(dividerEntry.blocks.map(\.kind) == [.sessionBoundary]
                   && !view.qaDocumentForChecks.entries.contains { $0.blocks.contains { $0.kind == .notice } && AgentTranscriptCopyController.plainText(for: $0.blocks).contains("In Terminal") },
                   "the divider must be a session boundary, not a notice card; got \(dividerEntry.blocks.map(\.kind.rawValue))")
        fixture.window.contentView?.layoutSubtreeIfNeeded()
        view.layoutSubtreeIfNeeded()
        fixture.pump(0.2)
        try expect(view.qaSessionBoundaries.contains { $0.text == "In Terminal · 2 turns" && $0.glyphVisible && $0.ruled },
                   "the divider must draw as a rule with the terminal glyph and its label")
        // The flip stopped the Array face's turn to hand the session over; that
        // is not the user stopping it, and the terminal's turns are newer.
        let tail = view.qaTailStatusText
        let strip = view.qaNewestWorkStripText ?? ""
        try expect(![tail, strip].contains { $0.contains("You stopped") || $0.contains("Interrupted") },
                   "after the flip back nothing may say the user stopped or the turn was interrupted; tail '\(tail)', strip '\(strip)'")
        try expect(joined.components(separatedBy: "terminal: slow third").count == 2
                   && joined.components(separatedBy: "terminal: fourth").count == 2
                   && !joined.contains("PLAIN first question"),
                   "each terminal turn must appear exactly once, and nothing from before the mark; got \(added)")
        try expect(view.qaTerminalFaceAppendedTurns == 2, "two terminal turns, got \(view.qaTerminalFaceAppendedTurns)")
        let adopted = supervisor.records[agentID]
        try expect(adopted?.providerSessionId == clearedId,
                   "the Array face must continue the session /clear moved to; record has \(String(describing: adopted?.providerSessionId)), want \(clearedId)")
        try expect(adopted?.model == "anthropic/claude-sonnet-5-5" && supervisor.launchSelection(for: agentID)?.model == "anthropic/claude-sonnet-5-5",
                   "the model picker must show what the terminal ran; record has \(String(describing: adopted?.model))")
        try expect(view.qaComposerDraftText == draftBefore, "the composer draft must stay in the Array face")
        try expect(fixture.canvas.tileRecord(for: view.tile.id)?.metadata.agentTerminalFace == nil
                   && !supervisor.isInTerminalFace(agentID) && supervisor.sendRefusal(for: agentID) == nil,
                   "flipping back must clear the persisted face and release the session")
        fixture.window.contentView?.layoutSubtreeIfNeeded()
        saveWindowPNG(fixture.window, to: directory.appendingPathComponent("face-array-after-flip-back.png"))
        // The Array face carries on in the same conversation.
        try expect(supervisor.send("PLAIN fifth", to: agentID), "the Array face must send again after the flip back")
        try expect(fixture.pump(until: { !supervisor.isRunning(agentID) }, timeout: 15), "the fifth turn never ended")
        let resumed = AgentSteeringQAFakes.argv(in: fixture.bin)
        try expect(resumed.contains(clearedId), "the managed runner must resume the terminal's session; argv \(resumed)")
        log.append("flip back: 2 turns appended under the divider; record adopted \(clearedId) and claude-sonnet-5-5")

        // 6. Relaunch: the face persists and reattaches to claude in tmux...
        try click(try segment("face.toggle", of: view), in: fixture.window)
        try expect(fixture.pump(until: { view.face == .terminal && launches().count == 2 }, timeout: 10),
                   "the second flip must start claude again")
        try expect(fixture.pump(until: { tmuxSessionAlive(view.tile.id) }, timeout: 5), "claude must run in tmux")
        // A detached tmux client is not claude leaving: the face attaches again.
        let firstSurface = view.terminalFaceSession
        _ = try? ProcessTmuxControl(tmuxPath: tmuxPath, defaults: fixture.defaults)
            .run(["detach-client", "-s", TmuxSession.sessionName(tileId: view.tile.id)])
        try expect(fixture.pump(until: { view.terminalFaceSession != nil && view.terminalFaceSession !== firstSurface }, timeout: 8),
                   "a detached client must be replaced by a new one")
        fixture.pump(0.5)
        try expect(view.face == .terminal && launches().count == 2 && tmuxSessionAlive(view.tile.id),
                   "after a client detach the same claude must still run in the Terminal face")
        log.append("detached client: reattached to the same claude")
        let persisted = try fixture.canvas.tileRecord(for: view.tile.id).unwrap("the tile record")
        try expect(persisted.metadata.agentTerminalFace != nil, "the Terminal face must be persisted")
        view.prepareForRemovalFromScene()
        fixture.canvas.removeTile(id: view.tile.id)
        fixture.pump(0.5)
        try expect(tmuxSessionAlive(persisted.id), "claude must outlive the tile's view")
        let relaunched = fixture.makeTile(width: 760, height: 560, metadata: persisted.metadata, id: persisted.id, environment: environment)
        liveViews.append(relaunched)
        // tmux answers off the main thread first (review #12).
        try expect(relaunched.reattachTerminalFaceIfNeeded() && fixture.pump(until: { relaunched.face == .terminal }, timeout: 5),
                   "a relaunched tile must come back in its Terminal face")
        fixture.pump(1.0)
        try expect(launches().count == 2, "reattaching must not start a second claude; launches \(launches().count)")
        // ...and comes back in the Array face when tmux lost the session.
        relaunched.prepareForRemovalFromScene()
        fixture.canvas.removeTile(id: persisted.id)
        _ = try? ProcessTmuxControl(tmuxPath: tmuxPath, defaults: fixture.defaults)
            .run(["kill-session", "-t", TmuxSession.sessionName(tileId: persisted.id)])
        fixture.pump(0.5)
        let orphaned = fixture.makeTile(width: 760, height: 560, metadata: persisted.metadata, id: persisted.id, environment: environment)
        liveViews.append(orphaned)
        orphaned.reattachTerminalFaceIfNeeded()
        try expect(fixture.pump(until: {
            orphaned.face == .array && orphaned.tile.metadata.agentTerminalFace == nil && !supervisor.isInTerminalFace(agentID)
        }, timeout: 5), "with the tmux session gone the tile must come back in the Array face and release the session")
        log.append("relaunch: reattached without a second claude; tmux gone came back in Array")

        // 7. The terminal's turns are the agent's, not the tile's: a tile opened
        //    later shows them, and so does one after a close from the Terminal face.
        func showsTerminalTurns(_ tile: ManagedAgentTileNSView, _ marks: [String]) -> Bool {
            let text = entriesText(tile).joined(separator: "\n")
            return text.contains("In Terminal") && marks.allSatisfy { text.components(separatedBy: $0).count == 2 }
        }
        try expect(showsTerminalTurns(orphaned, ["terminal: slow third", "terminal: fourth"]),
                   "a tile opened later must show the terminal's turns once each; got \(entriesText(orphaned))")
        try clickSegment("face.toggle", of: orphaned)
        guard fixture.pump(until: { orphaned.face == .terminal && orphaned.terminalFaceSession?.claudePid != nil }, timeout: 10),
              let closing = orphaned.terminalFaceSession else {
            throw Failure(description: "the reopened tile must flip to its Terminal face; face \(orphaned.face), banner \(String(describing: orphaned.qaFaceFlipBanner.content)), held \(supervisor.isInTerminalFace(agentID)), launches \(launches().count), pid \(String(describing: orphaned.terminalFaceSession?.claudePid))")
        }
        _ = closing.runtime.dispatchInsertedText("sixth")
        closing.runtime.sendReturn()
        try expect(fixture.pump(until: { closing.isBusy }, timeout: 6) && fixture.pump(until: { !closing.isBusy }, timeout: 8),
                   "the sixth turn must run in the terminal")
        let tmuxBeforeClose = QAMainThreadIO.tmuxRuns
        try click(try segment("close", of: orphaned), in: fixture.window)
        try expect(fixture.closeRequests.contains(orphaned.tile.id) && orphaned.face == .array,
                   "× in the Terminal face closes the tile")
        orphaned.prepareForRemovalFromScene()
        fixture.canvas.removeTile(id: orphaned.tile.id)
        try expect(fixture.pump(until: { !supervisor.isInTerminalFace(agentID) }, timeout: 8),
                   "× in the Terminal face must end the face and release the session")
        try expect(QAMainThreadIO.tmuxRuns == tmuxBeforeClose,
                   "× must end claude's tmux session off the main thread; \(QAMainThreadIO.tmuxRuns - tmuxBeforeClose) tmux runs on main")
        let reopened = fixture.makeTile(width: 760, height: 560, environment: environment)
        liveViews.append(reopened)
        try expect(showsTerminalTurns(reopened, ["terminal: slow third", "terminal: fourth", "terminal: sixth"]),
                   "a tile closed from the Terminal face must leave its turns in the agent's transcript; got \(entriesText(reopened))")
        log.append("reopen: terminal turns survive a close from the Terminal face and a later reopen")

        /// Each marker in exactly one entry, the entries in the markers' order.
        func onceInOrder(_ texts: [String], _ markers: [String]) -> Bool {
            let rows = markers.map { marker in texts.indices.filter { texts[$0].contains(marker) } }
            return rows.allSatisfy { $0.count == 1 } && rows.map { $0[0] } == rows.map { $0[0] }.sorted()
        }
        var turnsInOrder = ["PLAIN first question", "terminal: slow third", "terminal: fourth", "PLAIN fifth", "terminal: sixth"]
        try expect(onceInOrder(entriesText(reopened), turnsInOrder),
                   "the reopened tile must show every turn once, in order; got \(entriesText(reopened))")

        // 8. The face is the agent's, not the tile's (review #9). Parked
        //    mid-face (as `parkZoneLayers` parks a tile: detached, its surface
        //    kept), the tile comes back still in its face, so no restore runs
        //    over it; parked again, claude leaves while nobody shows it, and
        //    the face still ends, releases the session and brings the turn home.
        try clickSegment("face.toggle", of: reopened)
        guard fixture.pump(until: { reopened.face == .terminal && reopened.terminalFaceSession?.claudePid != nil }, timeout: 10),
              let parkedSurface = reopened.terminalFaceSession else {
            throw Failure(description: "step 8: the reopened tile must flip to its Terminal face; face \(reopened.face), banner \(String(describing: reopened.qaFaceFlipBanner.content)), held \(supervisor.isInTerminalFace(agentID)), launches \(launches().count)")
        }
        _ = parkedSurface.runtime.dispatchInsertedText("parked seventh")
        parkedSurface.runtime.sendReturn()
        try expect(fixture.pump(until: { parkedSurface.isBusy }, timeout: 6) && fixture.pump(until: { !parkedSurface.isBusy }, timeout: 8),
                   "the seventh turn must run in the terminal")
        reopened.prepareForParking()
        reopened.attach(agentID: agentID, supervisor: supervisor)
        try expect(reopened.reattachTerminalFaceIfNeeded() && reopened.face == .terminal && reopened.terminalFaceSession === parkedSurface,
                   "back from parking mid-face, the tile is still in its face and owns its history (no restore runs over it)")
        reopened.prepareForParking()
        _ = try? ProcessTmuxControl(tmuxPath: tmuxPath, defaults: fixture.defaults)
            .run(["send-keys", "-t", TmuxSession.sessionName(tileId: reopened.tile.id), "/exit", "Enter"])
        try expect(fixture.pump(until: { !supervisor.isInTerminalFace(agentID) && supervisor.sendRefusal(for: agentID) == nil }, timeout: 10),
                   "claude leaving while its tile is parked must end the face and release the session; held \(supervisor.isInTerminalFace(agentID))")
        reopened.attach(agentID: agentID, supervisor: supervisor)
        try expect(!reopened.reattachTerminalFaceIfNeeded() && reopened.face == .array && reopened.tile.metadata.agentTerminalFace == nil,
                   "back from parking after claude left, the tile shows its Array face")
        turnsInOrder.append("terminal: parked seventh")
        try expect(onceInOrder(entriesText(reopened), turnsInOrder),
                   "after the parked exit every turn must show once, in order; got \(entriesText(reopened))")
        log.append("parked: claude left while the tile was parked; the face ended, the session was released, every turn once")

        // 9. tmux off: claude is its surface's child. A tile retired from its
        //    workspace keeps claude running — a busy turn is never ended
        //    without asking — and the tile rebuilt for the agent shows the
        //    same claude again (review #17).
        var plain = environment
        plain.tmuxPath = nil
        let keepView = fixture.makeTile(width: 760, height: 560, environment: plain)
        liveViews.append(keepView)
        try clickSegment("face.toggle", of: keepView)
        guard fixture.pump(until: { keepView.face == .terminal && keepView.terminalFaceSession?.claudePid != nil }, timeout: 10),
              let keptSurface = keepView.terminalFaceSession, let keptPid = keptSurface.claudePid else {
            throw Failure(description: "the tmux-less tile must flip to its Terminal face; face \(keepView.face), readiness \(supervisor.terminalFaceReadiness(for: agentID)), watch tile \(String(describing: supervisor.terminalFaceWatch(for: agentID)?.tileId)), expected \(keepView.tile.id), launches \(launches().count)")
        }
        _ = keptSurface.runtime.dispatchInsertedText("slow eighth")
        keptSurface.runtime.sendReturn()
        try expect(fixture.pump(until: { keptSurface.isBusy }, timeout: 6), "the eighth turn must start")
        let keptTile = try fixture.canvas.tileRecord(for: keepView.tile.id).unwrap("the tmux-less tile record")
        keepView.prepareForRemovalFromScene()
        fixture.canvas.removeTile(id: keepView.tile.id)
        fixture.pump(0.5)
        try expect(kill(keptPid, 0) == 0 && supervisor.isInTerminalFace(agentID),
                   "with tmux off, a tile leaving its workspace must not end its busy claude (pid \(keptPid) alive: \(kill(keptPid, 0) == 0))")
        let rebuilt = fixture.makeTile(width: 760, height: 560, metadata: keptTile.metadata, id: keptTile.id, environment: plain)
        liveViews.append(rebuilt)
        try expect(rebuilt.reattachTerminalFaceIfNeeded() && rebuilt.face == .terminal && rebuilt.terminalFaceSession?.claudePid == keptPid,
                   "the rebuilt tile must show the same claude again")
        try expect(fixture.pump(until: { !keptSurface.isBusy }, timeout: 8), "the eighth turn never ended")
        _ = keptSurface.runtime.dispatchInsertedText("/exit")
        keptSurface.runtime.sendReturn()
        try expect(fixture.pump(until: { rebuilt.face == .array && !supervisor.isInTerminalFace(agentID) }, timeout: 10),
                   "/exit in the rebuilt tile must flip it back")
        turnsInOrder.append("terminal: slow eighth")
        try expect(onceInOrder(entriesText(rebuilt), turnsInOrder),
                   "the rebuilt tile must show every turn once, in order; got \(entriesText(rebuilt))")
        log.append("tmux off: a retired tile left claude running mid-turn; the rebuilt tile showed the same claude")

        // 10. A relaunch that finds claude gone (reviews #10, #8). The tile
        //     remembers a face no process of this launch watched: claude
        //     answered past the mark, `/clear`ed and answered again on another
        //     model. The record adopts the session and model it ended on, and
        //     the turns land once, after the history before the mark, with no
        //     second restore to come.
        let relaunch = AgentSupervisor(
            store: AgentStore(applicationSupportDirectory: fixture.root.appendingPathComponent("support", isDirectory: true)),
            makeRunner: AgentSupervisor.productionRunner,
            transcriptStore: AgentTranscriptStore(root: fixture.root.appendingPathComponent("transcripts-relaunch", isDirectory: true)))
        defer { relaunch.stopAll() }
        relaunch.sessionFilesHome = fixture.claudeHome
        _ = relaunch.restore()
        guard let restored = relaunch.records[agentID] else { throw Failure(description: "the relaunch did not restore the agent") }
        let resumedId = AgentSupervisor.claudeSessionLocation(for: restored).sessionId
        let resumedURL = ClaudeTerminalFace.sessionFileURL(claudeHome: fixture.claudeHome, cwd: restored.lastObservedWhere, sessionId: resumedId)
        let relaunchMark = ClaudeTerminalFace.sessionFileLength(resumedURL)
        func line(_ object: [String: Any]) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self) + "\n"
        }
        func turn(_ text: String, model: String, session: String) throws -> String {
            try line(["type": "user", "isSidechain": false, "uuid": UUID().uuidString, "sessionId": session,
                      "message": ["role": "user", "content": text]])
            + line(["type": "assistant", "isSidechain": false, "uuid": UUID().uuidString, "sessionId": session,
                    "message": ["role": "assistant", "model": model, "content": [["type": "text", "text": "terminal: " + text]]]])
        }
        let handle = try FileHandle(forWritingTo: resumedURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(try turn("tenth", model: "claude-haiku-4-5-20251001", session: resumedId).utf8))
        try handle.close()
        let afterClear = UUID().uuidString.lowercased()
        try Data(try turn("eleventh", model: "claude-opus-5-5", session: afterClear).utf8).write(
            to: ClaudeTerminalFace.sessionFileURL(claudeHome: fixture.claudeHome, cwd: restored.lastObservedWhere, sessionId: afterClear))
        var remembered = TileMetadata(launchProfileId: "managed")
        remembered.agentTerminalFace = AgentTerminalFaceState(
            sessionId: resumedId, cwd: restored.lastObservedWhere, sessionFileOffset: relaunchMark, latestSessionId: afterClear)
        func relaunchedTile(_ metadata: TileMetadata) -> ManagedAgentTileNSView {
            let tile = Tile(id: UUID(), kind: .managedAgent, title: "Fix login redirect",
                            frame: TileFrame(x: 40, y: 40, width: 760, height: 560),
                            zPosition: .fromLegacyRank(1), runtimeRef: nil, metadata: metadata)
            let view = ManagedAgentTileNSView(tile: tile)
            fixture.canvas.install(tileView: view, for: tile)
            view.terminalFaceEnvironment = environment
            view.attach(agentID: agentID, supervisor: relaunch)
            liveViews.append(view)
            return view
        }
        let readsBeforeRelaunch = QAMainThreadIO.fileReads
        let comeback = relaunchedTile(remembered)
        try expect(comeback.reattachTerminalFaceIfNeeded(), "a remembered face owns the tile's history until it has ended")
        try expect(fixture.pump(until: {
            relaunch.records[agentID]?.providerSessionId == afterClear && comeback.tile.metadata.agentTerminalFace == nil
        }, timeout: 5), "with claude gone the record must adopt the session /clear moved to; record has \(String(describing: relaunch.records[agentID]?.providerSessionId)), want \(afterClear)")
        try expect(relaunch.records[agentID]?.model == "anthropic/claude-opus-5-5" && comeback.face == .array
                   && !relaunch.isInTerminalFace(agentID),
                   "…and the model the terminal last ran; record has \(String(describing: relaunch.records[agentID]?.model))")
        try expect(QAMainThreadIO.fileReads == readsBeforeRelaunch,
                   "the relaunch's face end must read off the main thread; \(QAMainThreadIO.fileReads - readsBeforeRelaunch) reads on main")
        try expect(!relaunch.needsPreviousSessionNotice(agentID),
                   "the face's end restored the history, so no second restore of the session file may run over it")
        let relaunchedTurns = ["terminal: fourth", "terminal: sixth", "terminal: parked seventh", "terminal: slow eighth",
                               "In Terminal · 2 turns", "terminal: tenth", "terminal: eleventh"]
        try expect(onceInOrder(entriesText(comeback), relaunchedTurns),
                   "after the relaunch the history and the terminal's turns must show once each, in order; got \(entriesText(comeback))")
        let reopenedAfterRelaunch = relaunchedTile(TileMetadata(launchProfileId: "managed"))
        try expect(onceInOrder(entriesText(reopenedAfterRelaunch), relaunchedTurns),
                   "a tile opened after that must show the same, once each, in order; got \(entriesText(reopenedAfterRelaunch))")
        log.append("relaunch: claude gone; the record adopted \(afterClear) and claude-opus-5-5; turns once, in order")

        // 11. Review finding 2: a pending fork (Copy before its first turn, or a
        //    `/clear` rotation) is a session another process may still be
        //    writing. The Terminal face forks it too, never resumes it as is,
        //    and the agent adopts only the fork's own id.
        for forkEnvironment in [environment, plain] {
            reopened.terminalFaceEnvironment = forkEnvironment
            let sourceId = UUID().uuidString.lowercased()
            let sourceURL = ClaudeTerminalFace.sessionFileURL(
                claudeHome: fixture.claudeHome, cwd: record.lastObservedWhere, sessionId: sourceId)
            try ([
                #"{"type":"user","isSidechain":false,"uuid":"src-u1","message":{"role":"user","content":"SOURCE question"}}"#,
                #"{"type":"assistant","isSidechain":false,"uuid":"src-a1","message":{"role":"assistant","model":"claude-haiku-4-5-20251001","content":[{"type":"text","text":"SOURCE answer"}]}}"#,
            ].joined(separator: "\n") + "\n").write(to: sourceURL, atomically: true, encoding: .utf8)
            let sourceBytes = try Data(contentsOf: sourceURL)
            supervisor.markSessionFork(agentID, from: sourceId)
            let sessionBeforeFork = supervisor.records[agentID]?.providerSessionId
            // A face that ends before claude reports the fork's id hands back the
            // source's: that is never adopted, and the fork stays pending.
            try expect(supervisor.beginTerminalFace(for: agentID) != nil, "the supervisor must hand a ready agent to the Terminal face")
            supervisor.endTerminalFace(for: agentID, sessionId: sourceId, model: nil, tookTurns: false)
            try expect(supervisor.records[agentID]?.providerSessionId == sessionBeforeFork
                       && supervisor.records[agentID]?.pendingSessionForkFrom == sourceId,
                       "a face that never reported its fork must not adopt the session it forked from; record has \(String(describing: supervisor.records[agentID]?.providerSessionId)), pending \(String(describing: supervisor.records[agentID]?.pendingSessionForkFrom))")
            let launchesBeforeFork = launches().count
            // The tile's own switch, through ⌃⌘T's path (the band click is
            // witnessed above).
            try expect(reopened.toggleFace(), "the reopened tile must take the switch")
            try expect(fixture.pump(until: { reopened.face == .terminal && launches().count == launchesBeforeFork + 1 }, timeout: 10),
                       "the fork's Terminal face must start claude; face \(reopened.face), pending \(reopened.pendingTerminalFlip), banner \(String(describing: reopened.qaFaceFlipBanner.content)), readiness \(supervisor.terminalFaceReadiness(for: agentID)), launches \(launches().count - launchesBeforeFork)")
            let forkArgv = launches().last?["argv"] as? [String] ?? []
            try expect(forkArgv.starts(with: ["--resume", sourceId, "--fork-session"]),
                       "a pending fork must run `claude --resume <source> --fork-session`, never resume the source itself; argv \(forkArgv)")
            guard let forking = reopened.terminalFaceSession else { throw Failure(description: "no fork terminal session") }
            try expect(fixture.pump(until: { forking.sessionIds.count == 2 }, timeout: 8),
                       "the face must follow the fork's own id from claude's live file; ids \(forking.sessionIds)")
            let forkId = forking.currentSessionId
            let beforeForkFlip = entriesText(reopened)
            _ = forking.runtime.dispatchInsertedText("forked turn")
            forking.runtime.sendReturn()
            try expect(fixture.pump(until: { forking.isBusy }, timeout: 6) && fixture.pump(until: { !forking.isBusy }, timeout: 8),
                       "the forked turn must run in the terminal")
            _ = forking.runtime.dispatchInsertedText("/exit")
            forking.runtime.sendReturn()
            try expect(fixture.pump(until: { reopened.face == .array }, timeout: 10), "/exit must flip the fork back")
            let sourceAfter = try Data(contentsOf: sourceURL)
            try expect(sourceAfter == sourceBytes, "the forked-from session file must never be written")
            try expect(supervisor.records[agentID]?.providerSessionId == forkId && supervisor.records[agentID]?.pendingSessionForkFrom == nil,
                       "the agent must continue the fork, not its source; record has \(String(describing: supervisor.records[agentID]?.providerSessionId)), want \(forkId)")
            let forkAdded = Array(entriesText(reopened).dropFirst(beforeForkFlip.count)).joined(separator: "\n")
            try expect(forkAdded.contains("In Terminal · 1 turn") && forkAdded.components(separatedBy: "terminal: forked turn").count == 2
                       && !forkAdded.contains("SOURCE question"),
                       "the flip back appends the fork's own turn once, never the history it copied; got \(forkAdded)")
            log.append("fork: --resume \(sourceId) --fork-session, adopted \(forkId), source untouched, tmux \(forkEnvironment.tmuxPath != nil)")
        }

        let manifest: [String: Any] = ["log": log, "launches": launches().map { $0.mapValues { "\($0)" } }]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent("manifest.json"))
        return (log + ["agent face flip: passed, artifacts \(directory.path)"]).joined(separator: "\n")
    }
}

private extension Optional {
    func unwrap(_ what: String) throws -> Wrapped {
        guard let self else { throw AgentFaceChecks.Failure(description: "missing \(what)") }
        return self
    }
}
