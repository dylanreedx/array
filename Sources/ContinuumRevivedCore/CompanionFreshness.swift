import Foundation

public enum CompanionDesktopPowerHint: String, Codable, Equatable, Sendable {
    case active
    case willSleep
    case waking
    case shuttingDown
    case unknown
}

public enum CompanionTransportAvailability: String, Codable, Equatable, Sendable {
    case available
    case connecting
    case networkUnavailable
    case accountUnavailable
    case transportUnavailable
    case sessionInvalid
}

public enum CompanionOfflineReason: String, Codable, Equatable, Sendable {
    case networkUnavailable
    case accountUnavailable
    case transportUnavailable
    case sessionInvalid
    case desktopSilent
}

public struct CompanionFreshnessPolicy: Equatable, Sendable {
    public var liveWindow: TimeInterval
    public var sleepingWindow: TimeInterval

    public init(liveWindow: TimeInterval = 90, sleepingWindow: TimeInterval = 300) {
        self.liveWindow = liveWindow
        self.sleepingWindow = sleepingWindow
    }
}

public struct CompanionFreshnessMetadata: Codable, Equatable, Sendable {
    public var instanceId: UUID
    public var desktopReplicaId: String
    public var bootId: String
    public var sequence: Int64
    public var publishedAt: Date
    public var receivedAt: Date
    public var powerHint: CompanionDesktopPowerHint
    public var spatialWatermark: String?
    public var activityWatermark: String?

    public init(
        instanceId: UUID,
        desktopReplicaId: String,
        bootId: String,
        sequence: Int64,
        publishedAt: Date,
        receivedAt: Date,
        powerHint: CompanionDesktopPowerHint,
        spatialWatermark: String?,
        activityWatermark: String?
    ) {
        self.instanceId = instanceId
        self.desktopReplicaId = desktopReplicaId
        self.bootId = bootId
        self.sequence = sequence
        self.publishedAt = publishedAt
        self.receivedAt = receivedAt
        self.powerHint = powerHint
        self.spatialWatermark = spatialWatermark
        self.activityWatermark = activityWatermark
    }
}

public struct CompanionFreshnessSample: Codable, Equatable, Sendable {
    public var metadata: CompanionFreshnessMetadata

    public init(metadata: CompanionFreshnessMetadata) {
        self.metadata = metadata
    }
}

public struct CompanionFreshnessInput: Equatable, Sendable {
    public var sessionState: PairedCompanionSessionState
    public var spatialSnapshot: CompanionFreshnessSample?
    public var activitySnapshot: CompanionFreshnessSample?
    public var latestHeartbeat: CompanionFreshnessSample?
    public var transportAvailability: CompanionTransportAvailability
    public var now: Date

    public init(
        sessionState: PairedCompanionSessionState,
        spatialSnapshot: CompanionFreshnessSample? = nil,
        activitySnapshot: CompanionFreshnessSample? = nil,
        latestHeartbeat: CompanionFreshnessSample? = nil,
        transportAvailability: CompanionTransportAvailability = .connecting,
        now: Date
    ) {
        self.sessionState = sessionState
        self.spatialSnapshot = spatialSnapshot
        self.activitySnapshot = activitySnapshot
        self.latestHeartbeat = latestHeartbeat
        self.transportAvailability = transportAvailability
        self.now = now
    }
}

public enum CompanionFreshnessState: Equatable, Sendable {
    case unpaired
    case syncing
    case live(lastFreshAt: Date)
    case stale(lastFreshAt: Date)
    case desktopSleeping(lastFreshAt: Date)
    case offline(lastFreshAt: Date?, reason: CompanionOfflineReason)
}

public struct CompanionFreshness: Equatable, Sendable {
    public var state: CompanionFreshnessState
    public var title: String
    public var subtitle: String
    public var allowsMutations: Bool
    public var actionBlocker: String?
    public var showsCachedCanvas: Bool
    public var lastFreshAt: Date?
    public var deliveryLag: TimeInterval?

    public static func derive(
        _ input: CompanionFreshnessInput,
        policy: CompanionFreshnessPolicy = CompanionFreshnessPolicy()
    ) -> CompanionFreshness {
        guard case .paired(let session) = input.sessionState else {
            return CompanionFreshness(
                state: .unpaired,
                title: "Pair this phone",
                subtitle: "Connect to your Continuum instance",
                allowsMutations: false,
                actionBlocker: "Pair this phone",
                showsCachedCanvas: false,
                lastFreshAt: nil,
                deliveryLag: nil
            )
        }

        let latest = latestSample(in: input)
        let lastFreshAt = latest?.metadata.publishedAt
        let deliveryLag = latest.map { max(0, $0.metadata.receivedAt.timeIntervalSince($0.metadata.publishedAt)) }
        let hasCachedCanvas = input.spatialSnapshot != nil

        if let reason = offlineReason(for: input.transportAvailability) {
            return CompanionFreshness(
                state: .offline(lastFreshAt: lastFreshAt, reason: reason),
                title: "Offline",
                subtitle: hasCachedCanvas ? "Mac offline/asleep — showing last canvas" : "Waiting for your Mac",
                allowsMutations: false,
                actionBlocker: "Mac offline/asleep",
                showsCachedCanvas: hasCachedCanvas,
                lastFreshAt: lastFreshAt,
                deliveryLag: deliveryLag
            )
        }

        guard let latest else {
            return CompanionFreshness(
                state: .syncing,
                title: "Syncing…",
                subtitle: "Waiting for your Mac",
                allowsMutations: false,
                actionBlocker: "Reconnect to act",
                showsCachedCanvas: false,
                lastFreshAt: nil,
                deliveryLag: nil
            )
        }

        if latest.metadata.powerHint == .willSleep || latest.metadata.powerHint == .shuttingDown {
            return CompanionFreshness(
                state: .desktopSleeping(lastFreshAt: latest.metadata.publishedAt),
                title: "Mac asleep",
                subtitle: hasCachedCanvas ? "Canvas asleep — showing last canvas" : "Waiting for your Mac",
                allowsMutations: false,
                actionBlocker: "Mac offline/asleep",
                showsCachedCanvas: hasCachedCanvas,
                lastFreshAt: latest.metadata.publishedAt,
                deliveryLag: deliveryLag
            )
        }

        let age = input.now.timeIntervalSince(latest.metadata.publishedAt)
        if age <= policy.liveWindow {
            let scopeAllowsMutation = CanvasEditIntent.isEditingPermitted(scope: session.scopes)
            return CompanionFreshness(
                state: .live(lastFreshAt: latest.metadata.publishedAt),
                title: "Live",
                subtitle: "Updated just now",
                allowsMutations: scopeAllowsMutation,
                actionBlocker: scopeAllowsMutation ? nil : "Observer scope",
                showsCachedCanvas: hasCachedCanvas,
                lastFreshAt: latest.metadata.publishedAt,
                deliveryLag: deliveryLag
            )
        }

        if age > policy.sleepingWindow {
            return CompanionFreshness(
                state: .desktopSleeping(lastFreshAt: latest.metadata.publishedAt),
                title: "Mac asleep",
                subtitle: hasCachedCanvas ? "Canvas asleep — showing last canvas" : "Waiting for your Mac",
                allowsMutations: false,
                actionBlocker: "Mac offline/asleep",
                showsCachedCanvas: hasCachedCanvas,
                lastFreshAt: latest.metadata.publishedAt,
                deliveryLag: deliveryLag
            )
        }

        return CompanionFreshness(
            state: .stale(lastFreshAt: latest.metadata.publishedAt),
            title: "Stale",
            subtitle: hasCachedCanvas ? "Showing last canvas" : "Waiting for your Mac",
            allowsMutations: false,
            actionBlocker: "Reconnect to act",
            showsCachedCanvas: hasCachedCanvas,
            lastFreshAt: latest.metadata.publishedAt,
            deliveryLag: deliveryLag
        )
    }

    private static func latestSample(in input: CompanionFreshnessInput) -> CompanionFreshnessSample? {
        [input.latestHeartbeat, input.spatialSnapshot, input.activitySnapshot]
            .compactMap { $0 }
            .max { lhs, rhs in
                if lhs.metadata.publishedAt == rhs.metadata.publishedAt {
                    return lhs.metadata.receivedAt < rhs.metadata.receivedAt
                }
                return lhs.metadata.publishedAt < rhs.metadata.publishedAt
            }
    }

    private static func offlineReason(for availability: CompanionTransportAvailability) -> CompanionOfflineReason? {
        switch availability {
        case .available, .connecting:
            return nil
        case .networkUnavailable:
            return .networkUnavailable
        case .accountUnavailable:
            return .accountUnavailable
        case .transportUnavailable:
            return .transportUnavailable
        case .sessionInvalid:
            return .sessionInvalid
        }
    }
}

public protocol CompanionLifecycleHintPublishing: Sendable {
    func publishHeartbeat(_ metadata: CompanionFreshnessMetadata) async throws
    func publishPowerHint(_ hint: CompanionDesktopPowerHint, metadata: CompanionFreshnessMetadata) async throws
}
