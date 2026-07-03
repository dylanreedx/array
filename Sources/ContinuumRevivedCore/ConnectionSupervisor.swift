import Foundation

public enum NetworkStatus: String, Codable, Equatable, Sendable {
    case unknown
    case offline
    case online
}

public enum ConnectionPhase: String, Codable, Equatable, Sendable {
    case available
    case offline
    case connecting
    case backoff
    case connected
    case blocked
}

public enum ConnectionUIProjection: String, Codable, Equatable, Sendable {
    case disconnected
    case synchronizing
    case ready
}

public func connectionUIProjection(for phase: ConnectionPhase) -> ConnectionUIProjection {
    switch phase {
    case .available, .offline, .backoff, .blocked:
        return .disconnected
    case .connecting:
        return .synchronizing
    case .connected:
        return .ready
    }
}

public enum ConnectionError: Error, Codable, Equatable, Sendable {
    case openFailed(String)
    case probeFailed(String)
    case probeTimedOut
    case authFailed
    case scopeExceeded
}

public struct ConnectionState: Codable, Equatable, Sendable {
    public var desired: Bool
    public var network: NetworkStatus
    public var phase: ConnectionPhase
    public var attempt: Int
    public var generation: Int?
    public var lastFailure: ConnectionError?
    public var retryAt: Date?

    public init(
        desired: Bool = false,
        network: NetworkStatus = .unknown,
        phase: ConnectionPhase = .available,
        attempt: Int = 0,
        generation: Int? = nil,
        lastFailure: ConnectionError? = nil,
        retryAt: Date? = nil
    ) {
        self.desired = desired
        self.network = network
        self.phase = phase
        self.attempt = attempt
        self.generation = generation
        self.lastFailure = lastFailure
        self.retryAt = retryAt
    }
}

public enum ConnectionSignal: Equatable, Sendable {
    case connectRequested
    case disconnectRequested
    case retryNow
    case networkChanged(NetworkStatus)
    case wakeup
    case socketClosed
}

public struct ConnectionSupervisorSettings: Equatable, Sendable {
    public var retryDelays: [TimeInterval]
    public var establishTimeout: TimeInterval
    public var probeTimeout: TimeInterval
    public var backoffReset: TimeInterval
    public var snapshotDebounce: TimeInterval
    public var grantedScope: Scope

    public init(
        retryDelays: [TimeInterval] = [1, 2, 4, 8, 16],
        establishTimeout: TimeInterval = 15,
        probeTimeout: TimeInterval = 15,
        backoffReset: TimeInterval = 30,
        snapshotDebounce: TimeInterval = 0.5,
        grantedScope: Scope = .observer
    ) {
        self.retryDelays = retryDelays
        self.establishTimeout = establishTimeout
        self.probeTimeout = probeTimeout
        self.backoffReset = backoffReset
        self.snapshotDebounce = snapshotDebounce
        self.grantedScope = grantedScope
    }

    public static let defaults = ConnectionSupervisorSettings()
}

public actor ConnectionSupervisor {
    public private(set) var state: ConnectionState
    public private(set) var session: (any RemoteSession)?

    private let settings: ConnectionSupervisorSettings
    private let driver: any ConnectionDriver
    private let clock: any Clock
    private let sessionStream: AsyncStream<(any RemoteSession)?>
    private let sessionContinuation: AsyncStream<(any RemoteSession)?>.Continuation
    private var failureCount = 0
    private var lastConnectedDuration: TimeInterval = 0

    public init(
        driver: any ConnectionDriver,
        settings: ConnectionSupervisorSettings = .defaults,
        clock: any Clock = SystemClock()
    ) {
        self.driver = driver
        self.settings = settings
        self.clock = clock
        self.state = ConnectionState()
        (sessionStream, sessionContinuation) = AsyncStream<(any RemoteSession)?>.makeStream()
    }

    public var sessions: AsyncStream<(any RemoteSession)?> { sessionStream }

    public func run() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
        } onCancel: {}
    }

    public func send(_ signal: ConnectionSignal) async {
        switch signal {
        case .connectRequested:
            state.desired = true
            await driveIfNeeded(force: true)
        case .disconnectRequested:
            state.desired = false
            clearSession()
            state.phase = .available
            state.retryAt = nil
            state.lastFailure = nil
        case .retryNow, .wakeup:
            await driveIfNeeded(force: true)
        case .networkChanged(let network):
            state.network = network
            await driveIfNeeded(force: true)
        case .socketClosed:
            clearSession()
            if lastConnectedDuration >= settings.backoffReset {
                failureCount = 0
            }
            scheduleBackoff(error: .probeFailed("socket-closed"))
        }
    }

    public func simulateConnectedDurationForChecks(_ duration: TimeInterval) {
        lastConnectedDuration = duration
    }

    private func driveIfNeeded(force: Bool) async {
        guard state.desired else {
            clearSession()
            state.phase = .available
            return
        }
        guard state.network != .offline else {
            clearSession()
            state.phase = .offline
            state.retryAt = nil
            return
        }
        if state.phase == .connected && !force { return }
        if state.phase == .backoff && !force { return }
        await runAttempt()
    }

    private func runAttempt() async {
        state.phase = .connecting
        state.attempt += 1
        state.retryAt = nil
        state.lastFailure = nil

        let socket: any RemoteSocket
        do {
            socket = try await driver.openSocket()
        } catch let error as ConnectionError {
            scheduleBackoff(error: error)
            return
        } catch {
            scheduleBackoff(error: .openFailed(String(describing: error)))
            return
        }

        let probe: ReadinessProbeResult
        do {
            if let fakeDriver = driver as? ProbeResultOverrideDriver,
               let override = try await fakeDriver.consumeProbeResult() {
                probe = override
            } else {
                probe = try await socket.readinessProbe()
            }
        } catch ConnectionError.authFailed {
            await socket.close()
            block(error: .authFailed)
            return
        } catch ConnectionError.scopeExceeded {
            await socket.close()
            block(error: .scopeExceeded)
            return
        } catch ConnectionError.probeTimedOut {
            await socket.close()
            scheduleBackoff(error: .probeTimedOut)
            return
        } catch let error as ConnectionError {
            await socket.close()
            scheduleBackoff(error: error)
            return
        } catch {
            await socket.close()
            scheduleBackoff(error: .probeFailed(String(describing: error)))
            return
        }

        guard probe.negotiatedScope.isSubset(of: settings.grantedScope) else {
            await socket.close()
            block(error: .scopeExceeded)
            return
        }

        let nextGeneration = (state.generation ?? 0) + 1
        let newSession = ConnectionRemoteSession(
            socket: socket,
            readinessProbe: probe,
            scope: probe.negotiatedScope,
            generation: nextGeneration
        )
        session = newSession
        sessionContinuation.yield(newSession)
        state.phase = .connected
        state.generation = nextGeneration
        state.lastFailure = nil
        state.retryAt = nil
        failureCount = 0
        lastConnectedDuration = 0
    }

    private func scheduleBackoff(error: ConnectionError) {
        clearSession()
        failureCount += 1
        let index = min(max(failureCount - 1, 0), settings.retryDelays.count - 1)
        let delay = settings.retryDelays[index]
        state.phase = .backoff
        state.lastFailure = error
        state.retryAt = clock.now().addingTimeInterval(delay)
    }

    private func block(error: ConnectionError) {
        clearSession()
        state.phase = .blocked
        state.lastFailure = error
        state.retryAt = nil
    }

    private func clearSession() {
        if session != nil {
            session = nil
            sessionContinuation.yield(nil)
        }
    }
}

public protocol ProbeResultOverrideDriver: ConnectionDriver {
    func consumeProbeResult() async throws -> ReadinessProbeResult?
}

public enum GenerationRevalidationDecision: Equatable, Sendable {
    case suspend
    case refetch
    case unchanged
}

public struct GenerationRevalidationGate: Sendable {
    private var lastGeneration: Int?

    public init() {}

    public mutating func observe(_ generation: Int?) -> GenerationRevalidationDecision {
        guard let generation else { return .suspend }
        guard generation != lastGeneration else { return .unchanged }
        lastGeneration = generation
        return .refetch
    }
}
