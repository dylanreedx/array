import Foundation

public struct AgentStatusEngine: Equatable, Sendable {
    public enum Signal: Equatable, Sendable {
        case explicit(AgentStatus)
        case terminalTitle(String)
        case outputActivity
        case promptObserved
    }

    public struct Configuration: Equatable, Sendable {
        public var workingHysteresis: TimeInterval
        public var staleTimeout: TimeInterval

        public init(workingHysteresis: TimeInterval = 5, staleTimeout: TimeInterval = 300) {
            self.workingHysteresis = workingHysteresis
            self.staleTimeout = staleTimeout
        }
    }

    public private(set) var status: AgentStatus
    public private(set) var statusUpdatedAt: Date
    private var explicitStatus: AgentStatus?
    private var explicitUpdatedAt: Date?
    private var inferredStatus: AgentStatus?
    private var inferredUpdatedAt: Date?
    private var lastSignalAt: Date
    private let configuration: Configuration

    public init(initialStatus: AgentStatus = .configuring, now: Date = Date(), configuration: Configuration = Configuration()) {
        self.status = initialStatus
        self.statusUpdatedAt = now
        self.lastSignalAt = now
        self.configuration = configuration
    }

    public mutating func ingest(_ signal: Signal, at now: Date = Date()) -> AgentStatus {
        switch signal {
        case .explicit(let explicit):
            lastSignalAt = now
            explicitStatus = explicit
            explicitUpdatedAt = now
        case .terminalTitle(let title):
            if let titleStatus = Self.statusInferred(fromTitle: title) {
                lastSignalAt = now
                inferredStatus = titleStatus
                inferredUpdatedAt = now
            }
        case .outputActivity:
            lastSignalAt = now
            if explicitStatus == nil {
                inferredStatus = .working
                inferredUpdatedAt = now
            }
        case .promptObserved:
            lastSignalAt = now
            if explicitStatus == nil {
                inferredStatus = .idle
                inferredUpdatedAt = now
            }
        }
        recompute(at: now)
        return status
    }

    public mutating func tick(at now: Date = Date()) -> AgentStatus {
        recompute(at: now)
        return status
    }

    private mutating func recompute(at now: Date) {
        let next: AgentStatus
        if let explicitStatus {
            next = explicitStatus
        } else if now.timeIntervalSince(lastSignalAt) >= configuration.staleTimeout {
            next = .stale
        } else if let inferredStatus {
            if status == .working,
               inferredStatus == .idle,
               let inferredUpdatedAt,
               now.timeIntervalSince(inferredUpdatedAt) < configuration.workingHysteresis {
                next = .working
            } else {
                next = inferredStatus
            }
        } else {
            next = status
        }

        if next != status {
            status = next
            statusUpdatedAt = now
        }
    }

    public static func statusInferred(fromTitle title: String) -> AgentStatus? {
        let lowercased = title.lowercased()
        if lowercased.contains("needs attention") || lowercased.contains("waiting for input") || lowercased.contains("needs you") {
            return .needsAttention
        }
        if lowercased.contains("done") || lowercased.contains("complete") || lowercased.contains("completed") {
            return .done
        }
        if lowercased.contains("working") || lowercased.contains("running") || lowercased.contains("thinking") {
            return .working
        }
        if lowercased.contains("idle") || lowercased.contains("ready") {
            return .idle
        }
        return nil
    }
}
