import ContinuumRevivedCore
import Foundation

struct ProjectLaunchCoordinator {
    struct PickerRequest: Equatable {
        var reason: ProjectRootResolver.Reason
        var rows: [ProjectPickerRow]
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
                rows: ProjectPickerModel.makeRows(registry: registry, fileSystem: fileSystem)
            ))
        }
    }

    static func selectProject(id: UUID, from request: PickerRequest) -> URL? {
        guard case let .selected(url) = ProjectPickerModel.select(id: id, from: request.rows) else { return nil }
        return url
    }
}
