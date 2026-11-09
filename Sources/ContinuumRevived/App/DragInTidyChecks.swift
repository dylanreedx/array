import AppKit
import ContinuumRevivedCore
import ObjectiveC

/// Does a tidied zone STAY tidy under everyday drags (`.plans/auto-layout-night`)?
/// Tidy now makes rows of tiles of different widths at exact gap contact, filling
/// the zone; the jelly interaction (latched swap, slide-in, single-axis pushes,
/// rest magnetism) was designed when tiles had similar sizes.
///
/// One zone of eight mixed tiles (two browsers, a terminal, two agents with real
/// records, three notes), tidied, then real drags through `NSApp.sendEvent` with
/// the focus monitor installed (`CanvasPointerPathChecks`' path): a wide-narrow
/// swap in one row, a swap across rows, a slide to a row's end, and a drag to the
/// zone's edge and back. After each drop: no overlaps, every tile inside the
/// zone, no tile resized by the drop, the zone never smaller than its members;
/// then a tidy restores the fill. Auto layout on.
@MainActor
enum DragInTidyChecks {
    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }
    typealias Fixture = WorkspaceInvariantsFixture

    final class KeyWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
        override var isKeyWindow: Bool { true }
    }

    private static func acceptFirstMouseEverywhere() {
        guard let method = class_getInstanceMethod(NSView.self, #selector(NSView.acceptsFirstMouse(for:))) else { return }
        let always: @convention(block) (NSView, NSEvent?) -> Bool = { _, _ in true }
        method_setImplementation(method, imp_implementationWithBlock(always))
    }

    private static var failures: [String] = []
    private static func check(_ condition: Bool, _ message: @autoclosure () -> String) {
        if !condition { failures.append(message()) }
    }

    static let zoneOrigin = ZonePoint(x: 400, y: 300)
    static let zoneSize = ZoneSize(width: 1700, height: 1100)

    struct Seed {
        let id: UUID
        let kind: TileKind
        let name: String
        let frame: TileFrame
    }

    static func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "D7A60000-0000-4000-8000-%012d", n))! }

    static let seeds: [Seed] = [
        Seed(id: id(1), kind: .browser, name: "web1", frame: TileFrame(x: 430, y: 360, width: 640, height: 360)),
        Seed(id: id(2), kind: .note, name: "note1", frame: TileFrame(x: 1090, y: 360, width: 300, height: 200)),
        Seed(id: id(3), kind: .managedAgent, name: "agent1", frame: TileFrame(x: 1410, y: 360, width: 400, height: 440)),
        Seed(id: id(4), kind: .terminal, name: "term", frame: TileFrame(x: 1830, y: 360, width: 240, height: 320)),
        Seed(id: id(5), kind: .browser, name: "web2", frame: TileFrame(x: 430, y: 830, width: 640, height: 360)),
        Seed(id: id(6), kind: .note, name: "note2", frame: TileFrame(x: 1090, y: 830, width: 300, height: 200)),
        Seed(id: id(7), kind: .managedAgent, name: "agent2", frame: TileFrame(x: 1410, y: 830, width: 400, height: 440)),
        Seed(id: id(8), kind: .note, name: "note3", frame: TileFrame(x: 1830, y: 830, width: 240, height: 200)),
    ]
    static var names: [UUID: String] { Dictionary(uniqueKeysWithValues: seeds.map { ($0.id, $0.name) }) }

    struct DropReport {
        let name: String
        let fillAfterTidy: Double
    }

    static func run() throws {
        acceptFirstMouseEverywhere()
        failures = []
        let fixture = try makeFixture()
        defer { fixture.dispose() }
        try fixture.mount()
        let host = try Host(fixture: fixture)
        defer { host.close() }

        try host.tidy()
        let tidiedFill = host.fill()
        check(tidiedFill >= 0.95, "precondition: the first tidy must fill the zone; fill \(String(format: "%.3f", tidiedFill))")
        print("drag-in-tidy: tidied \(host.describeRows())  fill \(String(format: "%.3f", tidiedFill))")

        var reports: [DropReport] = []
        func attempt(_ step: () throws -> DropReport) {
            do { reports.append(try step()) } catch { check(false, "\(error)") }
        }
        // 1. A wide browser onto a narrow note in its own row.
        if let (wide, narrow) = host.pairInOneRow(wideKind: .browser, narrowKind: .note) {
            attempt { try host.drop("swap wide \(names[wide]!) onto narrow \(names[narrow]!) (one row)",
                                    moving: wide, ontoCentreOf: narrow, sameRow: true) }
        } else { check(false, "precondition: no row holds both a browser and a note: \(host.describeRows())") }
        // 2. Across rows: a tile of the top row onto one in the next.
        if let (upper, lower) = host.pairAcrossRows() {
            attempt { try host.drop("swap \(names[upper]!) across rows onto \(names[lower]!)",
                                    moving: upper, ontoCentreOf: lower, sameRow: false) }
        } else { check(false, "precondition: the tidy made fewer than two rows: \(host.describeRows())") }
        // 3. Slide the first tile of a row to that row's end.
        if let (first, last) = host.rowEnds() {
            attempt { try host.slide("slide \(names[first]!) to the row's end past \(names[last]!)", first, pastRightOf: last) }
        }
        // 4. To the zone's right edge (still inside) and back.
        if let tile = host.rowEnds()?.0 {
            attempt { try host.edgeAndBack("drag \(names[tile]!) to the zone's edge and back", tile) }
        }

        for report in reports {
            print("drag-in-tidy: \(report.name): fill after tidy \(String(format: "%.3f", report.fillAfterTidy))")
        }
        guard failures.isEmpty else {
            throw Failure(message: "\(failures.count) failed:\n  " + failures.joined(separator: "\n  "))
        }
        print("DragInTidyChecks passed: every drop in a tidied mixed zone kept it legal, and tidy restored the fill")
    }

    private static func makeFixture() throws -> Fixture {
        let fixture = try Fixture(label: "drag-in-tidy")
        let store = WorkspaceStore(workspaceId: Fixture.workspaceA, applicationSupportDirectory: fixture.appSupport)
        var document = try store.load()
        guard let index = document.zones.firstIndex(where: { $0.zoneId == Fixture.zoneA1 }) else {
            throw Failure(message: "seed: zone A1 is missing")
        }
        document.zones[index].origin = zoneOrigin
        document.zones[index].size = zoneSize
        for other in [Fixture.zoneA2, Fixture.zoneA3] {
            if let i = document.zones.firstIndex(where: { $0.zoneId == other }) {
                document.zones[i].origin = ZonePoint(x: 4000 + Double(i) * 1200, y: 300)
            }
        }
        document.viewport = CanvasViewport(x: 300, y: 200, zoom: 0.9)
        try store.save(document)
        let root = fixture.projectRoots[Fixture.projectA1]!
        let project = ProjectStore(projectRoot: root)
        guard var canvas = try project.tryLoadCanvas() else { throw Failure(message: "seed: project A1 has no canvas") }
        canvas.tiles.removeAll { $0.zoneId == Fixture.zoneA1 }
        for (rank, seed) in seeds.enumerated() {
            let metadata: TileMetadata
            switch seed.kind {
            case .browser: metadata = TileMetadata(url: "about:blank")
            case .terminal: metadata = TileMetadata(launchProfileId: "shell", projectRelativeCwd: ".")
            case .managedAgent: metadata = TileMetadata(launchProfileId: "managed-agent", projectRelativeCwd: ".")
            default:
                metadata = TileMetadata(noteId: seed.id)
                try project.saveNoteBody(id: seed.id, text: seed.name)
            }
            var tile = Tile(id: seed.id, kind: seed.kind, title: seed.name, frame: seed.frame,
                            zPosition: .fromLegacyRank(20 + rank), runtimeRef: nil, metadata: metadata)
            tile.zoneId = Fixture.zoneA1
            canvas.tiles.append(tile)
        }
        try project.saveCanvas(canvas)
        let appSupport = fixture.appSupport
        fixture.configureMount = { delegate, _ in
            delegate.agentSupervisor = AgentSupervisor(
                store: AgentStore(applicationSupportDirectory: appSupport),
                makeRunner: { _ in ScriptedAgentRunner(script: [], holdUntilStopped: true) })
            for seed in seeds where seed.kind == .managedAgent {
                _ = delegate.agentSupervisor.spawn(
                    role: nil, prompt: nil, cwd: root, harness: .claudeCode,
                    model: "fixture/drag-in-tidy", thinking: "medium",
                    projectId: Fixture.projectA1, projectRoot: root, tileId: seed.id, displayName: seed.name)
            }
        }
        return fixture
    }

    @MainActor
    struct Host {
        let fixture: Fixture
        let mounted: Fixture.Mounted
        let window: KeyWindow
        /// The zone as it was when the last drag began.
        var lastZone: TileFrame? { get { Self.zoneAtDrag } nonmutating set { Self.zoneAtDrag = newValue } }
        static var zoneAtDrag: TileFrame?
        var canvas: CanvasNSView { mounted.canvas }

        init(fixture: Fixture) throws {
            self.fixture = fixture
            mounted = try fixture.requireMounted("drag in tidy")
            TileInsertSlideChecks.pin(mounted.canvas, autoLayout: true)
            window = KeyWindow(contentRect: mounted.canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = mounted.canvas
            window.orderFrontOffscreenForChecks()
            window.makeKey()
            mounted.delegate.qaInstallTileFocusMonitor()
            mounted.canvas.setViewport(CanvasViewport(x: 300, y: 200, zoom: 0.9))
            mounted.canvas.layoutSubtreeIfNeeded()
        }

        func close() {
            mounted.delegate.qaAgentSupervisor.stopAll()
            mounted.delegate.qaRemoveTileFocusMonitor()
            window.orderOut(nil)
            window.contentView = nil
        }

        func frames() -> [UUID: TileFrame] {
            Dictionary(uniqueKeysWithValues: (canvas.tilesInWorldFrames(forZoneId: Fixture.zoneA1) ?? []).map { ($0.id, $0.frame) })
        }
        func zoneRect() -> TileFrame? { canvas.zonePlacement(for: Fixture.zoneA1).map(CanvasEngine.zoneWorldFrame) }
        func content() -> TileFrame? {
            guard let zone = zoneRect() else { return nil }
            let padding = ZoneBoundsConfig.padding(defaults: canvas.autoLayoutDefaults)
            let header = Double(ZoneChromeNSView.headerHeight)
            return TileFrame(x: zone.x + padding, y: zone.y + header + padding,
                             width: zone.width - 2 * padding, height: zone.height - header - 2 * padding)
        }

        /// Members' bounding box over the content rect: 1 when tidy fills edge to edge.
        func fill() -> Double {
            let f = Array(frames().values)
            guard let c = content(), !f.isEmpty, c.width > 0, c.height > 0 else { return 0 }
            let minX = max(f.map(\.x).min()!, c.x), minY = max(f.map(\.y).min()!, c.y)
            let maxX = min(f.map { $0.x + $0.width }.max()!, c.x + c.width)
            let maxY = min(f.map { $0.y + $0.height }.max()!, c.y + c.height)
            return max(0, maxX - minX) * max(0, maxY - minY) / (c.width * c.height)
        }

        /// Rows by top edge (within 4pt), each left to right.
        func rows() -> [[UUID]] {
            let f = frames()
            var rows: [[UUID]] = []
            for id in f.keys.sorted(by: { (f[$0]!.y, f[$0]!.x) < (f[$1]!.y, f[$1]!.x) }) {
                if let last = rows.last?.first, abs(f[last]!.y - f[id]!.y) < 4 { rows[rows.count - 1].append(id) }
                else { rows.append([id]) }
            }
            return rows.map { $0.sorted { f[$0]!.x < f[$1]!.x } }
        }
        func describeRows() -> String {
            let f = frames()
            return rows().map { $0.map { "\(DragInTidyChecks.names[$0] ?? "?") \(Int(f[$0]!.width))x\(Int(f[$0]!.height))" }.joined(separator: " | ") }
                .joined(separator: " // ")
        }
        func kind(_ id: UUID) -> TileKind? { DragInTidyChecks.seeds.first { $0.id == id }?.kind }

        func pairInOneRow(wideKind: TileKind, narrowKind: TileKind) -> (UUID, UUID)? {
            let f = frames()
            for row in rows() {
                guard let wide = row.first(where: { kind($0) == wideKind }),
                      let narrow = row.first(where: { kind($0) == narrowKind && f[$0]!.width < f[wide]!.width - 40 }) else { continue }
                return (wide, narrow)
            }
            return nil
        }
        func pairAcrossRows() -> (UUID, UUID)? {
            let r = rows()
            guard r.count >= 2, let upper = r[0].first, let lower = r[1].last, upper != lower else { return nil }
            return (upper, lower)
        }
        func rowEnds() -> (UUID, UUID)? {
            guard let row = rows().first(where: { $0.count >= 3 }) ?? rows().first(where: { $0.count >= 2 }),
                  let first = row.first, let last = row.last else { return nil }
            return (first, last)
        }

        func tidy() throws {
            guard mounted.delegate.qaPerformPaletteAction(.tidyCanvas) else { throw Failure(message: "palette refused Tidy Canvas") }
            canvas.layoutSubtreeIfNeeded()
            fixture.drain(0.3)
        }

        // MARK: Events

        private func send(_ type: NSEvent.EventType, _ point: NSPoint) throws {
            guard let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                pressure: type == .leftMouseUp ? 0 : 1)
            else { throw Failure(message: "could not synthesize \(type)") }
            NSApp.sendEvent(event)
        }

        /// An empty point of the tile's title bar, in window space.
        func grabPoint(_ id: UUID) throws -> NSPoint {
            guard let view = canvas.tileView(for: id) else { throw Failure(message: "tile \(DragInTidyChecks.names[id] ?? "?") has no view") }
            guard let host = canvas.superview else { throw Failure(message: "canvas has no host") }
            let rows = [0.5, 0.35, 0.65, 0.2, 0.8].map { view.chromeBarHeight * $0 }
            let w = view.bounds.width
            // Fractions, then absolute points near both ends: a browser's address
            // field covers most of its bar.
            let xs = [0.12, 0.88, 0.5, 0.3, 0.7, 0.06, 0.94].map { w * $0 } + [10, 16, 24, 32, w - 10, w - 16, w - 24]
            var tried: [String] = []
            for y in rows {
                for x in xs {
                    let local = NSPoint(x: x, y: y)
                    let move = view.qaDragKindIsMove(at: local)
                    let candidate = view.convert(local, to: nil)
                    let hit = canvas.hitTest(canvas.convert(canvas.convert(candidate, from: nil), to: host))
                    if tried.count < 8 { tried.append("(\(Int(x)),\(Int(y))) move=\(move) hit=\(hit.map { String(describing: type(of: $0)) } ?? "nil")") }
                    guard move else { continue }
                    if hit === view || (hit?.isDescendant(of: view) == true && !(hit is NSControl)) { return candidate }
                }
            }
            throw Failure(message: "tile \(DragInTidyChecks.names[id] ?? "?") \(view.frame) has no empty title-bar point; \(tried)")
        }

        /// Press at `grab`, move along `path` (world points, cumulative from the
        /// grab), dwelling on the last point long enough for a latch, release.
        func drag(_ id: UUID, worldPath: [CGVector]) throws {
            var trajectory: [String] = []
            lastZone = zoneRect()
            let grab = try grabPoint(id)
            let grabCanvas = canvas.convert(grab, from: nil)
            let zoom = canvas.viewport.zoom
            func window(_ v: CGVector) -> NSPoint {
                canvas.convert(NSPoint(x: grabCanvas.x + v.dx * zoom, y: grabCanvas.y + v.dy * zoom), to: nil)
            }
            try send(.leftMouseDown, grab)
            fixture.drain(0.03)
            let names = DragInTidyChecks.names
            func line(_ label: String) -> String {
                let f = frames()
                let slot = canvas.autoLayoutLatchedSlot.map { "slot(\(Int($0.x)),\(Int($0.y)) \(Int($0.width))x\(Int($0.height)))" } ?? "no slot"
                return label + " " + slot + " " + f.keys.sorted { names[$0] ?? "" < names[$1] ?? "" }
                    .map { "\(names[$0] ?? "?")(\(Int(f[$0]!.x)),\(Int(f[$0]!.y)))" }.joined(separator: " ")
            }
            for (index, step) in worldPath.enumerated() {
                try send(.leftMouseDragged, window(step))
                canvas.layoutSubtreeIfNeeded()
                fixture.drain(0.016)
                if index % 4 == 3 || index == worldPath.count - 1 {
                    trajectory.append(line(String(format: "  f%02d d(%+5.0f,%+5.0f)", index, step.dx, step.dy)))
                }
            }
            // Dwell: the latch is a decision at rest (.plans/107).
            fixture.drain(0.5)
            trajectory.append(line("  dwell        "))
            try send(.leftMouseUp, window(worldPath.last ?? CGVector(dx: 0, dy: 0)))
            canvas.layoutSubtreeIfNeeded()
            fixture.drain(0.5)
            trajectory.append(line("  dropped      "))
            print("drag-in-tidy trajectory \(names[id] ?? "?"):\n" + trajectory.joined(separator: "\n"))
        }

        func ramp(to target: CGVector, frames: Int = 24) -> [CGVector] {
            (1...frames).map { i in let t = Double(i) / Double(frames); return CGVector(dx: target.dx * t, dy: target.dy * t) }
        }

        /// The grab point in WORLD space: where the pointer presses.
        func grabWorld(_ id: UUID) throws -> CGPoint {
            let canvasPoint = canvas.convert(try grabPoint(id), from: nil)
            return CanvasEngine.screenToWorld(canvasPoint, viewport: canvas.viewport)
        }

        /// `sameRow`: an exchange within one row keeps the row's length, so the
        /// zone must not grow; across rows, a row that gets longer may grow it.
        func drop(_ name: String, moving id: UUID, ontoCentreOf target: UUID, sameRow: Bool) throws -> DropReport {
            let before = frames()
            guard let b = before[target] else { throw Failure(message: "\(name): missing tiles") }
            // The POINTER goes to the target's centre, as a user aims a swap: the
            // latch follows the pointer, not the dragged tile's centre.
            let grab = try grabWorld(id)
            let delta = CGVector(dx: (b.x + b.width / 2) - grab.x, dy: (b.y + b.height / 2) - grab.y)
            try drag(id, worldPath: ramp(to: delta))
            // It really exchanged: each now stands where the other stood, by row
            // (top edge) and, in one row, by order.
            let after = frames()
            if let a0 = before[id], let b0 = before[target], let a1 = after[id], let b1 = after[target] {
                let traded = abs(a1.y - b0.y) < 1 && abs(b1.y - a0.y) < 1
                    && (!sameRow || (a0.x < b0.x) == (a1.x > b1.x))
                DragInTidyChecks.check(traded, "\(name): the pair did not exchange places: \(DragInTidyChecks.names[id] ?? "?") \(a0) -> \(a1), \(DragInTidyChecks.names[target] ?? "?") \(b0) -> \(b1)")
            }
            return assess(name, before: before, swap: sameRow)
        }

        func slide(_ name: String, _ id: UUID, pastRightOf last: UUID) throws -> DropReport {
            let before = frames()
            guard let a = before[id], let l = before[last] else { throw Failure(message: "\(name): missing tiles") }
            let delta = CGVector(dx: (l.x + l.width) - (a.x + a.width) + 24, dy: 0)
            try drag(id, worldPath: ramp(to: delta, frames: 30))
            return assess(name, before: before)
        }

        func edgeAndBack(_ name: String, _ id: UUID) throws -> DropReport {
            let before = frames()
            guard let a = before[id], let zone = zoneRect() else { throw Failure(message: "\(name): missing tile") }
            let out = CGVector(dx: (zone.x + zone.width - 40) - (a.x + a.width / 2), dy: 0)
            try drag(id, worldPath: ramp(to: out) + ramp(to: out).reversed().dropFirst() + [CGVector(dx: 0, dy: 0)])
            return assess(name, before: before)
        }

        /// The invariants after one drop, then a tidy and its fill.
        func assess(_ name: String, before: [UUID: TileFrame], swap: Bool = false, zoneBefore: TileFrame? = nil) -> DropReport {
            let after = frames()
            // A swap inside a zone needs no room the zone did not have.
            if swap, let was = zoneBefore ?? lastZone, let now = zoneRect() {
                DragInTidyChecks.check(abs(now.x - was.x) < 0.5 && abs(now.y - was.y) < 0.5
                    && now.width <= was.width + 0.5 && now.height <= was.height + 0.5,
                    "\(name): a swap grew or moved the zone \(was) -> \(now)")
            }
            let names = DragInTidyChecks.names
            if let landed = after.values.map({ $0.y }).min(), let zone = zoneRect() {
                // A drop never flings a tile out above its zone's content.
                DragInTidyChecks.check(landed >= zone.y - 0.5, "\(name): a tile landed above the zone at y \(landed)")
            }
            DragInTidyChecks.check(Set(after.keys) == Set(before.keys),
                "\(name): the zone's members changed: \(Set(before.keys).symmetricDifference(after.keys).map { names[$0] ?? "?" })")
            let ids = after.keys.sorted { $0.uuidString < $1.uuidString }
            for (i, p) in ids.enumerated() {
                for q in ids.dropFirst(i + 1) {
                    let a = after[p]!, b = after[q]!
                    let overlap = a.x < b.x + b.width - 0.5 && b.x < a.x + a.width - 0.5
                        && a.y < b.y + b.height - 0.5 && b.y < a.y + a.height - 0.5
                    DragInTidyChecks.check(!overlap, "\(name): \(names[p] ?? "?") \(a) overlaps \(names[q] ?? "?") \(b)")
                }
            }
            if let zone = zoneRect() {
                for (id, f) in after {
                    DragInTidyChecks.check(f.x >= zone.x - 0.5 && f.y >= zone.y - 0.5
                        && f.x + f.width <= zone.x + zone.width + 0.5 && f.y + f.height <= zone.y + zone.height + 0.5,
                        "\(name): \(names[id] ?? "?") \(f) is outside the zone \(zone)")
                }
            }
            for (id, f) in after {
                guard let b = before[id] else { continue }
                DragInTidyChecks.check(abs(f.width - b.width) < 0.5 && abs(f.height - b.height) < 0.5,
                    "\(name): the drop resized \(names[id] ?? "?") \(Int(b.width))x\(Int(b.height)) -> \(Int(f.width))x\(Int(f.height))")
            }
            let rowsAfterDrop = describeRows() + "  frames " + after.sorted { $0.key.uuidString < $1.key.uuidString }
                .map { "\(names[$0.key] ?? "?")(\(Int($0.value.x)),\(Int($0.value.y)))" }.joined(separator: " ")
            try? tidy()
            let fill = self.fill()
            DragInTidyChecks.check(fill >= 0.95, "\(name): a tidy after the drop left fill \(String(format: "%.3f", fill)); rows \(describeRows())")
            print("drag-in-tidy: \(name): after drop \(rowsAfterDrop)")
            return DropReport(name: name, fillAfterTidy: fill)
        }
    }
}
