import Foundation
import ContinuumRevivedCollaborationClient
import ContinuumRevivedCollaborationProtocol

public protocol SharedAreaHostHeartbeatTransport: Sendable {
    func heartbeat(host: SharedArea.ID<SharedArea.Host>, _ beat: Collaboration.HostHeartbeat) async throws -> Collaboration.HostLiveness
    func endHost(host: SharedArea.ID<SharedArea.Host>, generation: UUID) async throws
}

extension SharedAgentHandoffAPI: SharedAreaHostHeartbeatTransport {
    public func heartbeat(host: SharedArea.ID<SharedArea.Host>, _ beat: Collaboration.HostHeartbeat) async throws -> Collaboration.HostLiveness {
        try await api.hostHeartbeat(area: area, host: host, beat: beat)
    }
    public func endHost(host: SharedArea.ID<SharedArea.Host>, generation: UUID) async throws {
        try await api.endHost(area: area, host: host, generation: generation)
    }
}

/// Proves to the relay that this app is still the execution host for its
/// published agents in one area. Each `track(host:)` of a new host starts a new
/// run generation; the relay fences the run it replaced. A refused (superseded or
/// ended) run stops beating rather than minting a replacement, so two hosting
/// runs can never take turns claiming the same host.
@MainActor
public final class SharedAreaHostHeartbeat {
    public enum Phase: Equatable, Sendable { case idle, beating, superseded, ended }
    public typealias Sleep = @Sendable (TimeInterval) async throws -> Void

    private let transport: any SharedAreaHostHeartbeatTransport
    private let sleep: Sleep
    private var task: Task<Void, Never>?
    public private(set) var phase: Phase = .idle
    public private(set) var host: SharedArea.ID<SharedArea.Host>?
    public private(set) var generation: UUID?
    public private(set) var sequence: UInt64 = 0
    public private(set) var lastLiveness: Collaboration.HostLiveness?
    public private(set) var lastError: (any Error)?

    public init(transport: any SharedAreaHostHeartbeatTransport,
                sleep: @escaping Sleep = { try await Task.sleep(for: .seconds($0)) }) {
        self.transport = transport; self.sleep = sleep
    }

    /// Follow the host this app currently publishes from; nil ends the run.
    public func track(host next: SharedArea.ID<SharedArea.Host>?) {
        guard next != host || phase == .idle || phase == .ended else { return }
        if host != nil { end() }
        guard let next else { return }
        host = next; generation = UUID(); sequence = 0; phase = .beating; lastLiveness = nil; lastError = nil
        let run = generation
        task = Task { [weak self] in
            while let self, self.generation == run, self.phase == .beating, !Task.isCancelled {
                await self.beatOnce()
                do { try await self.sleep(Collaboration.HostLivenessPolicy.heartbeatInterval) } catch { return }
            }
        }
    }

    /// One beat of the current run. Network failure keeps the run: the relay
    /// shows it stale and then offline on its own clock. A 409 retires it.
    public func beatOnce() async {
        guard phase == .beating, let host, let run = generation else { return }
        sequence += 1
        do {
            let value = try await transport.heartbeat(host: host, .init(generation: run, sequence: sequence))
            guard generation == run else { return }
            lastLiveness = value; lastError = nil
        } catch {
            guard generation == run else { return }
            lastError = error
            if case CollaborationClientError.server(let status, _) = error, status == 409 || status == 403 || status == 404 {
                phase = .superseded; task?.cancel(); task = nil
            }
        }
    }

    /// Explicit clean shutdown: the relay shows `offline/ended` immediately
    /// instead of waiting out `offlineAfter`. Best effort; expiry covers loss.
    public func end() {
        task?.cancel(); task = nil
        guard let host, let run = generation else { phase = .idle; return }
        let wasBeating = phase == .beating
        phase = .ended; self.host = nil; generation = nil
        guard wasBeating else { return }
        let transport = self.transport
        Task { try? await transport.endHost(host: host, generation: run) }
    }
}

/// The words a teammate reads on a published agent card. Every state names
/// what is known; stale never claims the agent stopped, offline never claims
/// it is still running.
public enum SharedAreaHostLivenessCopy {
    public static func cardLine(_ liveness: Collaboration.HostLiveness?) -> String {
        guard let liveness else { return "Host has not checked in." }
        switch liveness.state {
        case .online: return "Host online."
        case .stale: return "Host not responding. Its agents may still be running."
        case .offline:
            switch liveness.reason {
            case .ended: return "Host offline. Its owner closed the shared workspace."
            case .accessRemoved: return "Host offline. It no longer has access."
            case .expired, nil: return "Host offline. Execution is unavailable."
            }
        }
    }
    /// Shown before "Send now" when the executing host is not online. Nil when
    /// it is online. Queueing stays available: the host takes queued prompts
    /// when it returns.
    public static func sendNowWarning(_ liveness: Collaboration.HostLiveness?) -> String? {
        guard liveness?.state != .online else { return nil }
        let lead: String
        switch liveness?.state {
        case .stale: lead = "The agent's host is not responding."
        case .offline: lead = "The agent's host is offline."
        default: lead = "The agent's host has not checked in."
        }
        return lead + " Send now may not reach the agent until it returns. Queue for next turn waits for the host."
    }
    public static func liveness(for item: SharedArea.Item, in hosts: [Collaboration.HostLiveness]) -> Collaboration.HostLiveness? {
        guard let host = item.source?.host else { return nil }
        return hosts.first { $0.host == host }
    }
}
