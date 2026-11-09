import AppKit
import ContinuumRevivedCore
import ObjectiveC

/// `--auto-layout-fanout-app-check` (.plans/107), through the user's path.
///
/// 1. Drag: a real mouse drag (`NSApp.sendEvent`, 16 ms apart) across a zone of
///    ten mixed-size tiles in the ragged layout the shipped placement made. Every
///    frame: at most `livePushBudget` other tiles move, none teleports (a big
///    step outside a latch change, or further than its rest-to-home distance),
///    and the release moves no bystander anywhere new. 0.7.35 moved 8 of 9 tiles
///    in one frame and flattened the zone into one line.
/// 2. Spawn: six ⌘K Agents, the camera centred on each new one in turn (as an
///    API reveal or the user's own jump does). The zone stays screen-shaped and
///    every new tile docks against another. 0.7.35 made a single row.
@MainActor
enum AutoLayoutFanoutChecks {
    typealias Fixture = WorkspaceInvariantsFixture
    struct Failure: Error, CustomStringConvertible { let description: String }

    private final class KeyWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
        override var isKeyWindow: Bool { true }
    }

    /// The user's app is active when they click; an inactive check app would
    /// eat the press as an activation click (as in `CanvasPointerPathChecks`).
    private static func acceptFirstMouseEverywhere() {
        guard let method = class_getInstanceMethod(NSView.self, #selector(NSView.acceptsFirstMouse(for:))) else { return }
        let always: @convention(block) (NSView, NSEvent?) -> Bool = { _, _ in true }
        method_setImplementation(method, imp_implementationWithBlock(always))
    }

    /// Evidence, not a witness: the real Settings modal, offscreen, on the
    /// Canvas pane (where "New tiles grow the zone" lives), light and dark.
    static func renderSettings(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            let suite = "fanout.settings.render.\(UUID().uuidString)"
            guard let defaults = QAIsolatedDefaults(isolatedSuiteName: suite) else {
                throw Failure(description: "could not create the isolated defaults suite")
            }
            defer { defaults.removePersistentDomain(forName: suite) }
            let model = SettingsModel(sections: SettingsSchema.sections(), defaults: defaults,
                                      navKeymap: .resolve(defaults: defaults, warn: { _ in }))
            let fixture = SettingsFixtureWindow(model: model, appearance: NSAppearance(named: appearanceName))
            defer { fixture.tearDown() }
            fixture.show(paneID: "canvasAndZones")
            fixture.settle(0.4)
            guard let view = fixture.window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                throw Failure(description: "settings render: no content view")
            }
            view.cacheDisplay(in: view.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else {
                throw Failure(description: "settings render: PNG encoding failed")
            }
            try png.write(to: directory.appendingPathComponent("settings-canvas-layout-\(name).png"))
        }
    }

    static func run() throws {
        acceptFirstMouseEverywhere()
        var failures: [String] = []
        do { failures += try dragAcrossRaggedZone() } catch { failures.append("drag: \(error)") }
        do { failures += try spawnWithCameraFollowing() } catch { failures.append("spawn: \(error)") }
        do { failures += try leadCluster() } catch { failures.append("cluster: \(error)") }
        do { failures += try tidyFillsZone() } catch { failures.append("tidy: \(error)") }
        guard failures.isEmpty else {
            throw Failure(description: "\(failures.count) failed:\n  " + failures.joined(separator: "\n  "))
        }
    }

    /// The 0.7.35 ragged layout (the probe's working zone), in zone A1's world space.
    private static let ragged: [(String, TileFrame)] = [
        ("Lead", TileFrame(x: 1724, y: 678, width: 640, height: 520)),
        ("H1", TileFrame(x: 2372, y: 678, width: 640, height: 520)),
        ("H2", TileFrame(x: 1076, y: 678, width: 640, height: 520)),
        ("H3", TileFrame(x: 1724, y: 1206, width: 640, height: 520)),
        ("Term", TileFrame(x: 1594, y: 86, width: 900, height: 584)),
        ("Note", TileFrame(x: 3020, y: 738, width: 640, height: 400)),
        ("Web", TileFrame(x: 44, y: 618, width: 1024, height: 640)),
        ("Edit", TileFrame(x: 1724, y: 1734, width: 640, height: 560)),
        ("Tree", TileFrame(x: 3020, y: 210, width: 360, height: 520)),
        ("Diff", TileFrame(x: 2372, y: 1206, width: 720, height: 520)),
    ]

    static func reseed(_ fixture: Fixture, zoneSize: ZoneSize, tiles: [(String, TileFrame)],
                               agents: Set<String> = [], browsers: Set<String> = []) throws -> [String: UUID] {
        let store = WorkspaceStore(workspaceId: Fixture.workspaceA, applicationSupportDirectory: fixture.appSupport)
        var document = try store.load()
        for (index, zone) in document.zones.enumerated() {
            if zone.zoneId == Fixture.zoneA1 {
                document.zones[index].origin = ZonePoint(x: 0, y: 0)
                document.zones[index].size = zoneSize
            } else {
                // Every other zone well out of the way: nothing here is about zones.
                document.zones[index].origin = ZonePoint(x: 20_000 + Double(index) * 4_000, y: 20_000)
            }
        }
        try store.save(document)
        let project = ProjectStore(projectRoot: fixture.projectRoots[Fixture.projectA1]!)
        guard var canvas = try project.tryLoadCanvas() else { throw Failure(description: "seed: project A1 has no canvas") }
        canvas.tiles.removeAll { $0.zoneId == Fixture.zoneA1 }
        var ids: [String: UUID] = [:]
        for (rank, (name, frame)) in tiles.enumerated() {
            let id = UUID()
            ids[name] = id
            let agent = agents.contains(name), browser = browsers.contains(name)
            var tile = Tile(id: id, kind: agent ? .managedAgent : browser ? .browser : .note, title: name, frame: frame,
                            zPosition: .fromLegacyRank(20 + rank), runtimeRef: nil,
                            metadata: agent ? TileMetadata(launchProfileId: "managed-agent", projectRelativeCwd: ".")
                                : browser ? TileMetadata(url: "about:blank") : TileMetadata(noteId: id))
            tile.zoneId = Fixture.zoneA1
            canvas.tiles.append(tile)
            if !agent && !browser { try project.saveNoteBody(id: id, text: name) }
        }
        try project.saveCanvas(canvas)
        return ids
    }

    private static func dragAcrossRaggedZone() throws -> [String] {
        let fixture = try Fixture(label: "fanout-drag")
        defer { fixture.dispose() }
        let ids = try reseed(fixture, zoneSize: ZoneSize(width: 3_700, height: 2_330), tiles: ragged)
        try fixture.mount()
        let m = try fixture.requireMounted("fanout drag")
        let canvas = m.canvas
        TileInsertSlideChecks.pin(canvas, autoLayout: true)
        if ProcessInfo.processInfo.environment["FANOUT_NO_MAGNET"] != nil {
            canvas.dragMagnetizeDefaults.set(false, forKey: DragMagnetizeConfig.enabledKey)
        }
        canvas.frame = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        let zoom = 0.4
        canvas.setViewport(CanvasViewport(x: -60, y: -60, zoom: zoom))
        let window = KeyWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = canvas
        window.orderFrontOffscreenForChecks()
        window.makeKey()
        defer { window.orderOut(nil) }
        m.delegate.qaInstallTileFocusMonitor()
        defer { m.delegate.qaRemoveTileFocusMonitor() }
        canvas.layoutSubtreeIfNeeded()

        func frames() -> [UUID: TileFrame] {
            Dictionary(canvas.allTilesInWorldFrames().filter { ids.values.contains($0.id) }.map { ($0.id, $0.frame) },
                       uniquingKeysWith: { a, _ in a })
        }
        let rest = frames()
        guard rest.count == ragged.count, ragged.allSatisfy({ rest[ids[$0.0]!] == $0.1 }) else {
            throw Failure(description: "precondition: the zone did not mount as seeded: \(rest.count) tiles")
        }
        guard let activeId = ids["H2"], let view = canvas.tileView(for: activeId), let home = rest[activeId] else {
            throw Failure(description: "precondition: H2 has no view")
        }
        guard let host = canvas.superview ?? Optional(canvas) else { throw Failure(description: "no host") }
        var grab: NSPoint?
        for step in [0.5, 0.3, 0.7, 0.2, 0.8] {
            let local = NSPoint(x: view.bounds.width * step, y: view.chromeBarHeight / 2)
            guard view.qaDragKindIsMove(at: local) else { continue }
            let candidate = view.convert(local, to: nil)
            let hit = canvas.hitTest(canvas.convert(canvas.convert(candidate, from: nil), to: host))
            if hit === view || hit?.superview === view && !(hit is NSControl) { grab = candidate; break }
        }
        guard let grab else { throw Failure(description: "precondition: H2 has no empty title-bar point") }

        var t = ProcessInfo.processInfo.systemUptime
        func send(_ type: NSEvent.EventType, _ point: NSPoint) throws {
            t += 0.016
            guard let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: t,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                pressure: type == .leftMouseUp ? 0 : 1)
            else { throw Failure(description: "could not synthesize \(type)") }
            NSApp.sendEvent(event)
            canvas.layoutSubtreeIfNeeded()
        }

        // The probe's working-zone drag: H2 right and down across the zone, eased,
        // with hand jitter, one event per 16 ms frame.
        let count = 96
        var steps: [CGVector] = []
        for i in 1...count {
            let s = Double(i) / Double(count)
            let eased = s < 0.5 ? 2 * s * s : 1 - pow(-2 * s + 2, 2) / 2
            let j = 5 * sin(Double(i) * 1.7) + 2.5 * sin(Double(i) * 0.43)
            steps.append(CGVector(dx: 1400 * eased + j * 0.4, dy: 420 * eased + j))
        }
        var failures: [String] = []
        let budget = CanvasAutoLayoutEngine.livePushBudget
        try send(.leftMouseDown, grab)
        var previous = rest
        var previousSlot = canvas.autoLayoutLatchedSlot
        var framesWithMotion = 0
        var last = grab
        for (index, step) in steps.enumerated() {
            last = NSPoint(x: grab.x + step.dx * zoom, y: grab.y - step.dy * zoom)
            try send(.leftMouseDragged, last)
            let now = frames()
            let slot = canvas.autoLayoutLatchedSlot
            var moved = 0
            for (id, frame) in now where id != activeId {
                guard let before = previous[id], let r = rest[id] else { continue }
                let d = max(abs(frame.x - before.x), abs(frame.y - before.y))
                if d > 0.5 { moved += 1 }
                let name = ids.first { $0.value == id }?.key ?? "?"
                if d > min(frame.width, frame.height) / 2, slot == previousSlot {
                    failures.append("frame \(index): \(name) jumped \(Int(d)) pt with no swap or slide-in starting")
                }
                let allowed = hypot(r.x - home.x, r.y - home.y) + max(r.width, r.height) / 4 + 1
                if d > allowed {
                    failures.append("frame \(index): \(name) teleported \(Int(d)) pt (its rest is \(Int(allowed)) pt from H2's home)")
                }
            }
            if ProcessInfo.processInfo.environment["FANOUT_TRACE"] != nil {
                let names = now.filter { id, f in id != activeId && previous[id].map { max(abs(f.x - $0.x), abs(f.y - $0.y)) > 0.5 } == true }
                    .map { id, f in "\(ids.first { $0.value == id }?.key ?? "?")(\(Int(f.x - rest[id]!.x)),\(Int(f.y - rest[id]!.y)))" }
                print("trace \(index) H2=\(now[activeId].map { "(\(Int($0.x)),\(Int($0.y)))" } ?? "-") slot=\(slot.map { "(\(Int($0.x)),\(Int($0.y)))" } ?? "-") moved=\(names.joined(separator: " "))")
            }
            // The pointer owns the dragged tile: the magnet may pull it at most
            // its release distance from where the pointer puts it.
            if let active = now[activeId] {
                let lag = max(abs(active.x - (home.x + step.dx)), abs(active.y - (home.y + step.dy)))
                let release = DragMagnetizeConfig.snapReleaseScreenPoints / zoom + 2
                if lag > release {
                    failures.append("frame \(index): H2 sits \(Int(lag)) pt from the pointer (the magnet may pull \(Int(release)))")
                }
            }
            if moved > budget { failures.append("frame \(index): \(moved) other tiles moved at once (at most \(budget))") }
            if moved > 0 { framesWithMotion += 1 }
            previous = now
            previousSlot = slot
        }
        let latchedAtRelease = canvas.autoLayoutLatchedSlot != nil
        try send(.leftMouseUp, last)
        let dropped = frames()
        guard let moverAfter = dropped[activeId], hypot(moverAfter.x - home.x, moverAfter.y - home.y) > 300 else {
            throw Failure(description: "the drag never moved H2: it is at \(String(describing: dropped[activeId]))")
        }
        if framesWithMotion == 0 {
            failures.append("control: no other tile reacted to the drag at all, so nothing above was exercised")
        }
        if !latchedAtRelease {
            for (id, frame) in dropped where id != activeId {
                guard let before = previous[id], let r = rest[id] else { continue }
                if max(abs(frame.x - before.x), abs(frame.y - before.y)) > 0.5, frame != r {
                    failures.append("release moved \(ids.first { $0.value == id }?.key ?? "?") somewhere new: \(frame)")
                }
            }
        }
        let all = Array(dropped.values)
        for (i, a) in all.enumerated() {
            for b in all.dropFirst(i + 1) where a.x < b.x + b.width - 0.5 && b.x < a.x + a.width - 0.5
                && a.y < b.y + b.height - 0.5 && b.y < a.y + a.height - 0.5 {
                failures.append("after the drop \(a) overlaps \(b)")
            }
        }
        print("auto-layout fan-out: real drag across a ragged 10-tile zone, \(framesWithMotion) frames with motion, "
              + "\(failures.isEmpty ? "no" : "\(failures.count)") violation(s)")
        return failures.map { "drag: " + $0 }
    }

    private static func spawnWithCameraFollowing() throws -> [String] {
        AgentModelCatalog.shared.resetForQA(snapshot: AgentHarnessCatalogSnapshot(
            harness: .pi, readiness: .ready, models: AgentCatalogQAFixture.pi))
        let savedArguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        var arguments = savedArguments
        arguments[AgentHarnessConfig.key] = AgentHarness.pi.rawValue
        arguments[AgentModelConfig.modelKey] = AgentCatalogQAFixture.pi[0]
        arguments[AgentModelConfig.thinkingKey] = AgentModelConfig.defaultThinking
        arguments[CanvasAutoLayoutConfig.enabledKey] = true
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        defer {
            UserDefaults.standard.setVolatileDomain(savedArguments, forName: UserDefaults.argumentDomain)
            AgentModelCatalog.shared.resetForQA()
        }
        let fixture = try Fixture(label: "fanout-spawn")
        defer { fixture.dispose() }
        let gap = TileGapResolver.resolvedGap()
        let padding = ZoneBoundsConfig.padding()
        let header = Double(ZoneChromeNSView.headerHeight)
        let lead = TileFrame(x: padding, y: header + padding, width: 640, height: 520)
        _ = try reseed(fixture, zoneSize: ZoneSize(width: 640 + 2 * padding, height: 520 + header + 2 * padding),
                       tiles: [("Lead", lead)])
        try fixture.mount()
        let m = try fixture.requireMounted("fanout spawn")
        defer { m.delegate.qaAgentSupervisor.stopAll() }
        guard m.canvas.isAutoLayoutEnabled else { throw Failure(description: "auto layout must be ON") }
        guard m.runtime.setActiveZone(Fixture.zoneA1, reason: .click) else { throw Failure(description: "zone A1 must arm") }
        let zoom = 0.55
        func members() -> [UUID: TileFrame] {
            Dictionary(m.canvas.allTilesInWorldFrames()
                .filter { m.canvas.qaZoneMembership(of: $0.id) == Fixture.zoneA1 }
                .map { ($0.id, $0.frame) }, uniquingKeysWith: { a, _ in a })
        }
        var newest = lead
        var failures: [String] = []
        for index in 1...6 {
            // The camera follows the newest tile, as an API reveal or a jump does.
            m.canvas.setViewport(CanvasViewport(
                x: newest.x + newest.width / 2 - Double(m.canvas.bounds.width) / zoom / 2,
                y: newest.y + newest.height / 2 - Double(m.canvas.bounds.height) / zoom / 2, zoom: zoom))
            let before = members()
            _ = m.delegate.qaPerformPaletteAction(.newManagedAgent)
            m.canvas.layoutSubtreeIfNeeded()
            let after = members()
            let created = Set(after.keys).subtracting(before.keys)
            guard created.count == 1, let id = created.first, let frame = after[id] else {
                throw Failure(description: "spawn \(index): ⌘K Agent created \(created.count) tile(s) in the zone")
            }
            let docked = after.contains { other in
                other.key != id && CanvasAutoLayoutEngine.isGapAdjacent(frame, other.value, gap: gap, tolerance: 1)
            }
            if !docked { failures.append("spawn \(index): \(frame) docks against no other tile") }
            newest = frame
        }
        let all = Array(members().values)
        for (i, a) in all.enumerated() {
            for b in all.dropFirst(i + 1) where a.x < b.x + b.width - 0.5 && b.x < a.x + a.width - 0.5
                && a.y < b.y + b.height - 0.5 && b.y < a.y + a.height - 0.5 {
                failures.append("\(a) overlaps \(b)")
            }
        }
        let minX = all.map(\.x).min()!, maxX = all.map { $0.x + $0.width }.max()!
        let minY = all.map(\.y).min()!, maxY = all.map { $0.y + $0.height }.max()!
        let aspect = (maxX - minX) / (maxY - minY)
        if !(0.8...3.0).contains(aspect) {
            failures.append("7 tiles with the camera following made a zone \(Int(maxX - minX))x\(Int(maxY - minY)) "
                            + "(aspect \(String(format: "%.2f", aspect))); it must stay screen-shaped, never a row")
        }
        print("auto-layout fan-out: six ⌘K Agents with the camera following made a "
              + "\(Int(maxX - minX))x\(Int(maxY - minY)) zone (aspect \(String(format: "%.2f", aspect)))")
        return failures.map { "spawn: " + $0 }
    }

    /// Model B (.plans/107): a lead with two half-height helpers, three notes
    /// pressed right against the cluster. (1) A helper dragged across its
    /// cluster and into a note moves no note, ever: only the cluster reacts.
    /// (2) The lead dragged away carries both helpers, rigidly, every frame.
    /// 3. Tidy (`.plans/auto-layout-night`): the zone's "Tidy Zone Now" entry,
    /// `CanvasNSView.tidyAutoLayout(zoneId:)`, on a mounted layered zone holding
    /// a lead with two helpers (real `AgentRecord` lineage), a browser and notes
    /// scattered with holes. The commit lands (no rejected transaction), the
    /// browser is 16:9, the lead and helpers form one block, the zone is filled
    /// edge to edge, the persisted canvas carries the tidied frames, and a
    /// second Tidy changes nothing.
    private static func tidyFillsZone() throws -> [String] {
        let tiles: [(String, TileFrame)] = [
            ("Web", TileFrame(x: 40, y: 90, width: 900, height: 700)),
            ("Lead", TileFrame(x: 1100, y: 60, width: 640, height: 520)),
            ("NoteA", TileFrame(x: 1900, y: 120, width: 520, height: 380)),
            ("H1", TileFrame(x: 80, y: 1000, width: 560, height: 480)),
            ("NoteB", TileFrame(x: 900, y: 1100, width: 640, height: 400)),
            ("H2", TileFrame(x: 1800, y: 1050, width: 600, height: 500)),
        ]
        let fixture = try Fixture(label: "fanout-tidy")
        defer { fixture.dispose() }
        let ids = try reseed(fixture, zoneSize: ZoneSize(width: 2_600, height: 1_800), tiles: tiles,
                             agents: ["Lead", "H1", "H2"], browsers: ["Web"])
        let root = fixture.projectRoots[Fixture.projectA1]!
        let appSupport = fixture.appSupport
        var agents: [String: AgentID] = [:]
        fixture.configureMount = { delegate, _ in
            delegate.agentSupervisor = AgentSupervisor(
                store: AgentStore(applicationSupportDirectory: appSupport),
                makeRunner: { _ in ScriptedAgentRunner(script: [], holdUntilStopped: true) })
            let lead = delegate.agentSupervisor.spawn(
                role: nil, prompt: nil, cwd: root, harness: .claudeCode, model: "fixture/cluster", thinking: "medium",
                projectId: Fixture.projectA1, projectRoot: root, tileId: ids["Lead"], displayName: "Lead")
            agents["Lead"] = lead
            for name in ["H1", "H2"] {
                agents[name] = delegate.agentSupervisor.spawn(
                    role: nil, prompt: nil, cwd: root, harness: .claudeCode, model: "fixture/cluster", thinking: "medium",
                    projectId: Fixture.projectA1, projectRoot: root, parentAgentID: lead, tileId: ids[name], displayName: name)
            }
        }
        try fixture.mount()
        let m = try fixture.requireMounted("fanout tidy")
        defer { m.delegate.qaAgentSupervisor.stopAll() }
        let canvas = m.canvas
        // Tidy is explicit: it must run with automatic layout switched off.
        TileInsertSlideChecks.pin(canvas, autoLayout: false)
        canvas.frame = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        canvas.setViewport(CanvasViewport(x: -60, y: -60, zoom: 0.5))
        let window = KeyWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = canvas
        window.orderFrontOffscreenForChecks()
        defer { window.orderOut(nil) }
        for name in ["Lead", "H1", "H2"] { m.delegate.wireManagedAgentTile(ids[name]!, agentID: agents[name]) }
        canvas.layoutSubtreeIfNeeded()

        func frames() -> [String: TileFrame] {
            var out: [String: TileFrame] = [:]
            for tile in canvas.allTilesInWorldFrames() {
                if let name = ids.first(where: { $0.value == tile.id })?.key { out[name] = tile.frame }
            }
            return out
        }
        var failures: [String] = []
        let rejectedBefore = canvas.qaRejectedLayoutTransactions
        let start = DispatchTime.now().uptimeNanoseconds
        canvas.tidyAutoLayout(zoneId: Fixture.zoneA1)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        canvas.layoutSubtreeIfNeeded()
        print(String(format: "  tidy: tidyAutoLayout(zoneId:) on the main thread %.1f ms (6 tiles, debug build)", elapsed))
        if canvas.qaRejectedLayoutTransactions != rejectedBefore { failures.append("tidy: the canvas rejected the tidy transaction") }
        let after = frames()
        guard after.count == tiles.count, let zone = canvas.qaLiveZonePlacement(Fixture.zoneA1) else {
            throw Failure(description: "tidy: lost tiles or the zone (\(after.count) of \(tiles.count))")
        }
        let padding = ZoneBoundsConfig.padding(defaults: canvas.autoLayoutDefaults)
        let header = Double(ZoneChromeNSView.headerHeight)
        let content = CGRect(x: zone.origin.x + padding, y: zone.origin.y + header + padding,
                             width: zone.size.width - 2 * padding, height: zone.size.height - header - 2 * padding)
        let area = after.values.reduce(0.0) { $0 + $1.width * $1.height }
        let fill = area / Double(content.width * content.height)
        print(String(format: "  tidy: zone %.0fx%.0f -> %.0fx%.0f, fill %.3f", 2_600.0, 1_800.0, zone.size.width, zone.size.height, fill))
        if fill < 0.8 { failures.append("tidy: the zone is not filled: \(fill)") }
        for (name, f) in after {
            if f.x < Double(content.minX) - 0.05 || f.y < Double(content.minY) - 0.05
                || f.x + f.width > Double(content.maxX) + 0.05 || f.y + f.height > Double(content.maxY) + 0.05 {
                failures.append("tidy: \(name) is outside the zone's content: \(f) vs \(content)")
            }
        }
        if let web = after["Web"], abs(web.width - web.height * 16 / 9) > 1.0 / 32 {
            failures.append("tidy: the browser is not 16:9: \(web)")
        }
        // The lead and its helpers are one block: helpers stacked one gap right
        // of the lead, their heights (with the gap) summing to the lead's.
        let gap = TileGapResolver.resolvedGap(defaults: canvas.autoLayoutDefaults)
        if let lead = after["Lead"], let h1 = after["H1"], let h2 = after["H2"] {
            let column = [h1, h2].sorted { $0.y < $1.y }
            if abs(h1.x - h2.x) > 0.01 || abs(h1.x - (lead.x + lead.width + gap)) > 0.01 {
                failures.append("tidy: the helpers are not one column beside the lead: \(lead) \(column)")
            }
            if abs(column[0].y - lead.y) > 0.01 || abs(column[0].height + gap + column[1].height - lead.height) > 0.01 {
                failures.append("tidy: the helpers do not span the lead's height: \(lead) \(column)")
            }
            let right = column.map { $0.x + $0.width }.max()!
            if after.contains(where: { !["Lead", "H1", "H2"].contains($0.key) && $0.value.x < right && $0.value.x + $0.value.width > lead.x
                && $0.value.y < lead.y + lead.height && $0.value.y + $0.value.height > lead.y }) {
                failures.append("tidy: another tile sits inside the lead's block")
            }
        }
        // Persisted through the production store, in world frames.
        if let saved = try ProjectStore(projectRoot: root).tryLoadCanvas() {
            for (name, id) in ids {
                guard let tile = saved.tiles.first(where: { $0.id == id }) else { failures.append("tidy: \(name) not persisted"); continue }
                if let f = after[name], abs(tile.frame.x - f.x) > 0.01 || abs(tile.frame.width - f.width) > 0.01
                    || abs(tile.frame.y - f.y) > 0.01 || abs(tile.frame.height - f.height) > 0.01 {
                    failures.append("tidy: \(name) persisted \(tile.frame), shows \(f)")
                }
            }
        } else {
            failures.append("tidy: no persisted canvas")
        }
        canvas.tidyAutoLayout(zoneId: Fixture.zoneA1)
        canvas.layoutSubtreeIfNeeded()
        if frames() != after || canvas.qaLiveZonePlacement(Fixture.zoneA1) != zone {
            failures.append("tidy: a second Tidy moved tiles or the zone")
        }
        return failures
    }

    private static func leadCluster() throws -> [String] {
        let tiles: [(String, TileFrame)] = [
            ("Lead", TileFrame(x: 24, y: 58, width: 640, height: 520)),
            ("H1", TileFrame(x: 672, y: 58, width: 640, height: 256)),
            ("H2", TileFrame(x: 672, y: 322, width: 640, height: 256)),
            ("NoteA", TileFrame(x: 1320, y: 58, width: 640, height: 400)),
            ("NoteB", TileFrame(x: 24, y: 586, width: 640, height: 400)),
            ("NoteC", TileFrame(x: 1320, y: 466, width: 640, height: 300)),
        ]
        let fixture = try Fixture(label: "fanout-cluster")
        defer { fixture.dispose() }
        let ids = try reseed(fixture, zoneSize: ZoneSize(width: 2_600, height: 1_900), tiles: tiles,
                             agents: ["Lead", "H1", "H2"])
        let root = fixture.projectRoots[Fixture.projectA1]!
        let appSupport = fixture.appSupport
        var agents: [String: AgentID] = [:]
        fixture.configureMount = { delegate, _ in
            delegate.agentSupervisor = AgentSupervisor(
                store: AgentStore(applicationSupportDirectory: appSupport),
                makeRunner: { _ in ScriptedAgentRunner(script: [], holdUntilStopped: true) })
            let lead = delegate.agentSupervisor.spawn(
                role: nil, prompt: nil, cwd: root, harness: .claudeCode, model: "fixture/cluster", thinking: "medium",
                projectId: Fixture.projectA1, projectRoot: root, tileId: ids["Lead"], displayName: "Lead")
            agents["Lead"] = lead
            for name in ["H1", "H2"] {
                agents[name] = delegate.agentSupervisor.spawn(
                    role: nil, prompt: nil, cwd: root, harness: .claudeCode, model: "fixture/cluster", thinking: "medium",
                    projectId: Fixture.projectA1, projectRoot: root, parentAgentID: lead, tileId: ids[name], displayName: name)
            }
        }
        try fixture.mount()
        let m = try fixture.requireMounted("fanout cluster")
        defer { m.delegate.qaAgentSupervisor.stopAll() }
        let canvas = m.canvas
        TileInsertSlideChecks.pin(canvas, autoLayout: true)
        canvas.frame = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        let zoom = 0.5
        canvas.setViewport(CanvasViewport(x: -60, y: -60, zoom: zoom))
        let window = KeyWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = canvas
        window.orderFrontOffscreenForChecks()
        window.makeKey()
        defer { window.orderOut(nil) }
        for name in ["Lead", "H1", "H2"] { m.delegate.wireManagedAgentTile(ids[name]!, agentID: agents[name]) }
        m.delegate.qaInstallTileFocusMonitor()
        defer { m.delegate.qaRemoveTileFocusMonitor() }
        canvas.layoutSubtreeIfNeeded()
        guard canvas.autoLayoutCluster(for: ids["H1"]!)?.all == Set(["Lead", "H1", "H2"].map { ids[$0]! }) else {
            throw Failure(description: "precondition: the canvas does not see Lead, H1 and H2 as one cluster")
        }
        func frames() -> [String: TileFrame] {
            var out: [String: TileFrame] = [:]
            for tile in canvas.allTilesInWorldFrames() {
                if let name = ids.first(where: { $0.value == tile.id })?.key { out[name] = tile.frame }
            }
            return out
        }
        guard let host = canvas.superview ?? Optional(canvas) else { throw Failure(description: "no host") }
        func grab(_ name: String) throws -> NSPoint {
            guard let view = canvas.tileView(for: ids[name]!) else { throw Failure(description: "\(name) has no view") }
            for step in [0.5, 0.3, 0.7, 0.2, 0.8, 0.4, 0.6] {
                let local = NSPoint(x: view.bounds.width * step, y: view.chromeBarHeight / 2)
                guard view.qaDragKindIsMove(at: local) else { continue }
                let candidate = view.convert(local, to: nil)
                let hit = canvas.hitTest(canvas.convert(canvas.convert(candidate, from: nil), to: host))
                if hit === view || hit?.superview === view && !(hit is NSControl) { return candidate }
            }
            throw Failure(description: "\(name) has no empty title-bar point")
        }
        var t = ProcessInfo.processInfo.systemUptime
        func send(_ type: NSEvent.EventType, _ point: NSPoint) throws {
            t += 0.016
            guard let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: t,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                pressure: type == .leftMouseUp ? 0 : 1)
            else { throw Failure(description: "could not synthesize \(type)") }
            NSApp.sendEvent(event)
            canvas.layoutSubtreeIfNeeded()
        }
        func path(_ dx: Double, _ dy: Double, count: Int = 60) -> [CGVector] {
            (1...count).map { i in
                let s = Double(i) / Double(count)
                let eased = s < 0.5 ? 2 * s * s : 1 - pow(-2 * s + 2, 2) / 2
                return CGVector(dx: dx * eased + 2 * sin(Double(i) * 1.7), dy: dy * eased + 3 * sin(Double(i) * 1.3))
            }
        }
        var failures: [String] = []
        let notes = ["NoteA", "NoteB", "NoteC"]

        // (1) H1 across its cluster and on into NoteC's edge.
        let rest = frames()
        let start = try grab("H1")
        try send(.leftMouseDown, start)
        var pressedNote = false
        var clusterMoved = false
        var last = start
        for (index, step) in path(420, 300).enumerated() {
            last = NSPoint(x: start.x + step.dx * zoom, y: start.y - step.dy * zoom)
            try send(.leftMouseDragged, last)
            let now = frames()
            for note in notes where now[note] != rest[note] {
                failures.append("helper drag frame \(index): \(note) moved to \(now[note]!) — only the cluster may react")
            }
            if let h1 = now["H1"], notes.contains(where: { note in
                let n = rest[note]!
                return h1.x < n.x + n.width + 8 && h1.x + h1.width + 8 > n.x && h1.y < n.y + n.height + 8 && h1.y + h1.height + 8 > n.y
            }) { pressedNote = true }
            if now["Lead"] != rest["Lead"] {
                failures.append("helper drag frame \(index): the lead moved to \(now["Lead"]!) — it anchors its cluster")
            }
            if now["H2"] != rest["H2"] { clusterMoved = true }
        }
        try send(.leftMouseUp, last)
        let afterHelper = frames()
        for note in notes where afterHelper[note] != rest[note] {
            failures.append("helper drop moved \(note) to \(afterHelper[note]!)")
        }
        if !pressedNote { failures.append("control: H1 never pressed on a note, so nothing tempted a push") }
        if !clusterMoved { failures.append("control: no cluster tile reacted to H1, so the cluster was never exercised") }

        // (2) The lead, dragged down and right, carries its helpers.
        let before = frames()
        let leadStart = try grab("Lead")
        try send(.leftMouseDown, leadStart)
        func offsets(_ f: [String: TileFrame]) -> [String: CGVector] {
            Dictionary(uniqueKeysWithValues: ["H1", "H2"].map { name in
                (name, CGVector(dx: f[name]!.x - f["Lead"]!.x, dy: f[name]!.y - f["Lead"]!.y))
            })
        }
        let expected = offsets(before)
        var leadLast = leadStart
        var leadMoved = false
        for (index, step) in path(260, 900).enumerated() {
            leadLast = NSPoint(x: leadStart.x + step.dx * zoom, y: leadStart.y - step.dy * zoom)
            try send(.leftMouseDragged, leadLast)
            let now = frames()
            if now["Lead"] != before["Lead"] { leadMoved = true }
            for (name, offset) in offsets(now) where abs(offset.dx - expected[name]!.dx) > 0.5 || abs(offset.dy - expected[name]!.dy) > 0.5 {
                failures.append("lead drag frame \(index): \(name) left the lead (offset \(offset), was \(expected[name]!))")
            }
        }
        try send(.leftMouseUp, leadLast)
        let afterLead = frames()
        if !leadMoved || afterLead["Lead"] == before["Lead"] { failures.append("control: the lead drag never moved the lead") }
        for (name, offset) in offsets(afterLead) where abs(offset.dx - expected[name]!.dx) > 0.5 || abs(offset.dy - expected[name]!.dy) > 0.5 {
            failures.append("after the lead's drop \(name) sits at offset \(offset), was \(expected[name]!)")
        }
        print("auto-layout fan-out: cluster — helper drag moved no note, lead drag carried both helpers: "
              + "\(failures.isEmpty ? "ok" : "\(failures.count) violation(s)")")
        return failures.map { "cluster: " + $0 }
    }
}
