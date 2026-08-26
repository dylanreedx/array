import Foundation

public struct ProjectRootResolver: Sendable {
    public enum Decision: Equatable, Sendable {
        case resolved(URL, Source)
        case needsPicker(Reason)
    }

    public enum Source: Equatable, Sendable {
        case environment
        case registryLastActiveProject
    }

    public enum Reason: Equatable, Sendable {
        case noUsableProject
        case openLastProjectDisabled
    }

    public struct FileSystemProbes: Sendable {
        public var directoryExists: @Sendable (String) -> Bool
        public var continuumDirectoryExists: @Sendable (String) -> Bool
        public var canCreateContinuumDirectory: @Sendable (String) -> Bool

        public init(
            directoryExists: @escaping @Sendable (String) -> Bool,
            continuumDirectoryExists: @escaping @Sendable (String) -> Bool,
            canCreateContinuumDirectory: @escaping @Sendable (String) -> Bool
        ) {
            self.directoryExists = directoryExists
            self.continuumDirectoryExists = continuumDirectoryExists
            self.canCreateContinuumDirectory = canCreateContinuumDirectory
        }

        public static let live = FileSystemProbes(
            directoryExists: { path in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
            },
            continuumDirectoryExists: { path in
                var isDirectory: ObjCBool = false
                let statePath = URL(fileURLWithPath: path).appendingPathComponent(".array").path
                return FileManager.default.fileExists(atPath: statePath, isDirectory: &isDirectory) && isDirectory.boolValue
            },
            canCreateContinuumDirectory: { path in
                FileManager.default.isWritableFile(atPath: path)
            }
        )
    }

    public var environment: [String: String]
    public var registry: Registry
    public var fileSystem: FileSystemProbes

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        registry: Registry,
        fileSystem: FileSystemProbes = .live
    ) {
        self.environment = environment
        self.registry = registry
        self.fileSystem = fileSystem
    }

    public func resolve() -> Decision {
        if let envRoot = environment["CONTINUUM_PROJECT_ROOT"], isAbsolutePath(envRoot) {
            return .resolved(URL(fileURLWithPath: envRoot), .environment)
        }

        guard registry.settings.openLastProjectOnLaunch else {
            return .needsPicker(.openLastProjectDisabled)
        }

        // The selected workspace is the primary launch context. Prefer one of
        // its authoritatively owned projects for the boot controller; otherwise
        // a last-used project from another workspace can leak its flat canvas
        // into the workspace being restored. An empty workspace intentionally
        // has no candidate and falls through to the compatibility controller
        // below, whose canvas is isolated by the app boot path.
        if let workspaceId = registry.lastActiveWorkspaceId,
           let workspace = registry.workspaces.first(where: { $0.id == workspaceId }) {
            var candidateIds: [UUID] = []
            if let lastActiveProjectId = registry.lastActiveProjectId {
                candidateIds.append(lastActiveProjectId)
            }
            candidateIds.append(contentsOf: workspace.projectIds)
            var visited = Set<UUID>()
            for candidateId in candidateIds where visited.insert(candidateId).inserted {
                guard let entry = registry.projects.first(where: {
                    $0.id == candidateId && $0.workspaceId == workspaceId
                }) else { continue }
                if isUsableProjectRoot(entry.rootPath) {
                    return .resolved(URL(fileURLWithPath: entry.rootPath), .registryLastActiveProject)
                }
            }
        }

        if let projectId = registry.lastActiveProjectId,
           let entry = registry.projects.first(where: { $0.id == projectId }),
           isUsableProjectRoot(entry.rootPath) {
            return .resolved(URL(fileURLWithPath: entry.rootPath), .registryLastActiveProject)
        }

        return .needsPicker(.noUsableProject)
    }

    private func isUsableProjectRoot(_ path: String) -> Bool {
        guard isAbsolutePath(path), fileSystem.directoryExists(path) else { return false }
        return fileSystem.continuumDirectoryExists(path) || fileSystem.canCreateContinuumDirectory(path)
    }

    private func isAbsolutePath(_ path: String) -> Bool {
        path.hasPrefix("/")
    }
}
