import AppKit
import Combine
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Foundation

@MainActor
final class ZoneRuntimeController {
    let projectRoot: URL
    let projectStore: any ProjectStoring
    let managedSessionStore: ManagedAgentSessionStore
    private(set) var project: Project

    // Decision F seam: the null implementation is the only live wiring today.
    var agentBus: any AgentMessageBus = NullAgentMessageBus()

    var runtimes: [GhosttyTerminalRuntime] = []
    var browserRuntimes: [WKWebViewBrowserRuntime] = []
    var noteViews: [UUID: NoteTileNSView] = [:]
    var fileTreeViews: [UUID: FileTreeTileNSView] = [:]

    weak var canvasView: CanvasNSView?
    /// STRONG on purpose. `WorkspaceRuntime.install`/`switchWorkspace` build the
    /// spawner for the arriving active project and hand it over here; while this was
    /// `weak`, that spawner had no other owner and deallocated before the switch
    /// returned, leaving every spawn action pointed at the boot project's spawner.
    /// `detachUI()` clears it, so the controller does not outlive its UI. TileSpawner
    /// holds `canvasView` weakly and every controller callback it exposes captures
    /// `[weak self]`, so this is not a cycle.
    var tileSpawner: TileSpawner?
    var onBrowserRuntimeHydrated: ((WKWebViewBrowserRuntime) -> Void)?
    /// Fired after `SessionObserver`'s `StatusWriter` persists a status
    /// change and pushes it onto the live tile view (docs/38-tickets/
    /// 40-session-observer.md). `AppDelegate` wires this to
    /// `refreshAgentAttentionSurface()`/`reloadWorkspaceSidebar()` — the
    /// same existing surfaces `updateAgentStatus` already refreshes on every
    /// other status-changing path (round-3 concern: observer writes must not
    /// be the one path that leaves the dock badge/sidebar stale).
    var onAgentStatusWritten: ((UUID, AgentStatus) -> Void)?
    var onObservedAgentStatusesChanged: (([UUID: AgentStatus]) -> Void)?
    /// Fired after the debounced canvas autosave actually persists — the
    /// single funnel every canvas mutation passes through. Ticket 86: the
    /// companion publish hangs off this so the phone tracks canvas changes
    /// without manual publishes.
    var onCanvasStatePersisted: (() -> Void)?
    /// Test-only override for the observer's readers, bypassing the default
    /// `ClaudeAgentStateReader()`/`CodexAgentStateReader()`/`PiAgentStateReader()`
    /// construction in `startSessionObserver()`. `NSHomeDirectory()` does not
    /// observe `setenv("HOME", ...)` once a process has launched (verified:
    /// it still resolves the real user home), so a check driving the real
    /// production wiring end to end has no other way to point the Claude
    /// reader's `homeURL` at an isolated directory instead of the developer's
    /// real `~/.claude` — the same seam `TileSpawner` already exposes for
    /// `managedSessionStore`/`tmuxPathResolver`/`tmuxControlFactory`.
    var sessionObserverReadersOverrideForTesting: SessionObserver.Readers?
    private weak var focusBroker: FocusBroker?

    private var saveTimer: Timer?
    private var browserSaveTimer: Timer?
    private var noteSaveTimer: Timer?
    private var fileTreeSaveTimer: Timer?
    private var sessionPruner: SessionPruner?
    private var sessionObserver: SessionObserver?

    /// QA (M1.3b): whether this controller took the process-wide attachments —
    /// session observer and tmux reaper. `attachSpawner` must leave both alone, and
    /// a witness that only checked `tileSpawner != nil` could not tell the two
    /// attach paths apart.
    var qaHoldsProcessWideAttachments: Bool { sessionObserver != nil || sessionPruner != nil }
    private var isCanvasDirty = false
    private var isBrowserDirty = false
    private var isNoteDirty = false
    private var isFileTreeDirty = false

    private let projectLock: ProjectLock?
    private var isClosed = false
    private(set) var hydrationTier: HydrationTier = .live

    // Ticket 24 (double-resume race): two focus events on the same tile close
    // together (e.g. `.appActivated` on relaunch immediately followed by a
    // `.userClick` restoring prior focus) can both read the same stale
    // `ManagedAgentSessionRecord` before either has written back a fresh
    // window target, each calling `tmux.newWindow` and leaking a duplicate
    // tmux window. This set is checked-and-inserted synchronously (no `await`
    // between the check and the insert), so it is safe under MainActor's
    // cooperative scheduling even though the recovery itself suspends: at most
    // one in-flight recovery per tile is ever allowed to reach `recoverRecord`.
    private var inFlightRecoveries: Set<UUID> = []

    enum HydrationLifecycleError: Error, CustomStringConvertible {
        case controllerClosed
        case uiUnavailable
        case focusedZoneMustRemainLive(UUID)
        case browserRehydrateFailed(UUID, TileSpawner.BrowserRestartOutcome)

        var description: String {
            switch self {
            case .controllerClosed:
                return "controller is closed"
            case .uiUnavailable:
                return "controller UI is unavailable"
            case let .focusedZoneMustRemainLive(tileId):
                return "cannot dehydrate focused zone while tile \(tileId) is active"
            case let .browserRehydrateFailed(tileId, outcome):
                return "failed to rehydrate browser tile \(tileId): \(outcome)"
            }
        }
    }

    enum SessionError: Error, CustomStringConvertible {
        case noBinding
        case noResumeState
        case windowRebindFailed(underlying: Error)

        var description: String {
            switch self {
            case .noBinding:
                return "no managed session binding"
            case .noResumeState:
                return "no resume state for managed session"
            case let .windowRebindFailed(underlying):
                return "window rebind failed: \(underlying)"
            }
        }
    }

    struct LiveSession: Equatable {
        let tileId: UUID
        let windowTarget: String
        let resumeCursor: Data?
    }

    enum RoutableSessionOutcome: Equatable {
        case live(LiveSession)
        case inactive
    }

    init(root projectRoot: URL, acquireLock: Bool = true) throws {
        self.projectRoot = projectRoot
        if acquireLock {
            let projectLock = ProjectLock(root: projectRoot)
            try projectLock.acquire()
            self.projectLock = projectLock
        } else {
            self.projectLock = nil
        }

        let projectStore = ProjectStore(projectRoot: projectRoot)
        self.projectStore = projectStore
        self.managedSessionStore = ManagedAgentSessionStore(projectRoot: projectRoot)

        pruneExitedSessions(in: projectStore)
        self.project = try Self.loadOrCreateProject(in: projectStore, projectRoot: projectRoot)
    }

    init(projectRoot: URL, projectStore: any ProjectStoring, project: Project) {
        self.projectRoot = projectRoot
        self.projectStore = projectStore
        self.managedSessionStore = ManagedAgentSessionStore(projectRoot: projectRoot)
        self.project = project
        self.projectLock = nil
    }

    /// The single authoritative call site for this controller's project session name.
    /// No other code should construct an `array-proj-` name by hand.
    func projectSessionName() -> String {
        TmuxSession.projectSessionName(projectId: project.id)
    }

    /// Project-scoped kill argv — callers must never issue this on a mere release,
    /// only on deliberate project deletion (see D16).
    func killProjectSessionCommand(tmuxPath: String) -> (command: String, arguments: [String]) {
        TmuxSession.killProjectSessionCommand(projectId: project.id, tmuxPath: tmuxPath)
    }

    // D16 (docs/38-locked-decisions.md): project release = DETACH, never kill.
    // This function intentionally issues no tmux command. The controller holds no
    // TmuxControl or Process, so release has no executable tmux path. Sessions stay
    // alive across workspace switches; only explicit user tile close may issue kill-window.
    func close() {
        guard !isClosed else { return }
        isClosed = true

        stopReaper()
        sessionObserver?.stop()
        onObservedAgentStatusesChanged?([:])
        flushPendingSaves()
        detachUI()

        let now = Date()
        for runtime in runtimes {
            if var descriptor = try? projectStore.loadSession(id: runtime.id) {
                descriptor.lastExit = TerminalLastExit(exitCode: nil, signal: nil, at: now)
                try? projectStore.saveSession(descriptor)
            }
            if var record = try? managedSessionStore.load(tileId: runtime.tileId) {
                record.status = .stopped
                record.lastSeenAt = now
                try? managedSessionStore.upsert(record)
            }
        }

        projectLock?.release()
    }

    /// A spawner for a live but NON-active controller. M1.3b (`.plans/46`).
    ///
    /// Deliberately a subset of `attachUI`: no session observer, no tmux reaper, no
    /// `focusBroker` callbacks. Those three take ownership of process-wide or
    /// shared state and exactly one controller may hold them, so they stay with the
    /// active zone. What a non-active controller does need is the ability to build
    /// and restore its own tiles — which is a per-project factory, safe to hold
    /// anywhere — so that hydration reaches every zone rather than only the one in
    /// front of you.
    func attachSpawner(_ tileSpawner: TileSpawner, canvasView: CanvasNSView) {
        self.canvasView = canvasView
        self.tileSpawner = tileSpawner
        tileSpawner.terminalSpawnedHandler = { [weak self] descriptor in
            self?.sessionObserverTileDidSpawn(descriptor)
        }
    }

    func attachUI(canvasView: CanvasNSView, tileSpawner: TileSpawner, focusBroker: FocusBroker) {
        self.canvasView = canvasView
        self.tileSpawner = tileSpawner
        self.focusBroker = focusBroker
        canvasView.focusBroker = focusBroker
        tileSpawner.terminalSpawnedHandler = { [weak self] descriptor in
            self?.sessionObserverTileDidSpawn(descriptor)
        }
        // Lockstep: every accepted tile focus (via requestFocus OR
        // acceptExistingFocus, both fire this) marks the tile active on the
        // canvas, so `activeSurface` and `lastActiveTileId` can never drift.
        focusBroker.onAcceptedTileFocus = { [weak self] tileId in
            self?.canvasView?.markActive(tileId: tileId)
        }
        // M1.10: compose from the app's OWN field, never from the live closure.
        // Chaining from `onAcceptedTileFocusWithReason` meant boot's
        // `installAcceptedTileFocusHook()` — which runs immediately after this —
        // overwrote the composite and killed `recoverManagedSessionOnFocus`, and
        // it meant every workspace switch added another link.
        focusBroker.onAcceptedTileFocusWithReason = { [weak self] tileId, reason in
            self?.recoverManagedSessionOnFocus(tileId: tileId, reason: reason)
        }
        // Scope leaving all tiles (canvas/modal) clears the marching-ants
        // border; the tile→tile transition is covered by markActive above.
        focusBroker.onAcceptedCanvasScope = { [weak self] in
            self?.canvasView?.clearFocusBorder()
        }
        focusBroker.activationFallbackSurfaces = { [weak self] in
            guard let self else { return [] }
            var fallbacks: [FocusSurfaceID] = []
            if let targetId = self.canvasView?.canvasState.lastActiveTileId {
                fallbacks.append(.tile(targetId))
            }
            if let fallback = self.runtimes.last?.tileId,
               !fallbacks.contains(.tile(fallback)) {
                fallbacks.append(.tile(fallback))
            }
            return fallbacks
        }
        startSessionObserver()
        if let tmuxPath = TmuxLocator.resolve() {
            startReaper(
                tmuxControl: ProcessTmuxControl(
                    tmuxPath: tmuxPath,
                    reach: project.remoteEnvironment?.reach ?? .localhost
                ),
                activitySnapshotSource: { nil }
            )
        }
    }

    // docs/38-tickets/40-session-observer.md, ruling C-20260706-031 items 2/5:
    // wires the three injected seams. `windowTargetLookup` and `writeStatus`
    // never touch anything the observer couldn't reach itself — this is the
    // controller's own load-mutate-saveSession shape, same as `close()`'s
    // `lastExit` write.
    private func startSessionObserver() {
        sessionObserver?.stop() // guards a second attachUI() the same way startReaper() does
        let tmuxPath = TmuxLocator.resolve()
        let reach = project.remoteEnvironment?.reach ?? .localhost
        let observer = SessionObserver(
            readers: sessionObserverReadersOverrideForTesting ?? SessionObserver.Readers(
                claude: ClaudeAgentStateReader(),
                codex: CodexAgentStateReader(),
                pi: PiAgentStateReader()
            ),
            paneCommandQuery: { target in
                guard let tmuxPath else { throw TmuxControlError.paneNotFound(target: target) }
                return try await SessionObserver.liveDisplayMessageQuery(
                    tmuxPath: tmuxPath,
                    target: target,
                    reach: reach
                )
            },
            windowTargetLookup: { [weak self] tileId in
                guard let self else { return nil }
                return (try? self.managedSessionStore.load(tileId: tileId))?.tmuxWindowTarget()
            },
            writeStatus: { [weak self] tileId, status, asOf in
                guard let self else { return }
                // Resolve tileId -> persisted descriptor the same way
                // `updateAgentStatus`/`stopHarnessRun` already do elsewhere
                // in this file, not via `self.runtimes` (a live-ghostty-only
                // list): a tile can be legitimately observed/detected
                // (`windowTargetLookup` only needs `managedSessionStore`)
                // before or without a live `GhosttyTerminalRuntime` entry
                // existing, and gating the WRITE on that entry while
                // detection isn't gated on it would silently drop otherwise-
                // valid status changes (round-3 concern: production wiring
                // must actually persist, not just be reachable).
                guard var descriptor = (try? self.projectStore.listSessions())?.first(where: { $0.tileId == tileId }) else { return }
                guard descriptor.agentDescriptor != nil else { return }
                descriptor.agentDescriptor?.status = status
                descriptor.agentDescriptor?.statusUpdatedAt = asOf
                try? self.projectStore.saveSession(descriptor)
                // Round-3 concern (Codex): the persisted write alone leaves
                // the live canvas stale — `canvasView.agentStatus`/the tile
                // view's own `agentStatus` property is what current
                // consumers (`currentAgentTileIds`, `updateAgentStatus`'s own
                // precedent) actually read, so push it the same way
                // `updateAgentStatus` does. `onAgentStatusWritten` lets the
                // owning `AppDelegate` refresh the dock badge and sidebar
                // (existing surfaces, not a new one — ruling item 8's
                // no-new-surface constraint is unaffected).
                self.canvasView?.tileView(for: tileId)?.agentStatus = status
                self.canvasView?.refreshRunArtifactsTiles()
                self.onAgentStatusWritten?(tileId, status)
            }
        )
        observer.onStatusesChanged = { [weak self] statuses in
            self?.onObservedAgentStatusesChanged?(statuses)
        }
        sessionObserver = observer
        observer.start(tiles: (try? projectStore.listSessions()) ?? [])
    }

    /// Called from the tile-spawn path (`TileSpawner.terminalSpawnedHandler`,
    /// wired by `AppDelegate`) whenever a new terminal tile comes to life
    /// while the observer is already running.
    func sessionObserverTileDidSpawn(_ descriptor: TerminalSessionDescriptor) {
        sessionObserver?.tileDidSpawn(descriptor)
    }

    /// Called from the deliberate tile-close path (`AppDelegate.deleteTile`)
    /// so the observer drops its watcher/state for a tile that no longer
    /// exists.
    func sessionObserverTileDidClose(tileId: UUID) {
        sessionObserver?.tileDidClose(tileId: tileId)
    }

    /// Test-only: exposes the real observer's detected kind for a tile so a
    /// production-wiring check (`--terminal-tmux-observer-wiring-check`) can
    /// distinguish "stuck" from "correctly detected." Two boot-ordering
    /// hazards land here: `windowTargetLookup` returning `nil` (no
    /// `managedSessionStore` record yet) leaves `detectAndRegister` returning
    /// before an observation ever exists; a stale/dead pre-restore `%pane_id`
    /// that still resolves (real tmux's `display-message -p` on a dead pane
    /// exits 0 with empty fields, not an error) DOES create an observation,
    /// but one permanently stuck at `.unknown` — `detectAndRegister`'s
    /// "fully settled" early-return re-derives the same empty result every
    /// slow-cadence pass. Either way the tile never becomes `.claude` until
    /// something re-notifies the observer with a fresh target.
    func sessionObserverDetectedKindForTesting(_ tileId: UUID) -> AgentKind? {
        sessionObserver?.detectedKindForTesting(tileId)
    }

    func startReaper(
        tmuxControl: any TmuxControl,
        activitySnapshotSource: @escaping @Sendable () async -> ActivityLogSnapshot?,
        clock: any Clock = SystemClock(),
        defaults: UserDefaults = .standard
    ) {
        stopReaper()

        let config = SessionPruner.Configuration(
            inactivityThreshold: IdleReaperConfig.resolveInactivityThreshold(defaults: defaults),
            sweepInterval: IdleReaperConfig.resolveSweepInterval(defaults: defaults)
        )

        let pruner = SessionPruner(
            tmuxControl: tmuxControl,
            clock: clock,
            configuration: config,
            bindingSource: { [weak self] in
                guard let self else { return [] }
                return await MainActor.run {
                    let tileIds = self.canvasView?.canvasState.tiles.map(\.id) ?? self.runtimes.map(\.tileId)
                    guard !tileIds.isEmpty else { return [] }
                    let recordLastSeenAt = tileIds
                        .compactMap { try? self.managedSessionStore.load(tileId: $0)?.lastSeenAt }
                        .max()
                    return [
                        SessionPruner.SessionBinding(
                            sessionName: self.projectSessionName(),
                            tileIds: tileIds,
                            lastSeenAt: recordLastSeenAt ?? self.project.createdAt
                        )
                    ]
                }
            },
            activitySnapshotSource: activitySnapshotSource
        )
        sessionPruner = pruner
        Task { await pruner.start() }
    }

    func stopReaper() {
        guard let pruner = sessionPruner else { return }
        sessionPruner = nil
        Task { await pruner.stop() }
    }

    func detachUI() {
        canvasView?.detachFocusBroker()
        focusBroker?.onAcceptedTileFocus = nil
        focusBroker?.onAcceptedTileFocusWithReason = nil
        focusBroker?.onAcceptedCanvasScope = nil
        focusBroker?.activationFallbackSurfaces = nil
        focusBroker = nil
        canvasView = nil
        tileSpawner = nil
    }

    func routableSession(
        forTile tileId: UUID,
        allowRecovery: Bool,
        tmux: any TmuxControl
    ) async throws -> RoutableSessionOutcome {
        guard let record = try managedSessionStore.load(tileId: tileId) else {
            throw SessionError.noBinding
        }

        if let target = record.tmuxWindowTarget(),
           try await tmux.isAlive(paneTarget: target) {
            var updated = record
            updated.lastSeenAt = Date()
            try managedSessionStore.upsert(updated)
            return .live(LiveSession(tileId: tileId, windowTarget: target, resumeCursor: record.resumeCursor))
        }

        guard allowRecovery else {
            return .inactive
        }

        guard record.resumeCursor != nil else {
            throw SessionError.noResumeState
        }

        return .live(try await recoverRecord(record, tmux: tmux))
    }

    private func recoverRecord(
        _ record: ManagedAgentSessionRecord,
        tmux: any TmuxControl
    ) async throws -> LiveSession {
        let cwd = runtimePayloadFields(from: record.runtimePayload)?.cwd ?? projectRoot.path
        let newTarget: String
        do {
            newTarget = try await tmux.newWindow(inSession: projectSessionName(), cwd: cwd, innerCommand: nil)
        } catch {
            throw SessionError.windowRebindFailed(underlying: error)
        }
        guard TmuxSession.isValidPaneId(newTarget) else {
            throw SessionError.windowRebindFailed(underlying: SessionError.noResumeState)
        }

        var updated = record
        updated.runtimePayload = try ManagedAgentSessionRecord.makeRuntimePayload(windowTarget: newTarget, cwd: cwd)
        updated.lastSeenAt = Date()
        try managedSessionStore.upsert(updated)
        return LiveSession(tileId: record.tileId, windowTarget: newTarget, resumeCursor: record.resumeCursor)
    }

    private func recoverManagedSessionOnFocus(tileId: UUID, reason: FocusRequest) {
        guard Self.shouldAttemptLazyRecovery(for: reason) else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let record = try? self.managedSessionStore.load(tileId: tileId) else { return }
            guard record.agentKind != .managed else { return }
            guard let tmuxPath = TmuxLocator.resolve() else {
                self.postSessionError(.windowRebindFailed(underlying: TmuxControlError.paneNotFound(target: "tmux-not-found")), forTile: tileId)
                return
            }
            await self.recoverManagedSessionOnFocus(
                tileId: tileId,
                reason: reason,
                tmux: ProcessTmuxControl(
                    tmuxPath: tmuxPath,
                    reach: self.project.remoteEnvironment?.reach ?? .localhost
                )
            )
        }
    }

    private func recoverManagedSessionOnFocus(
        tileId: UUID,
        reason: FocusRequest,
        tmux: any TmuxControl
    ) async {
        guard Self.shouldAttemptLazyRecovery(for: reason) else { return }
        // Coalesce: if a recovery for this tile is already in flight, skip —
        // the in-flight call owns the one-window guarantee. Check-and-insert
        // is synchronous (no `await` in between), so it is race-free even
        // though two focus events can enqueue concurrent calls to this method.
        guard !inFlightRecoveries.contains(tileId) else { return }
        inFlightRecoveries.insert(tileId)
        defer { inFlightRecoveries.remove(tileId) }
        do {
            _ = try await routableSession(
                forTile: tileId,
                allowRecovery: true,
                tmux: tmux
            )
        } catch SessionError.noBinding {
            return
        } catch let error as SessionError {
            postSessionError(error, forTile: tileId)
        } catch {
            postSessionError(.windowRebindFailed(underlying: error), forTile: tileId)
        }
    }

    private static func shouldAttemptLazyRecovery(for reason: FocusRequest) -> Bool {
        switch reason {
        case .userClick, .appActivated:
            return true
        case .modalOpened, .modalDismissed, .tileSpawned, .tileClosed, .runtimeExited, .recovery:
            return false
        }
    }

    private func postSessionError(_ error: SessionError, forTile tileId: UUID) {
        NotificationCenter.default.post(
            name: .continuumManagedSessionRecoveryError,
            object: self,
            userInfo: [
                "tileId": tileId,
                "error": error
            ]
        )
    }

    private func runtimePayloadFields(from data: Data?) -> ManagedAgentSessionRecord.RuntimePayloadFields? {
        guard let data else { return nil }
        return try? JSONCodec.makeDecoder().decode(ManagedAgentSessionRecord.RuntimePayloadFields.self, from: data)
    }

    func setTier(
        _ targetTier: HydrationTier,
        allowDehydratingFocusedZone: Bool = false,
        snapshotImageProvider: (WKWebViewBrowserRuntime) -> NSImage = { _ in ZoneRuntimeController.placeholderSnapshotImage() }
    ) throws {
        guard !isClosed else { throw HydrationLifecycleError.controllerClosed }
        guard targetTier != hydrationTier else { return }

        switch targetTier {
        case .live:
            try hydrateToLive()
        case .snapshot, .cold:
            try dehydrate(to: targetTier, allowDehydratingFocusedZone: allowDehydratingFocusedZone, snapshotImageProvider: snapshotImageProvider)
        }
        hydrationTier = targetTier
    }

    private func dehydrate(
        to targetTier: HydrationTier,
        allowDehydratingFocusedZone: Bool,
        snapshotImageProvider: (WKWebViewBrowserRuntime) -> NSImage
    ) throws {
        guard targetTier == .snapshot || targetTier == .cold else { return }
        guard let canvasView, let tileSpawner else { throw HydrationLifecycleError.uiUnavailable }
        if !allowDehydratingFocusedZone, let focusedTileId = canvasView.canvasState.lastActiveTileId {
            throw HydrationLifecycleError.focusedZoneMustRemainLive(focusedTileId)
        }

        flushPendingSaves()
        let liveBrowsers = browserRuntimes
        for runtime in liveBrowsers {
            try tileSpawner.installBrowserSnapshotTile(runtime: runtime, snapshotImage: snapshotImageProvider(runtime))
        }
        browserRuntimes.removeAll { runtime in
            liveBrowsers.contains { $0.id == runtime.id }
        }
    }

    private func hydrateToLive() throws {
        guard let canvasView, let tileSpawner else { throw HydrationLifecycleError.uiUnavailable }
        // M1.0 (.plans/46): read THIS project's tiles from whichever model owns
        // them. The flat `canvasState` holds the departed project's tiles after a
        // workspace switch, so filtering it here rehydrated the wrong browsers --
        // or none. Same root cause as the two persistence paths above.
        let ownedTiles = canvasView.isFlatCompatibilitySceneActive
            ? canvasView.canvasState.tiles
            : canvasView.tiles(forProjectId: project.id)
        let browserTileIds = ownedTiles
            .filter { $0.kind == .browser && $0.runtimeRef == nil }
            .map(\.id)

        for tileId in browserTileIds {
            switch tileSpawner.restartBrowserTile(tileId: tileId) {
            case let .restarted(runtime):
                browserRuntimes.append(runtime)
                onBrowserRuntimeHydrated?(runtime)
            case let outcome:
                throw HydrationLifecycleError.browserRehydrateFailed(tileId, outcome)
            }
        }
    }

    private static func placeholderSnapshotImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 80, height: 60))
        image.lockFocus()
        NSColor.windowBackgroundColor.setFill()
        NSRect(x: 0, y: 0, width: 80, height: 60).fill()
        image.unlockFocus()
        return image
    }

    func paletteRows(registryStore: RegistryStore?) -> (profiles: [TileSpawner.AnnotatedProfile], projects: [ProjectPickerRow], workspaces: [WorkspaceEntry]) {
        let profiles = tileSpawner?.annotatedProfiles() ?? []
        guard let registryStore,
              let registry = try? registryStore.loadOrEmpty() else {
            return (profiles, [], [])
        }
        let projects = ProjectPickerModel.makeRows(registry: registry)
            .filter { $0.id != project.id }
        return (profiles, projects, registry.workspaces)
    }

    /// What this controller is allowed to write into ITS OWN project's canvas.
    ///
    /// M1.0 (`.plans/46`). Both flush paths used to persist `canvasView.canvasState`
    /// verbatim. That flat collection is not a mirror: `setZones` never updates it
    /// and `retireFlatCompatibilityScene` deliberately leaves it holding the
    /// DEPARTED project's tiles. Since `canvasDidChange` schedules the save on the
    /// newly ACTIVE controller, the first canvas change after a workspace switch
    /// wrote project A's tiles into project B's file. Witnessed by
    /// `--canvas-persistence-model-check`.
    private func canvasStateToPersist(canvasView: CanvasNSView) -> CanvasState {
        let persistedTiles = ((try? projectStore.tryLoadCanvas()) ?? nil)?.tiles ?? []
        // Base on the LIVE canvas: this path's whole job is saving the camera.
        return canvasView.canvasStateForPersistence(
            projectId: project.id,
            base: canvasView.canvasState,
            persistedTiles: persistedTiles
        )
    }

    func scheduleCanvasSave() {
        // Coalesce drag-rate writes: schedule a save after the last change.
        // flushPendingSaves() runs immediately for project switch and close.
        isCanvasDirty = true
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.flushCanvasSaveOffMain() }
        }
    }

    /// One serial queue for every controller's canvas writes, so debounced and
    /// synchronous saves to a file can never interleave.
    private static let canvasSaveQueue = DispatchQueue(label: "dev.arrayapp.canvas-save", qos: .utility)

    /// The debounced save path: snapshot on main, persist on the save queue.
    /// The atomic write is a JSON encode, a decode-validation round trip, a
    /// backup copy and TWO fsyncs — tens of milliseconds that used to land on
    /// the main thread ~200 ms after the last camera step, which is exactly
    /// when the user's next gesture begins. Deliberate writers (project
    /// switch, close, checks) still use the synchronous `flushCanvasSave`.
    private func flushCanvasSaveOffMain() {
        saveTimer?.invalidate()
        saveTimer = nil
        guard isCanvasDirty, let canvasView else { return }
        let snapshot = canvasStateToPersist(canvasView: canvasView)
        let store = projectStore
        isCanvasDirty = false
        Self.canvasSaveQueue.async { [weak self] in
            try? store.saveCanvas(snapshot)
            Task { @MainActor [weak self] in self?.onCanvasStatePersisted?() }
        }
    }

    func scheduleBrowserSave() {
        // Browser url/title changes coalesce identically to canvas drags.
        isBrowserDirty = true
        browserSaveTimer?.invalidate()
        browserSaveTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.flushBrowserSave() }
        }
    }

    func scheduleNoteSave() {
        isNoteDirty = true
        noteSaveTimer?.invalidate()
        noteSaveTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.flushNoteSave() }
        }
    }

    func scheduleFileTreeSave() {
        isFileTreeDirty = true
        fileTreeSaveTimer?.invalidate()
        fileTreeSaveTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.flushFileTreeSave() }
        }
    }

    func flushPendingSaves() {
        flushCanvasSave()
        flushBrowserSave()
        flushNoteSave()
        flushFileTreeSave()
    }

    func flushCanvasSave() {
        saveTimer?.invalidate()
        saveTimer = nil
        guard isCanvasDirty, let canvasView else { return }
        let snapshot = canvasStateToPersist(canvasView: canvasView)
        // Serialize behind any in-flight debounced write so the durable copy
        // on disk is the newest state — project switch and close rely on it.
        Self.canvasSaveQueue.sync {
            try? projectStore.saveCanvas(snapshot)
        }
        isCanvasDirty = false
        onCanvasStatePersisted?()
    }

    func flushBrowserSave() {
        browserSaveTimer?.invalidate()
        browserSaveTimer = nil
        guard isBrowserDirty, let tileSpawner else { return }
        for runtime in browserRuntimes {
            tileSpawner.writeBrowserTileSnapshot(for: runtime)
        }
        isBrowserDirty = false
    }

    func flushNoteSave() {
        noteSaveTimer?.invalidate()
        noteSaveTimer = nil
        guard isNoteDirty, let tileSpawner else { return }
        for view in noteViews.values {
            tileSpawner.writeNoteSnapshot(noteId: view.noteId, tileId: view.tile.id, text: view.textView.string)
        }
        isNoteDirty = false
    }

    func flushFileTreeSave() {
        fileTreeSaveTimer?.invalidate()
        fileTreeSaveTimer = nil
        guard isFileTreeDirty, let tileSpawner else { return }
        for view in fileTreeViews.values {
            tileSpawner.writeFileTreeTileSnapshot(for: view)
        }
        isFileTreeDirty = false
    }

    static func runHydrationLifecycleSelfCheck() throws -> URL {
        enum CheckError: Error, CustomStringConvertible {
            case failed(String)
            var description: String {
                switch self { case let .failed(message): return message }
            }
        }
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw CheckError.failed(message) }
        }

        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("continuum-zone-hydration-lifecycle-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let now = Date()
        let tileId = UUID(uuidString: "00000000-0000-0000-0000-000000000451")!
        let project = Project(
            id: UUID(uuidString: "00000000-0000-0000-0000-00000000045F")!,
            name: "zone-hydration-lifecycle-check",
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
            tiles: [Tile(
                id: tileId,
                kind: .browser,
                title: "Lifecycle browser",
                frame: TileFrame(x: 20, y: 20, width: 640, height: 420),
                zPosition: .fromLegacyRank(1),
                runtimeRef: nil,
                metadata: TileMetadata(url: "data:text/html;charset=utf-8,<html><head><title>lifecycle</title></head><body>ok</body></html>")
            )],
            groups: [],
            lastActiveTileId: nil
        ))

        let canvas = CanvasNSView(canvasState: try store.loadCanvas())
        let browserEngine = BrowserEngineContext()
        defer { browserEngine.shutdown() }
        let spawner = TileSpawner(canvasView: canvas, ghostty: nil, browserEngine: browserEngine, projectStore: store, project: project)
        let controller = ZoneRuntimeController(projectRoot: tempRoot, projectStore: store, project: project)
        controller.attachUI(canvasView: canvas, tileSpawner: spawner, focusBroker: FocusBroker())

        switch spawner.restartBrowserTile(tileId: tileId) {
        case let .restarted(runtime):
            controller.browserRuntimes = [runtime]
        case let .invalidURL(url):
            throw CheckError.failed("seed restart rejected URL: \(url)")
        case .tileNotFound:
            throw CheckError.failed("seed restart did not find browser tile")
        case let .failure(error):
            throw CheckError.failed("seed restart failed: \(error)")
        }

        try controller.setTier(.snapshot)
        let afterSnapshotTile = canvas.canvasState.tiles.first(where: { $0.id == tileId })
        let snapshotViewPresent = canvas.tileView(for: tileId) is BrowserSnapshotTileNSView
        let liveCountAfterSnapshot = controller.browserRuntimes.count
        let snapshotRuntimeRefCleared = afterSnapshotTile?.runtimeRef == nil

        try controller.setTier(.live)
        let afterLiveTile = canvas.canvasState.tiles.first(where: { $0.id == tileId })
        let liveViewPresent = canvas.tileView(for: tileId) is BrowserTileNSView
        let liveCountAfterHydrate = controller.browserRuntimes.count
        let liveRuntimeRefRestored = afterLiveTile?.runtimeRef?.kind == .browserTile

        canvas.markActive(tileId: tileId)
        let focusedGuardRejected: Bool
        do {
            try controller.setTier(.snapshot)
            focusedGuardRejected = false
        } catch HydrationLifecycleError.focusedZoneMustRemainLive(tileId) {
            focusedGuardRejected = true
        }
        let tierAfterFocusedGuard = controller.hydrationTier

        try expect(controller.hydrationTier == .live, "controller returns to live tier")
        try expect(snapshotViewPresent, "snapshot tier installs BrowserSnapshotTileNSView")
        try expect(snapshotRuntimeRefCleared, "snapshot tier clears browser runtimeRef")
        try expect(liveCountAfterSnapshot == 0, "snapshot tier removes live browser runtime from controller")
        try expect(liveViewPresent, "live tier reinstalls BrowserTileNSView")
        try expect(liveCountAfterHydrate == 1, "live tier re-registers one browser runtime")
        try expect(liveRuntimeRefRestored, "live tier restores browser runtimeRef")
        try expect(focusedGuardRejected, "focused zone guard rejects dehydration")
        try expect(tierAfterFocusedGuard == .live, "focused zone guard leaves tier live")

        let manifest: [String: Any] = [
            "check": "zone-hydration-lifecycle",
            "snapshotViewPresent": snapshotViewPresent,
            "snapshotRuntimeRefCleared": snapshotRuntimeRefCleared,
            "liveCountAfterSnapshot": liveCountAfterSnapshot,
            "liveViewPresent": liveViewPresent,
            "liveCountAfterHydrate": liveCountAfterHydrate,
            "liveRuntimeRefRestored": liveRuntimeRefRestored,
            "focusedGuardRejected": focusedGuardRejected,
            "tierAfterFocusedGuard": String(describing: tierAfterFocusedGuard),
            "finalTier": String(describing: controller.hydrationTier),
            "tempProjectRoot": tempRoot.path
        ]
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let directory = URL(fileURLWithPath: fileManager.currentDirectoryPath)
            .appendingPathComponent("qa-runs", isDirectory: true)
            .appendingPathComponent(timestamp, isDirectory: true)
            .appendingPathComponent("zone-hydration-lifecycle", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifestURL = directory.appendingPathComponent("manifest.json")
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: manifestURL, options: .atomic)
        return manifestURL
    }

    // Ticket 74: flag-gated real-path check. The retry ruling exempts this
    // self-check call site from the production grep gate.
    static func runAgentMessageBusSelfCheck() throws -> URL {
        enum CheckError: Error, CustomStringConvertible {
            case failed(String)
            var description: String {
                switch self { case let .failed(message): return message }
            }
        }
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw CheckError.failed(message) }
        }

        final class MockAgentMessageBus: AgentMessageBus {
            private(set) var recorded: [AgentBusMessage] = []
            private var handlers: [(AgentBusMessage) -> Void] = []

            func post(_ message: AgentBusMessage) {
                recorded.append(message)
                for handler in handlers { handler(message) }
            }

            func subscribe(handler: @escaping (AgentBusMessage) -> Void) -> AnyCancellable {
                handlers.append(handler)
                return AnyCancellable {}
            }
        }

        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("continuum-agent-message-bus-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let controller = try ZoneRuntimeController(root: tempRoot, acquireLock: false)
        let startedAsNull = controller.agentBus is NullAgentMessageBus
        try expect(startedAsNull, "agentBus defaults to NullAgentMessageBus")

        let mock = MockAgentMessageBus()
        controller.agentBus = mock
        let acceptedReassignment = controller.agentBus is MockAgentMessageBus
        try expect(acceptedReassignment, "agentBus accepts assignment of another AgentMessageBus implementation")

        let testMessage = AgentBusMessage(
            senderTileId: UUID(uuidString: "A0000000-0000-4000-8000-000000007401")!,
            logicalTime: 1,
            payload: .progressNote(text: "self-check probe")
        )
        controller.agentBus.post(testMessage)
        let recordedExactlyOnce = mock.recorded == [testMessage]
        try expect(recordedExactlyOnce, "controller.agentBus.post(testMessage) must reach the injected implementation exactly once")

        let manifest: [String: Any] = [
            "check": "agent-message-bus",
            "startedAsNull": startedAsNull,
            "acceptedReassignment": acceptedReassignment,
            "recordedExactlyOnce": recordedExactlyOnce,
            "tempProjectRoot": tempRoot.path
        ]
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let directory = URL(fileURLWithPath: fileManager.currentDirectoryPath)
            .appendingPathComponent("qa-runs", isDirectory: true)
            .appendingPathComponent(timestamp, isDirectory: true)
            .appendingPathComponent("agent-message-bus", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifestURL = directory.appendingPathComponent("manifest.json")
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: manifestURL, options: .atomic)
        return manifestURL
    }

    static func runSaveIsolationSelfCheck() throws -> URL {
        enum CheckError: Error, CustomStringConvertible {
            case failed(String)
            var description: String {
                switch self { case let .failed(message): return message }
            }
        }
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw CheckError.failed(message) }
        }
        func seedProject(root: URL, name: String, tileId: UUID) throws -> (ProjectStore, Project, CanvasState) {
            let store = ProjectStore(projectRoot: root)
            let project = Project(
                name: name,
                rootPath: root.path,
                createdAt: Date(),
                updatedAt: Date(),
                defaultLaunchProfileId: "shell",
                editorPreference: .auto,
                settings: ProjectSettings(
                    restorePolicy: .restoreDescriptors,
                    browserStoragePolicy: .perProject,
                    terminalClosePolicy: .askWhenRunning
                )
            )
            let canvas = CanvasState(
                viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
                tiles: [Tile(
                    id: tileId,
                    kind: .note,
                    title: name,
                    frame: TileFrame(x: 20, y: 20, width: 300, height: 180),
                    zPosition: .fromLegacyRank(1),
                    runtimeRef: nil,
                    metadata: TileMetadata(noteId: tileId)
                )],
                groups: [],
                lastActiveTileId: nil
            )
            try store.saveProject(project)
            try store.saveCanvas(canvas)
            return (store, project, canvas)
        }
        func bytes(at url: URL) throws -> Data { try Data(contentsOf: url) }
        func modificationDate(at url: URL) throws -> Date {
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey])
            guard let date = values.contentModificationDate else { throw CheckError.failed("missing modification date for \(url.path)") }
            return date
        }

        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("continuum-zone-save-isolation-\(UUID().uuidString)", isDirectory: true)
        let projectARoot = tempRoot.appendingPathComponent("ProjectA", isDirectory: true)
        let projectBRoot = tempRoot.appendingPathComponent("ProjectB", isDirectory: true)
        let projectCRoot = tempRoot.appendingPathComponent("ProjectC", isDirectory: true)
        let appSupport = tempRoot.appendingPathComponent("AppSupport", isDirectory: true)
        try fileManager.createDirectory(at: projectARoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: projectBRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: projectCRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: appSupport, withIntermediateDirectories: true)

        let tileA = UUID(uuidString: "00000000-0000-0000-0000-0000000049A1")!
        let tileB = UUID(uuidString: "00000000-0000-0000-0000-0000000049B2")!
        let tileC = UUID(uuidString: "00000000-0000-0000-0000-0000000049C3")!
        let workspaceId = UUID(uuidString: "00000000-0000-0000-0000-0000000049D4")!
        let (storeA, projectA, canvasA) = try seedProject(root: projectARoot, name: "Project A", tileId: tileA)
        let (storeB, projectB, canvasB) = try seedProject(root: projectBRoot, name: "Project B", tileId: tileB)
        let (storeC, projectC, canvasC) = try seedProject(root: projectCRoot, name: "Project C", tileId: tileC)
        let workspaceStore = WorkspaceStore(workspaceId: workspaceId, applicationSupportDirectory: appSupport)
        var workspaceDocument = WorkspaceDocument(
            viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
            zones: [ZonePlacement(
                zoneId: UUID(uuidString: "00000000-0000-0000-0000-0000000049E5")!,
                projectId: projectA.id,
                origin: ZonePoint(x: 0, y: 0),
                size: ZoneSize(width: 1280, height: 720),
                color: "mint",
                collapsed: false,
                hydrationPolicy: .automatic
            )],
            zoneZOrder: [UUID(uuidString: "00000000-0000-0000-0000-0000000049E5")!],
            lastActiveZoneId: UUID(uuidString: "00000000-0000-0000-0000-0000000049E5")!
        )
        try workspaceStore.save(workspaceDocument)
        let beforeWorkspace = try bytes(at: workspaceStore.layout.canvasFile)
        let beforeWorkspaceModifiedAt = try modificationDate(at: workspaceStore.layout.canvasFile)
        let beforeB = try bytes(at: storeB.layout.canvasFile)
        let beforeBModifiedAt = try modificationDate(at: storeB.layout.canvasFile)
        let beforeC = try bytes(at: storeC.layout.canvasFile)
        let beforeCModifiedAt = try modificationDate(at: storeC.layout.canvasFile)
        Thread.sleep(forTimeInterval: 1.1)

        let viewA = CanvasNSView(canvasState: canvasA)
        let viewB = CanvasNSView(canvasState: canvasB)
        let viewC = CanvasNSView(canvasState: canvasC)
        let browserEngine = BrowserEngineContext()
        defer { browserEngine.shutdown() }
        let spawnerA = TileSpawner(canvasView: viewA, ghostty: nil, browserEngine: browserEngine, projectStore: storeA, project: projectA)
        let spawnerB = TileSpawner(canvasView: viewB, ghostty: nil, browserEngine: browserEngine, projectStore: storeB, project: projectB)
        let spawnerC = TileSpawner(canvasView: viewC, ghostty: nil, browserEngine: browserEngine, projectStore: storeC, project: projectC)
        let controllerA = ZoneRuntimeController(projectRoot: projectARoot, projectStore: storeA, project: projectA)
        let controllerB = ZoneRuntimeController(projectRoot: projectBRoot, projectStore: storeB, project: projectB)
        let controllerC = ZoneRuntimeController(projectRoot: projectCRoot, projectStore: storeC, project: projectC)
        controllerA.attachUI(canvasView: viewA, tileSpawner: spawnerA, focusBroker: FocusBroker())
        controllerB.attachUI(canvasView: viewB, tileSpawner: spawnerB, focusBroker: FocusBroker())
        controllerC.attachUI(canvasView: viewC, tileSpawner: spawnerC, focusBroker: FocusBroker())

        controllerB.flushPendingSaves()
        controllerC.flushPendingSaves()
        let afterBCleanFlush = try bytes(at: storeB.layout.canvasFile)
        let afterBCleanFlushModifiedAt = try modificationDate(at: storeB.layout.canvasFile)
        let afterCCleanFlush = try bytes(at: storeC.layout.canvasFile)
        let afterCCleanFlushModifiedAt = try modificationDate(at: storeC.layout.canvasFile)
        let cleanSidecarsAbsent = !fileManager.fileExists(atPath: storeB.layout.browserFile.path)
            && !fileManager.fileExists(atPath: storeB.layout.notesIndexFile.path)
            && !fileManager.fileExists(atPath: storeB.layout.fileTreeIndexFile.path)
            && !fileManager.fileExists(atPath: storeC.layout.browserFile.path)
            && !fileManager.fileExists(atPath: storeC.layout.notesIndexFile.path)
            && !fileManager.fileExists(atPath: storeC.layout.fileTreeIndexFile.path)

        viewA.setViewport(CanvasViewport(x: 49, y: 0, zoom: 1))
        controllerA.scheduleCanvasSave()
        controllerA.flushPendingSaves()

        let afterBWhenAFlushed = try bytes(at: storeB.layout.canvasFile)
        let afterBWhenAFlushedModifiedAt = try modificationDate(at: storeB.layout.canvasFile)
        let afterWorkspaceWhenProjectAFlushed = try bytes(at: workspaceStore.layout.canvasFile)
        let afterWorkspaceWhenProjectAFlushedModifiedAt = try modificationDate(at: workspaceStore.layout.canvasFile)
        let reloadedA = try storeA.loadCanvas()
        let bCleanFlushUnchanged = beforeB == afterBCleanFlush && beforeBModifiedAt == afterBCleanFlushModifiedAt
        let cCleanFlushUnchanged = beforeC == afterCCleanFlush && beforeCModifiedAt == afterCCleanFlushModifiedAt
        let bUnchangedAfterAFlush = beforeB == afterBWhenAFlushed && beforeBModifiedAt == afterBWhenAFlushedModifiedAt
        let workspaceUnchangedAfterProjectFlush = beforeWorkspace == afterWorkspaceWhenProjectAFlushed && beforeWorkspaceModifiedAt == afterWorkspaceWhenProjectAFlushedModifiedAt
        let aViewportFlushed = reloadedA.viewport.x == 49

        workspaceDocument.zones[0].origin.x = 240
        let workspaceSaveController = WorkspaceDocumentSaveController(store: workspaceStore)
        workspaceSaveController.scheduleZoneLayoutSave(workspaceDocument)
        try workspaceSaveController.flushPendingSave()
        let afterWorkspaceLayoutChange = try bytes(at: workspaceStore.layout.canvasFile)
        let reloadedWorkspace = try workspaceStore.load()
        let workspaceChangedAfterZoneLayout = beforeWorkspace != afterWorkspaceLayoutChange && reloadedWorkspace.zones[0].origin.x == 240

        viewA.setViewport(CanvasViewport(x: 98, y: 0, zoom: 1))
        controllerA.scheduleCanvasSave()
        try controllerA.setTier(.snapshot, allowDehydratingFocusedZone: true)
        let reloadedAAfterDehydrate = try storeA.loadCanvas()
        let afterBAfterDehydrate = try bytes(at: storeB.layout.canvasFile)
        let afterBAfterDehydrateModifiedAt = try modificationDate(at: storeB.layout.canvasFile)
        let pendingFlushOnDehydrate = reloadedAAfterDehydrate.viewport.x == 98
        let bUnchangedAfterDehydrate = beforeB == afterBAfterDehydrate && beforeBModifiedAt == afterBAfterDehydrateModifiedAt

        try expect(bCleanFlushUnchanged, "clean zone B flush did not rewrite project B canvas")
        try expect(cCleanFlushUnchanged, "clean zone C flush did not rewrite project C canvas")
        try expect(cleanSidecarsAbsent, "clean browser/note/file-tree flushes did not create sidecar files in clean zones")
        try expect(aViewportFlushed, "zone A canvas change flushed to project A")
        try expect(bUnchangedAfterAFlush, "flushing zone A did not rewrite project B canvas")
        try expect(workspaceUnchangedAfterProjectFlush, "project canvas changes do not rewrite workspace document")
        try expect(workspaceChangedAfterZoneLayout, "zone-layout changes rewrite workspace document")
        try expect(pendingFlushOnDehydrate, "dehydrating zone A flushes pending canvas changes")
        try expect(bUnchangedAfterDehydrate, "dehydrating zone A did not rewrite project B canvas")

        let manifest: [String: Any] = [
            "check": "zone-save-isolation",
            "bCleanFlushUnchanged": bCleanFlushUnchanged,
            "cCleanFlushUnchanged": cCleanFlushUnchanged,
            "cleanSidecarsAbsent": cleanSidecarsAbsent,
            "aViewportFlushed": aViewportFlushed,
            "bUnchangedAfterAFlush": bUnchangedAfterAFlush,
            "workspaceUnchangedAfterProjectFlush": workspaceUnchangedAfterProjectFlush,
            "workspaceChangedAfterZoneLayout": workspaceChangedAfterZoneLayout,
            "pendingFlushOnDehydrate": pendingFlushOnDehydrate,
            "bUnchangedAfterDehydrate": bUnchangedAfterDehydrate,
            "workspaceCanvas": workspaceStore.layout.canvasFile.path,
            "projectACanvas": storeA.layout.canvasFile.path,
            "projectBCanvas": storeB.layout.canvasFile.path,
            "projectCCanvas": storeC.layout.canvasFile.path,
            "projectBCanvasModifiedAt": beforeBModifiedAt.timeIntervalSince1970,
            "tempRoot": tempRoot.path
        ]
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let directory = URL(fileURLWithPath: fileManager.currentDirectoryPath)
            .appendingPathComponent("qa-runs", isDirectory: true)
            .appendingPathComponent(timestamp, isDirectory: true)
            .appendingPathComponent("zone-save-isolation", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifestURL = directory.appendingPathComponent("manifest.json")
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: manifestURL, options: .atomic)
        return manifestURL
    }

    static func runProjectSessionNamingSelfCheck() throws -> URL {
        enum CheckError: Error, CustomStringConvertible {
            case failed(String)
            var description: String {
                switch self { case let .failed(message): return message }
            }
        }
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw CheckError.failed(message) }
        }
        func makeController(projectRoot: URL, projectId: UUID) throws -> ZoneRuntimeController {
            let now = Date()
            let project = Project(
                id: projectId,
                name: "project-session-naming-check",
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
            return ZoneRuntimeController(projectRoot: projectRoot, projectStore: store, project: project)
        }

        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("continuum-zone-project-session-naming-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let projectIdA = UUID(uuidString: "00000000-0000-0000-0000-0000000014A1")!
        let projectIdB = UUID(uuidString: "00000000-0000-0000-0000-0000000014B2")!
        let rootA = tempRoot.appendingPathComponent("ProjectA", isDirectory: true)
        let rootB = tempRoot.appendingPathComponent("ProjectB", isDirectory: true)
        try fileManager.createDirectory(at: rootA, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: rootB, withIntermediateDirectories: true)

        let controllerA = try makeController(projectRoot: rootA, projectId: projectIdA)
        let controllerB = try makeController(projectRoot: rootB, projectId: projectIdB)

        // Independently-constructed literal expected values — deliberately NOT derived by
        // calling TmuxSession.projectSessionName/killProjectSessionCommand, so this check can
        // catch a bug in either those functions or the controller's delegation to them, not
        // merely prove the two agree with each other.
        let expectedNameA = "array-proj-\(projectIdA.uuidString)"
        let expectedNameB = "array-proj-\(projectIdB.uuidString)"
        let controllerNameA = controllerA.projectSessionName()
        let controllerNameB = controllerB.projectSessionName()

        try expect(controllerNameA == expectedNameA, "controller.projectSessionName() (A): expected \(expectedNameA) got \(controllerNameA)")
        try expect(controllerNameB == expectedNameB, "controller.projectSessionName() (B): expected \(expectedNameB) got \(controllerNameB)")
        try expect(controllerNameA != controllerNameB, "controllers over two distinct project ids must not produce the same session name")

        let tmuxPath = "/usr/bin/tmux"
        let expectedKillCommandA = tmuxPath
        let expectedKillArgumentsA = ["kill-session", "-t", "array-proj-\(projectIdA.uuidString)"]
        let controllerKillArgsA = controllerA.killProjectSessionCommand(tmuxPath: tmuxPath)
        try expect(controllerKillArgsA.command == expectedKillCommandA, "controller.killProjectSessionCommand command mismatch: expected \(expectedKillCommandA) got \(controllerKillArgsA.command)")
        try expect(controllerKillArgsA.arguments == expectedKillArgumentsA, "controller.killProjectSessionCommand arguments mismatch: expected \(expectedKillArgumentsA) got \(controllerKillArgsA.arguments)")

        let manifest: [String: Any] = [
            "check": "zone-project-session-naming",
            "projectIdA": projectIdA.uuidString,
            "projectIdB": projectIdB.uuidString,
            "controllerNameA": controllerNameA,
            "controllerNameB": controllerNameB,
            "expectedNameA": expectedNameA,
            "expectedNameB": expectedNameB,
            "controllerKillArgsA": controllerKillArgsA.arguments,
            "expectedKillArgsA": expectedKillArgumentsA,
            "tempRoot": tempRoot.path
        ]
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let directory = URL(fileURLWithPath: fileManager.currentDirectoryPath)
            .appendingPathComponent("qa-runs", isDirectory: true)
            .appendingPathComponent(timestamp, isDirectory: true)
            .appendingPathComponent("zone-project-session-naming", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifestURL = directory.appendingPathComponent("manifest.json")
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: manifestURL, options: .atomic)
        return manifestURL
    }

    static func runLazyResumeSelfCheck() throws -> URL {
        enum CheckError: Error, CustomStringConvertible {
            case failed(String)
            var description: String {
                switch self { case let .failed(message): return message }
            }
        }
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw CheckError.failed(message) }
        }
        func awaitMain<T>(_ operation: @escaping @MainActor () async throws -> T) throws -> T {
            let box = ZoneRuntimeControllerAsyncCheckBox()
            Task { @MainActor in
                do {
                    box.result = .success(try await operation())
                } catch {
                    box.result = .failure(error)
                }
            }
            let deadline = Date().addingTimeInterval(5)
            while box.result == nil && Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
            }
            guard let result = box.result else {
                throw CheckError.failed("timed out waiting for lazy resume operation")
            }
            guard let value = try result.get() as? T else {
                throw CheckError.failed("lazy resume operation returned unexpected value type")
            }
            return value
        }
        func makeController(root: URL, projectId: UUID) throws -> ZoneRuntimeController {
            let now = Date(timeIntervalSince1970: 1_800_024_000)
            let project = Project(
                id: projectId,
                name: "lazy-resume-check",
                rootPath: root.path,
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
            let store = ProjectStore(projectRoot: root)
            try store.saveProject(project)
            return ZoneRuntimeController(projectRoot: root, projectStore: store, project: project)
        }
        func writeRecord(
            _ controller: ZoneRuntimeController,
            tileId: UUID,
            target: String?,
            cwd: String?,
            cursor: Data?,
            lastSeenAt: Date
        ) throws {
            let payload: Data?
            if let target {
                payload = try ManagedAgentSessionRecord.makeRuntimePayload(windowTarget: target, cwd: cwd)
            } else {
                payload = nil
            }
            let record = ManagedAgentSessionRecord(
                tileId: tileId,
                agentKind: .claude,
                status: .running,
                lastSeenAt: lastSeenAt,
                resumeCursor: cursor,
                runtimePayload: payload
            )
            try controller.managedSessionStore.upsert(record)
        }

        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("continuum-zone-lazy-resume-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let projectId = UUID(uuidString: "00000000-0000-0000-0000-0000000024A0")!
        let controller = try makeController(root: tempRoot, projectId: projectId)
        let sessionName = controller.projectSessionName()
        let tmux = InMemoryTmuxControl()
        _ = try awaitMain { try await tmux.newSession(name: sessionName, cwd: "/tmp/lazy", innerCommand: nil) }
        let liveTarget = try awaitMain { try await tmux.newWindow(inSession: sessionName, cwd: "/tmp/lazy", innerCommand: nil) }
        let deadTarget = try awaitMain { try await tmux.newWindow(inSession: sessionName, cwd: "/tmp/dead", innerCommand: nil) }
        try awaitMain { try await tmux.killWindow(target: deadTarget) }

        let liveTile = UUID(uuidString: "00000000-0000-0000-0000-0000000024A1")!
        let inactiveTile = UUID(uuidString: "00000000-0000-0000-0000-0000000024A2")!
        let noCursorTile = UUID(uuidString: "00000000-0000-0000-0000-0000000024A3")!
        let resumeTile = UUID(uuidString: "00000000-0000-0000-0000-0000000024A4")!
        let nilPayloadTile = UUID(uuidString: "00000000-0000-0000-0000-0000000024A5")!
        let absentTile = UUID(uuidString: "00000000-0000-0000-0000-0000000024A6")!
        let oldDate = Date(timeIntervalSince1970: 1_700_000_000)
        let cursor = Data("cursor-24".utf8)

        try writeRecord(controller, tileId: liveTile, target: liveTarget, cwd: "/tmp/lazy", cursor: cursor, lastSeenAt: oldDate)
        try writeRecord(controller, tileId: inactiveTile, target: deadTarget, cwd: "/tmp/dead", cursor: cursor, lastSeenAt: oldDate)
        try writeRecord(controller, tileId: noCursorTile, target: deadTarget, cwd: "/tmp/dead", cursor: nil, lastSeenAt: oldDate)
        try writeRecord(controller, tileId: resumeTile, target: deadTarget, cwd: "/tmp/resume", cursor: cursor, lastSeenAt: oldDate)
        try writeRecord(controller, tileId: nilPayloadTile, target: nil, cwd: nil, cursor: nil, lastSeenAt: oldDate)

        let liveOutcome = try awaitMain {
            try await controller.routableSession(forTile: liveTile, allowRecovery: true, tmux: tmux)
        }
        try expect(liveOutcome == .live(LiveSession(tileId: liveTile, windowTarget: liveTarget, resumeCursor: cursor)), "live target should be adopted without creating a new window")
        let liveRecord = try controller.managedSessionStore.load(tileId: liveTile)
        try expect((liveRecord?.lastSeenAt ?? oldDate) > oldDate, "adopt-existing bumps lastSeenAt")

        let inactiveOutcome = try awaitMain {
            try await controller.routableSession(forTile: inactiveTile, allowRecovery: false, tmux: tmux)
        }
        try expect(inactiveOutcome == .inactive, "dead target with allowRecovery=false should return inactive")

        do {
            _ = try awaitMain {
                try await controller.routableSession(forTile: noCursorTile, allowRecovery: true, tmux: tmux)
            }
            throw CheckError.failed("dead target with no cursor should throw noResumeState")
        } catch SessionError.noResumeState {
        }

        do {
            _ = try awaitMain {
                try await controller.routableSession(forTile: absentTile, allowRecovery: true, tmux: tmux)
            }
            throw CheckError.failed("absent record should throw noBinding")
        } catch SessionError.noBinding {
        }

        do {
            _ = try awaitMain {
                try await controller.routableSession(forTile: nilPayloadTile, allowRecovery: true, tmux: tmux)
            }
            throw CheckError.failed("nil runtime payload with no cursor should throw noResumeState")
        } catch SessionError.noResumeState {
        }

        let resumeOutcome = try awaitMain {
            try await controller.routableSession(forTile: resumeTile, allowRecovery: true, tmux: tmux)
        }
        guard case let .live(resumed) = resumeOutcome else {
            throw CheckError.failed("dead target with cursor should resume to a live session")
        }
        try expect(resumed.tileId == resumeTile, "resume returns the original tile id")
        try expect(resumed.resumeCursor == cursor, "resume preserves opaque cursor")
        try expect(resumed.windowTarget != deadTarget && TmuxSession.isValidPaneId(resumed.windowTarget), "resume stores a fresh valid pane target")
        let resumedRecord = try controller.managedSessionStore.load(tileId: resumeTile)
        try expect(resumedRecord?.tmuxWindowTarget() == resumed.windowTarget, "resume persists the fresh window target")
        let resumedFields = try JSONCodec.makeDecoder().decode(
            ManagedAgentSessionRecord.RuntimePayloadFields.self,
            from: resumedRecord?.runtimePayload ?? Data()
        )
        try expect(resumedFields.cwd == "/tmp/resume", "resume preserves cwd from runtime payload")

        let focusVerdicts: [FocusRequest: Bool] = [
            .userClick: true,
            .appActivated: true,
            .tileSpawned: false,
            .tileClosed: false,
            .runtimeExited: false,
            .modalOpened: false,
            .modalDismissed: false,
            .recovery: false
        ]
        for (reason, expected) in focusVerdicts {
            try expect(ZoneRuntimeController.shouldAttemptLazyRecovery(for: reason) == expected, "focus reason \(reason.rawValue) lazy-resume verdict mismatch")
        }
        let postedErrors = ZoneRuntimeControllerNotificationCheckBox()
        let observer = NotificationCenter.default.addObserver(
            forName: .continuumManagedSessionRecoveryError,
            object: controller,
            queue: nil
        ) { notification in
            guard let tileId = notification.userInfo?["tileId"] as? UUID,
                  let error = notification.userInfo?["error"]
            else { return }
            postedErrors.values.append((tileId, String(describing: error)))
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        try awaitMain {
            await controller.recoverManagedSessionOnFocus(tileId: absentTile, reason: .userClick, tmux: tmux)
        }
        try expect(postedErrors.values.isEmpty, "focus recovery should keep noBinding silent")

        let logCountBeforeSkippedReason = tmux.log.count
        try awaitMain {
            await controller.recoverManagedSessionOnFocus(tileId: noCursorTile, reason: .tileClosed, tmux: tmux)
        }
        try expect(tmux.log.count == logCountBeforeSkippedReason, "non-user focus reasons should not query tmux")
        try expect(postedErrors.values.isEmpty, "skipped focus reasons should not surface errors")

        try awaitMain {
            await controller.recoverManagedSessionOnFocus(tileId: noCursorTile, reason: .userClick, tmux: tmux)
        }
        try expect(postedErrors.values.contains { $0.0 == noCursorTile && $0.1.contains("no resume state") }, "focus recovery should surface noResumeState for the tile")

        // Ticket 24 (double-resume race): two focus events landing close together on the
        // SAME tile (e.g. `.appActivated` on relaunch immediately followed by a `.userClick`
        // restoring prior focus) must not both reach `recoverRecord` — that would create two
        // real tmux windows for one tile. Fire two overlapping recovery calls concurrently for
        // a tile with a dead target + a resume cursor (recoverable) and assert exactly one
        // `tmux.newWindow` call results.
        let concurrentTile = UUID(uuidString: "00000000-0000-0000-0000-0000000024A7")!
        try writeRecord(controller, tileId: concurrentTile, target: deadTarget, cwd: "/tmp/concurrent", cursor: cursor, lastSeenAt: oldDate)
        func newWindowCallCount() -> Int {
            tmux.log.filter { if case .newWindow = $0 { return true } else { return false } }.count
        }
        let newWindowCountBeforeConcurrent = newWindowCallCount()
        _ = try awaitMain {
            async let firstRecovery: Void = controller.recoverManagedSessionOnFocus(tileId: concurrentTile, reason: .userClick, tmux: tmux)
            async let secondRecovery: Void = controller.recoverManagedSessionOnFocus(tileId: concurrentTile, reason: .userClick, tmux: tmux)
            _ = await (firstRecovery, secondRecovery)
            return true
        }
        let concurrentNewWindowDelta = newWindowCallCount() - newWindowCountBeforeConcurrent
        try expect(concurrentNewWindowDelta == 1, "two overlapping recover calls for one tile must create exactly one tmux window")
        let concurrentRecord = try controller.managedSessionStore.load(tileId: concurrentTile)
        let concurrentRecordTarget = concurrentRecord?.tmuxWindowTarget()
        try expect(concurrentRecordTarget != nil && concurrentRecordTarget != deadTarget, "concurrent recovery persists a fresh window target")
        try expect(controller.inFlightRecoveries.isEmpty, "in-flight recovery guard clears once both concurrent calls complete")

        let manifest: [String: Any] = [
            "check": "zone-lazy-resume",
            "projectSessionName": sessionName,
            "liveTarget": liveTarget,
            "deadTarget": deadTarget,
            "resumedTarget": resumed.windowTarget,
            "adoptedLastSeenAdvanced": (liveRecord?.lastSeenAt ?? oldDate) > oldDate,
            "focusVerdicts": Dictionary(uniqueKeysWithValues: focusVerdicts.map { ($0.key.rawValue, $0.value) }),
            "postedErrors": postedErrors.values.map { ["tileId": $0.0.uuidString, "error": $0.1] },
            "concurrentNewWindowDelta": concurrentNewWindowDelta,
            "concurrentRecordTarget": concurrentRecordTarget ?? "",
            "inFlightRecoveriesAfterConcurrent": controller.inFlightRecoveries.count,
            "tmuxLog": tmux.log.map(String.init(describing:)),
            "tempRoot": tempRoot.path
        ]
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let directory = URL(fileURLWithPath: fileManager.currentDirectoryPath)
            .appendingPathComponent("qa-runs", isDirectory: true)
            .appendingPathComponent(timestamp, isDirectory: true)
            .appendingPathComponent("zone-lazy-resume", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifestURL = directory.appendingPathComponent("manifest.json")
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: manifestURL, options: .atomic)
        return manifestURL
    }

    private static func loadOrCreateProject(in store: any ProjectStoring, projectRoot: URL) throws -> Project {
        if let existing = try store.tryLoadProject() {
            return existing
        }
        let now = Date()
        let project = Project(
            name: projectRoot.lastPathComponent,
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
        try store.saveProject(project)
        return project
    }
}

private final class ZoneRuntimeControllerAsyncCheckBox {
    var result: Result<Any, Error>?
}

private final class ZoneRuntimeControllerNotificationCheckBox: @unchecked Sendable {
    var values: [(UUID, String)] = []
}

extension Notification.Name {
    static let continuumManagedSessionRecoveryError = Notification.Name("continuum.managedSession.recoveryError")
}
