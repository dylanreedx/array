import AppKit
import ContinuumRevivedCore
import ObjectiveC
import QuartzCore

/// `--tidy-camera-check` (overnight auto-layout program, "practicality after
/// tidy"). Tidy can grow a zone, push it or shrink it, so what you were looking
/// at can leave the screen. The rule, through the production tidy entries:
///
/// - a zone wholly in view that tidy carries partly out of view is framed by the
///   navigation camera, the flight starting with the tidy's own movement and
///   landing exactly on the framed viewport (zone menu and ⌥⌘T alike);
/// - a zone that stays in view never moves the camera;
/// - Tidy canvas (every zone) never moves the camera.
///
/// It also measures Tidy canvas over 6 zones of 15 tiles: time to the first
/// committed movement, one commit, one Undo that restores every tile.
@MainActor
enum TidyCameraChecks {
    typealias Fixture = WorkspaceInvariantsFixture
    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    private final class KeyWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var isKeyWindow: Bool { true }
    }

    struct ZoneSpec {
        var id: UUID
        var project: UUID
        var origin: ZonePoint
        var size: ZoneSize
        var frames: [TileFrame]
    }

    struct Mount {
        let fixture: Fixture
        let mounted: Fixture.Mounted
        let window: NSWindow
        let tiles: [UUID: [UUID]]   // zone → its tile ids
        var canvas: CanvasNSView { mounted.canvas }
    }

    static func tileId(zone: Int, index: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-00%02X%08X", zone, 0x7C0A_0000 + index))!
    }

    /// Workspace A with exactly these zones and note tiles; everything else that
    /// workspace held is moved out of the way or removed.
    static func mount(_ specs: [ZoneSpec], label: String, camera: CanvasViewport? = nil,
                      requireAllHydrated: Bool = true) throws -> Mount {
        let fixture = try Fixture(label: "tidy-camera-\(label)")
        let workspaceStore = WorkspaceStore(workspaceId: Fixture.workspaceA, applicationSupportDirectory: fixture.appSupport)
        let existing = try workspaceStore.load()
        let colors = ["blue", "green", "teal", "purple", "orange", "pink"]
        let zones: [ZonePlacement] = specs.enumerated().map { index, spec in
            ZonePlacement(zoneId: spec.id, projectId: spec.project, origin: spec.origin, size: spec.size,
                          color: colors[index % colors.count], collapsed: false, hydrationPolicy: .automatic,
                          name: "Zone \(index + 1)")
        }
        // The camera at mount decides which zones hydrate live.
        let document = WorkspaceDocument(viewport: camera ?? existing.viewport, zones: zones,
                                         zoneZOrder: zones.map(\.zoneId), lastActiveZoneId: specs.first?.id)
        try workspaceStore.save(document)

        var tiles: [UUID: [UUID]] = [:]
        for project in [Fixture.projectA1, Fixture.projectA2] {
            let store = ProjectStore(projectRoot: fixture.projectRoots[project]!)
            var state = try store.loadCanvas()
            state.tiles.removeAll()
            for (zoneIndex, spec) in specs.enumerated() where spec.project == project {
                for (index, frame) in spec.frames.enumerated() {
                    let id = tileId(zone: zoneIndex, index: index)
                    var tile = Tile(id: id, kind: .note, title: "z\(zoneIndex) note \(index)", frame: frame,
                                    zPosition: .fromLegacyRank(index + 1), runtimeRef: nil,
                                    metadata: TileMetadata(noteId: id))
                    tile.zoneId = spec.id
                    state.tiles.append(tile)
                    tiles[spec.id, default: []].append(id)
                    try store.saveNoteBody(id: id, text: "note \(index)\nline two")
                }
            }
            try store.saveCanvas(state)
        }

        try fixture.mount()
        let mounted = try fixture.requireMounted("tidy camera \(label)")
        let canvas = mounted.canvas
        _ = ZoneTruthChecks.pinPreferences(canvas, autoLayout: true)
        canvas.autoLayoutReduceMotionProvider = { false }
        let window = KeyWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = canvas
        window.orderFrontOffscreenForChecks()
        window.makeKey()
        canvas.layoutSubtreeIfNeeded(); canvas.displayIfNeeded(); CATransaction.flush()
        fixture.drain(0.3)
        let all = tiles.values.flatMap { $0 }
        let missing = all.filter { canvas.tileView(for: $0) == nil }
        guard missing.isEmpty || !requireAllHydrated else { throw Failure(message: "\(label): mount hydrated \(all.count - missing.count) of \(all.count) tiles") }
        return Mount(fixture: fixture, mounted: mounted, window: window, tiles: tiles)
    }

    /// Twelve 400x300 notes overlapping inside a 900x700 zone: more tile than
    /// zone even at tidy's smallest scale, so tidy must grow it downward.
    static func crampedZone(_ id: UUID, project: UUID, at origin: ZonePoint) -> ZoneSpec {
        let frames = (0..<12).map { i in
            TileFrame(x: origin.x + 20 + Double(i % 3) * 240, y: origin.y + 40 + Double(i / 3) * 110, width: 400, height: 300)
        }
        return ZoneSpec(id: id, project: project, origin: origin, size: ZoneSize(width: 900, height: 700), frames: frames)
    }

    /// `count` small notes on an uneven grid with room to spare.
    static func roomyZone(_ id: UUID, project: UUID, at origin: ZonePoint, count: Int, size: ZoneSize) -> ZoneSpec {
        let columns = max(2, Int(Double(count).squareRoot().rounded(.up)))
        let frames = (0..<count).map { i in
            TileFrame(x: origin.x + 30 + Double(i % columns) * 300 + Double((i * 37) % 40),
                      y: origin.y + 60 + Double(i / columns) * 220 + Double((i * 53) % 30),
                      width: 240, height: 160)
        }
        return ZoneSpec(id: id, project: project, origin: origin, size: size, frames: frames)
    }

    // MARK: - Driving

    static func zoneMenuTidy(_ m: Mount, zoneId: UUID) throws {
        let canvas = m.canvas
        guard let rect = canvas.zoneWorldRect(zoneId) else { throw Failure(message: "zone \(zoneId) is not live") }
        let header = CGPoint(x: rect.minX + 60, y: rect.minY + Double(ZoneChromeNSView.headerHeight) / 2)
        let point = canvas.convert(CanvasEngine.worldToScreen(header, viewport: canvas.viewport), to: nil)
        guard let event = NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: m.window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1),
              let item = canvas.menu(for: event)?.items.first(where: { $0.title == "Tidy Zone Now" }) else {
            throw Failure(message: "the zone header menu has no Tidy Zone Now")
        }
        NSApp.sendAction(item.action!, to: item.target, from: item)
    }

    static func pressTidyShortcut(_ m: Mount) throws {
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command, .option],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: m.window.windowNumber,
            context: nil, characters: "†", charactersIgnoringModifiers: "t",
            isARepeat: false, keyCode: 17) else { throw Failure(message: "could not synthesize ⌥⌘T") }
        NSApp.sendEvent(event)
    }

    static func committedTileAnimations(_ m: Mount) -> Int {
        m.tiles.values.flatMap { $0 }.compactMap { m.canvas.tileView(for: $0)?.layer }.filter { layer in
            (layer.animationKeys() ?? []).contains { (layer.animation(forKey: $0) as? CABasicAnimation)?.beginTime ?? 0 > 0 }
        }.count
    }

    /// Zoom 1.4 with the zone's bottom edge 10 points above the view's: wholly
    /// in view, with no room below for it to grow into.
    static func bottomHugging(_ canvas: CanvasNSView, zone: CGRect) -> CanvasViewport {
        let zoom = 1.4
        let height = Double(canvas.bounds.height) / zoom
        return CanvasViewport(x: Double(zone.minX) - 20, y: Double(zone.maxY) + 10 - height, zoom: zoom)
    }

    static func settle(_ m: Mount) { m.canvas.layoutSubtreeIfNeeded(); m.canvas.displayIfNeeded(); CATransaction.flush() }

    /// Let a flight run out on the real driver (its stalled-link backstop lands
    /// it exactly when an offscreen window's display link does not tick).
    static func waitForFlight(_ m: Mount) {
        let deadline = Date().addingTimeInterval(3)
        while m.canvas.cameraDriver.isFlightActive, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }

    // MARK: - Scenarios

    static func run() throws {
        var failures: [String] = []
        var notes: [String] = []
        let a1 = Fixture.zoneA1, a2 = Fixture.zoneA2

        // A. A zone wholly in view that tidy grows past the bottom: framed, by
        //    the zone menu and by ⌥⌘T.
        for trigger in ["zone menu", "⌥⌘T"] {
            let m = try mount([crampedZone(a1, project: Fixture.projectA1, at: ZonePoint(x: 600, y: 200))], label: "grow")
            defer { m.mounted.delegate.qaRemoveHotkeyMonitor(); m.window.orderOut(nil); m.fixture.dispose() }
            let canvas = m.canvas
            canvas.navigationFlightOverrideForQA = true
            if trigger == "⌥⌘T" { m.mounted.delegate.qaInstallHotkeyMonitor() }
            canvas.setViewport(bottomHugging(canvas, zone: canvas.zoneWorldRect(a1)!))
            settle(m)
            let before = canvas.zoneWorldRect(a1)!
            guard canvas.isInUsableView(before) else { throw Failure(message: "A \(trigger): fixture zone is not wholly in view") }
            if trigger == "⌥⌘T" { try pressTidyShortcut(m) } else { try zoneMenuTidy(m, zoneId: a1) }
            let after = canvas.zoneWorldRect(a1)!
            let flying = canvas.cameraDriver.isFlightActive
            let target = canvas.cameraDriver.flightTarget
            let expected = canvas.framedZoneViewport(for: after)
            let animations = committedTileAnimations(m)
            if after.maxY <= before.maxY + 1 {
                failures.append("A \(trigger): fixture: tidy did not grow the zone downward (\(before) -> \(after))")
            }
            if !flying || target != expected {
                failures.append("A \(trigger): the zone left the view and the camera did not fly to frame it (flying \(flying), target \(String(describing: target)), want \(expected))")
            }
            // Same turn: the tidy's animations are committed and the flight is
            // armed when the trigger returns — the flight's first step is the
            // next frame, never after the slide.
            if animations == 0 { failures.append("A \(trigger): the tidy's movement was not committed with the flight") }
            waitForFlight(m)
            if canvas.cameraDriver.isFlightActive { failures.append("A \(trigger): the flight never landed") }
            if canvas.viewport != expected {
                failures.append("A \(trigger): the flight landed at \(canvas.viewport), not the framed \(expected)")
            }
            if !canvas.isInUsableView(after) { failures.append("A \(trigger): the grown zone is still not wholly in view") }
            notes.append(String(format: "A %@: zone %.0f→%.0f tall, camera zoom 1.40→%.2f, landed exactly", trigger,
                                before.height, after.height, canvas.viewport.zoom))
        }

        // B. A zone that stays in view: the camera does not move.
        do {
            let m = try mount([roomyZone(a1, project: Fixture.projectA1, at: ZonePoint(x: 600, y: 200), count: 4,
                                         size: ZoneSize(width: 1400, height: 900))], label: "stay")
            defer { m.window.orderOut(nil); m.fixture.dispose() }
            let canvas = m.canvas
            canvas.navigationFlightOverrideForQA = true
            let camera = CanvasViewport(x: 300, y: -100, zoom: 1)
            canvas.setViewport(camera)
            settle(m)
            let before = canvas.zoneWorldRect(a1)!
            try zoneMenuTidy(m, zoneId: a1)
            let after = canvas.zoneWorldRect(a1)!
            if before == after { failures.append("B: fixture: tidy left the zone unchanged") }
            if !canvas.isInUsableView(after) { failures.append("B: fixture: the tidied zone left the view") }
            if canvas.cameraDriver.isFlightActive || canvas.viewport != camera {
                failures.append("B: a zone that stayed in view moved the camera to \(canvas.viewport)")
            }
            notes.append(String(format: "B: zone %.0fx%.0f → %.0fx%.0f, still in view, camera unchanged",
                                before.width, before.height, after.width, after.height))
        }

        // C. Tidy canvas over the zone A grows: no camera change.
        do {
            let m = try mount([crampedZone(a1, project: Fixture.projectA1, at: ZonePoint(x: 600, y: 200))], label: "canvas")
            defer { m.window.orderOut(nil); m.fixture.dispose() }
            let canvas = m.canvas
            canvas.navigationFlightOverrideForQA = true
            let camera = bottomHugging(canvas, zone: canvas.zoneWorldRect(a1)!)
            canvas.setViewport(camera)
            settle(m)
            let before = canvas.zoneWorldRect(a1)!
            guard m.mounted.delegate.qaPerformPaletteAction(.tidyCanvas) else { throw Failure(message: "C: Tidy canvas did not run") }
            let after = canvas.zoneWorldRect(a1)!
            if canvas.isInUsableView(after) || after.maxY <= before.maxY {
                failures.append("C: fixture: Tidy canvas did not carry the zone out of view (\(before) -> \(after))")
            }
            if canvas.cameraDriver.isFlightActive || canvas.viewport != camera {
                failures.append("C: Tidy canvas moved the camera to \(canvas.viewport)")
            }
            notes.append("C: Tidy canvas grew the zone out of view, camera unchanged")
        }

        // D. Tidy canvas over 6 zones of 15 tiles: one commit, one Undo, timing.
        do {
            let zoneIds = [a1, a2, Fixture.zoneA3] + (0..<3).map { UUID(uuidString: String(format: "00000000-0000-0000-0000-0000067C0D%02X", $0))! }
            var specs: [ZoneSpec] = []
            for (index, id) in zoneIds.enumerated() {
                let origin = ZonePoint(x: 600 + Double(index % 3) * 3000, y: 200 + Double(index / 3) * 2000)
                specs.append(roomyZone(id, project: index % 2 == 0 ? Fixture.projectA1 : Fixture.projectA2, at: origin,
                                       count: 15, size: ZoneSize(width: 1600, height: 1200)))
            }
            // At most `ZoneHydrationBudgetConfig.maxLiveZones` zones are live (4 by
            // default); the rest hold no tile views and tidy must leave them alone.
            let m = try mount(specs, label: "six", camera: CanvasViewport(x: 300, y: -100, zoom: 0.28),
                              requireAllHydrated: false)
            defer { m.window.orderOut(nil); m.fixture.dispose() }
            let canvas = m.canvas
            let camera = CanvasViewport(x: 300, y: -100, zoom: 0.28)
            canvas.setViewport(camera)
            settle(m)
            let liveZones = Set(m.tiles.filter { $0.value.allSatisfy { canvas.tileView(for: $0) != nil } }.keys)
            let dormantZones = zoneIds.filter { !liveZones.contains($0) }
            let dormantRects = Dictionary(uniqueKeysWithValues: dormantZones.compactMap { id in canvas.zoneWorldRect(id).map { (id, $0) } })
            let all = m.tiles.filter { liveZones.contains($0.key) }.values.flatMap { $0 }
            func frames() -> [UUID: TileFrame] {
                Dictionary(canvas.allTilesInWorldFrames().map { ($0.id, $0.frame) }, uniquingKeysWith: { a, _ in a })
            }
            let before = frames()
            var commits = 0
            var commitShapes: [String] = []
            var insideCall = true
            let persist = canvas.onLayoutCommitted
            canvas.onLayoutCommitted = { transaction in
                commits += 1
                commitShapes.append("\(insideCall ? "in-call" : "after"): \(transaction.tileFrames.count) tiles, \(transaction.zonePlacements.count) zones")
                return persist?(transaction) ?? true
            }
            canvas.qaAutoLayoutStageTimes = .init()
            let triggerAt = CACurrentMediaTime()
            guard m.mounted.delegate.qaPerformPaletteAction(.tidyCanvas) else { throw Failure(message: "D: Tidy canvas did not run") }
            let callMs = (CACurrentMediaTime() - triggerAt) * 1000
            insideCall = false
            settle(m)
            var firstBegin = Double.infinity
            for id in all {
                guard let layer = canvas.tileView(for: id)?.layer else { continue }
                for key in layer.animationKeys() ?? [] {
                    if let a = layer.animation(forKey: key) as? CABasicAnimation, a.beginTime > 0 {
                        firstBegin = min(firstBegin, layer.convertTime(a.beginTime, to: nil))
                    }
                }
            }
            let startMs = firstBegin.isFinite ? (firstBegin - triggerAt) * 1000 : -1
            // Anything the tidy commits late (a debounced follow-up) lands here.
            m.fixture.drain(0.4)
            let tidyCommits = commits
            let tidied = frames()
            let moved = all.filter { before[$0] != tidied[$0] }
            var movedZones = Set<UUID>()
            for (zone, ids) in m.tiles where liveZones.contains(zone) && ids.contains(where: { before[$0] != tidied[$0] }) { movedZones.insert(zone) }
            if movedZones.count != liveZones.count {
                failures.append("D: Tidy canvas tidied \(movedZones.count) of the \(liveZones.count) live zones")
            }
            for (id, rect) in dormantRects where canvas.zoneWorldRect(id) != rect {
                failures.append("D: Tidy canvas changed zone \(id), which is not live (its tiles were not in the scene): \(rect) -> \(String(describing: canvas.zoneWorldRect(id)))")
            }
            for id in dormantZones where dormantRects[id] == nil {
                failures.append("D: zone \(id) is not live and has no rect to compare")
            }
            if tidyCommits != 1 { failures.append("D: Tidy canvas committed \(tidyCommits) layouts, expected 1: \(commitShapes)") }
            if startMs < 0 { failures.append("D: no committed movement found") }
            if !canvas.qaAutoLayoutUndoText.contains("Auto layout arranged") { failures.append("D: no Undo offered") }
            if canvas.viewport != camera { failures.append("D: Tidy canvas moved the camera") }
            guard canvas.qaClickAutoLayoutUndo() else { throw Failure(message: "D: Undo was not actionable") }
            settle(m)
            let restored = frames()
            let unrestored = all.filter { restored[$0] != before[$0] }
            if !unrestored.isEmpty { failures.append("D: one Undo left \(unrestored.count) of \(all.count) tiles un-restored") }
            let s = canvas.qaAutoLayoutStageTimes
            notes.append(String(format: "D: Tidy canvas, 6 zones x 15 tiles (%d live, %d dormant): %d tiles moved in %d zones, %d commit, one Undo restored all %d; motion start %.1f ms (call %.1f: solve %.1f, apply %.1f, present layout %.1f, flush %.1f, persist %.1f)",
                                liveZones.count, dormantZones.count, moved.count, movedZones.count, tidyCommits, all.count, startMs, callMs,
                                s.solve, s.apply, s.presentLayout, s.presentFlush, s.persist))
        }

        notes.forEach { print("tidy-camera: \($0)") }
        guard failures.isEmpty else {
            throw Failure(message: "\(failures.count) failed:\n  " + failures.joined(separator: "\n  "))
        }
    }
}
