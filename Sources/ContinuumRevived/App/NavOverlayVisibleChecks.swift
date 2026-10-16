import AppKit
import ContinuumRevivedCore
import Foundation

/// `--nav-overlay-visible-check`: the hold-⌥ Quick Jump overlay and the ⌃Space
/// nav overlay actually appear, in the main window, over every focus context a
/// user reaches.
///
/// 0.7.27 shipped a hold-⌥ leader that never opened while an editable text view
/// had the keyboard. An agent tile puts its composer there on every click, spawn
/// and jump, so with an agent selected the leader was simply dead, while every
/// nav witness hand-built a canvas whose first responder was the canvas itself.
///
/// This leg mounts the invariants fixture through `mountWorkspaceSceneAtBoot`,
/// hosts the canvas in a window laid out like launch's (a sidebar column and a
/// content pane holding the canvas, so the canvas is not the content view and
/// does not sit at the window origin), installs the production key monitors and
/// sends real events through `NSApp.sendEvent` with the production dwell. Focus
/// is put in place by `routeTileClickFocus`, the route the click monitor takes.
///
/// For each context it asserts what a user would see: the overlay is in the main
/// window, not hidden (nor any ancestor), opaque enough to see, covers the
/// canvas, is the canvas's topmost child, carries jump labels, and the rendered
/// canvas is different where a label is drawn and darker where the dim is.
@MainActor
enum NavOverlayVisibleChecks {
    typealias Fixture = WorkspaceInvariantsFixture

    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    private final class KeyableFixtureWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
    }

    static let agentTile = UUID(uuidString: "00000000-0000-0000-0000-0000067A1E01")!
    static let previewNote = Fixture.noteA1b
    static let editingNote = Fixture.noteA1a
    static let codeFile = UUID(uuidString: "00000000-0000-0000-0000-0000067A1E02")!
    static let codeFileName = "main.swift"
    static let terminalTile = UUID(uuidString: "00000000-0000-0000-0000-0000067A1E03")!

    static func run() throws -> URL {
        guard ProcessInfo.processInfo.environment["CONTINUUM_APP_SUPPORT"] != nil else {
            throw Failure(message: "refusing to run without CONTINUUM_APP_SUPPORT: mounting restores agents from the channel's store")
        }
        for harness in [AgentHarness.claudeCode, .codex, .pi] {
            AgentModelCatalog.shared.resetForQA(snapshot: .init(
                harness: harness, readiness: .missing, models: [], displayNames: [:], contextWindows: [:]))
        }

        let fixture = try Fixture(label: "nav-overlay")
        defer { fixture.dispose() }
        try seed(fixture)
        try fixture.mount()
        let m = try fixture.requireMounted("nav overlay")
        let window = try host(m)
        defer { window.orderOut(nil); window.contentView = nil }
        let canvas = m.canvas
        let delegate = m.delegate
        let broker = delegate.qaFocusBroker

        var failures: [String] = []
        var contexts: [[String: Any]] = []
        var bootSurfaceDescription = "unset"
        func record(bootSurface: FocusSurfaceID?) { bootSurfaceDescription = String(describing: bootSurface) }
        let pastDwell = TimeInterval(NavKeymap.default.effectiveLeaderDwellMs) / 1000 + 0.3

        func spin(_ seconds: TimeInterval) {
            let until = Date().addingTimeInterval(seconds)
            while Date() < until { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        }
        func flags(_ mods: NSEvent.ModifierFlags, keyCode: UInt16 = 58) throws {
            guard let event = NSEvent.keyEvent(
                with: .flagsChanged, location: .zero, modifierFlags: mods,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: keyCode)
            else { throw Failure(message: "could not synthesize flagsChanged") }
            NSApp.sendEvent(event)
        }
        func key(_ characters: String, ignoring: String? = nil, keyCode: UInt16, mods: NSEvent.ModifierFlags) throws {
            guard let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: mods,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: ignoring ?? characters,
                isARepeat: false, keyCode: keyCode)
            else { throw Failure(message: "could not synthesize keyDown \(characters)") }
            NSApp.sendEvent(event)
        }
        func clickFocus(_ tileId: UUID) throws {
            guard let view = canvas.tileView(for: tileId) else {
                throw Failure(message: "setup: tile \(tileId) has no view in the mounted scene")
            }
            let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
            AppDelegate.routeTileClickFocus(at: point, in: canvas, focusBroker: broker)
            canvas.layoutSubtreeIfNeeded()
        }
        func responderDescription() -> String {
            guard let responder = window.firstResponder else { return "nil" }
            if let text = responder as? NSTextView { return "\(type(of: text))(editable: \(text.isEditable))" }
            return String(describing: type(of: responder))
        }
        func render() -> NSBitmapImageRep? {
            canvas.layoutSubtreeIfNeeded()
            canvas.displayIfNeeded()
            guard let rep = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else { return nil }
            canvas.cacheDisplay(in: canvas.bounds, to: rep)
            return rep
        }
        /// Mean luminance of a point patch around `point` (canvas coordinates).
        func luminance(_ rep: NSBitmapImageRep, at point: CGPoint, radius: Int = 3) -> Double {
            let scaleX = CGFloat(rep.pixelsWide) / canvas.bounds.width
            let scaleY = CGFloat(rep.pixelsHigh) / canvas.bounds.height
            let topDown = canvas.isFlipped ? point.y : canvas.bounds.height - point.y
            var total = 0.0
            var count = 0.0
            for dx in -radius...radius {
                for dy in -radius...radius {
                    let px = Int((point.x + CGFloat(dx)) * scaleX)
                    let py = Int((topDown + CGFloat(dy)) * scaleY)
                    guard px >= 0, py >= 0, px < rep.pixelsWide, py < rep.pixelsHigh,
                          let color = rep.colorAt(x: px, y: py)?.usingColorSpace(.deviceRGB) else { continue }
                    total += 0.2126 * Double(color.redComponent) + 0.7152 * Double(color.greenComponent)
                        + 0.0722 * Double(color.blueComponent)
                    count += 1
                }
            }
            return count > 0 ? total / count : -1
        }

        /// Everything a user would see about an open overlay; returns the problems.
        func overlayProblems(_ presentation: String) -> [String] {
            guard let overlay = canvas.qaNavModeOverlayView else {
                return ["\(presentation): no overlay view is installed"]
            }
            var problems: [String] = []
            if overlay.window !== window { problems.append("\(presentation): overlay is in window \(String(describing: overlay.window)), not the main window") }
            if overlay.isHiddenOrHasHiddenAncestor { problems.append("\(presentation): overlay or an ancestor is hidden") }
            var alpha = overlay.alphaValue
            var ancestor = overlay.superview
            while let view = ancestor { alpha *= view.alphaValue; ancestor = view.superview }
            if alpha <= 0.01 { problems.append("\(presentation): overlay's effective alpha is \(alpha)") }
            if overlay.frame != canvas.bounds { problems.append("\(presentation): overlay frame \(overlay.frame) != canvas bounds \(canvas.bounds)") }
            if canvas.subviews.last !== overlay { problems.append("\(presentation): overlay is not the canvas's topmost child (top is \(canvas.subviews.last.map { String(describing: type(of: $0)) } ?? "nil"))") }
            return problems
        }

        /// One focus context: `focus` puts the keyboard where the user would have
        /// it; the leader and ⌃Space are then driven through real events.
        func context(_ name: String, focus: () throws -> Void, expectResponder: (NSResponder?) -> Bool) throws {
            try focus()
            spin(0.05)
            let responder = responderDescription()
            var record: [String: Any] = ["context": name, "firstResponder": responder]
            var problems: [String] = []
            guard expectResponder(window.firstResponder) else {
                failures.append("\(name): setup did not put the keyboard where this context needs it; first responder is \(responder)")
                record["setup"] = "failed"
                contexts.append(record)
                return
            }
            let closed = render()

            // Hold ⌥ alone past the production dwell.
            try flags(.option)
            spin(pastDwell)
            let leaderOpen = broker.activeSurface == .modal(.leader)
            record["leaderOpen"] = leaderOpen
            if !leaderOpen {
                problems.append("holding ⌥ past the dwell did not open Quick Jump (broker surface \(String(describing: broker.activeSurface)))")
            } else {
                problems += overlayProblems("Quick Jump")
                let assignments = canvas.leaderJumpAssignments()
                record["labels"] = assignments.map(\.label)
                if assignments.isEmpty {
                    problems.append("Quick Jump opened with no jump labels")
                } else if let closed, let open = render(), let overlay = canvas.qaNavModeOverlayView {
                    let first = assignments[0]
                    let badge = JumpIndicatorPlacementEngine.indicatorRect(for: first.placement, normalBadgeSize: CGSize(width: 24, height: 24))
                    // Inside the badge, left of its letter.
                    let badgePoint = overlay.convert(CGPoint(x: badge.minX + 5, y: badge.midY), to: canvas)
                    let labelClosed = luminance(closed, at: badgePoint, radius: 2)
                    let labelOpen = luminance(open, at: badgePoint, radius: 2)
                    // The dim lands everywhere a label does not: a point inside the
                    // labelled tile, clear of its badge.
                    let tileScreen = CanvasEngine.tileScreenFrame(first.worldFrame, viewport: canvas.viewport)
                    let dimPoint = overlay.convert(CGPoint(x: tileScreen.minX + 14, y: tileScreen.maxY - 14), to: canvas)
                    let dimClosed = luminance(closed, at: dimPoint)
                    let dimOpen = luminance(open, at: dimPoint)
                    record["pixels"] = ["labelClosed": labelClosed, "labelOpen": labelOpen, "dimClosed": dimClosed, "dimOpen": dimOpen]
                    // Dimming alone would scale the closed value by the dim ratio; a
                    // drawn badge is a different colour altogether.
                    let dimRatio = dimClosed > 0 ? dimOpen / dimClosed : 1
                    if abs(labelOpen - labelClosed * dimRatio) < 0.1 {
                        problems.append("no badge is drawn where label '\(first.label)' should be (luminance \(labelClosed) closed, \(labelOpen) open, dim alone would give \(labelClosed * dimRatio))")
                    }
                    if !(dimOpen < dimClosed * 0.9) {
                        problems.append("the rendered canvas is not darker under the overlay (luminance \(dimClosed) closed, \(dimOpen) open)")
                    }
                } else {
                    problems.append("could not render the canvas")
                }
            }
            try flags([])
            spin(0.05)
            if broker.activeSurface == .modal(.leader) { problems.append("releasing ⌥ did not close Quick Jump") }

            // ⌃Space toggles nav mode over the same context.
            try focus()
            spin(0.05)
            try key(" ", keyCode: 49, mods: .control)
            let navOpen = broker.activeSurface == .modal(.navMode)
            record["navModeOpen"] = navOpen
            if !navOpen {
                problems.append("⌃Space did not open nav mode (broker surface \(String(describing: broker.activeSurface)))")
            } else {
                problems += overlayProblems("nav mode")
            }
            try key(" ", keyCode: 49, mods: .control)
            if broker.activeSurface == .modal(.navMode) { problems.append("⌃Space again did not close nav mode") }
            spin(0.05)

            record["problems"] = problems
            contexts.append(record)
            failures += problems.map { "\(name): \($0)" }
        }

        func isEditableText(_ responder: NSResponder?) -> Bool { (responder as? NSTextView)?.isEditable == true }
        func isInsideTile(_ tileId: UUID) -> (NSResponder?) -> Bool {
            { responder in
                guard let view = responder as? NSView, let tile = canvas.tileView(for: tileId) else { return false }
                return view === tile || view.isDescendant(of: tile)
            }
        }

        // Straight after launch, before anything is clicked.
        record(bootSurface: broker.activeSurface)
        try context("fresh boot, nothing clicked", focus: {}, expectResponder: { _ in true })

        // Headline: an agent tile selected — its composer has the keyboard.
        try context("agent tile selected (composer focused)", focus: { try clickFocus(agentTile) }, expectResponder: { responder in
            guard let composer = (canvas.tileView(for: agentTile) as? ManagedAgentTileNSView)?.qaComposerForChecks else { return false }
            return responder === composer.textView
        })
        try context("note selected, preview (not editing)", focus: { try clickFocus(previewNote) }, expectResponder: { responder in
            isInsideTile(previewNote)(responder) && !isEditableText(responder)
        })
        try context("note editing", focus: { try clickFocus(editingNote) }, expectResponder: { responder in
            isInsideTile(editingNote)(responder) && isEditableText(responder)
        })
        try context("terminal tile selected", focus: { try clickFocus(terminalTile) }, expectResponder: isInsideTile(terminalTile))
        try context("bare canvas", focus: {
            _ = window.makeFirstResponder(canvas)
            _ = broker.requestFocus(.canvas, reason: .userClick)
        }, expectResponder: { $0 === canvas })
        try context("after clicking a zone", focus: {
            try fixture.armByClick(Fixture.zoneA1)
            _ = window.makeFirstResponder(canvas)
            _ = broker.requestFocus(.canvas, reason: .userClick)
        }, expectResponder: { $0 === canvas })

        // Immediately after a Quick Jump into the agent tile: the jump hands the
        // composer the keyboard, and the very next hold must still open.
        var jumped = false
        try context("after a Quick Jump into the agent tile", focus: {
            guard !jumped else { return }
            jumped = true
            _ = window.makeFirstResponder(canvas)
            _ = broker.requestFocus(.canvas, reason: .userClick)
            try flags(.option)
            spin(pastDwell)
            guard broker.activeSurface == .modal(.leader),
                  let label = canvas.leaderJumpAssignments().first(where: { $0.tileId == agentTile })?.label else {
                throw Failure(message: "setup: from the bare canvas, Quick Jump must open with a label on the agent tile")
            }
            let keyCodes: [String: UInt16] = ["a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "j": 38, "k": 40, "l": 37]
            try key(label, keyCode: keyCodes[label] ?? 0, mods: .option)
            try flags([])
            spin(0.1)
        }, expectResponder: { responder in
            guard let composer = (canvas.tileView(for: agentTile) as? ManagedAgentTileNSView)?.qaComposerForChecks else { return false }
            return responder === composer.textView
        })

        // The code editor is a WKWebView that focuses asynchronously; give it a
        // moment and say so plainly if it never takes the keyboard.
        var codeEditorNote: String?
        if let fileView = canvas.tileView(for: codeFile) as? FileTileNSView {
            try clickFocus(codeFile)
            let deadline = Date().addingTimeInterval(4)
            while !fileView.isCodeEditorFocused, Date() < deadline { spin(0.05) }
            if fileView.isCodeEditorFocused {
                try context("code editor focused", focus: {
                    if !fileView.isCodeEditorFocused {
                        try clickFocus(codeFile)
                        let again = Date().addingTimeInterval(2)
                        while !fileView.isCodeEditorFocused, Date() < again { spin(0.05) }
                    }
                }, expectResponder: { _ in fileView.isCodeEditorFocused })
            } else {
                codeEditorNote = "code editor context unverified: the editor did not take the keyboard within 4s (first responder \(responderDescription()))"
            }
        } else {
            failures.append("setup: the code file tile has no FileTileNSView")
        }

        // The selected tile is closed (⌘W / its × button): its focus scope goes
        // with it, so the next leader opens with no scope to restore.
        try clickFocus(terminalTile)
        delegate.deleteTile(id: terminalTile)
        canvas.layoutSubtreeIfNeeded()
        try context("after closing the selected tile", focus: {}, expectResponder: { _ in true })
        // …and every hold after that one must open again.
        try context("the hold after that", focus: {}, expectResponder: { _ in true })

        // Positive control: ⌘K opens the Command Center over the same window.
        _ = window.makeFirstResponder(canvas)
        _ = broker.requestFocus(.canvas, reason: .userClick)
        try key("k", keyCode: 40, mods: .command)
        let paletteOpen = delegate.qaProfilePalette?.isVisible == true
        if !paletteOpen { failures.append("positive control: ⌘K through the production monitor did not open the Command Center") }
        delegate.qaProfilePalette?.close()

        let timestamp = Int(Date().timeIntervalSince1970)
        let dir = URL(fileURLWithPath: "qa-runs/\(timestamp)/nav-overlay-visible", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let artifact = dir.appendingPathComponent("manifest.json", isDirectory: false)
        var manifest: [String: Any] = ["contexts": contexts, "paletteControl": paletteOpen, "failures": failures,
                                       "bootSurface": bootSurfaceDescription]
        if let codeEditorNote { manifest["note"] = codeEditorNote }
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: artifact, options: .atomic)
        if let codeEditorNote { print("MATRIX-NOTE: \(codeEditorNote)") }
        guard failures.isEmpty else {
            throw Failure(message: "nav overlay visible: \(failures.count) failure(s):\n  - " + failures.joined(separator: "\n  - "))
        }
        return artifact
    }

    /// An agent tile (no record: it stays unbound and starts nothing), a note in
    /// Preview, a source file and a terminal descriptor, all in zone A1 and in
    /// view of the seeded camera.
    private static func seed(_ fixture: Fixture) throws {
        let projectRoot = fixture.projectRoots[Fixture.projectA1]!
        let store = ProjectStore(projectRoot: projectRoot)
        var canvas = try store.loadCanvas()
        if let index = canvas.tiles.firstIndex(where: { $0.id == previewNote }) {
            canvas.tiles[index].metadata.markdownDocumentMode = .preview
        }
        var agent = Tile(
            id: agentTile, kind: .managedAgent, title: "agent", frame: TileFrame(x: 640, y: 480, width: 260, height: 200),
            zPosition: .fromLegacyRank(20), runtimeRef: nil,
            metadata: TileMetadata(launchProfileId: "managed-agent", projectRelativeCwd: ".", filesystemProjectId: Fixture.projectA1))
        agent.zoneId = Fixture.zoneA1
        try "let answer = 42\n".write(to: projectRoot.appendingPathComponent(codeFileName), atomically: true, encoding: .utf8)
        let location = DocumentLocationResolver.resolve(
            fileURL: projectRoot.appendingPathComponent(codeFileName),
            knownRoots: [DocumentLocationRoot(rootURL: projectRoot, projectId: Fixture.projectA1)])
        var code = Tile(
            id: codeFile, kind: .file, title: codeFileName, frame: TileFrame(x: 1200, y: 520, width: 280, height: 200),
            zPosition: .fromLegacyRank(21), runtimeRef: nil,
            metadata: TileMetadata(filePath: location.path, documentLocation: location))
        code.zoneId = Fixture.zoneA1
        var terminal = Tile(
            id: terminalTile, kind: .terminal, title: "shell", frame: TileFrame(x: 920, y: 690, width: 260, height: 180),
            zPosition: .fromLegacyRank(22), runtimeRef: nil,
            metadata: TileMetadata(launchProfileId: "shell", projectRelativeCwd: "."))
        terminal.zoneId = Fixture.zoneA1
        canvas.tiles += [agent, code, terminal]
        try store.saveCanvas(canvas)
    }

    /// Launch's shape without launch's side effects: a sidebar column and a
    /// content pane under a top strip, the canvas pinned inside the pane. No
    /// split-view delegate, so no layout pass can persist a sidebar width.
    private static func host(_ m: Fixture.Mounted) throws -> NSWindow {
        let size = NSSize(width: 1600, height: 1000)
        let window = KeyableFixtureWindow(
            contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        let topBar: CGFloat = 30
        let sidebarWidth = CGFloat(WorkspaceSidebarConfig.defaultWidth)
        let sidebar = NSView(frame: NSRect(x: 0, y: 0, width: sidebarWidth, height: size.height - topBar))
        let pane = NSView(frame: NSRect(x: sidebarWidth + 1, y: 0, width: size.width - sidebarWidth - 1, height: size.height - topBar))
        m.canvas.removeFromSuperview()
        m.canvas.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(m.canvas)
        NSLayoutConstraint.activate([
            m.canvas.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            m.canvas.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            m.canvas.topAnchor.constraint(equalTo: pane.topAnchor),
            m.canvas.bottomAnchor.constraint(equalTo: pane.bottomAnchor),
        ])
        container.addSubview(sidebar)
        container.addSubview(pane)
        window.contentView = container
        window.orderFrontOffscreenForChecks()
        window.makeKey()
        m.delegate.qaAttachWindowInstallingHotkeyMonitor(window)
        container.layoutSubtreeIfNeeded()
        m.canvas.layoutSubtreeIfNeeded()
        guard m.canvas.window === window, m.canvas.bounds.width > 1000 else {
            throw Failure(message: "setup: the canvas did not lay out inside the content pane (bounds \(m.canvas.bounds))")
        }
        return window
    }
}
