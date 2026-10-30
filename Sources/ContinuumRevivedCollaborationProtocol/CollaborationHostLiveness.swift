import Foundation

extension Collaboration {
    /// Execution-host liveness is not cursor presence. A pointer expires after
    /// `presenceLifetime` (15 s) because a person stopped moving or closed a view;
    /// a host goes stale and then offline only when the machine that runs the
    /// published agents stops proving it is alive. Neither implies the other.
    public enum HostLivenessPolicy {
        public static let heartbeatInterval: TimeInterval = 10
        public static let staleAfter: TimeInterval = 30
        public static let offlineAfter: TimeInterval = 90
        /// Retired run generations remembered per area host, newest first.
        public static let retiredGenerationLimit = 16
    }

    /// One heartbeat from one hosting run. `generation` is minted when the host
    /// session starts and never reused, so a restarted app supersedes the run it
    /// replaced and a late packet from the retired run is refused. `sequence`
    /// orders beats within one run. This is unrelated to the persisted logical
    /// binding generation that agent control CAS uses.
    public struct HostHeartbeat: Codable, Sendable, Equatable {
        public let generation: UUID
        public let sequence: UInt64
        public init(generation: UUID, sequence: UInt64) { self.generation = generation; self.sequence = sequence }
        public var valid: Bool { sequence > 0 && sequence <= UInt64(Int64.max) }
    }

    public enum HostLivenessState: String, Codable, Sendable, Equatable {
        /// A beat from the current run arrived within `staleAfter`.
        case online
        /// No beat for `staleAfter`; execution may still be running but cannot be confirmed.
        case stale
        /// No beat for `offlineAfter`, an explicit end, or the host lost its access.
        case offline
    }

    public enum HostOfflineReason: String, Codable, Sendable, Equatable {
        case expired, ended, accessRemoved
    }

    public struct HostLiveness: Codable, Sendable, Equatable {
        public let host: SharedArea.ID<SharedArea.Host>
        public let generation: UUID
        public let state: HostLivenessState
        public let lastSeen: Date
        public let staleAt: Date
        public let offlineAt: Date
        public let reason: HostOfflineReason?
        public init(host: SharedArea.ID<SharedArea.Host>, generation: UUID, state: HostLivenessState, lastSeen: Date,
                    staleAt: Date, offlineAt: Date, reason: HostOfflineReason?) {
            self.host = host; self.generation = generation; self.state = state; self.lastSeen = lastSeen
            self.staleAt = staleAt; self.offlineAt = offlineAt; self.reason = reason
        }

        /// The one evaluation both the service and its checks use.
        public static func evaluate(host: SharedArea.ID<SharedArea.Host>, generation: UUID, lastSeen: Date,
                                    ended: Bool, accessRemoved: Bool, now: Date) -> HostLiveness {
            let staleAt = lastSeen.addingTimeInterval(HostLivenessPolicy.staleAfter)
            let offlineAt = lastSeen.addingTimeInterval(HostLivenessPolicy.offlineAfter)
            let state: HostLivenessState, reason: HostOfflineReason?
            if accessRemoved { (state, reason) = (.offline, .accessRemoved) }
            else if ended { (state, reason) = (.offline, .ended) }
            else if now >= offlineAt { (state, reason) = (.offline, .expired) }
            else if now >= staleAt { (state, reason) = (.stale, nil) }
            else { (state, reason) = (.online, nil) }
            return .init(host: host, generation: generation, state: state, lastSeen: lastSeen,
                staleAt: staleAt, offlineAt: offlineAt, reason: reason)
        }

        /// The next instant this projection changes on its own, if any.
        public func nextTransition(after now: Date) -> Date? {
            guard reason == nil else { return nil }
            return [staleAt, offlineAt].filter { $0 > now }.min()
        }
    }
}
