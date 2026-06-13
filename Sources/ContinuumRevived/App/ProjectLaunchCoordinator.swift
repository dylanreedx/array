import ContinuumRevivedCore
import Foundation

struct ProjectLaunchCoordinator {
    nonisolated(unsafe) private static var pendingWorkspaceSelection: UUID?

    struct WorkspacePickerRow: Equatable {
        var workspace: WorkspaceEntry
        var isSelectable: Bool { !workspace.projectIds.isEmpty }
    }

    struct PickerRequest: Equatable {
        var reason: ProjectRootResolver.Reason
        var rows: [ProjectPickerRow]
        var workspaces: [WorkspacePickerRow] = []
    }

    enum Decision: Equatable {
        case open(URL)
        case presentPicker(PickerRequest)
    }

    static func decide(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        registry: Registry,
        fileSystem: ProjectRootResolver.FileSystemProbes = .live
    ) -> Decision {
        switch ProjectRootResolver(environment: environment, registry: registry, fileSystem: fileSystem).resolve() {
        case let .resolved(url, _):
            return .open(url)
        case let .needsPicker(reason):
            return .presentPicker(PickerRequest(
                reason: reason,
                rows: ProjectPickerModel.makeRows(registry: registry, fileSystem: fileSystem),
                workspaces: registry.workspaces.map { WorkspacePickerRow(workspace: $0) }
            ))
        }
    }

    static func selectProject(id: UUID, from request: PickerRequest) -> URL? {
        guard case let .selected(url) = ProjectPickerModel.select(id: id, from: request.rows) else { return nil }
        return url
    }

    static func selectWorkspace(id: UUID, from request: PickerRequest) -> UUID? {
        guard let row = request.workspaces.first(where: { $0.workspace.id == id }), row.isSelectable else { return nil }
        return row.workspace.projectIds.first
    }

    static func selectWorkspaceForNextLaunch(id: UUID, from request: PickerRequest) -> UUID? {
        guard let projectId = selectWorkspace(id: id, from: request) else { return nil }
        pendingWorkspaceSelection = id
        return projectId
    }

    static func consumePendingWorkspaceSelection() -> UUID? {
        defer { pendingWorkspaceSelection = nil }
        return pendingWorkspaceSelection
    }
}
