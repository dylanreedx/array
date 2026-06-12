import Foundation

public enum ProjectPickerAvailability: Equatable, Sendable {
    case available
    case relativePath
    case missingDirectory
    case unusableStateDirectory
}

public struct ProjectPickerRow: Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let rootPath: String
    public let lastOpenedAt: Date
    public let pinned: Bool
    public let isLastActive: Bool
    public let availability: ProjectPickerAvailability

    public var isMissing: Bool { availability != .available }
    public var isSelectable: Bool { availability == .available }

    public init(
        id: UUID,
        name: String,
        rootPath: String,
        lastOpenedAt: Date,
        pinned: Bool,
        isLastActive: Bool,
        availability: ProjectPickerAvailability
    ) {
        self.id = id
        self.name = name
        self.rootPath = rootPath
        self.lastOpenedAt = lastOpenedAt
        self.pinned = pinned
        self.isLastActive = isLastActive
        self.availability = availability
    }
}

public enum ProjectPickerSelection: Equatable, Sendable {
    case selected(URL)
    case unselectable(ProjectPickerAvailability)
    case notFound
}

public enum ProjectPickerModel {
    public static func makeRows(
        registry: Registry,
        fileSystem: ProjectRootResolver.FileSystemProbes = .live
    ) -> [ProjectPickerRow] {
        makeRows(
            projects: registry.projects,
            lastActiveProjectId: registry.lastActiveProjectId,
            fileSystem: fileSystem
        )
    }

    public static func makeRows(
        projects: [ProjectEntry],
        lastActiveProjectId: UUID?,
        fileSystem: ProjectRootResolver.FileSystemProbes = .live
    ) -> [ProjectPickerRow] {
        projects
            .map { entry in
                ProjectPickerRow(
                    id: entry.id,
                    name: entry.name,
                    rootPath: entry.rootPath,
                    lastOpenedAt: entry.lastOpenedAt,
                    pinned: entry.pinned,
                    isLastActive: entry.id == lastActiveProjectId,
                    availability: entry.missing ? .missingDirectory : availability(for: entry.rootPath, fileSystem: fileSystem)
                )
            }
            .sorted(by: rowPrecedes)
    }

    public static func filterRows(_ rows: [ProjectPickerRow], query: String) -> [ProjectPickerRow] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return rows }
        let tokens = trimmed.split(separator: " ").map(String.init)
        return rows.filter { row in
            let haystacks = [row.name, row.rootPath, row.id.uuidString].map { $0.lowercased() }
            return tokens.allSatisfy { token in
                haystacks.contains { $0.contains(token) }
            }
        }
    }

    public static func select(id: UUID, from rows: [ProjectPickerRow]) -> ProjectPickerSelection {
        guard let row = rows.first(where: { $0.id == id }) else { return .notFound }
        guard row.isSelectable else { return .unselectable(row.availability) }
        return .selected(URL(fileURLWithPath: row.rootPath))
    }

    public static func availability(
        for rootPath: String,
        fileSystem: ProjectRootResolver.FileSystemProbes = .live
    ) -> ProjectPickerAvailability {
        guard rootPath.hasPrefix("/") else { return .relativePath }
        guard fileSystem.directoryExists(rootPath) else { return .missingDirectory }
        guard fileSystem.continuumDirectoryExists(rootPath) || fileSystem.canCreateContinuumDirectory(rootPath) else {
            return .unusableStateDirectory
        }
        return .available
    }

    private static func rowPrecedes(_ lhs: ProjectPickerRow, _ rhs: ProjectPickerRow) -> Bool {
        if lhs.pinned != rhs.pinned { return lhs.pinned && !rhs.pinned }
        if lhs.lastOpenedAt != rhs.lastOpenedAt { return lhs.lastOpenedAt > rhs.lastOpenedAt }
        let nameCompare = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        if nameCompare != .orderedSame { return nameCompare == .orderedAscending }
        let pathCompare = lhs.rootPath.localizedCaseInsensitiveCompare(rhs.rootPath)
        if pathCompare != .orderedSame { return pathCompare == .orderedAscending }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
