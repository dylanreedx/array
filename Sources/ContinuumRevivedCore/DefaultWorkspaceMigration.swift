import Foundation

public enum TopologyMigrationState: Equatable, Sendable {
    case notNeeded
    case needed(legacyDescriptorIds: [UUID])
}

public struct DefaultWorkspaceMigration: Sendable {
    public static let defaultWorkspaceName = "Default"
    public static let defaultZoneColor = "blue"
    public static let defaultZoneSize = ZoneSize(width: 1280, height: 800)

    public init() {}

    public func ensureDefaultWorkspace(
        for project: Project,
        registry: inout Registry,
        applicationSupportDirectory: URL,
        now: Date = Date(),
        workspaceId: UUID = UUID(),
        zoneId: UUID = UUID()
    ) throws -> UUID {
        registry.upsertProject(project, openedAt: now)

        if let existingWorkspaceId = try resolveExistingWorkspace(
            for: project.id,
            registry: &registry,
            applicationSupportDirectory: applicationSupportDirectory,
            updatedAt: now
        ) {
            return existingWorkspaceId
        }

        let workspace = WorkspaceEntry(
            id: workspaceId,
            name: Self.defaultWorkspaceName,
            projectIds: [project.id],
            createdAt: now,
            updatedAt: now
        )
        registry.workspaces.append(workspace)
        registry.lastActiveWorkspaceId = workspaceId
        attach(projectId: project.id, toWorkspace: workspaceId, registry: &registry, updatedAt: now)

        let store = WorkspaceStore(workspaceId: workspaceId, applicationSupportDirectory: applicationSupportDirectory)
        if try store.tryLoad() == nil {
            let document = WorkspaceDocument(
                viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
                zones: [ZonePlacement(
                    zoneId: zoneId,
                    projectId: project.id,
                    origin: ZonePoint(x: 0, y: 0),
                    size: Self.defaultZoneSize,
                    color: Self.defaultZoneColor,
                    collapsed: false,
                    hydrationPolicy: .automatic
                )],
                zoneZOrder: [zoneId],
                lastActiveZoneId: zoneId
            )
            try store.save(document)
        }

        return workspaceId
    }

    public func resolveExistingWorkspace(
        for projectId: UUID,
        registry: inout Registry,
        applicationSupportDirectory: URL,
        updatedAt: Date = Date()
    ) throws -> UUID? {
        let projectWorkspaceId = registry.projects.first(where: { $0.id == projectId })?.workspaceId
        let candidates = ([registry.lastActiveWorkspaceId, projectWorkspaceId].compactMap { $0 } + registry.workspaces.map(\.id))
            .reduce(into: [UUID]()) { unique, id in
                if !unique.contains(id) { unique.append(id) }
            }

        for candidate in candidates where registry.workspaces.contains(where: { $0.id == candidate }) {
            let store = WorkspaceStore(workspaceId: candidate, applicationSupportDirectory: applicationSupportDirectory)
            if try store.tryLoad() != nil {
                registry.lastActiveWorkspaceId = candidate
                attach(projectId: projectId, toWorkspace: candidate, registry: &registry, updatedAt: updatedAt)
                return candidate
            }
        }
        return nil
    }

    public func detectTopologyMigration(
        descriptors: [TerminalSessionDescriptor],
        canvas: CanvasState,
        workspace: WorkspaceDocument
    ) -> TopologyMigrationState {
        let legacyIds = descriptors.compactMap { descriptor -> UUID? in
            guard hasLegacyPerTileSessionName(descriptor.args) else { return nil }
            guard canvas.tiles.contains(where: { $0.id == descriptor.tileId }) else { return nil }
            guard tileIsInProjectZone(tileId: descriptor.tileId, canvas: canvas, workspace: workspace) else { return nil }
            return descriptor.id
        }
        return legacyIds.isEmpty ? .notNeeded : .needed(legacyDescriptorIds: legacyIds)
    }

    private func attach(projectId: UUID, toWorkspace workspaceId: UUID, registry: inout Registry, updatedAt: Date) {
        if let workspaceIndex = registry.workspaces.firstIndex(where: { $0.id == workspaceId }) {
            if !registry.workspaces[workspaceIndex].projectIds.contains(projectId) {
                registry.workspaces[workspaceIndex].projectIds.append(projectId)
            }
            registry.workspaces[workspaceIndex].updatedAt = updatedAt
        }
        if let projectIndex = registry.projects.firstIndex(where: { $0.id == projectId }) {
            registry.projects[projectIndex].workspaceId = workspaceId
        }
    }

    private func hasLegacyPerTileSessionName(_ args: [String]) -> Bool {
        guard args.count >= 2 else { return false }
        for index in args.indices.dropLast() where args[index] == "-s" {
            let name = args[args.index(after: index)]
            if name.hasPrefix("array-"),
               !name.hasPrefix("array-proj-"),
               !name.hasPrefix("array-ws-"),
               !name.hasPrefix("array-view-") {
                return true
            }
        }
        return false
    }

    private func tileIsInProjectZone(
        tileId: UUID,
        canvas: CanvasState,
        workspace: WorkspaceDocument
    ) -> Bool {
        for zone in workspace.zones where zone.projectId == nil {
            if workspace.tiles(forZone: zone.zoneId).contains(where: { $0.id == tileId }) {
                return false
            }
        }
        guard let tile = canvas.tiles.first(where: { $0.id == tileId }) else { return false }
        let center = ZonePoint(
            x: tile.frame.x + tile.frame.width / 2,
            y: tile.frame.y + tile.frame.height / 2
        )
        for zone in workspace.zones where zone.projectId != nil {
            let frame = CanvasEngine.zoneWorldFrame(zone)
            if center.x >= frame.x,
               center.x <= frame.x + frame.width,
               center.y >= frame.y,
               center.y <= frame.y + frame.height {
                return true
            }
        }
        return false
    }
}
