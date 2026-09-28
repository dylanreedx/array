import AppKit
import ContinuumRevivedCore
import Foundation

/// `--zone-presentation-check`: a zone's header is a pure function of its
/// placement, its project's registry entry, its rollup and whether it is still
/// provisional (`.plans/67-target-architecture`, ARC-3).
///
/// Driven through the invariants fixture's real mount and the entry points a
/// user reaches: the inline rename mutation, the Home picker's confirm (the
/// header's Home action presents it; the leg presses the row), Create Zone's
/// provisional flow, the agent-status refresh, the sidebar switch, the quit
/// sequence. After every step each header's DRAWN text must equal both the
/// fixture's canonical oracle and the literal this leg expects.
///
/// It also pins the states that used to share one label: provisional, unbound
/// (no project), bound to a project the registry does not know, and bound to a
/// registered project whose folder is missing each draw their own Home label.
@MainActor
enum ZonePresentationChecks {
    typealias Fixture = WorkspaceInvariantsFixture

    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String) throws {
        if !condition() { throw Failure(message: message()) }
    }

    static func run() throws -> URL {
        var manifest: [String: Any] = [:]
        // Header mismatches are collected, not thrown at the first, so one run
        // reports every step that drew the wrong thing.
        var failures: [String] = []
        manifest["lifecycle"] = try runLifecycle(&failures)
        manifest["states"] = try runDistinctStates(&failures)
        manifest["failures"] = failures

        let timestamp = Int(Date().timeIntervalSince1970)
        let dir = URL(fileURLWithPath: "qa-runs/\(timestamp)/zone-presentation", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let artifact = dir.appendingPathComponent("manifest.json", isDirectory: false)
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: artifact, options: .atomic)
        try expect(failures.isEmpty, "\(failures.count) header failure(s):\n  " + failures.joined(separator: "\n  "))
        return artifact
    }

    /// Record a header mismatch and carry on; seams and setup still throw.
    private static func soft(_ condition: Bool, _ message: @autoclosure () -> String, _ failures: inout [String]) {
        if !condition { failures.append(message()) }
    }

    /// The drawn title and Home label: the first two strings a header draws.
    private static func titleAndHome(_ drawn: [String]?) -> [String] { Array((drawn ?? []).prefix(2)) }

    // MARK: - Lifecycle

    private static func runLifecycle(_ failures: inout [String]) throws -> [String: Any] {
        let fixture = try Fixture(label: "presentation")
        defer { fixture.dispose() }
        // The picker validates a Home against the filesystem, so it must exist.
        try FileManager.default.createDirectory(
            at: fixture.projectRoots[Fixture.projectA1]!.appendingPathComponent("Sources", isDirectory: true),
            withIntermediateDirectories: true)
        var steps: [[String: Any]] = []

        /// Chrome equals the oracle over the mounted document AND the literals.
        func check(_ step: String, _ expected: [UUID: [String]]) throws {
            let chrome = try fixture.chromeView()
            let violations = try fixture.allViolations(invariants: [.projection])
            steps.append(["step": step,
                          "drawn": Dictionary(uniqueKeysWithValues: chrome.map { ($0.key.uuidString, $0.value) }),
                          "violations": violations.map(\.description)])
            soft(violations.isEmpty, "after \(step): \(violations.map(\.description))", &failures)
            for (zoneId, want) in expected {
                soft(titleAndHome(chrome[zoneId]) == want,
                     "after \(step): zone \(zoneId) drew \(chrome[zoneId] ?? []), expected \(want)", &failures)
            }
        }

        /// A status tick may change status-dependent display only.
        func tick(_ step: String) throws {
            let m = try fixture.requireMounted(step)
            let before = try fixture.chromeView().mapValues(titleAndHome)
            m.delegate.qaApplyAgentStatusesToCanvas()
            let after = try fixture.chromeView().mapValues(titleAndHome)
            for (zoneId, drawn) in before {
                soft(after[zoneId] == drawn,
                     "\(step): the rollup tick changed zone \(zoneId)'s header from \(drawn) to \(after[zoneId] ?? [])", &failures)
            }
        }

        try fixture.mount()
        try check("mount A", [
            Fixture.zoneA1: ["Roots", "Alder / Project Root"],
            Fixture.zoneA2: ["Birch", "Birch / Project Root"]
        ])

        // A zone that took its title from its project renames to its own.
        try fixture.rename(Fixture.zoneA2, to: "Sapling")
        try check("rename A2", [Fixture.zoneA2: ["Sapling", "Birch / Project Root"]])

        // Home change: the header's Home action presents the picker; press its row.
        var m = try fixture.requireMounted("home")
        m.canvas.requestZoneScopeChange(zoneId: Fixture.zoneA1)
        try expect(m.delegate.qaConfirmProjectHomePicker(projectId: Fixture.projectA1, homeRelativePath: "Sources"),
                   "home: the Home action presented no picker offering Alder")
        fixture.drain()
        try check("change A1's Home", [Fixture.zoneA1: ["Roots", "Alder / Sources"]])
        try tick("tick after the Home change")
        try check("tick after the Home change", [
            Fixture.zoneA1: ["Roots", "Alder / Sources"],
            Fixture.zoneA2: ["Sapling", "Birch / Project Root"]
        ])

        // Create Zone: provisional until a project is chosen, then bound.
        let created = m.canvas.beginProvisionalZone(screenRect: CGRect(x: 40, y: 1000, width: 420, height: 300))
        let createdName = m.canvas.qaLiveZonePlacement(created)?.name ?? "<no placement>"
        let provisional = titleAndHome(m.canvas.qaRenderedZoneHeaderText(for: created))
        soft(provisional == [createdName, "Choose a project to finish"],
             "create: the provisional zone drew \(provisional)", &failures)
        try expect(m.delegate.qaConfirmProjectHomePicker(projectId: Fixture.projectA1, homeRelativePath: nil),
                   "create: Create Zone presented no picker offering Alder")
        fixture.drain()
        try check("create a zone", [created: [createdName, "Alder / Project Root"]])
        try tick("tick after create")
        // The tick used to drop a new zone's display entry, so its rename then
        // persisted while the header kept the old name.
        try fixture.rename(created, to: "Seedling")
        try check("rename the new zone after a tick", [created: ["Seedling", "Alder / Project Root"]])
        try tick("tick after the new zone's rename")

        let settled: [UUID: [String]] = [
            Fixture.zoneA1: ["Roots", "Alder / Sources"],
            Fixture.zoneA2: ["Sapling", "Birch / Project Root"],
            created: ["Seedling", "Alder / Project Root"]
        ]
        try fixture.switchTo(Fixture.workspaceB)
        try check("switch to B", [Fixture.zoneB1: ["Canopy", "Cedar / Project Root"]])
        try fixture.switchTo(Fixture.workspaceA)
        try check("switch back to A", settled)
        try tick("tick after switching back")

        fixture.drain()
        try fixture.remount(crash: false)
        try check("quit and remount", settled)
        m = try fixture.requireMounted("remount")

        // The canonical inputs are durable, not just in memory.
        let onDisk = try fixture.readWorkspaceFile(Fixture.workspaceA).document
        let diskZones = Dictionary(uniqueKeysWithValues: (onDisk?.zones ?? []).map { ($0.zoneId, $0) })
        soft(diskZones[Fixture.zoneA1]?.homeRelativePath == "Sources"
                   && diskZones[Fixture.zoneA2]?.name == "Sapling"
                   && diskZones[created]?.name == "Seedling" && diskZones[created]?.projectId == Fixture.projectA1,
             "disk: workspace A holds \(onDisk?.zones.map { "\($0.name)|\($0.homeRelativePath ?? "-")" } ?? [])", &failures)
        return ["steps": steps, "actions": fixture.actionLog]
    }

    // MARK: - Distinct states

    private static func runDistinctStates(_ failures: inout [String]) throws -> [String: Any] {
        let fixture = try Fixture(label: "presentation-states")
        defer { fixture.dispose() }

        // An unbound zone, as a workspace file holds one, mounted for real.
        let unboundZone = UUID(uuidString: "00000000-0000-0000-0000-00000067A0FF")!
        let store = WorkspaceStore(workspaceId: Fixture.workspaceA, applicationSupportDirectory: fixture.appSupport)
        var document = try store.load()
        document.zones.append(ZonePlacement(
            zoneId: unboundZone, projectId: nil,
            origin: ZonePoint(x: 3000, y: 200), size: ZoneSize(width: 600, height: 400),
            color: "orange", collapsed: false, hydrationPolicy: .automatic, name: "Loose"))
        try store.save(document)
        try fixture.mount()
        let mountedUnbound = titleAndHome(try fixture.chromeView()[unboundZone])
        soft(mountedUnbound == ["Loose", "Needs Project"],
             "unbound: the mounted zone with no project drew \(mountedUnbound)", &failures)
        let unboundViolations = try fixture.allViolations(invariants: [.projection])
        soft(unboundViolations.isEmpty, "unbound: \(unboundViolations.map(\.description))", &failures)
        let m = try fixture.requireMounted("provisional")
        let provisionalZone = m.canvas.beginProvisionalZone(screenRect: CGRect(x: 40, y: 1000, width: 420, height: 300))
        let provisional = titleAndHome(m.canvas.qaRenderedZoneHeaderText(for: provisionalZone))
        m.canvas.cancelProvisionalZone(zoneId: provisionalZone)
        try fixture.quit()

        // A project the registry does not know, and one whose folder is gone,
        // cannot mount today (`mountableZones` throws on the first; the factory
        // refuses the second). Launch still draws them: it builds the pre-mount
        // canvas from these same models before the mount runs.
        let orphanZone = UUID(uuidString: "00000000-0000-0000-0000-00000067A0EE")!
        document.zones.append(ZonePlacement(
            zoneId: orphanZone, projectId: UUID(uuidString: "00000000-0000-0000-0000-0000000067EE")!,
            origin: ZonePoint(x: 3000, y: 800), size: ZoneSize(width: 600, height: 400),
            color: "red", collapsed: false, hydrationPolicy: .automatic, name: "Orphan"))
        var registry = try fixture.registryStore.loadOrEmpty()
        if let index = registry.projects.firstIndex(where: { $0.id == Fixture.projectA2 }) {
            registry.projects[index].missing = true
        }
        let models = AppDelegate.zoneRenderModels(from: document, registry: registry)
        let launchCanvas = CanvasNSView(
            canvasState: CanvasState(viewport: document.viewport, tiles: [], groups: [], lastActiveTileId: nil),
            activeZone: nil, zoneRenderModels: models)
        launchCanvas.frame = CGRect(x: 0, y: 0, width: 2600, height: 1400)
        launchCanvas.layoutSubtreeIfNeeded()
        var launchDrawn: [UUID: [String]] = [:]
        for zone in document.zones {
            launchDrawn[zone.zoneId] = titleAndHome(launchCanvas.qaRenderedZoneHeaderText(for: zone.zoneId))
            let want = Fixture.expectedHeader(for: zone, registry: registry)
            soft(launchDrawn[zone.zoneId] == want,
                 "launch canvas: zone \(zone.name.isEmpty ? zone.zoneId.uuidString : zone.name) drew \(launchDrawn[zone.zoneId] ?? []), canonical \(want)", &failures)
        }
        soft(launchDrawn[orphanZone] == ["Orphan", "Project Not Found"],
             "registry miss: drew \(launchDrawn[orphanZone] ?? [])", &failures)
        soft(launchDrawn[Fixture.zoneA2] == ["Birch", "Birch / Project Root · Unavailable"],
             "unavailable: drew \(launchDrawn[Fixture.zoneA2] ?? [])", &failures)

        let labels = [
            "provisional": provisional.last ?? "",
            "unbound": mountedUnbound.last ?? "",
            "registryMiss": launchDrawn[orphanZone]?.last ?? "",
            "unavailable": launchDrawn[Fixture.zoneA2]?.last ?? "",
            "bound": launchDrawn[Fixture.zoneA1]?.last ?? ""
        ]
        soft(Set(labels.values).count == labels.count, "states: two states share a Home label: \(labels)", &failures)
        return ["labels": labels]
    }
}
