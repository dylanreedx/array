import ContinuumRevivedCore
import Foundation

// Confidence pass, sidebar stream (`.plans/70-confidence-pass.md`, S4).
//
// THE SIDEBAR'S INPUTS, READ FROM DISK ON STRUCTURAL REBUILDS ONLY.
//
// Before this, every push — one per streamed agent event, debounced — re-read the
// registry, every workspace document and every project's `canvas.json` on the
// main thread, twice (once for the inbox rows, once for the hidden outline tree),
// plus `listSessions()` per project. And the active project's tiles came from
// `canvasView.canvasState`, the flat boot model, which after the first `setZones`
// describes the DEPARTED project: the sidebar listed a frozen snapshot of what
// the canvas held at launch.
//
// Now: `load` reads disk once per structural rebuild (boot, workspace switch, tile
// added or removed, app activation — the callers that already rebuilt), and
// `overlaying` lays the live, in-memory state on top for every push: the mounted
// workspace's document, and every project whose tiles live in installed zone
// layers, through the same `canvasStateForPersistence` merge the save path uses.
struct SidebarModelInputs {
    var registry: Registry
    var documents: [UUID: WorkspaceDocument]
    var projectCanvases: [UUID: CanvasState]
    /// Projects whose tiles are UNKNOWN rather than absent: the root is gone, or
    /// its `canvas.json` exists and could not be read. A record bound to a tile in
    /// one of these must not be derived closed — one unreadable root is not
    /// evidence that its agents' tiles were deleted.
    var unknownProjectIds: Set<UUID>

    static func load(registryStore: RegistryStore?) -> SidebarModelInputs {
        let registry = (try? registryStore?.loadOrEmpty()) ?? Registry.empty()
        var documents: [UUID: WorkspaceDocument] = [:]
        if let registryStore {
            let appSupport = registryStore.registryFile.deletingLastPathComponent()
            for workspace in registry.workspaces {
                let store = WorkspaceStore(workspaceId: workspace.id, applicationSupportDirectory: appSupport)
                if let document = try? store.tryLoad() { documents[workspace.id] = document }
            }
        }
        var canvases: [UUID: CanvasState] = [:]
        var unknown: Set<UUID> = []
        for project in registry.projects {
            let root = URL(fileURLWithPath: project.rootPath, isDirectory: true)
            guard !project.missing, FileManager.default.fileExists(atPath: root.path) else {
                unknown.insert(project.id)
                continue
            }
            do {
                if let canvas = try ProjectStore(projectRoot: root).tryLoadCanvas() {
                    canvases[project.id] = canvas
                }
            } catch {
                unknown.insert(project.id)
            }
        }
        return SidebarModelInputs(
            registry: registry, documents: documents,
            projectCanvases: canvases, unknownProjectIds: unknown)
    }

    /// The live state on top of what disk said at the last structural rebuild.
    @MainActor
    func overlaying(
        currentWorkspaceId: UUID?,
        currentDocument: WorkspaceDocument?,
        activeProjectId: UUID?,
        canvas: CanvasNSView?
    ) -> SidebarModelInputs {
        var result = self
        if let currentWorkspaceId, let currentDocument {
            result.documents[currentWorkspaceId] = currentDocument
        }
        guard let canvas else { return result }
        for project in registry.projects {
            let installed = !canvas.installedZoneIds(forProjectId: project.id).isEmpty
            let flatOwner = canvas.isFlatCompatibilitySceneActive && project.id == activeProjectId
            guard installed || flatOwner else { continue }
            let persisted = projectCanvases[project.id]
            let base = persisted ?? CanvasState(
                viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
                tiles: [], groups: [], lastActiveTileId: nil)
            result.projectCanvases[project.id] = canvas.canvasStateForPersistence(
                projectId: project.id, base: base, persistedTiles: persisted?.tiles ?? [])
            result.unknownProjectIds.remove(project.id)
        }
        return result
    }

    /// Every tile the sidebar can place — a tile some workspace document holds,
    /// through the same fold the outline draws — plus every tile installed on the
    /// live canvas, which covers a tile spawned since the last structural rebuild.
    @MainActor
    func reachableTileIds(canvas: CanvasNSView?) -> Set<UUID> {
        let tree = SidebarTreeBuilder.build(
            registry: registry, documents: documents, projectCanvases: projectCanvases)
        var ids = Set(tree.workspaces.flatMap(\.zones).flatMap(\.tiles).map(\.tileId))
        if let canvas { ids.formUnion(canvas.allWorkspaceTiles().map(\.id)) }
        return ids
    }

    /// Whether an agent's recorded tile is a binding nothing can find. False when
    /// the agent has no tile (headless is not closed), and false when its
    /// project's tiles are unknown.
    func tileIsUnreachable(_ record: AgentRecord, reachable: Set<UUID>) -> Bool {
        guard let tileId = record.tileId, !reachable.contains(tileId) else { return false }
        if let projectId = record.projectId, unknownProjectIds.contains(projectId) { return false }
        return true
    }
}
