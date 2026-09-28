import AppKit
import ContinuumRevivedCore
import Foundation

/// Directed witnesses for the data-protection patches (`.plans/67`, slice 1),
/// each on `WorkspaceInvariantsFixture`: two real workspaces mounted through
/// `mountWorkspaceSceneAtBoot`, driven through the entry points a user reaches,
/// asserted on the bytes on disk. Each flag runs every scenario and reports all
/// that failed, so a RED run names every broken route at once.
@MainActor
enum WorkspaceDataProtectionChecks {
    typealias Fixture = WorkspaceInvariantsFixture

    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String) throws {
        if !condition() { throw Failure(message: message()) }
    }

    /// Run each scenario on its own fixture; fail with every failure message.
    private static func runScenarios(
        _ name: String, _ scenarios: [(String, (Fixture) throws -> [String: Any])]
    ) throws -> URL {
        var manifest: [String: Any] = [:]
        var failures: [String] = []
        for (label, body) in scenarios {
            let fixture = try Fixture(label: label)
            do {
                var result = try body(fixture)
                result["actions"] = fixture.actionLog
                manifest[label] = result
            } catch {
                failures.append("\(label): \(error)")
                manifest[label] = ["failure": "\(error)", "actions": fixture.actionLog]
            }
            fixture.dispose()
        }
        let timestamp = Int(Date().timeIntervalSince1970)
        let dir = URL(fileURLWithPath: "qa-runs/\(timestamp)/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let artifact = dir.appendingPathComponent("manifest.json", isDirectory: false)
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: artifact, options: .atomic)
        if !failures.isEmpty {
            throw Failure(message: "\(failures.count) of \(scenarios.count) scenario(s) failed (\(artifact.path)):\n  "
                          + failures.joined(separator: "\n  "))
        }
        return artifact
    }

    // MARK: - --workspace-saver-identity-check

    /// One saver per mounted workspace, superseded by every later save; no
    /// writer reads the mounted document back from disk.
    static func runSaverIdentity() throws -> URL {
        try runScenarios("workspace-saver-identity", [
            ("cross-workspace", crossWorkspaceArming),
            ("arm-then-rename", armThenRename),
            ("arm-then-layout-commit", armThenLayoutCommit)
        ])
    }

    /// Mount A, arm A, switch to B, arm B, drain: A's file is not touched by
    /// anything B does, and B's arming lands in B's file.
    private static func crossWorkspaceArming(_ fixture: Fixture) throws -> [String: Any] {
        try fixture.mount()
        try fixture.armByClick(Fixture.zoneA2)
        try fixture.switchTo(Fixture.workspaceB)
        let aBytes = try fixture.readWorkspaceFile(Fixture.workspaceA).bytes
        try expect(aBytes != nil, "A has no file after switching away")
        try fixture.armByClick(Fixture.zoneB2)
        fixture.drain()
        let aAfter = try fixture.readWorkspaceFile(Fixture.workspaceA)
        let bAfter = try fixture.readWorkspaceFile(Fixture.workspaceB)
        try expect(aAfter.bytes == aBytes,
                   "A's file changed while B was mounted; it now holds zones "
                   + "\(aAfter.document?.zones.map(\.zoneId) ?? []) armed at \(String(describing: aAfter.document?.lastActiveZoneId))")
        try expect(bAfter.document?.lastActiveZoneId == Fixture.zoneB2,
                   "arming zone B2 in B never reached B's file; B's file is armed at "
                   + "\(String(describing: bAfter.document?.lastActiveZoneId))")
        return ["aUnchanged": true]
    }

    /// Arm (debounced), then rename (synchronous) inside the debounce window,
    /// drain, then die: the durable document is the latest one, both changes.
    private static func armThenRename(_ fixture: Fixture) throws -> [String: Any] {
        let name = "Renamed inside the debounce window"
        try fixture.mount()
        try fixture.armByClick(Fixture.zoneA2)
        try fixture.rename(Fixture.zoneA1, to: name)
        fixture.drain()
        try fixture.remount(crash: true)
        let document = try fixture.modelView().document
        let zone = document.zones.first { $0.zoneId == Fixture.zoneA1 }
        try expect(zone?.name == name,
                   "the rename did not survive: zone A1 is named \(String(describing: zone?.name)) after remount")
        try expect(document.lastActiveZoneId == Fixture.zoneA2,
                   "the arming did not survive: armed at \(String(describing: document.lastActiveZoneId)) after remount")
        return ["name": name]
    }

    /// Arm (debounced), then move a tile through the canvas's programmatic
    /// geometry route — the drag's own owner, which commits through the
    /// `onLayoutCommitted` callback production wires in the mount — inside the
    /// debounce window. Neither the commit nor the arming may undo the other,
    /// in memory or on disk.
    private static func armThenLayoutCommit(_ fixture: Fixture) throws -> [String: Any] {
        try fixture.mount()
        let m = try fixture.requireMounted("layout commit")
        try fixture.armByClick(Fixture.zoneA2)
        var requested = Fixture.seed.tiles[Fixture.noteA1a]!
        requested.x += 30
        let outcome = m.canvas.applyProgrammaticTileGeometry(
            tileId: Fixture.noteA1a, in: Fixture.zoneA1, worldFrame: requested, action: .moveTile)
        guard case .committed = outcome else { throw Failure(message: "the tile move was not committed: \(outcome)") }
        let committed = try fixture.modelView().tileWorldFrames[Fixture.noteA1a]
        try expect(committed != Fixture.seed.tiles[Fixture.noteA1a], "the committed move left the tile where it was")
        try expect(m.runtime.qaArmedZoneId == Fixture.zoneA2,
                   "the layout commit reverted the in-memory arming to "
                   + "\(String(describing: m.runtime.qaArmedZoneId))")
        fixture.drain()
        let onDisk = try fixture.readWorkspaceFile(Fixture.workspaceA).document
        try expect(onDisk?.lastActiveZoneId == Fixture.zoneA2,
                   "disk lost the arming: armed at \(String(describing: onDisk?.lastActiveZoneId))")
        let tile = fixture.readProjectFile(Fixture.projectA1).canvas?.tiles.first { $0.id == Fixture.noteA1a }
        try expect(tile?.frame == committed,
                   "disk lost the committed tile frame: \(String(describing: tile?.frame)), committed \(String(describing: committed))")
        return ["armed": Fixture.zoneA2.uuidString, "committed": "\(String(describing: committed))"]
    }
}

private extension Optional {
    func orThrow(_ error: Error) throws -> Wrapped {
        guard let value = self else { throw error }
        return value
    }
}
