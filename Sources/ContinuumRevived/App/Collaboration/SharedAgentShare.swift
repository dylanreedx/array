import AppKit
import ContinuumRevivedCore
import ContinuumRevivedCollaborationProtocol

// Mode A of the share redesign (`.plans/105-collaboration/SHARE-REDESIGN.md`):
// share one agent. Copy publishes the agent into an area that is only a
// permission container; nothing on the sharer's canvas moves and no zone is
// made. The person who opens the link gets one `.sharedAgent` tile in the zone
// they are looking at. The agent keeps running on the sharer's Mac.

/// The agents this Mac shares, by account, so their hosts restart at launch and
/// Share on the same tile reopens the same area. App state, channel-split: it
/// sits beside the collaboration account list, never in a project's `.array/`.
@MainActor
final class HostedAgentShareIndex {
    struct Entry: Codable, Equatable {
        let account: String
        let area: UUID
        let tile: UUID
        let object: UUID?
    }
    private struct File: Codable { var schema = 1; var entries: [Entry] }

    let url: URL
    private(set) var entries: [Entry]

    init(directory: URL) {
        url = directory.appendingPathComponent("hosted-agents.json")
        entries = (try? JSONDecoder().decode(File.self, from: Data(contentsOf: url)))?.entries ?? []
    }

    func area(forTile tile: UUID, account: String) -> UUID? {
        entries.last { $0.tile == tile && $0.account == account }?.area
    }
    func entries(account: String) -> [Entry] { entries.filter { $0.account == account } }

    func add(_ entry: Entry) throws {
        entries.removeAll { $0.area == entry.area || ($0.tile == entry.tile && $0.account == entry.account) }
        entries.append(entry)
        try save()
    }
    func remove(area: UUID) throws {
        guard entries.contains(where: { $0.area == area }) else { return }
        entries.removeAll { $0.area == area }
        try save()
    }
    private func save() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(File(entries: entries)).write(to: url, options: .atomic)
    }
}

/// What one `.sharedAgent` tile reads from: the area's controller (document,
/// host liveness, member names), the owner's projection through the live view,
/// and the handoff controller its prompts go through.
@MainActor
final class SharedAgentTileSession {
    let tileId: UUID
    let reference: SharedAgentTileReference
    let controller: SharedAreaController
    let prompter: SharedAgentHandoffController
    let live: SharedAgentLiveView
    private weak var view: SharedAgentTileNSView?
    private var observer: UUID?
    private var openTask: Task<Void, Never>?
    private var hadItem = false
    private(set) var isClosed = false
    private struct Applied: Equatable { let state: SharedAgentTileNSView.State; let hostName: String; let colour: NSColor }
    private var lastApplied: Applied?
    /// The guest sidebar's feed: this tile's connection, the lead's phase and
    /// its helpers, after every read and every liveness change. The receiver
    /// pushes rows only when they changed (`SharedAgentSidebarRows.Tracker`).
    var onSidebarFacts: ((UUID, SharedAgentSidebarRows.Facts) -> Void)?
    private var tileState: SharedAgentTileNSView.State = .connecting
    var sidebarFacts: SharedAgentSidebarRows.Facts {
        let connection: SharedAgentSidebarRows.Connection
        switch tileState {
        case .live: connection = live.replica.state == nil ? .connecting : .live
        case .offline: connection = .offline
        case .stopped: connection = .stopped
        case .connecting, .placeholder: connection = .connecting
        }
        return .init(connection: connection, phase: live.replica.state?.phase, helpers: live.helpers.helpers)
    }

    init(view: SharedAgentTileNSView, reference: SharedAgentTileReference, controller: SharedAreaController,
         prompter: SharedAgentHandoffController) {
        tileId = view.tile.id; self.view = view; self.reference = reference
        self.controller = controller; self.prompter = prompter
        live = SharedAgentLiveView(controller: controller)
        live.prompter = prompter
        view.install(live: live)
        view.session = self
        live.onRead = { [weak self] in self?.reportSidebar() }
    }

    private func reportSidebar() {
        guard !isClosed else { return }
        onSidebarFacts?(tileId, sidebarFacts)
    }

    func start() {
        guard !isClosed, observer == nil else { return }
        observer = controller.addChangeObserver { [weak self] in self?.refresh() }
        refresh()
        openTask = Task { [weak self] in
            guard let self else { return }
            await controller.open()
            refresh()
        }
    }
    func waitUntilOpen() async { await openTask?.value }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        openTask?.cancel(); openTask = nil
        live.stop()
        if let observer { controller.removeChangeObserver(observer) }; observer = nil
        if view?.session === self { view?.session = nil }
        let controller = controller
        Task { await controller.close() }
    }

    var item: SharedArea.Item? {
        controller.document?.items.first { $0.id.rawValue == reference.objectId && $0.kind == .agentObservation }
    }
    var hostPerson: SharedArea.ID<SharedArea.Person>? {
        item?.source?.owner ?? reference.hostPerson.map(SharedArea.ID<SharedArea.Person>.init)
    }
    var hostName: String {
        guard let host = hostPerson else { return reference.hostName }
        return controller.memberNames[host].map { String($0.prefix(28)) } ?? reference.hostName
    }

    func refresh() {
        guard !isClosed, let view else { return }
        let item = self.item
        if item != nil { hadItem = true }
        let host = hostPerson
        let colour = host.map { SharedAreaPersonColour.color(for: $0, host: $0) } ?? .systemOrange
        let liveness = item.flatMap { SharedAreaHostLivenessCopy.liveness(for: $0, in: controller.hostLiveness) }
        live.hostOnline = liveness.map { $0.state == .online ? true : $0.state == .offline ? false : nil } ?? nil
        let next: SharedAgentTileNSView.State
        switch controller.status {
        case .unavailable(.accessDenied):
            next = .stopped("\(hostName) stopped sharing")
        case .unavailable:
            next = .stopped("\(hostName)'s agent can't be reached")
        default:
            if hadItem, item == nil, controller.document != nil {
                next = .stopped("\(hostName) stopped sharing")
            } else if liveness?.state == .offline {
                next = .offline(lastSeen: liveness?.lastSeen)
            } else if controller.document == nil {
                next = .connecting
            } else {
                next = .live
            }
        }
        if case .stopped = next {
            // Nothing new arrives and nothing more is sent: what was already
            // delivered stays on screen until the tile is closed.
            live.stop()
            if live.prompter != nil { live.prompter = nil }
            live.ended = "No longer shared · showing what arrived before"
        } else {
            // Access came back (a new link, or a cached refusal the relay
            // has since lifted): prompts go through again.
            if live.prompter == nil { live.prompter = prompter }
            if live.ended != nil { live.ended = nil }
            if let item, live.object != item.id || !live.isPolling { live.show(object: item.id, in: controller.document) }
        }
        tileState = next
        reportSidebar()
        // Only a change repaints: the controller reports every presence frame.
        let applied = Applied(state: next, hostName: hostName, colour: colour)
        guard applied != lastApplied else { return }
        lastApplied = applied
        view.apply(next, hostName: hostName, colour: colour)
    }
}

extension AppDelegate {
    // MARK: - Host: share one agent

    var hostedAgentShares: HostedAgentShareIndex? {
        if let hostedAgentSharesStorage { return hostedAgentSharesStorage }
        guard let model = try? collaborationAccountModel() else { return nil }
        let index = HostedAgentShareIndex(directory: model.storeDirectory)
        hostedAgentSharesStorage = index
        return index
    }

    /// The area an agent tile is already shared through, for the signed-in account.
    func hostedAgentArea(forTile tile: UUID) -> UUID? {
        guard let model = try? collaborationAccountModel(), let account = model.activeAccount?.id ?? model.selectedAccountID else { return nil }
        return hostedAgentShares?.area(forTile: tile, account: account)
    }

    /// Copy, for one agent: create the area, publish the agent into it as a
    /// live observation, and start this Mac's host for it. The tile keeps its
    /// zone, its frame and its runner; no zone is made.
    func shareAgent(tile tileId: UUID, name: String) async throws -> UUID {
        guard let canvas = canvasView else { throw WorkspaceRuntime.SharedZoneError.noCanvas }
        guard let tile = canvas.tileRecord(for: tileId), tile.kind == .managedAgent,
              let zone = tile.zoneId, let project = canvas.projectId(forZone: zone) else {
            throw WorkspaceRuntime.SharedZoneError.tileNotInstalled(tileId)
        }
        let model = try await shareLinks.readyAccount()
        guard let account = model.activeAccount?.id else { throw ShareLinkFailure.notSignedIn }
        if hostedAgentShares?.area(forTile: tileId, account: account) != nil {
            throw WorkspaceRuntime.SharedZoneError.alreadyShared(tileId)
        }
        // The access poll can hold the account for a moment; wait it out.
        let area = try await ShareLinkCoordinator.waitingOutBusy { try await model.createArea(label: name).scope.area.rawValue }
        let objects = try await ShareLinkCoordinator.waitingOutBusy {
            try await self.shareLinks.publish(selection: .tiles([.init(projectID: project, tileID: tileId)]), intoArea: area)
        }
        guard let object = objects[tileId] else { throw ShareLinkFailure.nothingToShare }
        try hostedAgentShares?.add(.init(account: account, area: area, tile: tileId, object: object.rawValue))
        startHostingSharedAgent(area: area, model: model)
        refreshHostedAgentMarks()
        return area
    }

    /// Undo of `shareAgent` when no link could be minted: the agent leaves the
    /// area and this Mac stops hosting it.
    func cancelAgentShare(area: UUID) async {
        if let model = try? collaborationAccountModel(), let account = model.activeAccount?.id {
            sharedAreaHostSessions.removeValue(forKey: account + "/" + area.uuidString)?.stop()
            if let controller = try? model.makeSharedAreaController(area: area) {
                await controller.open()
                if let document = controller.document, !document.items.isEmpty, controller.canSubmit {
                    _ = await controller.submit(.init(area: document.id, expectedRevision: document.revision,
                                                      edits: document.items.map { .remove($0.id) }))
                }
                await controller.close()
            }
        }
        try? hostedAgentShares?.remove(area: area)
        refreshHostedAgentMarks()
    }

    /// The host that publishes the agent's projection and runs teammates'
    /// prompts. It needs no zone and no scene.
    func startHostingSharedAgent(area: UUID, model: CollaborationAccountController) {
        guard let account = model.activeAccount?.id, Self.reachesRelay(model) else { return }
        let key = account + "/" + area.uuidString
        if let existing = sharedAreaHostSessions[key] { existing.start(); return }
        do {
            let host = try SharedAreaHostSession(account: model, area: area, supervisor: agentSupervisor)
            let storage = host.controller.storageDirectory
            host.liveTileSources = { [weak self] binding in self?.makeLiveTileSource(binding, storage: storage) }
            sharedAreaHostSessions[key] = host
            host.start()
        } catch {
            fputs("startHostingSharedAgent failed: \(error)\n", stderr)
        }
    }

    /// Fixture accounts name relays that do not exist: a check talks to the
    /// relay only when it runs a real one on loopback, as `openSharedArea`
    /// rules for zones.
    static func reachesRelay(_ model: CollaborationAccountController) -> Bool {
        !CommandLine.arguments.contains(where: { $0.hasSuffix("-check") })
            || (model.activeAccount?.endpoint.hasPrefix("http://127.0.0.1") ?? false)
    }

    /// At launch: every agent this Mac shares is hosted again, so queued
    /// prompts run and teammates see it live. Never asks for a sign-in.
    func resumeHostedAgentShares() {
        // Nothing is read from the Keychain unless this Mac shares an agent.
        guard let model = try? collaborationAccountModel(),
              let remembered = model.activeAccount?.id ?? model.selectedAccountID ?? (model.accounts.count == 1 ? model.accounts.first?.id : nil),
              hostedAgentShares?.entries(account: remembered).isEmpty == false else { return }
        Task { [weak self] in
            guard let self else { return }
            if model.status != .ready { _ = try? await model.select(accountID: remembered) }
            guard model.status == .ready, let account = model.activeAccount?.id,
                  let entries = hostedAgentShares?.entries(account: account), !entries.isEmpty else { return }
            for entry in entries { startHostingSharedAgent(area: entry.area, model: model) }
            refreshHostedAgentMarks()
        }
    }

    /// "Yours · shared" on every agent tile this Mac shares, naming the people
    /// who have access once the relay lists them.
    func refreshHostedAgentMarks() {
        guard let canvas = canvasView, let model = try? collaborationAccountModel(),
              let account = model.activeAccount?.id ?? model.selectedAccountID else { return }
        let entries = hostedAgentShares?.entries(account: account) ?? []
        let shared = Set(entries.map(\.tile))
        for tile in canvas.allWorkspaceTiles() where tile.kind == .managedAgent || TileNSView.sharesLive(tile.kind) {
            guard let view = canvas.tileView(for: tile.id) else { continue }
            guard shared.contains(tile.id), let entry = entries.last(where: { $0.tile == tile.id }) else {
                if view.ownershipMark != nil { view.setOwnershipMark(nil) }
                continue
            }
            let people = hostedAgentPeople[entry.area] ?? []
            let text = people.isEmpty ? "Yours · shared" : "Yours · shared with " + ListFormatter.localizedString(byJoining: people)
            let me = model.activeAccount?.identity.person
            view.setOwnershipMark(.init(text: text, colour: me.map { SharedAreaPersonColour.color(for: $0, host: $0) } ?? .systemPurple,
                                        outlined: false))
        }
        // A shared terminal also carries its Live badge and Stop sharing.
        refreshTerminalLiveBadges()
        // An agent shared in a portal keeps that mark instead.
        refreshHostedPortalMarks()
        guard hostedAgentAccessTask == nil, !entries.isEmpty, Self.reachesRelay(model) else { return }
        // Who has access, re-read on a slow beat while anything is shared, so
        // the tab names someone who joined without the popover open.
        hostedAgentAccessTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let account = (try? collaborationAccountModel())?.activeAccount?.id,
                      hostedAgentShares?.entries(account: account).isEmpty == false else { break }
                // An open popover reads access itself, every 2 s.
                if !shareEntry.isPresented { await refreshHostedAgentPeople() }
                try? await Task.sleep(for: .seconds(15))
            }
            self?.hostedAgentAccessTask = nil
        }
    }

    /// Who has opened each shared agent, as the relay lists them now.
    func refreshHostedAgentPeople() async {
        guard let model = try? collaborationAccountModel(), let account = model.activeAccount?.id,
              let entries = hostedAgentShares?.entries(account: account) else { return }
        var changed = false
        for entry in entries {
            guard let rows = try? await shareLinks.listAccess(area: entry.area) else { continue }
            var seen = Set<UUID>()
            let names = rows.filter { $0.status != .revoked }.flatMap(\.people)
                .filter { $0.active && seen.insert($0.person.rawValue).inserted }.map(\.label)
            if hostedAgentPeople[entry.area] != names { hostedAgentPeople[entry.area] = names; changed = true }
        }
        if changed { refreshHostedAgentMarks() }
    }

    // MARK: - Migration from 0.7.37's one-agent zones

    /// A 0.7.37 shared zone holding exactly one agent becomes mode A on load.
    /// The sharer's agent stays in its own zone and this Mac keeps hosting it;
    /// on anyone else's canvas the zone becomes one `.sharedAgent` tile in the
    /// nearest project zone. Either way the zone leaves the document. A zone
    /// holding anything else stays a zone until the portal tile replaces it.
    /// Witness: `--shared-agent-migration-check`.
    @discardableResult
    func migrateOneAgentZone(_ session: SharedAreaZoneSession, model: CollaborationAccountController,
                             person: SharedArea.ID<SharedArea.Person>) -> Bool {
        guard let runtime = sharedAreaRuntime, let document = session.controller.document,
              document.items.count == 1, let item = document.items.first, item.kind == .agentObservation,
              let owner = item.source?.owner, let account = model.activeAccount?.id,
              let zone = runtime.document.zones.first(where: { $0.zoneId == session.zoneId }) else { return false }
        if owner == person {
            // The sharer: its tile never left its project (0.7.37 lent it, and a
            // relaunch lends it again only after this). Keep hosting it.
            guard let tile = session.controller.sourceBindings.first(where: { $0.object == item.id })?.tileID else { return false }
            closeSharedAreaZone(session.zoneId)
            try? hostedAgentShares?.add(.init(account: account, area: session.areaId, tile: tile, object: item.id.rawValue))
            startHostingSharedAgent(area: session.areaId, model: model)
            refreshHostedAgentMarks()
            return true
        }
        // Someone else's agent: one tile in the project zone nearest the old zone.
        let centre = (x: zone.origin.x + zone.size.width / 2, y: zone.origin.y + zone.size.height / 2)
        func distance(_ other: ZonePlacement) -> Double {
            let dx = other.origin.x + other.size.width / 2 - centre.x, dy = other.origin.y + other.size.height / 2 - centre.y
            return dx * dx + dy * dy
        }
        guard let target = runtime.document.zones.filter({ $0.projectId != nil }).min(by: { distance($0) < distance($1) }),
              let project = target.projectId, let spawner = runtime.controller(for: project)?.tileSpawner else { return false }
        let hostName = session.controller.memberNames[owner].map { String($0.prefix(28)) } ?? "A teammate"
        let label = model.activeAccount?.knownAreas.first(where: { $0.id == session.areaId })?.label ?? "Shared agent"
        let reference = SharedAgentTileReference(areaId: session.areaId, objectId: item.id.rawValue, hostName: hostName,
                                                 hostPerson: owner.rawValue, accountId: account)
        closeSharedAreaZone(session.zoneId)
        guard case .success(let view) = spawner.spawnSharedAgent(reference, title: label, targetZoneId: target.zoneId) else {
            return false
        }
        attachSharedAgentTile(view)
        return true
    }

    // MARK: - Guest: one tile in the armed zone

    /// Whether a link's area is one shared agent: exactly one item, an agent
    /// observation, owned by someone else.
    static func sharedAgentItem(in document: SharedArea.Document, me: SharedArea.ID<SharedArea.Person>?) -> SharedArea.Item? {
        guard document.items.count == 1, let item = document.items.first, item.kind == .agentObservation,
              let owner = item.source?.owner, owner != me else { return nil }
        return item
    }

    /// A link to one agent: one `.sharedAgent` tile lands in the zone this
    /// person is looking at, in view. Opening it again reveals the same tile.
    @discardableResult
    func openSharedAgentLink(model: CollaborationAccountController, area: UUID, item: SharedArea.Item) async throws -> UUID {
        guard let canvas = canvasView else { throw ShareLinkFailure.noWorkspace }
        if let existing = canvas.allWorkspaceTiles().first(where: {
            $0.kind == .sharedAgent && $0.metadata.sharedAgent?.areaId == area && $0.metadata.sharedAgent?.objectId == item.id.rawValue
        }) {
            // Opened again, say after access was removed and a new link
            // given: the same tile reconnects with the access just granted.
            if let view = canvas.tileView(for: existing.id) as? SharedAgentTileNSView, let reference = view.reference {
                startSharedAgentSession(view, reference: reference, model: model,
                                        controller: try model.makeSharedAreaController(area: area))
            }
            canvas.centerOnTile(existing.id)
            focusSpawnedTile(existing.id)
            return existing.id
        }
        guard let spawner = spawnerForFilesystemCreation() else { throw ShareLinkFailure.noWorkspace }
        // The owner's name, from the relay, before the tile is made: it is what
        // a placeholder on another install will say.
        let controller = try model.makeSharedAreaController(area: area)
        await controller.open()
        let owner = item.source?.owner
        // Member names come with the first authority frame, a moment after open.
        for _ in 0..<50 where owner.map({ controller.memberNames[$0] == nil }) ?? false {
            try? await Task.sleep(for: .milliseconds(100))
        }
        let hostName = owner.flatMap { controller.memberNames[$0] }.map { String($0.prefix(28)) } ?? "A teammate"
        let label = model.activeAccount?.knownAreas.first(where: { $0.id == area })?.label ?? "Shared agent"
        let reference = SharedAgentTileReference(areaId: area, objectId: item.id.rawValue, hostName: hostName,
                                                 hostPerson: owner?.rawValue, accountId: model.activeAccount?.id)
        let view: SharedAgentTileNSView
        switch spawner.spawnSharedAgent(reference, title: label) {
        case .success(let spawned): view = spawned
        case .failure(let error): await controller.close(); throw error
        }
        attachSharedAgentTile(view, model: model, controller: controller)
        canvas.centerOnTile(view.tile.id)
        focusSpawnedTile(view.tile.id)
        presentSharedAgentArrival(hostName: hostName, tile: view.tile.id,
                                  colour: owner.map { SharedAreaPersonColour.color(for: $0, host: $0) } ?? .systemPurple)
        return view.tile.id
    }

    /// A hydrated `.sharedAgent` tile: reconnects through the signed-in
    /// account when it is the one that joined, else shows the placeholder.
    func attachSharedAgentTile(_ view: SharedAgentTileNSView, model given: CollaborationAccountController? = nil,
                               controller opened: SharedAreaController? = nil) {
        view.onWindowChange = { [weak self] view, inWindow in
            guard let self else { return }
            if inWindow { if view.session == nil { attachSharedAgentTile(view) } }
            else { sharedAgentTileSessions.removeValue(forKey: view.tile.id)?.close() }
        }
        guard let reference = view.reference else { return }
        if let opened, let given {
            startSharedAgentSession(view, reference: reference, model: given, controller: opened)
            return
        }
        guard !view.attaching else { return }
        view.attaching = true
        Task { [weak self, weak view] in
            defer { view?.attaching = false }
            guard let self, let view, view.session == nil else { return }
            guard let model = try? collaborationAccountModel() else { return }
            await Self.awaitRememberedAccount(model)
            guard view.session == nil, model.status == .ready, let account = model.activeAccount,
                  reference.accountId == nil || reference.accountId == account.id,
                  account.knownAreas.contains(where: { $0.id == reference.areaId }),
                  let controller = try? model.makeSharedAreaController(area: reference.areaId) else { return }
            startSharedAgentSession(view, reference: reference, model: model, controller: controller)
        }
    }

    func startSharedAgentSession(_ view: SharedAgentTileNSView, reference: SharedAgentTileReference,
                                         model: CollaborationAccountController, controller: SharedAreaController) {
        guard let prompter = try? model.makeAgentHandoffController(area: reference.areaId) else { return }
        sharedAgentTileSessions.removeValue(forKey: view.tile.id)?.close()
        registerSharedAgentSession(SharedAgentTileSession(view: view, reference: reference, controller: controller,
                                                          prompter: prompter))
    }

    /// Every guest tile session starts here: kept by tile, and feeding the
    /// sidebar's row for it (`noteSharedAgentSidebar`).
    func registerSharedAgentSession(_ session: SharedAgentTileSession) {
        sharedAgentTileSessions.removeValue(forKey: session.tileId)?.close()
        session.onSidebarFacts = { [weak self] tile, facts in self?.noteSharedAgentSidebar(tile: tile, facts) }
        sharedAgentTileSessions[session.tileId] = session
        session.start()
    }

    /// The tile was closed on this canvas: only this canvas forgets it.
    func sharedAgentTileClosed(_ tileId: UUID) {
        sharedAgentTileSessions.removeValue(forKey: tileId)?.close()
        sharedAgentSidebar.forget(tile: tileId)
    }

    /// "Dylan shared an agent with you. It runs on Dylan's Mac." with Show,
    /// at the top of the canvas; it leaves after a few seconds or on Show.
    func presentSharedAgentArrival(hostName: String, tile: UUID, colour: NSColor = .systemPurple) {
        guard let canvas = canvasView else { return }
        canvas.subviews.filter { $0 is SharedAgentArrivalBanner }.forEach { $0.removeFromSuperview() }
        let banner = SharedAgentArrivalBanner(text: "\(hostName) shared an agent with you. It runs on \(hostName)'s Mac.", colour: colour)
        let size = banner.preferredSize
        banner.frame = NSRect(x: (canvas.bounds.width - size.width) / 2, y: canvas.isFlipped ? 14 : canvas.bounds.height - size.height - 14,
                              width: size.width, height: size.height)
        banner.autoresizingMask = canvas.isFlipped ? [.minXMargin, .maxXMargin, .maxYMargin] : [.minXMargin, .maxXMargin, .minYMargin]
        banner.onShow = { [weak self, weak banner] in
            banner?.removeFromSuperview()
            self?.canvasView?.centerOnTile(tile)
            self?.focusSpawnedTile(tile)
        }
        canvas.addSubview(banner, positioned: .above, relativeTo: nil)
        Task { @MainActor [weak banner] in
            try? await Task.sleep(for: .seconds(10))
            banner?.removeFromSuperview()
        }
    }
}
