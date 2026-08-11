import Foundation

/// Why a newly created managed agent received its initial Home.
///
/// This is host-local decision evidence. It deliberately carries no path and is
/// not persisted or synced; the resolved `AgentHome` becomes ordinary record
/// state through `AgentSupervisor.spawn`.
public enum ManagedAgentSpawnHomeProvenance: Equatable, Sendable {
    case explicitAction
    case selectedAgent
    case contextGravity
    case activeProject
}

public struct ManagedAgentSpawnHomeResolution: Equatable, Sendable {
    public let home: AgentHome
    public let provenance: ManagedAgentSpawnHomeProvenance

    public init(home: AgentHome, provenance: ManagedAgentSpawnHomeProvenance) {
        self.home = home
        self.provenance = provenance
    }
}

/// Pure precedence for a managed agent's initial Home.
///
/// Callers validate filesystem-backed candidates before supplying them. Keeping
/// that policy at the App boundary prevents Core from gaining ambient filesystem
/// authority and makes the absence of a process-cwd fallback explicit.
public enum ManagedAgentSpawnHomeResolver: Sendable {
    public static func resolve(
        explicit: AgentHome? = nil,
        selectedAgent: AgentHome? = nil,
        contextGravity: AgentScopeBinding? = nil,
        activeProject: AgentHome? = nil
    ) -> ManagedAgentSpawnHomeResolution? {
        if let explicit {
            return ManagedAgentSpawnHomeResolution(home: explicit, provenance: .explicitAction)
        }
        if let selectedAgent {
            return ManagedAgentSpawnHomeResolution(home: selectedAgent, provenance: .selectedAgent)
        }
        if let contextGravity {
            return ManagedAgentSpawnHomeResolution(home: contextGravity.home, provenance: .contextGravity)
        }
        if let activeProject {
            return ManagedAgentSpawnHomeResolution(home: activeProject, provenance: .activeProject)
        }
        return nil
    }
}
