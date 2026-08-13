import AppKit
import ContinuumRevivedCore
import ContinuumRevivedFileTree
import Foundation
import GhosttyKit
import WebKit

private final class TmuxSyncBox: @unchecked Sendable {
    var value: Any?
    var error: Error?
}

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
        case invalidPaneId(String)
    }

    struct AnnotatedProfile {
        let spec: LaunchProfileSpec
        let resolution: LaunchProfileResolution
    }

    private enum FreshTerminalProfileResolution {
        case resolved(spec: LaunchProfileSpec, profile: LaunchProfile, projectRoot: String)
        case failed(Outcome)
    }

    private struct TmuxWrappedProfile {
        let profile: LaunchProfile
        let windowTarget: String?
        let createdWindow: Bool
        let viewSessionExisted: Bool
    }

    weak var canvasView: CanvasNSView?
    private let ghostty: GhosttyRuntimeContext?
    private let browserEngine: BrowserEngineContext
    private let projectStore: any ProjectStoring
    private let managedSessionStore: ManagedAgentSessionStore
    private let project: Project
    private let registry: LaunchProfileRegistry
    private let detector: ToolDetector
    private let defaults: UserDefaults
    private let tmuxPathResolver: (UserDefaults) -> String?
    private let environmentProvider: () -> [String: String]
    private let tmuxControlFactory: @Sendable (String, RemoteReach, UserDefaults) -> any TmuxControl
    private var browserProfiles: [BrowserProfile]

    /// Dynamic source used by browser tile profile menus after registry edits.
    var browserProfileMenuProvider: (() -> [BrowserProfile])?

    /// Optional zone/project context for terminal launches. When present, agent
    /// descriptors and launch-profile resolution use this root rather than the
    /// process-wide active project root, allowing worktree project entries to
    /// spawn agents into their own checkout.
    var terminalProjectContextProvider: (() -> ProjectEntry?)?
    var terminalSessionTargetProvider: (() -> TerminalSessionTarget?)?
    var terminalFocusedPaneTargetProvider: (() -> String?)?
    var focusedTerminalCwdProvider: (() -> String?)?
    var browserProfileSwitchHandler: ((UUID, UUID) -> Void)?
    var browserProfileCreateHandler: ((UUID) -> Void)?
    var browserProfileRenameHandler: ((UUID, UUID) -> Void)?
    var browserProfileDeleteHandler: ((UUID, UUID) -> Void)?

    /// Called right after a new terminal session descriptor is persisted, so
    /// the owning `ZoneRuntimeController` can hand it to its
    /// `SessionObserver` (docs/38-tickets/40-session-observer.md).
    var terminalSpawnedHandler: ((TerminalSessionDescriptor) -> Void)?

    /// Called after every browser-tile state change (URL, title, loading, error)
    /// so the AppDelegate can schedule a debounced BrowserState save.
    var browserPersistenceHandler: (() -> Void)?

    /// Called after every note text change so the AppDelegate can schedule a
    /// debounced note body + index save.
    var notePersistenceHandler: (() -> Void)?

    /// Called after file-tree expansion, selection, or search changes so the
    /// AppDelegate can schedule a debounced FileTreeState save.
    var fileTreePersistenceHandler: (() -> Void)?

    /// Lets runtime-owned key paths route reserved shortcuts through the app's
    /// FocusBroker instead of consuming them inside terminal/browser content.
    var reservedShortcutHandler: ((NSEvent) -> Bool)?
    private var lastSpawnedCwd: String?

    init(
        canvasView: CanvasNSView,
        ghostty: GhosttyRuntimeContext?,
        browserEngine: BrowserEngineContext,
        projectStore: any ProjectStoring,
        project: Project,
        registry: LaunchProfileRegistry = LaunchProfileRegistry(),
        detector: ToolDetector = .live,
        defaults: UserDefaults = .standard,
        tmuxPathResolver: @escaping (UserDefaults) -> String? = { TmuxLocator.resolve(defaults: $0) },
        tmuxControlFactory: @escaping @Sendable (String) -> any TmuxControl = {
            ProcessTmuxControl(tmuxPath: $0)
        },
        tmuxOwnerControlFactory: (@Sendable (String, RemoteReach, UserDefaults) -> any TmuxControl)? = nil,
        // Go-live Phase 4: .tool resolution consults the augmented PATH
        // (well-known install dirs + login-shell upgrade), not the thin GUI
        // process PATH. Injectable so checks can pin resolution behavior.
        environmentProvider: @escaping () -> [String: String] = { ToolEnvironment.shared.environment() },
        browserProfiles: [BrowserProfile] = [BrowserProfile.builtInDefault()],
        managedSessionStore: ManagedAgentSessionStore? = nil
    ) {
        self.canvasView = canvasView
        self.ghostty = ghostty
        self.browserEngine = browserEngine
        self.projectStore = projectStore
        self.managedSessionStore = managedSessionStore ?? ManagedAgentSessionStore(projectRoot: URL(fileURLWithPath: project.rootPath, isDirectory: true))
        self.project = project
        self.registry = registry
        self.detector = detector
        self.defaults = defaults
        self.tmuxPathResolver = tmuxPathResolver
        self.tmuxControlFactory = tmuxOwnerControlFactory ?? { tmuxPath, reach, defaults in
            switch reach {
            case .localhost:
                return tmuxControlFactory(tmuxPath)
            case .sshForward, .tailscale, .tunnel:
                return ProcessTmuxControl(tmuxPath: tmuxPath, reach: reach, defaults: defaults)
            }
        }
        self.environmentProvider = environmentProvider
        self.browserProfiles = browserProfiles
        canvasView.onFileURLDrop = { [weak self] path, worldPoint in
            guard let self else { return }
            if let fileOpenHandler {
                fileOpenHandler(path, worldPoint)
            } else {
                _ = spawnFile(path: path, at: worldPoint)
            }
        }
    }

    func annotatedProfiles() -> [AnnotatedProfile] {
        registry.all().map { spec in
            AnnotatedProfile(
                spec: spec,
                resolution: registry.resolve(
                    spec,
                    in: project.rootPath,
                    environment: environmentProvider(),
                    detector: detector
                )
            )
        }
    }

    func spawnTerminal(profileId: String, at worldPoint: CGPoint? = nil, allowTmuxPersistence: Bool = true) -> Outcome {
        let spec: LaunchProfileSpec
        let profile: LaunchProfile
        let projectRoot: String
        switch resolvedFreshTerminalProfile(profileId: profileId) {
        case let .resolved(resolvedSpec, resolvedProfile, resolvedProjectRoot):
            spec = resolvedSpec
            profile = resolvedProfile
            projectRoot = resolvedProjectRoot
        case let .failed(outcome):
            return outcome
        }
        let now = Date()
        return spawnTerminal(
            profile: profile,
            launchProfileId: spec.id,
            agentDescriptor: agentDescriptor(for: spec, projectRoot: projectRoot, at: now),
            createdAt: now,
            at: worldPoint,
            allowTmuxPersistence: allowTmuxPersistence
        )
    }

    private func resolvedFreshTerminalProfile(profileId: String) -> FreshTerminalProfileResolution {
        guard let spec = registry.spec(for: profileId) else {
            return .failed(.unknownProfile(id: profileId))
        }
        let projectRoot = terminalProjectRoot()
        let resolution = registry.resolve(
            spec,
            in: projectRoot,
            environment: environmentProvider(),
            detector: detector
        )
        let profile: LaunchProfile
        switch resolution {
        case let .found(p): profile = p
        case let .missing(name): return .failed(.missingCommand(executable: name))
        case let .notConfigured(id): return .failed(.notConfigured(profileId: id))
        }
        let inheritedCwd = resolvedSpawnCwd(projectRoot: projectRoot)
        let effectiveProfile = LaunchProfile(
            command: profile.command,
            arguments: profile.arguments,
            cwd: inheritedCwd,
            title: profile.title
        )
        return .resolved(spec: spec, profile: effectiveProfile, projectRoot: projectRoot)
    }

    func spawnHarnessRoleRun(role: HarnessRole, prompt: String, at worldPoint: CGPoint? = nil) -> Outcome {
        let projectRoot = terminalProjectRoot()
        let now = Date()
        let runId = HarnessRoleRunBuilder.makeRunId(roleId: role.id, now: now, suffix: UUID().uuidString)
        let profile = HarnessRoleRunBuilder.buildLaunchProfile(role: role, prompt: prompt, projectRoot: projectRoot, runId: runId)
        return spawnTerminal(
            profile: profile,
            launchProfileId: "harness:\(role.id)",
            agentDescriptor: AgentDescriptor.configuring(agentKind: .pi, worktreePath: projectRoot, now: now, runId: runId),
            createdAt: now,
            at: worldPoint,
            allowTmuxPersistence: false
        )
    }

    private func spawnTerminal(
        profile: LaunchProfile,
        launchProfileId: String,
        agentDescriptor: AgentDescriptor?,
        createdAt now: Date,
        at worldPoint: CGPoint?,
        allowTmuxPersistence: Bool
    ) -> Outcome {
        guard let canvasView else { return .failure(SpawnError.canvasUnavailable) }
        guard let ghostty else { return .failure(SpawnError.canvasUnavailable) }
        let frame = makePlacement(
            worldPoint: worldPoint,
            size: CanvasEngine.defaultFrame(for: .terminal),
            in: canvasView
        )
        let nextZ = CanvasEngine.zPositionAbove(canvasView.canvasState.tiles)
        var tile = Tile(
            id: UUID(),
            kind: .terminal,
            title: profile.title,
            frame: frame,
            zPosition: nextZ,
            runtimeRef: nil,
            metadata: TileMetadata(launchProfileId: launchProfileId, projectRelativeCwd: ".")
        )
        let sessionTarget = terminalSessionTargetProvider?()
        let wrappedProfile: TmuxWrappedProfile
        do {
            wrappedProfile = allowTmuxPersistence
                ? try tmuxWrappedProfileIfAvailable(profile, tileId: tile.id, target: sessionTarget)
                : TmuxWrappedProfile(profile: profile, windowTarget: nil, createdWindow: false, viewSessionExisted: false)
        } catch {
            return .failure(error)
        }
        let launchProfile = wrappedProfile.profile
        let runtime = GhosttyTerminalRuntime(
            id: UUID(),
            tileId: tile.id,
            title: profile.title,
            launchProfile: launchProfile,
            ghostty: ghostty,
            displayDefaults: defaults
        )
        runtime.reservedShortcutHandler = reservedShortcutHandler
        tile.runtimeRef = RuntimeRef(kind: .terminalSession, id: runtime.id)

        let view = TerminalTileNSView(tile: tile, runtime: runtime)
        view.agentStatus = agentDescriptor?.status
        canvasView.install(tileView: view, for: tile)

        let descriptor = TerminalSessionDescriptor(
            id: runtime.id,
            tileId: tile.id,
            launchProfileId: launchProfileId,
            command: launchProfile.command,
            args: launchProfile.arguments,
            cwd: launchProfile.cwd,
            env: [:],
            title: launchProfile.title,
            createdAt: now,
            lastStartedAt: now,
            lastExit: nil,
            agentDescriptor: agentDescriptor
        )
        do {
            try projectStore.saveSession(descriptor)
            writeInitialManagedSessionRecord(for: descriptor, windowTarget: wrappedProfile.windowTarget, at: now)
            try projectStore.saveCanvas(canvasView.canvasState)
            terminalSpawnedHandler?(descriptor)
        } catch {
            if let target = wrappedProfile.windowTarget {
                let reach = project.remoteEnvironment?.reach ?? .localhost
                if let tmuxPath = tmuxPathResolver(defaults) {
                    let control = tmuxControlFactory(tmuxPath, reach, defaults)
                    if wrappedProfile.createdWindow {
                        try? Self.runTmuxControlOperationSync {
                            try await control.killWindow(target: target)
                        }
                    }
                    if !wrappedProfile.viewSessionExisted, sessionTarget != nil {
                        let viewSessionName = TmuxSession.viewSessionName(tileId: tile.id)
                        try? Self.runTmuxControlOperationSync {
                            try await control.killSession(name: viewSessionName)
                        }
                    }
                }
            }
            return .failure(error)
        }
        return .spawned(runtime)
    }

    private func writeInitialManagedSessionRecord(for descriptor: TerminalSessionDescriptor, windowTarget: String?, at now: Date) {
        guard let windowTarget,
              let runtimePayload = try? ManagedAgentSessionRecord.makeRuntimePayload(windowTarget: windowTarget, cwd: descriptor.cwd)
        else { return }
        let record = ManagedAgentSessionRecord(
            tileId: descriptor.tileId,
            agentKind: descriptor.agentDescriptor?.agentKind ?? .shell,
            status: .running,
            lastSeenAt: now,
            runtimePayload: runtimePayload
        )
        try? managedSessionStore.upsert(record)
    }

    private func terminalProjectRoot() -> String {
        terminalProjectContextProvider?().map(\.rootPath) ?? project.rootPath
    }

    private func resolvedSpawnCwd(projectRoot: String) -> String {
        let resolved = resolveNewTileCwd(
            policy: NewTileCwdConfig.policy(defaults: defaults),
            focused: focusedTerminalCwdProvider?(),
            lastUsed: lastSpawnedCwd,
            projectRoot: projectRoot
        )
        lastSpawnedCwd = resolved
        return resolved
    }

    private func tmuxWrappedProfileIfAvailable(
        _ profile: LaunchProfile,
        tileId: UUID,
        target: TerminalSessionTarget?,
        existingWindowTarget: String? = nil
    ) throws -> TmuxWrappedProfile {
        guard TmuxPersistenceConfig.enabled(defaults: defaults),
              let tmuxPath = tmuxPathResolver(defaults) else {
            return TmuxWrappedProfile(profile: profile, windowTarget: nil, createdWindow: false, viewSessionExisted: false)
        }
        let reach = project.remoteEnvironment?.reach ?? .localhost
        guard let target else {
            return TmuxWrappedProfile(profile: TmuxSession.wrap(profile: profile, tileId: tileId, tmuxPath: tmuxPath, reach: reach, defaults: defaults), windowTarget: nil, createdWindow: false, viewSessionExisted: false)
        }
        if case .ambient = target,
           !TmuxPersistenceConfig.ambientPerWorkspaceEnabled(defaults: defaults) {
            return TmuxWrappedProfile(profile: TmuxSession.wrap(profile: profile, tileId: tileId, tmuxPath: tmuxPath, reach: reach, defaults: defaults), windowTarget: nil, createdWindow: false, viewSessionExisted: false)
        }
        let control = tmuxControlFactory(tmuxPath, reach, defaults)
        let sessionName: String
        switch target {
        case let .project(projectId):
            sessionName = TmuxSession.projectSessionName(projectId: projectId)
        case let .ambient(workspaceId):
            sessionName = TmuxSession.ambientSessionName(workspaceId: workspaceId)
        }
        let viewSessionName = TmuxSession.viewSessionName(tileId: tileId)
        let viewSessionExisted = try Self.runTmuxControlOperationSync {
            try await control.sessionExists(name: viewSessionName)
        }
        // Ticket 15: a restart/restore must not blindly create a new window when
        // the persisted descriptor's pane is still alive — that orphans the old
        // tmux window every relaunch. Re-bind to it instead.
        if let existingWindowTarget, try Self.runTmuxControlOperationSync({ try await control.isAlive(paneTarget: existingWindowTarget) }) {
            return TmuxWrappedProfile(
                profile: try TmuxSession.groupedViewProfile(
                    profile: profile,
                    tileId: tileId,
                    baseSessionName: sessionName,
                    windowTarget: existingWindowTarget,
                    tmuxPath: tmuxPath,
                    reach: reach,
                    defaults: defaults
                ),
                windowTarget: existingWindowTarget,
                createdWindow: false,
                viewSessionExisted: viewSessionExisted
            )
        }
        let innerCommand = Self.innerCommand(for: profile)
        let focusedPaneTarget: String? = {
            guard case .ambient = target else { return nil }
            return terminalFocusedPaneTargetProvider?()
        }()
        let paneTarget = try Self.runTmuxControlOperationSync {
            if case .project = target {
                do {
                    return try await control.newWindow(inSession: sessionName, cwd: profile.cwd, innerCommand: innerCommand)
                } catch {
                    return try await control.newSession(name: sessionName, cwd: profile.cwd, innerCommand: innerCommand)
                }
            } else if try await control.sessionExists(name: sessionName) {
                let cwd = try await Self.cwdForNewWindow(profileCwd: profile.cwd, control: control, focusedPaneTarget: focusedPaneTarget)
                return try await control.newWindow(inSession: sessionName, cwd: cwd, innerCommand: innerCommand)
            } else {
                return try await control.newSession(name: sessionName, cwd: profile.cwd, innerCommand: innerCommand)
            }
        }
        guard TmuxSession.isValidPaneId(paneTarget) else {
            if !paneTarget.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try? Self.runTmuxControlOperationSync {
                    try await control.killWindow(target: paneTarget)
                }
            }
            throw SpawnError.invalidPaneId(paneTarget)
        }
        return TmuxWrappedProfile(
            profile: try TmuxSession.groupedViewProfile(
                profile: profile,
                tileId: tileId,
                baseSessionName: sessionName,
                windowTarget: paneTarget,
                tmuxPath: tmuxPath,
                reach: reach,
                defaults: defaults
            ),
            windowTarget: paneTarget,
            createdWindow: true,
            viewSessionExisted: viewSessionExisted
        )
    }

    private nonisolated static func cwdForNewWindow(profileCwd: String, control: any TmuxControl, focusedPaneTarget: String?) async throws -> String {
        guard let focusedPaneTarget,
              !focusedPaneTarget.isEmpty
        else {
            return profileCwd
        }
        return try await control.paneCurrentPath(paneTarget: focusedPaneTarget)
    }

    private static func innerCommand(for profile: LaunchProfile) -> [String]? {
        guard !(profile.title == "Shell" && profile.arguments.isEmpty) else { return nil }
        return [profile.command] + profile.arguments
    }

    private static func runTmuxControlOperationSync<T>(_ operation: @escaping @Sendable () async throws -> T) throws -> T {
        let box = TmuxSyncBox()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                box.value = try await operation()
            } catch {
                box.error = error
            }
            semaphore.signal()
        }
        semaphore.wait()
        if let error = box.error { throw error }
        return box.value as! T
    }

    private func agentDescriptor(for spec: LaunchProfileSpec, projectRoot: String, at now: Date) -> AgentDescriptor? {
        Self.agentDescriptor(for: spec, projectRoot: projectRoot, at: now)
    }

    static func agentDescriptor(for spec: LaunchProfileSpec, projectRoot: String, at now: Date) -> AgentDescriptor? {
        guard let agentKind = spec.agentKind else { return nil }
        return AgentDescriptor.configuring(agentKind: agentKind, worktreePath: projectRoot, now: now)
    }

    static func makeTerminalSessionDescriptor(
        runtimeId: UUID,
        tileId: UUID,
        spec: LaunchProfileSpec,
        profile: LaunchProfile,
        projectRoot: String,
        now: Date
    ) -> TerminalSessionDescriptor {
        TerminalSessionDescriptor(
            id: runtimeId,
            tileId: tileId,
            launchProfileId: spec.id,
            command: profile.command,
            args: profile.arguments,
            cwd: profile.cwd,
            env: [:],
            title: profile.title,
            createdAt: now,
            lastStartedAt: now,
            lastExit: nil,
            agentDescriptor: agentDescriptor(for: spec, projectRoot: projectRoot, at: now)
        )
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
    /// Prefers the persisted descriptor's cwd (post-`cd` dir) over the resolved
    /// project-root cwd. Replays saved scrollback when enabled.
    func restartTerminalTile(tileId: UUID) -> RestartOutcome {
        guard let canvasView else { return .failure(SpawnError.canvasUnavailable) }
        guard let ghostty else { return .failure(SpawnError.canvasUnavailable) }
        guard let existing = canvasView.canvasState.tiles.first(where: { $0.id == tileId }) else {
            return .tileNotFound
        }
        let profileId = existing.metadata.launchProfileId ?? "shell"
        guard let spec = registry.spec(for: profileId) else {
            return .unknownProfile(id: profileId)
        }
        let projectRoot = terminalProjectRoot()
        let resolution = registry.resolve(
            spec,
            in: projectRoot,
            environment: environmentProvider(),
            detector: detector
        )
        let profile: LaunchProfile
        switch resolution {
        case let .found(p): profile = p
        case let .missing(name): return .missingCommand(executable: name)
        case let .notConfigured(id): return .notConfigured(profileId: id)
        }

        // Prefer the persisted descriptor's cwd (may be post-`cd`) over the
        // profile's project-root cwd. Fall back to profile.cwd when no persisted
        // descriptor exists yet (first launch, not a restore).
        let persistedDescriptor = try? projectStore.listSessions().first(where: { $0.tileId == tileId })
        let persistedRecord = try? managedSessionStore.load(tileId: tileId)
        let persistedWindowTarget = persistedRecord?.tmuxWindowTarget()
        let restoredCwd = persistedDescriptor?.cwd ?? profile.cwd

        let profileWithCwd = LaunchProfile(
            command: profile.command,
            arguments: profile.arguments,
            cwd: restoredCwd,
            title: profile.title
        )
        let wrappedProfile: TmuxWrappedProfile
        do {
            wrappedProfile = try tmuxWrappedProfileIfAvailable(
                profileWithCwd,
                tileId: existing.id,
                target: terminalSessionTargetProvider?(),
                existingWindowTarget: persistedWindowTarget
            )
        } catch {
            return .failure(error)
        }
        let launchProfile = wrappedProfile.profile

        let runtime = GhosttyTerminalRuntime(
            id: UUID(),
            tileId: existing.id,
            title: profile.title,
            launchProfile: launchProfile,
            ghostty: ghostty,
            displayDefaults: defaults
        )
        runtime.reservedShortcutHandler = reservedShortcutHandler
        var tile = existing
        tile.runtimeRef = RuntimeRef(kind: .terminalSession, id: runtime.id)
        tile.title = profile.title
        let now = Date()
        let agentDescriptor = agentDescriptor(for: spec, projectRoot: projectRoot, at: now)
        let view = TerminalTileNSView(tile: tile, runtime: runtime)
        view.agentStatus = agentDescriptor?.status
        canvasView.install(tileView: view, for: tile)

        let descriptor = TerminalSessionDescriptor(
            id: runtime.id,
            tileId: tile.id,
            launchProfileId: spec.id,
            command: launchProfile.command,
            args: launchProfile.arguments,
            cwd: launchProfile.cwd,
            env: [:],
            title: launchProfile.title,
            createdAt: now,
            lastStartedAt: now,
            lastExit: nil,
            agentDescriptor: agentDescriptor,
            scrollback: persistedDescriptor?.scrollback
        )
        do {
            try projectStore.saveSession(descriptor)
            // Concern (Codex, C4 wiring-check follow-up): the pre-restart
            // descriptor (e.g. the exited one `handleRuntimeExited` stamped
            // `lastExit` on and deliberately left on disk) is superseded the
            // instant a new descriptor is persisted for this tile — leaving
            // both around makes every `listSessions().first(where: {
            // $0.tileId == tileId })` lookup in this codebase (including the
            // SessionObserver `StatusWriter`) non-deterministic, since
            // `listSessions()` is directory-read order, not creation order.
            // Delete it now instead of waiting for the next boot's
            // `pruneExitedSessions` sweep, so at most one descriptor exists
            // per tileId immediately after a restart.
            if let staleId = persistedDescriptor?.id, staleId != descriptor.id {
                try? projectStore.deleteSession(id: staleId)
            }
            writeInitialManagedSessionRecord(for: descriptor, windowTarget: wrappedProfile.windowTarget ?? persistedWindowTarget, at: now)
            try projectStore.saveCanvas(canvasView.canvasState)
            terminalSpawnedHandler?(descriptor)
        } catch {
            if let target = wrappedProfile.windowTarget,
               let tmuxPath = tmuxPathResolver(defaults) {
                let reach = project.remoteEnvironment?.reach ?? .localhost
                let control = tmuxControlFactory(tmuxPath, reach, defaults)
                if wrappedProfile.createdWindow {
                    try? Self.runTmuxControlOperationSync {
                        try await control.killWindow(target: target)
                    }
                }
                if !wrappedProfile.viewSessionExisted {
                    let viewSessionName = TmuxSession.viewSessionName(tileId: tile.id)
                    try? Self.runTmuxControlOperationSync {
                        try await control.killSession(name: viewSessionName)
                    }
                }
            }
            return .failure(error)
        }

        // Scrollback replay is option (c): persisted to disk (descriptor.scrollback
        // above), on-screen replay deferred (NEEDS-HUMAN mechanism decision pending).

        return .restarted(runtime)
    }

    /// Captures the live cwd and scrollback from a running terminal runtime and persists
    /// them into the stored descriptor. This is the real production persist path that
    /// T13's check drives (the equivalent of what T12's debounced autosave flush will
    /// call). cwd is read from the last OSC-7 report (runtime.capturedCwd); scrollback
    /// is bounded to SessionResumeConfig.scrollbackMaxLines() at capture time.
    ///
    /// - Parameters:
    ///   - defaults: UserDefaults suite for reading config (default: .standard). Test-
    ///     injected suites allow driving the config gate without touching .standard.
    ///   - maxLines: Override for the scrollback line cap. Nil (default) reads from
    ///     SessionResumeConfig. Test-injected small values exercise the real suffix bound.
    func flushTerminalSessionSnapshot(
        tileId: UUID,
        runtime: GhosttyTerminalRuntime,
        defaults: UserDefaults = .standard,
        maxLines: Int? = nil
    ) throws {
        let now = Date()
        guard let existing = try? projectStore.listSessions().first(where: { $0.tileId == tileId }) else {
            return  // no descriptor yet (tile never saved); nothing to flush
        }

        let liveCwd = runtime.capturedCwd
        let resolvedMaxLines = maxLines ?? SessionResumeConfig.scrollbackMaxLines(defaults: defaults)
        let rawScrollback = runtime.capturedScrollback
        let boundedScrollback: String? = {
            guard SessionResumeConfig.scrollbackEnabled(defaults: defaults) else { return nil }
            let lines = rawScrollback.components(separatedBy: "\n")
            let capped = lines.suffix(resolvedMaxLines)
            let joined = capped.joined(separator: "\n")
            return joined.isEmpty ? nil : joined
        }()

        let descriptor = TerminalSessionDescriptor(
            id: existing.id,
            tileId: tileId,
            launchProfileId: existing.launchProfileId,
            command: existing.command,
            args: existing.args,
            cwd: liveCwd,
            env: existing.env,
            title: existing.title,
            createdAt: existing.createdAt,
            lastStartedAt: now,
            lastExit: existing.lastExit,
            agentDescriptor: existing.agentDescriptor,
            scrollback: boundedScrollback
        )
        try projectStore.saveSession(descriptor)
    }

    enum NoteOutcome {
        case spawned(noteId: UUID, tileId: UUID)
        case failure(Error)
    }

    enum ManagedAgentOutcome {
        case spawned(tileId: UUID)
        case failure(Error)
    }

    /// ⌘K's managed-agent spawn. `refusedModel` is a THIRD outcome on purpose: an
    /// explicit choice that has left the live catalogue is refused, not substituted
    /// and not a construction failure, and the caller must be able to say so.
    enum ManagedAgentSelectionOutcome {
        case spawned(tileId: UUID, providerSettings: AgentModelConfig.Resolution)
        case refusedModel(String)
        case failure(Error)
    }

    enum FileOutcome {
        case spawned(tileId: UUID)
        /// A tile for this exact file is already on the canvas; it is not moved.
        case alreadyOpen(tileId: UUID)
        case invalidPath
        case failure(Error)
    }

    enum FileTreeOutcome {
        case spawned(tileId: UUID, viewModel: FileTreeViewModel)
        case invalidPath
        case failure(Error)
    }

    enum FileTreeRestartOutcome {
        case restarted(FileTreeViewModel)
        case tileNotFound
        case failure(Error)
    }

    enum BrowserOutcome {
        case spawned(WKWebViewBrowserRuntime)
        case invalidURL(String)
        case failure(Error)
    }

    enum BrowserRestartOutcome {
        case restarted(WKWebViewBrowserRuntime)
        case invalidURL(String)
        case tileNotFound
        case failure(Error)
    }

    enum BrowserProfileSwitchOutcome {
        case switched(oldRuntimeId: UUID?, newRuntime: WKWebViewBrowserRuntime)
        case unknownProfile(UUID)
        case invalidURL(String)
        case tileNotFound
        case failure(Error)
    }

    enum BrowserInspectorOutcome {
        case spawned(tileId: UUID)
        case notBrowserTile
        case failure(Error)
    }

    private static var defaultBrowserURL: String { DefaultBrowserURL.current }

    func updateBrowserProfiles(_ profiles: [BrowserProfile]) {
        browserProfiles = RegistrySettings.normalizedBrowserProfilesForApp(profiles)
    }

    private func availableBrowserProfiles() -> [BrowserProfile] {
        RegistrySettings.normalizedBrowserProfilesForApp(browserProfileMenuProvider?() ?? browserProfiles)
    }

    private func browserProfile(for id: UUID?) -> BrowserProfile {
        let requested = id ?? project.settings.defaultBrowserProfileId
        return availableBrowserProfiles().first(where: { $0.id == requested }) ?? BrowserProfile.builtInDefault()
    }

    private func activeBrowserProfileId(for tileId: UUID) -> UUID {
        if let persisted = try? loadBrowserStateIfAvailable()?.tiles.first(where: { $0.tileId == tileId }) {
            return browserProfile(for: persisted.profileId).id
        }
        return browserProfile(for: canvasView?.canvasState.tiles.first(where: { $0.id == tileId })?.metadata.browserProfileId).id
    }

    private func configureBrowserProfileMenu(_ view: BrowserTileNSView, tileId: UUID) {
        view.browserProfilesProvider = { [weak self] in self?.availableBrowserProfiles() ?? [BrowserProfile.builtInDefault()] }
        view.activeBrowserProfileProvider = { [weak self] in self?.activeBrowserProfileId(for: tileId) ?? BrowserProfile.defaultProfileId }
        view.onSwitchBrowserProfile = { [weak self] profileId in self?.browserProfileSwitchHandler?(tileId, profileId) }
        view.onCreateBrowserProfile = { [weak self] in self?.browserProfileCreateHandler?(tileId) }
        view.onRenameBrowserProfile = { [weak self] profileId in self?.browserProfileRenameHandler?(tileId, profileId) }
        view.onDeleteBrowserProfile = { [weak self] profileId in self?.browserProfileDeleteHandler?(tileId, profileId) }
    }

    private func configureBrowserInspectorMenu(_ view: BrowserTileNSView, tileId: UUID) {
        view.onOpenInspector = { [weak self] in
            _ = self?.spawnBrowserInspector(for: tileId)
        }
    }

    private func browserTileDidRefresh(tileId: UUID) {
        refreshBrowserInspectors(inspecting: tileId)
        browserPersistenceHandler?()
    }

    /// Spawns a live `WKWebView` browser tile. Defaults to the configured
    /// browser URL (`about:blank` unless overridden) if `url` is nil. Persists a BrowserTile entry into BrowserState alongside
    /// the canvas state. Returns the runtime so the caller can track it for
    /// shutdown.
    func spawnBrowser(url: String? = nil, at worldPoint: CGPoint? = nil) -> BrowserOutcome {
        guard let canvasView else { return .failure(SpawnError.canvasUnavailable) }
        let urlString = url ?? Self.defaultBrowserURL
        guard URL(string: urlString) != nil else {
            return .invalidURL(urlString)
        }
        let browserState: BrowserState
        do {
            browserState = try loadBrowserStateIfAvailable() ?? BrowserState(tiles: [])
        } catch {
            return .failure(error)
        }

        let frame = makePlacement(
            worldPoint: worldPoint,
            size: CanvasEngine.defaultFrame(for: .browser),
            in: canvasView
        )
        let nextZ = CanvasEngine.zPositionAbove(canvasView.canvasState.tiles)
        var tile = Tile(
            id: UUID(),
            kind: .browser,
            title: "Browser",
            frame: frame,
            zPosition: nextZ,
            runtimeRef: nil,
            metadata: TileMetadata(url: urlString, browserProfileId: browserProfile(for: nil).id)
        )

        let profile = browserProfile(for: tile.metadata.browserProfileId)
        let storageGroupId = profile.dataStoreIdentifier
        let webView = browserEngine.makeWebView(storageGroupId: storageGroupId)
        let runtime = WKWebViewBrowserRuntime(
            id: UUID(),
            tileId: tile.id,
            webView: webView,
            initialURL: urlString
        )
        configureBrowserRuntime(runtime, profileId: profile.id)
        tile.runtimeRef = RuntimeRef(kind: .browserTile, id: runtime.id)

        let view = BrowserTileNSView(tile: tile, runtime: runtime)
        view.onAfterRefresh = { [weak self] in self?.browserTileDidRefresh(tileId: tile.id) }
        view.onTabModelChange = { [weak self] model in try? self?.writeBrowserTabModel(tileId: tile.id, runtimeId: runtime.id, model: model, storageGroupId: storageGroupId, profileId: profile.id) }
        configureBrowserProfileMenu(view, tileId: tile.id)
        configureBrowserInspectorMenu(view, tileId: tile.id)
        canvasView.install(tileView: view, for: tile)

        do {
            try upsertBrowserTile(
                runtimeId: runtime.id,
                tileId: tile.id,
                url: urlString,
                title: "",
                storageGroupId: storageGroupId,
                profileId: profile.id,
                in: browserState
            )
            try projectStore.saveCanvas(canvasView.canvasState)
        } catch {
            return .failure(error)
        }

        runtime.loadURL(urlString)
        return .spawned(runtime)
    }

    private func configureBrowserRuntime(_ runtime: WKWebViewBrowserRuntime, profileId: UUID) {
        runtime.reservedShortcutHandler = reservedShortcutHandler
        runtime.onNewWindowRequest = { [weak self, weak runtime] request, configuration, _, _ in
            guard let self, let opener = runtime else { return nil }
            return self.spawnBrowserForNewWindow(request: request, configuration: configuration, openerTileId: opener.tileId, profileId: profileId)
        }
    }

    private func spawnBrowserForNewWindow(request: URLRequest, configuration: WKWebViewConfiguration, openerTileId: UUID, profileId: UUID) -> WKWebView? {
        guard let canvasView else { return nil }
        let urlString = request.url?.absoluteString ?? Self.defaultBrowserURL
        guard URL(string: urlString) != nil else { return nil }
        let browserState: BrowserState
        do {
            browserState = try loadBrowserStateIfAvailable() ?? BrowserState(tiles: [])
        } catch {
            fputs("TileSpawner target=_blank BrowserState load failed: \(error)\n", stderr)
            return nil
        }

        let openerFrame = canvasView.canvasState.tiles.first(where: { $0.id == openerTileId })?.frame
        let placementPoint: CGPoint?
        if let openerFrame {
            placementPoint = CGPoint(x: openerFrame.x + openerFrame.width + 24, y: openerFrame.y + 24)
        } else {
            placementPoint = nil
        }
        let frame = makePlacement(
            worldPoint: placementPoint,
            size: CanvasEngine.defaultFrame(for: .browser),
            in: canvasView
        )
        let nextZ = CanvasEngine.zPositionAbove(canvasView.canvasState.tiles)
        let profile = browserProfile(for: profileId)
        var tile = Tile(
            id: UUID(),
            kind: .browser,
            title: "Browser",
            frame: frame,
            zPosition: nextZ,
            runtimeRef: nil,
            metadata: TileMetadata(url: urlString, browserProfileId: profile.id)
        )

        let webView = WKWebView(frame: .zero, configuration: configuration)
        browserEngine.applyInspectionPolicy(to: webView)
        let runtime = WKWebViewBrowserRuntime(
            id: UUID(),
            tileId: tile.id,
            webView: webView,
            initialURL: urlString
        )
        configureBrowserRuntime(runtime, profileId: profile.id)
        tile.runtimeRef = RuntimeRef(kind: .browserTile, id: runtime.id)

        let view = BrowserTileNSView(tile: tile, runtime: runtime)
        view.onAfterRefresh = { [weak self] in self?.browserTileDidRefresh(tileId: tile.id) }
        view.onTabModelChange = { [weak self] model in try? self?.writeBrowserTabModel(tileId: tile.id, runtimeId: runtime.id, model: model, storageGroupId: profile.dataStoreIdentifier, profileId: profile.id) }
        configureBrowserProfileMenu(view, tileId: tile.id)
        configureBrowserInspectorMenu(view, tileId: tile.id)
        canvasView.install(tileView: view, for: tile)

        do {
            try upsertBrowserTile(
                runtimeId: runtime.id,
                tileId: tile.id,
                url: urlString,
                title: "",
                storageGroupId: profile.dataStoreIdentifier,
                profileId: profile.id,
                in: browserState
            )
            try projectStore.saveCanvas(canvasView.canvasState)
        } catch {
            fputs("TileSpawner target=_blank persistence failed: \(error)\n", stderr)
            canvasView.removeTile(id: tile.id)
            return nil
        }
        return webView
    }

    func installBrowserSnapshotTile(runtime: WKWebViewBrowserRuntime, snapshotImage: NSImage) throws {
        guard let canvasView,
              let existing = canvasView.canvasState.tiles.first(where: { $0.id == runtime.tileId })
        else { throw SpawnError.canvasUnavailable }
        try writeBrowserTileSnapshotOrThrow(for: runtime)
        var tile = existing
        tile.runtimeRef = nil
        if !runtime.title.isEmpty {
            tile.title = runtime.title
        }
        let view = BrowserSnapshotTileNSView(
            tile: tile,
            snapshotImage: snapshotImage,
            urlString: runtime.url
        )
        canvasView.install(tileView: view, for: tile)
        try projectStore.saveCanvas(canvasView.canvasState)
        runtime.terminate(policy: .force)
    }

    /// Re-resolve an existing browser tile's URL and replace its view with a
    /// fresh runtime. Reuses tile id, frame, and z-index.
    func restartBrowserTile(tileId: UUID) -> BrowserRestartOutcome {
        guard let canvasView else { return .failure(SpawnError.canvasUnavailable) }
        guard let existing = canvasView.canvasState.tiles.first(where: { $0.id == tileId }) else {
            return .tileNotFound
        }
        let browserState: BrowserState?
        let persistedBrowserTile: BrowserTile?
        do {
            browserState = try loadBrowserStateIfAvailable()
            persistedBrowserTile = browserState?.tiles.first(where: { $0.tileId == tileId })
        } catch {
            return .failure(error)
        }
        let requestedURLString = persistedBrowserTile?.url ?? existing.metadata.url ?? Self.defaultBrowserURL
        let requestedScheme = URL(string: requestedURLString)?.scheme ?? ""
        let urlString = requestedScheme.isEmpty ? DefaultBrowserURL.fallback : requestedURLString
        guard let scheme = URL(string: urlString)?.scheme, !scheme.isEmpty else {
            return .invalidURL(requestedURLString)
        }

        let profile = browserProfile(for: persistedBrowserTile?.profileId ?? existing.metadata.browserProfileId)
        let storageGroupId = persistedBrowserTile?.storageGroupId ?? profile.dataStoreIdentifier
        let webView = browserEngine.makeWebView(storageGroupId: storageGroupId)
        let runtime = WKWebViewBrowserRuntime(
            id: UUID(),
            tileId: existing.id,
            webView: webView,
            initialURL: urlString
        )
        configureBrowserRuntime(runtime, profileId: profile.id)
        var tile = existing
        tile.runtimeRef = RuntimeRef(kind: .browserTile, id: runtime.id)
        if let persistedTitle = persistedBrowserTile?.title, !persistedTitle.isEmpty {
            tile.title = persistedTitle
        }

        let view = BrowserTileNSView(tile: tile, runtime: runtime, browserTile: persistedBrowserTile)
        view.onAfterRefresh = { [weak self] in self?.browserTileDidRefresh(tileId: tile.id) }
        view.onTabModelChange = { [weak self] model in try? self?.writeBrowserTabModel(tileId: tile.id, runtimeId: runtime.id, model: model, storageGroupId: storageGroupId, profileId: profile.id) }
        configureBrowserProfileMenu(view, tileId: tile.id)
        configureBrowserInspectorMenu(view, tileId: tile.id)
        canvasView.install(tileView: view, for: tile)

        do {
            try upsertBrowserTile(
                runtimeId: runtime.id,
                tileId: tile.id,
                url: urlString,
                title: persistedBrowserTile?.title ?? tile.title,
                storageGroupId: storageGroupId,
                profileId: profile.id,
                interactionState: persistedBrowserTile?.interactionState,
                in: browserState ?? BrowserState(tiles: [])
            )
            try projectStore.saveCanvas(canvasView.canvasState)
        } catch {
            return .failure(error)
        }

        // Apply persisted interactionState (back/forward history, scroll, forms)
        // when available, restoring richer session state than URL-only.
        if let interactionState = persistedBrowserTile?.interactionState {
            runtime.restoreInteractionState(interactionState)
        } else {
            runtime.loadURL(urlString)
        }
        return .restarted(runtime)
    }

    func spawnBrowserInspector(for browserTileId: UUID, at worldPoint: CGPoint? = nil) -> BrowserInspectorOutcome {
        guard let canvasView else { return .failure(SpawnError.canvasUnavailable) }
        guard let browserTile = canvasView.canvasState.tiles.first(where: { $0.id == browserTileId && $0.kind == .browser }) else {
            return .notBrowserTile
        }

        let browserState: BrowserState
        do {
            browserState = try loadBrowserStateIfAvailable() ?? BrowserState(tiles: [])
        } catch {
            return .failure(error)
        }

        if let existingInspectorId = existingBrowserInspectorTileId(inspecting: browserTileId, browserState: browserState, in: canvasView) {
            refreshBrowserInspector(inspectorTileId: existingInspectorId, browserTileId: browserTileId, browserState: browserState)
            _ = revealTile(existingInspectorId)
            try? projectStore.saveCanvas(canvasView.canvasState)
            return .spawned(tileId: existingInspectorId)
        }

        let frame = makePlacement(
            worldPoint: worldPoint ?? CGPoint(x: browserTile.frame.x + browserTile.frame.width + 24, y: browserTile.frame.y),
            size: CanvasEngine.defaultFrame(for: .browserInspector),
            in: canvasView
        )
        let nextZ = CanvasEngine.zPositionAbove(canvasView.canvasState.tiles)
        let now = Date()
        let inspectorTileId = UUID()
        let inspectorState = BrowserInspectorState(
            inspectorTileId: inspectorTileId,
            inspectedBrowserTileId: browserTileId,
            selectedPanel: .elements,
            createdAt: now,
            updatedAt: now
        )
        let summary = browserInspectorSummary(for: browserTileId, browserState: browserState)
        let tile = Tile(
            id: inspectorTileId,
            kind: .browserInspector,
            title: "Inspector — \(Self.inspectorDisplayName(title: summary?.title, url: summary?.url))",
            frame: frame,
            zPosition: nextZ,
            runtimeRef: nil,
            metadata: TileMetadata()
        )
        let view = BrowserInspectorTileNSView(
            tile: tile,
            inspectorState: inspectorState,
            inspectedBrowser: summary,
            domSnapshotProvider: browserInspectorDOMSnapshotProvider(for: browserTileId),
            domHighlighter: browserInspectorDOMHighlighter(for: browserTileId),
            computedStyleProvider: browserInspectorComputedStyleProvider(for: browserTileId),
            consoleLogProvider: browserInspectorConsoleLogProvider(for: browserTileId),
            consoleClearer: browserInspectorConsoleClearer(for: browserTileId),
            networkLiteEventProvider: browserInspectorNetworkLiteEventProvider(for: browserTileId)
        )
        configureBrowserInspectorView(view, inspectorTileId: inspectorTileId, browserTileId: browserTileId)
        canvasView.install(tileView: view, for: tile)

        var nextState = browserState
        nextState.inspectorStates.append(inspectorState)
        do {
            try projectStore.saveBrowserState(nextState)
            _ = revealTile(inspectorTileId)
            try projectStore.saveCanvas(canvasView.canvasState)
        } catch {
            return .failure(error)
        }
        return .spawned(tileId: inspectorTileId)
    }

    func installBrowserInspectorTile(_ tile: Tile, in canvasView: CanvasNSView) {
        let browserState = try? loadBrowserStateIfAvailable()
        let inspectorState = browserState?.inspectorStates.first { $0.inspectorTileId == tile.id }
        let summary = inspectorState.flatMap { browserInspectorSummary(for: $0.inspectedBrowserTileId, browserState: browserState) }
        let view = BrowserInspectorTileNSView(
            tile: tile,
            inspectorState: inspectorState,
            inspectedBrowser: summary,
            domSnapshotProvider: inspectorState.map { browserInspectorDOMSnapshotProvider(for: $0.inspectedBrowserTileId) },
            domHighlighter: inspectorState.map { browserInspectorDOMHighlighter(for: $0.inspectedBrowserTileId) },
            computedStyleProvider: inspectorState.map { browserInspectorComputedStyleProvider(for: $0.inspectedBrowserTileId) },
            consoleLogProvider: inspectorState.map { browserInspectorConsoleLogProvider(for: $0.inspectedBrowserTileId) },
            consoleClearer: inspectorState.map { browserInspectorConsoleClearer(for: $0.inspectedBrowserTileId) },
            networkLiteEventProvider: inspectorState.map { browserInspectorNetworkLiteEventProvider(for: $0.inspectedBrowserTileId) }
        )
        let inspectorTileId = tile.id
        if let browserTileId = inspectorState?.inspectedBrowserTileId {
            configureBrowserInspectorView(view, inspectorTileId: inspectorTileId, browserTileId: browserTileId)
        } else {
            view.onSelectedPanelChange = { [weak self] panel in
                try? self?.updateBrowserInspectorPanel(inspectorTileId: inspectorTileId, selectedPanel: panel)
            }
        }
        canvasView.install(tileView: view, for: tile)
    }

    private func configureBrowserInspectorView(_ view: BrowserInspectorTileNSView, inspectorTileId: UUID, browserTileId: UUID) {
        view.onSelectedPanelChange = { [weak self] panel in
            try? self?.updateBrowserInspectorPanel(inspectorTileId: inspectorTileId, selectedPanel: panel)
        }
        view.onRevealBrowser = { [weak self] in
            guard let self else { return }
            _ = self.revealTile(browserTileId)
            if let canvasView = self.canvasView {
                try? self.projectStore.saveCanvas(canvasView.canvasState)
            }
        }
    }

    private func existingBrowserInspectorTileId(inspecting browserTileId: UUID, browserState: BrowserState, in canvasView: CanvasNSView) -> UUID? {
        browserState.inspectorStates.first { state in
            state.inspectedBrowserTileId == browserTileId
                && canvasView.canvasState.tiles.contains { $0.id == state.inspectorTileId && $0.kind == .browserInspector }
        }?.inspectorTileId
    }

    @discardableResult
    private func revealTile(_ tileId: UUID) -> Bool {
        guard let canvasView,
              canvasView.canvasState.tiles.contains(where: { $0.id == tileId })
        else { return false }
        canvasView.centerOnTile(tileId)
        if canvasView.focusBroker?.enterScope(.tile(tileId), reason: .userClick) != true {
            canvasView.bringToFront(tileId: tileId)
        }
        return canvasView.canvasState.lastActiveTileId == tileId
    }

    private func refreshBrowserInspectors(inspecting browserTileId: UUID) {
        guard let browserState = try? loadBrowserStateIfAvailable() else { return }
        for inspectorState in browserState.inspectorStates where inspectorState.inspectedBrowserTileId == browserTileId {
            refreshBrowserInspector(
                inspectorTileId: inspectorState.inspectorTileId,
                browserTileId: browserTileId,
                browserState: browserState
            )
        }
    }

    private func refreshBrowserInspector(inspectorTileId: UUID, browserTileId: UUID, browserState: BrowserState) {
        guard let canvasView else { return }
        let summary = browserInspectorSummary(for: browserTileId, browserState: browserState)
        if let inspectorView = canvasView.tileView(for: inspectorTileId) as? BrowserInspectorTileNSView {
            inspectorView.updateInspectedBrowser(summary)
        }
        guard let summary,
              let index = canvasView.canvasState.tiles.firstIndex(where: { $0.id == inspectorTileId && $0.kind == .browserInspector })
        else { return }
        var tile = canvasView.canvasState.tiles[index]
        let title = "Inspector — \(Self.inspectorDisplayName(title: summary.title, url: summary.url))"
        guard tile.title != title else { return }
        tile.title = title
        canvasView.updateTile(tile, recalculateZoneBounds: false)
    }

    private func browserInspectorDOMSnapshotProvider(for browserTileId: UUID) -> BrowserInspectorTileNSView.DOMSnapshotProvider {
        { [weak self] completion in
            guard let browserView = self?.canvasView?.tileView(for: browserTileId) as? BrowserTileNSView else {
                completion(.failure(Self.browserInspectorConnectionError("linked browser tile is not live")))
                return
            }
            browserView.captureDOMSnapshotForInspector(completion: completion)
        }
    }

    private func browserInspectorDOMHighlighter(for browserTileId: UUID) -> BrowserInspectorTileNSView.DOMHighlighter {
        { [weak self] nodePath, completion in
            guard let browserView = self?.canvasView?.tileView(for: browserTileId) as? BrowserTileNSView else {
                completion(.failure(Self.browserInspectorConnectionError("linked browser tile is not live")))
                return
            }
            browserView.highlightDOMNodeForInspector(path: nodePath, completion: completion)
        }
    }

    private func browserInspectorComputedStyleProvider(for browserTileId: UUID) -> BrowserInspectorTileNSView.ComputedStyleProvider {
        { [weak self] nodePath, completion in
            guard let browserView = self?.canvasView?.tileView(for: browserTileId) as? BrowserTileNSView else {
                completion(.failure(Self.browserInspectorConnectionError("linked browser tile is not live")))
                return
            }
            browserView.captureComputedStylesForInspector(path: nodePath, completion: completion)
        }
    }

    private func browserInspectorConsoleLogProvider(for browserTileId: UUID) -> BrowserInspectorTileNSView.ConsoleLogProvider {
        { [weak self] in
            guard let browserView = self?.canvasView?.tileView(for: browserTileId) as? BrowserTileNSView else { return nil }
            return browserView.consoleLogEntriesForInspector()
        }
    }

    private func browserInspectorConsoleClearer(for browserTileId: UUID) -> BrowserInspectorTileNSView.ConsoleClearer {
        { [weak self] in
            guard let browserView = self?.canvasView?.tileView(for: browserTileId) as? BrowserTileNSView else { return false }
            return browserView.clearConsoleLogEntriesForInspector()
        }
    }

    private func browserInspectorNetworkLiteEventProvider(for browserTileId: UUID) -> BrowserInspectorTileNSView.NetworkLiteEventProvider {
        { [weak self] in
            guard let browserView = self?.canvasView?.tileView(for: browserTileId) as? BrowserTileNSView else { return nil }
            return browserView.networkLiteEventsForInspector()
        }
    }

    private static func browserInspectorConnectionError(_ message: String) -> NSError {
        NSError(domain: "ContinuumBrowserInspectorConnection", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    @discardableResult
    func deleteBrowserInspectors(inspecting browserTileId: UUID, in canvasView: CanvasNSView) -> [UUID] {
        guard var browserState = try? loadBrowserStateIfAvailable() else { return [] }
        let inspectorIds = Set(browserState.inspectorStates
            .filter { $0.inspectedBrowserTileId == browserTileId }
            .map(\.inspectorTileId))
        guard !inspectorIds.isEmpty else { return [] }
        browserState.inspectorStates.removeAll { inspectorIds.contains($0.inspectorTileId) }
        try? projectStore.saveBrowserState(browserState)
        for inspectorId in inspectorIds {
            canvasView.removeTile(id: inspectorId)
        }
        return Array(inspectorIds)
    }

    func deleteBrowserInspector(tileId: UUID) {
        guard var browserState = try? loadBrowserStateIfAvailable() else { return }
        let originalCount = browserState.inspectorStates.count
        browserState.inspectorStates.removeAll { $0.inspectorTileId == tileId }
        if browserState.inspectorStates.count != originalCount {
            try? projectStore.saveBrowserState(browserState)
        }
    }

    private func updateBrowserInspectorPanel(inspectorTileId: UUID, selectedPanel: BrowserInspectorPanel) throws {
        var browserState = try loadBrowserStateIfAvailable() ?? BrowserState(tiles: [])
        guard let index = browserState.inspectorStates.firstIndex(where: { $0.inspectorTileId == inspectorTileId }) else { return }
        browserState.inspectorStates[index].selectedPanel = selectedPanel
        browserState.inspectorStates[index].updatedAt = Date()
        try projectStore.saveBrowserState(browserState)
    }

    private func browserInspectorSummary(for browserTileId: UUID, browserState: BrowserState?) -> BrowserInspectorTileNSView.InspectedBrowserSummary? {
        guard let canvasView,
              let tile = canvasView.canvasState.tiles.first(where: { $0.id == browserTileId && $0.kind == .browser })
        else { return nil }
        let liveBrowser = canvasView.tileView(for: browserTileId) as? BrowserTileNSView
        let persisted = browserState?.tiles.first { $0.tileId == browserTileId }
        let liveTitle = liveBrowser?.runtime.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let persistedTitle = persisted?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let canvasTitle = tile.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayTitle: String
        if !liveTitle.isEmpty {
            displayTitle = liveTitle
        } else if !persistedTitle.isEmpty {
            displayTitle = persistedTitle
        } else {
            displayTitle = canvasTitle == "Browser" ? "" : canvasTitle
        }
        let liveURL = liveBrowser?.runtime.url.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let displayURL = !liveURL.isEmpty ? liveURL : (persisted?.url ?? tile.metadata.url)
        return BrowserInspectorTileNSView.InspectedBrowserSummary(
            tileId: browserTileId,
            title: displayTitle,
            url: displayURL
        )
    }

    private static func inspectorDisplayName(title: String?, url: String?) -> String {
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedTitle.isEmpty { return trimmedTitle }
        if let url, let host = URL(string: url)?.host, !host.isEmpty { return host }
        return "Browser"
    }

    /// Switches one browser tile to a different persisted profile by replacing
    /// its WKWebView/runtime. WebKit data stores are construction-time state,
    /// so profile changes cannot be applied in place.
    func switchBrowserTileProfile(tileId: UUID, profileId: UUID) -> BrowserProfileSwitchOutcome {
        guard let canvasView else { return .failure(SpawnError.canvasUnavailable) }
        guard let existing = canvasView.canvasState.tiles.first(where: { $0.id == tileId }) else {
            return .tileNotFound
        }
        guard let selectedProfile = availableBrowserProfiles().first(where: { $0.id == profileId }) else {
            return .unknownProfile(profileId)
        }

        let oldBrowserView = canvasView.tileView(for: tileId) as? BrowserTileNSView
        let oldRuntime = oldBrowserView?.runtime
        let browserState: BrowserState?
        let persistedBrowserTile: BrowserTile?
        do {
            browserState = try loadBrowserStateIfAvailable()
            persistedBrowserTile = browserState?.tiles.first(where: { $0.tileId == tileId })
        } catch {
            return .failure(error)
        }
        let urlString = oldRuntime?.url ?? persistedBrowserTile?.url ?? existing.metadata.url ?? Self.defaultBrowserURL
        guard URL(string: urlString) != nil else { return .invalidURL(urlString) }
        let title = oldRuntime?.title.isEmpty == false ? (oldRuntime?.title ?? existing.title) : (persistedBrowserTile?.title ?? existing.title)

        let webView = browserEngine.makeWebView(storageGroupId: selectedProfile.dataStoreIdentifier)
        let runtime = WKWebViewBrowserRuntime(
            id: UUID(),
            tileId: existing.id,
            webView: webView,
            initialURL: urlString
        )
        configureBrowserRuntime(runtime, profileId: selectedProfile.id)

        var tile = existing
        tile.runtimeRef = RuntimeRef(kind: .browserTile, id: runtime.id)
        tile.title = title.isEmpty ? existing.title : title
        tile.metadata.url = urlString
        tile.metadata.browserProfileId = selectedProfile.id

        let view = BrowserTileNSView(tile: tile, runtime: runtime, browserTile: persistedBrowserTile)
        view.onAfterRefresh = { [weak self] in self?.browserTileDidRefresh(tileId: tile.id) }
        view.onTabModelChange = { [weak self] model in try? self?.writeBrowserTabModel(tileId: tile.id, runtimeId: runtime.id, model: model, storageGroupId: selectedProfile.dataStoreIdentifier, profileId: selectedProfile.id) }
        configureBrowserProfileMenu(view, tileId: tile.id)
        configureBrowserInspectorMenu(view, tileId: tile.id)
        canvasView.install(tileView: view, for: tile)

        do {
            try upsertBrowserTile(
                runtimeId: runtime.id,
                tileId: tile.id,
                url: urlString,
                title: title,
                storageGroupId: selectedProfile.dataStoreIdentifier,
                profileId: selectedProfile.id,
                in: browserState ?? BrowserState(tiles: [])
            )
            try projectStore.saveCanvas(canvasView.canvasState)
        } catch {
            return .failure(error)
        }

        oldRuntime?.onStateChange = nil
        oldRuntime?.terminate(policy: .requestClose)
        runtime.loadURL(urlString)
        return .switched(oldRuntimeId: oldRuntime?.id, newRuntime: runtime)
    }

    // MARK: - Managed agent tiles

    /// Spawns the product-managed agent surface. This path deliberately does
    /// not create a terminal session descriptor; raw CLI terminals remain the
    /// explicit fallback profiles in `LaunchProfileRegistry`.
    func spawnManagedAgent(
        agentKind: AgentKind = .managed,
        at worldPoint: CGPoint? = nil,
        providerSettings: AgentModelConfig.Resolution? = nil
    ) -> ManagedAgentOutcome {
        guard let canvasView else { return .failure(SpawnError.canvasUnavailable) }
        let now = Date()
        let tileId = UUID()
        let threadId = "managed-\(tileId.uuidString)"
        let frame = makePlacement(
            worldPoint: worldPoint,
            size: CanvasEngine.defaultFrame(for: .managedAgent),
            in: canvasView
        )
        let nextZ = CanvasEngine.zPositionAbove(canvasView.canvasState.tiles)
        // One resolution seeds every pre-attach projection. Cmd+K supplies its
        // explicit choice; generic creation falls back to Settings. Wiring gives
        // the same resolution to the agent record before the view attaches.
        let resolvedProviderSettings = providerSettings ?? AgentModelConfig.resolvedFromDefaults()
        let spawnModelID = resolvedProviderSettings.model
        let spawnModelName = AgentModelCatalog.shared.displayName(for: spawnModelID)
            ?? spawnModelID.split(separator: "/").last.map(String.init)
            ?? spawnModelID
        let tile = Tile(
            id: tileId,
            kind: .managedAgent,
            title: spawnModelName,
            frame: frame,
            zPosition: nextZ,
            runtimeRef: nil,
            metadata: TileMetadata(launchProfileId: "managed-agent", projectRelativeCwd: ".")
        )
        let descriptor = AgentDescriptor(agentKind: agentKind, worktreePath: nil, status: .configuring, statusUpdatedAt: now)
        let view = ManagedAgentTileNSView(
            tile: tile,
            threadId: threadId,
            descriptor: descriptor,
            providerSettings: resolvedProviderSettings
        )
        view.ingest(.sessionStateChanged(.ready))
        view.ingest(.contentDelta(threadId: threadId, turnId: "bootstrap", streamKind: .assistant, delta: "Ready. Type a prompt below to run \(spawnModelName) in this tile."))
        canvasView.install(tileView: view, for: tile)

        do {
            try managedSessionStore.upsert(ManagedAgentSessionRecord(
                tileId: tileId,
                agentKind: agentKind,
                // P3.1: `.running`, matching the terminal path above — the tile is
                // installed and ingesting by the line above this `do`. `.starting`
                // here was the bug: nothing ever transitioned it, so a record could
                // claim it was mid-launch forever.
                status: .running,
                lastSeenAt: now,
                resumeCursor: nil,
                runtimePayload: nil
            ))
            try projectStore.saveCanvas(canvasView.canvasState)
        } catch {
            try? managedSessionStore.delete(tileId: tileId)
            return .failure(error)
        }
        return .spawned(tileId: tileId)
    }

    /// ⌘K's managed-agent spawn, whole, in ONE function: validate the explicit
    /// choice against the catalogue AS IT STANDS, say so out loud if it has left,
    /// and otherwise hand the SAME resolution to tile creation and to the agent
    /// record (`wire`) before the view can attach and copy a model off it.
    ///
    /// It lives here, and not at the AppDelegate call site, because here it can be
    /// WITNESSED: `runManagedAgentModelSpawnSelfCheck` drives this exact function
    /// with a departed id and observes that no tile was built, no record was wired,
    /// and a refusal naming the model was spoken. The first draft of that witness
    /// asserted only that `ContinuumApp.swift` CONTAINED the guard's call — a
    /// reviewer then replaced `else { return false }` with
    /// `?? AgentModelConfig.resolvedFromDefaults()`, silently substituting the
    /// default for the departed model (the exact inverse of the fix), rebuilt, and
    /// the check still printed `passed`.
    ///
    /// The refusal is not theoretical: the palette's rows are the catalogue as it was
    /// when the model step opened, and a live `pi --list-models` probe landing while
    /// it is up narrows the list to the providers pi reports as authed, so a row can
    /// outlive its model.
    func spawnManagedAgentForSelectedModel(
        _ selection: String?,
        defaults: UserDefaults = .standard,
        announceRefusal: @MainActor (String) -> Void = TileSpawner.announceManagedAgentModelRefusal,
        wire: (UUID, AgentModelConfig.Resolution) -> Void
    ) -> ManagedAgentSelectionOutcome {
        guard let providerSettings = AgentModelConfig.resolved(selection: selection, defaults: defaults) else {
            // `resolved` returns nil only for a non-nil selection outside the
            // catalogue, so this is always a real id someone picked.
            let refused = selection ?? ""
            announceRefusal(Self.managedAgentModelRefusalMessage(for: refused))
            return .refusedModel(refused)
        }
        switch spawnManagedAgent(providerSettings: providerSettings) {
        case let .spawned(tileId):
            wire(tileId, providerSettings)
            return .spawned(tileId: tileId, providerSettings: providerSettings)
        case let .failure(error):
            return .failure(error)
        }
    }

    /// A refused ⌘K model choice, said out loud. ⌘K dispatches and closes whatever
    /// the result, so a bare `return false` was a keystroke that did nothing at all
    /// and explained nothing — this matches the neighbouring refusals in
    /// `ContinuumApp.swift`, which beep and name themselves on stderr.
    static func announceManagedAgentModelRefusal(_ message: String) {
        NSSound.beep()
        fputs(message + "\n", stderr)
    }

    static func managedAgentModelRefusalMessage(for selection: String) -> String {
        "New agent refused: \(selection) is no longer offered by the model catalogue (a live model probe narrowed it while the command center was open) — no tile and no agent were created. Reopen the command center and choose from the current list."
    }

    /// A tile for an agent that ALREADY EXISTS — revealing a tileless agent from the
    /// inbox or from ⌘K's History row.
    ///
    /// Every pre-attach projection (the tile title, the bootstrap line) comes from
    /// THAT agent's record, never from the Settings default. Closing a tile is not
    /// deleting an agent, so a revealed agent still runs whatever model it was
    /// spawned with, and `ManagedAgentTileNSView.attach` puts that model in the
    /// composer footer regardless — which is how a tile ended up titled
    /// "Claude Opus 5" over a composer reading "GPT-5.6 Sol". `tile.title` is
    /// user-visible: ⌘K renders "Jump to <title>".
    ///
    /// Takes the SUPERVISOR rather than a resolution so the call site cannot forget
    /// to look one up — the omission this repairs — and so the rule has one home the
    /// self-check can drive.
    func spawnManagedAgentForExistingAgent(
        _ agentID: AgentID,
        supervisor: AgentSupervisor
    ) -> ManagedAgentOutcome {
        spawnManagedAgent(providerSettings: supervisor.providerSettings(for: agentID))
    }

    /// Deterministic witness for ⌘K's explicit-model spawn contract.
    ///
    /// BEHAVIOR, not source text. Every rule below is asserted by driving the same
    /// function production drives — `spawnManagedAgentForSelectedModel` and
    /// `spawnManagedAgentForExistingAgent` — and then observing what it built: the
    /// tile, its user-visible title, the composer seed, the resolution handed to the
    /// agent record, and the refusal's own spoken message. The first draft asserted
    /// that `ContinuumApp.swift` CONTAINED the guard's call, which pins the call and
    /// not the refusal: a reviewer substituted the Settings default for a departed
    /// model and this check stayed green.
    ///
    /// Two narrow scans remain at the end. Each reads ONE AppDelegate method body —
    /// methods that need a live app to execute — and asserts only that production
    /// still routes through a seam whose behavior is witnessed here.
    static func runManagedAgentModelSpawnSelfCheck() throws {
        struct CheckError: Error, CustomStringConvertible {
            let description: String
        }
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw CheckError(description: message) }
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("array-managed-agent-model-spawn-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = Project(
            id: UUID(),
            name: "managed-agent-model-spawn-check",
            rootPath: root.path,
            createdAt: Date(),
            updatedAt: Date(),
            defaultLaunchProfileId: "shell",
            editorPreference: .auto,
            settings: ProjectSettings(
                restorePolicy: .restoreDescriptors,
                browserStoragePolicy: .perProject,
                terminalClosePolicy: .askWhenRunning)
        )
        let store = ProjectStore(projectRoot: root)
        try store.saveProject(project)
        try store.saveCanvas(CanvasState(
            viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
            tiles: [],
            groups: [],
            lastActiveTileId: nil))
        let canvas = CanvasNSView(canvasState: try store.loadCanvas())
        let browserEngine = BrowserEngineContext()
        defer { browserEngine.shutdown() }
        let spawner = TileSpawner(
            canvasView: canvas,
            ghostty: nil,
            browserEngine: browserEngine,
            projectStore: store,
            project: project)
        // This check WRITES the configured model, and that key is the user's own
        // choice: it goes to a private suite, never to the standard domain. The
        // seam takes its defaults injected for exactly this reason.
        let suiteName = "continuum.qa.managed-agent-model-spawn.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw CheckError(description: "could not open the private defaults suite this check writes into")
        }
        // Unique per run, and erased after it: two worktrees can run this leg at the
        // same moment, and a shared suite would have them overwriting each other's
        // fixture mid-check. Same shape as the other QA suites in this target.
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // QA never probes, so `modelOptions` is the frozen fallback and the catalogue
        // holds no display names — a tile title falls back to the id's model segment,
        // which is what the literal titles below assert.
        let live = AgentModelConfig.modelOptions
        let chosen = "openai-codex/gpt-5.6-luna"
        let configured = "openai-codex/gpt-5.6-sol"
        let reconfigured = "openai-codex/gpt-5.4-mini"
        let revealedModel = "openai-codex/gpt-5.5"
        let departed = "openai-codex/gpt-5.6-luna-retired"
        for id in [chosen, configured, reconfigured, revealedModel] {
            try expect(live.contains(id), "the QA catalogue no longer offers \(id); this witness is testing nothing")
            try expect(AgentModelCatalog.shared.displayName(for: id) == nil,
                       "a live catalogue probe ran in QA, so \(id)'s title is pi's display name and the literal titles below are wrong")
        }
        try expect(!live.contains(departed), "fixture id \(departed) must not be a real catalogue id")
        defaults.set(configured, forKey: AgentModelConfig.modelKey)
        // Not `AgentModelConfig.defaultThinking`, so a resolution that ignored these
        // defaults cannot accidentally agree with them.
        defaults.set("high", forKey: AgentModelConfig.thinkingKey)

        var refusals: [String] = []
        var wired: [(tileId: UUID, settings: AgentModelConfig.Resolution)] = []
        var composerAtWireTime: [AgentModelConfig.Resolution] = []
        // Called where production wires the agent RECORD. Reading the composer here
        // is what proves the tile was already built from this resolution — the
        // post-attach repair this replaces could only ever run later.
        func wire(_ tileId: UUID, _ settings: AgentModelConfig.Resolution) {
            if let view = canvas.tileView(for: tileId) as? ManagedAgentTileNSView {
                composerAtWireTime.append(view.qaProviderSettings)
            }
            wired.append((tileId, settings))
        }

        // MARK: 1 · a model that left the catalogue while ⌘K was open builds NOTHING

        let refused = spawner.spawnManagedAgentForSelectedModel(
            departed,
            defaults: defaults,
            announceRefusal: { refusals.append($0) },
            wire: wire)
        guard case let .refusedModel(refusedID) = refused, refusedID == departed else {
            throw CheckError(description: "a model outside the live catalogue must be REFUSED, never substituted: \(refused)")
        }
        try expect(canvas.canvasState.tiles.isEmpty,
                   "a refused model still built \(canvas.canvasState.tiles.count) tile(s); refusing must leave nothing behind")
        let persistedAfterRefusal = try store.loadCanvas().tiles
        try expect(persistedAfterRefusal.isEmpty,
                   "a refused model persisted \(persistedAfterRefusal.count) tile(s) into the project canvas")
        try expect(wired.isEmpty, "a refused model still wired an agent record: \(wired)")
        try expect(refusals.count == 1 && refusals[0].contains(departed),
                   "a refused model must SAY so and name the model — ⌘K dispatches and closes whatever the result, so a silent refusal is a keystroke that does nothing at all: \(refusals)")

        // …and a partial id, which `--model` would fuzzy-match onto whichever model
        // the provider picked, is refused by the same guard (P0.10).
        let partial = spawner.spawnManagedAgentForSelectedModel(
            "openai-codex/gpt-5.6",
            defaults: defaults,
            announceRefusal: { refusals.append($0) },
            wire: wire)
        guard case .refusedModel = partial else {
            throw CheckError(description: "a partial id must be refused, not handed to a --model pattern match: \(partial)")
        }
        try expect(canvas.canvasState.tiles.isEmpty && wired.isEmpty,
                   "a refused partial id built something: \(canvas.canvasState.tiles.count) tile(s), \(wired.count) record(s)")

        // MARK: 2 · the explicit choice outranks Settings and reaches everything at once

        let explicit = spawner.spawnManagedAgentForSelectedModel(
            chosen,
            defaults: defaults,
            announceRefusal: { refusals.append($0) },
            wire: wire)
        guard case let .spawned(chosenTile, chosenSettings) = explicit else {
            throw CheckError(description: "an in-catalogue explicit choice did not spawn: \(explicit)")
        }
        try expect(chosenSettings == AgentModelConfig.Resolution(model: chosen, thinking: "high"),
                   "the explicit choice did not outrank the configured default \(configured), or lost the configured thinking level: \(chosenSettings)")
        guard let chosenView = canvas.tileView(for: chosenTile) as? ManagedAgentTileNSView else {
            throw CheckError(description: "the explicit-model spawn installed no managed-agent view")
        }
        try expect(chosenView.qaProviderSettings == chosenSettings,
                   "the composer was not seeded from the explicit spawn resolution: \(chosenView.qaProviderSettings)")
        let chosenTitle = canvas.canvasState.tiles.first(where: { $0.id == chosenTile })?.title
        try expect(chosenTitle == "gpt-5.6-luna",
                   "the tile title was not seeded from the explicit spawn resolution: \(String(describing: chosenTitle))")
        try expect(wired.count == 1 && wired[0].tileId == chosenTile && wired[0].settings == chosenSettings,
                   "the agent record was not given the SAME resolution the tile was built from: \(wired)")
        try expect(composerAtWireTime == [chosenSettings],
                   "the composer did not already hold the chosen model when the record was wired — the model is being repaired after attach again, which is the bug: \(composerAtWireTime)")

        // MARK: 3 · generic creation with NO selection still comes from Settings

        // Against a literal, and against a value written HERE. Comparing
        // `resolved(selection: nil)` with `resolvedFromDefaults()` — the first draft's
        // assertion — cannot fail: the former returns the latter by construction.
        defaults.set(reconfigured, forKey: AgentModelConfig.modelKey)
        defaults.set("low", forKey: AgentModelConfig.thinkingKey)
        let generic = spawner.spawnManagedAgentForSelectedModel(
            nil,
            defaults: defaults,
            announceRefusal: { refusals.append($0) },
            wire: wire)
        guard case let .spawned(genericTile, genericSettings) = generic else {
            throw CheckError(description: "generic creation with no selection did not spawn: \(generic)")
        }
        try expect(genericSettings == AgentModelConfig.Resolution(model: reconfigured, thinking: "low"),
                   "generic creation must read Settings: expected \(reconfigured)/low, got \(genericSettings)")
        let genericTitle = canvas.canvasState.tiles.first(where: { $0.id == genericTile })?.title
        try expect(genericTitle == "gpt-5.4-mini",
                   "a generic tile was not titled from the Settings model: \(String(describing: genericTitle))")

        // MARK: 4 · a tile revealed for an EXISTING agent is titled from its record

        // Closing a tile is not deleting an agent, so revealing one from the inbox
        // gives an existing agent a new view. Spawning that view from Settings left
        // the tile titled after the configured default while `attach` put the
        // record's real model in the composer — and `tile.title` is user-visible
        // ("Jump to <title>" in ⌘K).
        let agentStore = AgentStore(
            applicationSupportDirectory: root.appendingPathComponent("app-support", isDirectory: true))
        let supervisor = AgentSupervisor(store: agentStore, warn: { _ in })
        try expect(AgentModelConfig.resolvedFromDefaults().model != revealedModel,
                   "the ambient configured default IS \(revealedModel); this witness could not tell the record from Settings")
        let revealed = supervisor.spawn(
            role: nil, prompt: nil, cwd: root, model: revealedModel, thinking: "xhigh")
        switch spawner.spawnManagedAgentForExistingAgent(revealed, supervisor: supervisor) {
        case let .spawned(revealTile):
            guard let revealView = canvas.tileView(for: revealTile) as? ManagedAgentTileNSView else {
                throw CheckError(description: "revealing an agent installed no managed-agent view")
            }
            try expect(revealView.qaProviderSettings == AgentModelConfig.Resolution(model: revealedModel, thinking: "xhigh"),
                       "a revealed agent's composer was not seeded from its own record: \(revealView.qaProviderSettings)")
            let revealTitle = canvas.canvasState.tiles.first(where: { $0.id == revealTile })?.title
            try expect(revealTitle == "gpt-5.5",
                       "a revealed agent's tile was titled from Settings rather than from its own record: \(String(describing: revealTitle))")
        case let .failure(error):
            throw CheckError(description: "revealing an existing agent failed to spawn a tile: \(error)")
        }

        try expect(refusals.count == 2,
                   "an accepted spawn spoke a refusal: \(refusals)")

        // MARK: 5 · and production still goes through both witnessed seams

        let paletteBody = try appDelegateMethodBody(
            "private func spawnManagedAgentFromPalette(model: String? = nil) -> Bool {")
        try expect(paletteBody.contains("spawnManagedAgentForSelectedModel("),
                   "⌘K's spawn no longer routes through the seam every rule above is witnessed on:\n\(paletteBody)")
        let revealBody = try appDelegateMethodBody(
            "private func attachTileToAgentFromInbox(_ agentId: AgentID) -> UUID? {")
        try expect(revealBody.contains("spawnManagedAgentForExistingAgent("),
                   "revealing an agent no longer routes through the seam, so its tile is titled from Settings again:\n\(revealBody)")
    }

    /// The body of one `AppDelegate` method, comments stripped, bounded by the closing
    /// brace at the method's own four-space indentation. Same mechanism and same
    /// reason as `paletteAgentSpawnBranch` in AgentSupervisor.swift: those methods
    /// need a live app to execute. A signature that no longer matches THROWS rather
    /// than reading as a pass — a blind scan is worse than no scan.
    private static func appDelegateMethodBody(_ signature: String) throws -> String {
        struct ScanError: Error, CustomStringConvertible { let description: String }
        let path = "Sources/ContinuumRevived/App/ContinuumApp.swift"
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(path)
        guard let source = try? String(contentsOf: url, encoding: .utf8) else {
            throw ScanError(description: "could not read \(path) — run this check from the repo root")
        }
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == signature }) else {
            throw ScanError(description: "no `\(signature)` in \(path) — it was renamed or removed, and this scan is now blind")
        }
        var body: [String] = []
        for line in lines[(start + 1)...] {
            if line == "    }" { break }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") { continue }
            body.append(line)
        }
        guard !body.isEmpty else {
            throw ScanError(description: "`\(signature)` scanned as an empty body")
        }
        return body.joined(separator: "\n")
    }

    // MARK: - Note tiles

    /// Spawns a new blank note tile. Creates the note body file and index entry,
    /// installs the tile view, and persists the canvas state.
    func spawnNote(title: String, at worldPoint: CGPoint? = nil) -> NoteOutcome {
        guard let canvasView else { return .failure(SpawnError.canvasUnavailable) }
        let noteId = UUID()
        let tileId = UUID()
        let frame = makePlacement(
            worldPoint: worldPoint,
            size: CanvasEngine.defaultFrame(for: .note),
            in: canvasView
        )
        let nextZ = CanvasEngine.zPositionAbove(canvasView.canvasState.tiles)
        let tile = Tile(
            id: tileId,
            kind: .note,
            title: title,
            frame: frame,
            zPosition: nextZ,
            runtimeRef: nil,
            metadata: TileMetadata(noteId: noteId)
        )
        do {
            try projectStore.saveNoteBody(id: noteId, text: "")
            try upsertNoteTile(noteId: noteId, tileId: tileId, title: title)
        } catch {
            return .failure(error)
        }
        let view = NoteTileNSView(tile: tile, noteId: noteId, initialBody: "")
        view.onTextChange = { [weak self] in self?.notePersistenceHandler?() }
        canvasView.install(tileView: view, for: tile)
        do {
            try projectStore.saveCanvas(canvasView.canvasState)
        } catch {
            return .failure(error)
        }
        return .spawned(noteId: noteId, tileId: tileId)
    }

    /// Installs a note tile view for an existing `Tile` (e.g. canvas restore).
    /// If old canvas data lacks a note id, a note id is generated and persisted.
    func installNoteTile(_ tile: Tile, in canvasView: CanvasNSView) {
        let noteId: UUID
        var activeTile = tile
        if let existingNoteId = tile.metadata.noteId {
            noteId = existingNoteId
        } else {
            noteId = UUID()
            activeTile.metadata = TileMetadata(
                launchProfileId: tile.metadata.launchProfileId,
                projectRelativeCwd: tile.metadata.projectRelativeCwd,
                url: tile.metadata.url,
                noteId: noteId,
                filePath: tile.metadata.filePath
            )
            canvasView.updateTile(activeTile)
            try? upsertNoteTile(noteId: noteId, tileId: tile.id, title: tile.title)
            try? projectStore.saveCanvas(canvasView.canvasState)
        }
        let initialBody = projectStore.tryLoadNoteBody(id: noteId) ?? ""
        let view = NoteTileNSView(tile: activeTile, noteId: noteId, initialBody: initialBody)
        view.onTextChange = { [weak self] in self?.notePersistenceHandler?() }
        canvasView.install(tileView: view, for: activeTile)
    }

    /// Writes the current text body and updates the note's `updatedAt` timestamp.
    func writeNoteSnapshot(noteId: UUID, tileId: UUID, text: String) {
        try? projectStore.saveNoteBody(id: noteId, text: text)
        guard var state = try? projectStore.loadNoteState(),
              let idx = state.tiles.firstIndex(where: { $0.id == noteId && $0.tileId == tileId })
        else { return }
        state.tiles[idx].updatedAt = Date()
        try? projectStore.saveNoteState(state)
    }

    private func upsertNoteTile(noteId: UUID, tileId: UUID, title: String) throws {
        var state = (try? projectStore.tryLoadNoteState()) ?? NoteState(tiles: [])
        let now = Date()
        if let idx = state.tiles.firstIndex(where: { $0.id == noteId }) {
            state.tiles[idx].title = title
            state.tiles[idx].updatedAt = now
        } else {
            state.tiles.append(NoteTile(
                id: noteId,
                tileId: tileId,
                filename: "\(noteId.uuidString).md",
                title: title,
                createdAt: now,
                updatedAt: now
            ))
        }
        try projectStore.saveNoteState(state)
    }

    // MARK: - File tiles

    /// Set by `AppDelegate` so a file-tree activation or a canvas drop routes
    /// through the one active-context open action (`WorkspaceRuntime.openProjectFile`)
    /// instead of calling back into whichever spawner instance happened to wire the
    /// tile. Nil in checks that drive a spawner directly.
    var fileOpenHandler: ((String, CGPoint?) -> Void)?

    /// Spawns a read-only file preview tile and persists the canvas state.
    func spawnFile(path: String, title: String? = nil, at worldPoint: CGPoint? = nil) -> FileOutcome {
        spawnFile(path: path, title: title, at: worldPoint, beside: nil)
    }

    /// Opens the file gap-adjacent to an existing tile, or focuses it in place when
    /// it is already open.
    func spawnFile(path: String, title: String? = nil, beside anchorTileId: UUID) -> FileOutcome {
        spawnFile(path: path, title: title, at: nil, beside: anchorTileId)
    }

    /// Gap between an anchor tile and the file tile docked beside it.
    static let anchoredFileGap: Double = 24

    private func spawnFile(
        path: String,
        title: String?,
        at worldPoint: CGPoint?,
        beside anchorTileId: UUID?
    ) -> FileOutcome {
        guard let canvasView else { return .failure(SpawnError.canvasUnavailable) }
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else { return .invalidPath }
        // One canonical spelling per file, so "already open" is decidable and the
        // persisted metadata does not depend on how the path was authored.
        let canonicalPath = URL(fileURLWithPath: trimmedPath).standardizedFileURL.resolvingSymlinksInPath().path

        let siblings = canvasView.projectTiles()
        if let existing = siblings.first(where: { $0.kind == .file && $0.metadata.filePath == canonicalPath }) {
            return .alreadyOpen(tileId: existing.id)
        }

        let size = CanvasEngine.defaultFrame(for: .file)
        let anchor = anchorTileId.flatMap { id in siblings.first(where: { $0.id == id }) }
        let frame: TileFrame
        if let anchor {
            frame = Self.anchoredFrame(size: size, anchor: anchor.frame, siblings: siblings)
        } else {
            frame = makeProjectTilePlacement(worldPoint: worldPoint, size: size, in: canvasView)
        }

        let tile = Tile(
            id: UUID(),
            kind: .file,
            title: title ?? URL(fileURLWithPath: canonicalPath).lastPathComponent,
            frame: frame,
            zPosition: CanvasEngine.zPositionAbove(siblings),
            zoneId: anchor?.zoneId,
            runtimeRef: nil,
            metadata: TileMetadata(filePath: canonicalPath)
        )
        let view = FileTileNSView(tile: tile)
        let target = canvasView.installProjectTile(tileView: view, for: tile)

        do {
            try persistProjectCanvas(after: target, in: canvasView)
        } catch {
            return .failure(error)
        }
        return .spawned(tileId: tile.id)
    }

    /// Top-aligned, `anchoredFileGap` to the right of `anchor`. Falls back to
    /// directly below when that slot already holds a tile, and to nil-driven
    /// automatic placement only when neither adjacent slot is free.
    private static func anchoredFrame(size: CGSize, anchor: TileFrame, siblings: [Tile]) -> TileFrame {
        let seed = TileFrame(x: anchor.x, y: anchor.y, width: Double(size.width), height: Double(size.height))
        let occupied = siblings.map(\.frame)
        // `TileArrangement.Direction` names the direction of TRAVEL, and the tile
        // parks on the near side of what it runs into. Travelling `.left` toward the
        // anchor therefore lands to its RIGHT, and `.up` lands directly below it.
        for direction in [TileArrangement.Direction.left, .up] {
            let candidate = TileArrangement.dockDestination(seed, direction: direction, against: anchor, gap: anchoredFileGap)
            let overlaps = occupied.contains { other in
                candidate.x < other.x + other.width && other.x < candidate.x + candidate.width &&
                    candidate.y < other.y + other.height && other.y < candidate.y + candidate.height
            }
            if !overlaps { return candidate }
        }
        return TileArrangement.dockDestination(seed, direction: .left, against: anchor, gap: anchoredFileGap)
    }

    /// Persists through the model that actually received the tile. The flat
    /// `canvasState` is only authoritative while the single-zone boot path owns the
    /// active project; once `setZones` has installed layers, the layer's tiles are.
    private func persistProjectCanvas(
        after target: CanvasNSView.ProjectTileTarget,
        in canvasView: CanvasNSView
    ) throws {
        switch target {
        case .flatCanvasState:
            try projectStore.saveCanvas(canvasView.canvasState)
        case let .zoneLayer(zoneId):
            guard let tiles = canvasView.tiles(inZone: zoneId) else { throw SpawnError.canvasUnavailable }
            var state = ((try? projectStore.tryLoadCanvas()) ?? nil) ?? CanvasState(
                viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
                tiles: [],
                groups: [],
                lastActiveTileId: nil
            )
            state.tiles = tiles
            try projectStore.saveCanvas(state)
        }
    }

    /// Installs a file tile view for an existing `Tile` during canvas restore.
    func installFileTile(_ tile: Tile, in canvasView: CanvasNSView) {
        let view = FileTileNSView(tile: tile)
        canvasView.install(tileView: view, for: tile)
    }

    /// Spawns a read-only run artifacts viewer tile and persists the canvas state.
    func spawnRunArtifacts(runDirectoryPath: String, title: String? = nil, at worldPoint: CGPoint? = nil) -> FileOutcome {
        guard let canvasView else { return .failure(SpawnError.canvasUnavailable) }
        let trimmedPath = runDirectoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else { return .invalidPath }

        let frame = makePlacement(
            worldPoint: worldPoint,
            size: CanvasEngine.defaultFrame(for: .runArtifacts),
            in: canvasView
        )
        let nextZ = CanvasEngine.zPositionAbove(canvasView.canvasState.tiles)
        let tile = Tile(
            id: UUID(),
            kind: .runArtifacts,
            title: title ?? "Run: \(URL(fileURLWithPath: trimmedPath).lastPathComponent)",
            frame: frame,
            zPosition: nextZ,
            runtimeRef: nil,
            metadata: TileMetadata(filePath: trimmedPath)
        )
        let view = RunArtifactsTileNSView(tile: tile)
        canvasView.install(tileView: view, for: tile)

        do {
            try projectStore.saveCanvas(canvasView.canvasState)
        } catch {
            return .failure(error)
        }
        return .spawned(tileId: tile.id)
    }

    /// Installs a run artifacts viewer tile for an existing `Tile` during canvas restore.
    func installRunArtifactsTile(_ tile: Tile, in canvasView: CanvasNSView) {
        let view = RunArtifactsTileNSView(tile: tile)
        canvasView.install(tileView: view, for: tile)
    }

    private func writeBrowserTabModel(tileId: UUID, runtimeId: UUID, model: BrowserTabModel, storageGroupId: String, profileId: UUID, notify: Bool = false) throws {
        var state = try loadBrowserStateIfAvailable() ?? BrowserState(tiles: [])
        let now = Date()
        if let idx = state.tiles.firstIndex(where: { $0.tileId == tileId }) {
            state.tiles[idx].tabs = model.tabs
            state.tiles[idx].activeTabId = model.activeTabId
            state.tiles[idx].storageGroupId = storageGroupId
            state.tiles[idx].profileId = profileId
            state.tiles[idx].updatedAt = now
            state.tiles[idx].withActiveTabMirrorUpdated()
        } else {
            let active = model.activeTab
            state.tiles.append(BrowserTile(id: runtimeId, tileId: tileId, url: active.url, title: active.title, storageGroupId: storageGroupId, profileId: profileId, createdAt: now, updatedAt: now, interactionState: active.interactionState, tabs: model.tabs, activeTabId: model.activeTabId))
        }
        try projectStore.saveBrowserState(state)
        if notify { browserPersistenceHandler?() }
    }

    /// Upserts a BrowserTile entry into BrowserState by tileId so multiple
    /// browser tiles in the same project don't clobber each other.
    private func upsertBrowserTile(
        runtimeId: UUID,
        tileId: UUID,
        url: String,
        title: String,
        storageGroupId: String,
        profileId: UUID,
        interactionState: Data? = nil,
        in browserState: BrowserState? = nil
    ) throws {
        var state: BrowserState
        if let browserState {
            state = browserState
        } else {
            state = try loadBrowserStateIfAvailable() ?? BrowserState(tiles: [])
        }
        let now = Date()
        if let idx = state.tiles.firstIndex(where: { $0.tileId == tileId }) {
            state.tiles[idx].storageGroupId = storageGroupId
            state.tiles[idx].profileId = profileId
            state.tiles[idx].updateActiveTab(url: url, title: title, interactionState: interactionState, now: now)
        } else {
            state.tiles.append(BrowserTile(
                id: runtimeId,
                tileId: tileId,
                url: url,
                title: title,
                storageGroupId: storageGroupId,
                profileId: profileId,
                createdAt: now,
                updatedAt: now,
                interactionState: interactionState
            ))
        }
        try projectStore.saveBrowserState(state)
    }

    /// Loads BrowserState when present. A missing file is the only condition
    /// treated as empty; corrupt/unreadable/future-schema state must surface so
    /// callers do not overwrite it from stale canvas metadata.
    private func loadBrowserStateIfAvailable() throws -> BrowserState? {
        do {
            return try projectStore.loadBrowserState()
        } catch AtomicWriterError.noValidBackup where !projectStore.browserStateFileExists() {
            return nil
        }
    }

    /// Persist the current url/title for a runtime's tile. Called by the
    /// AppDelegate's debounced flush in response to runtime state changes.
    func writeBrowserTileSnapshot(for runtime: WKWebViewBrowserRuntime) {
        try? writeBrowserTileSnapshotOrThrow(for: runtime)
    }

    func writeBrowserTileSnapshotOrThrow(for runtime: WKWebViewBrowserRuntime) throws {
        guard let canvasView,
              let tile = canvasView.canvasState.tiles.first(where: { $0.id == runtime.tileId })
        else { return }
        let persistedTile = try loadBrowserStateIfAvailable()?.tiles.first(where: { $0.tileId == tile.id })
        let profile = browserProfile(for: persistedTile?.profileId ?? tile.metadata.browserProfileId)
        let storageGroupId = persistedTile?.storageGroupId ?? profile.dataStoreIdentifier
        if let browserView = canvasView.tileView(for: runtime.tileId) as? BrowserTileNSView {
            try writeBrowserTabModel(
                tileId: tile.id,
                runtimeId: runtime.id,
                model: browserView.tabModelForBrowserStatePersistence,
                storageGroupId: storageGroupId,
                profileId: profile.id
            )
            return
        }
        let persistedTitle = persistedTile?.title
        let title = runtime.title.isEmpty ? (persistedTitle ?? runtime.title) : runtime.title
        let interactionState = runtime.capturedInteractionState
        try upsertBrowserTile(
            runtimeId: runtime.id,
            tileId: tile.id,
            url: runtime.url,
            title: title,
            storageGroupId: storageGroupId,
            profileId: profile.id,
            interactionState: interactionState
        )
    }

    static func runBrowserInspectionPolicySelfCheck() throws -> URL {
        enum CheckError: Error, CustomStringConvertible {
            case failed(String)
            var description: String { if case let .failed(message) = self { return message }; return "failed" }
        }
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw CheckError.failed(message) }
        }

        let supportsInspectableAPI: Bool
        let defaultInspectable: Bool
        let optInInspectableWhenSupported: Bool
        let optInAttemptDidNotCrash: Bool
        if #available(macOS 13.3, *) {
            supportsInspectableAPI = true
            defaultInspectable = BrowserEngineContext(inspectionPolicy: BrowserInspectionPolicy(isEnabled: false, source: "test"))
                .makeWebView(storageGroupId: BrowserState.sharedStorageGroupId).isInspectable
            optInInspectableWhenSupported = BrowserEngineContext(inspectionPolicy: BrowserInspectionPolicy(isEnabled: true, source: "test"))
                .makeWebView(storageGroupId: BrowserState.sharedStorageGroupId).isInspectable
            optInAttemptDidNotCrash = true
        } else {
            supportsInspectableAPI = false
            defaultInspectable = false
            optInInspectableWhenSupported = false
            optInAttemptDidNotCrash = true
        }
        try expect(defaultInspectable == false, "default browser inspection policy must be non-inspectable")
        if supportsInspectableAPI {
            try expect(optInInspectableWhenSupported == true, "opt-in browser inspection policy must set isInspectable on supported OS")
        }

        let suiteName = "continuum-browser-inspection-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else { throw CheckError.failed("could not create isolated defaults") }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.removeObject(forKey: BrowserInspectionPolicy.userDefaultsKey)
        let defaultPolicySource = BrowserInspectionPolicy.resolved(defaults: defaults, environment: [:]).source

        let dynamicEngine = BrowserEngineContext(inspectionPolicyProvider: {
            BrowserInspectionPolicy.resolved(defaults: defaults, environment: [:])
        })
        let dynamicDefaultInspectable: Bool
        let dynamicOptInInspectable: Bool
        let existingWebViewCanBeReappliedAfterPreferenceChange: Bool
        if #available(macOS 13.3, *) {
            let liveWebView = dynamicEngine.makeWebView(storageGroupId: BrowserState.sharedStorageGroupId)
            dynamicDefaultInspectable = liveWebView.isInspectable
            defaults.set(true, forKey: BrowserInspectionPolicy.userDefaultsKey)
            let optInWebView = dynamicEngine.makeWebView(storageGroupId: BrowserState.sharedStorageGroupId)
            dynamicOptInInspectable = optInWebView.isInspectable
            dynamicEngine.applyInspectionPolicy(to: liveWebView)
            existingWebViewCanBeReappliedAfterPreferenceChange = liveWebView.isInspectable == true
        } else {
            dynamicDefaultInspectable = false
            defaults.set(true, forKey: BrowserInspectionPolicy.userDefaultsKey)
            dynamicOptInInspectable = false
            existingWebViewCanBeReappliedAfterPreferenceChange = true
        }
        try expect(dynamicDefaultInspectable == false, "dynamic default policy must be non-inspectable")
        if supportsInspectableAPI {
            try expect(dynamicOptInInspectable == true, "dynamic defaults opt-in must set isInspectable on supported OS")
            try expect(existingWebViewCanBeReappliedAfterPreferenceChange, "existing webviews should be re-applicable after settings change")
        }

        let sections = SettingsSchema.sections()
        guard let browserSectionIndex = sections.firstIndex(where: { $0.id == "browser" }) else {
            throw CheckError.failed("Settings surface is missing Browser section")
        }
        let settingsSurfaceContainsWebInspectorToggle = sections[browserSectionIndex].fields.contains { field in
            if case .toggle(BrowserWebInspectorConfig.userDefaultsKey, "Enable Safari Web Inspector for Browser Tiles (open from Safari Develop)", BrowserWebInspectorConfig.defaultEnabled) = field {
                return true
            }
            return false
        }
        try expect(settingsSurfaceContainsWebInspectorToggle, "Settings surface is missing Safari Web Inspector toggle")
        let settingsPanel = SettingsPanel(sections: sections, defaults: defaults)
        settingsPanel.show(near: nil)
        settingsPanel.selectSectionForQA(browserSectionIndex)
        let settingsSurfaceRendered = settingsPanel.selectedSectionFieldsAllRenderedForQA()
        guard let webInspectorToggle = settingsPanel.firstToggleControlForQA() else {
            settingsPanel.close()
            throw CheckError.failed("Settings Browser section did not render a toggle")
        }
        defaults.set(false, forKey: BrowserInspectionPolicy.userDefaultsKey)
        webInspectorToggle.state = .off
        webInspectorToggle.performClick(nil)
        let settingsToggleRoundTrips = defaults.bool(forKey: BrowserInspectionPolicy.userDefaultsKey) == true
        settingsPanel.close()
        try expect(settingsSurfaceRendered, "Settings Browser section did not render controls")
        try expect(settingsToggleRoundTrips, "Settings Web Inspector toggle did not round-trip through UserDefaults")

        // Keep the target=_blank check deliberately asymmetric: defaults are false
        // while the engine policy is true. A child that re-resolves UserDefaults
        // instead of using BrowserEngineContext will fail here even though the old
        // self-check (defaults true + engine true) passed.
        defaults.set(false, forKey: BrowserInspectionPolicy.userDefaultsKey)

        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("continuum-browser-inspection-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let profile = BrowserProfile.builtInDefault()
        let project = Project(
            id: UUID(),
            name: "browser-inspection-policy-check",
            rootPath: tempRoot.path,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1),
            defaultLaunchProfileId: "shell",
            editorPreference: .auto,
            settings: ProjectSettings(restorePolicy: .restoreDescriptors, browserStoragePolicy: .perProject, terminalClosePolicy: .askWhenRunning, defaultBrowserProfileId: profile.id)
        )
        let store = ProjectStore(projectRoot: tempRoot)
        try store.saveProject(project)
        try store.saveCanvas(CanvasState(viewport: CanvasViewport(x: 0, y: 0, zoom: 1), tiles: [], groups: [], lastActiveTileId: nil))
        let canvas = CanvasNSView(canvasState: try store.loadCanvas())
        let fixedOptInEngine = BrowserEngineContext(inspectionPolicy: BrowserInspectionPolicy(isEnabled: true, source: "test"))
        let spawner = TileSpawner(
            canvasView: canvas,
            ghostty: nil,
            browserEngine: fixedOptInEngine,
            projectStore: store,
            project: project,
            defaults: defaults,
            browserProfiles: [profile]
        )
        let opener: WKWebViewBrowserRuntime
        switch spawner.spawnBrowser(url: "data:text/html;charset=utf-8,opener") {
        case let .spawned(runtime): opener = runtime
        case let .invalidURL(url): throw CheckError.failed("opener spawn invalid URL \(url)")
        case let .failure(error): throw error
        }
        let request = URLRequest(url: URL(string: "data:text/html;charset=utf-8,target-blank-child")!)
        let child = opener.onNewWindowRequest?(request, WKWebViewConfiguration(), WKNavigationAction(), WKWindowFeatures())
        try expect(child != nil, "target blank seam should return child webview")
        let targetBlankChildInspectableFollowsPolicy: Bool
        if #available(macOS 13.3, *) {
            targetBlankChildInspectableFollowsPolicy = child?.isInspectable == true
        } else {
            targetBlankChildInspectableFollowsPolicy = true
        }
        try expect(targetBlankChildInspectableFollowsPolicy, "target blank child should follow BrowserEngineContext inspection policy")

        let liveReapplyEvidence = try AppDelegate.runBrowserInspectionLiveReapplySelfCheck()

        let sourceRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Sources")
        var unconditionalInspectableAssignments: [String] = []
        var programmaticInspectorOpenAPIs: [String] = []
        if let enumerator = FileManager.default.enumerator(at: sourceRoot, includingPropertiesForKeys: nil) {
            for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
                let text = (try? String(contentsOf: fileURL)) ?? ""
                let relative = fileURL.path.replacingOccurrences(of: FileManager.default.currentDirectoryPath + "/", with: "")
                if text.contains("isInspectable = " + "true") { unconditionalInspectableAssignments.append(relative) }
                if text.contains("show" + "WebInspector") || text.contains("_" + "inspector") || text.contains("inspect" + "Element") {
                    programmaticInspectorOpenAPIs.append(relative)
                }
            }
        }
        try expect(unconditionalInspectableAssignments.isEmpty, "unconditional isInspectable assignments found: \(unconditionalInspectableAssignments)")
        try expect(programmaticInspectorOpenAPIs.isEmpty, "programmatic inspector APIs found: \(programmaticInspectorOpenAPIs)")

        let artifactDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("qa-runs/\(Int(Date().timeIntervalSince1970))/browser-inspection-policy", isDirectory: true)
        try FileManager.default.createDirectory(at: artifactDir, withIntermediateDirectories: true)
        let artifact = artifactDir.appendingPathComponent("manifest.json")
        let manifest: [String: Any] = [
            "check": "browser-inspection-policy",
            "supportsInspectableAPI": supportsInspectableAPI,
            "defaultInspectable": defaultInspectable,
            "optInInspectableWhenSupported": optInInspectableWhenSupported,
            "optInAttemptDidNotCrash": optInAttemptDidNotCrash,
            "dynamicDefaultInspectable": dynamicDefaultInspectable,
            "dynamicOptInInspectable": dynamicOptInInspectable,
            "existingWebViewCanBeReappliedAfterPreferenceChange": existingWebViewCanBeReappliedAfterPreferenceChange,
            "settingsSurfacePath": "Array > Settings… > Browser > Enable Safari Web Inspector for Browser Tiles (open from Safari Develop)",
            "settingsSurfaceContainsWebInspectorToggle": settingsSurfaceContainsWebInspectorToggle,
            "settingsSurfaceRendered": settingsSurfaceRendered,
            "settingsToggleRoundTrips": settingsToggleRoundTrips,
            "targetBlankChildInspectableFollowsPolicy": targetBlankChildInspectableFollowsPolicy,
            "targetBlankPolicyRegression": "engine opt-in true while defaults false",
            "liveReapplyEvidence": liveReapplyEvidence,
            "unconditionalInspectableAssignments": unconditionalInspectableAssignments,
            "programmaticInspectorOpenAPIs": programmaticInspectorOpenAPIs,
            "defaultSource": defaultPolicySource,
            "manualSafariDevelopVerification": "PENDING"
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: artifact, options: .atomic)
        return artifact
    }

    static func runBrowserTargetBlankSelfCheck() throws -> URL {
        enum CheckError: Error, CustomStringConvertible {
            case failed(String)
            var description: String { if case let .failed(message) = self { return message }; return "failed" }
        }
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw CheckError.failed(message) }
        }

        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("continuum-browser-target-blank-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let profile = BrowserProfile(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000074AA")!,
            name: "Popup Profile",
            dataStoreIdentifier: "00000000-0000-0000-0000-0000000074AB",
            createdAt: Date(timeIntervalSince1970: 74)
        )
        let project = Project(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000074FF")!,
            name: "browser-target-blank-check",
            rootPath: tempRoot.path,
            createdAt: Date(timeIntervalSince1970: 74),
            updatedAt: Date(timeIntervalSince1970: 74),
            defaultLaunchProfileId: "shell",
            editorPreference: .auto,
            settings: ProjectSettings(
                restorePolicy: .restoreDescriptors,
                browserStoragePolicy: .perProject,
                terminalClosePolicy: .askWhenRunning,
                defaultBrowserProfileId: profile.id
            )
        )
        let store = ProjectStore(projectRoot: tempRoot)
        try store.saveProject(project)
        try store.saveCanvas(CanvasState(viewport: CanvasViewport(x: 0, y: 0, zoom: 1), tiles: [], groups: [], lastActiveTileId: nil))
        let canvas = CanvasNSView(canvasState: try store.loadCanvas())
        let spawner = TileSpawner(
            canvasView: canvas,
            ghostty: nil,
            browserEngine: BrowserEngineContext(),
            projectStore: store,
            project: project,
            browserProfiles: [profile]
        )

        let opener: WKWebViewBrowserRuntime
        switch spawner.spawnBrowser(url: "data:text/html;charset=utf-8,opener") {
        case let .spawned(runtime): opener = runtime
        case let .invalidURL(url): throw CheckError.failed("opener spawn invalid URL \(url)")
        case let .failure(error): throw error
        }
        try expect(canvas.canvasState.tiles.count == 1, "opener spawn should create one browser tile")
        let request = URLRequest(url: URL(string: "data:text/html;charset=utf-8,target-blank-child")!)
        let returned = opener.onNewWindowRequest?(request, WKWebViewConfiguration(), WKNavigationAction(), WKWindowFeatures())
        try expect(returned != nil, "target blank seam should return the spawned child WKWebView")
        try expect(canvas.canvasState.tiles.count == 2, "target blank should create a second browser tile")
        let childTile = canvas.canvasState.tiles.first { $0.id != opener.tileId }
        try expect(childTile?.kind == .browser, "target blank child should be a browser tile")
        try expect(childTile?.metadata.browserProfileId == profile.id, "target blank child should inherit opener profile metadata")
        let browserState = try store.loadBrowserState()
        let childBrowserState = browserState.tiles.first { $0.tileId == childTile?.id }
        try expect(childBrowserState?.profileId == profile.id, "target blank child should persist opener profile id")
        try expect(childBrowserState?.storageGroupId == profile.dataStoreIdentifier, "target blank child should persist opener storage group")
        try expect(childBrowserState?.url.contains("target-blank-child") == true, "target blank child should persist requested URL")

        let artifactDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("qa-runs/browser-target-blank-\(Int(Date().timeIntervalSince1970))", isDirectory: true)
        try fileManager.createDirectory(at: artifactDir, withIntermediateDirectories: true)
        let artifact = artifactDir.appendingPathComponent("manifest.json")
        let payload = """
        {"check":"browser-target-blank","tileCount":\(canvas.canvasState.tiles.count),"profileId":"\(profile.id.uuidString)","storageGroupId":"\(profile.dataStoreIdentifier)","childURL":"\(childBrowserState?.url ?? "")"}
        """
        try payload.write(to: artifact, atomically: true, encoding: .utf8)
        return artifact
    }

    static func runBrowserProfilePersistenceSelfCheck() throws -> URL {
        enum CheckError: Error, CustomStringConvertible {
            case failed(String)
            var description: String {
                switch self {
                case let .failed(message): return message
                }
            }
        }
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw CheckError.failed(message) }
        }

        let profileA = BrowserProfile(
            id: UUID(),
            name: "QA Profile A",
            dataStoreIdentifier: UUID().uuidString,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let profileB = BrowserProfile(
            id: UUID(),
            name: "QA Profile B",
            dataStoreIdentifier: UUID().uuidString,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let tileA = UUID()
        let tileB = UUID()
        let state = BrowserState(tiles: [
            BrowserTile(id: UUID(), tileId: tileA, url: "https://example.test/a", title: "A", storageGroupId: profileA.dataStoreIdentifier, profileId: profileA.id, createdAt: Date(timeIntervalSince1970: 2), updatedAt: Date(timeIntervalSince1970: 3)),
            BrowserTile(id: UUID(), tileId: tileB, url: "https://example.test/b", title: "B", storageGroupId: profileB.dataStoreIdentifier, profileId: profileB.id, createdAt: Date(timeIntervalSince1970: 4), updatedAt: Date(timeIntervalSince1970: 5))
        ])
        let data = try JSONCodec.makeEncoder().encode(state)
        let decoded = try JSONCodec.makeDecoder().decode(BrowserState.self, from: data)
        try expect(decoded.tiles.first(where: { $0.tileId == tileA })?.profileId == profileA.id, "profile A id round-trips")
        try expect(decoded.tiles.first(where: { $0.tileId == tileB })?.profileId == profileB.id, "profile B id round-trips")
        try expect(decoded.tiles.first(where: { $0.tileId == tileA })?.storageGroupId != decoded.tiles.first(where: { $0.tileId == tileB })?.storageGroupId, "profiles retain isolated WK data-store identifiers")

        let legacy = """
        {"id":"\(UUID().uuidString)","tileId":"\(UUID().uuidString)","url":"https://legacy.test","title":"Legacy","storageGroupId":"\(profileA.dataStoreIdentifier)","createdAt":"1970-01-01T00:00:00Z","updatedAt":"1970-01-01T00:00:00Z"}
        """.data(using: .utf8)!
        let legacyTile = try JSONCodec.makeDecoder().decode(BrowserTile.self, from: legacy)
        try expect(legacyTile.profileId == BrowserProfile.defaultProfileId, "legacy BrowserTile without profileId decodes to Default")

        let registryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("continuum-browser-profile-registry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: registryRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: registryRoot) }
        let registryStore = RegistryStore(applicationSupportDirectory: registryRoot, retainedBackups: 1)
        var registry = Registry.empty()
        guard let createdProfile = BrowserProfilePersistenceActions.createProfile(
            named: "QA Created",
            in: &registry,
            now: Date(timeIntervalSince1970: 20)
        ) else {
            throw CheckError.failed("profile create helper accepts custom profile")
        }
        try registryStore.save(registry)
        var persistedRegistry = try registryStore.loadOrEmpty()
        try expect(persistedRegistry.settings.browserProfiles.contains(where: { $0.id == createdProfile.id && $0.name == "QA Created" }), "created profile persists to registry store")
        try expect(BrowserProfilePersistenceActions.renameProfile(id: createdProfile.id, to: "QA Created Renamed", in: &persistedRegistry), "profile rename helper accepts custom profile")
        try registryStore.save(persistedRegistry)
        persistedRegistry = try registryStore.loadOrEmpty()
        try expect(persistedRegistry.settings.browserProfiles.first(where: { $0.id == createdProfile.id })?.name == "QA Created Renamed", "renamed profile persists to registry store")

        let deletedProfile = BrowserProfilePersistenceActions.makeProfile(
            name: "QA Deleted",
            id: UUID(),
            dataStoreIdentifier: UUID().uuidString,
            createdAt: Date(timeIntervalSince1970: 21)
        )
        try expect(persistedRegistry.settings.upsertBrowserProfile(deletedProfile), "delete fixture profile is present before delete")
        let rewriteTileId = UUID()
        let rewriteCanvasOnlyTileId = UUID()
        let deleteRewriteURLString = "https://profile-delete-rewrite.test/"
        var rewriteBrowserState: BrowserState? = BrowserState(tiles: [
            BrowserTile(id: UUID(), tileId: rewriteTileId, url: deleteRewriteURLString, title: "Deleted Profile Tile", storageGroupId: deletedProfile.dataStoreIdentifier, profileId: deletedProfile.id, createdAt: Date(timeIntervalSince1970: 22), updatedAt: Date(timeIntervalSince1970: 22))
        ])
        var rewriteCanvasState: CanvasState? = CanvasState(viewport: CanvasViewport(x: 0, y: 0, zoom: 1), tiles: [
            Tile(id: rewriteTileId, kind: .browser, title: "Deleted Profile Tile", frame: TileFrame(x: 0, y: 0, width: 800, height: 600), zPosition: .fromLegacyRank(0), runtimeRef: nil, metadata: TileMetadata(url: deleteRewriteURLString, browserProfileId: deletedProfile.id)),
            Tile(id: rewriteCanvasOnlyTileId, kind: .browser, title: "Canvas Only", frame: TileFrame(x: 10, y: 10, width: 800, height: 600), zPosition: .fromLegacyRank(1), runtimeRef: nil, metadata: TileMetadata(url: deleteRewriteURLString, browserProfileId: deletedProfile.id))
        ], groups: [], lastActiveTileId: rewriteTileId)
        let deleteRewrite = BrowserProfilePersistenceActions.deleteProfile(
            id: deletedProfile.id,
            in: &persistedRegistry,
            browserState: &rewriteBrowserState,
            canvasState: &rewriteCanvasState,
            now: Date(timeIntervalSince1970: 23)
        )
        try expect(deleteRewrite.registryDeleted, "profile delete helper removes custom profile")
        try registryStore.save(persistedRegistry)
        persistedRegistry = try registryStore.loadOrEmpty()
        try expect(!persistedRegistry.settings.browserProfiles.contains(where: { $0.id == deletedProfile.id }), "deleted profile is absent after registry store reload")
        try expect(rewriteBrowserState?.tiles.first(where: { $0.tileId == rewriteTileId })?.profileId == BrowserProfile.defaultProfileId, "delete rewrite falls persisted browser tile back to Default profile")
        try expect(rewriteBrowserState?.tiles.first(where: { $0.tileId == rewriteTileId })?.storageGroupId == BrowserProfile.defaultDataStoreIdentifier, "delete rewrite falls persisted browser tile storage group back to Default")
        try expect(rewriteCanvasState?.tiles.first(where: { $0.id == rewriteTileId })?.metadata.browserProfileId == BrowserProfile.defaultProfileId, "delete rewrite falls canvas browser tile back to Default profile")
        try expect(rewriteCanvasState?.tiles.first(where: { $0.id == rewriteCanvasOnlyTileId })?.metadata.browserProfileId == BrowserProfile.defaultProfileId, "delete rewrite covers canvas-only existing browser tile")
        var defaultDeleteBrowserState: BrowserState? = nil
        var defaultDeleteCanvasState: CanvasState? = nil
        let defaultDelete = BrowserProfilePersistenceActions.deleteProfile(id: BrowserProfile.defaultProfileId, in: &persistedRegistry, browserState: &defaultDeleteBrowserState, canvasState: &defaultDeleteCanvasState)
        try expect(!defaultDelete.registryDeleted, "profile delete refuses Default")

        func runLoopUntil(_ done: @autoclosure () -> Bool, timeout: TimeInterval = 5) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while !done(), Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }
            return done()
        }
        let fixtureBaseURL = FileManager.default.temporaryDirectory.appendingPathComponent("continuum-profile-check-origin", isDirectory: true)
        try? FileManager.default.createDirectory(at: fixtureBaseURL, withIntermediateDirectories: true)
        let fixtureURL = fixtureBaseURL.appendingPathComponent("index.html")
        try "<html><body>profile fixture</body></html>".data(using: .utf8)!.write(to: fixtureURL, options: .atomic)
        func loadFixture(_ webView: WKWebView) throws {
            webView.loadFileURL(fixtureURL, allowingReadAccessTo: fixtureBaseURL)
            try expect(runLoopUntil(!webView.isLoading), "fixture page loads")
        }
        func eval(_ js: String, in webView: WKWebView) throws -> Any? {
            var done = false
            var value: Any?
            var evalError: Error?
            webView.evaluateJavaScript(js) { result, error in
                value = result
                evalError = error
                done = true
            }
            try expect(runLoopUntil(done), "JS evaluation completes for \(js)")
            if let evalError { throw evalError }
            return value
        }

        let dataStoreA = WKWebsiteDataStore(forIdentifier: UUID(uuidString: profileA.dataStoreIdentifier)!)
        let dataStoreB = WKWebsiteDataStore(forIdentifier: UUID(uuidString: profileB.dataStoreIdentifier)!)
        let configA1 = WKWebViewConfiguration()
        configA1.websiteDataStore = dataStoreA
        var webView: WKWebView? = WKWebView(frame: .zero, configuration: configA1)
        try loadFixture(webView!)
        _ = try eval("localStorage.setItem('continuumProfileCheck','profile-a'); localStorage.getItem('continuumProfileCheck')", in: webView!)
        webView = nil

        let configA2 = WKWebViewConfiguration()
        configA2.websiteDataStore = dataStoreA
        let restoredA = WKWebView(frame: .zero, configuration: configA2)
        try loadFixture(restoredA)
        let restoredValue = try eval("localStorage.getItem('continuumProfileCheck')", in: restoredA) as? String
        try expect(restoredValue == "profile-a", "profile A localStorage persists across web view recreation")

        let configB = WKWebViewConfiguration()
        configB.websiteDataStore = dataStoreB
        let isolatedB = WKWebView(frame: .zero, configuration: configB)
        try loadFixture(isolatedB)
        let isolatedValue = try eval("localStorage.getItem('continuumProfileCheck')", in: isolatedB) as? String
        try expect(isolatedValue == nil, "profile B localStorage is isolated from profile A")

        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("continuum-browser-profile-switch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let now = Date(timeIntervalSince1970: 10)
        let project = Project(
            id: UUID(),
            name: "browser-profile-switch-check",
            rootPath: tempRoot.path,
            createdAt: now,
            updatedAt: now,
            defaultLaunchProfileId: "shell",
            editorPreference: .auto,
            settings: ProjectSettings(
                restorePolicy: .restoreDescriptors,
                browserStoragePolicy: .perProject,
                terminalClosePolicy: .askWhenRunning
            )
        )
        let store = ProjectStore(projectRoot: tempRoot)
        try store.saveProject(project)
        let switchTileId = UUID()
        try store.saveCanvas(CanvasState(viewport: CanvasViewport(x: 0, y: 0, zoom: 1), tiles: [
            Tile(
                id: switchTileId,
                kind: .browser,
                title: "Browser",
                frame: TileFrame(x: 0, y: 0, width: 800, height: 600),
                zPosition: .fromLegacyRank(0),
                runtimeRef: nil,
                metadata: TileMetadata(url: fixtureURL.absoluteString, browserProfileId: profileA.id)
            )
        ], groups: [], lastActiveTileId: switchTileId))
        try store.saveBrowserState(BrowserState(tiles: [
            BrowserTile(id: UUID(), tileId: switchTileId, url: fixtureURL.absoluteString, title: "Browser", storageGroupId: profileA.dataStoreIdentifier, profileId: profileA.id, createdAt: now, updatedAt: now)
        ]))
        let switchCanvas = CanvasNSView(canvasState: try store.loadCanvas())
        let switchEngine = BrowserEngineContext()
        defer { switchEngine.shutdown() }
        let spawner = TileSpawner(
            canvasView: switchCanvas,
            ghostty: nil,
            browserEngine: switchEngine,
            projectStore: store,
            project: project,
            browserProfiles: [profileA, profileB]
        )
        let restarted: WKWebViewBrowserRuntime
        switch spawner.restartBrowserTile(tileId: switchTileId) {
        case let .restarted(runtime): restarted = runtime
        case let .invalidURL(url): throw CheckError.failed("app seam rejected fixture URL: \(url)")
        case .tileNotFound: throw CheckError.failed("app seam tile missing before switch")
        case let .failure(error): throw error
        }
        let oldRuntimeId = restarted.id
        var switchRuntimeReplaced = false
        switch spawner.switchBrowserTileProfile(tileId: switchTileId, profileId: profileB.id) {
        case let .switched(oldRuntimeId: oldId, newRuntime):
            try expect(oldId == oldRuntimeId, "profile switch reports replaced runtime id")
            switchRuntimeReplaced = newRuntime.id != oldRuntimeId
            try expect(switchRuntimeReplaced, "profile switch creates a new runtime")
            newRuntime.terminate(policy: .requestClose)
        case let .unknownProfile(id): throw CheckError.failed("app seam unknown profile: \(id)")
        case let .invalidURL(url): throw CheckError.failed("app seam rejected switch URL: \(url)")
        case .tileNotFound: throw CheckError.failed("app seam tile missing during switch")
        case let .failure(error): throw error
        }
        let switchedTile = try store.loadBrowserState().tiles.first(where: { $0.tileId == switchTileId })
        try expect(switchedTile?.profileId == profileB.id, "app seam persists selected profile id")
        try expect(switchedTile?.storageGroupId == profileB.dataStoreIdentifier, "app seam persists selected storage group")
        try expect(switchCanvas.canvasState.tiles.first(where: { $0.id == switchTileId })?.metadata.browserProfileId == profileB.id, "app seam updates canvas metadata profile id")

        let manifest: [String: Any] = [
            "check": "browser-profile-persistence",
            "profileAId": profileA.id.uuidString,
            "profileADataStoreIdentifier": profileA.dataStoreIdentifier,
            "profileBId": profileB.id.uuidString,
            "profileBDataStoreIdentifier": profileB.dataStoreIdentifier,
            "profileIdsRoundTrip": true,
            "dataStoresDistinct": true,
            "legacyDefaultProfileFallback": true,
            "profileCreatePersistedId": createdProfile.id.uuidString,
            "profileRenamePersistedName": persistedRegistry.settings.browserProfiles.first(where: { $0.id == createdProfile.id })?.name as Any,
            "profileDeleteRegistryAbsent": !persistedRegistry.settings.browserProfiles.contains(where: { $0.id == deletedProfile.id }),
            "profileDeleteBrowserTilesRewritten": deleteRewrite.browserTileIdsRewritten.map(\.uuidString),
            "profileDeleteCanvasTilesRewritten": deleteRewrite.canvasTileIdsRewritten.map(\.uuidString),
            "profileDeleteBrowserFallbackProfileId": rewriteBrowserState?.tiles.first(where: { $0.tileId == rewriteTileId })?.profileId.uuidString as Any,
            "profileDeleteBrowserFallbackStorageGroupId": rewriteBrowserState?.tiles.first(where: { $0.tileId == rewriteTileId })?.storageGroupId as Any,
            "profileDeleteCanvasOnlyFallbackProfileId": rewriteCanvasState?.tiles.first(where: { $0.id == rewriteCanvasOnlyTileId })?.metadata.browserProfileId?.uuidString as Any,
            "profileALocalStorageAfterRecreate": restoredValue as Any,
            "profileBLocalStorageValue": isolatedValue as Any,
            "localStorageIsolationMeasured": isolatedValue == nil && restoredValue == "profile-a",
            "appProfileSwitchRuntimeReplaced": switchRuntimeReplaced,
            "appProfileSwitchPersistedProfileId": switchedTile?.profileId.uuidString as Any,
            "appProfileSwitchPersistedStorageGroupId": switchedTile?.storageGroupId as Any
        ]
        let fileManager = FileManager.default
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let directory = URL(fileURLWithPath: fileManager.currentDirectoryPath)
            .appendingPathComponent("qa-runs", isDirectory: true)
            .appendingPathComponent(timestamp, isDirectory: true)
            .appendingPathComponent("browser-profile-persistence", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let artifact = directory.appendingPathComponent("manifest.json")
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(to: artifact, options: .atomic)
        return artifact
    }

    static func runBrowserTabRestoreSelfCheck() throws -> URL {
        enum CheckError: Error, CustomStringConvertible {
            case failed(String)
            var description: String { if case let .failed(message) = self { return message }; return "failed" }
        }
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw CheckError.failed(message) }
        }
        func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if condition() { return true }
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.03))
            }
            return condition()
        }
        func dataPage(title: String) -> String {
            let html = "<html><head><title>\(title)</title></head><body>\(title)</body></html>"
            return "data:text/html;base64,\(Data(html.utf8).base64EncodedString())"
        }

        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("continuum-browser-tab-restore-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let now = Date()
        let project = Project(
            id: UUID(), name: "browser-tab-restore-check", rootPath: tempRoot.path,
            createdAt: now, updatedAt: now, defaultLaunchProfileId: "shell", editorPreference: .auto,
            settings: ProjectSettings(restorePolicy: .restoreDescriptors, browserStoragePolicy: .perProject, terminalClosePolicy: .askWhenRunning)
        )
        let store = ProjectStore(projectRoot: tempRoot)
        try store.saveProject(project)
        let tileId = UUID()
        let profileId = BrowserProfile.defaultProfileId
        let storageGroupId = BrowserState.storageGroupIdentifier(for: project)
        let engine = BrowserEngineContext()
        defer { engine.shutdown() }
        let interactionStateURL = dataPage(title: "Interaction Restored Tab")
        let interactionRuntime = WKWebViewBrowserRuntime(
            tileId: UUID(),
            webView: engine.makeWebView(storageGroupId: storageGroupId),
            initialURL: interactionStateURL
        )
        interactionRuntime.loadURL(interactionStateURL)
        try expect(waitUntil { interactionRuntime.capturedInteractionState != nil }, "fixture interactionState should be captured from a real WKWebView")
        let capturedInactiveInteractionState = interactionRuntime.capturedInteractionState
        interactionRuntime.terminate(policy: .force)

        var tabs = (0..<20).map { idx in
            BrowserTab(
                id: UUID(),
                url: dataPage(title: "tab-\(idx)"),
                title: idx == 7 ? "Active Restored Tab" : "Restored Tab \(idx)",
                faviconURL: nil,
                createdAt: now.addingTimeInterval(Double(idx)),
                lastAccessedAt: now.addingTimeInterval(Double(idx)),
                interactionState: nil
            )
        }
        tabs[12].url = interactionStateURL
        tabs[12].title = "Interaction Restored Tab"
        tabs[12].interactionState = capturedInactiveInteractionState
        let invalidInactiveURL = "://invalid-restored-tab"
        tabs[13].url = invalidInactiveURL
        tabs[13].title = "Invalid Restored Tab"
        let activeTab = tabs[7]
        try store.saveCanvas(CanvasState(
            viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
            tiles: [Tile(id: tileId, kind: .browser, title: "canvas browser", frame: TileFrame(x: 20, y: 20, width: 640, height: 420), zPosition: .fromLegacyRank(1), runtimeRef: nil, metadata: TileMetadata(url: "about:blank"))],
            groups: [], lastActiveTileId: tileId
        ))
        try store.saveBrowserState(BrowserState(tiles: [BrowserTile(
            id: UUID(), tileId: tileId, url: activeTab.url, title: activeTab.title,
            storageGroupId: storageGroupId, profileId: profileId, createdAt: now, updatedAt: now,
            interactionState: nil, tabs: tabs, activeTabId: activeTab.id
        )]))

        let canvas = CanvasNSView(canvasState: try store.loadCanvas())
        let spawner = TileSpawner(canvasView: canvas, ghostty: nil, browserEngine: engine, projectStore: store, project: project)
        let start = Date()
        let creationsBefore = engine.webViewCreationCountForQA
        let runtime: WKWebViewBrowserRuntime
        switch spawner.restartBrowserTile(tileId: tileId) {
        case let .restarted(r): runtime = r
        case let .invalidURL(url): throw CheckError.failed("restart rejected seeded URL: \(url)")
        case .tileNotFound: throw CheckError.failed("restart did not find seeded tile")
        case let .failure(error): throw CheckError.failed("restart failed: \(error)")
        }
        let restoreDurationMs = Int(Date().timeIntervalSince(start) * 1000)
        let creationsAtBoot = engine.webViewCreationCountForQA - creationsBefore
        guard let view = canvas.tileView(for: tileId) as? BrowserTileNSView else { throw CheckError.failed("restored BrowserTileNSView missing") }
        let snapshot = view.restoredTabSnapshotForQA
        let inactive = tabs[12]
        view.selectTabForQA(tabId: inactive.id)
        let interactionStateRestoreInvoked = view.lastTabActivationUsedInteractionStateForQA
        try spawner.writeBrowserTileSnapshotOrThrow(for: runtime)
        let postSwitchState = try store.loadBrowserState()
        let postSwitchTile = postSwitchState.tiles.first(where: { $0.tileId == tileId })
        let switchUpdated = postSwitchTile?.activeTabId == inactive.id && postSwitchTile?.url == inactive.url

        let invalidInactive = tabs[13]
        view.selectTabForQA(tabId: invalidInactive.id)
        let invalidInactiveTabFallbackUsed = view.activeTabURLForQA == DefaultBrowserURL.fallback
            && view.lastInvalidTabURLFallbackForQA == invalidInactiveURL
        try spawner.writeBrowserTileSnapshotOrThrow(for: runtime)
        let postInvalidTile = try store.loadBrowserState().tiles.first(where: { $0.tileId == tileId })
        let invalidInactiveFallbackPersisted = postInvalidTile?.activeTabId == invalidInactive.id
            && postInvalidTile?.url == DefaultBrowserURL.fallback

        let invalidActiveTileId = UUID()
        let invalidActiveURL = "://invalid-active-restored-tab"
        let invalidActiveTile = Tile(
            id: invalidActiveTileId,
            kind: .browser,
            title: "Invalid Active Browser",
            frame: TileFrame(x: 700, y: 20, width: 640, height: 420),
            zPosition: .fromLegacyRank(2),
            runtimeRef: nil,
            metadata: TileMetadata(url: invalidActiveURL)
        )
        canvas.install(tileView: DescriptorTileNSView(tile: invalidActiveTile), for: invalidActiveTile)
        let invalidActiveTab = BrowserTab(id: UUID(), url: invalidActiveURL, title: "Invalid Active", createdAt: now, lastAccessedAt: now)
        var invalidActiveState = try store.loadBrowserState()
        invalidActiveState.tiles.append(BrowserTile(
            id: UUID(), tileId: invalidActiveTileId, url: invalidActiveURL, title: "Invalid Active",
            storageGroupId: storageGroupId, profileId: profileId, createdAt: now, updatedAt: now,
            tabs: [invalidActiveTab], activeTabId: invalidActiveTab.id
        ))
        try store.saveBrowserState(invalidActiveState)
        switch spawner.restartBrowserTile(tileId: invalidActiveTileId) {
        case .restarted: break
        case let .invalidURL(url): throw CheckError.failed("invalid active restart should fall back, got invalid URL: \(url)")
        case .tileNotFound: throw CheckError.failed("invalid active restart did not find seeded tile")
        case let .failure(error): throw CheckError.failed("invalid active restart failed: \(error)")
        }
        let invalidActiveBootTile = try store.loadBrowserState().tiles.first(where: { $0.tileId == invalidActiveTileId })
        let invalidActiveBootFallbackUsed = invalidActiveBootTile?.url == DefaultBrowserURL.fallback

        let legacyTile = BrowserTile(id: UUID(), tileId: UUID(), url: "https://legacy.example/", title: "Legacy", storageGroupId: storageGroupId, profileId: profileId, createdAt: now, updatedAt: now)
        let legacyOneTabMigrationStillWorks = legacyTile.tabs.count == 1 && legacyTile.activeTab.url == "https://legacy.example/"
        let invalidActive = BrowserTile(id: UUID(), tileId: UUID(), url: tabs[0].url, title: tabs[0].title, storageGroupId: storageGroupId, profileId: profileId, createdAt: now, updatedAt: now, tabs: Array(tabs.prefix(3)), activeTabId: UUID())
        let invalidActiveTabFallbackUsed = invalidActive.activeTabId == tabs[0].id

        let manifest: [String: Any] = [
            "check": "browser-tab-restore",
            "seededTabCount": tabs.count,
            "restoredTabCount": snapshot.count,
            "activeTabURL": snapshot.activeURL,
            "activeTabTitle": snapshot.activeTitle,
            "webViewCreationCountAtBoot": creationsAtBoot,
            "browserRuntimeCountAtBoot": creationsAtBoot,
            "inactiveTabsHydratedAtBoot": max(0, creationsAtBoot - 1),
            "switchInactiveUpdatedActiveTab": switchUpdated,
            "inactiveInteractionStateRestoredOnSelection": interactionStateRestoreInvoked,
            "invalidInactiveTabFallbackUsed": invalidInactiveTabFallbackUsed,
            "invalidInactiveFallbackPersisted": invalidInactiveFallbackPersisted,
            "invalidActiveBootFallbackUsed": invalidActiveBootFallbackUsed,
            "invalidTabFallbackURL": DefaultBrowserURL.fallback,
            "invalidTabErrorNote": "Malformed restored tab URLs are repaired to about:blank instead of loading the previous active tab URL.",
            "legacyOneTabMigrationStillWorks": legacyOneTabMigrationStillWorks,
            "invalidActiveTabFallbackUsed": invalidActiveTabFallbackUsed,
            "usedTileSpawnerRestartBrowserTile": true,
            "restoredBrowserTileNSView": true,
            "seedStatePath": store.layout.browserFile.path,
            "profileIdPreserved": postSwitchTile?.profileId == profileId,
            "storageGroupIdPreserved": postSwitchTile?.storageGroupId == storageGroupId,
            "restoreDurationMs": restoreDurationMs,
            "restoreDurationWithinBudget": restoreDurationMs < 2000
        ]
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let directory = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("qa-runs", isDirectory: true).appendingPathComponent(timestamp, isDirectory: true).appendingPathComponent("browser-tab-restore", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let artifact = directory.appendingPathComponent("manifest.json")
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(to: artifact, options: .atomic)

        try expect(snapshot.count == 20, "restored tab strip should expose all 20 tabs")
        try expect(snapshot.activeTabId == activeTab.id, "seeded active tab should remain active")
        try expect(snapshot.activeURL == activeTab.url && snapshot.activeTitle == activeTab.title, "active URL/title should be restored")
        try expect(creationsAtBoot == 1, "restore should create exactly one WKWebView")
        try expect(switchUpdated, "switching inactive restored tab should persist active tab")
        try expect(interactionStateRestoreInvoked, "selecting inactive restored tab with interactionState should use restore path")
        try expect(invalidInactiveTabFallbackUsed, "invalid inactive restored tab URL should fall back to about:blank")
        try expect(invalidInactiveFallbackPersisted, "invalid inactive restored tab fallback should persist")
        try expect(invalidActiveBootFallbackUsed, "invalid active restored tab URL should fall back at boot")
        try expect(legacyOneTabMigrationStillWorks, "legacy one-page BrowserState should still migrate")
        try expect(invalidActiveTabFallbackUsed, "invalid active tab id should fall back to first tab")
        try expect(postSwitchTile?.profileId == profileId && postSwitchTile?.storageGroupId == storageGroupId, "profile/storage group should be preserved")
        try expect(restoreDurationMs < 2000, "20-tab restore exceeded budget")
        return artifact
    }

    static func runBrowserRestoreStateSelfCheck() throws -> URL {
        enum CheckError: Error, CustomStringConvertible {
            case failed(String)

            var description: String {
                switch self {
                case let .failed(message): return message
                }
            }
        }

        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw CheckError.failed(message) }
        }

        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("continuum-browser-restore-state-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let now = Date()
        let tileId = UUID(uuidString: "00000000-0000-0000-0000-000000000501")!
        let runtimeIdA = UUID(uuidString: "00000000-0000-0000-0000-0000000005A1")!
        let runtimeIdB = UUID(uuidString: "00000000-0000-0000-0000-0000000005B1")!
        let canvasURL = "data:text/html;charset=utf-8,<html><head><title>canvas-A</title></head><body>A</body></html>"
        let browserStateURL = "data:text/html;charset=utf-8,<html><head><title>browser-B</title></head><body>B</body></html>"
        let canvasTitle = "Canvas title A"
        let browserStateTitle = "Browser title B"

        let project = Project(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000005FF")!,
            name: "browser-restore-state-check",
            rootPath: tempRoot.path,
            createdAt: now,
            updatedAt: now,
            defaultLaunchProfileId: "shell",
            editorPreference: .auto,
            settings: ProjectSettings(
                restorePolicy: .restoreDescriptors,
                browserStoragePolicy: .perProject,
                terminalClosePolicy: .askWhenRunning
            )
        )
        let expectedStorageGroupId = BrowserState.storageGroupIdentifier(for: project)
        let store = ProjectStore(projectRoot: tempRoot)
        try store.saveProject(project)
        try store.saveCanvas(CanvasState(
            viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
            tiles: [Tile(
                id: tileId,
                kind: .browser,
                title: canvasTitle,
                frame: TileFrame(x: 20, y: 20, width: 640, height: 420),
                zPosition: .fromLegacyRank(1),
                runtimeRef: RuntimeRef(kind: .browserTile, id: runtimeIdA),
                metadata: TileMetadata(url: canvasURL)
            )],
            groups: [],
            lastActiveTileId: tileId
        ))
        try store.saveBrowserState(BrowserState(tiles: [BrowserTile(
            id: runtimeIdB,
            tileId: tileId,
            url: browserStateURL,
            title: browserStateTitle,
            storageGroupId: expectedStorageGroupId,
            createdAt: now,
            updatedAt: now
        )]))

        let canvas = CanvasNSView(canvasState: try store.loadCanvas())
        let browserEngine = BrowserEngineContext()
        let spawner = TileSpawner(
            canvasView: canvas,
            ghostty: nil,
            browserEngine: browserEngine,
            projectStore: store,
            project: project
        )
        let runtime: WKWebViewBrowserRuntime
        switch spawner.restartBrowserTile(tileId: tileId) {
        case let .restarted(created):
            runtime = created
        case let .invalidURL(url):
            throw CheckError.failed("restartBrowserTile rejected seeded URL: \(url)")
        case .tileNotFound:
            throw CheckError.failed("restartBrowserTile did not find seeded tile")
        case let .failure(error):
            throw CheckError.failed("restartBrowserTile failed: \(error)")
        }
        var runtimeToClose: WKWebViewBrowserRuntime?
        defer {
            runtimeToClose?.terminate(policy: .requestClose)
            browserEngine.shutdown()
        }

        let browserTileView = canvas.tileView(for: tileId) as? BrowserTileNSView
        let snapshotImage = NSImage(size: NSSize(width: 80, height: 60))
        snapshotImage.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 80, height: 60).fill()
        snapshotImage.unlockFocus()
        do {
            try spawner.installBrowserSnapshotTile(runtime: runtime, snapshotImage: snapshotImage)
        } catch {
            throw CheckError.failed("installBrowserSnapshotTile failed: \(error)")
        }
        let installedSnapshot = true
        let snapshotTileView = canvas.tileView(for: tileId) as? BrowserSnapshotTileNSView
        let snapshotCanvasTile = canvas.canvasState.tiles.first(where: { $0.id == tileId })
        let snapshotContainsWKWebView = snapshotTileView?.subviews.contains { subview in
            String(describing: type(of: subview)).contains("WKWebView")
        } ?? false
        let postSnapshotState = try store.loadBrowserState()
        let postSnapshotEntry = postSnapshotState.tiles.first(where: { $0.tileId == tileId })
        let rehydratedRuntime: WKWebViewBrowserRuntime
        switch spawner.restartBrowserTile(tileId: tileId) {
        case let .restarted(created):
            rehydratedRuntime = created
            runtimeToClose = created
        case let .invalidURL(url):
            throw CheckError.failed("rehydrate rejected snapshot URL: \(url)")
        case .tileNotFound:
            throw CheckError.failed("rehydrate did not find snapshotted tile")
        case let .failure(error):
            throw CheckError.failed("rehydrate failed: \(error)")
        }
        let rehydratedTileView = canvas.tileView(for: tileId) as? BrowserTileNSView
        let runtimeURL = runtime.url
        let chromeURL = browserTileView?.chromeURLStringForQA
        let tileTitle = browserTileView?.tile.title
        let canvasTileAfterBoot = try store.loadCanvas().tiles.first(where: { $0.id == tileId })
        let postBootState = try store.loadBrowserState()
        let postBootEntry = postBootState.tiles.first(where: { $0.tileId == tileId })
        let postBootURL = postBootEntry?.url
        let postBootTitle = postBootEntry?.title
        let postBootStorageGroupId = postBootEntry?.storageGroupId

        let corruptRoot = tempRoot.appendingPathComponent("corrupt-browser-state", isDirectory: true)
        try fileManager.createDirectory(at: corruptRoot, withIntermediateDirectories: true)
        let corruptProject = Project(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000006FF")!,
            name: "browser-corrupt-state-check",
            rootPath: corruptRoot.path,
            createdAt: now,
            updatedAt: now,
            defaultLaunchProfileId: "shell",
            editorPreference: .auto,
            settings: ProjectSettings(
                restorePolicy: .restoreDescriptors,
                browserStoragePolicy: .perProject,
                terminalClosePolicy: .askWhenRunning
            )
        )
        let corruptStore = ProjectStore(projectRoot: corruptRoot)
        try corruptStore.saveProject(corruptProject)
        try corruptStore.saveCanvas(CanvasState(
            viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
            tiles: [Tile(
                id: tileId,
                kind: .browser,
                title: canvasTitle,
                frame: TileFrame(x: 20, y: 20, width: 640, height: 420),
                zPosition: .fromLegacyRank(1),
                runtimeRef: RuntimeRef(kind: .browserTile, id: runtimeIdA),
                metadata: TileMetadata(url: canvasURL)
            )],
            groups: [],
            lastActiveTileId: tileId
        ))
        try fileManager.createDirectory(at: corruptStore.layout.browserDirectory, withIntermediateDirectories: true)
        let corruptSeed = Data("{ this is not valid BrowserState JSON".utf8)
        try corruptSeed.write(to: corruptStore.layout.browserFile, options: .atomic)
        let corruptCanvas = CanvasNSView(canvasState: try corruptStore.loadCanvas())
        let corruptSpawner = TileSpawner(
            canvasView: corruptCanvas,
            ghostty: nil,
            browserEngine: browserEngine,
            projectStore: corruptStore,
            project: corruptProject
        )
        let corruptRestartFailedSafely: Bool
        let corruptRestartFailureDescription: String
        switch corruptSpawner.restartBrowserTile(tileId: tileId) {
        case .restarted:
            corruptRestartFailedSafely = false
            corruptRestartFailureDescription = "unexpected restart"
        case let .invalidURL(url):
            corruptRestartFailedSafely = false
            corruptRestartFailureDescription = "unexpected invalidURL(\(url))"
        case .tileNotFound:
            corruptRestartFailedSafely = false
            corruptRestartFailureDescription = "unexpected tileNotFound"
        case let .failure(error):
            corruptRestartFailedSafely = true
            corruptRestartFailureDescription = String(describing: error)
        }
        let corruptBrowserBytesAfterRestart = try Data(contentsOf: corruptStore.layout.browserFile)
        let corruptBrowserStateUnchanged = corruptBrowserBytesAfterRestart == corruptSeed
        let corruptBrowserStateTextAfterRestart = String(decoding: corruptBrowserBytesAfterRestart, as: UTF8.self)
        let corruptCanvasURLAfterRestart = try corruptStore.loadCanvas().tiles.first(where: { $0.id == tileId })?.metadata.url
        let corruptDidNotOverwriteWithCanvasURL = !corruptBrowserStateTextAfterRestart.contains(canvasURL)

        let corruptSpawnRoot = tempRoot.appendingPathComponent("corrupt-browser-state-spawn", isDirectory: true)
        try fileManager.createDirectory(at: corruptSpawnRoot, withIntermediateDirectories: true)
        let corruptSpawnProject = Project(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000007FF")!,
            name: "browser-corrupt-state-spawn-check",
            rootPath: corruptSpawnRoot.path,
            createdAt: now,
            updatedAt: now,
            defaultLaunchProfileId: "shell",
            editorPreference: .auto,
            settings: ProjectSettings(
                restorePolicy: .restoreDescriptors,
                browserStoragePolicy: .perProject,
                terminalClosePolicy: .askWhenRunning
            )
        )
        let corruptSpawnStore = ProjectStore(projectRoot: corruptSpawnRoot)
        try corruptSpawnStore.saveProject(corruptSpawnProject)
        try corruptSpawnStore.saveCanvas(CanvasState(
            viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
            tiles: [],
            groups: [],
            lastActiveTileId: nil
        ))
        try fileManager.createDirectory(at: corruptSpawnStore.layout.browserDirectory, withIntermediateDirectories: true)
        let corruptSpawnSeed = Data("{ this corrupt BrowserState must survive spawnBrowser".utf8)
        try corruptSpawnSeed.write(to: corruptSpawnStore.layout.browserFile, options: .atomic)
        let corruptSpawnCanvas = CanvasNSView(canvasState: try corruptSpawnStore.loadCanvas())
        let corruptSpawnSpawner = TileSpawner(
            canvasView: corruptSpawnCanvas,
            ghostty: nil,
            browserEngine: browserEngine,
            projectStore: corruptSpawnStore,
            project: corruptSpawnProject
        )
        let webViewCreationsBeforeCorruptSpawn = browserEngine.webViewCreationCountForQA
        let corruptSpawnSubviewCountBefore = corruptSpawnCanvas.subviews.count
        let corruptSpawnFailedSafely: Bool
        let corruptSpawnFailureDescription: String
        switch corruptSpawnSpawner.spawnBrowser(url: canvasURL) {
        case .spawned:
            corruptSpawnFailedSafely = false
            corruptSpawnFailureDescription = "unexpected spawn"
        case let .invalidURL(url):
            corruptSpawnFailedSafely = false
            corruptSpawnFailureDescription = "unexpected invalidURL(\(url))"
        case let .failure(error):
            corruptSpawnFailedSafely = true
            corruptSpawnFailureDescription = String(describing: error)
        }
        let corruptSpawnBrowserBytesAfter = try Data(contentsOf: corruptSpawnStore.layout.browserFile)
        let corruptSpawnBrowserStateUnchanged = corruptSpawnBrowserBytesAfter == corruptSpawnSeed
        let corruptSpawnBrowserStateTextAfter = String(decoding: corruptSpawnBrowserBytesAfter, as: UTF8.self)
        let corruptSpawnCanvasAfter = try corruptSpawnStore.loadCanvas()
        let corruptSpawnCanvasTileCountAfter = corruptSpawnCanvas.canvasState.tiles.count
        let corruptSpawnPersistedCanvasTileCountAfter = corruptSpawnCanvasAfter.tiles.count
        let corruptSpawnSubviewCountAfter = corruptSpawnCanvas.subviews.count
        let corruptSpawnWebViewCreationsAfter = browserEngine.webViewCreationCountForQA
        let corruptSpawnInstalledNoTileOrRuntime = corruptSpawnCanvasTileCountAfter == 0
            && corruptSpawnPersistedCanvasTileCountAfter == 0
            && corruptSpawnSubviewCountAfter == corruptSpawnSubviewCountBefore
            && corruptSpawnWebViewCreationsAfter == webViewCreationsBeforeCorruptSpawn

        let manifest: [String: Any] = [
            "check": "browser-restore-state",
            "seedCanvasUrl": canvasURL,
            "seedCanvasTitle": canvasTitle,
            "seedBrowserStateUrl": browserStateURL,
            "seedBrowserStateTitle": browserStateTitle,
            "runtimeUrl": runtimeURL,
            "chromeUrl": chromeURL as Any,
            "tileTitle": tileTitle as Any,
            "canvasMetadataUrlAfterBoot": canvasTileAfterBoot?.metadata.url as Any,
            "postBootBrowserStateUrl": postBootURL as Any,
            "postBootBrowserStateTitle": postBootTitle as Any,
            "postBootStorageGroupId": postBootStorageGroupId as Any,
            "browserStateTileCount": postBootState.tiles.count,
            "snapshotInstalled": installedSnapshot,
            "snapshotViewPresent": snapshotTileView != nil,
            "snapshotCanvasRuntimeRefCleared": snapshotCanvasTile?.runtimeRef == nil,
            "snapshotContainsWKWebView": snapshotContainsWKWebView,
            "postSnapshotBrowserStateUrl": postSnapshotEntry?.url as Any,
            "postSnapshotBrowserStateTitle": postSnapshotEntry?.title as Any,
            "rehydratedViewPresent": rehydratedTileView != nil,
            "rehydratedRuntimeUrl": rehydratedRuntime.url,
            "corruptRestartFailedSafely": corruptRestartFailedSafely,
            "corruptRestartFailureDescription": corruptRestartFailureDescription,
            "corruptBrowserStateUnchanged": corruptBrowserStateUnchanged,
            "corruptBrowserStateTextAfterRestart": corruptBrowserStateTextAfterRestart,
            "corruptCanvasMetadataUrlAfterRestart": corruptCanvasURLAfterRestart as Any,
            "corruptDidNotOverwriteWithCanvasUrl": corruptDidNotOverwriteWithCanvasURL,
            "corruptProjectRoot": corruptRoot.path,
            "corruptSpawnFailedSafely": corruptSpawnFailedSafely,
            "corruptSpawnFailureDescription": corruptSpawnFailureDescription,
            "corruptSpawnBrowserStateUnchanged": corruptSpawnBrowserStateUnchanged,
            "corruptSpawnBrowserStateTextAfter": corruptSpawnBrowserStateTextAfter,
            "corruptSpawnCanvasTileCountAfter": corruptSpawnCanvasTileCountAfter,
            "corruptSpawnPersistedCanvasTileCountAfter": corruptSpawnPersistedCanvasTileCountAfter,
            "corruptSpawnSubviewCountBefore": corruptSpawnSubviewCountBefore,
            "corruptSpawnSubviewCountAfter": corruptSpawnSubviewCountAfter,
            "corruptSpawnWebViewCreationsBefore": webViewCreationsBeforeCorruptSpawn,
            "corruptSpawnWebViewCreationsAfter": corruptSpawnWebViewCreationsAfter,
            "corruptSpawnInstalledNoTileOrRuntime": corruptSpawnInstalledNoTileOrRuntime,
            "corruptSpawnProjectRoot": corruptSpawnRoot.path,
            "tileId": tileId.uuidString,
            "runtimeTileId": runtime.tileId.uuidString,
            "usedProductionSpawnerPath": true,
            "tempProjectRoot": tempRoot.path
        ]
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let directory = URL(fileURLWithPath: fileManager.currentDirectoryPath)
            .appendingPathComponent("qa-runs", isDirectory: true)
            .appendingPathComponent(timestamp, isDirectory: true)
            .appendingPathComponent("browser-restore-state", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let artifact = directory.appendingPathComponent("manifest.json")
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: artifact, options: .atomic)

        try expect(runtime.tileId == tileId, "runtime should reuse seeded tileId")
        try expect(runtimeURL == browserStateURL, "runtime URL should prefer BrowserState URL B over canvas URL A")
        try expect(chromeURL == browserStateURL, "browser chrome URL field should show BrowserState URL B")
        try expect(tileTitle == browserStateTitle, "tile title should use BrowserState title B")
        try expect(postBootURL == browserStateURL, "boot should not overwrite BrowserState URL B with canvas URL A")
        try expect(postBootTitle == browserStateTitle, "boot should preserve BrowserState title B")
        try expect(postBootStorageGroupId == expectedStorageGroupId, "boot should preserve expected storage group id")
        try expect(postBootState.tiles.count == 1, "boot should not create an extra BrowserState entry")
        try expect(installedSnapshot, "dehydrate should install a browser snapshot tile")
        try expect(snapshotTileView != nil, "dehydrate should replace live browser view with BrowserSnapshotTileNSView")
        try expect(snapshotCanvasTile?.runtimeRef == nil, "snapshot canvas tile should not reference a live runtime")
        try expect(!snapshotContainsWKWebView, "snapshot tile should not retain a WKWebView descendant")
        try expect(postSnapshotEntry?.url == browserStateURL, "dehydrate should persist BrowserState URL before terminating runtime")
        try expect(rehydratedTileView != nil, "rehydrate should reinstall live BrowserTileNSView")
        try expect(rehydratedRuntime.url == browserStateURL, "rehydrate should restore URL from BrowserState")
        try expect(runtimeURL != canvasURL && chromeURL != canvasURL && postBootURL != canvasURL, "URL A must not be used for runtime, chrome, or post-boot BrowserState")
        try expect(runtimeURL != Self.defaultBrowserURL && chromeURL != Self.defaultBrowserURL && postBootURL != Self.defaultBrowserURL, "default URL must not mask restore source")
        try expect(corruptRestartFailedSafely, "corrupt BrowserState should fail safely instead of restarting from canvas metadata")
        try expect(corruptBrowserStateUnchanged, "corrupt BrowserState file should remain byte-for-byte unchanged")
        try expect(corruptDidNotOverwriteWithCanvasURL, "corrupt BrowserState must not be overwritten with canvas URL A")
        try expect(corruptCanvasURLAfterRestart == canvasURL, "corrupt scenario should keep seeded canvas metadata available but unused for BrowserState rewrite")
        try expect(corruptSpawnFailedSafely, "spawnBrowser should fail safely when existing BrowserState is corrupt")
        try expect(corruptSpawnBrowserStateUnchanged, "spawnBrowser must leave corrupt BrowserState byte-for-byte unchanged")
        try expect(!corruptSpawnBrowserStateTextAfter.contains(canvasURL), "spawnBrowser must not overwrite corrupt BrowserState with requested URL")
        try expect(corruptSpawnInstalledNoTileOrRuntime, "spawnBrowser corrupt preflight failure must install no canvas tile, NSView, WKWebView, or runtime")

        return artifact
    }

    static func runNoteFileTileSpawnSelfCheck() throws -> URL {
        enum CheckError: Error, CustomStringConvertible {
            case failed(String)

            var description: String {
                switch self {
                case let .failed(message): return message
                }
            }
        }

        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw CheckError.failed(message) }
        }

        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("continuum-note-file-spawn-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let sampleFile = tempRoot.appendingPathComponent("sample.txt")
        try Data("file tile ok".utf8).write(to: sampleFile)

        let now = Date()
        let project = Project(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000008FF")!,
            name: "note-file-spawn-check",
            rootPath: tempRoot.path,
            createdAt: now,
            updatedAt: now,
            defaultLaunchProfileId: "shell",
            editorPreference: .auto,
            settings: ProjectSettings(
                restorePolicy: .restoreDescriptors,
                browserStoragePolicy: .perProject,
                terminalClosePolicy: .askWhenRunning
            )
        )
        let store = ProjectStore(projectRoot: tempRoot)
        try store.saveProject(project)
        try store.saveCanvas(CanvasState(
            viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
            tiles: [],
            groups: [],
            lastActiveTileId: nil
        ))
        let canvas = CanvasNSView(canvasState: try store.loadCanvas())
        let browserEngine = BrowserEngineContext()
        defer { browserEngine.shutdown() }
        let spawner = TileSpawner(
            canvasView: canvas,
            ghostty: nil,
            browserEngine: browserEngine,
            projectStore: store,
            project: project
        )

        let noteId: UUID
        let noteTileId: UUID
        switch spawner.spawnNote(title: "QA Note") {
        case let .spawned(createdNoteId, createdTileId):
            noteId = createdNoteId
            noteTileId = createdTileId
        case let .failure(error):
            throw CheckError.failed("spawnNote failed: \(error)")
        }
        guard let noteView = canvas.tileView(for: noteTileId) as? NoteTileNSView else {
            throw CheckError.failed("spawnNote did not install NoteTileNSView")
        }
        noteView.textView.string = "note body ok"
        spawner.writeNoteSnapshot(noteId: noteId, tileId: noteTileId, text: noteView.textView.string)

        let fileTileId: UUID
        switch spawner.spawnFile(path: sampleFile.path, title: nil) {
        case let .spawned(createdTileId):
            fileTileId = createdTileId
        case let .alreadyOpen(existingTileId):
            fileTileId = existingTileId
        case .invalidPath:
            throw CheckError.failed("spawnFile rejected valid path")
        case let .failure(error):
            throw CheckError.failed("spawnFile failed: \(error)")
        }
        guard let fileView = canvas.tileView(for: fileTileId) as? FileTileNSView else {
            throw CheckError.failed("spawnFile did not install FileTileNSView")
        }

        let canvasOnDisk = try store.loadCanvas()
        let noteState = try store.loadNoteState()
        let noteBody = store.tryLoadNoteBody(id: noteId)
        let noteTile = canvasOnDisk.tiles.first(where: { $0.id == noteTileId })
        let fileTile = canvasOnDisk.tiles.first(where: { $0.id == fileTileId })
        let noteIndex = noteState.tiles.first(where: { $0.id == noteId })

        let manifest: [String: Any] = [
            "check": "note-file-tile-spawn",
            "tempProjectRoot": tempRoot.path,
            "noteId": noteId.uuidString,
            "noteTileId": noteTileId.uuidString,
            "fileTileId": fileTileId.uuidString,
            "noteViewInstalled": true,
            "fileViewInstalled": true,
            "fileViewText": fileView.textView.string,
            "noteBody": noteBody as Any,
            "canvasTileKinds": canvasOnDisk.tiles.map { $0.kind.rawValue }
        ]
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let directory = URL(fileURLWithPath: fileManager.currentDirectoryPath)
            .appendingPathComponent("qa-runs", isDirectory: true)
            .appendingPathComponent(timestamp, isDirectory: true)
            .appendingPathComponent("note-file-tile-spawn", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let artifact = directory.appendingPathComponent("manifest.json")
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: artifact, options: .atomic)

        try expect(noteView.noteId == noteId, "NoteTileNSView should expose spawned noteId")
        try expect(noteTile?.kind == .note, "canvas should persist note tile")
        try expect(noteTile?.metadata.noteId == noteId, "canvas note metadata should persist noteId")
        try expect(noteIndex?.tileId == noteTileId, "note index should point at spawned tile")
        try expect(noteBody == "note body ok", "writeNoteSnapshot should persist note body")
        try expect(fileTile?.kind == .file, "canvas should persist file tile")
        try expect(fileTile?.metadata.filePath == sampleFile.path, "file tile metadata should persist selected path")
        try expect(fileView.textView.string == "file tile ok", "FileTileNSView should load UTF-8 preview text")

        return artifact
    }

    static func runRunArtifactsTileSelfCheck() throws -> URL {
        enum CheckError: Error, CustomStringConvertible {
            case failed(String)
            var description: String {
                switch self {
                case let .failed(message): return message
                }
            }
        }
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw CheckError.failed(message) }
        }

        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("continuum-run-artifacts-tile-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let runDir = tempRoot.appendingPathComponent("code-scout-fixture", isDirectory: true)
        try fileManager.createDirectory(at: runDir, withIntermediateDirectories: true)
        try Data("{\"id\":\"code-scout-fixture\",\"role\":\"code-scout\",\"status\":\"done\",\"task\":\"inspect CON-92\",\"cwd\":\"/tmp/project\",\"createdAt\":\"2026-06-13T00:00:00Z\",\"updatedAt\":\"2026-06-13T00:01:00Z\"}".utf8).write(to: runDir.appendingPathComponent("run.json"))
        try Data("{\"ts\":\"2026-06-13T00:00:30Z\",\"type\":\"message\"}\nnot-json\n".utf8).write(to: runDir.appendingPathComponent("events.jsonl"))
        try Data("# Final\nCON-92 fixture final output\n".utf8).write(to: runDir.appendingPathComponent("final.md"))

        let project = Project(
            id: UUID(),
            name: "run-artifacts-tile-check",
            rootPath: tempRoot.path,
            createdAt: Date(),
            updatedAt: Date(),
            defaultLaunchProfileId: "shell",
            editorPreference: .auto,
            settings: ProjectSettings(restorePolicy: .restoreDescriptors, browserStoragePolicy: .perProject, terminalClosePolicy: .askWhenRunning)
        )
        let store = ProjectStore(projectRoot: tempRoot)
        try store.saveProject(project)
        try store.saveCanvas(CanvasState(viewport: CanvasViewport(x: 0, y: 0, zoom: 1), tiles: [], groups: [], lastActiveTileId: nil))
        let canvas = CanvasNSView(canvasState: try store.loadCanvas())
        let browserEngine = BrowserEngineContext()
        defer { browserEngine.shutdown() }
        let spawner = TileSpawner(canvasView: canvas, ghostty: nil, browserEngine: browserEngine, projectStore: store, project: project)

        let tileId: UUID
        switch spawner.spawnRunArtifacts(runDirectoryPath: runDir.path) {
        case let .spawned(createdTileId): tileId = createdTileId
        case let .alreadyOpen(existingTileId): tileId = existingTileId
        case .invalidPath: throw CheckError.failed("spawnRunArtifacts rejected valid path")
        case let .failure(error): throw CheckError.failed("spawnRunArtifacts failed: \(error)")
        }
        guard let view = canvas.tileView(for: tileId) as? RunArtifactsTileNSView else {
            throw CheckError.failed("spawnRunArtifacts did not install RunArtifactsTileNSView")
        }
        let canvasOnDisk = try store.loadCanvas()
        let tile = canvasOnDisk.tiles.first(where: { $0.id == tileId })
        let rendered = view.textView.string
        try Data("{\"id\":\"code-scout-fixture\",\"role\":\"code-scout\",\"status\":\"running\",\"task\":\"inspect CON-92\",\"cwd\":\"/tmp/project\",\"createdAt\":\"2026-06-13T00:00:00Z\",\"updatedAt\":\"2026-06-13T00:02:00Z\"}".utf8).write(to: runDir.appendingPathComponent("run.json"))
        canvas.refreshRunArtifactsTiles()
        let refreshedRendered = view.textView.string

        let restoredCanvas = CanvasNSView(canvasState: canvasOnDisk)
        guard let tile else { throw CheckError.failed("canvas should persist runArtifacts tile") }
        spawner.installRunArtifactsTile(tile, in: restoredCanvas)
        let restoredView = restoredCanvas.tileView(for: tileId) as? RunArtifactsTileNSView

        let manifest: [String: Any] = [
            "check": "run-artifacts-tile",
            "tempProjectRoot": tempRoot.path,
            "runDirectory": runDir.path,
            "tileId": tileId.uuidString,
            "renderedText": rendered,
            "refreshedText": refreshedRendered,
            "canvasTileKinds": canvasOnDisk.tiles.map { $0.kind.rawValue },
            "restoredViewInstalled": restoredView != nil
        ]
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let directory = URL(fileURLWithPath: fileManager.currentDirectoryPath)
            .appendingPathComponent("qa-runs", isDirectory: true)
            .appendingPathComponent(timestamp, isDirectory: true)
            .appendingPathComponent("run-artifacts-tile", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let artifact = directory.appendingPathComponent("manifest.json")
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: artifact, options: .atomic)

        try expect(tile.kind == .runArtifacts, "canvas should persist runArtifacts tile")
        try expect(tile.metadata.filePath == runDir.path, "runArtifacts tile metadata should persist run dir path")
        try expect(rendered.contains("Run ID: code-scout-fixture"), "viewer should render run id")
        try expect(rendered.contains("Status: done"), "viewer should render status")
        try expect(refreshedRendered.contains("Status: running"), "observer refresh hook should reload runArtifacts tile content")
        try expect(rendered.contains("inspect CON-92"), "viewer should render task")
        try expect(rendered.contains("Events: 1 parsed, 1 bad"), "viewer should render event summary")
        try expect(rendered.contains("CON-92 fixture final output"), "viewer should render final.md")
        try expect(view.textView.isEditable == false && view.textView.isSelectable, "viewer text must be read-only and selectable")
        try expect(restoredView != nil, "boot-restore install should recreate RunArtifactsTileNSView")

        return artifact
    }

    static func runSpawnPlacementSelfCheck() throws -> URL {
        enum CheckError: Error, CustomStringConvertible {
            case failed(String)
            var description: String {
                switch self {
                case let .failed(message): return message
                }
            }
        }
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw CheckError.failed(message) }
        }

        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("continuum-spawn-placement-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let project = Project(
            id: UUID(),
            name: "spawn-placement-check",
            rootPath: tempRoot.path,
            createdAt: Date(),
            updatedAt: Date(),
            defaultLaunchProfileId: "shell",
            editorPreference: .auto,
            settings: ProjectSettings(restorePolicy: .restoreDescriptors, browserStoragePolicy: .perProject, terminalClosePolicy: .askWhenRunning)
        )
        let store = ProjectStore(projectRoot: tempRoot)
        try store.saveProject(project)
        let activeZone = ZonePlacement(
            zoneId: UUID(),
            projectId: project.id,
            origin: ZonePoint(x: 1000, y: 500),
            size: ZoneSize(width: 1800, height: 900),
            color: "#6E8BFF",
            collapsed: false,
            hydrationPolicy: .automatic
        )
        try store.saveCanvas(CanvasState(viewport: CanvasViewport(x: 900, y: 400, zoom: 1), tiles: [], groups: [], lastActiveTileId: nil))
        let canvas = CanvasNSView(canvasState: try store.loadCanvas(), activeZone: activeZone)
        canvas.setFrameSize(CGSize(width: 1800, height: 900))
        let browserEngine = BrowserEngineContext()
        defer { browserEngine.shutdown() }
        let spawner = TileSpawner(canvasView: canvas, ghostty: nil, browserEngine: browserEngine, projectStore: store, project: project)

        var spawnedIds: [UUID] = []
        for index in 1...4 {
            switch spawner.spawnNote(title: "Placed \(index)") {
            case let .spawned(_, tileId): spawnedIds.append(tileId)
            case let .failure(error): throw CheckError.failed("spawnNote \(index) failed: \(error)")
            }
        }
        let tiles = canvas.canvasState.tiles.filter { spawnedIds.contains($0.id) }
        try expect(tiles.count == 4, "spawn-placement check should find all 4 spawned tiles in canvas state, got \(tiles.count)")
        let rects = tiles.map { CGRect(x: $0.frame.x, y: $0.frame.y, width: $0.frame.width, height: $0.frame.height) }
        for rect in rects {
            try expect(rect.minX >= 0 && rect.minY >= 0, "spawned tile frame should be zone-local, not world-offset: \(rect)")
            try expect(rect.maxX <= activeZone.size.width && rect.maxY <= activeZone.size.height, "spawned tile frame should fit inside active zone bounds: \(rect)")
            let worldRect = rect.offsetBy(dx: activeZone.origin.x, dy: activeZone.origin.y)
            try expect(worldRect.minX >= activeZone.origin.x && worldRect.minY >= activeZone.origin.y, "rendered world frame should land inside active zone: \(worldRect)")
        }
        for i in rects.indices {
            for j in rects.indices where j > i {
                try expect(!rects[i].intersects(rects[j]), "spawned tile frames should not intersect: \(rects[i]) vs \(rects[j])")
            }
        }

        let manifest: [String: Any] = [
            "check": "spawn-placement",
            "tempProjectRoot": tempRoot.path,
            "activeZone": ["originX": activeZone.origin.x, "originY": activeZone.origin.y, "width": activeZone.size.width, "height": activeZone.size.height],
            "frames": tiles.map { ["id": $0.id.uuidString, "x": $0.frame.x, "y": $0.frame.y, "width": $0.frame.width, "height": $0.frame.height] }
        ]
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let directory = URL(fileURLWithPath: fileManager.currentDirectoryPath)
            .appendingPathComponent("qa-runs", isDirectory: true)
            .appendingPathComponent(timestamp, isDirectory: true)
            .appendingPathComponent("spawn-placement", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let artifact = directory.appendingPathComponent("manifest.json")
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: artifact, options: .atomic)
        return artifact
    }

    static func runTerminalDefaultReadabilitySelfCheck() throws -> URL {
        enum CheckError: Error, CustomStringConvertible {
            case failed(String)
            var description: String {
                switch self {
                case let .failed(message): return message
                }
            }
        }
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw CheckError.failed(message) }
        }
        func pump(_ context: GhosttyRuntimeContext, seconds: TimeInterval) throws {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                ghostty_app_tick(try context.app)
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }
        }
        func pump(_ context: GhosttyRuntimeContext, timeout: TimeInterval, until condition: () -> Bool) throws {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if condition() { return }
                try pump(context, seconds: 0.05)
            }
            throw CheckError.failed("timed out waiting for terminal readability probe")
        }
        func runProcess(_ command: String, _ arguments: [String]) throws -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: command)
            process.arguments = arguments
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }

        let fileManager = FileManager.default
        let started = Date()
        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("continuum-terminal-default-readability-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let project = Project(
            id: UUID(),
            name: "terminal-default-readability-check",
            rootPath: tempRoot.path,
            createdAt: started,
            updatedAt: started,
            defaultLaunchProfileId: "shell",
            editorPreference: .auto,
            settings: ProjectSettings(restorePolicy: .restoreDescriptors, browserStoragePolicy: .perProject, terminalClosePolicy: .askWhenRunning)
        )
        let store = ProjectStore(projectRoot: tempRoot)
        try store.saveProject(project)
        try store.saveCanvas(CanvasState(viewport: CanvasViewport(x: 0, y: 0, zoom: 1), tiles: [], groups: [], lastActiveTileId: nil))

        let defaultsSuiteName = "continuum.terminal.defaultReadability.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuiteName)!
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let context = try GhosttyRuntimeContext()
        defer { context.shutdown() }
        let browserEngine = BrowserEngineContext()
        defer { browserEngine.shutdown() }
        let canvas = CanvasNSView(canvasState: try store.loadCanvas())
        canvas.setFrameSize(CGSize(width: 1000, height: 700))
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 1000, height: 700),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = canvas
        window.orderFront(nil)
        defer { window.close() }

        let tmuxPath = TmuxLocator.resolve(defaults: defaults)
        let spawner = TileSpawner(
            canvasView: canvas,
            ghostty: context,
            browserEngine: browserEngine,
            projectStore: store,
            project: project,
            defaults: defaults
        )

        let runtime: GhosttyTerminalRuntime
        switch spawner.spawnTerminal(profileId: "shell") {
        case let .spawned(spawnedRuntime):
            runtime = spawnedRuntime
        case let .missingCommand(executable):
            throw CheckError.failed("spawnTerminal(shell) missing command: \(executable)")
        case let .notConfigured(profileId):
            throw CheckError.failed("spawnTerminal(shell) not configured: \(profileId)")
        case let .unknownProfile(id):
            throw CheckError.failed("spawnTerminal(shell) unknown profile: \(id)")
        case let .failure(error):
            throw CheckError.failed("spawnTerminal(shell) failed: \(error)")
        }

        guard let tile = canvas.canvasState.tiles.first(where: { $0.id == runtime.tileId }) else {
            throw CheckError.failed("spawned terminal tile missing from canvas state")
        }
        let expectedSize = CanvasEngine.defaultFrame(for: .terminal)
        try expect(tile.frame.width == Double(expectedSize.width) && tile.frame.height == Double(expectedSize.height), "spawned shell should use terminal default size \(expectedSize), got \(tile.frame)")
        let screenFrame = CanvasEngine.tileScreenFrame(tile.frame, viewport: canvas.viewport)
        try expect(screenFrame.minX >= -0.001 && screenFrame.minY >= -0.001, "default shell should spawn in view at zoom 1, got \(screenFrame)")
        try expect(screenFrame.maxX <= canvas.bounds.width + 0.001 && screenFrame.maxY <= canvas.bounds.height + 0.001, "default shell should fit a 1000×700 canvas at zoom 1, got \(screenFrame) in \(canvas.bounds)")
        try expect(ReadabilityPolicy.editingReliable(for: .tile(.terminal), zoom: canvas.viewport.zoom), "spawned shell starts at editable terminal zoom, got \(canvas.viewport.zoom)")

        try pump(context, seconds: 0.8)
        guard let term = runtime.qaTerminalView, let surface = term.surface else {
            throw CheckError.failed("spawned terminal surface missing")
        }
        let surfaceSize = ghostty_surface_size(surface)
        let configuredFontSize = term.qaConfiguredFontSize.map(Double.init)
        try expect(abs((configuredFontSize ?? -1) - TerminalDisplayConfig.defaultFontSize) < 0.01, "terminal surface should use readable font default \(TerminalDisplayConfig.defaultFontSize), got \(String(describing: configuredFontSize))")
        try expect(surfaceSize.columns >= 80, "default terminal should provide at least 80 columns, got \(surfaceSize.columns)")
        try expect(surfaceSize.rows >= 20, "default terminal should provide at least 20 rows, got \(surfaceSize.rows)")

        let sentinel = "a02-default-readable-ok"
        runtime.sendInput(Data("printf '\(sentinel)\\n'\n".utf8))
        try pump(context, timeout: 5.0) { runtime.visibleText().contains(sentinel) }
        let inputWorked = runtime.visibleText().contains(sentinel)

        guard let descriptor = try store.listSessions().first(where: { $0.tileId == tile.id }) else {
            throw CheckError.failed("spawned terminal session descriptor missing")
        }
        let tmuxWrapped = tmuxPath != nil && descriptor.command == tmuxPath
        if let tmuxPath {
            try expect(tmuxWrapped, "default shell should start through tmux when tmux is available at \(tmuxPath); descriptor command=\(descriptor.command)")
        }

        runtime.terminate(policy: .force)
        if let terminalTile = canvas.tileView(for: tile.id) as? TerminalTileNSView {
            terminalTile.hostView.detachRuntime()
        }
        try pump(context, seconds: 0.2)

        var tmuxCleanup: [String: Any] = ["attempted": false]
        if tmuxWrapped {
            let kill = TmuxSession.killSessionCommand(tileId: tile.id, tmuxPath: descriptor.command)
            do {
                let status = try runProcess(kill.command, kill.arguments)
                tmuxCleanup = ["attempted": true, "command": kill.command, "arguments": kill.arguments, "terminationStatus": Int(status)]
            } catch {
                tmuxCleanup = ["attempted": true, "command": kill.command, "arguments": kill.arguments, "error": String(describing: error)]
            }
        }

        let timestamp = ISO8601DateFormatter().string(from: started).replacingOccurrences(of: ":", with: "")
        let directory = URL(fileURLWithPath: fileManager.currentDirectoryPath)
            .appendingPathComponent("qa-runs", isDirectory: true)
            .appendingPathComponent(timestamp, isDirectory: true)
            .appendingPathComponent("terminal-default-readability", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let viewportManifest: [String: Any] = ["x": canvas.viewport.x, "y": canvas.viewport.y, "zoom": canvas.viewport.zoom]
        let canvasSizeManifest: [String: Any] = ["width": Double(canvas.bounds.width), "height": Double(canvas.bounds.height)]
        let tileFrameManifest: [String: Any] = ["x": tile.frame.x, "y": tile.frame.y, "width": tile.frame.width, "height": tile.frame.height]
        let screenFrameManifest: [String: Any] = ["x": Double(screenFrame.minX), "y": Double(screenFrame.minY), "width": Double(screenFrame.width), "height": Double(screenFrame.height)]
        let surfaceSizeManifest: [String: Any] = [
            "columns": Int(surfaceSize.columns),
            "rows": Int(surfaceSize.rows),
            "widthPx": Int(surfaceSize.width_px),
            "heightPx": Int(surfaceSize.height_px),
            "cellWidthPx": Int(surfaceSize.cell_width_px),
            "cellHeightPx": Int(surfaceSize.cell_height_px)
        ]
        let manifest: [String: Any] = [
            "check": "terminal-default-readability",
            "viewport": viewportManifest,
            "canvasSize": canvasSizeManifest,
            "tileFrame": tileFrameManifest,
            "screenFrame": screenFrameManifest,
            "configuredFontSize": configuredFontSize ?? NSNull(),
            "surfaceSize": surfaceSizeManifest,
            "tmuxAvailable": tmuxPath != nil,
            "tmuxWrapped": tmuxWrapped,
            "descriptorCommand": (descriptor.command as NSString).lastPathComponent,
            "descriptorArgsPrefix": Array(descriptor.args.prefix(5)),
            "inputWorked": inputWorked,
            "tmuxCleanup": tmuxCleanup
        ]
        let artifact = directory.appendingPathComponent("manifest.json")
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: artifact, options: .atomic)
        return artifact
    }

    static func runTerminalThemeFidelitySelfCheck() throws -> URL {
        enum CheckError: Error, CustomStringConvertible {
            case failed(String)
            var description: String {
                switch self {
                case let .failed(message): return message
                }
            }
        }
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw CheckError.failed(message) }
        }
        func pump(_ context: GhosttyRuntimeContext, seconds: TimeInterval) throws {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                ghostty_app_tick(try context.app)
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }
        }
        func pump(_ context: GhosttyRuntimeContext, timeout: TimeInterval, until condition: () -> Bool) throws {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if condition() { return }
                try pump(context, seconds: 0.05)
            }
            throw CheckError.failed("timed out waiting for terminal theme probe")
        }
        func runProcess(_ command: String, _ arguments: [String]) throws -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: command)
            process.arguments = arguments
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }

        let fileManager = FileManager.default
        let started = Date()
        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("continuum-terminal-theme-fidelity-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let project = Project(
            id: UUID(),
            name: "terminal-theme-fidelity-check",
            rootPath: tempRoot.path,
            createdAt: started,
            updatedAt: started,
            defaultLaunchProfileId: "shell",
            editorPreference: .auto,
            settings: ProjectSettings(restorePolicy: .restoreDescriptors, browserStoragePolicy: .perProject, terminalClosePolicy: .askWhenRunning)
        )
        let store = ProjectStore(projectRoot: tempRoot)
        try store.saveProject(project)
        try store.saveCanvas(CanvasState(viewport: CanvasViewport(x: 0, y: 0, zoom: 1), tiles: [], groups: [], lastActiveTileId: nil))

        let defaultsSuiteName = "continuum.terminal.themeFidelity.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuiteName)!
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let context = try GhosttyRuntimeContext()
        defer { context.shutdown() }
        let browserEngine = BrowserEngineContext()
        defer { browserEngine.shutdown() }
        let canvas = CanvasNSView(canvasState: try store.loadCanvas())
        canvas.setFrameSize(CGSize(width: 1000, height: 700))
        let window = NSWindow(
            contentRect: NSRect(x: 120, y: 120, width: 1000, height: 700),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = canvas
        window.orderFront(nil)
        defer { window.close() }

        let spawner = TileSpawner(
            canvasView: canvas,
            ghostty: context,
            browserEngine: browserEngine,
            projectStore: store,
            project: project,
            defaults: defaults
        )

        let runtime: GhosttyTerminalRuntime
        switch spawner.spawnTerminal(profileId: "shell") {
        case let .spawned(spawnedRuntime):
            runtime = spawnedRuntime
        case let .missingCommand(executable):
            throw CheckError.failed("spawnTerminal(shell) missing command: \(executable)")
        case let .notConfigured(profileId):
            throw CheckError.failed("spawnTerminal(shell) not configured: \(profileId)")
        case let .unknownProfile(id):
            throw CheckError.failed("spawnTerminal(shell) unknown profile: \(id)")
        case let .failure(error):
            throw CheckError.failed("spawnTerminal(shell) failed: \(error)")
        }

        guard let tile = canvas.canvasState.tiles.first(where: { $0.id == runtime.tileId }),
              let terminalTile = canvas.tileView(for: runtime.tileId) as? TerminalTileNSView
        else {
            throw CheckError.failed("spawned terminal tile missing from real canvas path")
        }
        try pump(context, seconds: 0.8)
        guard runtime.qaTerminalView?.surface != nil else {
            throw CheckError.failed("spawned terminal surface missing")
        }

        let theme = context.themeSnapshot
        guard let expectedBackground = theme.backgroundHex else {
            throw CheckError.failed("Ghostty config did not expose a resolved background color")
        }
        let tileLayerBackground = GhosttyThemeSnapshot.hexString(cgColor: terminalTile.layer?.backgroundColor)
        let hostLayerBackground = GhosttyThemeSnapshot.hexString(cgColor: terminalTile.hostView.layer?.backgroundColor)
        try expect(tileLayerBackground == expectedBackground, "terminal tile layer background should match Ghostty background \(expectedBackground), got \(String(describing: tileLayerBackground))")
        try expect(hostLayerBackground == expectedBackground, "terminal host background should match Ghostty background \(expectedBackground), got \(String(describing: hostLayerBackground))")

        guard let descriptor = try store.listSessions().first(where: { $0.tileId == tile.id }) else {
            throw CheckError.failed("spawned terminal session descriptor missing")
        }
        let tmuxPath = TmuxLocator.resolve(defaults: defaults)
        let tmuxWrapped = tmuxPath != nil && descriptor.command == tmuxPath

        let sentinel = "a06-theme-\(String(UUID().uuidString.prefix(8)))"
        let probeFile = tempRoot.appendingPathComponent("terminal-theme-probe.txt")
        let probePath = probeFile.path.replacingOccurrences(of: "'", with: "'\\''")
        let probe = """
        {
          printf '\(sentinel)-env TERM=%s COLORTERM=%s TMUX=%s\\n' "$TERM" "${COLORTERM:-}" "${TMUX:+yes}"
          if [ -n "${TMUX:-}" ] && command -v tmux >/dev/null 2>&1; then
            printf '\(sentinel)-tmux-status-style=%s\\n' "$(tmux show -gqv status-style)"
            printf '\(sentinel)-tmux-default-terminal=%s\\n' "$(tmux show -gqv default-terminal)"
            printf '\(sentinel)-tmux-terminal-overrides=%s\\n' "$(tmux show -gqv terminal-overrides)"
          fi
        } > '\(probePath)'
        """
        runtime.sendInput(Data((probe + "\n").utf8))
        var capturedProbeText = ""
        try pump(context, timeout: 8.0) {
            guard let text = try? String(contentsOf: probeFile, encoding: .utf8), text.contains("\(sentinel)-env") else { return false }
            if tmuxWrapped && !(text.contains("\(sentinel)-tmux-status-style=") && text.contains("\(sentinel)-tmux-default-terminal=")) {
                return false
            }
            capturedProbeText = text
            return true
        }
        let probeLines = capturedProbeText.components(separatedBy: .newlines).filter {
            $0.contains(sentinel)
        }
        let envLine = probeLines.first { $0.contains("-env ") } ?? ""
        try expect(envLine.contains("TERM=tmux-256color"), "theme fidelity shell should report TERM=tmux-256color, got: \(envLine)")
        try expect(envLine.contains("COLORTERM=truecolor"), "theme fidelity shell should report COLORTERM=truecolor, got: \(envLine)")
        if tmuxWrapped {
            try expect(envLine.contains("TMUX=yes"), "tmux-wrapped shell should report TMUX=yes in the real terminal path, got: \(envLine)")
            let defaultTerminalLine = probeLines.first { $0.contains("-tmux-default-terminal=") } ?? ""
            try expect(defaultTerminalLine.contains("tmux-256color"), "tmux default-terminal should be tmux-256color, got: \(defaultTerminalLine)")
            try expect(probeLines.contains(where: { $0.contains("-tmux-status-style=") }), "tmux status-style should be captured from the real pane")
        }
        try expect(theme.foregroundHex != nil, "Ghostty config should expose a resolved foreground color")
        try expect(theme.paletteHex.count >= 16, "Ghostty config should expose at least ANSI palette colors 0-15")

        runtime.terminate(policy: .force)
        terminalTile.hostView.detachRuntime()
        try pump(context, seconds: 0.2)

        var tmuxCleanup: [String: Any] = ["attempted": false]
        if tmuxWrapped {
            let kill = TmuxSession.killSessionCommand(tileId: tile.id, tmuxPath: descriptor.command)
            do {
                let status = try runProcess(kill.command, kill.arguments)
                tmuxCleanup = ["attempted": true, "command": kill.command, "arguments": kill.arguments, "terminationStatus": Int(status)]
            } catch {
                tmuxCleanup = ["attempted": true, "command": kill.command, "arguments": kill.arguments, "error": String(describing: error)]
            }
        }

        let timestamp = ISO8601DateFormatter().string(from: started).replacingOccurrences(of: ":", with: "")
        let directory = URL(fileURLWithPath: fileManager.currentDirectoryPath)
            .appendingPathComponent("qa-runs", isDirectory: true)
            .appendingPathComponent(timestamp, isDirectory: true)
            .appendingPathComponent("terminal-theme-fidelity", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "check": "terminal-theme-fidelity",
            "themeSnapshot": theme.manifestValue,
            "tileLayerBackgroundHex": tileLayerBackground as Any,
            "hostLayerBackgroundHex": hostLayerBackground as Any,
            "descriptorCommand": (descriptor.command as NSString).lastPathComponent,
            "descriptorArgsPrefix": Array(descriptor.args.prefix(5)),
            "tmuxAvailable": tmuxPath != nil,
            "tmuxWrapped": tmuxWrapped,
            "probeLines": probeLines,
            "tmuxCleanup": tmuxCleanup
        ]
        let artifact = directory.appendingPathComponent("manifest.json")
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: artifact, options: .atomic)
        return artifact
    }

    static func runNewTileCwdSelfCheck() throws -> URL {
        enum CheckError: Error, CustomStringConvertible {
            case failed(String)
            var description: String {
                switch self {
                case let .failed(message): return message
                }
            }
        }
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw CheckError.failed(message) }
        }
        func makeProject(root: URL, name: String) -> Project {
            Project(
                id: UUID(),
                name: name,
                rootPath: root.path,
                createdAt: Date(),
                updatedAt: Date(),
                defaultLaunchProfileId: "shell",
                editorPreference: .auto,
                settings: ProjectSettings(restorePolicy: .restoreDescriptors, browserStoragePolicy: .perProject, terminalClosePolicy: .askWhenRunning)
            )
        }
        func makeDefaults(policy: NewTileCwdPolicy, tmuxEnabled: Bool = false, tmuxPath: String = "/usr/bin/false") -> UserDefaults {
            let suiteName = "continuum.new-tile-cwd.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName)!
            defaults.removePersistentDomain(forName: suiteName)
            defaults.setVolatileDomain([:], forName: UserDefaults.argumentDomain)
            defaults.set(policy.rawValue, forKey: NewTileCwdConfig.userDefaultsKey)
            defaults.set(tmuxEnabled, forKey: TmuxPersistenceConfig.enabledKey)
            defaults.set(tmuxPath, forKey: TmuxPersistenceConfig.pathKey)
            defaults.set(true, forKey: TmuxPersistenceConfig.ambientPerWorkspaceKey)
            return defaults
        }
        func makeSpawner(
            root: URL,
            defaults: UserDefaults,
            tmuxControlFactory: @escaping @Sendable (String) -> any TmuxControl = { _ in InMemoryTmuxControl() }
        ) throws -> (TileSpawner, CanvasNSView, BrowserEngineContext) {
            let project = makeProject(root: root, name: root.lastPathComponent)
            let store = ProjectStore(projectRoot: root)
            try store.saveProject(project)
            try store.saveCanvas(CanvasState(viewport: CanvasViewport(x: 0, y: 0, zoom: 1), tiles: [], groups: [], lastActiveTileId: nil))
            let canvas = CanvasNSView(canvasState: try store.loadCanvas())
            canvas.setFrameSize(CGSize(width: 1200, height: 800))
            let browserEngine = BrowserEngineContext()
            let spawner = TileSpawner(
                canvasView: canvas,
                ghostty: nil,
                browserEngine: browserEngine,
                projectStore: store,
                project: project,
                defaults: defaults,
                tmuxPathResolver: { TmuxLocator.resolve(defaults: $0) },
                tmuxControlFactory: tmuxControlFactory
            )
            return (spawner, canvas, browserEngine)
        }
        func resolvedProfile(spawner: TileSpawner) throws -> LaunchProfile {
            switch spawner.resolvedFreshTerminalProfile(profileId: "shell") {
            case let .resolved(_, profile, _):
                return profile
            case let .failed(outcome):
                throw CheckError.failed("fresh profile resolution failed: \(outcome)")
            }
        }

        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory.appendingPathComponent("continuum-new-tile-cwd-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let focusedRoot = tempRoot.appendingPathComponent("focused", isDirectory: true)
        let projectPolicyRoot = tempRoot.appendingPathComponent("project-policy", isDirectory: true)
        let lastUsedRoot = tempRoot.appendingPathComponent("last-used", isDirectory: true)
        let tmuxRoot = tempRoot.appendingPathComponent("tmux", isDirectory: true)
        try [focusedRoot, projectPolicyRoot, lastUsedRoot, tmuxRoot].forEach {
            try fileManager.createDirectory(at: $0, withIntermediateDirectories: true)
        }

        let focusedCwd = focusedRoot.appendingPathComponent("Sources", isDirectory: true)
        let ignoredFocusCwd = projectPolicyRoot.appendingPathComponent("Ignored", isDirectory: true)
        let secondFocusCwd = lastUsedRoot.appendingPathComponent("SecondFocus", isDirectory: true)
        let tmuxFocusedCwd = tmuxRoot.appendingPathComponent("TmuxFocused", isDirectory: true)
        try [focusedCwd, ignoredFocusCwd, secondFocusCwd, tmuxFocusedCwd].forEach {
            try fileManager.createDirectory(at: $0, withIntermediateDirectories: true)
        }

        let focusedDefaults = makeDefaults(policy: .inheritFocus)
        let (focusedSpawner, _, focusedBrowser) = try makeSpawner(root: focusedRoot, defaults: focusedDefaults)
        defer { focusedBrowser.shutdown() }
        focusedSpawner.focusedTerminalCwdProvider = { focusedCwd.path }
        let focusedProfile = try resolvedProfile(spawner: focusedSpawner)
        try expect(focusedProfile.cwd == focusedCwd.path, "inheritFocus fresh profile should use focused cwd, got \(focusedProfile.cwd)")
        let focusedWrapped = try focusedSpawner.tmuxWrappedProfileIfAvailable(focusedProfile, tileId: UUID(), target: nil)
        try expect(focusedWrapped.profile.cwd == focusedCwd.path, "tmux-disabled inheritFocus wrapper should preserve focused cwd")
        try expect(focusedWrapped.windowTarget == nil, "tmux-disabled inheritFocus wrapper should not create a managed target")

        let projectDefaults = makeDefaults(policy: .projectRoot)
        let (projectSpawner, _, projectBrowser) = try makeSpawner(root: projectPolicyRoot, defaults: projectDefaults)
        defer { projectBrowser.shutdown() }
        projectSpawner.focusedTerminalCwdProvider = { ignoredFocusCwd.path }
        let projectProfile = try resolvedProfile(spawner: projectSpawner)
        try expect(projectProfile.cwd == projectPolicyRoot.path, "projectRoot policy should ignore focused cwd, got \(projectProfile.cwd)")

        let lastDefaults = makeDefaults(policy: .lastUsed)
        let (lastSpawner, _, lastBrowser) = try makeSpawner(root: lastUsedRoot, defaults: lastDefaults)
        defer { lastBrowser.shutdown() }
        lastSpawner.focusedTerminalCwdProvider = { secondFocusCwd.path }
        let firstLastProfile = try resolvedProfile(spawner: lastSpawner)
        lastSpawner.focusedTerminalCwdProvider = { nil }
        let secondLastProfile = try resolvedProfile(spawner: lastSpawner)
        try expect(firstLastProfile.cwd == lastUsedRoot.path, "lastUsed first fresh profile should fall back to project root, got \(firstLastProfile.cwd)")
        try expect(secondLastProfile.cwd == lastUsedRoot.path, "lastUsed should reuse the spawner-local previous cwd, got \(secondLastProfile.cwd)")

        let fakeTmux = tempRoot.appendingPathComponent("fake-tmux")
        try "#!/bin/sh\nexit 0\n".write(to: fakeTmux, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeTmux.path)
        let tmuxDefaults = makeDefaults(policy: .inheritFocus, tmuxEnabled: true, tmuxPath: fakeTmux.path)
        let tmuxControl = InMemoryTmuxControl()
        let (tmuxSpawner, _, tmuxBrowser) = try makeSpawner(
            root: tmuxRoot,
            defaults: tmuxDefaults,
            tmuxControlFactory: { _ in tmuxControl }
        )
        defer { tmuxBrowser.shutdown() }
        let workspaceId = UUID(uuidString: "A1818181-1818-4818-8818-181818181818")!
        tmuxSpawner.focusedTerminalCwdProvider = { tmuxFocusedCwd.path }
        let tmuxProfile = try resolvedProfile(spawner: tmuxSpawner)
        let tmuxWrapped = try tmuxSpawner.tmuxWrappedProfileIfAvailable(tmuxProfile, tileId: UUID(), target: .ambient(workspaceId: workspaceId))
        let ambientSessionName = TmuxSession.ambientSessionName(workspaceId: workspaceId)
        try expect(tmuxControl.log.contains(.newSession(name: ambientSessionName, cwd: tmuxFocusedCwd.path)), "tmux fresh spawn should create session with inherited cwd, log=\(tmuxControl.log)")
        try expect(tmuxWrapped.profile.arguments == ["attach-session", "-t", "%1"], "tmux wrapper should attach to captured pane target, got \(tmuxWrapped.profile.arguments)")
        try expect(tmuxWrapped.profile.cwd == tmuxFocusedCwd.path, "tmux wrapper should preserve inherited cwd for descriptor persistence, got \(tmuxWrapped.profile.cwd)")

        let terminalSection = SettingsSchema.sections().first { $0.id == "terminal" }
        let hasSettingsChoice = terminalSection?.fields.contains {
            if case let .choice(key, _, options, defaultValue) = $0 {
                return key == NewTileCwdConfig.userDefaultsKey
                    && options == NewTileCwdPolicy.allCases.map(\.rawValue)
                    && defaultValue == NewTileCwdConfig.defaultPolicy.rawValue
            }
            return false
        } ?? false
        try expect(hasSettingsChoice, "Terminal settings must expose the newTileCwd choice field with all policies")

        let artifact = tempRoot.appendingPathComponent("new-tile-cwd-manifest.json")
        let manifest: [String: Any] = [
            "check": "new-tile-cwd",
            "inheritFocusProfileCwd": focusedProfile.cwd,
            "projectRootProfileCwd": projectProfile.cwd,
            "lastUsedFirstProfileCwd": firstLastProfile.cwd,
            "lastUsedSecondProfileCwd": secondLastProfile.cwd,
            "tmuxLog": tmuxControl.log.map(String.init(describing:)),
            "tmuxWrappedProfileCwd": tmuxWrapped.profile.cwd,
            "settingsChoicePresent": hasSettingsChoice
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: artifact, options: .atomic)
        return artifact
    }

    // MARK: - tmux terminal persistence check

    static func runTerminalTmuxPersistenceSelfCheck() throws -> URL {
        enum CheckError: Error, CustomStringConvertible {
            case failed(String)
            var description: String {
                switch self {
                case let .failed(message): return message
                }
            }
        }
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw CheckError.failed(message) }
        }
        func runtimeId(for tile: Tile) throws -> UUID {
            guard let runtimeRef = tile.runtimeRef, runtimeRef.kind == .terminalSession else {
                throw CheckError.failed("terminal tile missing terminal runtimeRef")
            }
            return runtimeRef.id
        }
        func makeDefaults(enabled: Bool, path: String) -> UserDefaults {
            let suiteName = "continuum.tmux-p2-check.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName)!
            defaults.removePersistentDomain(forName: suiteName)
            defaults.set(enabled, forKey: TmuxPersistenceConfig.enabledKey)
            defaults.set(path, forKey: TmuxPersistenceConfig.pathKey)
            return defaults
        }
        final class ThrowingSessionStore: ProjectStoring, @unchecked Sendable {
            enum StoreError: Error { case saveSessionFailed }
            private let base: ProjectStore
            init(base: ProjectStore) { self.base = base }
            func saveProject(_ project: Project) throws { try base.saveProject(project) }
            func loadProject() throws -> Project { try base.loadProject() }
            func tryLoadProject() throws -> Project? { try base.tryLoadProject() }
            func saveCanvas(_ canvas: CanvasState) throws { try base.saveCanvas(canvas) }
            func loadCanvas() throws -> CanvasState { try base.loadCanvas() }
            func loadCanvasWithSanitizationResult() throws -> CanvasEngine.CanvasSanitizationResult { try base.loadCanvasWithSanitizationResult() }
            func tryLoadCanvas() throws -> CanvasState? { try base.tryLoadCanvas() }
            func tryLoadCanvasWithSanitizationResult() throws -> CanvasEngine.CanvasSanitizationResult? { try base.tryLoadCanvasWithSanitizationResult() }
            func saveSession(_ descriptor: TerminalSessionDescriptor) throws { throw StoreError.saveSessionFailed }
            func loadSession(id: UUID) throws -> TerminalSessionDescriptor { try base.loadSession(id: id) }
            func deleteSession(id: UUID) throws { try base.deleteSession(id: id) }
            func listSessions() throws -> [TerminalSessionDescriptor] { try base.listSessions() }
            func saveBrowserState(_ state: BrowserState) throws { try base.saveBrowserState(state) }
            func loadBrowserState() throws -> BrowserState { try base.loadBrowserState() }
            func tryLoadBrowserState() throws -> BrowserState? { try base.tryLoadBrowserState() }
            func browserStateFileExists() -> Bool { base.browserStateFileExists() }
            func saveFileTreeState(_ state: FileTreeState) throws { try base.saveFileTreeState(state) }
            func loadFileTreeState() throws -> FileTreeState { try base.loadFileTreeState() }
            func tryLoadFileTreeState() throws -> FileTreeState? { try base.tryLoadFileTreeState() }
            func fileTreeStateFileExists() -> Bool { base.fileTreeStateFileExists() }
            func saveNoteState(_ state: NoteState) throws { try base.saveNoteState(state) }
            func loadNoteState() throws -> NoteState { try base.loadNoteState() }
            func tryLoadNoteState() throws -> NoteState? { try base.tryLoadNoteState() }
            func saveNoteBody(id: UUID, text: String) throws { try base.saveNoteBody(id: id, text: text) }
            func loadNoteBody(id: UUID) throws -> String { try base.loadNoteBody(id: id) }
            func tryLoadNoteBody(id: UUID) -> String? { base.tryLoadNoteBody(id: id) }
            func deleteNoteBody(id: UUID) throws { try base.deleteNoteBody(id: id) }
            func saveReviewCommentState(_ state: ReviewCommentState) throws { try base.saveReviewCommentState(state) }
            func loadReviewCommentState(reviewId: UUID) throws -> ReviewCommentState { try base.loadReviewCommentState(reviewId: reviewId) }
            func tryLoadReviewCommentState(reviewId: UUID) throws -> ReviewCommentState? { try base.tryLoadReviewCommentState(reviewId: reviewId) }
            func deleteReviewCommentState(reviewId: UUID) throws { try base.deleteReviewCommentState(reviewId: reviewId) }
        }
        func makeProject(root: URL, name: String) -> Project {
            Project(
                id: UUID(),
                name: name,
                rootPath: root.path,
                createdAt: Date(),
                updatedAt: Date(),
                defaultLaunchProfileId: "shell",
                editorPreference: .auto,
                settings: ProjectSettings(restorePolicy: .restoreDescriptors, browserStoragePolicy: .perProject, terminalClosePolicy: .askWhenRunning)
            )
        }
        final class MalformedPaneTmuxControl: TmuxControl, @unchecked Sendable {
            let malformedTarget: String
            var sessions: Set<String> = []
            var log: [InMemoryTmuxControl.TmuxCall] = []

            init(malformedTarget: String) {
                self.malformedTarget = malformedTarget
            }

            func newSession(name: String, cwd: String, innerCommand: [String]?) async throws -> String {
                sessions.insert(name)
                log.append(.newSession(name: name, cwd: cwd))
                return malformedTarget
            }

            func newWindow(inSession: String, cwd: String, innerCommand: [String]?) async throws -> String {
                log.append(.newWindow(session: inSession, cwd: cwd))
                return malformedTarget
            }

            func killWindow(target: String) async throws {
                log.append(.killWindow(target: target))
            }

            func killSession(name: String) async throws {
                log.append(.killSession(name: name))
            }

            func detachSession(name: String) async throws {
                log.append(.detachSession(name: name))
            }

            func sessionExists(name: String) async throws -> Bool {
                log.append(.sessionExists(name: name))
                return sessions.contains(name)
            }

            func isAlive(paneTarget: String) async throws -> Bool {
                log.append(.isAlive(target: paneTarget))
                return false
            }

            func paneCurrentPath(paneTarget: String) async throws -> String {
                log.append(.paneCurrentPath(target: paneTarget))
                return "/tmp"
            }

            func paneCurrentCommand(paneTarget: String) async throws -> String {
                log.append(.paneCurrentCommand(target: paneTarget))
                return "zsh"
            }

            func listSessions() async throws -> [TmuxSessionInfo] {
                log.append(.listSessions)
                return sessions.map { TmuxSessionInfo(name: $0, windowCount: 1, paneTargets: [malformedTarget]) }
            }
        }
        func makeSpawner(
            root: URL,
            defaults: UserDefaults,
            resolver: @escaping (UserDefaults) -> String?,
            tmuxControlFactory: @escaping @Sendable (String) -> any TmuxControl = { _ in InMemoryTmuxControl() },
            storeOverride: (any ProjectStoring)? = nil
        ) throws -> (TileSpawner, ProjectStore, CanvasNSView, BrowserEngineContext, GhosttyRuntimeContext) {
            let project = makeProject(root: root, name: root.lastPathComponent)
            let store = ProjectStore(projectRoot: root)
            try store.saveProject(project)
            try store.saveCanvas(CanvasState(viewport: CanvasViewport(x: 0, y: 0, zoom: 1), tiles: [], groups: [], lastActiveTileId: nil))
            let canvas = CanvasNSView(canvasState: try store.loadCanvas())
            canvas.setFrameSize(CGSize(width: 1200, height: 800))
            let browserEngine = BrowserEngineContext()
            let ghostty = try GhosttyRuntimeContext()
            let spawner = TileSpawner(
                canvasView: canvas,
                ghostty: ghostty,
                browserEngine: browserEngine,
                projectStore: storeOverride ?? store,
                project: project,
                defaults: defaults,
                tmuxPathResolver: resolver,
                tmuxControlFactory: tmuxControlFactory
            )
            return (spawner, store, canvas, browserEngine, ghostty)
        }
        func spawnAndDescriptor(spawner: TileSpawner, store: ProjectStore, canvas: CanvasNSView) throws -> (Tile, TerminalSessionDescriptor) {
            switch spawner.spawnTerminal(profileId: "shell") {
            case let .spawned(runtime):
                guard let tile = canvas.canvasState.tiles.first(where: { $0.id == runtime.tileId }) else {
                    throw CheckError.failed("spawnTerminal did not create a terminal tile")
                }
                return (tile, try store.loadSession(id: try runtimeId(for: tile)))
            case let .unknownProfile(id): throw CheckError.failed("unknown profile: \(id)")
            case let .missingCommand(executable): throw CheckError.failed("missing command: \(executable)")
            case let .notConfigured(profileId): throw CheckError.failed("not configured: \(profileId)")
            case let .failure(error): throw CheckError.failed("spawnTerminal failed: \(error)")
            }
        }
        func managedTarget(spawner: TileSpawner, tileId: UUID) throws -> String? {
            try spawner.managedSessionStore.load(tileId: tileId)?.tmuxWindowTarget()
        }
        func restartAndDescriptor(tileId: UUID, spawner: TileSpawner, store: ProjectStore, canvas: CanvasNSView) throws -> TerminalSessionDescriptor {
            switch spawner.restartTerminalTile(tileId: tileId) {
            case .restarted:
                guard let tile = canvas.canvasState.tiles.first(where: { $0.id == tileId }) else {
                    throw CheckError.failed("restart removed terminal tile")
                }
                return try store.loadSession(id: try runtimeId(for: tile))
            case let .unknownProfile(id): throw CheckError.failed("restart unknown profile: \(id)")
            case let .missingCommand(executable): throw CheckError.failed("restart missing command: \(executable)")
            case let .notConfigured(profileId): throw CheckError.failed("restart not configured: \(profileId)")
            case .tileNotFound: throw CheckError.failed("restart tile not found")
            case let .failure(error): throw CheckError.failed("restart failed: \(error)")
            }
        }

        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory.appendingPathComponent("continuum-tmux-p2-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let fakeTmux = tempRoot.appendingPathComponent("fake-tmux")
        try "#!/bin/sh\nexit 0\n".write(to: fakeTmux, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeTmux.path)

        let enabledRoot = tempRoot.appendingPathComponent("enabled", isDirectory: true)
        let offRoot = tempRoot.appendingPathComponent("off", isDirectory: true)
        let absentRoot = tempRoot.appendingPathComponent("absent", isDirectory: true)
        let ambientRoot = tempRoot.appendingPathComponent("ambient-workspace", isDirectory: true)
        let ambientOffRoot = tempRoot.appendingPathComponent("ambient-off", isDirectory: true)
        let malformedRoot = tempRoot.appendingPathComponent("malformed-pane", isDirectory: true)
        try [enabledRoot, offRoot, absentRoot, ambientRoot, ambientOffRoot, malformedRoot].forEach { try fileManager.createDirectory(at: $0, withIntermediateDirectories: true) }

        let enabledDefaults = makeDefaults(enabled: true, path: fakeTmux.path)
        let enabledTmux = InMemoryTmuxControl()
        let (enabledSpawner, enabledStore, enabledCanvas, enabledBrowser, enabledGhostty) = try makeSpawner(
            root: enabledRoot,
            defaults: enabledDefaults,
            resolver: { TmuxLocator.resolve(defaults: $0) },
            tmuxControlFactory: { _ in enabledTmux }
        )
        defer { enabledGhostty.shutdown(); enabledBrowser.shutdown() }
        let (spawnedTile, spawnedDescriptor) = try spawnAndDescriptor(spawner: enabledSpawner, store: enabledStore, canvas: enabledCanvas)
        let restartedDescriptor = try restartAndDescriptor(tileId: spawnedTile.id, spawner: enabledSpawner, store: enabledStore, canvas: enabledCanvas)
        let expectedSessionName = TmuxSession.sessionName(tileId: spawnedTile.id)
        let expectedArgs = ["new-session", "-A", "-s", expectedSessionName, "-c", enabledRoot.path]
        try expect(spawnedDescriptor.command == fakeTmux.path, "enabled spawn should use fake tmux command, got \(spawnedDescriptor.command)")
        try expect(spawnedDescriptor.args == expectedArgs, "enabled spawn should tmux-wrap with stable session/cwd, got \(spawnedDescriptor.args)")
        let enabledManagedTarget = try managedTarget(spawner: enabledSpawner, tileId: spawnedTile.id)
        try expect(enabledManagedTarget == nil, "per-tile tmux spawn should not persist a managed pane target")
        try expect(!enabledTmux.log.contains { if case .newWindow = $0 { return true }; return false }, "ambient spawn should not create project windows via TmuxControl")
        try expect(restartedDescriptor.command == fakeTmux.path, "enabled restart should use fake tmux command, got \(restartedDescriptor.command)")
        try expect(restartedDescriptor.args == expectedArgs, "enabled restart should keep same tmux session args, got \(restartedDescriptor.args)")
        try expect(spawnedDescriptor.args.firstIndex(of: expectedSessionName) == restartedDescriptor.args.firstIndex(of: expectedSessionName), "spawn and restart should carry the same session name")

        let ambientDefaults = makeDefaults(enabled: true, path: fakeTmux.path)
        ambientDefaults.set(true, forKey: TmuxPersistenceConfig.ambientPerWorkspaceKey)
        let ambientTmux = InMemoryTmuxControl()
        let (ambientSpawner, ambientStore, ambientCanvas, ambientBrowser, ambientGhostty) = try makeSpawner(
            root: ambientRoot,
            defaults: ambientDefaults,
            resolver: { _ in fakeTmux.path },
            tmuxControlFactory: { _ in ambientTmux }
        )
        defer { ambientGhostty.shutdown(); ambientBrowser.shutdown() }
        let ambientWorkspaceId = UUID(uuidString: "A2222222-2222-4222-8222-222222222222")!
        ambientSpawner.terminalSessionTargetProvider = { .ambient(workspaceId: ambientWorkspaceId) }
        var focusedPaneTarget: String?
        ambientSpawner.terminalFocusedPaneTargetProvider = { focusedPaneTarget }
        var ambientDescriptors: [TerminalSessionDescriptor] = []
        let (firstAmbientTile, firstAmbientDescriptor) = try spawnAndDescriptor(spawner: ambientSpawner, store: ambientStore, canvas: ambientCanvas)
        ambientDescriptors.append(firstAmbientDescriptor)
        focusedPaneTarget = try managedTarget(spawner: ambientSpawner, tileId: firstAmbientTile.id)
        let inheritedCwd = ambientRoot.appendingPathComponent("focused-pane-cwd", isDirectory: true)
        try fileManager.createDirectory(at: inheritedCwd, withIntermediateDirectories: true)
        if let focusedPaneTarget, var stub = ambientTmux.livePanes[focusedPaneTarget] {
            stub.cwd = inheritedCwd.path
            ambientTmux.livePanes[focusedPaneTarget] = stub
        }
        let (_, secondAmbientDescriptor) = try spawnAndDescriptor(spawner: ambientSpawner, store: ambientStore, canvas: ambientCanvas)
        ambientDescriptors.append(secondAmbientDescriptor)
        let ambientSessionName = TmuxSession.ambientSessionName(workspaceId: ambientWorkspaceId)
        let ambientTargets = try ambientCanvas.canvasState.tiles.map { try managedTarget(spawner: ambientSpawner, tileId: $0.id) }.compactMap { $0 }
        try expect(ambientTmux.log.filter { if case .newSession = $0 { return true }; return false }.count == 1, "ambient spawns should create exactly one workspace tmux session, log=\(ambientTmux.log)")
        try expect(ambientTmux.log.filter { if case .newWindow = $0 { return true }; return false }.count == 1, "ambient spawns should create exactly one second workspace window, log=\(ambientTmux.log)")
        try expect(ambientTmux.log.contains(.paneCurrentPath(target: focusedPaneTarget ?? "")), "second ambient spawn should read the focused pane cwd before creating a sibling window, log=\(ambientTmux.log)")
        try expect(ambientTmux.log.contains(.newWindow(session: ambientSessionName, cwd: inheritedCwd.path)), "second ambient spawn should inherit focused pane cwd for new-window, log=\(ambientTmux.log)")
        try expect(!ambientTmux.log.contains { if case .killWindow = $0 { return true }; return false }, "successful ambient spawn should not compensate-kill a window, log=\(ambientTmux.log)")
        try expect(ambientTargets.count == 2 && Set(ambientTargets).count == 2, "ambient descriptors should persist two distinct pane targets, got \(ambientTargets)")
        try expect(ambientTmux.sessions[ambientSessionName] == ambientTargets, "fake ambient session should contain exactly persisted targets")
        for (index, descriptor) in ambientDescriptors.enumerated() {
            let viewSessionName = TmuxSession.viewSessionName(tileId: descriptor.tileId)
            let expectedViewArgs = ["new-session", "-t", ambientSessionName, "-s", viewSessionName, "-A", ";", "select-window", "-t", ambientTargets[index]]
            try expect(descriptor.command == fakeTmux.path, "ambient descriptor should launch tmux view, got \(descriptor.command)")
            try expect(descriptor.args == expectedViewArgs, "ambient descriptor should attach through its stable grouped view, got \(descriptor.args)")
            try expect(descriptor.args != ["attach-session", "-t", ambientTargets[index]], "ambient descriptor must reject bare shared-session attach, got \(descriptor.args)")
        }

        let ambientOffDefaults = makeDefaults(enabled: true, path: fakeTmux.path)
        ambientOffDefaults.set(false, forKey: TmuxPersistenceConfig.ambientPerWorkspaceKey)
        let ambientOffTmux = InMemoryTmuxControl()
        let (ambientOffSpawner, ambientOffStore, ambientOffCanvas, ambientOffBrowser, ambientOffGhostty) = try makeSpawner(
            root: ambientOffRoot,
            defaults: ambientOffDefaults,
            resolver: { _ in fakeTmux.path },
            tmuxControlFactory: { _ in ambientOffTmux }
        )
        defer { ambientOffGhostty.shutdown(); ambientOffBrowser.shutdown() }
        let ambientOffWorkspaceId = UUID(uuidString: "A3333333-3333-4333-8333-333333333333")!
        ambientOffSpawner.terminalSessionTargetProvider = { .ambient(workspaceId: ambientOffWorkspaceId) }
        let (ambientOffTile, ambientOffDescriptor) = try spawnAndDescriptor(spawner: ambientOffSpawner, store: ambientOffStore, canvas: ambientOffCanvas)
        let expectedAmbientOffSessionName = TmuxSession.sessionName(tileId: ambientOffTile.id)
        let ambientOffManagedTarget = try managedTarget(spawner: ambientOffSpawner, tileId: ambientOffTile.id)
        try expect(ambientOffManagedTarget == nil, "ambient fallback-off should not persist a workspace window target")
        try expect(ambientOffTmux.log.isEmpty, "ambient fallback-off should not call TmuxControl, log=\(ambientOffTmux.log)")
        try expect(ambientOffDescriptor.command == fakeTmux.path, "ambient fallback-off should still use tmux per-tile wrapper")
        try expect(ambientOffDescriptor.args.prefix(5) == ["new-session", "-A", "-s", expectedAmbientOffSessionName, "-c"], "ambient fallback-off should use per-tile new-session -A wrapper, got \(ambientOffDescriptor.args)")

        let projectRoot = tempRoot.appendingPathComponent("project-window", isDirectory: true)
        try fileManager.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        let projectTmux = InMemoryTmuxControl()
        let projectDefaults = makeDefaults(enabled: true, path: fakeTmux.path)
        let (projectSpawner, projectStore, projectCanvas, projectBrowser, projectGhostty) = try makeSpawner(
            root: projectRoot,
            defaults: projectDefaults,
            resolver: { _ in fakeTmux.path },
            tmuxControlFactory: { _ in projectTmux }
        )
        defer { projectGhostty.shutdown(); projectBrowser.shutdown() }
        let projectId = UUID()
        let projectEntry = ProjectEntry(id: projectId, name: "Project Window", rootPath: projectRoot.path, workspaceId: nil, lastOpenedAt: Date(), pinned: false, missing: false)
        projectSpawner.terminalProjectContextProvider = { projectEntry }
        projectSpawner.terminalSessionTargetProvider = { .project(projectId: projectId) }
        var projectDescriptors: [TerminalSessionDescriptor] = []
        for _ in 0..<3 {
            let (_, descriptor) = try spawnAndDescriptor(spawner: projectSpawner, store: projectStore, canvas: projectCanvas)
            projectDescriptors.append(descriptor)
        }
        let projectSessionName = TmuxSession.projectSessionName(projectId: projectId)
        let projectTargets = try projectCanvas.canvasState.tiles.map { try managedTarget(spawner: projectSpawner, tileId: $0.id) }.compactMap { $0 }
        try expect(projectTmux.log.filter { if case .newSession = $0 { return true }; return false }.count == 1, "project spawns should create exactly one tmux session after the first newWindow fallback, log=\(projectTmux.log)")
        try expect(projectTmux.log.filter { if case .newWindow = $0 { return true }; return false }.count == 3, "project spawns should try newWindow for every project tile, falling back to newSession only for the first missing session, log=\(projectTmux.log)")
        try expect(projectTargets.count == 3 && Set(projectTargets).count == 3, "project descriptors should persist three distinct pane targets, got \(projectTargets)")
        try expect(projectTmux.sessions[projectSessionName] == projectTargets, "fake project session should contain exactly persisted targets")
        for (index, descriptor) in projectDescriptors.enumerated() {
            let viewSessionName = TmuxSession.viewSessionName(tileId: descriptor.tileId)
            let expectedViewArgs = ["new-session", "-t", projectSessionName, "-s", viewSessionName, "-A", ";", "select-window", "-t", projectTargets[index]]
            try expect(descriptor.command == fakeTmux.path, "project descriptor should launch tmux view, got \(descriptor.command)")
            try expect(descriptor.args == expectedViewArgs, "project descriptor should attach through its stable grouped view, got \(descriptor.args)")
            try expect(descriptor.args != ["attach-session", "-t", projectTargets[index]], "project descriptor must reject bare shared-session attach, got \(descriptor.args)")
        }

        // Ticket 15 ("new-tile -> new-window"): restarting a project-zone tile
        // whose persisted tmuxWindowTarget is still alive (the boot-time restore
        // path — installInitialTerminalTile -> restartTerminalTile) must re-bind
        // to that window rather than blindly creating a new one, or every launch
        // orphans the previous tmux window. Uses a dedicated fourth tile (rather
        // than reusing projectDescriptors[0]) so the restarted real terminal
        // runtime this exercises can't race the flush check below, which reuses
        // projectDescriptors[0]'s tileId for its own synthetic runtime.
        let (restartCheckTile, _) = try spawnAndDescriptor(spawner: projectSpawner, store: projectStore, canvas: projectCanvas)
        let restartTileId = restartCheckTile.id
        let liveTargetBeforeRestart = try managedTarget(spawner: projectSpawner, tileId: restartTileId)
        let newWindowCountBeforeLiveRestart = projectTmux.log.filter { if case .newWindow = $0 { return true }; return false }.count
        let restartedLiveDescriptor = try restartAndDescriptor(tileId: restartTileId, spawner: projectSpawner, store: projectStore, canvas: projectCanvas)
        let newWindowCountAfterLiveRestart = projectTmux.log.filter { if case .newWindow = $0 { return true }; return false }.count
        try expect(
            projectTmux.log.contains(.isAlive(target: liveTargetBeforeRestart ?? "")),
            "restart should check the persisted pane's liveness via TmuxControl.isAlive before deciding, log=\(projectTmux.log)"
        )
        try expect(
            newWindowCountAfterLiveRestart == newWindowCountBeforeLiveRestart,
            "restart with a live persisted tmux window must not create a new window (ticket 15), log=\(projectTmux.log)"
        )
        let liveRestartTarget = try managedTarget(spawner: projectSpawner, tileId: restartTileId)
        try expect(liveRestartTarget == liveTargetBeforeRestart, "restart with a live persisted tmux window must reuse the same managed pane target")
        let restartViewSessionName = TmuxSession.viewSessionName(tileId: restartTileId)
        let expectedLiveRestartArgs = ["new-session", "-t", projectSessionName, "-s", restartViewSessionName, "-A", ";", "select-window", "-t", liveTargetBeforeRestart ?? ""]
        try expect(
            restartedLiveDescriptor.args == expectedLiveRestartArgs,
            "restart with a live target should reattach and repin its stable grouped view, got \(restartedLiveDescriptor.args)"
        )

        // Now kill that window out from under the descriptor (simulating a pane
        // that died between launches) and restart again: a dead target must
        // still fall back to creating a fresh window, exactly like today.
        try Self.runTmuxControlOperationSync { try await projectTmux.killWindow(target: liveTargetBeforeRestart ?? "") }
        let newWindowCountBeforeDeadRestart = projectTmux.log.filter { if case .newWindow = $0 { return true }; return false }.count
        let restartedDeadDescriptor = try restartAndDescriptor(tileId: restartTileId, spawner: projectSpawner, store: projectStore, canvas: projectCanvas)
        let newWindowCountAfterDeadRestart = projectTmux.log.filter { if case .newWindow = $0 { return true }; return false }.count
        try expect(
            newWindowCountAfterDeadRestart == newWindowCountBeforeDeadRestart + 1,
            "restart with a dead persisted tmux window should create exactly one new window, log=\(projectTmux.log)"
        )
        let deadRestartTarget = try managedTarget(spawner: projectSpawner, tileId: restartTileId)
        try expect(deadRestartTarget != nil && deadRestartTarget != liveTargetBeforeRestart, "restart with a dead target should persist a fresh managed pane target")
        let expectedDeadRestartArgs = ["new-session", "-t", projectSessionName, "-s", restartViewSessionName, "-A", ";", "select-window", "-t", deadRestartTarget ?? ""]
        try expect(restartedDeadDescriptor.args == expectedDeadRestartArgs, "restart with a dead target should repin the same stable grouped view to its replacement, got \(restartedDeadDescriptor.args)")

        let nilTargetRecord = ManagedAgentSessionRecord(
            tileId: restartTileId,
            agentKind: .shell,
            status: .running,
            lastSeenAt: Date(),
            runtimePayload: nil
        )
        try projectSpawner.managedSessionStore.upsert(nilTargetRecord)
        let logCountBeforeNilRestart = projectTmux.log.count
        _ = try restartAndDescriptor(tileId: restartTileId, spawner: projectSpawner, store: projectStore, canvas: projectCanvas)
        let nilRestartLog = Array(projectTmux.log.dropFirst(logCountBeforeNilRestart))
        try expect(!nilRestartLog.contains { if case .isAlive = $0 { return true }; return false }, "restart with nil target should not probe liveness, log=\(nilRestartLog)")
        try expect(nilRestartLog.contains { call in
            if case let .newWindow(session, cwd) = call {
                return session == projectSessionName && cwd == projectRoot.path
            }
            return false
        }, "restart with nil target should create a project window, log=\(nilRestartLog)")
        let nilRestartTarget = try managedTarget(spawner: projectSpawner, tileId: restartTileId)
        try expect(nilRestartTarget != nil, "restart with nil target should persist a fresh managed pane target")

        let sessionGoneRoot = tempRoot.appendingPathComponent("project-window-session-gone", isDirectory: true)
        try fileManager.createDirectory(at: sessionGoneRoot, withIntermediateDirectories: true)
        let sessionGoneTmux = InMemoryTmuxControl()
        let (sessionGoneSpawner, sessionGoneStore, sessionGoneCanvas, sessionGoneBrowser, sessionGoneGhostty) = try makeSpawner(
            root: sessionGoneRoot,
            defaults: projectDefaults,
            resolver: { _ in fakeTmux.path },
            tmuxControlFactory: { _ in sessionGoneTmux }
        )
        defer { sessionGoneGhostty.shutdown(); sessionGoneBrowser.shutdown() }
        let sessionGoneProjectId = UUID()
        let sessionGoneSessionName = TmuxSession.projectSessionName(projectId: sessionGoneProjectId)
        sessionGoneSpawner.terminalProjectContextProvider = {
            ProjectEntry(id: sessionGoneProjectId, name: "Session Gone", rootPath: sessionGoneRoot.path, workspaceId: nil, lastOpenedAt: Date(), pinned: false, missing: false)
        }
        sessionGoneSpawner.terminalSessionTargetProvider = { .project(projectId: sessionGoneProjectId) }
        let (sessionGoneTile, _) = try spawnAndDescriptor(spawner: sessionGoneSpawner, store: sessionGoneStore, canvas: sessionGoneCanvas)
        let sessionGoneOldTarget = try managedTarget(spawner: sessionGoneSpawner, tileId: sessionGoneTile.id)
        try expect(sessionGoneOldTarget != nil, "session-gone setup should persist an initial target")
        try Self.runTmuxControlOperationSync { try await sessionGoneTmux.killWindow(target: sessionGoneOldTarget ?? "") }
        let sessionGoneLogCountBeforeRestart = sessionGoneTmux.log.count
        _ = try restartAndDescriptor(tileId: sessionGoneTile.id, spawner: sessionGoneSpawner, store: sessionGoneStore, canvas: sessionGoneCanvas)
        let sessionGoneRestartLog = Array(sessionGoneTmux.log.dropFirst(sessionGoneLogCountBeforeRestart))
        try expect(
            sessionGoneRestartLog.prefix(4) == [
                .sessionExists(name: TmuxSession.viewSessionName(tileId: sessionGoneTile.id)),
                .isAlive(target: sessionGoneOldTarget ?? ""),
                .newWindow(session: sessionGoneSessionName, cwd: sessionGoneRoot.path),
                .newSession(name: sessionGoneSessionName, cwd: sessionGoneRoot.path)
            ],
            "restart with a dead target and missing project session must check view -> isAlive -> newWindow -> newSession, log=\(sessionGoneRestartLog)"
        )
        let sessionGoneNewTarget = try managedTarget(spawner: sessionGoneSpawner, tileId: sessionGoneTile.id)
        try expect(sessionGoneNewTarget != nil && sessionGoneNewTarget != sessionGoneOldTarget, "session-gone restart should persist the newSession target")

        let flushDescriptorBefore = projectDescriptors[0]
        let flushRuntime = GhosttyTerminalRuntime(
            id: flushDescriptorBefore.id,
            tileId: flushDescriptorBefore.tileId,
            title: flushDescriptorBefore.title,
            launchProfile: LaunchProfile(
                command: flushDescriptorBefore.command,
                arguments: flushDescriptorBefore.args,
                cwd: "\(projectRoot.path)/flushed-cwd",
                title: flushDescriptorBefore.title
            ),
            ghostty: projectGhostty,
            displayDefaults: projectDefaults
        )
        try projectSpawner.flushTerminalSessionSnapshot(tileId: flushDescriptorBefore.tileId, runtime: flushRuntime)
        let flushDescriptorAfter = try projectStore.loadSession(id: flushDescriptorBefore.id)
        let flushManagedTarget = try managedTarget(spawner: projectSpawner, tileId: flushDescriptorBefore.tileId)
        try expect(flushManagedTarget == projectTargets[0], "terminal snapshot flush should preserve managed tmuxWindowTarget")
        try expect(flushDescriptorAfter.cwd.hasSuffix("/flushed-cwd"), "terminal snapshot flush should still update live cwd")

        let descriptor = TerminalSessionDescriptor(
            id: UUID(),
            tileId: UUID(),
            launchProfileId: "shell",
            command: "/bin/zsh",
            args: [],
            cwd: "/tmp",
            env: [:],
            title: "Shell",
            createdAt: Date(timeIntervalSince1970: 1),
            lastStartedAt: Date(timeIntervalSince1970: 1),
            lastExit: nil
        )
        let encoded = try JSONEncoder().encode(descriptor)
        let encodedString = String(data: encoded, encoding: .utf8) ?? ""
        let decoded = try JSONDecoder().decode(TerminalSessionDescriptor.self, from: encoded)
        try expect(decoded == descriptor, "TerminalSessionDescriptor should round-trip without host-local tmuxWindowTarget")
        try expect(!encodedString.contains("tmuxWindowTarget"), "TerminalSessionDescriptor raw JSON should omit tmuxWindowTarget")
        let v2JSON = """
        {"schemaVersion":2,"id":"00000000-0000-0000-0000-000000000001","tileId":"00000000-0000-0000-0000-000000000002","launchProfileId":"shell","command":"/bin/zsh","args":[],"cwd":"/tmp","env":{},"title":"Shell","createdAt":1,"lastStartedAt":1,"lastExit":null}
        """.data(using: .utf8)!
        let v2Decoded = try JSONDecoder().decode(TerminalSessionDescriptor.self, from: v2JSON)
        try expect(v2Decoded.launchProfileId == "shell", "schema v2 descriptors should decode without tmuxWindowTarget")

        let failureRoot = tempRoot.appendingPathComponent("project-window-save-failure", isDirectory: true)
        try fileManager.createDirectory(at: failureRoot, withIntermediateDirectories: true)
        let failureBaseStore = ProjectStore(projectRoot: failureRoot)
        let failureProject = makeProject(root: failureRoot, name: "project-window-save-failure")
        try failureBaseStore.saveProject(failureProject)
        try failureBaseStore.saveCanvas(CanvasState(viewport: CanvasViewport(x: 0, y: 0, zoom: 1), tiles: [], groups: [], lastActiveTileId: nil))
        let failureTmux = InMemoryTmuxControl()
        let throwingStore = ThrowingSessionStore(base: failureBaseStore)
        let failureCanvas = CanvasNSView(canvasState: try failureBaseStore.loadCanvas())
        let failureBrowser = BrowserEngineContext()
        let failureGhostty = try GhosttyRuntimeContext()
        defer { failureGhostty.shutdown(); failureBrowser.shutdown() }
        let failureSpawner = TileSpawner(
            canvasView: failureCanvas,
            ghostty: failureGhostty,
            browserEngine: failureBrowser,
            projectStore: throwingStore,
            project: failureProject,
            defaults: projectDefaults,
            tmuxPathResolver: { _ in fakeTmux.path },
            tmuxControlFactory: { _ in failureTmux }
        )
        let failureProjectId = UUID()
        let failureSessionName = TmuxSession.projectSessionName(projectId: failureProjectId)
        let siblingPane = try Self.runTmuxControlOperationSync {
            try await failureTmux.newSession(name: failureSessionName, cwd: failureRoot.path, innerCommand: ["/bin/zsh"])
        }
        failureSpawner.terminalProjectContextProvider = {
            ProjectEntry(id: failureProjectId, name: "Failing Project", rootPath: failureRoot.path, workspaceId: nil, lastOpenedAt: Date(), pinned: false, missing: false)
        }
        failureSpawner.terminalSessionTargetProvider = { .project(projectId: failureProjectId) }
        switch failureSpawner.spawnTerminal(profileId: "shell") {
        case .failure:
            break
        default:
            throw CheckError.failed("project spawn should fail when descriptor save fails")
        }
        let createdPane = failureTmux.log.compactMap { call -> String? in
            if case let .killWindow(target) = call { return target }
            return nil
        }.first
        try expect(createdPane != nil, "save failure after project window creation should kill the captured pane, log=\(failureTmux.log)")
        let failureViewKills = failureTmux.log.compactMap { call -> String? in
            if case let .killSession(name) = call { return name }
            return nil
        }
        try expect(failureViewKills.count == 1 && failureViewKills[0].hasPrefix("array-view-"), "save failure should clean up only its newly created stable view, log=\(failureTmux.log)")
        try expect(failureTmux.sessions[failureSessionName] == [siblingPane], "save rollback must preserve the sibling window and shared base session, sessions=\(failureTmux.sessions)")
        try expect(!failureTmux.log.contains(.killSession(name: failureSessionName)), "save rollback must never kill the shared base session, log=\(failureTmux.log)")

        let malformedDefaults = makeDefaults(enabled: true, path: fakeTmux.path)
        let malformedTmux = MalformedPaneTmuxControl(malformedTarget: "not-a-pane-id")
        let (malformedSpawner, _, _, malformedBrowser, malformedGhostty) = try makeSpawner(
            root: malformedRoot,
            defaults: malformedDefaults,
            resolver: { _ in fakeTmux.path },
            tmuxControlFactory: { _ in malformedTmux }
        )
        defer { malformedGhostty.shutdown(); malformedBrowser.shutdown() }
        let malformedProjectId = UUID()
        let malformedSessionName = TmuxSession.projectSessionName(projectId: malformedProjectId)
        malformedTmux.sessions.insert(malformedSessionName)
        malformedSpawner.terminalProjectContextProvider = {
            ProjectEntry(id: malformedProjectId, name: "Malformed Project", rootPath: malformedRoot.path, workspaceId: nil, lastOpenedAt: Date(), pinned: false, missing: false)
        }
        malformedSpawner.terminalSessionTargetProvider = { .project(projectId: malformedProjectId) }
        switch malformedSpawner.spawnTerminal(profileId: "shell") {
        case let .failure(error):
            try expect(String(describing: error).contains("invalidPaneId"), "malformed pane capture should fail with invalidPaneId, got \(error)")
        default:
            throw CheckError.failed("project spawn should fail when tmux returns malformed pane id")
        }
        try expect(
            malformedTmux.log.contains(.killWindow(target: "not-a-pane-id")),
            "malformed pane-id capture should issue compensating kill-window for the created target, log=\(malformedTmux.log)"
        )

        let offDefaults = makeDefaults(enabled: false, path: fakeTmux.path)
        let offTmux = InMemoryTmuxControl()
        let (offSpawner, offStore, offCanvas, offBrowser, offGhostty) = try makeSpawner(
            root: offRoot,
            defaults: offDefaults,
            resolver: { _ in fakeTmux.path },
            tmuxControlFactory: { _ in offTmux }
        )
        defer { offGhostty.shutdown(); offBrowser.shutdown() }
        let (_, offDescriptor) = try spawnAndDescriptor(spawner: offSpawner, store: offStore, canvas: offCanvas)
        try expect(offDescriptor.command != fakeTmux.path, "toggle-off should fall back to bare shell command")
        try expect(!offDescriptor.args.contains("new-session"), "toggle-off should not include tmux argv")
        try expect(offDescriptor.cwd == offRoot.path, "toggle-off should preserve bare cwd")
        try expect(offTmux.log.isEmpty, "tmux-disabled spawn/restart path should not call TmuxControl, log=\(offTmux.log)")

        let absentDefaults = makeDefaults(enabled: true, path: "")
        let (absentSpawner, absentStore, absentCanvas, absentBrowser, absentGhostty) = try makeSpawner(
            root: absentRoot,
            defaults: absentDefaults,
            resolver: { _ in nil }
        )
        defer { absentGhostty.shutdown(); absentBrowser.shutdown() }
        let (_, absentDescriptor) = try spawnAndDescriptor(spawner: absentSpawner, store: absentStore, canvas: absentCanvas)
        try expect(absentDescriptor.command != fakeTmux.path, "tmux-absent should fall back to bare shell command")
        try expect(!absentDescriptor.args.contains("new-session"), "tmux-absent should not include tmux argv")
        try expect(absentDescriptor.cwd == absentRoot.path, "tmux-absent should preserve bare cwd")

        let manifest: [String: Any] = [
            "check": "terminal-tmux-persistence",
            "fakeTmux": fakeTmux.path,
            "enabled": [
                "tileId": spawnedTile.id.uuidString,
                "sessionName": expectedSessionName,
                "spawnCommand": spawnedDescriptor.command,
                "spawnArgs": spawnedDescriptor.args,
                "restartCommand": restartedDescriptor.command,
                "restartArgs": restartedDescriptor.args
            ],
            "projectWindow": [
                "sessionName": projectSessionName,
                "targets": projectTargets,
                "descriptors": projectDescriptors.map { ["tileId": $0.tileId.uuidString, "args": $0.args] },
                "liveRestart": [
                    "tileId": restartTileId.uuidString,
                    "target": liveTargetBeforeRestart ?? "",
                    "args": restartedLiveDescriptor.args
                ],
                "deadRestart": [
                    "tileId": restartTileId.uuidString,
                    "target": deadRestartTarget ?? "",
                    "args": restartedDeadDescriptor.args
                ],
                "flushPreservedTarget": projectTargets[0],
                "flushCwd": flushDescriptorAfter.cwd,
                "log": projectTmux.log.map(String.init(describing:))
            ],
            "ambientWorkspace": [
                "sessionName": ambientSessionName,
                "targets": ambientTargets,
                "descriptors": ambientDescriptors.enumerated().map { ["args": $0.element.args, "target": ambientTargets[$0.offset]] },
                "log": ambientTmux.log.map(String.init(describing:))
            ],
            "ambientFallbackOff": [
                "workspaceId": ambientOffWorkspaceId.uuidString,
                "tileSessionName": expectedAmbientOffSessionName,
                "target": NSNull(),
                "args": ambientOffDescriptor.args,
                "log": ambientOffTmux.log.map(String.init(describing:))
            ],
            "toggleOff": ["command": offDescriptor.command, "args": offDescriptor.args, "cwd": offDescriptor.cwd],
            "tmuxAbsent": ["command": absentDescriptor.command, "args": absentDescriptor.args, "cwd": absentDescriptor.cwd]
        ]
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let directory = URL(fileURLWithPath: fileManager.currentDirectoryPath)
            .appendingPathComponent("qa-runs", isDirectory: true)
            .appendingPathComponent(timestamp, isDirectory: true)
            .appendingPathComponent("terminal-tmux-persistence", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let artifact = directory.appendingPathComponent("manifest.json")
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(to: artifact, options: .atomic)
        return artifact
    }

    /// App-level I2 witness. This deliberately drives the production
    /// TileSpawner fresh/restart scenarios above, then independently reads the
    /// emitted behavior artifact and rejects any direct shared-session attach.
    static func runTerminalTmuxNoMirrorSelfCheck() throws -> URL {
        enum CheckError: Error, CustomStringConvertible {
            case failed(String)
            var description: String {
                if case let .failed(message) = self { return message }
                return "failed"
            }
        }
        func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw CheckError.failed(message) }
        }

        let sourceArtifact = try runTerminalTmuxPersistenceSelfCheck()
        guard let root = try JSONSerialization.jsonObject(with: Data(contentsOf: sourceArtifact)) as? [String: Any],
              let project = root["projectWindow"] as? [String: Any],
              let sessionName = project["sessionName"] as? String,
              let targets = project["targets"] as? [String],
              let descriptors = project["descriptors"] as? [[String: Any]],
              let liveRestart = project["liveRestart"] as? [String: Any],
              let deadRestart = project["deadRestart"] as? [String: Any]
        else {
            throw CheckError.failed("production persistence artifact omitted project no-mirror evidence")
        }
        try require(targets.count >= 2 && Set(targets).count == targets.count, "fresh project targets must be distinct: \(targets)")

        var freshViews: Set<String> = []
        for (index, descriptor) in descriptors.enumerated() {
            guard let tileIdString = descriptor["tileId"] as? String,
                  let tileId = UUID(uuidString: tileIdString),
                  let args = descriptor["args"] as? [String]
            else { throw CheckError.failed("malformed fresh project descriptor evidence") }
            let viewName = TmuxSession.viewSessionName(tileId: tileId)
            freshViews.insert(viewName)
            let expected = ["new-session", "-t", sessionName, "-s", viewName, "-A", ";", "select-window", "-t", targets[index]]
            try require(args == expected, "fresh project tile did not use production grouped-view argv: \(args)")
            try require(args != ["attach-session", "-t", targets[index]], "fresh project tile used forbidden bare attach")
        }
        try require(freshViews.count == descriptors.count, "fresh project tiles must use distinct stable view names")

        guard let restartTileIdString = liveRestart["tileId"] as? String,
              let restartTileId = UUID(uuidString: restartTileIdString),
              let liveTarget = liveRestart["target"] as? String,
              let liveArgs = liveRestart["args"] as? [String],
              let deadTarget = deadRestart["target"] as? String,
              let deadArgs = deadRestart["args"] as? [String]
        else { throw CheckError.failed("malformed restart no-mirror evidence") }
        let stableView = TmuxSession.viewSessionName(tileId: restartTileId)
        try require(liveTarget != deadTarget, "dead restart must replace the pane target")
        try require(liveArgs == ["new-session", "-t", sessionName, "-s", stableView, "-A", ";", "select-window", "-t", liveTarget], "live restart did not repin stable view")
        try require(deadArgs == ["new-session", "-t", sessionName, "-s", stableView, "-A", ";", "select-window", "-t", deadTarget], "dead restart did not repin the same stable view")

        let directory = sourceArtifact.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("terminal-tmux-no-mirror", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let artifact = directory.appendingPathComponent("manifest.json")
        let manifest: [String: Any] = [
            "check": "terminal-tmux-no-mirror",
            "sourceArtifact": sourceArtifact.path,
            "baseSession": sessionName,
            "freshTargets": targets,
            "freshViews": freshViews.sorted(),
            "stableRestartView": stableView,
            "liveRestartTarget": liveTarget,
            "deadRestartTarget": deadTarget,
            "bareAttachRejected": true
        ]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: artifact, options: .atomic)
        return artifact
    }

    // MARK: - tmux live integration check

    static func runTerminalTmuxLiveIntegrationSelfCheck() throws -> (message: String, artifact: URL?) {
        enum CheckError: Error, CustomStringConvertible {
            case failed(String)
            var description: String {
                switch self {
                case let .failed(message): return message
                }
            }
        }
        struct CommandResult {
            let status: Int32
            let stdout: String
            let stderr: String
        }
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw CheckError.failed(message) }
        }
        func run(_ command: String, _ arguments: [String], allowFailure: Bool = false) throws -> CommandResult {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: command)
            process.arguments = arguments
            let out = Pipe()
            let err = Pipe()
            process.standardOutput = out
            process.standardError = err
            try process.run()
            process.waitUntilExit()
            let result = CommandResult(
                status: process.terminationStatus,
                stdout: String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
                stderr: String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            )
            if !allowFailure && result.status != 0 {
                throw CheckError.failed("command failed (\(result.status)): \(command) \(arguments.joined(separator: " ")) stdout=\(result.stdout) stderr=\(result.stderr)")
            }
            return result
        }
        func artifact(_ manifest: [String: Any]) throws -> URL {
            let fileManager = FileManager.default
            let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
            let directory = URL(fileURLWithPath: fileManager.currentDirectoryPath)
                .appendingPathComponent("qa-runs", isDirectory: true)
                .appendingPathComponent(timestamp, isDirectory: true)
                .appendingPathComponent("terminal-tmux-live-integration", isDirectory: true)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let path = directory.appendingPathComponent("manifest.json")
            try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(to: path, options: .atomic)
            return path
        }
        func headlessArguments(from wrapped: LaunchProfile) -> [String] {
            precondition(wrapped.arguments.first == "new-session")
            return ["new-session", "-d"] + wrapped.arguments.dropFirst()
        }
        func comparablePath(_ path: String) -> String {
            path.hasPrefix("/private/var/") ? String(path.dropFirst("/private".count)) : path
        }
        func paneState(tmuxPath: String, sessionName: String) throws -> (paneId: String, cwd: String) {
            let result = try run(tmuxPath, ["list-panes", "-t", sessionName, "-F", "#{pane_id}\t#{pane_current_path}"])
            let line = result.stdout.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2 else {
                throw CheckError.failed("could not parse tmux pane state: \(result.stdout)")
            }
            return (parts[0], parts[1])
        }
        func waitForCwd(tmuxPath: String, sessionName: String, cwd: String) throws -> (paneId: String, cwd: String) {
            var last: (paneId: String, cwd: String)?
            for _ in 0..<30 {
                last = try paneState(tmuxPath: tmuxPath, sessionName: sessionName)
                if comparablePath(last?.cwd ?? "") == comparablePath(cwd) { return last! }
                usleep(100_000)
            }
            throw CheckError.failed("pane cwd did not become \(cwd); last=\(String(describing: last))")
        }
        func looksLikeTmuxVersion(_ output: String) -> Bool {
            guard output.lowercased().hasPrefix("tmux") else { return false }
            let suffix = output.dropFirst(4)
            return suffix.first.map { $0.isWhitespace } ?? true
        }
        func shellSingleQuoted(_ value: String) -> String {
            "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        func pump(_ context: GhosttyRuntimeContext, seconds: TimeInterval) throws {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                ghostty_app_tick(try context.app)
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.03))
            }
        }
        func pump(_ context: GhosttyRuntimeContext, timeout: TimeInterval, waitingFor label: String, until condition: () -> Bool) throws {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if condition() { return }
                try pump(context, seconds: 0.06)
            }
            throw CheckError.failed("timed out waiting for \(label)")
        }
        func makeWindow(canvas: CanvasNSView, origin: CGPoint) -> NSWindow {
            let window = NSWindow(
                contentRect: NSRect(x: origin.x, y: origin.y, width: 1000, height: 700),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.contentView = canvas
            window.orderFront(nil)
            return window
        }

        guard let tmuxPath = TmuxLocator.resolve() else {
            let path = try artifact([
                "check": "terminal-tmux-live-integration",
                "status": "skipped",
                "reason": "tmux did not resolve from configured path, PATH, or standard fallback paths"
            ])
            return ("SKIP: terminal-tmux-live-integration-check no real tmux resolved; artifact: \(path.path)", path)
        }

        let fileManager = FileManager.default
        guard fileManager.isExecutableFile(atPath: tmuxPath) else {
            let path = try artifact([
                "check": "terminal-tmux-live-integration",
                "status": "skipped",
                "reason": "resolved tmux path is not executable",
                "tmuxPath": tmuxPath
            ])
            return ("SKIP: terminal-tmux-live-integration-check resolved tmux path is not executable; artifact: \(path.path)", path)
        }

        let version = try run(tmuxPath, ["-V"], allowFailure: true)
        guard version.status == 0 && looksLikeTmuxVersion(version.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            let path = try artifact([
                "check": "terminal-tmux-live-integration",
                "status": "skipped",
                "reason": "resolved executable did not behave like tmux -V",
                "tmuxPath": tmuxPath,
                "tmuxVersionStatus": version.status,
                "tmuxVersionStdout": version.stdout,
                "tmuxVersionStderr": version.stderr
            ])
            return ("SKIP: terminal-tmux-live-integration-check resolved executable is not real tmux; artifact: \(path.path)", path)
        }

        let tileId = UUID()
        let sessionName = TmuxSession.sessionName(tileId: tileId)
        let root = fileManager.temporaryDirectory.appendingPathComponent("continuum-tmux-live-\(tileId.uuidString)", isDirectory: true)
        let startCwd = root.appendingPathComponent("start", isDirectory: true)
        let changedCwd = root.appendingPathComponent("changed", isDirectory: true)
        let restartCwd = root.appendingPathComponent("restart", isDirectory: true)
        try [startCwd, changedCwd, restartCwd].forEach { try fileManager.createDirectory(at: $0, withIntermediateDirectories: true) }
        let startCwdPath = (startCwd.path as NSString).resolvingSymlinksInPath
        let changedCwdPath = (changedCwd.path as NSString).resolvingSymlinksInPath
        let restartCwdPath = (restartCwd.path as NSString).resolvingSymlinksInPath
        let kill = TmuxSession.killSessionCommand(tileId: tileId, tmuxPath: tmuxPath)
        defer {
            _ = try? run(kill.command, kill.arguments, allowFailure: true)
            try? fileManager.removeItem(at: root)
        }

        let profile = LaunchProfile(command: "/bin/sh", arguments: [], cwd: startCwdPath, title: "Shell")
        let wrapped = TmuxSession.wrap(profile: profile, tileId: tileId, tmuxPath: tmuxPath)
        let createArgs = headlessArguments(from: wrapped)
        try expect(wrapped.command == tmuxPath, "wrapped profile should use resolved tmux path")
        try expect(!createArgs.contains("-L"), "live integration check must use the default tmux server and no -L socket")
        try expect(createArgs.contains("-A") && createArgs.contains("-s") && createArgs.contains(sessionName) && createArgs.contains("-c") && createArgs.contains(startCwdPath), "create args should preserve new-session -A -s name -c cwd semantics: \(createArgs)")
        _ = try run(tmuxPath, createArgs)
        let createdPane = try waitForCwd(tmuxPath: tmuxPath, sessionName: sessionName, cwd: startCwdPath)

        _ = try run(tmuxPath, ["send-keys", "-t", sessionName, "cd \(shellSingleQuoted(changedCwdPath))", "C-m"])
        let changedPane = try waitForCwd(tmuxPath: tmuxPath, sessionName: sessionName, cwd: changedCwdPath)
        try expect(changedPane.paneId == createdPane.paneId, "pane id should survive cwd change")

        let restartProfile = LaunchProfile(command: "/bin/sh", arguments: [], cwd: restartCwdPath, title: "Shell")
        let restartWrapped = TmuxSession.wrap(profile: restartProfile, tileId: tileId, tmuxPath: tmuxPath)
        let restartArgs = restartWrapped.arguments
        let scriptedReattachArgs = ["-q", "/dev/null", tmuxPath] + restartArgs + [";", "detach-client"]
        try expect(!restartArgs.contains("-L"), "restart/reattach args must use default tmux server and no -L socket")
        _ = try run("/usr/bin/script", scriptedReattachArgs)
        let reattachedPane = try waitForCwd(tmuxPath: tmuxPath, sessionName: sessionName, cwd: changedCwdPath)
        try expect(reattachedPane.paneId == createdPane.paneId, "reattach should preserve the existing pane id")
        try expect(comparablePath(reattachedPane.cwd) == comparablePath(changedCwdPath), "reattach should preserve live pane cwd and ignore restart -c cwd")

        let killResult = try run(kill.command, kill.arguments)
        let postKill = try run(tmuxPath, ["has-session", "-t", sessionName], allowFailure: true)
        try expect(postKill.status != 0, "cleanup should remove the isolated test session")

        // Product-path phase: spawn a terminal tile through TileSpawner + Ghostty,
        // detach the Ghostty client like an app quit, prune the descriptor like boot,
        // then reload the canvas and restart the same tile id. This catches checks
        // that only exercise raw tmux CLI construction and never prove the app path.
        let realRoot = fileManager.temporaryDirectory.appendingPathComponent("continuum-tmux-real-\(UUID().uuidString)", isDirectory: true)
        let realChangedCwd = realRoot.appendingPathComponent("changed", isDirectory: true)
        try [realRoot, realChangedCwd].forEach { try fileManager.createDirectory(at: $0, withIntermediateDirectories: true) }
        let realRootPath = (realRoot.path as NSString).resolvingSymlinksInPath
        let realChangedCwdPath = (realChangedCwd.path as NSString).resolvingSymlinksInPath
        let realDefaultsSuiteName = "continuum.tmux-live-real.\(UUID().uuidString)"
        let realDefaults = UserDefaults(suiteName: realDefaultsSuiteName)!
        realDefaults.removePersistentDomain(forName: realDefaultsSuiteName)
        realDefaults.set(true, forKey: TmuxPersistenceConfig.enabledKey)
        realDefaults.set(tmuxPath, forKey: TmuxPersistenceConfig.pathKey)
        defer {
            realDefaults.removePersistentDomain(forName: realDefaultsSuiteName)
            try? fileManager.removeItem(at: realRoot)
        }

        let realProject = Project(
            id: UUID(),
            name: "terminal-tmux-real-restart-check",
            rootPath: realRootPath,
            createdAt: Date(),
            updatedAt: Date(),
            defaultLaunchProfileId: "shell",
            editorPreference: .auto,
            settings: ProjectSettings(restorePolicy: .restoreDescriptors, browserStoragePolicy: .perProject, terminalClosePolicy: .askWhenRunning)
        )
        let realStore = ProjectStore(projectRoot: realRoot)
        try realStore.saveProject(realProject)
        try realStore.saveCanvas(CanvasState(viewport: CanvasViewport(x: 0, y: 0, zoom: 1), tiles: [], groups: [], lastActiveTileId: nil))

        let realContext1 = try GhosttyRuntimeContext()
        let realBrowser1 = BrowserEngineContext()
        let realCanvas1 = CanvasNSView(canvasState: try realStore.loadCanvas())
        realCanvas1.setFrameSize(CGSize(width: 1000, height: 700))
        let realWindow1 = makeWindow(canvas: realCanvas1, origin: CGPoint(x: 120, y: 120))
        let realSpawner1 = TileSpawner(
            canvasView: realCanvas1,
            ghostty: realContext1,
            browserEngine: realBrowser1,
            projectStore: realStore,
            project: realProject,
            defaults: realDefaults,
            tmuxPathResolver: { _ in tmuxPath }
        )
        realSpawner1.terminalSessionTargetProvider = { .project(projectId: realProject.id) }

        let realRuntime1: GhosttyTerminalRuntime
        switch realSpawner1.spawnTerminal(profileId: "shell") {
        case let .spawned(runtime): realRuntime1 = runtime
        case let .unknownProfile(id): throw CheckError.failed("real app spawn unknown profile: \(id)")
        case let .missingCommand(executable): throw CheckError.failed("real app spawn missing command: \(executable)")
        case let .notConfigured(profileId): throw CheckError.failed("real app spawn not configured: \(profileId)")
        case let .failure(error): throw error
        }
        guard let realTile = realCanvas1.canvasState.tiles.first(where: { $0.id == realRuntime1.tileId }) else {
            throw CheckError.failed("real app spawn did not persist a terminal tile")
        }
        let realSessionName = TmuxSession.projectSessionName(projectId: realProject.id)
        let realViewSessionName = TmuxSession.viewSessionName(tileId: realTile.id)
        let realKill = TmuxSession.killProjectSessionCommand(projectId: realProject.id, tmuxPath: tmuxPath)
        var shouldRunRealDeferKill = true
        defer {
            if shouldRunRealDeferKill {
                _ = try? run(tmuxPath, ["kill-session", "-t", realViewSessionName], allowFailure: true)
                _ = try? run(realKill.command, realKill.arguments, allowFailure: true)
            }
        }
        guard let realSpawnDescriptor = try realStore.listSessions().first(where: { $0.tileId == realTile.id }) else {
            throw CheckError.failed("real shared app spawn did not persist its terminal descriptor")
        }
        try expect(realSpawnDescriptor.args.contains(realViewSessionName) && realSpawnDescriptor.args.contains(realSessionName), "real app spawn must launch through the production grouped view: \(realSpawnDescriptor.args)")

        let realMarker = "a05-real-\(String(UUID().uuidString.prefix(8)))"
        try pump(realContext1, timeout: 8.0, waitingFor: "initial real terminal surface") {
            realRuntime1.qaTerminalView?.surface != nil
        }
        realRuntime1.sendInput(Data("printf '\(realMarker)-start-%s\\n' \"$(pwd)\"\n".utf8))
        try pump(realContext1, timeout: 8.0, waitingFor: "initial real terminal input") {
            realRuntime1.visibleText().contains("\(realMarker)-start-")
        }
        realRuntime1.sendInput(Data("cd \(shellSingleQuoted(realChangedCwdPath)) && printf '\(realMarker)-changed-%s\\n' \"$(pwd)\"\n".utf8))
        try pump(realContext1, timeout: 8.0, waitingFor: "real terminal cwd change") {
            realRuntime1.visibleText().contains("\(realMarker)-changed-")
        }
        let realPaneBeforeDetach = try waitForCwd(tmuxPath: tmuxPath, sessionName: realSessionName, cwd: realChangedCwdPath)

        realRuntime1.terminate(policy: .force)
        if let terminalTile = realCanvas1.tileView(for: realTile.id) as? TerminalTileNSView {
            terminalTile.hostView.detachRuntime()
        }
        try pump(realContext1, seconds: 0.4)
        realWindow1.close()
        realBrowser1.shutdown()
        realContext1.shutdown()

        guard var descriptorBeforePrune = try realStore.listSessions().first(where: { $0.tileId == realTile.id }) else {
            throw CheckError.failed("real app spawn did not save a terminal descriptor")
        }
        descriptorBeforePrune.lastExit = TerminalLastExit(exitCode: nil, signal: nil, at: Date())
        try realStore.saveSession(descriptorBeforePrune)
        pruneExitedSessions(in: realStore)
        let descriptorsPrunedOnBoot = try !realStore.listSessions().contains { $0.tileId == realTile.id }
        try expect(descriptorsPrunedOnBoot, "boot prune should remove app-close-stamped terminal descriptor before restart")
        let sessionSurvivedAppDetach = try run(tmuxPath, ["has-session", "-t", realSessionName], allowFailure: true).status == 0
        try expect(sessionSurvivedAppDetach, "tmux session should survive Ghostty/app detach for tile \(realTile.id)")

        let realContext2 = try GhosttyRuntimeContext()
        let realBrowser2 = BrowserEngineContext()
        let realCanvas2 = CanvasNSView(canvasState: try realStore.loadCanvas())
        realCanvas2.setFrameSize(CGSize(width: 1000, height: 700))
        let realWindow2 = makeWindow(canvas: realCanvas2, origin: CGPoint(x: 180, y: 180))
        let realSpawner2 = TileSpawner(
            canvasView: realCanvas2,
            ghostty: realContext2,
            browserEngine: realBrowser2,
            projectStore: realStore,
            project: realProject,
            defaults: realDefaults,
            tmuxPathResolver: { _ in tmuxPath }
        )
        realSpawner2.terminalSessionTargetProvider = { .project(projectId: realProject.id) }
        let realRuntime2: GhosttyTerminalRuntime
        switch realSpawner2.restartTerminalTile(tileId: realTile.id) {
        case let .restarted(runtime): realRuntime2 = runtime
        case let .unknownProfile(id): throw CheckError.failed("real app restart unknown profile: \(id)")
        case let .missingCommand(executable): throw CheckError.failed("real app restart missing command: \(executable)")
        case let .notConfigured(profileId): throw CheckError.failed("real app restart not configured: \(profileId)")
        case .tileNotFound: throw CheckError.failed("real app restart lost the terminal tile")
        case let .failure(error): throw error
        }
        try pump(realContext2, timeout: 8.0, waitingFor: "restarted real terminal surface") {
            realRuntime2.qaTerminalView?.surface != nil
        }
        try pump(realContext2, timeout: 8.0, waitingFor: "tmux scrollback in restarted terminal") {
            realRuntime2.visibleText().contains("\(realMarker)-changed-")
        }
        let realPaneAfterRestart = try waitForCwd(tmuxPath: tmuxPath, sessionName: realSessionName, cwd: realChangedCwdPath)
        try expect(realPaneAfterRestart.paneId == realPaneBeforeDetach.paneId, "real app restart should reattach the same tmux pane")
        guard let realRestartDescriptor = try realStore.listSessions().first(where: { $0.tileId == realTile.id }) else {
            throw CheckError.failed("real shared app restart did not persist its terminal descriptor")
        }
        try expect(realRestartDescriptor.args.contains(realViewSessionName) && realRestartDescriptor.args.contains(realSessionName), "real app restart must reuse the production grouped view: \(realRestartDescriptor.args)")
        realRuntime2.sendInput(Data("printf '\(realMarker)-after-%s\\n' \"$(pwd)\"\n".utf8))
        try pump(realContext2, timeout: 8.0, waitingFor: "input after real app restart") {
            realRuntime2.visibleText().contains("\(realMarker)-after-")
        }
        let inputAfterRestartWorked = realRuntime2.visibleText().contains("\(realMarker)-after-")
        let scrollbackVisibleAfterRestart = realRuntime2.visibleText().contains("\(realMarker)-changed-")

        realRuntime2.terminate(policy: .force)
        if let terminalTile = realCanvas2.tileView(for: realTile.id) as? TerminalTileNSView {
            terminalTile.hostView.detachRuntime()
        }
        try pump(realContext2, seconds: 0.4)
        realWindow2.close()
        realBrowser2.shutdown()
        realContext2.shutdown()
        _ = try run(tmuxPath, ["kill-session", "-t", realViewSessionName], allowFailure: true)
        let realKillResult = try run(realKill.command, realKill.arguments)
        shouldRunRealDeferKill = false
        let realPostKill = try run(tmuxPath, ["has-session", "-t", realSessionName], allowFailure: true)
        try expect(realPostKill.status != 0, "real app cleanup should remove tmux session \(realSessionName)")

        let realAppManifest: [String: Any] = [
            "status": "passed",
            "projectRoot": realRootPath,
            "tileId": realTile.id.uuidString,
            "sessionName": realSessionName,
            "viewSessionName": realViewSessionName,
            "spawnArgs": realSpawnDescriptor.args,
            "restartArgs": realRestartDescriptor.args,
            "marker": realMarker,
            "descriptorPrunedOnBoot": descriptorsPrunedOnBoot,
            "sessionSurvivedAppDetach": sessionSurvivedAppDetach,
            "paneBeforeDetach": ["paneId": realPaneBeforeDetach.paneId, "cwd": realPaneBeforeDetach.cwd],
            "paneAfterRestart": ["paneId": realPaneAfterRestart.paneId, "cwd": realPaneAfterRestart.cwd],
            "scrollbackVisibleAfterRestart": scrollbackVisibleAfterRestart,
            "inputAfterRestartWorked": inputAfterRestartWorked,
            "killCommand": [realKill.command] + realKill.arguments,
            "killExitStatus": realKillResult.status,
            "postKillHasSessionStatus": realPostKill.status
        ]

        let closeLifecycleProjectId = UUID()
        let closeLifecycleSessionName = TmuxSession.projectSessionName(projectId: closeLifecycleProjectId)
        let closeLifecycleRoot = fileManager.temporaryDirectory.appendingPathComponent("continuum-tmux-close-\(closeLifecycleProjectId.uuidString)", isDirectory: true)
        let closeLifecycleCwd = (closeLifecycleRoot.path as NSString).resolvingSymlinksInPath
        try fileManager.createDirectory(at: closeLifecycleRoot, withIntermediateDirectories: true)
        let closeLifecycleKillSession = TmuxSession.killProjectSessionCommand(projectId: closeLifecycleProjectId, tmuxPath: tmuxPath)
        var shouldCleanupCloseLifecycleSession = true
        defer {
            if shouldCleanupCloseLifecycleSession {
                _ = try? run(closeLifecycleKillSession.command, closeLifecycleKillSession.arguments, allowFailure: true)
            }
            try? fileManager.removeItem(at: closeLifecycleRoot)
        }
        func captureCloseLifecycleSnapshot() throws -> SessionTopologySnapshot {
            let output = try run(tmuxPath, ["list-windows", "-a", "-F", SessionTopologySnapshot.tmuxFormatString], allowFailure: true)
            guard output.status == 0 || output.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CheckError.failed("tmux list-windows failed while capturing close lifecycle snapshot: stdout=\(output.stdout) stderr=\(output.stderr)")
            }
            return try SessionTopologySnapshot.parse(tmuxOutput: output.stdout)
        }
        func closeLifecycleWindowCount() throws -> Int {
            try captureCloseLifecycleSnapshot().session(named: closeLifecycleSessionName)?.windows.count ?? 0
        }

        let closePane1 = try run(tmuxPath, [
            "new-session", "-d", "-s", closeLifecycleSessionName, "-c", closeLifecycleCwd, "-P", "-F", "#{pane_id}"
        ]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let closePane2 = try run(tmuxPath, TmuxSession.newWindowArguments(projectSessionName: closeLifecycleSessionName, cwd: closeLifecycleCwd, innerCommand: nil)).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let closePane3 = try run(tmuxPath, TmuxSession.newWindowArguments(projectSessionName: closeLifecycleSessionName, cwd: closeLifecycleCwd, innerCommand: nil)).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        try expect([closePane1, closePane2, closePane3].allSatisfy(TmuxSession.isValidPaneId), "project close lifecycle panes must be captured as pane ids: \([closePane1, closePane2, closePane3])")
        let closeSnapshotBefore = try captureCloseLifecycleSnapshot()
        let closeWindowsBefore = closeSnapshotBefore.session(named: closeLifecycleSessionName)?.windows.count ?? 0
        try expect(closeWindowsBefore == 3, "project close lifecycle should start with three tmux windows, got \(closeWindowsBefore)")

        let closeKillMiddle = TmuxSession.killWindowCommand(target: closePane2, tmuxPath: tmuxPath)
        let closeKillMiddleResult = try run(closeKillMiddle.command, closeKillMiddle.arguments)
        let closeSnapshotAfterOne = try captureCloseLifecycleSnapshot()
        let closeWindowsAfterOne = closeSnapshotAfterOne.session(named: closeLifecycleSessionName)?.windows.count ?? 0
        try expect(closeWindowsAfterOne == 2, "killing one captured pane should leave two project windows, got \(closeWindowsAfterOne)")
        try expect(closeSnapshotAfterOne.window(paneId: closePane2) == nil, "killed pane should disappear from topology snapshot")
        try expect(closeSnapshotAfterOne.window(paneId: closePane1) != nil && closeSnapshotAfterOne.window(paneId: closePane3) != nil, "other project panes should remain after one window close")

        let closeKillFirst = TmuxSession.killWindowCommand(target: closePane1, tmuxPath: tmuxPath)
        let closeKillThird = TmuxSession.killWindowCommand(target: closePane3, tmuxPath: tmuxPath)
        _ = try run(closeKillFirst.command, closeKillFirst.arguments)
        let closeWindowsAfterTwo = try closeLifecycleWindowCount()
        try expect(closeWindowsAfterTwo == 1, "killing two of three captured panes should leave one project window, got \(closeWindowsAfterTwo)")
        let closeKillThirdResult = try run(closeKillThird.command, closeKillThird.arguments)
        shouldCleanupCloseLifecycleSession = false
        let closeSnapshotAfterAll = try captureCloseLifecycleSnapshot()
        let closeWindowsAfterAll = closeSnapshotAfterAll.session(named: closeLifecycleSessionName)?.windows.count ?? 0
        let closePostKillHasSession = try run(tmuxPath, ["has-session", "-t", closeLifecycleSessionName], allowFailure: true)
        try expect(closeWindowsAfterAll == 0, "killing the last project window should remove the session from topology, got \(closeWindowsAfterAll)")
        try expect(closePostKillHasSession.status != 0, "killing the last project window should let tmux reap the project session")
        let closeLifecycleManifest: [String: Any] = [
            "status": "passed",
            "projectId": closeLifecycleProjectId.uuidString,
            "sessionName": closeLifecycleSessionName,
            "paneTargets": [closePane1, closePane2, closePane3],
            "windowsBefore": closeWindowsBefore,
            "windowsAfterOneClose": closeWindowsAfterOne,
            "windowsAfterTwoCloses": closeWindowsAfterTwo,
            "windowsAfterAllClosed": closeWindowsAfterAll,
            "killOneCommand": [closeKillMiddle.command] + closeKillMiddle.arguments,
            "killOneExitStatus": closeKillMiddleResult.status,
            "killLastCommand": [closeKillThird.command] + closeKillThird.arguments,
            "killLastExitStatus": closeKillThirdResult.status,
            "postLastCloseHasSessionStatus": closePostKillHasSession.status,
            "snapshotBefore": try String(data: JSONEncoder().encode(closeSnapshotBefore), encoding: .utf8) ?? "",
            "snapshotAfterOneClose": try String(data: JSONEncoder().encode(closeSnapshotAfterOne), encoding: .utf8) ?? "",
            "snapshotAfterAllClosed": try String(data: JSONEncoder().encode(closeSnapshotAfterAll), encoding: .utf8) ?? ""
        ]

        let manifestPath = try artifact([
            "check": "terminal-tmux-live-integration",
            "status": "passed",
            "tmuxPath": tmuxPath,
            "tmuxVersion": version.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            "usesDefaultTmuxServer": true,
            "socketFlagPresent": createArgs.contains("-L") || restartArgs.contains("-L"),
            "headlessDetachedFlag": "-d is inserted for initial creation because tmux new-session without -d requires an interactive controlling terminal. The simulated restart uses /usr/bin/script to provide a pseudo-terminal for the real new-session -A -s name -c cwd reattach path, then immediately detaches the tmux client.",
            "tileId": tileId.uuidString,
            "sessionName": sessionName,
            "createArgs": createArgs,
            "restartArgs": restartArgs,
            "scriptedReattachCommand": ["/usr/bin/script"] + scriptedReattachArgs,
            "createdPaneId": createdPane.paneId,
            "changedPaneId": changedPane.paneId,
            "reattachedPaneId": reattachedPane.paneId,
            "startCwd": startCwdPath,
            "changedCwd": changedCwdPath,
            "restartCwdIgnoredOnAttach": restartCwdPath,
            "reattachedCwd": reattachedPane.cwd,
            "killCommand": [kill.command] + kill.arguments,
            "killExitStatus": killResult.status,
            "postKillHasSessionStatus": postKill.status,
            "realAppRestart": realAppManifest,
            "projectCloseWindowLifecycle": closeLifecycleManifest
        ])
        return ("ContinuumRevivedTerminalTmuxLiveIntegrationChecks passed: \(manifestPath.path)", manifestPath)
    }

    // MARK: - File tree tiles

    func spawnFileTree(rootPath: String, at worldPoint: CGPoint? = nil) -> FileTreeOutcome {
        guard let canvasView else { return .failure(SpawnError.canvasUnavailable) }
        let trimmedRootPath = rootPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRootPath.isEmpty else { return .invalidPath }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: trimmedRootPath, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return .invalidPath
        }

        let frame = makePlacement(
            worldPoint: worldPoint,
            size: CanvasEngine.defaultFrame(for: .fileTree),
            in: canvasView
        )
        let nextZ = CanvasEngine.zPositionAbove(canvasView.canvasState.tiles)
        let tile = Tile(
            id: UUID(),
            kind: .fileTree,
            title: URL(fileURLWithPath: trimmedRootPath, isDirectory: true).lastPathComponent,
            frame: frame,
            zPosition: nextZ,
            runtimeRef: nil,
            metadata: TileMetadata(filePath: URL(fileURLWithPath: trimmedRootPath, isDirectory: true).standardizedFileURL.path)
        )
        let fileTreeTile = defaultFileTreeTile(tileId: tile.id, rootPath: trimmedRootPath)
        do {
            try upsertFileTreeTile(fileTreeTile)
        } catch {
            return .failure(error)
        }

        let viewModel = installFileTreeView(tile, fileTreeTile: fileTreeTile, in: canvasView)
        do {
            try projectStore.saveCanvas(canvasView.canvasState)
        } catch {
            return .failure(error)
        }
        return .spawned(tileId: tile.id, viewModel: viewModel)
    }

    func restartFileTreeTile(tileId: UUID) -> FileTreeRestartOutcome {
        guard let canvasView else { return .failure(SpawnError.canvasUnavailable) }
        guard var existing = canvasView.canvasState.tiles.first(where: { $0.id == tileId }) else {
            return .tileNotFound
        }

        switch validatedFileTreeTile(for: existing) {
        case let .valid(fileTreeTile, backfilledDescriptorRoot):
            if let backfilledDescriptorRoot {
                existing.metadata.filePath = backfilledDescriptorRoot
                canvasView.updateTile(existing)
            }
            do {
                try upsertFileTreeTile(fileTreeTile)
                try projectStore.saveCanvas(canvasView.canvasState)
            } catch {
                return .failure(error)
            }
            let viewModel = installFileTreeView(existing, fileTreeTile: fileTreeTile, in: canvasView)
            return .restarted(viewModel)
        case let .recoverableError(fileTreeTile, message):
            let viewModel = installFileTreeErrorView(existing, fileTreeTile: fileTreeTile, message: message, in: canvasView)
            return .restarted(viewModel)
        }
    }

    func writeFileTreeTileSnapshot(for view: FileTreeTileNSView) {
        guard !view.isRecoverableError else { return }
        try? upsertFileTreeTile(view.currentFileTreeTile)
    }

    private func installFileTreeView(
        _ tile: Tile,
        fileTreeTile: FileTreeTile,
        in canvasView: CanvasNSView
    ) -> FileTreeViewModel {
        let viewModel = FileTreeViewModel()
        let view = FileTreeTileNSView(tile: tile, fileTreeTile: fileTreeTile, viewModel: viewModel)
        view.onPersist = { [weak self] _ in
            self?.fileTreePersistenceHandler?()
        }
        view.onSpawnFile = { [weak self] path in
            guard let self else { return }
            if let fileOpenHandler {
                fileOpenHandler(path, nil)
            } else {
                _ = spawnFile(path: path, title: URL(fileURLWithPath: path).lastPathComponent)
            }
        }
        view.onOpenFile = { [weak self] path in
            self?.openFileInPreferredEditor(path: path)
        }
        canvasView.install(tileView: view, for: tile)
        return viewModel
    }

    private func installFileTreeErrorView(
        _ tile: Tile,
        fileTreeTile: FileTreeTile,
        message: String,
        in canvasView: CanvasNSView
    ) -> FileTreeViewModel {
        let viewModel = FileTreeViewModel()
        let view = FileTreeTileNSView(tile: tile, fileTreeTile: fileTreeTile, recoverableErrorMessage: message)
        canvasView.install(tileView: view, for: tile)
        return viewModel
    }

    private func defaultFileTreeTile(tileId: UUID, rootPath: String) -> FileTreeTile {
        FileTreeTile(
            tileId: tileId,
            rootPath: rootPath,
            expandedPaths: [],
            selectedPath: nil,
            searchQuery: "",
            ignoredNames: Array(FileTreeScanner.defaultIgnoredNames).sorted(),
            gitBadges: .off
        )
    }

    func openFileInPreferredEditor(path: String) {
        if launchPreferredEditor(path: path) {
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: false))
    }

    private enum FileTreeValidationOutcome {
        case valid(FileTreeTile, backfilledDescriptorRoot: String?)
        case recoverableError(FileTreeTile, message: String)
    }

    private func validatedFileTreeTile(for tile: Tile) -> FileTreeValidationOutcome {
        let descriptorRoot = tile.metadata.filePath.map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL.path }
        do {
            guard let state = try projectStore.tryLoadFileTreeState() else {
                let kind = projectStore.fileTreeStateFileExists()
                    ? "corrupt"
                    : "missing"
                return .recoverableError(
                    defaultFileTreeTile(tileId: tile.id, rootPath: descriptorRoot ?? project.rootPath),
                    message: fileTreeValidationMessage(kind: kind, expectedRoot: descriptorRoot)
                )
            }
            guard let fileTreeTile = state.tiles.first(where: { $0.tileId == tile.id }) else {
                return .recoverableError(
                    defaultFileTreeTile(tileId: tile.id, rootPath: descriptorRoot ?? project.rootPath),
                    message: fileTreeValidationMessage(kind: "missing tile entry", expectedRoot: descriptorRoot)
                )
            }
            let sidecarRoot = URL(fileURLWithPath: fileTreeTile.rootPath, isDirectory: true).standardizedFileURL.path
            if let descriptorRoot, sidecarRoot != descriptorRoot {
                return .recoverableError(
                    defaultFileTreeTile(tileId: tile.id, rootPath: descriptorRoot),
                    message: fileTreeValidationMessage(kind: "root mismatch", expectedRoot: descriptorRoot, actualRoot: sidecarRoot)
                )
            }
            return .valid(fileTreeTile, backfilledDescriptorRoot: descriptorRoot == nil ? sidecarRoot : nil)
        } catch {
            return .recoverableError(
                defaultFileTreeTile(tileId: tile.id, rootPath: descriptorRoot ?? project.rootPath),
                message: fileTreeValidationMessage(kind: "corrupt", expectedRoot: descriptorRoot, detail: error.localizedDescription)
            )
        }
    }

    private func fileTreeValidationMessage(
        kind: String,
        expectedRoot: String?,
        actualRoot: String? = nil,
        detail: String? = nil
    ) -> String {
        var message = "File tree state \(kind)."
        if let expectedRoot {
            message += " Expected root: \(expectedRoot)."
        }
        if let actualRoot {
            message += " Sidecar root: \(actualRoot)."
        }
        if let detail {
            message += " \(detail)"
        }
        message += " This is recoverable: remove/recreate the file-tree tile or repair .array/file-tree/index.json."
        return message
    }

    private func existingFileTreeTile(for tileId: UUID) -> FileTreeTile? {
        guard let state = try? projectStore.tryLoadFileTreeState() else {
            return nil
        }
        return state.tiles.first { $0.tileId == tileId }
    }

    private func upsertFileTreeTile(_ fileTreeTile: FileTreeTile) throws {
        var state = (try? projectStore.tryLoadFileTreeState()) ?? FileTreeState(tiles: [])
        if let index = state.tiles.firstIndex(where: { $0.tileId == fileTreeTile.tileId }) {
            state.tiles[index] = fileTreeTile
        } else {
            state.tiles.append(fileTreeTile)
        }
        try projectStore.saveFileTreeState(state)
    }

    static func runFileTreeBootPersistenceSelfCheck() throws -> URL {
        enum CheckError: Error, CustomStringConvertible {
            case failed(String)

            var description: String {
                switch self {
                case let .failed(message): return message
                }
            }
        }

        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw CheckError.failed(message) }
        }

        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("continuum-file-tree-boot-persistence-\(UUID().uuidString)", isDirectory: true)
        let projectRoot = tempRoot.appendingPathComponent("project", isDirectory: true)
        try fileManager.createDirectory(at: projectRoot.appendingPathComponent("Sources/Deep", isDirectory: true), withIntermediateDirectories: true)
        try Data("needle\n".utf8).write(to: projectRoot.appendingPathComponent("Sources/Deep/Needle.swift"), options: .atomic)

        let now = Date()
        let project = Project(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000F02")!,
            name: "file-tree-boot-persistence-check",
            rootPath: projectRoot.path,
            createdAt: now,
            updatedAt: now,
            defaultLaunchProfileId: "shell",
            editorPreference: .auto,
            settings: ProjectSettings(
                restorePolicy: .restoreDescriptors,
                browserStoragePolicy: .perProject,
                terminalClosePolicy: .askWhenRunning
            )
        )
        let store = ProjectStore(projectRoot: projectRoot)
        try store.saveProject(project)

        let tileId = UUID(uuidString: "00000000-0000-0000-0000-000000000F03")!
        let tile = Tile(
            id: tileId,
            kind: .fileTree,
            title: "project",
            frame: TileFrame(x: 20, y: 20, width: 420, height: 360),
            zPosition: .fromLegacyRank(7),
            runtimeRef: nil,
            metadata: TileMetadata()
        )
        try store.saveCanvas(CanvasState(
            viewport: CanvasViewport(x: 13, y: 21, zoom: 1.25),
            tiles: [tile],
            groups: [],
            lastActiveTileId: tileId
        ))
        try store.saveFileTreeState(FileTreeState(tiles: [FileTreeTile(
            tileId: tileId,
            rootPath: projectRoot.path,
            expandedPaths: ["Sources"],
            selectedPath: "Sources/Deep/Needle.swift",
            searchQuery: "Needle.swift",
            ignoredNames: [".git", "node_modules"],
            gitBadges: .off
        )]))

        let browserEngine = BrowserEngineContext()
        defer { browserEngine.shutdown() }

        let firstCanvas = CanvasNSView(canvasState: try store.loadCanvas())
        let firstSpawner = TileSpawner(
            canvasView: firstCanvas,
            ghostty: nil,
            browserEngine: browserEngine,
            projectStore: store,
            project: project
        )
        switch firstSpawner.restartFileTreeTile(tileId: tileId) {
        case .restarted:
            break
        case .tileNotFound:
            throw CheckError.failed("first boot did not find file-tree tile")
        case let .failure(error):
            throw CheckError.failed("first boot failed: \(error)")
        }
        guard let firstView = firstCanvas.tileView(for: tileId) as? FileTreeTileNSView else {
            throw CheckError.failed("first boot did not install FileTreeTileNSView")
        }
        firstView.currentFileTreeTile.expandedPaths.forEach { _ in }
        firstSpawner.writeFileTreeTileSnapshot(for: firstView)
        try store.saveCanvas(firstCanvas.canvasState)

        let secondCanvas = CanvasNSView(canvasState: try store.loadCanvas())
        let secondSpawner = TileSpawner(
            canvasView: secondCanvas,
            ghostty: nil,
            browserEngine: browserEngine,
            projectStore: store,
            project: project
        )
        switch secondSpawner.restartFileTreeTile(tileId: tileId) {
        case .restarted:
            break
        case .tileNotFound:
            throw CheckError.failed("relaunch did not find file-tree tile")
        case let .failure(error):
            throw CheckError.failed("relaunch failed: \(error)")
        }
        guard let secondView = secondCanvas.tileView(for: tileId) as? FileTreeTileNSView else {
            throw CheckError.failed("relaunch did not install FileTreeTileNSView")
        }
        let persisted = try store.loadFileTreeState().tiles.first { $0.tileId == tileId }
        try expect(secondCanvas.canvasState.tiles.first?.kind == .fileTree, "relaunch canvas should retain file-tree tile kind")
        try expect(secondCanvas.canvasState.tiles.first?.runtimeRef == nil, "file-tree tile should not gain a runtimeRef")
        try expect(persisted?.rootPath == projectRoot.path, "file-tree state should retain root path")
        try expect(persisted?.expandedPaths == ["Sources"], "file-tree state should retain expanded paths")
        try expect(persisted?.selectedPath == "Sources/Deep/Needle.swift", "file-tree state should retain selected path")
        try expect(persisted?.searchQuery == "Needle.swift", "file-tree state should retain search query")
        try expect(secondView.currentFileTreeTile == persisted, "relaunch view should use persisted file-tree tile state")

        let searchManifest = try FileTreeTileNSView.runSearchVisibilitySelfCheck()
        let debounceManifest = try FileTreeTileNSView.runDebounceFlushSelfCheck()
        let manifest: [String: Any] = [
            "check": "file-tree-boot-persistence",
            "tempProjectRoot": projectRoot.path,
            "tileId": tileId.uuidString,
            "firstBootInstalled": true,
            "relaunchInstalled": true,
            "persistedRootPath": persisted?.rootPath as Any,
            "persistedExpandedPaths": persisted?.expandedPaths ?? [],
            "persistedSelectedPath": persisted?.selectedPath as Any,
            "persistedSearchQuery": persisted?.searchQuery as Any,
            "searchVisibility": searchManifest,
            "debounceFlush": debounceManifest
        ]
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let directory = URL(fileURLWithPath: fileManager.currentDirectoryPath)
            .appendingPathComponent("qa-runs", isDirectory: true)
            .appendingPathComponent(timestamp, isDirectory: true)
            .appendingPathComponent("file-tree-boot-persistence", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let artifact = directory.appendingPathComponent("manifest.json")
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: artifact, options: .atomic)
        return artifact
    }

    static func runFileTreeHardeningSelfCheck() throws -> URL {
        enum CheckError: Error, CustomStringConvertible {
            case failed(String)

            var description: String {
                switch self {
                case let .failed(message): return message
                }
            }
        }

        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw CheckError.failed(message) }
        }

        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("continuum-file-tree-hardening-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let now = Date()
        let tileId = UUID(uuidString: "00000000-0000-0000-0000-000000001121")!
        let descriptorRoot = tempRoot.appendingPathComponent("descriptor-root", isDirectory: true)
        let wrongRoot = tempRoot.appendingPathComponent("wrong-root", isDirectory: true)
        try fileManager.createDirectory(at: descriptorRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: wrongRoot, withIntermediateDirectories: true)

        let browserEngine = BrowserEngineContext()
        defer { browserEngine.shutdown() }

        func makeProjectStore(named name: String) throws -> (Project, ProjectStore, CanvasNSView, TileSpawner) {
            let projectRoot = tempRoot.appendingPathComponent(name, isDirectory: true)
            try fileManager.createDirectory(at: projectRoot, withIntermediateDirectories: true)
            let project = Project(
                id: UUID(),
                name: name,
                rootPath: projectRoot.path,
                createdAt: now,
                updatedAt: now,
                defaultLaunchProfileId: "shell",
                editorPreference: .auto,
                settings: ProjectSettings(
                    restorePolicy: .restoreDescriptors,
                    browserStoragePolicy: .perProject,
                    terminalClosePolicy: .askWhenRunning
                )
            )
            let store = ProjectStore(projectRoot: projectRoot)
            try store.saveProject(project)
            let tile = Tile(
                id: tileId,
                kind: .fileTree,
                title: "descriptor-root",
                frame: TileFrame(x: 20, y: 20, width: 420, height: 360),
                zPosition: .fromLegacyRank(1),
                runtimeRef: nil,
                metadata: TileMetadata(filePath: descriptorRoot.path)
            )
            try store.saveCanvas(CanvasState(
                viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
                tiles: [tile],
                groups: [],
                lastActiveTileId: tileId
            ))
            let canvas = CanvasNSView(canvasState: try store.loadCanvas())
            let spawner = TileSpawner(
                canvasView: canvas,
                ghostty: nil,
                browserEngine: browserEngine,
                projectStore: store,
                project: project
            )
            return (project, store, canvas, spawner)
        }

        func runScenario(_ name: String, seed: (ProjectStore) throws -> Void) throws -> [String: Any] {
            let (project, store, canvas, spawner) = try makeProjectStore(named: name)
            try seed(store)
            let sidecarBefore = try? Data(contentsOf: store.layout.fileTreeIndexFile)
            switch spawner.restartFileTreeTile(tileId: tileId) {
            case .restarted:
                break
            case .tileNotFound:
                throw CheckError.failed("\(name): tile not found")
            case let .failure(error):
                throw CheckError.failed("\(name): restart failed: \(error)")
            }
            guard let view = canvas.tileView(for: tileId) as? FileTreeTileNSView else {
                throw CheckError.failed("\(name): did not install file-tree view")
            }
            spawner.writeFileTreeTileSnapshot(for: view)
            let sidecarAfter = try? Data(contentsOf: store.layout.fileTreeIndexFile)
            let persisted = try? store.tryLoadFileTreeState()?.tiles.first(where: { $0.tileId == tileId })
            let didFallbackToProjectRoot = persisted?.rootPath == project.rootPath
            let didStartScannerForWrongRoot = view.currentSnapshot?.root.path == wrongRoot.path || view.currentSnapshot?.root.path == project.rootPath
            try expect(view.isRecoverableError, "\(name): should install recoverable error tile")
            try expect(view.currentSnapshot == nil, "\(name): should not scan while sidecar is invalid")
            try expect(!didFallbackToProjectRoot, "\(name): should not fall back to project root")
            try expect(!didStartScannerForWrongRoot, "\(name): should not start scanner for wrong root")
            if let sidecarBefore {
                try expect(sidecarAfter == sidecarBefore, "\(name): should not overwrite invalid sidecar")
            } else {
                try expect(sidecarAfter == nil, "\(name): should not create sidecar from missing invalid state")
            }
            return [
                "scenario": name,
                "errorKind": view.recoverableErrorMessage ?? "",
                "didInstallRecoverableTile": view.isRecoverableError,
                "didFallbackToProjectRoot": didFallbackToProjectRoot,
                "didStartScannerForWrongRoot": didStartScannerForWrongRoot,
                "sidecarUnchanged": sidecarAfter == sidecarBefore
            ]
        }

        let scenarios: [[String: Any]] = try [
            runScenario("missing-sidecar") { _ in },
            runScenario("corrupt-sidecar") { store in
                try fileManager.createDirectory(at: store.layout.fileTreeDirectory, withIntermediateDirectories: true)
                try Data("{ not-json".utf8).write(to: store.layout.fileTreeIndexFile, options: .atomic)
            },
            runScenario("missing-tile-entry") { store in
                try store.saveFileTreeState(FileTreeState(tiles: []))
            },
            runScenario("mismatched-root") { store in
                try store.saveFileTreeState(FileTreeState(tiles: [FileTreeTile(
                    tileId: tileId,
                    rootPath: wrongRoot.path,
                    expandedPaths: [],
                    selectedPath: nil,
                    searchQuery: "",
                    ignoredNames: [],
                    gitBadges: .off
                )]))
            }
        ]

        let manifest: [String: Any] = [
            "check": "file-tree-hardening",
            "debounceFlush": try FileTreeTileNSView.runDebounceFlushSelfCheck(),
            "truncatedOutline": try FileTreeTileNSView.runTruncatedOutlineSelfCheck(),
            "sidecarValidation": scenarios
        ]
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let directory = URL(fileURLWithPath: fileManager.currentDirectoryPath)
            .appendingPathComponent("qa-runs", isDirectory: true)
            .appendingPathComponent(timestamp, isDirectory: true)
            .appendingPathComponent("file-tree-hardening", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let artifact = directory.appendingPathComponent("manifest.json")
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: artifact, options: .atomic)
        return artifact
    }

    static func runBrowserInspectorTileShellSelfCheck() throws -> URL {
        enum CheckError: Error, CustomStringConvertible {
            case failed(String)
            var description: String { if case let .failed(message) = self { return message }; return "failed" }
        }
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw CheckError.failed(message) }
        }
        func timestamp() -> String {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            return formatter.string(from: Date())
        }

        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("continuum-browser-inspector-tile-shell-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let profile = BrowserProfile.builtInDefault()
        let project = Project(
            id: UUID(),
            name: "browser-inspector-tile-shell-check",
            rootPath: tempRoot.path,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1),
            defaultLaunchProfileId: "shell",
            editorPreference: .auto,
            settings: ProjectSettings(
                restorePolicy: .restoreDescriptors,
                browserStoragePolicy: .perProject,
                terminalClosePolicy: .askWhenRunning,
                defaultBrowserProfileId: profile.id
            )
        )
        let store = ProjectStore(projectRoot: tempRoot)
        try store.saveProject(project)
        try store.saveCanvas(CanvasState(viewport: CanvasViewport(x: 0, y: 0, zoom: 1), tiles: [], groups: [], lastActiveTileId: nil))

        let canvas = CanvasNSView(canvasState: try store.loadCanvas())
        let spawner = TileSpawner(
            canvasView: canvas,
            ghostty: nil,
            browserEngine: BrowserEngineContext(),
            projectStore: store,
            project: project,
            browserProfiles: [profile]
        )

        let browserRuntime: WKWebViewBrowserRuntime
        switch spawner.spawnBrowser(url: "data:text/html;charset=utf-8,<html><head><title>Inspector Source</title></head><body>ok</body></html>") {
        case let .spawned(runtime):
            browserRuntime = runtime
        case let .invalidURL(url):
            throw CheckError.failed("browser spawn rejected URL \(url)")
        case let .failure(error):
            throw error
        }
        let browserTileId = browserRuntime.tileId
        var seededBrowserState = try store.loadBrowserState()
        if let browserIndex = seededBrowserState.tiles.firstIndex(where: { $0.tileId == browserTileId }) {
            seededBrowserState.tiles[browserIndex].updateActiveTab(
                url: "https://example.test/inspected",
                title: "Inspector Source",
                interactionState: nil,
                now: Date(timeIntervalSince1970: 2)
            )
            try store.saveBrowserState(seededBrowserState)
        }

        let inspectorTileId: UUID
        switch spawner.spawnBrowserInspector(for: browserTileId) {
        case let .spawned(tileId):
            inspectorTileId = tileId
        case .notBrowserTile:
            throw CheckError.failed("spawnBrowserInspector rejected a browser tile")
        case let .failure(error):
            throw error
        }

        let spawnedInspectorTile = canvas.canvasState.tiles.first { $0.id == inspectorTileId }
        let spawnedInspectorState = try store.loadBrowserState().inspectorStates.first { $0.inspectorTileId == inspectorTileId }
        let spawnedForBrowserTile = spawnedInspectorTile?.kind == .browserInspector
            && spawnedInspectorState?.inspectedBrowserTileId == browserTileId
            && spawnedInspectorState?.selectedPanel == .elements
            && spawnedInspectorTile?.frame.width ?? 0 >= 520
            && spawnedInspectorTile?.frame.height ?? 0 >= 360
        try expect(spawnedForBrowserTile, "browser tile did not spawn a linked inspector tile")

        guard let inspectorView = canvas.tileView(for: inspectorTileId) as? BrowserInspectorTileNSView else {
            throw CheckError.failed("spawned inspector tile did not install BrowserInspectorTileNSView")
        }
        inspectorView.selectPanelForQA(.network)
        let panelSavedBeforeRestore = try store.loadBrowserState().inspectorStates.first { $0.inspectorTileId == inspectorTileId }?.selectedPanel == .network
        try expect(panelSavedBeforeRestore, "selected inspector panel did not persist after view selection")
        try store.saveCanvas(canvas.canvasState)

        let restoredCanvas = CanvasNSView(canvasState: try store.loadCanvas())
        let restoredSpawner = TileSpawner(
            canvasView: restoredCanvas,
            ghostty: nil,
            browserEngine: BrowserEngineContext(),
            projectStore: store,
            project: project,
            browserProfiles: [profile]
        )
        guard let restoredInspectorTile = restoredCanvas.canvasState.tiles.first(where: { $0.id == inspectorTileId }) else {
            throw CheckError.failed("saved canvas did not restore inspector tile")
        }
        restoredSpawner.installBrowserInspectorTile(restoredInspectorTile, in: restoredCanvas)
        let restoredInspectorState = try store.loadBrowserState().inspectorStates.first { $0.inspectorTileId == inspectorTileId }
        let relationshipPersisted = restoredCanvas.canvasState.tiles.contains(where: { $0.id == inspectorTileId && $0.kind == .browserInspector })
            && restoredInspectorState?.inspectedBrowserTileId == browserTileId
        let panelSelectionPersisted = (restoredCanvas.tileView(for: inspectorTileId) as? BrowserInspectorTileNSView)?.selectedPanelForQA == .network
            && restoredInspectorState?.selectedPanel == .network
        try expect(relationshipPersisted, "inspector relationship did not persist across save/load")
        try expect(panelSelectionPersisted, "inspector selected panel did not persist across save/load")

        let deletedInspectorIds = restoredSpawner.deleteBrowserInspectors(inspecting: browserTileId, in: restoredCanvas)
        restoredCanvas.removeTile(id: browserTileId)
        var afterDeleteBrowserState = try store.loadBrowserState()
        afterDeleteBrowserState.tiles.removeAll { $0.tileId == browserTileId }
        try store.saveBrowserState(afterDeleteBrowserState)
        try store.saveCanvas(restoredCanvas.canvasState)
        let inspectorStateRemovedAfterDelete = !(try store.loadBrowserState().inspectorStates.contains { $0.inspectorTileId == inspectorTileId })
        let deletedBrowserDeletesInspector = deletedInspectorIds.contains(inspectorTileId)
            && !restoredCanvas.canvasState.tiles.contains(where: { $0.id == inspectorTileId })
            && inspectorStateRemovedAfterDelete
        try expect(deletedBrowserDeletesInspector, "deleting browser tile did not delete linked inspector tile")

        let inspectorSource = try String(contentsOfFile: "Sources/ContinuumRevived/Canvas/BrowserInspectorTileNSView.swift", encoding: .utf8)
        let forbiddenNativeInspectorNeedles = [
            "isInspectable = true",
            "show" + "WebInspector",
            "inspect" + "Element",
            "developerExtras",
            "_" + "inspector"
        ]
        let nativeInspectorNeedleHits = forbiddenNativeInspectorNeedles.filter { inspectorSource.contains($0) }
        let usesNativeSafariInspector = !nativeInspectorNeedleHits.isEmpty
        try expect(!usesNativeSafariInspector, "browser inspector shell referenced native/private inspector APIs: \(nativeInspectorNeedleHits)")

        let artifactDir = URL(fileURLWithPath: fileManager.currentDirectoryPath)
            .appendingPathComponent("qa-runs", isDirectory: true)
            .appendingPathComponent(timestamp(), isDirectory: true)
            .appendingPathComponent("browser-inspector-tile-shell", isDirectory: true)
        try fileManager.createDirectory(at: artifactDir, withIntermediateDirectories: true)
        let artifact = artifactDir.appendingPathComponent("manifest.json")
        let manifest: [String: Any] = [
            "check": "browser-inspector-tile-shell",
            "spawnedForBrowserTile": spawnedForBrowserTile,
            "relationshipPersisted": relationshipPersisted,
            "panelSelectionPersisted": panelSelectionPersisted,
            "deletedBrowserDeletesInspector": deletedBrowserDeletesInspector,
            "usesNativeSafariInspector": usesNativeSafariInspector,
            "browserTileId": browserTileId.uuidString,
            "inspectorTileId": inspectorTileId.uuidString,
            "selectedPanelAfterRestore": restoredInspectorState?.selectedPanel.rawValue ?? "missing",
            "nativeInspectorNeedleHits": nativeInspectorNeedleHits
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: artifact, options: .atomic)
        return artifact
    }

    static func runBrowserInspectorDOMTreeSelfCheck() throws -> URL {
        enum CheckError: Error, CustomStringConvertible {
            case failed(String)
            var description: String { if case let .failed(message) = self { return message }; return "failed" }
        }
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw CheckError.failed(message) }
        }
        func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if condition() { return true }
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.03))
            }
            return condition()
        }
        func timestamp() -> String {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            return formatter.string(from: Date())
        }

        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("continuum-browser-inspector-dom-tree-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let profile = BrowserProfile.builtInDefault()
        let project = Project(
            id: UUID(),
            name: "browser-inspector-dom-tree-check",
            rootPath: tempRoot.path,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1),
            defaultLaunchProfileId: "shell",
            editorPreference: .auto,
            settings: ProjectSettings(
                restorePolicy: .restoreDescriptors,
                browserStoragePolicy: .perProject,
                terminalClosePolicy: .askWhenRunning,
                defaultBrowserProfileId: profile.id
            )
        )
        let store = ProjectStore(projectRoot: tempRoot)
        try store.saveProject(project)
        try store.saveCanvas(CanvasState(viewport: CanvasViewport(x: 0, y: 0, zoom: 1), tiles: [], groups: [], lastActiveTileId: nil))

        let canvas = CanvasNSView(canvasState: try store.loadCanvas())
        canvas.frame = NSRect(x: 0, y: 0, width: 1_120, height: 620)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_120, height: 620),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = canvas
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }

        let spawner = TileSpawner(
            canvasView: canvas,
            ghostty: nil,
            browserEngine: BrowserEngineContext(),
            projectStore: store,
            project: project,
            browserProfiles: [profile]
        )

        let html = """
        <!doctype html>
        <html>
          <head><meta charset="utf-8"><title>DOM Tree QA</title></head>
          <body>
            <main id="app" class="shell primary">
              <section class="card">
                <p class="copy"><span id="target" class="target selected">Expected DOM text from WKWebView</span></p>
              </section>
              <iframe src="https://cross-origin.example.test/frame"></iframe>
            </main>
          </body>
        </html>
        """
        let encodedHTML = html.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? html
        let dataURL = "data:text/html;charset=utf-8,\(encodedHTML)"

        let browserRuntime: WKWebViewBrowserRuntime
        switch spawner.spawnBrowser(url: dataURL) {
        case let .spawned(runtime):
            browserRuntime = runtime
        case let .invalidURL(url):
            throw CheckError.failed("browser spawn rejected URL \(url)")
        case let .failure(error):
            throw error
        }
        try expect(waitUntil { browserRuntime.title == "DOM Tree QA" || !browserRuntime.webView.isLoading }, "browser data URL did not finish loading")
        try expect(browserRuntime.webView.url?.absoluteString.hasPrefix("data:text/html") == true, "check must evaluate a real WKWebView data URL")

        let inspectorTileId: UUID
        switch spawner.spawnBrowserInspector(for: browserRuntime.tileId) {
        case let .spawned(tileId):
            inspectorTileId = tileId
        case .notBrowserTile:
            throw CheckError.failed("spawnBrowserInspector rejected the browser tile")
        case let .failure(error):
            throw error
        }
        guard let inspectorView = canvas.tileView(for: inspectorTileId) as? BrowserInspectorTileNSView else {
            throw CheckError.failed("spawned inspector did not install BrowserInspectorTileNSView")
        }

        var snapshotResult: Result<BrowserDOMSnapshot, Error>?
        inspectorView.refreshElementsForQA { result in snapshotResult = result }
        try expect(waitUntil { snapshotResult != nil }, "DOM snapshot refresh timed out")
        let snapshot = try snapshotResult?.get() ?? { throw CheckError.failed("DOM snapshot result missing") }()
        let expectedNode = snapshot.nodes.first { node in
            node.tagName == "span"
                && node.idAttribute == "target"
                && (node.className?.contains("target") == true)
                && (node.textPreview?.contains("Expected DOM text") == true)
        }
        let expectedNodeFound = expectedNode != nil
        try expect(expectedNodeFound, "snapshot did not include expected span#target node")
        try expect(snapshot.maxNodes == 800 && snapshot.maxDepth == 32, "DOM snapshot did not expose node/depth cap metadata")
        try expect(snapshot.nodes.contains(where: { $0.tagName == "main" && $0.idAttribute == "app" && $0.className?.contains("shell") == true }), "snapshot did not include expected main#app.shell node")

        var highlightResult: Result<Bool, Error>?
        inspectorView.selectDOMNodeForQA(id: expectedNode!.id) { result in highlightResult = result }
        try expect(waitUntil { highlightResult != nil }, "DOM highlight timed out")
        let highlightReturnedTrue = try highlightResult?.get() ?? false
        try expect(highlightReturnedTrue, "highlight script did not return true for selected node")
        try expect(browserRuntime.domSnapshotEvaluationCountForQA > 0, "DOM snapshot must use WKWebView.evaluateJavaScript")
        try expect(browserRuntime.domHighlightEvaluationCountForQA > 0, "DOM highlight must use WKWebView.evaluateJavaScript")

        guard let inspectorTile = canvas.canvasState.tiles.first(where: { $0.id == inspectorTileId }) else {
            throw CheckError.failed("inspector tile missing before disconnected scenario")
        }
        canvas.removeTile(id: browserRuntime.tileId)
        spawner.installBrowserInspectorTile(inspectorTile, in: canvas)
        guard let disconnectedInspector = canvas.tileView(for: inspectorTileId) as? BrowserInspectorTileNSView else {
            throw CheckError.failed("disconnected inspector did not reinstall")
        }
        try expect(disconnectedInspector.isDisconnectedForQA, "missing linked browser should render disconnected inspector state")
        var disconnectedRefreshResult: Result<BrowserDOMSnapshot, Error>?
        disconnectedInspector.refreshElementsForQA { result in disconnectedRefreshResult = result }
        try expect(waitUntil { disconnectedRefreshResult != nil }, "disconnected refresh did not complete")
        if let disconnectedRefreshResult {
            switch disconnectedRefreshResult {
            case .success:
                throw CheckError.failed("disconnected inspector unexpectedly returned a DOM snapshot")
            case .failure:
                break
            }
        }

        let realWKWebViewEvaluated = browserRuntime.domSnapshotEvaluationCountForQA > 0 && browserRuntime.domHighlightEvaluationCountForQA > 0
        let artifactDir = URL(fileURLWithPath: fileManager.currentDirectoryPath)
            .appendingPathComponent("qa-runs", isDirectory: true)
            .appendingPathComponent(timestamp(), isDirectory: true)
            .appendingPathComponent("browser-inspector-dom-tree", isDirectory: true)
        try fileManager.createDirectory(at: artifactDir, withIntermediateDirectories: true)
        let artifact = artifactDir.appendingPathComponent("manifest.json")
        let manifest: [String: Any] = [
            "check": "browser-inspector-dom-tree",
            "realWKWebViewEvaluated": realWKWebViewEvaluated,
            "nodeCount": snapshot.nodes.count,
            "truncated": snapshot.truncated,
            "maxNodes": snapshot.maxNodes,
            "maxDepth": snapshot.maxDepth,
            "expectedNodeFound": expectedNodeFound,
            "expectedNodePath": expectedNode?.id ?? "missing",
            "highlightReturnedTrue": highlightReturnedTrue,
            "disconnectedPanelRendered": disconnectedInspector.isDisconnectedForQA,
            "crossOriginIframeSupport": "out-of-scope"
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: artifact, options: .atomic)
        return artifact
    }

    static func runBrowserInspectorStylesSelfCheck() throws -> URL {
        enum CheckError: Error, CustomStringConvertible {
            case failed(String)
            var description: String { if case let .failed(message) = self { return message }; return "failed" }
        }
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw CheckError.failed(message) }
        }
        func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if condition() { return true }
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.03))
            }
            return condition()
        }
        func timestamp() -> String {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            return formatter.string(from: Date())
        }
        func normalizedCSSValue(_ value: String?) -> String {
            (value ?? "")
                .replacingOccurrences(of: " ", with: "")
                .lowercased()
        }

        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("continuum-browser-inspector-styles-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let profile = BrowserProfile.builtInDefault()
        let project = Project(
            id: UUID(),
            name: "browser-inspector-styles-check",
            rootPath: tempRoot.path,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1),
            defaultLaunchProfileId: "shell",
            editorPreference: .auto,
            settings: ProjectSettings(
                restorePolicy: .restoreDescriptors,
                browserStoragePolicy: .perProject,
                terminalClosePolicy: .askWhenRunning,
                defaultBrowserProfileId: profile.id
            )
        )
        let store = ProjectStore(projectRoot: tempRoot)
        try store.saveProject(project)
        try store.saveCanvas(CanvasState(viewport: CanvasViewport(x: 0, y: 0, zoom: 1), tiles: [], groups: [], lastActiveTileId: nil))

        let canvas = CanvasNSView(canvasState: try store.loadCanvas())
        canvas.frame = NSRect(x: 0, y: 0, width: 1_120, height: 620)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_120, height: 620),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = canvas
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }

        let spawner = TileSpawner(
            canvasView: canvas,
            ghostty: nil,
            browserEngine: BrowserEngineContext(),
            projectStore: store,
            project: project,
            browserProfiles: [profile]
        )

        let html = """
        <!doctype html>
        <html>
          <head>
            <meta charset="utf-8">
            <title>Styles QA</title>
            <style>
              body { margin: 0; }
              #target {
                display: inline-block;
                position: relative;
                width: 123px;
                height: 45px;
                margin: 7px 9px 11px 13px;
                padding: 5px 11px 6px 12px;
                color: rgb(12, 34, 56);
                background-color: rgb(210, 220, 230);
                font-family: Helvetica, Arial, sans-serif;
                font-size: 19px;
                font-weight: 700;
                line-height: 23px;
                z-index: 5;
                overflow: hidden;
              }
            </style>
          </head>
          <body>
            <main id="app"><div id="target" class="style-target">Styled target</div></main>
          </body>
        </html>
        """
        let fixtureURL = tempRoot.appendingPathComponent("styles-fixture.html", isDirectory: false)
        try Data(html.utf8).write(to: fixtureURL, options: .atomic)

        let browserRuntime: WKWebViewBrowserRuntime
        switch spawner.spawnBrowser(url: fixtureURL.absoluteString) {
        case let .spawned(runtime):
            browserRuntime = runtime
        case let .invalidURL(url):
            throw CheckError.failed("browser spawn rejected URL \(url)")
        case let .failure(error):
            throw error
        }
        defer { browserRuntime.terminate(policy: .requestClose) }

        try expect(waitUntil { browserRuntime.title == "Styles QA" || !browserRuntime.webView.isLoading }, "browser styles fixture did not finish loading")
        try expect(browserRuntime.webView.url?.isFileURL == true, "styles check must evaluate a real WKWebView file URL")

        let inspectorTileId: UUID
        switch spawner.spawnBrowserInspector(for: browserRuntime.tileId) {
        case let .spawned(tileId):
            inspectorTileId = tileId
        case .notBrowserTile:
            throw CheckError.failed("spawnBrowserInspector rejected the browser tile")
        case let .failure(error):
            throw error
        }
        guard let inspectorView = canvas.tileView(for: inspectorTileId) as? BrowserInspectorTileNSView else {
            throw CheckError.failed("spawned inspector did not install BrowserInspectorTileNSView")
        }

        inspectorView.selectPanelForQA(.styles)
        let emptyStateVisible = inspectorView.stylesStatusTextForQA.contains("Select an element") && inspectorView.stylesRowTextsForQA.isEmpty
        try expect(emptyStateVisible, "Styles panel did not show the no-selected-element empty state")

        var snapshotResult: Result<BrowserDOMSnapshot, Error>?
        inspectorView.refreshElementsForQA { result in snapshotResult = result }
        try expect(waitUntil { snapshotResult != nil }, "DOM snapshot refresh timed out")
        let snapshot = try snapshotResult?.get() ?? { throw CheckError.failed("DOM snapshot result missing") }()
        let expectedNode = snapshot.nodes.first { node in
            node.tagName == "div"
                && node.idAttribute == "target"
                && (node.className?.contains("style-target") == true)
                && (node.textPreview?.contains("Styled target") == true)
        }
        let selectedNodeFound = expectedNode != nil
        try expect(selectedNodeFound, "snapshot did not include expected div#target node")

        var highlightResult: Result<Bool, Error>?
        inspectorView.selectDOMNodeForQA(id: expectedNode!.id) { result in highlightResult = result }
        try expect(waitUntil { highlightResult != nil }, "DOM selection/highlight timed out")
        let highlightReturnedTrue = try highlightResult?.get() ?? false
        try expect(highlightReturnedTrue, "selected node did not highlight before styles fetch")

        var styleResult: Result<BrowserComputedStyleSnapshot, Error>?
        inspectorView.refreshSelectedNodeStylesForQA { result in styleResult = result }
        try expect(waitUntil { styleResult != nil }, "computed style fetch timed out")
        let styleSnapshot = try styleResult?.get() ?? { throw CheckError.failed("computed style result missing") }()
        let propertyValues = Dictionary(uniqueKeysWithValues: styleSnapshot.properties.map { ($0.name, $0.value) })
        let expectedColorMatched = ["rgb(12,34,56)", "rgba(12,34,56,1)"].contains(normalizedCSSValue(propertyValues["color"]))
        let expectedDisplayMatched = normalizedCSSValue(propertyValues["display"]) == "inline-block"
        let expectedWidthMatched = normalizedCSSValue(propertyValues["width"]) == "123px"
        let computedStyleFetched = browserRuntime.domComputedStyleEvaluationCountForQA > 0
            && styleSnapshot.nodeId == expectedNode!.id
            && styleSnapshot.properties.count >= 20
            && expectedWidthMatched
        let stylesPanelRendered = inspectorView.stylesRowTextsForQA.contains { $0.contains("Display: inline-block") }
            && inspectorView.stylesRowTextsForQA.contains { $0.contains("Color: text=rgb(12, 34, 56)") }

        try expect(computedStyleFetched, "computed styles were not fetched through WKWebView for the selected DOM path")
        try expect(expectedColorMatched, "computed color did not match expected normalized rgb(12,34,56); got \(propertyValues["color"] ?? "missing")")
        try expect(expectedDisplayMatched, "computed display did not match expected inline-block; got \(propertyValues["display"] ?? "missing")")
        try expect(stylesPanelRendered, "Styles panel did not render the computed display/color rows")

        let artifactDir = URL(fileURLWithPath: fileManager.currentDirectoryPath)
            .appendingPathComponent("qa-runs", isDirectory: true)
            .appendingPathComponent(timestamp(), isDirectory: true)
            .appendingPathComponent("browser-inspector-styles", isDirectory: true)
        try fileManager.createDirectory(at: artifactDir, withIntermediateDirectories: true)
        let artifact = artifactDir.appendingPathComponent("manifest.json")
        let manifest: [String: Any] = [
            "check": "browser-inspector-styles",
            "selectedNodeFound": selectedNodeFound,
            "computedStyleFetched": computedStyleFetched,
            "expectedColorMatched": expectedColorMatched,
            "expectedDisplayMatched": expectedDisplayMatched,
            "styleEditing": "out-of-scope",
            "emptyStateVisible": emptyStateVisible,
            "stylesPanelRendered": stylesPanelRendered,
            "computedStyleEvaluationCount": browserRuntime.domComputedStyleEvaluationCountForQA,
            "selectedNodePath": expectedNode?.id ?? "missing",
            "expectedComputedValues": [
                "color": propertyValues["color"] ?? "missing",
                "display": propertyValues["display"] ?? "missing",
                "width": propertyValues["width"] ?? "missing",
                "height": propertyValues["height"] ?? "missing",
                "background-color": propertyValues["background-color"] ?? "missing"
            ],
            "boundingRect": [
                "x": styleSnapshot.boundingRect.x,
                "y": styleSnapshot.boundingRect.y,
                "width": styleSnapshot.boundingRect.width,
                "height": styleSnapshot.boundingRect.height
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: artifact, options: .atomic)
        return artifact
    }

    static func runBrowserInspectorConsoleSelfCheck() throws -> URL {
        enum CheckError: Error, CustomStringConvertible {
            case failed(String)
            var description: String { if case let .failed(message) = self { return message }; return "failed" }
        }
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw CheckError.failed(message) }
        }
        func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if condition() { return true }
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.03))
            }
            return condition()
        }
        func timestamp() -> String {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            return formatter.string(from: Date())
        }

        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("continuum-browser-inspector-console-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let profile = BrowserProfile.builtInDefault()
        let project = Project(
            id: UUID(),
            name: "browser-inspector-console-check",
            rootPath: tempRoot.path,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1),
            defaultLaunchProfileId: "shell",
            editorPreference: .auto,
            settings: ProjectSettings(
                restorePolicy: .restoreDescriptors,
                browserStoragePolicy: .perProject,
                terminalClosePolicy: .askWhenRunning,
                defaultBrowserProfileId: profile.id
            )
        )
        let store = ProjectStore(projectRoot: tempRoot)
        try store.saveProject(project)
        try store.saveCanvas(CanvasState(viewport: CanvasViewport(x: 0, y: 0, zoom: 1), tiles: [], groups: [], lastActiveTileId: nil))

        let canvas = CanvasNSView(canvasState: try store.loadCanvas())
        canvas.frame = NSRect(x: 0, y: 0, width: 1_120, height: 620)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_120, height: 620),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = canvas
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }

        let spawner = TileSpawner(
            canvasView: canvas,
            ghostty: nil,
            browserEngine: BrowserEngineContext(),
            projectStore: store,
            project: project,
            browserProfiles: [profile]
        )

        let fixtureSecret = "I03-Fixture-Secret-\(UUID().uuidString)"
        let fixtureToken = "I03-Fixture-Token-\(UUID().uuidString)"
        let html = """
        <!doctype html>
        <html>
          <head><meta charset="utf-8"><title>Console QA</title></head>
          <body>
            <h1>Console QA</h1>
            <script>
              for (let i = 0; i < 20; i++) { console.debug('evicted-debug-' + i); }
              console.log('captured-log ready');
              console.warn('captured-warn warning-object', {kind: 'warning'});
              console.error('captured-error password=\(fixtureSecret) token=\(fixtureToken)');
              for (let i = 0; i < 497; i++) { console.info('tail-info-' + i); }
            </script>
          </body>
        </html>
        """
        let fixtureURL = tempRoot.appendingPathComponent("console-fixture.html", isDirectory: false)
        try Data(html.utf8).write(to: fixtureURL, options: .atomic)

        let browserRuntime: WKWebViewBrowserRuntime
        switch spawner.spawnBrowser(url: fixtureURL.absoluteString) {
        case let .spawned(runtime):
            browserRuntime = runtime
        case let .invalidURL(url):
            throw CheckError.failed("browser spawn rejected URL \(url)")
        case let .failure(error):
            throw error
        }
        defer { browserRuntime.terminate(policy: .requestClose) }

        try expect(waitUntil { browserRuntime.title == "Console QA" || !browserRuntime.webView.isLoading }, "browser console fixture did not finish loading")
        try expect(waitUntil { browserRuntime.consoleLogEntries.count == BrowserConsoleLogBuffer.defaultCapacity }, "console events did not reach the app buffer through WKScriptMessageHandler")
        let entriesBeforeClear = browserRuntime.consoleLogEntries
        let requiredLevels: [BrowserConsoleLogLevel] = [.log, .warn, .error]
        let levelsCaptured = requiredLevels.filter { level in entriesBeforeClear.contains { $0.level == level } }.map(\.rawValue)
        let eventsReachAppBuffer = requiredLevels.allSatisfy { level in entriesBeforeClear.contains { $0.level == level } }
        let bufferCapEnforced = entriesBeforeClear.count == BrowserConsoleLogBuffer.defaultCapacity
            && browserRuntime.consoleLogCapacity == BrowserConsoleLogBuffer.defaultCapacity
            && entriesBeforeClear.first?.message.contains("captured-log") == true
            && !entriesBeforeClear.contains { $0.message.contains("evicted-debug-") }
        let realWKWebViewMessageHandler = browserRuntime.consoleBridgeUserScriptInstalledForQA
            && browserRuntime.consoleMessageHandlerEventCountForQA >= BrowserConsoleLogBuffer.defaultCapacity
            && browserRuntime.webView.url?.isFileURL == true
        try expect(eventsReachAppBuffer, "log/warn/error messages were not captured in the app buffer")
        try expect(bufferCapEnforced, "console buffer did not keep the newest 500 messages")
        try expect(realWKWebViewMessageHandler, "console check did not use the real WKWebView message handler")

        let inspectorTileId: UUID
        switch spawner.spawnBrowserInspector(for: browserRuntime.tileId) {
        case let .spawned(tileId):
            inspectorTileId = tileId
        case .notBrowserTile:
            throw CheckError.failed("spawnBrowserInspector rejected the browser tile")
        case let .failure(error):
            throw error
        }
        guard let inspectorView = canvas.tileView(for: inspectorTileId) as? BrowserInspectorTileNSView else {
            throw CheckError.failed("spawned inspector did not install BrowserInspectorTileNSView")
        }
        inspectorView.selectPanelForQA(.console)
        let consolePanelDisplayedMessages = inspectorView.consoleVisibleRowCountForQA == BrowserConsoleLogBuffer.defaultCapacity
            && inspectorView.consoleRowTextsForQA.contains(where: { $0.contains("captured-log ready") })
            && inspectorView.consoleRowTextsForQA.contains(where: { $0.contains("captured-warn") })
            && inspectorView.consoleRowTextsForQA.contains(where: { $0.contains("captured-error") })
            && inspectorView.consoleClearEnabledForQA
        try expect(consolePanelDisplayedMessages, "inspector Console panel did not render captured log/warn/error rows")

        inspectorView.clearConsoleForQA()
        let clearWorked = browserRuntime.consoleLogEntries.isEmpty
            && inspectorView.consoleVisibleRowCountForQA == 0
            && inspectorView.consoleStatusTextForQA.contains("No console messages")
        try expect(clearWorked, "Console panel clear button did not clear the browser/inspector buffer")

        let redactedSampleMessages = entriesBeforeClear
            .filter { requiredLevels.contains($0.level) }
            .prefix(10)
            .map { SecretRedactor.redact($0.message, explicitSecrets: [fixtureSecret, fixtureToken]) }
        let redactedContainsSecret = redactedSampleMessages.contains { $0.contains(fixtureSecret) || $0.contains(fixtureToken) }
        try expect(!redactedContainsSecret, "redacted console samples still contain the fixture secret")

        let artifactDir = URL(fileURLWithPath: fileManager.currentDirectoryPath)
            .appendingPathComponent("qa-runs", isDirectory: true)
            .appendingPathComponent(timestamp(), isDirectory: true)
            .appendingPathComponent("browser-inspector-console", isDirectory: true)
        try fileManager.createDirectory(at: artifactDir, withIntermediateDirectories: true)
        let artifact = artifactDir.appendingPathComponent("manifest.json")
        let manifest: [String: Any] = [
            "check": "browser-inspector-console",
            "realWKWebViewMessageHandler": realWKWebViewMessageHandler,
            "levelsCaptured": levelsCaptured,
            "bufferCap": BrowserConsoleLogBuffer.defaultCapacity,
            "bufferCountBeforeClear": entriesBeforeClear.count,
            "messageHandlerEventCount": browserRuntime.consoleMessageHandlerEventCountForQA,
            "consolePanelDisplayedMessages": consolePanelDisplayedMessages,
            "clearWorked": clearWorked,
            "artifactSecretFree": true,
            "redactedSampleMessages": Array(redactedSampleMessages),
            "rawConsoleLogsPersistedAcrossRestart": false,
            "javascriptEvaluationPromptAvailable": false
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: artifact, options: .atomic)
        let written = try String(contentsOf: artifact, encoding: .utf8)
        let artifactSecretFree = !written.contains(fixtureSecret) && !written.contains(fixtureToken)
        try expect(artifactSecretFree, "console QA artifact contains an unredacted fixture secret")
        return artifact
    }

    static func runBrowserInspectorNetworkLiteSelfCheck() throws -> URL {
        enum CheckError: Error, CustomStringConvertible {
            case failed(String)
            var description: String { if case let .failed(message) = self { return message }; return "failed" }
        }
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw CheckError.failed(message) }
        }
        func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if condition() { return true }
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.03))
            }
            return condition()
        }
        func timestamp() -> String {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            return formatter.string(from: Date())
        }

        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("continuum-browser-inspector-network-lite-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let profile = BrowserProfile.builtInDefault()
        let project = Project(
            id: UUID(),
            name: "browser-inspector-network-lite-check",
            rootPath: tempRoot.path,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1),
            defaultLaunchProfileId: "shell",
            editorPreference: .auto,
            settings: ProjectSettings(
                restorePolicy: .restoreDescriptors,
                browserStoragePolicy: .perProject,
                terminalClosePolicy: .askWhenRunning,
                defaultBrowserProfileId: profile.id
            )
        )
        let store = ProjectStore(projectRoot: tempRoot)
        try store.saveProject(project)
        try store.saveCanvas(CanvasState(viewport: CanvasViewport(x: 0, y: 0, zoom: 1), tiles: [], groups: [], lastActiveTileId: nil))

        let canvas = CanvasNSView(canvasState: try store.loadCanvas())
        canvas.frame = NSRect(x: 0, y: 0, width: 1_120, height: 620)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_120, height: 620),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = canvas
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }

        let spawner = TileSpawner(
            canvasView: canvas,
            ghostty: nil,
            browserEngine: BrowserEngineContext(),
            projectStore: store,
            project: project,
            browserProfiles: [profile]
        )

        let html = """
        <!doctype html>
        <html>
          <head><meta charset="utf-8"><title>Network Lite QA</title></head>
          <body>
            <h1>Network Lite QA</h1>
            <img src="missing-subresource.png" alt="subresource intentionally unsupported">
          </body>
        </html>
        """
        let fixtureURL = tempRoot.appendingPathComponent("network-lite-fixture.html", isDirectory: false)
        try Data(html.utf8).write(to: fixtureURL, options: .atomic)

        let browserRuntime: WKWebViewBrowserRuntime
        switch spawner.spawnBrowser(url: fixtureURL.absoluteString) {
        case let .spawned(runtime):
            browserRuntime = runtime
        case let .invalidURL(url):
            throw CheckError.failed("browser spawn rejected URL \(url)")
        case let .failure(error):
            throw error
        }
        defer { browserRuntime.terminate(policy: .requestClose) }

        try expect(waitUntil { browserRuntime.title == "Network Lite QA" || !browserRuntime.webView.isLoading }, "browser network-lite fixture did not finish loading")
        try expect(browserRuntime.webView.url?.isFileURL == true, "network-lite check must load a real local fixture in WKWebView")
        try expect(waitUntil { browserRuntime.networkLiteEvents.contains { $0.kind == BrowserNetworkLiteEventKind.navigationStarted.rawValue } }, "network-lite navigation start event did not reach app buffer")

        let events = browserRuntime.networkLiteEvents
        let eventKinds = events.map(\.kind)
        guard let startIndex = eventKinds.firstIndex(of: BrowserNetworkLiteEventKind.navigationStarted.rawValue) else {
            throw CheckError.failed("navigationStarted event missing")
        }
        let committedIndex = eventKinds.firstIndex(of: BrowserNetworkLiteEventKind.committed.rawValue)
        let finishedIndex = eventKinds.firstIndex(of: BrowserNetworkLiteEventKind.finished.rawValue)
        let mainNavigationStarted = events[startIndex].url == fixtureURL.absoluteString
        let mainNavigationFinishedOrCommitted = [committedIndex, finishedIndex]
            .compactMap { $0 }
            .contains { $0 > startIndex }
        let noFakeStatusCodes = events
            .filter { $0.url == fixtureURL.absoluteString || $0.url.hasPrefix("file://") }
            .allSatisfy { $0.statusCode == nil }
        let realWKWebViewNavigationEvents = browserRuntime.networkLiteDelegateEventCountForQA >= 2
            && mainNavigationStarted
            && mainNavigationFinishedOrCommitted
        try expect(mainNavigationStarted, "network-lite log did not capture the fixture main navigation start URL")
        try expect(mainNavigationFinishedOrCommitted, "network-lite log did not capture a committed or finished event after start")
        try expect(noFakeStatusCodes, "network-lite log invented a status code for a file/data navigation")
        try expect(realWKWebViewNavigationEvents, "network-lite log did not use real WKWebView delegate events")

        let inspectorTileId: UUID
        switch spawner.spawnBrowserInspector(for: browserRuntime.tileId) {
        case let .spawned(tileId):
            inspectorTileId = tileId
        case .notBrowserTile:
            throw CheckError.failed("spawnBrowserInspector rejected the browser tile")
        case let .failure(error):
            throw error
        }
        guard let inspectorView = canvas.tileView(for: inspectorTileId) as? BrowserInspectorTileNSView else {
            throw CheckError.failed("spawned inspector did not install BrowserInspectorTileNSView")
        }
        inspectorView.selectPanelForQA(.network)
        let networkRows = inspectorView.networkRowTextsForQA
        let unsupportedSubresourceWaterfallDocumented = networkRows.contains { $0.contains("subresource waterfall unsupported") }
        let networkPanelDisplayedNavigation = networkRows.contains { $0.contains("navigationStarted") && $0.contains(fixtureURL.absoluteString) }
            && networkRows.contains { $0.contains("method=unknown") && $0.contains("status=unknown") }
        try expect(unsupportedSubresourceWaterfallDocumented, "Network panel did not document unsupported subresource waterfall scope")
        try expect(networkPanelDisplayedNavigation, "Network panel did not render the captured navigation event honestly")

        let artifactDir = URL(fileURLWithPath: fileManager.currentDirectoryPath)
            .appendingPathComponent("qa-runs", isDirectory: true)
            .appendingPathComponent(timestamp(), isDirectory: true)
            .appendingPathComponent("browser-inspector-network-lite", isDirectory: true)
        try fileManager.createDirectory(at: artifactDir, withIntermediateDirectories: true)
        let artifact = artifactDir.appendingPathComponent("manifest.json")
        let manifest: [String: Any] = [
            "check": "browser-inspector-network-lite",
            "mainNavigationStarted": mainNavigationStarted,
            "mainNavigationFinishedOrCommitted": mainNavigationFinishedOrCommitted,
            "unsupportedSubresourceWaterfallDocumented": unsupportedSubresourceWaterfallDocumented,
            "noFakeStatusCodes": noFakeStatusCodes,
            "realWKWebViewNavigationEvents": realWKWebViewNavigationEvents,
            "networkPanelDisplayedNavigation": networkPanelDisplayedNavigation,
            "eventKinds": eventKinds,
            "events": events.map { event in
                [
                    "kind": event.kind,
                    "url": event.url,
                    "statusCode": event.statusCode.map { $0 as Any } ?? NSNull(),
                    "errorDescription": event.errorDescription.map { $0 as Any } ?? NSNull()
                ]
            },
            "sampleRows": Array(networkRows.prefix(8)),
            "unsupportedCapabilities": [
                "subresourceWaterfall",
                "headers",
                "responseBodies",
                "timingBreakdown",
                "requestReplay"
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: artifact, options: .atomic)
        return artifact
    }

    static func runBrowserInspectorLinkLifecycleSelfCheck() throws -> URL {
        enum CheckError: Error, CustomStringConvertible {
            case failed(String)
            var description: String { if case let .failed(message) = self { return message }; return "failed" }
        }
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw CheckError.failed(message) }
        }
        func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if condition() { return true }
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.03))
            }
            return condition()
        }
        func timestamp() -> String {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            return formatter.string(from: Date())
        }
        func attachFocusBroker(to canvas: CanvasNSView) -> FocusBroker {
            let broker = FocusBroker()
            canvas.focusBroker = broker
            broker.onAcceptedTileFocus = { [weak canvas] id in canvas?.markActive(tileId: id) }
            broker.onAcceptedCanvasScope = { [weak canvas] in canvas?.clearFocusBorder() }
            return broker
        }
        func makeWindow(for canvas: CanvasNSView) -> NSWindow {
            canvas.frame = NSRect(x: 0, y: 0, width: 1_120, height: 620)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1_120, height: 620),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.contentView = canvas
            window.makeKeyAndOrderFront(nil)
            return window
        }

        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("continuum-browser-inspector-link-lifecycle-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let profile = BrowserProfile.builtInDefault()
        let project = Project(
            id: UUID(),
            name: "browser-inspector-link-lifecycle-check",
            rootPath: tempRoot.path,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1),
            defaultLaunchProfileId: "shell",
            editorPreference: .auto,
            settings: ProjectSettings(
                restorePolicy: .restoreDescriptors,
                browserStoragePolicy: .perProject,
                terminalClosePolicy: .askWhenRunning,
                defaultBrowserProfileId: profile.id
            )
        )
        let store = ProjectStore(projectRoot: tempRoot)
        try store.saveProject(project)
        try store.saveCanvas(CanvasState(viewport: CanvasViewport(x: 0, y: 0, zoom: 1), tiles: [], groups: [], lastActiveTileId: nil))

        let canvas = CanvasNSView(canvasState: try store.loadCanvas())
        let focusBroker = attachFocusBroker(to: canvas)
        let window = makeWindow(for: canvas)
        defer { window.close() }

        let spawner = TileSpawner(
            canvasView: canvas,
            ghostty: nil,
            browserEngine: BrowserEngineContext(),
            projectStore: store,
            project: project,
            browserProfiles: [profile]
        )

        let htmlA = """
        <!doctype html><html><head><meta charset=\"utf-8\"><title>Link Lifecycle A</title></head><body>A</body></html>
        """
        let htmlB = """
        <!doctype html><html><head><meta charset=\"utf-8\"><title>Link Lifecycle B</title></head><body>B</body></html>
        """
        let fixtureAURL = tempRoot.appendingPathComponent("link-lifecycle-a.html", isDirectory: false)
        let fixtureBURL = tempRoot.appendingPathComponent("link-lifecycle-b.html", isDirectory: false)
        try Data(htmlA.utf8).write(to: fixtureAURL, options: .atomic)
        try Data(htmlB.utf8).write(to: fixtureBURL, options: .atomic)

        let browserRuntime: WKWebViewBrowserRuntime
        switch spawner.spawnBrowser(url: fixtureAURL.absoluteString) {
        case let .spawned(runtime):
            browserRuntime = runtime
        case let .invalidURL(url):
            throw CheckError.failed("browser spawn rejected URL \(url)")
        case let .failure(error):
            throw error
        }
        defer { browserRuntime.terminate(policy: .requestClose) }
        try expect(waitUntil { browserRuntime.title == "Link Lifecycle A" || !browserRuntime.webView.isLoading }, "browser lifecycle fixture A did not finish loading")
        let browserTileId = browserRuntime.tileId

        let browserContextMenuIncludesOpenInspector = (canvas.tileView(for: browserTileId) as? BrowserTileNSView)?
            .contextMenuForQA()
            .items
            .contains(where: { $0.title == "Open Inspector Tile" }) == true
        try expect(browserContextMenuIncludesOpenInspector, "browser context menu did not include Open Inspector Tile")

        let inspectorTileId: UUID
        switch spawner.spawnBrowserInspector(for: browserTileId) {
        case let .spawned(tileId):
            inspectorTileId = tileId
        case .notBrowserTile:
            throw CheckError.failed("spawnBrowserInspector rejected the browser tile")
        case let .failure(error):
            throw error
        }
        guard let inspectorView = canvas.tileView(for: inspectorTileId) as? BrowserInspectorTileNSView else {
            throw CheckError.failed("spawned inspector did not install BrowserInspectorTileNSView")
        }
        try expect(inspectorView.revealBrowserEnabledForQA, "Reveal browser tile button was not enabled for a linked inspector")

        _ = focusBroker.requestFocus(.tile(browserTileId), reason: .userClick)
        let secondInspectorTileId: UUID
        switch spawner.spawnBrowserInspector(for: browserTileId) {
        case let .spawned(tileId):
            secondInspectorTileId = tileId
        case .notBrowserTile:
            throw CheckError.failed("second spawnBrowserInspector rejected the browser tile")
        case let .failure(error):
            throw error
        }
        let inspectorTilesAfterSecondOpen = canvas.canvasState.tiles.filter { $0.kind == .browserInspector }
        let duplicateInspectorPrevented = secondInspectorTileId == inspectorTileId
            && inspectorTilesAfterSecondOpen.count == 1
            && canvas.canvasState.lastActiveTileId == inspectorTileId
            && focusBroker.activeSurface == .tile(inspectorTileId)
        try expect(duplicateInspectorPrevented, "opening inspector twice did not reveal/focus the existing inspector")

        canvas.setViewport(CanvasViewport(x: 5_000, y: 4_000, zoom: 1))
        let viewportBeforeReveal = canvas.canvasState.viewport
        inspectorView.revealBrowserForQA()
        let viewportAfterReveal = canvas.canvasState.viewport
        let revealBrowserWorked = canvas.canvasState.lastActiveTileId == browserTileId
            && focusBroker.activeSurface == .tile(browserTileId)
            && viewportAfterReveal != viewportBeforeReveal
        try expect(revealBrowserWorked, "Reveal browser tile did not focus and frame the linked browser")

        browserRuntime.loadURL(fixtureBURL.absoluteString)
        let reloadUpdatedHeader = waitUntil(7) {
            inspectorView.headerTitleForQA.contains("Link Lifecycle B")
                && inspectorView.headerDetailForQA.contains("link-lifecycle-b.html")
        }
        try expect(reloadUpdatedHeader, "browser reload did not refresh inspector header URL/title")
        try store.saveCanvas(canvas.canvasState)

        let restoredCanvas = CanvasNSView(canvasState: try store.loadCanvas())
        let restoredFocusBroker = attachFocusBroker(to: restoredCanvas)
        let restoredWindow = makeWindow(for: restoredCanvas)
        defer { restoredWindow.close() }
        let restoredSpawner = TileSpawner(
            canvasView: restoredCanvas,
            ghostty: nil,
            browserEngine: BrowserEngineContext(),
            projectStore: store,
            project: project,
            browserProfiles: [profile]
        )
        var restoredRuntimeForCleanup: WKWebViewBrowserRuntime?
        defer { restoredRuntimeForCleanup?.terminate(policy: .requestClose) }
        switch restoredSpawner.restartBrowserTile(tileId: browserTileId) {
        case let .restarted(runtime):
            restoredRuntimeForCleanup = runtime
        case let .invalidURL(url):
            throw CheckError.failed("restored browser rejected URL \(url)")
        case .tileNotFound:
            throw CheckError.failed("restored canvas did not contain browser tile")
        case let .failure(error):
            throw error
        }
        guard let restoredInspectorTile = restoredCanvas.canvasState.tiles.first(where: { $0.id == inspectorTileId && $0.kind == .browserInspector }) else {
            throw CheckError.failed("restored canvas did not contain inspector tile")
        }
        restoredSpawner.installBrowserInspectorTile(restoredInspectorTile, in: restoredCanvas)
        guard let restoredInspectorView = restoredCanvas.tileView(for: inspectorTileId) as? BrowserInspectorTileNSView else {
            throw CheckError.failed("restored inspector did not install BrowserInspectorTileNSView")
        }
        let restoredInspectorState = try store.loadBrowserState().inspectorStates.first { $0.inspectorTileId == inspectorTileId }
        let restartPreservedLink = restoredInspectorState?.inspectedBrowserTileId == browserTileId
            && !restoredInspectorView.isDisconnectedForQA
            && restoredInspectorView.revealBrowserEnabledForQA
            && restoredFocusBroker.requestFocus(.tile(inspectorTileId), reason: .userClick)
        try expect(restartPreservedLink, "app restart did not preserve inspector/browser link")

        let deletedInspectorIds = restoredSpawner.deleteBrowserInspectors(inspecting: browserTileId, in: restoredCanvas)
        restoredCanvas.removeTile(id: browserTileId)
        var browserStateAfterDelete = try store.loadBrowserState()
        browserStateAfterDelete.tiles.removeAll { $0.tileId == browserTileId }
        try store.saveBrowserState(browserStateAfterDelete)
        try store.saveCanvas(restoredCanvas.canvasState)
        let inspectorStateRemovedAfterDelete = !(try store.loadBrowserState().inspectorStates.contains { $0.inspectorTileId == inspectorTileId })
        let deleteBrowserDeletedInspector = deletedInspectorIds.contains(inspectorTileId)
            && !restoredCanvas.canvasState.tiles.contains(where: { $0.id == inspectorTileId })
            && inspectorStateRemovedAfterDelete
        try expect(deleteBrowserDeletedInspector, "deleting browser did not delete linked inspector")

        let artifactDir = URL(fileURLWithPath: fileManager.currentDirectoryPath)
            .appendingPathComponent("qa-runs", isDirectory: true)
            .appendingPathComponent(timestamp(), isDirectory: true)
            .appendingPathComponent("browser-inspector-link-lifecycle", isDirectory: true)
        try fileManager.createDirectory(at: artifactDir, withIntermediateDirectories: true)
        let artifact = artifactDir.appendingPathComponent("manifest.json")
        let manifest: [String: Any] = [
            "check": "browser-inspector-link-lifecycle",
            "duplicateInspectorPrevented": duplicateInspectorPrevented,
            "revealBrowserWorked": revealBrowserWorked,
            "deleteBrowserDeletedInspector": deleteBrowserDeletedInspector,
            "restartPreservedLink": restartPreservedLink,
            "reloadUpdatedHeader": reloadUpdatedHeader,
            "browserContextMenuIncludesOpenInspector": browserContextMenuIncludesOpenInspector,
            "browserTileId": browserTileId.uuidString,
            "inspectorTileId": inspectorTileId.uuidString,
            "headerTitleAfterReload": inspectorView.headerTitleForQA,
            "headerDetailAfterReload": inspectorView.headerDetailForQA,
            "viewportBeforeReveal": [
                "x": viewportBeforeReveal.x,
                "y": viewportBeforeReveal.y,
                "zoom": viewportBeforeReveal.zoom
            ],
            "viewportAfterReveal": [
                "x": viewportAfterReveal.x,
                "y": viewportAfterReveal.y,
                "zoom": viewportAfterReveal.zoom
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: artifact, options: .atomic)
        return artifact
    }

    private func launchPreferredEditor(path: String) -> Bool {
        guard let spec = registry.spec(for: "nvim") else {
            return false
        }
        let resolution = registry.resolve(
            spec,
            in: project.rootPath,
            environment: environmentProvider(),
            detector: detector
        )
        guard case let .found(profile) = resolution else {
            return false
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: profile.command, isDirectory: false)
        process.currentDirectoryURL = URL(fileURLWithPath: profile.cwd, isDirectory: true)
        process.arguments = editorArguments(from: profile.arguments, path: path)
        do {
            try process.run()
            return true
        } catch {
            return false
        }
    }

    private func editorArguments(from arguments: [String], path: String) -> [String] {
        if let index = arguments.firstIndex(of: ".") {
            var patched = arguments
            patched[index] = path
            return patched
        }
        return arguments + [path]
    }

    /// Placement for a tile that will be installed through `installProjectTile`.
    ///
    /// A ZoneLayer stores ZONE-LOCAL frames (`_layoutLayerTile` adds the zone origin
    /// back); the flat single-zone path stores world frames. Only the file-open route
    /// installs layer-aware today, so only it may place in local space — the other
    /// spawn paths still call `install`/`saveCanvas` directly and must keep the
    /// existing world-frame behaviour until they migrate too.
    private func makeProjectTilePlacement(worldPoint: CGPoint?, size: CGSize, in canvasView: CanvasNSView) -> TileFrame {
        guard let zone = canvasView.activeProjectZonePlacement else {
            return makePlacement(worldPoint: worldPoint, size: size, in: canvasView)
        }
        if let worldPoint {
            let local = CanvasEngine.zoneLocalPoint(world: worldPoint, zone: zone)
            return TileFrame(
                x: Double(local.x) - Double(size.width) / 2,
                y: Double(local.y) - Double(size.height) / 2,
                width: Double(size.width),
                height: Double(size.height)
            )
        }
        let zoom = canvasView.viewport.zoom.isFinite && canvasView.viewport.zoom > 0 ? canvasView.viewport.zoom : 1
        let visibleWidth = max(Double(canvasView.bounds.width) / zoom, Double(size.width))
        let visibleHeight = max(Double(canvasView.bounds.height) / zoom, Double(size.height))
        return CanvasEngine.placementFrame(
            size: size,
            viewport: CanvasViewport(
                x: canvasView.viewport.x - zone.origin.x,
                y: canvasView.viewport.y - zone.origin.y,
                zoom: zoom
            ),
            visibleSize: CGSize(width: visibleWidth * zoom, height: visibleHeight * zoom),
            existing: canvasView.projectTiles().map(\.frame)
        )
    }

    private func makePlacement(worldPoint: CGPoint?, size: CGSize, in canvasView: CanvasNSView) -> TileFrame {
        if let worldPoint {
            return TileFrame(
                x: Double(worldPoint.x) - Double(size.width) / 2,
                y: Double(worldPoint.y) - Double(size.height) / 2,
                width: Double(size.width),
                height: Double(size.height)
            )
        }
        var placementViewport = canvasView.viewport
        var placementVisibleSize = canvasView.bounds.size
        if let activeZone = canvasView.activeZone {
            let zoom = canvasView.viewport.zoom.isFinite && canvasView.viewport.zoom > 0 ? canvasView.viewport.zoom : 1
            let localX = canvasView.viewport.x - activeZone.origin.x
            let localY = canvasView.viewport.y - activeZone.origin.y
            let maxOriginX = max(0, activeZone.size.width - Double(size.width))
            let maxOriginY = max(0, activeZone.size.height - Double(size.height))
            let clampedX = min(max(localX, 0), maxOriginX)
            let clampedY = min(max(localY, 0), maxOriginY)
            let visibleWidth = max(Double(canvasView.bounds.width) / zoom, Double(size.width))
            let visibleHeight = max(Double(canvasView.bounds.height) / zoom, Double(size.height))
            let boundedVisibleWidth = min(visibleWidth, max(Double(size.width), activeZone.size.width - clampedX))
            let boundedVisibleHeight = min(visibleHeight, max(Double(size.height), activeZone.size.height - clampedY))
            placementViewport = CanvasViewport(x: clampedX, y: clampedY, zoom: zoom)
            placementVisibleSize = CGSize(width: boundedVisibleWidth * zoom, height: boundedVisibleHeight * zoom)
        }
        return CanvasEngine.placementFrame(
            size: size,
            viewport: placementViewport,
            visibleSize: placementVisibleSize,
            existing: canvasView.canvasState.tiles.map(\.frame)
        )
    }
}
