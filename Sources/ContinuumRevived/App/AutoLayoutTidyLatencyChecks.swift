import AppKit
import ContinuumRevivedCore
import ObjectiveC
import QuartzCore

/// `--auto-layout-tidy-latency-check` (overnight auto-layout program, stream 2).
///
/// Dylan: tidy "is laggy and delayed". This leg measures the time from the
/// trigger to the start of the movement on the production path, at 4, 12, 30
/// and 89 tiles in one zone:
///
/// - **Tidy Zone Now**: the zone header's context menu item, performed the way
///   the menu performs it, on a scene mounted by `mountWorkspaceSceneAtBoot`
///   with launch's callbacks (so the commit reaches `persistLayoutTransaction`
///   and the real stores).
/// - **Drag release**: a title-bar drag sent through `NSApp.sendEvent` with the
///   production focus monitor installed (the `--canvas-pointer-path-check`
///   pattern), so the release reaches the settle and commit the user's does.
///
/// Every scenario is broken into the Array-owned stages the canvas clocks
/// (`CanvasNSView.qaAutoLayoutStageTimes`) plus the end of the run-loop turn
/// (view layout, display, and the CA flush — published, never gated as Array
/// cost: see memory flush-is-not-array-cpu). The movement can start only when
/// the trigger's run-loop turn ends, so "delay before the animation starts" is
/// the synchronous main-thread time of the trigger plus that turn's layout.
@MainActor
enum AutoLayoutTidyLatencyChecks {
    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    typealias Fixture = WorkspaceInvariantsFixture

    private final class KeyWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
        override var isKeyWindow: Bool { true }
    }

    private static func acceptFirstMouseEverywhere() {
        guard let method = class_getInstanceMethod(NSView.self, #selector(NSView.acceptsFirstMouse(for:))) else { return }
        let always: @convention(block) (NSView, NSEvent?) -> Bool = { _, _ in true }
        method_setImplementation(method, imp_implementationWithBlock(always))
    }

    static var tileCounts: [Int] {
        ProcessInfo.processInfo.environment["ALN_TIDY_COUNTS"].map { $0.split(separator: ",").compactMap { Int($0) } }
            ?? [4, 12, 30, 89]
    }
    static var repetitions: Int { Int(ProcessInfo.processInfo.environment["ALN_TIDY_REPS"] ?? "") ?? 5 }

    /// Budgets, in ms, on the app-side work between the trigger and the commit
    /// that starts the movement (see the gate in `summarize`).
    static let appSideBudgetMs: [Int: Double] = [4: 6, 12: 10, 30: 20, 89: 50]

    struct Sample {
        var trigger = 0.0          // synchronous: the menu action / mouse-up returns
        var layout = 0.0           // end of turn: view layout
        var display = 0.0          // end of turn: display
        var flush = 0.0            // end of turn: CA commit (compositor; published only)
        var stages = CanvasNSView.AutoLayoutStageTimes()
        var animatedViews = 0      // tile/zone views carrying a position animation after the first commit
        var animationDelay = 0.0   // max (animation beginTime - commit time), ms; 0 = starts with the commit
        var animationDuration = 0.0
        var maxStallAfter = 0.0    // longest main-thread busy stretch in the 400 ms that follow
        var movedTiles = 0
        var movementStart = 0.0    // trigger → the commit that carries the first position animation, ms
        var beginTimes = 0         // animations whose beginTime CA stamped (vs. inferred from the commit)
        var needLayout: [String: Int] = [:]
        var needDisplay: [String: Int] = [:]
        var layersNeedDisplay = 0
        var menuOverhead = 0.0
        var animatedAtPersist = 0  // moved tiles whose position animation CA had committed when the durable write ran
        var titleRedraws = 0       // title-bar invalidations on the moved tiles (a pure move draws nothing new)
        var tileInvalidations = 0  // `invalidateForCanvasLayout` on the moved tiles (same reason)
        var dragEvent = 0.0        // drag release only: median mouseDragged handling, ms
        var dragEventMax = 0.0
    }

    static func run() throws -> URL {
        acceptFirstMouseEverywhere()
        var rows: [[String: Any]] = []
        var failures: [String] = []
        var table: [String] = []
        for count in tileCounts {
            let tidy = try measure(count: count, scenario: .tidyMenu)
            let drag = try measure(count: count, scenario: .dragRelease)
            for (name, samples) in [("tidy", tidy), ("drag-release", drag)] {
                let row = summarize(name: name, count: count, samples: samples)
                rows.append(row.json)
                table.append(row.line)
                failures += row.failures
            }
        }
        let directory = URL(fileURLWithPath: "qa-runs/aln-tidy-latency", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let artifact = directory.appendingPathComponent(
            ProcessInfo.processInfo.environment["ALN_TIDY_LATENCY_LABEL"].map { "\($0).json" } ?? "latest.json")
        let data = try JSONSerialization.data(withJSONObject: ["rows": rows], options: [.prettyPrinted, .sortedKeys])
        try data.write(to: artifact, options: .atomic)
        print("scenario            n   trigger  solve   apply  anim   begin  finish capt   persist notify undo  | layout display flush | animViews delay dur  stall")
        table.forEach { print($0) }
        print("artifact: \(artifact.path)")
        guard failures.isEmpty else {
            throw Failure(message: "\(failures.count) failed:\n  " + failures.joined(separator: "\n  "))
        }
        return artifact
    }

    enum Scenario { case tidyMenu, dragRelease }

    // MARK: - Fixture

    static func tileId(_ index: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-0000%08X", 0x7A1D_0000 + index))!
    }

    /// A deliberately untidy zone: uneven gaps, three sizes, rows that do not
    /// line up, so tidy has real work and moves almost every tile.
    static func messyFrames(count: Int, origin: ZonePoint) -> (frames: [TileFrame], size: ZoneSize) {
        let columns = max(2, Int(Double(count).squareRoot().rounded(.up)))
        let sizes: [(Double, Double)] = [(240, 160), (320, 220), (400, 260)]
        var frames: [TileFrame] = []
        for index in 0..<count {
            let column = index % columns, row = index / columns
            let size = sizes[index % sizes.count]
            frames.append(TileFrame(
                x: origin.x + 40 + Double(column) * 470 + Double((index * 37) % 50),
                y: origin.y + 70 + Double(row) * 320 + Double((index * 53) % 40),
                width: size.0, height: size.1))
        }
        let rows = (count + columns - 1) / columns
        return (frames, ZoneSize(width: Double(columns) * 470 + 120, height: Double(rows) * 320 + 160))
    }

    struct Mount {
        let fixture: Fixture
        let mounted: Fixture.Mounted
        let window: NSWindow
        let ids: [UUID]
    }

    static func mount(count: Int) throws -> Mount {
        let fixture = try Fixture(label: "tidy-latency-\(count)")
        let workspaceStore = WorkspaceStore(workspaceId: Fixture.workspaceA, applicationSupportDirectory: fixture.appSupport)
        var document = try workspaceStore.load()
        guard let a1 = document.zones.firstIndex(where: { $0.zoneId == Fixture.zoneA1 }) else {
            throw Failure(message: "fixture has no zone A1")
        }
        let origin = document.zones[a1].origin
        let messy = messyFrames(count: count, origin: origin)
        document.zones[a1].size = messy.size
        // Keep the other zones clear of the grown A1, so nothing here measures a
        // zone-push the scenario did not ask for.
        let right = origin.x + messy.size.width + 400, below = origin.y + messy.size.height + 400
        if let a2 = document.zones.firstIndex(where: { $0.zoneId == Fixture.zoneA2 }) {
            document.zones[a2].origin = ZonePoint(x: right, y: origin.y)
        }
        if let a3 = document.zones.firstIndex(where: { $0.zoneId == Fixture.zoneA3 }) {
            document.zones[a3].origin = ZonePoint(x: origin.x, y: below)
        }
        try workspaceStore.save(document)

        let root = fixture.projectRoots[Fixture.projectA1]!
        let store = ProjectStore(projectRoot: root)
        var state = try store.loadCanvas()
        // A1's tiles are replaced; A3's note follows its zone.
        state.tiles.removeAll { $0.zoneId == Fixture.zoneA1 }
        if let note = state.tiles.firstIndex(where: { $0.id == Fixture.noteA3a }) {
            state.tiles[note].frame = TileFrame(x: origin.x + 40, y: below + 60, width: 240, height: 160)
        }
        var ids: [UUID] = []
        for (index, frame) in messy.frames.enumerated() {
            let id = tileId(index)
            ids.append(id)
            var tile = Tile(id: id, kind: .note, title: "note \(index)", frame: frame,
                            zPosition: .fromLegacyRank(index + 10), runtimeRef: nil,
                            metadata: TileMetadata(noteId: id))
            tile.zoneId = Fixture.zoneA1
            state.tiles.append(tile)
            try store.saveNoteBody(id: id, text: "note \(index)\nline two of the body")
        }
        try store.saveCanvas(state)

        try fixture.mount()
        let mounted = try fixture.requireMounted("tidy latency")
        let canvas = mounted.canvas
        _ = ZoneTruthChecks.pinPreferences(canvas, autoLayout: true)
        canvas.autoLayoutReduceMotionProvider = { false }
        let zoom = min(1, min(2600 / (messy.size.width + 200), 1400 / (messy.size.height + 200)))
        canvas.setViewport(CanvasViewport(x: origin.x - 100, y: origin.y - 100, zoom: zoom))
        let window = KeyWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = canvas
        window.orderFrontOffscreenForChecks()
        window.makeKey()
        mounted.delegate.qaInstallTileFocusMonitor()
        canvas.layoutSubtreeIfNeeded()
        canvas.displayIfNeeded()
        CATransaction.flush()
        fixture.drain(0.3)
        let missing = ids.filter { canvas.tileView(for: $0) == nil }
        guard missing.isEmpty else {
            throw Failure(message: "n=\(count): production mount hydrated \(ids.count - missing.count) of \(ids.count) tiles")
        }
        return Mount(fixture: fixture, mounted: mounted, window: window, ids: ids)
    }

    // MARK: - Measurement

    static func clock() -> Double { CACurrentMediaTime() * 1000 }

    static func measure(count: Int, scenario: Scenario) throws -> [Sample] {
        let m = try mount(count: count)
        defer {
            m.mounted.delegate.qaRemoveTileFocusMonitor()
            m.window.orderOut(nil)
            m.fixture.dispose()
        }
        let canvas = m.mounted.canvas
        var samples: [Sample] = []
        var menuOverhead = 0.0
        // When the durable write runs, has the movement already started? Count
        // the tiles whose position animation CA has committed (a stamped
        // beginTime) at that moment.
        var animatedAtPersist = 0
        let persist = canvas.onLayoutCommitted
        canvas.onLayoutCommitted = { transaction in
            animatedAtPersist = m.ids.compactMap { canvas.tileView(for: $0)?.layer }.filter { layer in
                (layer.animationKeys() ?? []).contains { key in
                    guard let animation = layer.animation(forKey: key) as? CABasicAnimation else { return false }
                    return animation.keyPath == "position" && animation.beginTime > 0
                }
            }.count
            return persist?(transaction) ?? true
        }
        func titleRedraws() -> Int { m.ids.compactMap { canvas.tileView(for: $0)?.qaTitleBarRedrawCount }.reduce(0, +) }
        func tileInvalidations() -> Int {
            m.ids.compactMap { canvas.tileView(for: $0)?.qaCanvasLayoutInvalidationCount }.reduce(0, +)
        }
        func frames() -> [UUID: TileFrame] {
            Dictionary(canvas.allTilesInWorldFrames().map { ($0.id, $0.frame) }, uniquingKeysWith: { a, _ in a })
        }
        func send(_ type: NSEvent.EventType, _ point: NSPoint) throws {
            guard let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: m.window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
            else { throw Failure(message: "could not synthesize \(type)") }
            NSApp.sendEvent(event)
        }
        func header(_ id: UUID) throws -> NSPoint {
            guard let view = canvas.tileView(for: id), let host = canvas.superview else {
                throw Failure(message: "n=\(count): tile \(id) has no view")
            }
            var misses: [String] = []
            for step in [0.3, 0.2, 0.1, 0.05, 0.4, 0.5, 0.6, 0.7, 0.85] {
                let local = NSPoint(x: view.bounds.width * step, y: view.chromeBarHeight / 2)
                guard view.qaDragKindIsMove(at: local) else { misses.append("\(step): not move"); continue }
                let candidate = view.convert(local, to: nil)
                let hit = canvas.hitTest(canvas.convert(canvas.convert(candidate, from: nil), to: host))
                if hit === view || hit?.superview === view && !(hit is NSControl) { return candidate }
                misses.append("\(step): \(hit.map { String(describing: type(of: $0)) } ?? "nil")")
            }
            throw Failure(message: "n=\(count): tile \(id) has no empty title-bar point (zoom \(canvas.viewport.zoom), hits \(misses))")
        }
        func zoneHeaderMenuTidy() throws -> (NSMenu, Int) {
            guard let placement = canvas.qaLiveZonePlacement(Fixture.zoneA1) else {
                throw Failure(message: "n=\(count): zone A1 is not live")
            }
            let world = CGPoint(x: placement.origin.x + 60, y: placement.origin.y + Double(ZoneChromeNSView.headerHeight) / 2)
            let local = CanvasEngine.worldToScreen(world, viewport: canvas.viewport)
            let windowPoint = canvas.convert(local, to: nil)
            guard let event = NSEvent.mouseEvent(
                with: .rightMouseDown, location: windowPoint, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: m.window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1),
                  let menu = canvas.menu(for: event),
                  let index = menu.items.firstIndex(where: { $0.title == "Tidy Zone Now" }) else {
                throw Failure(message: "n=\(count): the zone header menu has no Tidy Zone Now")
            }
            return (menu, index)
        }

        for repetition in 0..<repetitions {
            let before = frames()
            animatedAtPersist = 0
            var titleRedrawsBefore = titleRedraws()
            var tileInvalidationsBefore = tileInvalidations()
            var sample = Sample()
            var triggerAt = 0.0
            switch scenario {
            case .tidyMenu:
                let (menu, index) = try zoneHeaderMenuTidy()
                canvas.qaAutoLayoutStageTimes = .init()
                let item = menu.items[index]
                if repetition == 0 {
                    // AppKit's own cost of performing a menu item, published, not
                    // gated: measured once, then undone.
                    let t0 = clock()
                    menu.performActionForItem(at: index)
                    menuOverhead = clock() - t0 - canvas.qaAutoLayoutStageTimes.tidy
                    _ = canvas.qaClickAutoLayoutUndo()
                    canvas.layoutSubtreeIfNeeded(); canvas.displayIfNeeded(); CATransaction.flush()
                    m.fixture.drain(0.3)
                    canvas.qaAutoLayoutStageTimes = .init()
                    // The undo re-lays out every tile; count from here.
                    titleRedrawsBefore = titleRedraws()
                    tileInvalidationsBefore = tileInvalidations()
                }
                // The dispatch the menu makes once it has done its own work.
                triggerAt = CACurrentMediaTime()
                let start = clock()
                NSApp.sendAction(item.action!, to: item.target, from: item)
                sample.trigger = clock() - start
                sample.menuOverhead = menuOverhead
            case .dragRelease:
                // A different tile each repetition, dragged over its neighbours
                // and released; the release settles and commits the zone.
                // The 400pt-wide size: its title bar has empty stretches at every zoom.
                let id = m.ids[(repetition * 3 + 2) % m.ids.count]
                let start = try header(id)
                let zoom = CGFloat(canvas.viewport.zoom)
                try send(.leftMouseDown, start)
                var dragTimes: [Double] = []
                for step in 1...6 {
                    let t0 = clock()
                    try send(.leftMouseDragged, NSPoint(x: start.x + CGFloat(step) * 40 * zoom, y: start.y - CGFloat(step) * 12 * zoom))
                    dragTimes.append(clock() - t0)
                }
                sample.dragEvent = dragTimes.sorted()[dragTimes.count / 2]
                sample.dragEventMax = dragTimes.max() ?? 0
                let end = NSPoint(x: start.x + 240 * zoom, y: start.y - 72 * zoom)
                canvas.layoutSubtreeIfNeeded(); canvas.displayIfNeeded(); CATransaction.flush()
                canvas.qaAutoLayoutStageTimes = .init()
                triggerAt = CACurrentMediaTime()
                let t0 = clock()
                try send(.leftMouseUp, end)
                sample.trigger = clock() - t0
            }
            sample.stages = canvas.qaAutoLayoutStageTimes
            sample.animatedAtPersist = animatedAtPersist
            sample.titleRedraws = titleRedraws() - titleRedrawsBefore
            sample.tileInvalidations = tileInvalidations() - tileInvalidationsBefore
            // Counted, not timed: what the end of the turn has to do.
            var needLayout: [String: Int] = [:], needDisplay: [String: Int] = [:], layersNeedDisplay = 0
            func walk(_ view: NSView) {
                let name = String(describing: type(of: view))
                if view.needsLayout { needLayout[name, default: 0] += 1 }
                if view.needsDisplay { needDisplay[name, default: 0] += 1 }
                if view.layer?.needsDisplay() == true { layersNeedDisplay += 1; needDisplay["layer:" + name, default: 0] += 1 }
                for sub in view.layer?.sublayers ?? [] where sub.delegate == nil && sub.needsDisplay() {
                    needDisplay["sublayer:" + String(describing: type(of: sub)) + " in " + name, default: 0] += 1
                }
                view.subviews.forEach(walk)
            }
            walk(canvas)
            sample.needLayout = needLayout
            sample.needDisplay = needDisplay
            sample.layersNeedDisplay = layersNeedDisplay
            // The end of the trigger's run-loop turn, split by stage.
            var t = clock()
            canvas.layoutSubtreeIfNeeded()
            sample.layout = clock() - t
            t = clock()
            canvas.displayIfNeeded()
            sample.display = clock() - t
            t = clock()
            CATransaction.flush()
            sample.flush = clock() - t
            let committedAt = CACurrentMediaTime()
            // Did the movement start with that commit?
            var delay = 0.0, duration = 0.0, animated = 0, firstBegin = Double.infinity, stamped = 0
            let views: [NSView] = m.ids.compactMap { canvas.tileView(for: $0) }
            for view in views {
                guard let layer = view.layer, let keys = layer.animationKeys(), !keys.isEmpty else { continue }
                for key in keys {
                    guard let animation = layer.animation(forKey: key) as? CABasicAnimation,
                          animation.keyPath == "position" || animation.keyPath == "frameOrigin" else { continue }
                    animated += 1
                    if animation.beginTime > 0 { stamped += 1 }
                    let begin = animation.beginTime > 0 ? layer.convertTime(animation.beginTime, to: nil) : committedAt
                    firstBegin = min(firstBegin, begin)
                    delay = max(delay, (begin - committedAt) * 1000)
                    duration = max(duration, animation.duration)
                    break
                }
            }
            sample.animatedViews = animated
            sample.beginTimes = stamped
            sample.movementStart = firstBegin.isFinite ? (firstBegin - triggerAt) * 1000 : 0
            sample.animationDelay = delay
            sample.animationDuration = duration * 1000
            sample.maxStallAfter = longestStall(during: 0.4)
            let after = frames()
            sample.movedTiles = m.ids.filter { before[$0] != after[$0] }.count
            samples.append(sample)
            // Back to the untidy scene for the next repetition.
            if scenario == .tidyMenu {
                guard canvas.qaClickAutoLayoutUndo() else {
                    throw Failure(message: "n=\(count): tidy offered no Undo on repetition \(repetition)")
                }
                canvas.layoutSubtreeIfNeeded(); canvas.displayIfNeeded(); CATransaction.flush()
                m.fixture.drain(0.3)
            }
        }
        return samples
    }

    /// The longest stretch the main run loop spent awake (after-waiting to
    /// before-waiting) while it runs for `seconds`.
    static func longestStall(during seconds: TimeInterval) -> Double {
        final class Box { var awakeSince: Double?; var longest = 0.0 }
        let box = Box()
        let activities: CFRunLoopActivity = [.afterWaiting, .beforeWaiting]
        let observer = CFRunLoopObserverCreateWithHandler(nil, activities.rawValue, true, 0) { _, activity in
            let now = CACurrentMediaTime() * 1000
            if activity == .afterWaiting { box.awakeSince = now }
            if activity == .beforeWaiting, let since = box.awakeSince {
                box.longest = max(box.longest, now - since)
                box.awakeSince = nil
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
        return box.longest
    }

    struct Row { var json: [String: Any]; var line: String; var failures: [String] }

    static func summarize(name: String, count: Int, samples: [Sample]) -> Row {
        func median(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        }
        func med(_ key: (Sample) -> Double) -> Double { median(samples.map(key)) }
        let stages: [(String, (Sample) -> Double)] = [
            ("trigger", { $0.trigger }), ("solve", { $0.stages.solve }), ("apply", { $0.stages.apply }),
            ("animate", { $0.stages.animate }), ("begin", { $0.stages.begin }), ("finish", { $0.stages.finish }),
            ("capture", { $0.stages.capture }), ("persist", { $0.stages.persist }), ("notify", { $0.stages.notify }),
            ("undo", { $0.stages.undo }), ("tidyCall", { $0.stages.tidy }), ("layout", { $0.layout }), ("display", { $0.display }), ("flush", { $0.flush }),
            ("animationDelay", { $0.animationDelay }), ("animationDuration", { $0.animationDuration }),
            ("maxStallAfter", { $0.maxStallAfter }), ("movementStart", { $0.movementStart }),
            ("menuOverhead", { $0.menuOverhead }),
            ("presentLayout", { $0.stages.presentLayout }), ("presentDisplay", { $0.stages.presentDisplay }),
            ("presentFlush", { $0.stages.presentFlush }), ("dragEvent", { $0.dragEvent }), ("dragEventMax", { $0.dragEventMax }),
        ]
        var json: [String: Any] = ["scenario": name, "tiles": count, "repetitions": samples.count]
        for (key, read) in stages {
            json[key + "Ms"] = (med(read) * 1000).rounded() / 1000
            json[key + "MaxMs"] = ((samples.map(read).max() ?? 0) * 1000).rounded() / 1000
        }
        json["solves"] = samples.map(\.stages.solves)
        json["animatedViews"] = samples.map(\.animatedViews)
        json["stampedBeginTimes"] = samples.map(\.beginTimes)
        json["animatedAtPersist"] = samples.map(\.animatedAtPersist)
        json["titleRedraws"] = samples.map(\.titleRedraws)
        json["tileInvalidations"] = samples.map(\.tileInvalidations)
        json["needLayout"] = samples.last?.needLayout ?? [:]
        json["needDisplay"] = samples.last?.needDisplay ?? [:]
        json["layersNeedDisplay"] = samples.map(\.layersNeedDisplay)
        json["movedTiles"] = samples.map(\.movedTiles)
        func f(_ v: Double) -> String { String(format: "%6.2f", v) }
        let line = "\(name.padding(toLength: 18, withPad: " ", startingAt: 0)) \(String(format: "%3d", count)) "
            + [med { $0.trigger }, med { $0.stages.solve }, med { $0.stages.apply }, med { $0.stages.animate },
               med { $0.stages.begin }, med { $0.stages.finish }, med { $0.stages.capture }, med { $0.stages.persist },
               med { $0.stages.notify }, med { $0.stages.undo }].map(f).joined(separator: " ")
            + (name == "tidy" ? " tidyCall " + f(med { $0.stages.tidy }) : "")
            + " | " + [med { $0.layout }, med { $0.display }, med { $0.flush }].map(f).joined(separator: " ")
            + " | \(samples.map(\.animatedViews).max() ?? 0)/\(samples.map(\.movedTiles).max() ?? 0) "
            + f(med { $0.animationDelay }) + f(med { $0.animationDuration }) + f(med { $0.maxStallAfter })
            + " | start " + f(med { $0.movementStart })
            + (name == "tidy" ? " (menu itself " + f(samples.first?.menuOverhead ?? 0) + ")" : "")
            + (name == "tidy" ? "" : " | drag event " + f(med { $0.dragEvent }) + " max " + f(med { $0.dragEventMax }))
        var failures: [String] = []
        if ProcessInfo.processInfo.environment["ALN_TIDY_LATENCY_GATE"] != "0" {
            for (index, sample) in samples.enumerated() where sample.movedTiles > 0 {
                let label = "\(name) n=\(count) rep \(index)"
                if sample.animatedViews == 0 {
                    failures.append("\(label): \(sample.movedTiles) tiles moved and none animated")
                }
                // The movement starts before the disk: every moved tile's
                // animation is committed by the time the durable write runs.
                if sample.animatedAtPersist < sample.animatedViews {
                    failures.append("\(label): the durable write ran before the movement started "
                        + "(\(sample.animatedAtPersist) of \(sample.animatedViews) animations committed)")
                }
                if sample.animationDelay > 1 {
                    failures.append("\(label): the animation begins \(f(sample.animationDelay)) ms after its commit")
                }
                if sample.titleRedraws > 0 || sample.tileInvalidations > 0 {
                    failures.append("\(label): moving tiles invalidated \(sample.titleRedraws) title bars and "
                        + "\(sample.tileInvalidations) tile surfaces; a move draws nothing new")
                }
            }
            // Wall-clock budget on the app side of the pre-movement path: the
            // canvas stages around the solve plus the presentation's layout and
            // display. The solve (the packer's own cost) and the CA flush
            // (compositor) are published above, never gated here. The FASTEST
            // repetition is gated, the estimator least moved by a loaded Mac
            // (a run under load doubled every median); the counted assertions
            // above are the deterministic half of this witness.
            let budget = appSideBudgetMs[count] ?? 50
            let appSide = samples.map { $0.stages.begin + $0.stages.apply + $0.stages.finish + $0.stages.capture
                + $0.stages.presentLayout + $0.stages.presentDisplay }.min() ?? 0
            if appSide > budget {
                failures.append("\(name) n=\(count): the app-side work before the movement took \(f(appSide)) ms (budget \(budget))")
            }
        }
        return Row(json: json, line: line, failures: failures)
    }
}
