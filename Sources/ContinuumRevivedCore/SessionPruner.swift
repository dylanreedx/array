import Foundation

/// Removes all terminal session descriptors that have a non-nil `lastExit`
/// from the given store. Called once at app boot, before the tile loop, so
/// stale descriptors from previous launches do not accumulate in `sessions/`.
///
/// Best-effort: a failure to list or delete a single session writes a warning
/// to stderr and continues rather than propagating. This mirrors the
/// `listSessions` internal skip-on-error behavior.
public func pruneExitedSessions(in store: any ProjectStoring) {
    let sessions: [TerminalSessionDescriptor]
    do {
        sessions = try store.listSessions()
    } catch {
        fputs("pruneExitedSessions: could not list sessions: \(error)\n", stderr)
        return
    }

    for descriptor in sessions where descriptor.lastExit != nil {
        do {
            try store.deleteSession(id: descriptor.id)
        } catch {
            fputs("pruneExitedSessions: could not delete session \(descriptor.id): \(error)\n", stderr)
        }
    }
}

public actor SessionPruner {
    public struct Configuration: Sendable, Equatable {
        public var inactivityThreshold: TimeInterval
        public var sweepInterval: TimeInterval

        public init(
            inactivityThreshold: TimeInterval = IdleReaperConfig.defaultInactivityThreshold,
            sweepInterval: TimeInterval = IdleReaperConfig.defaultSweepInterval
        ) {
            self.inactivityThreshold = inactivityThreshold
            self.sweepInterval = sweepInterval
        }
    }

    public struct SessionBinding: Sendable, Equatable {
        public let sessionName: String
        public let tileIds: [UUID]
        public var lastSeenAt: Date

        public init(sessionName: String, tileIds: [UUID], lastSeenAt: Date) {
            self.sessionName = sessionName
            self.tileIds = tileIds
            self.lastSeenAt = lastSeenAt
        }
    }

    private let tmuxControl: any TmuxControl
    private let clock: any Clock
    public let configuration: Configuration
    private let bindingSource: @Sendable () async -> [SessionBinding]
    private let activitySnapshotSource: @Sendable () async -> ActivityLogSnapshot?
    private var sweepTask: Task<Void, Never>?

    public init(
        tmuxControl: any TmuxControl,
        clock: any Clock,
        configuration: Configuration = .init(),
        bindingSource: @Sendable @escaping () async -> [SessionBinding],
        activitySnapshotSource: @Sendable @escaping () async -> ActivityLogSnapshot?
    ) {
        self.tmuxControl = tmuxControl
        self.clock = clock
        self.configuration = configuration
        self.bindingSource = bindingSource
        self.activitySnapshotSource = activitySnapshotSource
    }

    public func start() {
        guard sweepTask == nil else { return }
        sweepTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.sweep()
                let interval = self.configuration.sweepInterval
                let nanoseconds = UInt64(max(0, interval) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
            }
        }
    }

    public func stop() {
        sweepTask?.cancel()
        sweepTask = nil
    }

    public func sweep() async {
        let now = clock.now()
        let bindings = await bindingSource()

        for binding in bindings {
            guard now.timeIntervalSince(binding.lastSeenAt) >= configuration.inactivityThreshold else {
                continue
            }

            let snapshot = await activitySnapshotSource()
            let hasActiveTurn = binding.tileIds.contains { tileId in
                guard let activity = snapshot?.byTile[tileId] else { return false }
                if activity.status == .working { return true }
                return now.timeIntervalSince(activity.updatedAt) < configuration.inactivityThreshold
            }
            guard !hasActiveTurn else { continue }

            try? await tmuxControl.detachSession(name: binding.sessionName)
        }
    }
}
