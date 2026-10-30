import AppKit
import CryptoKit
import ContinuumRevivedCore
import Foundation

/// Reads the same model boundary as persistence, without writing any source or
/// acquiring a project/runtime. A selected layout is never a collection of views.
@MainActor
enum SharedAreaInventory {
    typealias Publication = SharedAreaPublication
    typealias Key = Publication.SourceKey

    enum Reason: String, Sendable {
        case sceneUnavailable, projectUnavailable, projectNotInWorkspace
        case ambientUnsupported, noteUnavailable, agentUnavailable
    }
    struct Issue: Equatable, Sendable {
        let projectID: UUID?
        let tileID: UUID?
        let label: String
        let reason: Reason
    }
    enum Failure: Error, LocalizedError {
        case incompleteCoverage([Issue])
        case unavailableContent(Key)
        var errorDescription: String? {
            switch self {
            case .incompleteCoverage(let issues):
                return "Sharing cannot read the complete selection: " + issues.map { "\($0.label) (\($0.reason.rawValue))" }.joined(separator: ", ")
            case .unavailableContent: return "The selected note content is unavailable. Review the selection again."
            }
        }
    }
    /// `artifactWithUntracked` is the explicit opt-in that adds untracked
    /// files to a working-tree diff snapshot; plain `artifact` never does.
    enum Mode: Sendable { case agentObservation, agreement, discussion, artifact, artifactWithUntracked, omit }

    struct Snapshot {
        let inventory: Publication.Inventory
        /// Local review content only. Neither Snapshot nor these keys encode.
        let noteTexts: [Key: String]
        let issues: [Issue]
        /// Diff/file tiles resolved to what they would capture. Resolving runs
        /// no git; capture happens off main in the review coordinator.
        var artifactSources: [Key: SharedArtifactSource] = [:]

        /// Rebuild the selected content from this freshly read owner snapshot,
        /// rather than reusing text captured before the confirmation gesture.
        func choices(for modes: [Key: Mode], drafts: [Key: SharedArtifactProducer.Draft] = [:]) throws -> [Publication.Choice] {
            try modes.map { key, mode in
                let content: Publication.Content
                switch mode {
                case .agentObservation: content = .agentObservation
                case .artifact, .artifactWithUntracked: content = .artifact(digest: drafts[key]?.contentDigest ?? "")
                case .omit: content = .omit
                case .agreement, .discussion:
                    guard let text = noteTexts[key] else { throw Failure.unavailableContent(key) }
                    content = switch mode {
                    case .agreement: .agreement(text: text)
                    default: .discussion(text: text)
                    }
                }
                return .init(source: key, content: content)
            }.sorted {
                if $0.source.projectID != $1.source.projectID { return $0.source.projectID.uuidString < $1.source.projectID.uuidString }
                return $0.source.tileID.uuidString < $1.source.tileID.uuidString
            }
        }
    }

    static func capture(runtime: WorkspaceRuntime, supervisor: AgentSupervisor,
                        selection: Publication.Selection) throws -> Snapshot {
        guard let canvas = runtime.collaborationCanvas else {
            throw Failure.incompleteCoverage([.init(projectID: nil, tileID: nil, label: "Workspace", reason: .sceneUnavailable)])
        }
        let zones = runtime.collaborationZones
        let projectZones = zones.filter { $0.projectId != nil }
        let allProjectIDs = Set(projectZones.compactMap(\.projectId))
        let requiredProjects: Set<UUID>
        let coverage: Publication.Coverage
        switch selection {
        case .workspace, .enclosed:
            requiredProjects = allProjectIDs; coverage = .completeWorkspace
        case .zone(let zoneID):
            guard let zone = zones.first(where: { $0.zoneId == zoneID }), let projectID = zone.projectId else {
                throw Failure.incompleteCoverage([.init(projectID: nil, tileID: nil,
                    label: zones.first(where: { $0.zoneId == zoneID })?.name ?? "Selected zone", reason: .ambientUnsupported)])
            }
            requiredProjects = [projectID]; coverage = .zones([zoneID])
        case .tiles(let keys):
            requiredProjects = Set(keys.map(\.projectID)); coverage = .partial
        }
        var failures: [Issue] = []
        if case .completeWorkspace = coverage {
            // Ambient tiles have no project owner. Do not fabricate one to make
            // the capture look complete or silently leave the tiles out.
            failures += runtime.document.ambientTiles.map {
                .init(projectID: nil, tileID: $0.id, label: $0.title.isEmpty ? "Ambient tile" : $0.title, reason: .ambientUnsupported)
            }
        }
        var sources: [Publication.SourceTile] = [], noteTexts: [Key: String] = [:], issues: [Issue] = []
        var artifactSources: [Key: SharedArtifactSource] = [:]
        for projectID in requiredProjects.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard allProjectIDs.contains(projectID), (try? runtime.collaborationOwnsProject(projectID)) == true else {
                failures.append(.init(projectID: projectID, tileID: nil, label: "Selected project", reason: .projectNotInWorkspace))
                continue
            }
            guard let controller = runtime.controller(for: projectID), controller.canvasUnavailable == nil else {
                let label = projectZones.first(where: { $0.projectId == projectID })?.name ?? "Project"
                failures.append(.init(projectID: projectID, tileID: nil, label: label, reason: .projectUnavailable))
                continue
            }
            let persisted: CanvasState
            do {
                persisted = try controller.projectStore.tryLoadCanvas()
                    ?? .init(viewport: .init(x: 0, y: 0, zoom: 1), tiles: [], groups: [], lastActiveTileId: nil)
            } catch {
                failures.append(.init(projectID: projectID, tileID: nil, label: controller.project.name, reason: .projectUnavailable))
                continue
            }
            let world: CanvasState
            if canvas.isFlatCompatibilitySceneActive && canvas.installedZoneIds(forProjectId: projectID).isEmpty {
                // A flat boot scene has no reliable ownership for another
                // project's live tiles. Refuse rather than copy its flat list.
                guard runtime.activeController?.project.id == projectID else {
                    failures.append(.init(projectID: projectID, tileID: nil, label: controller.project.name, reason: .sceneUnavailable))
                    continue
                }
                world = canvas.canvasStateForPersistence(projectId: projectID, base: persisted, persistedTiles: persisted.tiles)
            } else {
                world = canvas.canvasStateForPersistence(projectId: projectID, base: persisted, persistedTiles: persisted.tiles)
            }
            let ownedZones = projectZones.filter { $0.projectId == projectID }
            let home = ownedZones.contains(where: { $0.zoneId == runtime.document.lastActiveZoneId })
                ? runtime.document.lastActiveZoneId! : ownedZones[0].zoneId
            // Unlike WorkspaceRuntime.membership, the pure resolver never
            // persists its repaired stamps. WORLD frames remain unchanged.
            let resolved = CanvasEngine.resolveZoneMembership(tiles: world.tiles, projectZones: ownedZones,
                documentZoneIds: Set(runtime.document.zones.map(\.zoneId)), homeZoneId: home)
            let tiles = resolved.byZone.values.flatMap { $0 }
            for tile in tiles {
                let key = Key(projectID: projectID, tileID: tile.id)
                let agentID: AgentID?
                if tile.kind == .managedAgent {
                    let matches = supervisor.records.values.filter { $0.tileId == tile.id && $0.projectId == projectID }
                    agentID = matches.count == 1 ? matches.first?.id : nil
                    if agentID == nil { issues.append(.init(projectID: projectID, tileID: tile.id, label: tile.title, reason: .agentUnavailable)) }
                } else { agentID = nil }
                var generation: String?
                if tile.kind == .note {
                    let text: String?
                    if let noteID = tile.metadata.noteId, let live = controller.noteViews[noteID], live.noteId == noteID {
                        text = live.textView.string
                    } else if let noteID = tile.metadata.noteId {
                        text = try? controller.projectStore.loadNoteBody(id: noteID)
                    } else { text = nil }
                    if let text {
                        noteTexts[key] = text
                        generation = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
                    } else { issues.append(.init(projectID: projectID, tileID: tile.id, label: tile.title, reason: .noteUnavailable)) }
                }
                if let source = SharedArtifactSource.resolve(tile: tile, projectRoot: URL(fileURLWithPath: controller.project.rootPath, isDirectory: true)) {
                    artifactSources[key] = source
                }
                sources.append(.init(projectID: projectID, tile: tile, agentID: agentID, contentRevision: generation))
            }
        }
        guard failures.isEmpty else { throw Failure.incompleteCoverage(failures) }
        return Snapshot(inventory: .init(workspaceID: runtime.workspaceId, coverage: coverage, sources: sources),
            noteTexts: noteTexts, issues: issues, artifactSources: artifactSources)
    }
}
