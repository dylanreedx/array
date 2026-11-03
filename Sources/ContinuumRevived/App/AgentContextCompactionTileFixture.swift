import AppKit
import ContinuumRevivedCore

/// Shared UI fixture for the live acceptance check and its offline replay.
@MainActor
enum AgentContextCompactionTileFixture {
    static func makeAttachedTile(supervisor: AgentSupervisor, id: AgentID, tileID: UUID, scratch: URL) -> (tile: ManagedAgentTileNSView, window: NSWindow) {
        let tile = ManagedAgentTileNSView(tile: Tile(
            id: tileID, kind: .managedAgent, title: "live-context-compaction",
            frame: TileFrame(x: 0, y: 0, width: 640, height: 480),
            zPosition: .fromLegacyRank(1), runtimeRef: nil,
            metadata: TileMetadata(launchProfileId: "managed")))
        tile.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        tile.bindV2ComposerState(
            draftStore: AgentComposerDraftStore(
                applicationSupportDirectory: scratch.appendingPathComponent("drafts", isDirectory: true),
                debounceInterval: 0),
            promptHistory: AgentPromptHistory())
        tile.attach(agentID: id, supervisor: supervisor)
        // The canvas renderer counts placed blocks. A windowless tile never
        // lays them out, even after the supervisor has completed the turn.
        let window = NSWindow(contentRect: tile.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = tile
        window.orderFrontOffscreenForChecks()
        return (tile, window)
    }

}
