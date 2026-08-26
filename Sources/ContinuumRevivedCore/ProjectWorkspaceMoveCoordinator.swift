import Foundation

/// The explicit, transactional boundary for changing project ownership.
/// Ordinary workspace switching never calls this type.
public struct ProjectWorkspaceMoveCoordinator: Sendable {
    public let registryStore: RegistryStore

    public init(registryStore: RegistryStore) {
        self.registryStore = registryStore
    }

    /// Transfer registry ownership, every project zone, and any workspace-owned
    /// tiles stamped into those zones. Each file is atomically replaced; if a later
    /// write fails, earlier writes are restored before the error is returned.
    public func moveProject(_ projectId: UUID, to targetWorkspaceId: UUID, now: Date = Date()) throws {
        let applicationSupportDirectory = registryStore.registryFile.deletingLastPathComponent()
        let originalRegistry = try registryStore.loadOrEmpty()
        try originalRegistry.validateExclusiveProjectOwnership()
        guard let sourceWorkspaceId = try originalRegistry.exclusiveWorkspaceOwner(of: projectId) else {
            throw ProjectWorkspaceOwnershipError.unknownProject(projectId)
        }
        guard sourceWorkspaceId != targetWorkspaceId else { return }

        let sourceStore = WorkspaceStore(
            workspaceId: sourceWorkspaceId,
            applicationSupportDirectory: applicationSupportDirectory)
        let targetStore = WorkspaceStore(
            workspaceId: targetWorkspaceId,
            applicationSupportDirectory: applicationSupportDirectory)
        let originalSource = try sourceStore.load()
        let originalTarget = try targetStore.load()

        guard !originalTarget.zones.contains(where: { $0.projectId == projectId }) else {
            throw ProjectWorkspaceMoveError.targetAlreadyContainsProjectZones(
                projectId: projectId, workspaceId: targetWorkspaceId)
        }

        let movingZones = originalSource.zones.filter { $0.projectId == projectId }
        let movingZoneIds = Set(movingZones.map(\.zoneId))
        let movingAmbientTiles = originalSource.ambientTiles.filter {
            $0.zoneId.map(movingZoneIds.contains) == true
        }
        let targetAmbientIds = Set(originalTarget.ambientTiles.map(\.id))
        if let collision = movingAmbientTiles.first(where: { targetAmbientIds.contains($0.id) }) {
            throw ProjectWorkspaceMoveError.ambientTileCollision(collision.id)
        }

        var updatedSource = originalSource
        updatedSource.zones.removeAll { $0.projectId == projectId }
        updatedSource.ambientTiles.removeAll { $0.zoneId.map(movingZoneIds.contains) == true }
        if updatedSource.lastActiveZoneId.map(movingZoneIds.contains) == true {
            updatedSource.lastActiveZoneId = updatedSource.zonesInZOrder.last?.zoneId
        }

        var updatedTarget = originalTarget
        updatedTarget.zones.append(contentsOf: movingZones)
        updatedTarget.ambientTiles.append(contentsOf: movingAmbientTiles)
        if updatedTarget.lastActiveZoneId == nil {
            updatedTarget.lastActiveZoneId = movingZones.first?.zoneId
        }

        var updatedRegistry = originalRegistry
        try updatedRegistry.moveProject(projectId, to: targetWorkspaceId, now: now)

        var sourceWasSaved = false
        var targetWasSaved = false
        do {
            try sourceStore.save(updatedSource)
            sourceWasSaved = true
            try targetStore.save(updatedTarget)
            targetWasSaved = true
            try registryStore.save(updatedRegistry)
        } catch {
            var rollbackFailures: [String] = []
            if targetWasSaved {
                do { try targetStore.save(originalTarget) }
                catch { rollbackFailures.append("target: \(error)") }
            }
            if sourceWasSaved {
                do { try sourceStore.save(originalSource) }
                catch { rollbackFailures.append("source: \(error)") }
            }
            if !rollbackFailures.isEmpty {
                throw ProjectWorkspaceMoveError.rollbackFailed(
                    original: String(describing: error), failures: rollbackFailures)
            }
            throw error
        }
    }
}

public enum ProjectWorkspaceMoveError: Error, Equatable, LocalizedError, Sendable {
    case targetAlreadyContainsProjectZones(projectId: UUID, workspaceId: UUID)
    case ambientTileCollision(UUID)
    case rollbackFailed(original: String, failures: [String])

    public var errorDescription: String? {
        switch self {
        case let .targetAlreadyContainsProjectZones(projectId, workspaceId):
            return "Workspace \(workspaceId) already contains zones for project \(projectId); no files were changed."
        case let .ambientTileCollision(tileId):
            return "Project move found workspace tile \(tileId) in both workspaces; no files were changed."
        case let .rollbackFailed(original, failures):
            return "Project move failed (\(original)) and rollback also failed: \(failures.joined(separator: "; "))"
        }
    }
}
