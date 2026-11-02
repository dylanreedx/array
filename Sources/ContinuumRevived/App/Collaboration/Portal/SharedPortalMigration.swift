import AppKit
import ContinuumRevivedCore
import ContinuumRevivedCollaborationProtocol

extension AppDelegate {
    /// A 0.7.37/0.7.38 shared zone holding more than one agent becomes mode B
    /// on load. The zone leaves the workspace document either way.
    /// - The sharer: its tiles never left home (a relaunch lends them only
    ///   after this), so they stay where they are and this Mac hosts the area
    ///   as a portal, positioned from where the tiles sit now.
    /// - Anyone else: one `.sharedPortal` tile in the project zone nearest the
    ///   old zone.
    /// Witness: `--shared-portal-migration-check`.
    @discardableResult
    func migrateZoneToPortal(_ session: SharedAreaZoneSession, model: CollaborationAccountController,
                             person: SharedArea.ID<SharedArea.Person>) -> Bool {
        guard let runtime = sharedAreaRuntime, let canvas = canvasView, let document = session.controller.document,
              let account = model.activeAccount?.id,
              let zone = runtime.document.zones.first(where: { $0.zoneId == session.zoneId }) else { return false }
        let label = model.activeAccount?.knownAreas.first(where: { $0.id == session.areaId })?.label ?? "Shared canvas"
        let owned = document.items.filter { $0.source?.owner == person }
        let bindings = session.controller.sourceBindings.filter { binding in owned.contains { $0.id == binding.object } }
        if !bindings.isEmpty {
            // The zone goes first: it hands any tile it still holds back home.
            closeSharedAreaZone(session.zoneId)
            var shared: [HostedPortalIndex.Shared] = []
            var frames: [TileFrame] = []
            for binding in bindings {
                guard let tile = binding.tileID, !shared.contains(where: { $0.tile == tile }),
                      let record = canvas.tileRecord(for: tile), let kind = SharedPortal.ItemKind.forTile(record.kind) else { continue }
                shared.append(.init(tile: tile, object: binding.object.rawValue, kind: kind))
                frames.append(canvas.worldFrame(forTileFrame: record.frame, tileId: tile))
            }
            guard !shared.isEmpty else { return true }
            let entry = HostedPortalIndex.Entry(account: account, area: session.areaId, name: label,
                                                origin: .enclosing(frames), tiles: shared)
            try? hostedPortalIndex?.put(entry)
            startHostingPortal(entry, model: model)
            refreshHostedPortalMarks()
            return true
        }
        // Someone else's area: one portal tile in the project zone nearest the old zone.
        let centre = (x: zone.origin.x + zone.size.width / 2, y: zone.origin.y + zone.size.height / 2)
        func distance(_ other: ZonePlacement) -> Double {
            let dx = other.origin.x + other.size.width / 2 - centre.x, dy = other.origin.y + other.size.height / 2 - centre.y
            return dx * dx + dy * dy
        }
        guard let target = runtime.document.zones.filter({ $0.projectId != nil }).min(by: { distance($0) < distance($1) }),
              let project = target.projectId, let spawner = runtime.controller(for: project)?.tileSpawner else { return false }
        let owner = document.items.compactMap(\.source?.owner).first { $0 != person }
        let hostName = owner.flatMap { session.controller.memberNames[$0] }.map { String($0.prefix(28)) } ?? "A teammate"
        let reference = SharedPortalTileReference(areaId: session.areaId, hostName: hostName, hostPerson: owner?.rawValue,
                                                  accountId: account, name: label)
        closeSharedAreaZone(session.zoneId)
        guard case .success(let view) = spawner.spawnSharedPortal(reference, title: label, targetZoneId: target.zoneId) else {
            return false
        }
        attachSharedPortalTile(view)
        return true
    }
}
