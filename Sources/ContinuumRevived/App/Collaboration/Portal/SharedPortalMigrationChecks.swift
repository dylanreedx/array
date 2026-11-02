import AppKit
import ContinuumRevivedCore
import ContinuumRevivedCollaborationProtocol

/// `--shared-portal-migration-check`: 0.7.37 and 0.7.38 shared an area of
/// tiles by turning it into a shared zone on both canvases. Mode B
/// (`.plans/105-collaboration/SHARE-REDESIGN.md`) shares it as one portal tile.
/// This witness makes that state through the old code paths
/// (`createSharedZone` on the sharer, `openSharedArea` into a zone on the
/// receiver), writes both workspace documents, then reopens them the way a
/// launch does (`reopenSharedAreas`), and asserts what each person now has:
/// the sharer's tiles home and hosted as a portal, with no zone; the
/// receiver's zone replaced by one `.sharedPortal` tile in a project zone,
/// saved as a reference.
@MainActor
enum SharedPortalMigrationChecks {
    private struct Failure: Error, CustomStringConvertible { let description: String }
    private static func expect(_ value: Bool, _ label: String) throws {
        guard value else { throw Failure(description: "shared portal migration: " + label) }
        print("PASS shared portal migration: \(label)")
    }

    static func run() async throws {
        let root = try SharedAreaCheckRig.root("shared-portal-migration")
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = Collaboration.Identity(person: .init(), device: UUID())
        let receiver = Collaboration.Identity(person: .init(), device: UUID())
        let authority = SharedAreaCheckRig.Authority(document: .init(), members: [(owner, .owner), (receiver, .editor)])
        let links = ShareLinkAppChecks.Links()
        let endpoint = try CollaborationServiceEndpoint(URL(string: "https://portal-migration.example.test")!)

        // The sharer, as 0.7.38 left them: an agent and a note shared as a zone.
        let noteTile = UUID(), noteId = UUID()
        let fixture = try WorkspaceAPIChecks.makeFixture(beforeMount: { delegate, directory in
            let source = ProjectStore(projectRoot: directory.appendingPathComponent("Pb"))
            var canvas = try source.loadCanvas()
            let record = delegate.qaAgentSupervisor.records.values.first(where: {
                $0.projectRoot == directory.appendingPathComponent("Pb").path && $0.tileId != nil })
            guard let index = canvas.tiles.firstIndex(where: { $0.id == record?.tileId }) else {
                throw Failure(description: "shared portal migration: the fixture has no agent tile")
            }
            canvas.tiles[index].kind = .managedAgent; canvas.tiles[index].title = "Map the checkout state machine"
            let agent = canvas.tiles[index]
            try source.saveNoteBody(id: noteId, text: "Checkout states: cart, address, payment.")
            canvas.tiles.append(Tile(id: noteTile, kind: .note, title: "Checkout notes",
                frame: TileFrame(x: agent.frame.x + agent.frame.width + 40, y: agent.frame.y, width: 320, height: 240),
                zPosition: .fromLegacyRank(99), zoneId: agent.zoneId, runtimeRef: nil, metadata: TileMetadata(noteId: noteId)))
            try source.saveCanvas(canvas)
        })
        defer { fixture.runtime.closeAll(); fixture.tearDown() }
        let sender = fixture.delegate
        let ownerAccount = try ShareLinkAppChecks.account(root: root.appendingPathComponent("owner"), identity: owner,
                                                          authority: authority, links: links)
        _ = try await ownerAccount.enroll(endpoint: endpoint, code: "scripted-owner-enrollment", deviceLabel: "Dylan's Mac", accountLabel: "Dylan")
        sender.qaAdoptCollaborationAccount(ownerAccount)
        let agent = fixture.agentTileB
        let homeZone = fixture.canvas.tileRecord(for: agent)?.zoneId
        var worldBefore: [UUID: TileFrame] = [:]
        for tile in fixture.canvas.allTilesInWorldFrames() { worldBefore[tile.id] = tile.frame }
        let zonesBefore = fixture.runtime.document.zones.count
        let share = try await sender.createSharedZone(fromTiles: [agent, noteTile], name: "Checkout")
        let area = share.areaId
        try expect(fixture.runtime.sharedAreaZone(for: area) != nil && fixture.canvas.lentTile(agent) != nil
            && fixture.runtime.document.zones.count == zonesBefore + 1,
            "precondition: the old path shares the agent and the note as a zone and lends their tiles to it")
        let published = await authority.document
        try expect(published.items.count == 2 && published.items.contains { $0.kind == .agentObservation }
            && published.items.contains { $0.kind == .discussion },
            "precondition: the area holds the agent and the note")
        try fixture.runtime.flushMountedWorkspaceState()

        // The receiver, as 0.7.38 left them: the area as a zone on their canvas.
        let workspace = try WorkspaceInvariantsFixture(label: "shared-portal-migration-receiver")
        try workspace.mount()
        defer { workspace.dispose() }
        let mounted = try workspace.requireMounted("migration receiver")
        let guest = mounted.delegate
        mounted.canvas.frame = .init(x: 0, y: 0, width: 1400, height: 900)
        let window = NSWindow(contentRect: mounted.canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = mounted.canvas
        guest.qaAttachWindowForOfflineCheck(window)
        window.orderFrontOffscreenForChecks()
        defer { window.orderOut(nil) }
        let guestAccount = try ShareLinkAppChecks.account(root: root.appendingPathComponent("receiver"), identity: receiver,
                                                          authority: authority, links: links)
        _ = try await guestAccount.enroll(endpoint: endpoint, code: "scripted-receiver-enrollment", deviceLabel: "Sam's Mac", accountLabel: "Sam")
        _ = try await guestAccount.openArea(id: area, label: "Checkout")
        guest.qaAdoptCollaborationAccount(guestAccount)
        let guestZonesBefore = mounted.runtime.document.zones.count
        let recordsBefore = guest.agentSupervisor.records.count
        guard let opened = guest.openSharedArea(controller: try guestAccount.makeSharedAreaController(area: area),
                                                person: receiver.person, area: area, model: guestAccount) else {
            throw Failure(description: "shared portal migration: the receiver's old zone did not open")
        }
        await opened.waitUntilOpen()
        try expect(mounted.runtime.sharedAreaZone(for: area) != nil && mounted.runtime.document.zones.count == guestZonesBefore + 1,
            "precondition: the receiver has the area as a zone, as the old version opened it")
        try mounted.runtime.flushMountedWorkspaceState()

        // Relaunch: every open area leaves the canvas, then the launch reopen.
        for app in [sender, guest] {
            app.closeSharedAreaSessions()
            app.reopenSharedAreas()
            await app.sharedAreaReopenTask?.value
        }

        // The sharer: no zone, both tiles home where they were, and this Mac
        // hosts the area as a portal.
        try expect(fixture.runtime.sharedAreaZone(for: area) == nil && fixture.runtime.document.zones.count == zonesBefore,
            "the sharer's zone leaves the workspace document")
        var worldAfter: [UUID: TileFrame] = [:]
        for tile in fixture.canvas.allTilesInWorldFrames() { worldAfter[tile.id] = tile.frame }
        let notLent = fixture.canvas.lentTile(agent) == nil && fixture.canvas.lentTile(noteTile) == nil
        let home = fixture.canvas.tileRecord(for: agent)?.zoneId == homeZone
        let unmoved = worldAfter[agent] == worldBefore[agent] && worldAfter[noteTile] == worldBefore[noteTile]
        try expect(notLent && home && unmoved, "the sharer's tiles are home, not lent, at the world frames they had before sharing")
        let entry: HostedPortalIndex.Entry? = sender.hostedPortalIndex?.entry(area: area)
        let holdsAgent = entry?.tiles.contains(where: { $0.tile == agent && $0.kind == .agent }) ?? false
        try expect(sender.hostedPortalArea(forTile: agent) == area && holdsAgent, "the sharer hosts the area as a portal holding the agent")
        let sharedFrames: [TileFrame] = (entry?.tiles ?? []).compactMap { worldAfter[$0.tile] }
        try expect(entry?.origin == SharedPortal.Origin.enclosing(sharedFrames), "the portal's origin is where the shared tiles sit now")
        try expect(sender.qaSharedAreaZoneSessions.allSatisfy(\.isClosed), "no zone session stays open on the sharer's canvas")

        // The receiver: no zone; one portal tile in a project zone.
        try expect(mounted.runtime.sharedAreaZone(for: area) == nil && mounted.runtime.document.zones.count == guestZonesBefore,
            "the receiver's zone leaves the workspace document")
        let tiles = mounted.canvas.allWorkspaceTiles().filter { $0.kind == .sharedPortal }
        let reference = tiles.first?.metadata.sharedPortal
        try expect(tiles.count == 1 && reference?.areaId == area && reference?.hostPerson == owner.person.rawValue
            && reference?.accountId == guestAccount.activeAccount?.id && reference?.name == "Checkout",
            "the receiver gets exactly one sharedPortal tile referring to the area")
        try expect(!mounted.canvas.allWorkspaceTiles().contains { $0.kind == .sharedAgent },
            "and no separate shared agent tile: the agent is inside the portal")
        let zone = tiles.first?.zoneId.flatMap { id in mounted.runtime.document.zones.first { $0.zoneId == id } }
        try expect(zone?.projectId != nil, "the tile lives in a project zone")
        try expect(guest.agentSupervisor.records.count == recordsBefore, "no AgentRecord is created on the receiver")
        try mounted.runtime.flushMountedWorkspaceState()
        let saved = Set(mounted.runtime.document.zones.compactMap(\.projectId)).flatMap { project -> [Tile] in
            (try? mounted.runtime.controller(for: project)?.projectStore.loadCanvas().tiles) ?? []
        }.filter { $0.kind == .sharedPortal }
        try expect(saved.count == 1 && saved.first?.metadata.sharedPortal?.areaId == area && saved.first?.metadata.sharedPortal?.camera == nil,
            "the tile is saved in its project's canvas.json as a reference only")
        print("Shared portal migration checks passed: an old shared zone of several tiles becomes a portal on load, on both canvases.")
    }
}
