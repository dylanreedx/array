import AppKit
import ContinuumRevivedCore
import ContinuumRevivedCollaborationProtocol

/// `--shared-agent-migration-check`: 0.7.37 shared one agent by turning it into
/// a shared zone on both canvases. Mode A (`.plans/105-collaboration/SHARE-REDESIGN.md`)
/// shares it as one tile. This witness makes the 0.7.37 state through the
/// 0.7.37 code paths (`createSharedZone` on the sharer, `openSharedArea` into a
/// zone on the receiver), writes both workspace documents, then reopens them
/// the way a launch does (`reopenSharedAreas`), and asserts what each person
/// now has: the sharer's agent home and still hosted, with no zone; the
/// receiver's zone replaced by one `.sharedAgent` tile in a project zone.
@MainActor
enum SharedAgentMigrationChecks {
    private struct Failure: Error, CustomStringConvertible { let description: String }
    private static func expect(_ value: Bool, _ label: String) throws {
        guard value else { throw Failure(description: "shared agent migration: " + label) }
        print("PASS shared agent migration: \(label)")
    }

    static func run() async throws {
        let root = try SharedAreaCheckRig.root("shared-agent-migration")
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = Collaboration.Identity(person: .init(), device: UUID())
        let receiver = Collaboration.Identity(person: .init(), device: UUID())
        let authority = SharedAreaCheckRig.Authority(document: .init(), members: [(owner, .owner), (receiver, .editor)])
        let links = ShareLinkAppChecks.Links()
        let endpoint = try CollaborationServiceEndpoint(URL(string: "https://share-migration.example.test")!)

        // The sharer, as 0.7.37 left them: one agent shared as a zone.
        let fixture = try WorkspaceAPIChecks.makeFixture(beforeMount: { delegate, directory in
            // The fixture's agent tile, as a managed agent with a title (as ShareLinkAppChecks makes it).
            let source = ProjectStore(projectRoot: directory.appendingPathComponent("Pb"))
            var canvas = try source.loadCanvas()
            let record = delegate.qaAgentSupervisor.records.values.first(where: {
                $0.projectRoot == directory.appendingPathComponent("Pb").path && $0.tileId != nil })
            guard let index = canvas.tiles.firstIndex(where: { $0.id == record?.tileId }) else {
                throw Failure(description: "shared agent migration: the fixture has no agent tile")
            }
            canvas.tiles[index].kind = .managedAgent; canvas.tiles[index].title = "Map the checkout state machine"
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
        let agentView = fixture.canvas.tileView(for: agent)
        let zonesBefore = fixture.runtime.document.zones.count
        let share = try await sender.createSharedZone(fromTiles: [agent], name: "Map the checkout state machine")
        let area = share.areaId
        try expect(fixture.runtime.sharedAreaZone(for: area) != nil && fixture.canvas.lentTile(agent) != nil
            && fixture.runtime.document.zones.count == zonesBefore + 1,
            "precondition: the 0.7.37 path shares one agent as a zone and lends its tile to it")
        let published = await authority.document
        try expect(published.items.count == 1 && published.items.first?.kind == .agentObservation,
            "precondition: the area holds exactly the one agent")
        try fixture.runtime.flushMountedWorkspaceState()

        // The receiver, as 0.7.37 left them: the area as a zone on their canvas.
        let workspace = try WorkspaceInvariantsFixture(label: "shared-agent-migration-receiver")
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
        _ = try await guestAccount.openArea(id: area, label: "Map the checkout state machine")
        guest.qaAdoptCollaborationAccount(guestAccount)
        let guestZonesBefore = mounted.runtime.document.zones.count
        let recordsBefore = guest.agentSupervisor.records.count
        guard let opened = guest.openSharedArea(controller: try guestAccount.makeSharedAreaController(area: area),
                                                person: receiver.person, area: area, model: guestAccount) else {
            throw Failure(description: "shared agent migration: the receiver's 0.7.37 zone did not open")
        }
        await opened.waitUntilOpen()
        try expect(mounted.runtime.sharedAreaZone(for: area) != nil && mounted.runtime.document.zones.count == guestZonesBefore + 1,
            "precondition: the receiver has the area as a zone, as 0.7.37 opened it")
        try mounted.runtime.flushMountedWorkspaceState()

        // Relaunch: every open area leaves the canvas, then the launch reopen.
        for app in [sender, guest] {
            app.closeSharedAreaSessions()
            app.reopenSharedAreas()
            await app.sharedAreaReopenTask?.value
        }

        // The sharer: no zone, the agent home in its own zone with its own
        // view, and this Mac still shares it.
        try expect(fixture.runtime.sharedAreaZone(for: area) == nil && fixture.runtime.document.zones.count == zonesBefore,
            "the sharer's one-agent zone leaves the workspace document")
        try expect(fixture.canvas.lentTile(agent) == nil && fixture.canvas.tileRecord(for: agent)?.zoneId == homeZone
            && fixture.canvas.tileView(for: agent) === agentView,
            "the sharer's agent is in its home zone, not lent, with its own view")
        try expect(sender.hostedAgentArea(forTile: agent) == area,
            "the sharer still shares the agent through the same area")
        try expect(sender.qaSharedAreaZoneSessions.allSatisfy(\.isClosed), "no zone session stays open on the sharer's canvas")

        // The receiver: no zone; one shared agent tile in a project zone.
        try expect(mounted.runtime.sharedAreaZone(for: area) == nil && mounted.runtime.document.zones.count == guestZonesBefore,
            "the receiver's zone leaves the workspace document")
        let tiles = mounted.canvas.allWorkspaceTiles().filter { $0.kind == .sharedAgent }
        let reference = tiles.first?.metadata.sharedAgent
        try expect(tiles.count == 1 && reference?.areaId == area && reference?.objectId == published.items.first?.id.rawValue
            && reference?.hostPerson == owner.person.rawValue && reference?.accountId == guestAccount.activeAccount?.id,
            "the receiver gets exactly one sharedAgent tile referring to the area's agent")
        let zone = tiles.first?.zoneId.flatMap { id in mounted.runtime.document.zones.first { $0.zoneId == id } }
        try expect(zone?.projectId != nil, "the tile lives in a project zone")
        try expect(guest.agentSupervisor.records.count == recordsBefore, "no AgentRecord is created on the receiver")
        try mounted.runtime.flushMountedWorkspaceState()
        let saved = Set(mounted.runtime.document.zones.compactMap(\.projectId)).flatMap { project -> [Tile] in
            (try? mounted.runtime.controller(for: project)?.projectStore.loadCanvas().tiles) ?? []
        }.filter { $0.kind == .sharedAgent }
        try expect(saved.count == 1 && saved.first?.metadata.sharedAgent == reference,
            "the tile is saved in its project's canvas.json as a reference only")
        print("Shared agent migration checks passed: a 0.7.37 one-agent shared zone becomes mode A on load, on both canvases.")
    }
}
