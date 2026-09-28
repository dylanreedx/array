import ContinuumRevivedCore
import Foundation

/// A bound zone's project as an already-loaded registry resolves it. Resolved
/// by whoever holds the registry (the runtime, the launch builder, the Home
/// picker) and handed to the canvas, so drawing a header never reads disk.
enum ZoneProjectResolution: Equatable {
    case registered(ProjectEntry)
    /// The zone names a project the registry has no entry for.
    case registryMiss

    init(projectId: UUID, in registry: Registry) {
        self = registry.projects.first(where: { $0.id == projectId }).map(Self.registered) ?? .registryMiss
    }
}

/// What a zone's header says. A pure function of its inputs, and the only
/// place a zone's title or Home label is made (`.plans/67-target-architecture`
/// §3.7): nothing stores a label string, so nothing can hold a stale one.
struct ZonePresentation: Equatable {
    var title: String
    /// Nil only when the canvas was never told how this zone's project
    /// resolves (isolated fixtures); production always resolves it.
    var homeLabel: String?
    var isProvisional: Bool
    var agentStatusRollup: CanvasNSView.AgentStatusRollup
    var qaVerdict: QARunManifestSnapshot?

    /// - Parameters:
    ///   - project: how the placement's project resolved; nil when unknown.
    ///     Ignored for an unbound placement (`projectId == nil`).
    ///   - fallbackTitle: a seed's title, used only for an unnamed placement
    ///     whose project resolves to no name.
    static func make(
        placement: ZonePlacement,
        project: ZoneProjectResolution?,
        isProvisional: Bool = false,
        rollup: CanvasNSView.AgentStatusRollup = .empty,
        qaVerdict: QARunManifestSnapshot? = nil,
        fallbackTitle: String = ""
    ) -> ZonePresentation {
        let registered: ProjectEntry?
        if placement.projectId != nil, case let .registered(entry)? = project { registered = entry } else { registered = nil }

        // A saved custom name always wins; a project name only fills an unnamed one.
        let title: String
        if !placement.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            title = placement.name
        } else if let registered {
            title = registered.name
        } else if !fallbackTitle.isEmpty {
            title = fallbackTitle
        } else {
            title = placement.projectId == nil ? "Group" : "Zone"
        }

        let homeLabel: String?
        if isProvisional {
            homeLabel = "Choose a project to finish"
        } else if placement.projectId == nil {
            homeLabel = "Needs Project"
        } else {
            switch project {
            case let .registered(entry)?:
                let home = "\(entry.name) / \(placement.homeRelativePath ?? "Project Root")"
                homeLabel = entry.missing ? "\(home) · Unavailable" : home
            case .registryMiss?:
                homeLabel = "Project Not Found"
            case nil:
                homeLabel = nil
            }
        }
        return ZonePresentation(
            title: title, homeLabel: homeLabel, isProvisional: isProvisional,
            agentStatusRollup: rollup, qaVerdict: qaVerdict)
    }
}
