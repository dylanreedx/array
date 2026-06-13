import Foundation

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

        if let assignedWorkspaceId = registry.projects.first(where: { $0.id == project.id })?.workspaceId,
           registry.workspaces.contains(where: { $0.id == assignedWorkspaceId }) {
            attach(projectId: project.id, toWorkspace: assignedWorkspaceId, registry: &registry, updatedAt: now)
            if registry.lastActiveWorkspaceId == nil {
                registry.lastActiveWorkspaceId = assignedWorkspaceId
            }
            return assignedWorkspaceId
        }

        if let existingWorkspaceId = registry.lastActiveWorkspaceId,
           registry.workspaces.contains(where: { $0.id == existingWorkspaceId }) {
            attach(projectId: project.id, toWorkspace: existingWorkspaceId, registry: &registry, updatedAt: now)
            return existingWorkspaceId
        }

        if let existing = registry.workspaces.first {
            registry.lastActiveWorkspaceId = existing.id
            attach(projectId: project.id, toWorkspace: existing.id, registry: &registry, updatedAt: now)
            return existing.id
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

    private func attach(projectId: UUID, toWorkspace workspaceId: UUID, registry: inout Registry, updatedAt: Date) {
        for index in registry.workspaces.indices where registry.workspaces[index].id != workspaceId {
            registry.workspaces[index].projectIds.removeAll { $0 == projectId }
        }
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
}
