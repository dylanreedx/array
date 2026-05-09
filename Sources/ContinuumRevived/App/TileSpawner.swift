import AppKit
import ContinuumRevivedCore
import Foundation

@MainActor
final class TileSpawner {
    enum Outcome {
        case spawned(GhosttyTerminalRuntime)
        case unknownProfile(id: String)
        case missingCommand(executable: String)
        case notConfigured(profileId: String)
        case failure(Error)
    }

    enum SpawnError: Error {
        case canvasUnavailable
    }

    struct AnnotatedProfile {
        let spec: LaunchProfileSpec
        let resolution: LaunchProfileResolution
    }

    weak var canvasView: CanvasNSView?
    private let ghostty: GhosttyRuntimeContext
    private let projectStore: ProjectStore
    private let project: Project
    private let registry: LaunchProfileRegistry
    private let detector: ToolDetector

    init(
        canvasView: CanvasNSView,
        ghostty: GhosttyRuntimeContext,
        projectStore: ProjectStore,
        project: Project,
        registry: LaunchProfileRegistry = LaunchProfileRegistry(),
        detector: ToolDetector = .live
    ) {
        self.canvasView = canvasView
        self.ghostty = ghostty
        self.projectStore = projectStore
        self.project = project
        self.registry = registry
        self.detector = detector
    }

    func annotatedProfiles() -> [AnnotatedProfile] {
        registry.all().map { spec in
            AnnotatedProfile(
                spec: spec,
                resolution: registry.resolve(
                    spec,
                    in: project.rootPath,
                    environment: ProcessInfo.processInfo.environment,
                    detector: detector
                )
            )
        }
    }

    func spawnTerminal(profileId: String, at worldPoint: CGPoint? = nil) -> Outcome {
        guard let canvasView else { return .failure(SpawnError.canvasUnavailable) }
        guard let spec = registry.spec(for: profileId) else {
            return .unknownProfile(id: profileId)
        }
        let resolution = registry.resolve(
            spec,
            in: project.rootPath,
            environment: ProcessInfo.processInfo.environment,
            detector: detector
        )
        let profile: LaunchProfile
        switch resolution {
        case let .found(p): profile = p
        case let .missing(name): return .missingCommand(executable: name)
        case let .notConfigured(id): return .notConfigured(profileId: id)
        }

        let frame = makePlacement(
            worldPoint: worldPoint,
            size: CanvasEngine.defaultFrame(for: .terminal),
            in: canvasView
        )
        let nextZ = (canvasView.canvasState.tiles.map(\.zIndex).max() ?? 0) + 1
        var tile = Tile(
            id: UUID(),
            kind: .terminal,
            title: profile.title,
            frame: frame,
            zIndex: nextZ,
            runtimeRef: nil,
            metadata: TileMetadata(launchProfileId: spec.id, projectRelativeCwd: ".")
        )
        let runtime = GhosttyTerminalRuntime(
            id: UUID(),
            tileId: tile.id,
            title: profile.title,
            launchProfile: profile,
            ghostty: ghostty
        )
        tile.runtimeRef = RuntimeRef(kind: .terminalSession, id: runtime.id)

        let view = TerminalTileNSView(tile: tile, runtime: runtime)
        canvasView.install(tileView: view, for: tile)

        let now = Date()
        let descriptor = TerminalSessionDescriptor(
            id: runtime.id,
            tileId: tile.id,
            launchProfileId: spec.id,
            command: profile.command,
            args: profile.arguments,
            cwd: profile.cwd,
            env: [:],
            title: profile.title,
            createdAt: now,
            lastStartedAt: now,
            lastExit: nil
        )
        do {
            try projectStore.saveSession(descriptor)
            try projectStore.saveCanvas(canvasView.canvasState)
        } catch {
            return .failure(error)
        }
        return .spawned(runtime)
    }

    enum RestartOutcome {
        case restarted(GhosttyTerminalRuntime)
        case unknownProfile(id: String)
        case missingCommand(executable: String)
        case notConfigured(profileId: String)
        case tileNotFound
        case failure(Error)
    }

    /// Re-resolve the existing tile's profile and replace its view with a fresh
    /// terminal runtime. Reuses tile id, frame, and z-index so the canvas slot
    /// doesn't shift; updates `runtimeRef`, title, and the persisted descriptor.
    func restartTerminalTile(tileId: UUID) -> RestartOutcome {
        guard let canvasView else { return .failure(SpawnError.canvasUnavailable) }
        guard let existing = canvasView.canvasState.tiles.first(where: { $0.id == tileId }) else {
            return .tileNotFound
        }
        let profileId = existing.metadata.launchProfileId ?? "shell"
        guard let spec = registry.spec(for: profileId) else {
            return .unknownProfile(id: profileId)
        }
        let resolution = registry.resolve(
            spec,
            in: project.rootPath,
            environment: ProcessInfo.processInfo.environment,
            detector: detector
        )
        let profile: LaunchProfile
        switch resolution {
        case let .found(p): profile = p
        case let .missing(name): return .missingCommand(executable: name)
        case let .notConfigured(id): return .notConfigured(profileId: id)
        }

        let runtime = GhosttyTerminalRuntime(
            id: UUID(),
            tileId: existing.id,
            title: profile.title,
            launchProfile: profile,
            ghostty: ghostty
        )
        var tile = existing
        tile.runtimeRef = RuntimeRef(kind: .terminalSession, id: runtime.id)
        tile.title = profile.title
        let view = TerminalTileNSView(tile: tile, runtime: runtime)
        canvasView.install(tileView: view, for: tile)

        let now = Date()
        let descriptor = TerminalSessionDescriptor(
            id: runtime.id,
            tileId: tile.id,
            launchProfileId: spec.id,
            command: profile.command,
            args: profile.arguments,
            cwd: profile.cwd,
            env: [:],
            title: profile.title,
            createdAt: now,
            lastStartedAt: now,
            lastExit: nil
        )
        do {
            try projectStore.saveSession(descriptor)
            try projectStore.saveCanvas(canvasView.canvasState)
        } catch {
            return .failure(error)
        }
        return .restarted(runtime)
    }

    @discardableResult
    func spawnBrowserDefault(at worldPoint: CGPoint? = nil) -> Result<Tile, Error> {
        guard let canvasView else { return .failure(SpawnError.canvasUnavailable) }
        let frame = makePlacement(
            worldPoint: worldPoint,
            size: CanvasEngine.defaultFrame(for: .browser),
            in: canvasView
        )
        let nextZ = (canvasView.canvasState.tiles.map(\.zIndex).max() ?? 0) + 1
        let tile = Tile(
            id: UUID(),
            kind: .browser,
            title: "Local browser",
            frame: frame,
            zIndex: nextZ,
            runtimeRef: nil,
            metadata: TileMetadata(url: "http://localhost:3000")
        )
        let view = DescriptorTileNSView(tile: tile)
        canvasView.install(tileView: view, for: tile)
        do {
            try projectStore.saveCanvas(canvasView.canvasState)
        } catch {
            return .failure(error)
        }
        return .success(tile)
    }

    private func makePlacement(worldPoint: CGPoint?, size: CGSize, in canvasView: CanvasNSView) -> TileFrame {
        let cascadeStep: Double = 32
        let world: CGPoint
        if let worldPoint {
            world = worldPoint
        } else {
            let centerScreen = CGPoint(x: canvasView.bounds.midX, y: canvasView.bounds.midY)
            world = CanvasEngine.screenToWorld(centerScreen, viewport: canvasView.viewport)
        }
        // Cascade per existing tile so freshly spawned tiles do not stack.
        let count = Double(canvasView.canvasState.tiles.count)
        let offset = count * cascadeStep
        return TileFrame(
            x: Double(world.x) - Double(size.width) / 2 + offset,
            y: Double(world.y) - Double(size.height) / 2 + offset,
            width: Double(size.width),
            height: Double(size.height)
        )
    }
}
