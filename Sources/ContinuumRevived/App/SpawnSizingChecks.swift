import AppKit
import ContinuumRevivedCore

/// A new tile starts in the shape tidy gives it (`TileGeometry.shapeRule`), and
/// in an auto-layout zone with room it is sized to the room instead of growing
/// the zone (`.plans/auto-layout-night`, stream 3). `--spawn-sizing-check`.
///
/// Drives the production routes: ⌘K's palette action for a browser and an agent,
/// `TileSpawner.spawnTerminal(profileId:)` (what a launch-profile row calls) for a
/// terminal, each into a zone drawn and homed the way a user draws one. Asserts
/// the WORLD frame: its shape, and that it sits inside the zone's world rect.
@MainActor
enum SpawnSizingChecks {
    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }
    typealias Fixture = WorkspaceInvariantsFixture

    static func run() throws {
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
        let ghostty = try GhosttyRuntimeContext()
        try runRoomyZone(ghostty: ghostty)
        try runSnugZone()
        print("SpawnSizingChecks passed: browser 16:9, terminal and agent taller than wide, snug zone fitted")
    }

    // MARK: - A roomy zone: every kind at its default, in its rule, inside the zone

    private static func runRoomyZone(ghostty: GhosttyRuntimeContext) throws {
        let fixture = try Fixture(label: "spawn-sizing-roomy")
        defer { fixture.dispose() }
        fixture.ghostty = ghostty
        // 2800 wide: a 1024 browser centred under the camera leaves 864pt either
        // side of the 2752pt content, room for the 720 terminal and the 576 agent.
        let (m, zoneId, projectId) = try drawZone(fixture, worldSize: CGSize(width: 2800, height: 1200), label: "roomy")
        defer { m.delegate.qaAgentSupervisor.stopAll() }
        guard let spawner = m.runtime.controller(for: projectId)?.tileSpawner else {
            throw Failure(message: "roomy: the drawn zone's project has no spawner")
        }
        let spawns: [(TileKind, () -> Bool)] = [
            (.browser, { m.delegate.qaPerformPaletteAction(.newBrowser) }),
            (.terminal, {
                if case .spawned = spawner.spawnTerminal(profileId: "shell", allowTmuxPersistence: false) { return true }
                return false
            }),
            (.managedAgent, { m.delegate.qaPerformPaletteAction(.newManagedAgent) }),
        ]
        for (kind, spawn) in spawns {
            let zoneBefore = try zoneRect(m, zoneId, "roomy")
            let tile = try created(m, kind: kind, label: "roomy \(kind)", by: spawn)
            try expect(m.canvas.qaZoneMembership(of: tile.id) == zoneId, "roomy \(kind): the tile is not in the armed zone")
            try expectInRule(tile, label: "roomy \(kind)")
            let wanted = CanvasEngine.defaultFrame(for: kind)
            try expect(tile.frame.width == Double(wanted.width) && tile.frame.height == Double(wanted.height),
                       "roomy \(kind): a zone with room for the default must keep it, got \(describe(tile.frame))")
            let zone = try zoneRect(m, zoneId, "roomy")
            try expectInside(tile.frame, zone, label: "roomy \(kind)")
            try expect(zone == zoneBefore,
                       "roomy \(kind): a zone with room grew from \(describe(zoneBefore)) to \(describe(zone))")
        }
        let terminal = CanvasEngine.defaultFrame(for: .terminal)
        try expect(terminal.width >= 80 * 9, "the default terminal must keep 80 columns of the default cell, is \(terminal.width) wide")
    }

    // MARK: - A snug zone: the browser shrinks to the room, still 16:9

    /// Content rect 900 x 520: a 1024 x 576 browser does not fit, its 7/8 step
    /// (896 x 504) does. Before this the spawn kept 1024 x 640 and grew the zone.
    private static func runSnugZone() throws {
        let fixture = try Fixture(label: "spawn-sizing-snug")
        defer { fixture.dispose() }
        let padding = ZoneBoundsConfig.padding()
        let header = Double(ZoneChromeNSView.headerHeight)
        let size = CGSize(width: 900 + 2 * padding, height: 520 + header + 2 * padding)
        let (m, zoneId, _) = try drawZone(fixture, worldSize: size, label: "snug")
        let zoneBefore = try zoneRect(m, zoneId, "snug")
        let tile = try created(m, kind: .browser, label: "snug browser") {
            m.delegate.qaPerformPaletteAction(.newBrowser)
        }
        try expectInRule(tile, label: "snug browser")
        try expect(tile.frame.width == 896 && tile.frame.height == 504,
                   "snug browser: expected the 7/8 step 896x504 that fits the 900x520 room, got \(describe(tile.frame))")
        let zone = try zoneRect(m, zoneId, "snug")
        try expectInside(tile.frame, zone, label: "snug browser")
        try expect(zone == zoneBefore,
                   "snug browser: the zone grew from \(describe(zoneBefore)) to \(describe(zone)) though the tile fitted")
    }

    // MARK: - Fixture

    /// Draws a zone of `worldSize` in empty canvas, homes it on a fresh project the
    /// way the Home picker does, and leaves it armed.
    private static func drawZone(_ fixture: Fixture, worldSize: CGSize, label: String)
        throws -> (Fixture.Mounted, UUID, UUID) {
        let projectId = UUID()
        let projectRoot = fixture.root.appendingPathComponent("Sizing", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        try ProjectStore(projectRoot: projectRoot).saveProject(Project(
            id: projectId, name: "Sizing", rootPath: projectRoot.path, createdAt: now, updatedAt: now,
            defaultLaunchProfileId: "shell", editorPreference: .auto,
            settings: ProjectSettings(restorePolicy: .restoreDescriptors, browserStoragePolicy: .perProject,
                                      terminalClosePolicy: .askWhenRunning)))
        var registry = try fixture.registryStore.loadOrEmpty()
        registry.projects.append(ProjectEntry(
            id: projectId, name: "Sizing", rootPath: projectRoot.path, workspaceId: nil,
            lastOpenedAt: now, pinned: false, missing: false))
        try fixture.registryStore.save(registry)
        try fixture.mount()
        let m = try fixture.requireMounted("spawn sizing \(label)")
        m.delegate.creationScopePickerPresenterForQA = { _ in }
        m.canvas.navigationFlightOverrideForQA = false
        try expect(m.canvas.isAutoLayoutEnabled, "\(label): auto layout must be ON for this witness")
        // Far from every seeded zone, at half zoom so a wide zone fits the canvas.
        let drawCamera = CanvasViewport(x: 8000, y: 8000, zoom: 0.5)
        m.canvas.setViewport(drawCamera)
        m.canvas.layoutSubtreeIfNeeded()
        let topLeft = CanvasEngine.worldToScreen(CGPoint(x: 8100, y: 8100), viewport: drawCamera)
        let screenRect = CGRect(x: topLeft.x, y: topLeft.y,
                                width: worldSize.width * 0.5, height: worldSize.height * 0.5)
        let zoneId = m.canvas.beginProvisionalZone(screenRect: screenRect)
        try expect(m.delegate.qaConfirmProjectHomePicker(projectId: projectId, homeRelativePath: nil),
                   "\(label): drawing a zone presented no Home picker offering the project")
        m.canvas.layoutSubtreeIfNeeded()
        try expect(m.canvas.armedZoneId == zoneId, "\(label): the drawn zone must be armed")
        let rect = try zoneRect(m, zoneId, label)
        try expect(rect.width == Double(worldSize.width) && rect.height == Double(worldSize.height),
                   "\(label): drew \(worldSize) but the zone is \(describe(rect))")
        // The camera centred on the zone, as framing a zone leaves it.
        let size = m.canvas.bounds.size
        m.canvas.setViewport(CanvasViewport(
            x: rect.x + rect.width / 2 - Double(size.width) / 0.5 / 2,
            y: rect.y + rect.height / 2 - Double(size.height) / 0.5 / 2, zoom: 0.5))
        m.canvas.layoutSubtreeIfNeeded()
        return (m, zoneId, projectId)
    }

    private static func created(_ m: Fixture.Mounted, kind: TileKind, label: String,
                                by spawn: () -> Bool) throws -> Tile {
        let before = Set(m.canvas.allTilesInWorldFrames().map(\.id))
        try expect(spawn(), "\(label): the production route refused the spawn")
        m.canvas.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        let new = m.canvas.allTilesInWorldFrames().filter { !before.contains($0.id) }
        guard new.count == 1, let tile = new.first, tile.kind == kind else {
            throw Failure(message: "\(label): expected one new \(kind) tile, got \(new.map(\.kind))")
        }
        return tile
    }

    private static func zoneRect(_ m: Fixture.Mounted, _ zoneId: UUID, _ label: String) throws -> TileFrame {
        guard let zone = m.canvas.qaLiveZonePlacement(zoneId) else { throw Failure(message: "\(label): the zone vanished") }
        return CanvasEngine.zoneWorldFrame(zone)
    }

    private static func expectInRule(_ tile: Tile, label: String) throws {
        let ratio = tile.frame.width / tile.frame.height
        switch TileGeometry.shapeRule(for: tile.kind) {
        case let .aspect(wanted):
            try expect(abs(ratio - wanted) < 1e-9, "\(label): \(describe(tile.frame)) is not \(wanted):1")
        case let .band(min, max):
            try expect(ratio >= min && ratio <= max, "\(label): \(describe(tile.frame)) ratio \(ratio) is outside \(min)...\(max)")
        case .keep:
            break
        }
    }

    private static func expectInside(_ frame: TileFrame, _ zone: TileFrame, label: String) throws {
        try expect(frame.x >= zone.x - 0.001 && frame.y >= zone.y - 0.001
                   && frame.x + frame.width <= zone.x + zone.width + 0.001
                   && frame.y + frame.height <= zone.y + zone.height + 0.001,
                   "\(label): world frame \(describe(frame)) is not inside the zone \(describe(zone))")
    }

    private static func describe(_ f: TileFrame) -> String { "(\(f.x), \(f.y)) \(f.width)x\(f.height)" }

    private static func expect(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        if !condition { throw Failure(message: message()) }
    }
}
