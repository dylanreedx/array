import ContinuumRevivedCore
import Foundation

/// Queue 91 P4 production-adapter foundation.
///
/// This adapter is deliberately pure: it only converts already-captured canvas,
/// registry, and agent-location snapshots into the provider-neutral Core input.
/// It does not read stores, process cwd, UI state, or filesystem metadata.
enum AgentContextGravityCanvasAdapter {
    struct ManagedAgentWorldSnapshot: Equatable, Sendable {
        var agentId: String
        var frame: TileFrame
        var location: AgentLocationSnapshot

        init(agentId: String, frame: TileFrame, location: AgentLocationSnapshot) {
            self.agentId = agentId
            self.frame = frame
            self.location = location
        }
    }

    struct DocumentWorldSnapshot: Equatable, Sendable {
        var tileId: UUID
        var frame: TileFrame
        var location: DocumentLocation
    }

    static func makeInput(
        newTileFrame: TileFrame,
        workspaceId: UUID,
        projectZones: [ZonePlacement],
        managedAgents: [ManagedAgentWorldSnapshot],
        documents: [DocumentWorldSnapshot] = [],
        registry: Registry,
        newAgentCheckoutRoot: URL,
        newAgentCheckoutRootsByProjectId: [UUID: URL] = [:],
        workspaceDefaultProjectId: UUID? = nil
    ) -> AgentContextGravityInput {
        let projectEntries = Dictionary(uniqueKeysWithValues: registry.projects.map { ($0.id, $0) })
        let safeCheckoutRoots = projectEntries.mapValues { project in
            newAgentCheckoutRootsByProjectId[project.id] ?? URL(fileURLWithPath: project.rootPath, isDirectory: true)
        }

        let zoneSignals = projectZones.compactMap { zone -> AgentScopeSignal? in
            guard let projectId = zone.projectId,
                  let project = projectEntries[projectId] else { return nil }
            return AgentScopeSignal(
                provenance: .projectZone(zoneId: zone.zoneId.uuidString),
                frame: AgentWorldRect(zone),
                home: home(for: project, checkoutRoot: safeCheckoutRoots[projectId]))
        }

        let agentSignals = managedAgents.map { snapshot in
            let projectId = snapshot.location.home.projectId
            let registryProject = projectId.flatMap { projectEntries[$0] }
            let home: AgentHome
            if let registryProject {
                home = Self.home(for: registryProject, checkoutRoot: safeCheckoutRoots[registryProject.id])
            } else {
                home = snapshot.location.home
            }
            return AgentScopeSignal(
                provenance: .managedAgent(agentId: snapshot.agentId),
                frame: AgentWorldRect(snapshot.frame),
                home: home,
                relativeDirectory: snapshot.location.workingLocation.relativePath)
        }

        let documentSignals = documents.compactMap { snapshot -> AgentScopeSignal? in
            guard case let .checkout(projectId, _, _) = snapshot.location.scope,
                  let projectId,
                  let project = projectEntries[projectId] else { return nil }
            return AgentScopeSignal(
                provenance: .file(entityId: snapshot.tileId.uuidString),
                frame: AgentWorldRect(snapshot.frame),
                home: home(for: project, checkoutRoot: safeCheckoutRoots[projectId]),
                relativeDirectory: snapshot.location.relativeDirectory)
        }

        let workspaceDefault = workspaceDefaultProjectId
            .flatMap { projectEntries[$0] }
            .map { project in home(for: project, checkoutRoot: safeCheckoutRoots[project.id]) }

        return AgentContextGravityInput(
            newAgentFrame: AgentWorldRect(newTileFrame),
            newAgentCheckoutRoot: newAgentCheckoutRoot,
            newAgentCheckoutRootsByProjectId: safeCheckoutRoots,
            projectZones: zoneSignals,
            managedAgents: agentSignals,
            documents: documentSignals,
            workspaceDefault: workspaceDefault,
            workspaceId: workspaceId.uuidString)
    }

    private static func home(for project: ProjectEntry, checkoutRoot: URL?) -> AgentHome {
        let root = URL(fileURLWithPath: project.rootPath, isDirectory: true)
        return AgentHome(projectId: project.id, projectRoot: root, checkoutRoot: checkoutRoot ?? root)
    }
}

private extension AgentWorldRect {
    init(_ frame: TileFrame) {
        self.init(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
    }

    init(_ zone: ZonePlacement) {
        self.init(x: zone.origin.x, y: zone.origin.y, width: zone.size.width, height: zone.size.height)
    }
}
