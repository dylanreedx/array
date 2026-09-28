import AppKit
import ContinuumRevivedCore
import Foundation

/// `--agent-tile-binding-check`: a managed-agent tile's binding is explicit —
/// bound, unbound or unavailable — and nothing but a person's own act mints an
/// agent for it (`.plans/67-target-architecture` §3.2, CLAUDE.md hazard 10).
///
/// Agent TILES live in the project's shared canvas; agent RECORDS live in this
/// channel's store. A tile whose record this store does not hold is therefore
/// ordinary, not corruption: another install made it. Mounted through the
/// invariants fixture's real `mountWorkspaceSceneAtBoot` (which runs
/// `agentSupervisor.restore()` before hydration), across a switch away and
/// back and a quit+remount, the leg asserts:
///
///  (a) the store gains no record for either tile, counted on disk and through
///      the supervisor;
///  (b) the real tile view says which state it is in, as transcript text;
///  (c) only a sent prompt — the person's act — starts a new agent for the
///      unbound tile, exactly one, and it survives remount bound; the
///      unavailable tile refuses, because its agent exists and is only
///      unreachable.
///
/// The agent store is the process's `CONTINUUM_APP_SUPPORT`; the leg refuses to
/// run without one, so it can never touch a real store. Every harness is marked
/// not installed first, so the one send the leg makes can never start a CLI.
@MainActor
enum AgentTileBindingChecks {
    typealias Fixture = WorkspaceInvariantsFixture

    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String) throws {
        if !condition() { throw Failure(message: message()) }
    }

    static let unboundTile = UUID(uuidString: "00000000-0000-0000-0000-0000067A1C01")!
    static let unavailableTile = UUID(uuidString: "00000000-0000-0000-0000-0000067A1D01")!
    static let unavailableAgent = AgentID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-0000067A1D0A")!)

    static func run() throws -> URL {
        guard let supportPath = ProcessInfo.processInfo.environment["CONTINUUM_APP_SUPPORT"] else {
            throw Failure(message: "refusing to run without CONTINUUM_APP_SUPPORT: the agent store would be a real one")
        }
        let agentStore = AgentStore(applicationSupportDirectory: URL(fileURLWithPath: supportPath, isDirectory: true))
        let preexisting = try agentStore.loadAll()
        try expect(preexisting.isEmpty, "the channel's agent store must start empty; it holds \(preexisting.count) record(s)")
        for harness in [AgentHarness.claudeCode, .codex, .pi] {
            AgentModelCatalog.shared.resetForQA(snapshot: .init(
                harness: harness, readiness: .missing, models: [], displayNames: [:], contextWindows: [:]))
        }

        let fixture = try Fixture(label: "agent-binding")
        defer { fixture.dispose() }
        try seed(fixture, agentStore: agentStore)
        var steps: [[String: Any]] = []
        // Outcome mismatches are collected, so one run reports every step.
        var failures: [String] = []
        func soft(_ condition: Bool, _ message: @autoclosure () -> String) {
            if !condition { failures.append(message()) }
        }

        func tile(_ tileId: UUID, _ step: String) throws -> ManagedAgentTileNSView {
            let m = try fixture.requireMounted(step)
            guard let view = m.canvas.tileView(for: tileId) as? ManagedAgentTileNSView else {
                throw Failure(message: "\(step): tile \(tileId) has no managed-agent view")
            }
            return view
        }
        /// Records naming `tileId`: on disk, and in the mounted supervisor.
        func records(_ tileId: UUID) throws -> (disk: [AgentID], live: [AgentID]) {
            let m = try fixture.requireMounted("records")
            return (try agentStore.loadAll().filter { $0.tileId == tileId }.map(\.id),
                    m.delegate.qaAgentSupervisor.records.values.filter { $0.tileId == tileId }.map(\.id))
        }
        func checkUnminted(_ step: String) throws {
            let unbound = try records(unboundTile)
            let unavailable = try records(unavailableTile)
            let unboundText = try tile(unboundTile, step).qaTranscriptText
            let unavailableText = try tile(unavailableTile, step).qaTranscriptText
            steps.append(["step": step, "unboundDisk": unbound.disk.count, "unboundLive": unbound.live.count,
                          "unavailableDisk": unavailable.disk.count, "unavailableLive": unavailable.live.count,
                          "unboundText": unboundText, "unavailableText": unavailableText])
            soft(unbound.disk.isEmpty && unbound.live.isEmpty,
                       "\(step): an agent was minted for the tile with no record: disk \(unbound.disk), supervisor \(unbound.live)")
            soft(unavailable.disk == [unavailableAgent] && unavailable.live.isEmpty,
                       "\(step): the unavailable tile's records changed: disk \(unavailable.disk), supervisor \(unavailable.live)")
            soft(unboundText.contains(ManagedAgentTileNSView.unboundAgentNoticeText),
                       "\(step): the tile with no record does not say it is unbound; transcript: \(unboundText)")
            soft(unavailableText.contains(ManagedAgentTileNSView.unavailableAgentNoticeText),
                       "\(step): the tile whose agent's Home is gone does not say it is unavailable; transcript: \(unavailableText)")
        }

        try fixture.mount()
        try checkUnminted("mount A")
        try fixture.switchTo(Fixture.workspaceB)
        try fixture.switchTo(Fixture.workspaceA)
        try checkUnminted("switch away and back")
        fixture.drain()
        try fixture.remount(crash: false)
        try checkUnminted("quit and remount")

        // (c) The unavailable tile's agent exists; a prompt must not replace it.
        try tile(unavailableTile, "act").qaSubmitPrompt("hello from the unavailable tile")
        fixture.drain(0.2)
        try checkUnminted("prompt in the unavailable tile")

        // The person's act: send a prompt in the unbound tile. That, and only
        // that, starts one new agent here.
        try tile(unboundTile, "act").qaSubmitPrompt("start one here")
        fixture.drain(0.2)
        let started = try records(unboundTile)
        soft(started.disk.count == 1 && started.live == started.disk,
                   "act: a prompt in the unbound tile must start exactly one agent; disk \(started.disk), supervisor \(started.live)")
        fixture.drain()
        try fixture.remount(crash: false)
        let remounted = try records(unboundTile)
        soft(remounted.disk == started.disk && remounted.live == started.disk,
                   "act then remount: the started agent must come back bound and alone; disk \(remounted.disk), supervisor \(remounted.live)")
        let boundText = try tile(unboundTile, "bound after remount").qaTranscriptText
        soft(!boundText.contains(ManagedAgentTileNSView.unboundAgentNoticeText),
                   "bound after remount: the tile still says it is unbound; transcript: \(boundText)")
        steps.append(["step": "act then remount", "agent": started.disk.first?.rawValue.uuidString ?? ""])

        let timestamp = Int(Date().timeIntervalSince1970)
        let dir = URL(fileURLWithPath: "qa-runs/\(timestamp)/agent-tile-binding", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let artifact = dir.appendingPathComponent("manifest.json", isDirectory: false)
        let data = try JSONSerialization.data(withJSONObject: ["steps": steps, "actions": fixture.actionLog, "failures": failures],
                                              options: [.prettyPrinted, .sortedKeys])
        try data.write(to: artifact, options: .atomic)
        try expect(failures.isEmpty, "\(failures.count) failure(s):\n  " + failures.joined(separator: "\n  "))
        return artifact
    }

    /// Two managed-agent tiles in zone A1: one no store has a record for, one
    /// whose record is in this store but whose Home directory is gone.
    private static func seed(_ fixture: Fixture, agentStore: AgentStore) throws {
        let store = ProjectStore(projectRoot: fixture.projectRoots[Fixture.projectA1]!)
        var canvas = try store.loadCanvas()
        for (index, (tileId, frame)) in [
            (unboundTile, TileFrame(x: 1200, y: 260, width: 260, height: 200)),
            (unavailableTile, TileFrame(x: 1200, y: 640, width: 260, height: 200))
        ].enumerated() {
            var tile = Tile(
                id: tileId, kind: .managedAgent, title: "agent \(index)", frame: frame,
                zPosition: .fromLegacyRank(10 + index), runtimeRef: nil,
                metadata: TileMetadata(launchProfileId: "managed-agent", projectRelativeCwd: ".",
                                       filesystemProjectId: Fixture.projectA1))
            tile.zoneId = Fixture.zoneA1
            canvas.tiles.append(tile)
        }
        try store.saveCanvas(canvas)
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        try agentStore.upsert(AgentRecord(
            id: unavailableAgent, displayName: "Moved away", harness: .pi, model: "google/gemini", thinking: "off",
            cwd: fixture.root.appendingPathComponent("gone", isDirectory: true).path,
            projectId: Fixture.projectA1, createdAt: now, lastActivityAt: now, tileId: unavailableTile))
    }
}
