import AppKit
import ContinuumRevivedCore
import Foundation

/// Sliding a tile in between two others (`--tile-insert-slide-check`).
///
/// Before this, a member move could only SWAP: when the dragged tile's centre
/// entered a sibling, that sibling latched and took the dragged tile's origin,
/// so in `A B C D` dragging D onto B gave `A D C B`. Now the pointer over a
/// sibling's outer quarter (or the gap) slides the row apart around an empty
/// slot and the drop lands in it: `A D B C`. Over a sibling's middle half, or
/// with ⌥ held, it still swaps.
///
/// Mounted through `mountWorkspaceSceneAtBoot` (`WorkspaceInvariantsFixture`),
/// with zone A1 moved to world (400, 300) so a zone-local/world mix-up shows,
/// and driven by real `TileNSView` mouse events.
@MainActor
enum TileInsertSlideChecks {
    typealias Fixture = WorkspaceInvariantsFixture

    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String) throws {
        if !condition() { throw Failure(message: message()) }
    }

    static let tileA = UUID(uuidString: "00000000-0000-0000-0000-00000051DE0A")!
    static let tileB = UUID(uuidString: "00000000-0000-0000-0000-00000051DE0B")!
    static let tileC = UUID(uuidString: "00000000-0000-0000-0000-00000051DE0C")!
    static let tileD = UUID(uuidString: "00000000-0000-0000-0000-00000051DE0D")!
    static let tileE = UUID(uuidString: "00000000-0000-0000-0000-00000051DE0E")!
    static let names: [UUID: String] = [tileA: "A", tileB: "B", tileC: "C", tileD: "D", tileE: "E"]
    static let gap = 8.0
    static let zoneOrigin = ZonePoint(x: 400, y: 300)
    static let zoneSize = ZoneSize(width: 1240, height: 600)
    /// One row, unequal widths and heights, tops aligned, exact 8pt gaps.
    static let row: [(UUID, TileFrame)] = [
        (tileA, TileFrame(x: 440, y: 380, width: 240, height: 160)),
        (tileB, TileFrame(x: 688, y: 380, width: 300, height: 200)),
        (tileC, TileFrame(x: 996, y: 380, width: 260, height: 180)),
        (tileD, TileFrame(x: 1264, y: 380, width: 320, height: 220)),
    ]
    /// A second row, for the cross-row leg only.
    static let lower: (UUID, TileFrame) = (tileE, TileFrame(x: 440, y: 620, width: 240, height: 160))
    static var seeded: [UUID: TileFrame] { Dictionary(uniqueKeysWithValues: row + [lower]) }

    /// Zone A1 at (400, 300) holding exactly the row (and, if asked, a second
    /// row); zone A2 moves out of its way. The rest of the seed stays.
    static func makeFixture(_ label: String, secondRow: Bool = false) throws -> Fixture {
        let fixture = try Fixture(label: "insert-slide-\(label)")
        let store = WorkspaceStore(workspaceId: Fixture.workspaceA, applicationSupportDirectory: fixture.appSupport)
        var document = try store.load()
        guard let index = document.zones.firstIndex(where: { $0.zoneId == Fixture.zoneA1 }) else {
            throw Failure(message: "seed: zone A1 is missing")
        }
        document.zones[index].origin = zoneOrigin
        document.zones[index].size = zoneSize
        if let a2 = document.zones.firstIndex(where: { $0.zoneId == Fixture.zoneA2 }) {
            document.zones[a2].origin = ZonePoint(x: 2600, y: 260)
        }
        try store.save(document)
        let project = ProjectStore(projectRoot: fixture.projectRoots[Fixture.projectA1]!)
        guard var canvas = try project.tryLoadCanvas() else { throw Failure(message: "seed: project A1 has no canvas") }
        canvas.tiles.removeAll { $0.zoneId == Fixture.zoneA1 }
        for (rank, (id, frame)) in (secondRow ? row + [lower] : row).enumerated() {
            var tile = Tile(id: id, kind: .note, title: names[id]!, frame: frame,
                            zPosition: .fromLegacyRank(20 + rank), runtimeRef: nil, metadata: TileMetadata(noteId: id))
            tile.zoneId = Fixture.zoneA1
            canvas.tiles.append(tile)
            try project.saveNoteBody(id: id, text: names[id]!)
        }
        try project.saveCanvas(canvas)
        return fixture
    }

    static func pin(_ canvas: CanvasNSView, autoLayout: Bool) {
        let suite = "insert-slide-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        // Production defaults otherwise: magnetic snapping stays ON.
        defaults.set(true, forKey: DragMagnetizeConfig.enabledKey)
        defaults.set(autoLayout, forKey: CanvasAutoLayoutConfig.enabledKey)
        canvas.dragMagnetizeDefaults = defaults
        canvas.autoLayoutDefaults = defaults
        canvas.breakoutDefaults = defaults
        canvas.autoLayoutReduceMotionProvider = { true }
    }

    static func frames(_ canvas: CanvasNSView) -> [UUID: TileFrame] {
        Dictionary(uniqueKeysWithValues: (canvas.tilesInWorldFrames(forZoneId: Fixture.zoneA1) ?? [])
            .filter { names[$0.id] != nil }.map { ($0.id, $0.frame) })
    }

    static func order(_ frames: [UUID: TileFrame]) -> String {
        frames.sorted { $0.value.x < $1.value.x }.map { names[$0.key]! }.joined(separator: " ")
    }

    /// Real pointer events on a tile's title bar. `pointer` lists the WORLD
    /// points the pointer visits; `inspect` runs after the last drag, before the drop.
    static func drag(_ id: UUID, _ m: Fixture.Mounted, window: NSWindow, to pointer: [CGPoint],
                     option: Bool = false, inspect: () throws -> Void = {}) throws {
        guard let view = m.canvas.tileView(for: id) else { throw Failure(message: "tile \(names[id]!) has no view") }
        let flags: NSEvent.ModifierFlags = option ? [.option] : []
        func event(_ type: NSEvent.EventType, _ point: NSPoint) throws -> NSEvent {
            guard let e = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
            else { throw Failure(message: "could not synthesize \(type)") }
            return e
        }
        let grab = view.convert(NSPoint(x: view.bounds.midX, y: TileNSView.titleBarHeight / 2), to: nil)
        let start = seeded[id]!
        let grabWorld = CGPoint(x: start.x + start.width / 2, y: start.y + TileNSView.titleBarHeight / 2)
        view.mouseDown(with: try event(.leftMouseDown, grab))
        var last = grab
        for point in pointer {
            // Zoom 1; window y goes up, the canvas is flipped.
            last = NSPoint(x: grab.x + (point.x - grabWorld.x), y: grab.y - (point.y - grabWorld.y))
            view.mouseDragged(with: try event(.leftMouseDragged, last))
        }
        try inspect()
        view.mouseUp(with: try event(.leftMouseUp, last))
        m.canvas.layoutSubtreeIfNeeded()
    }

    static func dragD(_ m: Fixture.Mounted, window: NSWindow, to pointerWorldX: [Double],
                      option: Bool = false, inspect: () throws -> Void = {}) throws {
        let y = seeded[tileD]!.y + TileNSView.titleBarHeight / 2
        try drag(tileD, m, window: window, to: pointerWorldX.map { CGPoint(x: $0, y: y) }, option: option, inspect: inspect)
    }

    static func expectRow(_ frames: [UUID: TileFrame], _ expected: [UUID], zone: ZonePlacement?, _ label: String) throws {
        try expect(order(frames) == expected.map { names[$0]! }.joined(separator: " "),
                   "\(label): order is \(order(frames)), expected \(expected.map { names[$0]! }.joined(separator: " "))")
        for (left, right) in zip(expected, expected.dropFirst()) {
            let l = frames[left]!, r = frames[right]!
            try expect(abs(r.x - (l.x + l.width) - gap) < 0.01,
                       "\(label): the gap \(names[left]!)→\(names[right]!) is \(r.x - (l.x + l.width)), not \(gap)")
        }
        try expect(Set(expected.map { frames[$0]!.y }).count == 1, "\(label): tops are not aligned: \(expected.map { frames[$0]!.y })")
        for id in expected {
            try expect(frames[id]!.width == seeded[id]!.width && frames[id]!.height == seeded[id]!.height,
                       "\(label): \(names[id]!) changed size")
        }
        if let zone {
            let rect = CanvasEngine.zoneWorldFrame(zone)
            for id in expected {
                let f = frames[id]!
                try expect(f.x >= rect.x && f.y >= rect.y && f.x + f.width <= rect.x + rect.width
                           && f.y + f.height <= rect.y + rect.height,
                           "\(label): \(names[id]!) \(f) sits outside the zone \(rect)")
            }
        }
    }

    /// The drop's frames must be the ones on disk and the ones a remount draws.
    static func expectDurable(_ fixture: Fixture, _ shown: [UUID: TileFrame], _ label: String) throws {
        fixture.drain()
        let disk = Dictionary(uniqueKeysWithValues: (fixture.readProjectFile(Fixture.projectA1).canvas?.tiles ?? [])
            .filter { names[$0.id] != nil }.map { ($0.id, $0.frame) })
        try expect(disk == shown, "\(label): canvas.json holds \(order(disk)) \(disk), the screen \(order(shown)) \(shown)")
        try fixture.remount(crash: false)
        let remounted = frames(try fixture.requireMounted("\(label) remount").canvas)
        try expect(remounted == shown, "\(label): after a remount the row is \(order(remounted)) \(remounted)")
    }

    static func run() throws -> URL {
        var manifest: [String: Any] = [:]
        var failures: [String] = []
        let a = seeded[tileA]!, b = seeded[tileB]!, c = seeded[tileC]!, d = seeded[tileD]!
        func leg(_ name: String, _ body: () throws -> [String: Any]) {
            do { manifest[name] = try body() } catch { failures.append("\(name): \(error)") }
        }

        // 1. Slide: D to B's left quarter, passing C's centre on the way.
        leg("slide") {
            let fixture = try makeFixture("slide")
            defer { fixture.dispose() }
            try fixture.mount()
            let m = try fixture.requireMounted("slide")
            pin(m.canvas, autoLayout: true)
            let window = ZoneTruthChecks.hostInWindow(m.canvas)
            defer { window.orderOut(nil) }
            try expect(frames(m.canvas) == Dictionary(uniqueKeysWithValues: row),
                       "precondition: the row did not mount as seeded: \(frames(m.canvas))")
            let shift = d.width + gap
            try dragD(m, window: window, to: [c.x + c.width / 2, b.x + b.width / 8]) {
                let live = frames(m.canvas)
                try expect(live[tileA] == a, "during: A must not move; it is at \(String(describing: live[tileA]))")
                try expect(live[tileB]?.x == b.x + shift && live[tileB]?.y == b.y,
                           "during: THE feature. B must slide right by D.width+gap to \(b.x + shift); it is at "
                           + "\(String(describing: live[tileB])) (row \(order(live)))")
                try expect(live[tileC]?.x == c.x + shift && live[tileC]?.y == c.y,
                           "during: C must slide right by D.width+gap; it is at \(String(describing: live[tileC]))")
                let slot = TileFrame(x: a.x + a.width + gap, y: a.y, width: d.width, height: d.height)
                let expectedGhost = CanvasEngine.tileScreenFrame(slot, viewport: m.canvas.viewport)
                try expect(m.canvas.qaDragGhostFrame == expectedGhost,
                           "during: the ghost must show the slot at A.maxX+gap \(expectedGhost); it is at "
                           + "\(String(describing: m.canvas.qaDragGhostFrame))")
            }
            let shown = frames(m.canvas)
            try expectRow(shown, [tileA, tileD, tileB, tileC], zone: m.canvas.zonePlacement(for: Fixture.zoneA1), "drop")
            try expect(shown[tileA] == a, "drop: A must stay where it was")
            try expectDurable(fixture, shown, "slide")
            return ["order": order(shown)]
        }

        // 2. Swap: the pointer over B's middle half still exchanges.
        // 3. Swap with ⌥: B's left quarter, which would slide without it.
        for (name, pointerX, option) in [("swap-centre", b.x + b.width / 2, false),
                                         ("swap-option", b.x + b.width / 8, true)] {
            leg(name) {
                let fixture = try makeFixture(name)
                defer { fixture.dispose() }
                try fixture.mount()
                let m = try fixture.requireMounted(name)
                pin(m.canvas, autoLayout: true)
                let window = ZoneTruthChecks.hostInWindow(m.canvas)
                defer { window.orderOut(nil) }
                try dragD(m, window: window, to: [c.x + c.width / 2, pointerX], option: option)
                let shown = frames(m.canvas)
                try expectRow(shown, [tileA, tileD, tileC, tileB], zone: m.canvas.zonePlacement(for: Fixture.zoneA1), name)
                try expectDurable(fixture, shown, name)
                return ["order": order(shown)]
            }
        }

        // 4. From another row: E (below A) up to B's left quarter. It joins the
        //    row as A E B C D and the zone grows to hold the longer row.
        leg("cross-row") {
            let fixture = try makeFixture("cross", secondRow: true)
            defer { fixture.dispose() }
            try fixture.mount()
            let m = try fixture.requireMounted("cross")
            pin(m.canvas, autoLayout: true)
            let window = ZoneTruthChecks.hostInWindow(m.canvas)
            defer { window.orderOut(nil) }
            let e = seeded[tileE]!
            try expect(frames(m.canvas) == seeded, "precondition: the rows did not mount as seeded: \(frames(m.canvas))")
            let pointerY = b.y + 40
            try drag(tileE, m, window: window, to: [CGPoint(x: e.x + e.width / 2, y: 560), CGPoint(x: b.x + b.width / 8, y: pointerY)]) {
                let live = frames(m.canvas)
                let shift = e.width + gap
                try expect(live[tileA] == a, "during: A must not move")
                for (id, start) in [(tileB, b), (tileC, c), (tileD, d)] {
                    try expect(live[id]?.x == start.x + shift && live[id]?.y == start.y,
                               "during: \(names[id]!) must slide right by E.width+gap; it is at \(String(describing: live[id]))")
                }
            }
            let shown = frames(m.canvas)
            let zone = m.canvas.zonePlacement(for: Fixture.zoneA1)
            try expectRow(shown, [tileA, tileE, tileB, tileC, tileD], zone: zone, "cross-row drop")
            try expect((zone?.size.width ?? 0) > zoneSize.width,
                       "cross-row: the zone must grow to hold the longer row; it is \(String(describing: zone?.size))")
            try expectDurable(fixture, shown, "cross-row")
            return ["order": order(shown), "zoneWidth": zone?.size.width ?? 0]
        }

        // 5. Free-form (auto-layout off): D follows the pointer; nothing slides.
        leg("free-form") {
            let fixture = try makeFixture("free")
            defer { fixture.dispose() }
            try fixture.mount()
            let m = try fixture.requireMounted("free")
            pin(m.canvas, autoLayout: false)
            m.canvas.dragMagnetizeDefaults.set(false, forKey: DragMagnetizeConfig.enabledKey)
            let window = ZoneTruthChecks.hostInWindow(m.canvas)
            defer { window.orderOut(nil) }
            let pointerX = b.x + b.width / 8
            try dragD(m, window: window, to: [c.x + c.width / 2, pointerX]) {
                let live = frames(m.canvas)
                try expect(live[tileB] == b && live[tileC] == c, "free-form: nothing may slide; row is \(live)")
            }
            let shown = frames(m.canvas)
            let followed = d.x + (pointerX - (d.x + d.width / 2))
            try expect(shown[tileD]?.x == followed && shown[tileD]?.y == d.y,
                       "free-form: D must land where the pointer put it (x \(followed)); it is at \(String(describing: shown[tileD]))")
            try expect(shown[tileA] == a && shown[tileB] == b && shown[tileC] == c, "free-form: the others must not move: \(shown)")
            try expectDurable(fixture, shown, "free-form")
            return ["d": [shown[tileD]!.x, shown[tileD]!.y]]
        }

        let dir = URL(fileURLWithPath: "qa-runs/\(Int(Date().timeIntervalSince1970))/tile-insert-slide", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let artifact = dir.appendingPathComponent("manifest.json")
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(to: artifact)
        guard failures.isEmpty else {
            throw Failure(message: "\(failures.count) leg(s) failed:\n  " + failures.joined(separator: "\n  "))
        }
        return artifact
    }
}
