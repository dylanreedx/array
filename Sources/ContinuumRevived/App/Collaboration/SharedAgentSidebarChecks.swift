import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import ContinuumRevivedCollaborationProtocol

/// `--shared-agent-sidebar-check [dir]`: someone else's shared agent is a real
/// row in this Mac's sidebar.
///
/// Host: a production supervisor and projection host publish a lead whose own
/// turn is over while one helper still works. Wire: the parity rig's loopback
/// relay. Guest: a real `.sharedAgent` tile session registered through
/// `registerSharedAgentSession`, an app whose production sidebar is wired by
/// `configureWorkspaceSidebar`, beside two of the guest's own agents.
///
/// Asserted on the drawn sidebar: the lead's row with its title, the owner's
/// "Shared by" marker, the working glyph and outline from its helper; child
/// rows for the helpers once opened; Most active placing the lead with the
/// working agents ahead of a more recently active idle one; a click on either
/// row going to the lead's tile; Open as the only verb; and the glyph clearing
/// when the helper finishes on the host. With a directory, light and dark stills.
@MainActor
enum SharedAgentSidebarChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }

    private static func expect(_ value: Bool, _ label: String) throws {
        guard value else { throw Failure(description: label) }
        print("PASS shared agent sidebar: \(label)")
    }

    private struct NoRoute: SharedAgentHandoffTransport {
        struct Unused: Error {}
        func state() async throws -> Collaboration.State { throw Unused() }
        func register(_ request: Collaboration.AgentHostRegistration) async throws -> Collaboration.AgentControlState { throw Unused() }
        func control(object: UUID) async throws -> Collaboration.AgentControlState { throw Unused() }
        func change(object: UUID, request: Collaboration.AgentControlMutation) async throws -> Collaboration.AgentControlState { throw Unused() }
        func send(object: UUID, request: Collaboration.AgentPromptRequest) async throws -> Collaboration.AgentDispatchReceipt { throw Unused() }
        func receipt(id: UUID) async throws -> Collaboration.AgentDispatchReceipt { throw Unused() }
        func pending(host: UUID) async throws -> [Collaboration.AgentDispatchReceipt] { throw Unused() }
        func claim(id: UUID, request: Collaboration.AgentHostClaim) async throws -> Collaboration.AgentDispatchReceipt { throw Unused() }
        func admit(id: UUID, request: Collaboration.AgentHostClaim) async throws -> Collaboration.AgentDispatchReceipt { throw Unused() }
        func finish(id: UUID, outcome: Collaboration.AgentHostOutcome) async throws -> Collaboration.AgentDispatchReceipt { throw Unused() }
    }

    static let leadTitle = "Map the checkout state machine"

    static func run(stills: URL?) async throws {
        let root = try SharedAreaCheckRig.root("shared-agent-sidebar")
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "continuum.shared-agent-sidebar.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw Failure(description: "no defaults suite") }
        defer { defaults.removePersistentDomain(forName: suite) }
        let start = Date()

        // MARK: Host: a lead, idle, with one helper working and one finished.

        let hostRoot = root.appendingPathComponent("host-agents")
        let hostStore = AgentStore(applicationSupportDirectory: hostRoot)
        let hostProject = UUID()
        func hostRecord(_ name: String, parent: AgentID?, color: String? = nil, at offset: TimeInterval) throws -> AgentID {
            let id = AgentID(rawValue: UUID())
            var value = AgentRecord(id: id, displayName: name, harness: .claudeCode, model: "fixture/sidebar", thinking: "none",
                                    cwd: hostRoot.path, projectId: hostProject, createdAt: start.addingTimeInterval(offset),
                                    lastActivityAt: start)
            value.parentAgentID = parent
            value.identityColor = color
            value.characterName = "fox"
            try hostStore.upsert(value)
            return id
        }
        let lead = try hostRecord(leadTitle, parent: nil, color: "teal", at: -600)
        let scout = try hostRecord("Scout the wallet path", parent: lead, color: "teal", at: -500)
        let reviewer = try hostRecord("Review the receipt email", parent: lead, at: -400)
        let hostSupervisor = AgentSupervisor(store: hostStore, makeRunner: { _ in ScriptedAgentRunner(script: []) },
                                             warn: { _ in }, nameTitlerCommand: { _ in nil },
                                             transcriptStore: AgentTranscriptStore(root: hostRoot.appendingPathComponent("transcripts", isDirectory: true)))
        _ = hostSupervisor.restore()

        // The area: Dylan hosts the agent, Sam opened it.
        let dylan = Collaboration.Identity(person: .init(), device: UUID())
        let sam = Collaboration.Identity(person: .init(), device: UUID())
        let hostID = SharedArea.ID<SharedArea.Host>()
        let item = SharedArea.Item(id: .init(), kind: .agentObservation, source: .init(owner: dylan.person, host: hostID, binding: .init()))
        var document = SharedArea.Document()
        try document.apply(.init(area: document.id, expectedRevision: 0, edits: [
            .admit(item, .init(id: .init(), object: item.id, rect: .init(x: 0, y: 0, width: 520, height: 640), z: 1)),
        ]))
        let authority = SharedAreaCheckRig.Authority(document: document, members: [(dylan, .owner), (sam, .editor)])
        try await authority.setMemberLabel(dylan.person, "Dylan")
        let loop = SharedTileParityChecks.Loopback()
        let hostController = try SharedTileParityChecks.controller(root: root.appendingPathComponent("host"), identity: dylan,
                                                                   label: "Dylan", authority: authority, loop: loop, document: document)
        await hostController.open()
        try await SharedAreaCheckRig.eventually("the host's controller connects") { hostController.status == .connected }
        let projection = SharedAreaAgentProjectionHost(supervisor: hostSupervisor, controller: hostController)
        projection.sync([SharedAreaLocalSourceBinding(object: item.id, binding: item.source!.binding, host: hostID,
                                                      projectID: hostProject, agentID: lead)])
        guard projection.projectors[item.id] != nil else {
            throw Failure(description: "the production projection host made no projector (\(String(describing: projection.lastError)))")
        }
        defer { projection.stop(); Task { await hostController.close() } }
        func deliver(_ event: AgentRuntimeEvent, _ id: AgentID) { hostSupervisor.qaDeliver(event, to: id) }
        func thread(_ id: AgentID) -> String { AgentSupervisor.threadId(for: id) }
        deliver(.turnStarted(threadId: thread(lead), turnId: "lead-1"), lead)
        for (child, name) in [(scout, "Scout the wallet path"), (reviewer, "Review the receipt email")] {
            deliver(.childAgentSpawned(threadId: thread(lead), childAgentID: child.rawValue, parentAgentID: lead.rawValue,
                                       displayName: name, sourceItemID: "toolu-\(name)", provider: "claude", spawnedAt: start), lead)
            deliver(.turnStarted(threadId: thread(child), turnId: "child-1"), child)
        }
        deliver(.turnCompleted(threadId: thread(reviewer), turnId: "child-1", outcome: .completed, errorMessage: nil), reviewer)
        deliver(.turnCompleted(threadId: thread(lead), turnId: "lead-1", outcome: .completed, errorMessage: nil), lead)

        // MARK: Guest: an app with its own two agents and the shared tile.

        let projectId = UUID(), zoneId = UUID()
        let guestRoot = root.appendingPathComponent("guest-agents")
        let guestStore = AgentStore(applicationSupportDirectory: guestRoot)
        let localWorking = AgentID(rawValue: UUID()), localIdle = AgentID(rawValue: UUID())
        let localWorkingTile = UUID(), localIdleTile = UUID(), sharedTile = UUID()
        // The idle one is the newest spawned and the most recently active: by
        // anything but liveness it would sit above the shared lead.
        for (id, tile, name, offset) in [(localWorking, localWorkingTile, "Fix the saved-card toggle", -900.0),
                                         (localIdle, localIdleTile, "Tidy the release notes", -30.0)] {
            try guestStore.upsert(AgentRecord(id: id, displayName: name, harness: .claudeCode, model: "fixture/sidebar",
                                              thinking: "none", cwd: guestRoot.path, projectId: projectId,
                                              createdAt: start.addingTimeInterval(offset), lastActivityAt: start, tileId: tile))
        }
        let guestSupervisor = AgentSupervisor(store: guestStore, makeRunner: { _ in ScriptedAgentRunner(script: []) },
                                              warn: { _ in }, nameTitlerCommand: { _ in nil },
                                              transcriptStore: AgentTranscriptStore(root: guestRoot.appendingPathComponent("transcripts", isDirectory: true)))
        func tile(_ id: UUID, _ kind: TileKind, _ title: String, x: Double, metadata: TileMetadata) -> Tile {
            var value = Tile(id: id, kind: kind, title: title, frame: .init(x: x, y: 40, width: 360, height: 260),
                             zPosition: .fromLegacyRank(1), runtimeRef: nil, metadata: metadata)
            value.zoneId = zoneId
            return value
        }
        let reference = SharedAgentTileReference(areaId: document.id.rawValue, objectId: item.id.rawValue, hostName: "Dylan",
                                                 hostPerson: dylan.person.rawValue)
        let sharedTileValue = tile(sharedTile, .sharedAgent, leadTitle, x: 840, metadata: TileMetadata(sharedAgent: reference))
        let world = try AppDelegate.makeSharedAgentSidebarWorldForQA(
            root: root.appendingPathComponent("guest"), defaults: defaults,
            tiles: [tile(localWorkingTile, .managedAgent, "Fix the saved-card toggle", x: 40,
                         metadata: TileMetadata(launchProfileId: "managed-agent")),
                    tile(localIdleTile, .managedAgent, "Tidy the release notes", x: 440,
                         metadata: TileMetadata(launchProfileId: "managed-agent")),
                    sharedTileValue],
            projectId: projectId, zoneId: zoneId, supervisor: guestSupervisor, now: start)
        defer { world.window.orderOut(nil) }
        let app = world.app, inbox = world.sidebar.agentInbox
        guestSupervisor.qaDeliver(.turnStarted(threadId: thread(localWorking), turnId: "local-1"), to: localWorking)
        world.refresh()
        func layout() { inbox.layoutForQA() }
        layout()

        // The guest's tile, through the production session registration.
        let guestView = SharedAgentTileNSView(tile: sharedTileValue)
        guestView.frame = NSRect(x: 0, y: 0, width: 520, height: 640)
        let tileWindow = NSWindow(contentRect: guestView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        tileWindow.isReleasedWhenClosed = false
        tileWindow.contentView = guestView
        tileWindow.orderFrontOffscreenForChecks()
        defer { tileWindow.orderOut(nil) }
        let guestController = try SharedTileParityChecks.controller(root: root.appendingPathComponent("guest-area"), identity: sam,
                                                                    label: "Sam", authority: authority, loop: loop, document: document)
        let prompter = try SharedAgentHandoffController(identity: sam, transport: NoRoute(),
                                                        directory: root.appendingPathComponent("handoff"))
        let session = SharedAgentTileSession(view: guestView, reference: reference, controller: guestController, prompter: prompter)
        app.registerSharedAgentSession(session)
        defer { session.close() }

        let helperRow = SharedAgentSidebarRows.helperRowId(lead: sharedTile, helper: scout.rawValue)
        let reviewerRow = SharedAgentSidebarRows.helperRowId(lead: sharedTile, helper: reviewer.rawValue)
        func drawnRow(_ id: UUID) -> AgentInboxRow? { inbox.rows.first { $0.id == id } }
        try await SharedAreaCheckRig.eventually("the guest's sidebar draws the shared lead with its roster", attempts: 2400) {
            layout()
            return drawnRow(sharedTile).map { _ in app.sharedAgentRowTiles[helperRow] != nil } ?? false
        }

        // MARK: The lead's row.

        guard let leadRow = drawnRow(sharedTile) else { throw Failure(description: "no shared lead row") }
        try expect(leadRow.identityColor == "teal" && leadRow.characterName == "fox", "lead identity crosses the projection into the sidebar")
        try expect(leadRow.title == leadTitle && leadRow.parentId == nil && leadRow.workspaceId == world.workspaceId
            && leadRow.projectId == projectId,
            "the shared tile is a top-level row titled as the tile, in its project and workspace")
        try expect(inbox.whereMarkerForQA(id: sharedTile)?.text == "Shared by Dylan",
            "the row carries the owner's 'Shared by Dylan' marker (got \(inbox.whereMarkerForQA(id: sharedTile)?.text ?? "none"))")
        guard let leadCell = inbox.ownershipCellForQA(id: sharedTile) else { throw Failure(description: "no cell for the shared lead") }
        leadCell.layoutSubtreeIfNeeded()
        let expectsSweep = leadCell.activeIndicatorStyle == SidebarActiveIndicatorStyle.classic.rawValue
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        try expect(leadRow.state == .ready && leadCell.showsWorkingGlyphForQA && leadCell.isSweepingForQA == expectsSweep,
            "an idle shared lead with a working helper draws its working glyph and follows the selected style's border policy "
            + "(state \(leadRow.state), glyph \(leadCell.showsWorkingGlyphForQA), outline \(leadCell.isSweepingForQA))")

        // MARK: Sort: Most active, the guest's first-launch order.

        try expect(inbox.sortModeForQA == .mostActive, "the guest sidebar opens on Most active")
        let leads = inbox.drawnSequenceForQA.filter { !$0.hasPrefix("#") }
        let expectedLeads = [leadTitle, "Fix the saved-card toggle", "Tidy the release notes"]
        try expect(leads.filter(expectedLeads.contains) == expectedLeads,
            "Most active puts the shared lead, whose helper's turn is newest, above the working local agent "
            + "and both above the newer, more recently active idle one (drew \(leads))")

        // MARK: Child rows.

        if inbox.drawnSequenceForQA.contains("Scout the wallet path") == false {
            try expect(inbox.clickDisclosureForQA(id: sharedTile), "the folded lead's fold control opens it")
            layout()
        }
        let sequence = inbox.drawnSequenceForQA
        guard let leadIndex = sequence.firstIndex(of: leadTitle) else { throw Failure(description: "the lead left the list") }
        let children = Array(sequence.dropFirst(leadIndex + 1).prefix(2))
        try expect(Set(children) == ["Scout the wallet path", "Review the receipt email"],
            "the open lead draws its two helpers as child rows right under it (drew \(sequence))")
        try expect(drawnRow(helperRow)?.parentId == sharedTile && drawnRow(helperRow)?.state == .working
            && drawnRow(reviewerRow)?.state == .ready && drawnRow(helperRow)?.identityColor == "teal",
            "each child row is parented to the lead, with the host's state and identity colour")

        // MARK: Selecting, and what a row offers.

        app.qaSharedAgentRevealTile = nil
        _ = inbox.clickRowForQA(id: helperRow)
        try expect(app.qaSharedAgentRevealTile == sharedTile, "clicking a helper's row goes to its lead's tile")
        app.qaSharedAgentRevealTile = nil
        _ = inbox.clickRowForQA(id: sharedTile)
        try expect(app.qaSharedAgentRevealTile == sharedTile, "clicking the lead's row goes to its tile")
        let menu = InboxRowAction.menuItems(for: [leadRow])
        try expect(menu == [.openInTile] && !inbox.beginRename(agentId: sharedTile),
            "a shared row offers Open alone and no rename (menu \(menu))")
        let palette = app.sidebarInboxRows().filter { $0.sharedAgent != nil }.count
        try expect(palette == 3, "the sidebar's rows hold the lead and both helpers (\(palette))")

        // MARK: Stills while the helper works.

        if let stills {
            try FileManager.default.createDirectory(at: stills, withIntermediateDirectories: true)
            for dark in [false, true] {
                world.window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                layout()
                try SidebarOwnershipChecks.write(world.sidebar, to: stills.appendingPathComponent("guest-sidebar-\(dark ? "dark" : "light").png"))
            }
            world.window.appearance = nil
        }

        // MARK: The helper finishes on the host.

        deliver(.turnCompleted(threadId: thread(scout), turnId: "child-1", outcome: .completed, errorMessage: nil), scout)
        try await SharedAreaCheckRig.eventually("the guest's helper row reads finished", attempts: 2400) {
            layout()
            return drawnRow(helperRow)?.state == .ready
        }
        guard let restingCell = inbox.ownershipCellForQA(id: sharedTile) else { throw Failure(description: "the lead's cell went away") }
        restingCell.layoutSubtreeIfNeeded()
        try expect(!restingCell.showsWorkingGlyphForQA && !restingCell.isSweepingForQA,
            "with the last helper done the shared lead drops the glyph and the outline")
        print("shared agent sidebar: lead row, marker, glyph from a helper, child rows, Most active position, reveal, Open-only"
              + (stills.map { "; stills in \($0.path)" } ?? ""))
    }
}
