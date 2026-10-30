import Foundation
import ContinuumRevivedCollaborationClient
import ContinuumRevivedCollaborationProtocol

public protocol SharedAgentHandoffTransport: Sendable {
    func state() async throws -> Collaboration.State
    func register(_ request: Collaboration.AgentHostRegistration) async throws -> Collaboration.AgentControlState
    func control(object: UUID) async throws -> Collaboration.AgentControlState
    func change(object: UUID, request: Collaboration.AgentControlMutation) async throws -> Collaboration.AgentControlState
    func send(object: UUID, request: Collaboration.AgentPromptRequest) async throws -> Collaboration.AgentDispatchReceipt
    func receipt(id: UUID) async throws -> Collaboration.AgentDispatchReceipt
    func pending(host: UUID) async throws -> [Collaboration.AgentDispatchReceipt]
    func claim(id: UUID, request: Collaboration.AgentHostClaim) async throws -> Collaboration.AgentDispatchReceipt
    func admit(id: UUID, request: Collaboration.AgentHostClaim) async throws -> Collaboration.AgentDispatchReceipt
    func finish(id: UUID, outcome: Collaboration.AgentHostOutcome) async throws -> Collaboration.AgentDispatchReceipt
}
public struct SharedAgentHandoffAPI: SharedAgentHandoffTransport {
    public let api: CollaborationAPI
    public let area: UUID
    public init(api: CollaborationAPI, area: UUID) { self.api = api; self.area = area }
    public func state() async throws -> Collaboration.State { try await api.state(area: area) }
    public func register(_ request: Collaboration.AgentHostRegistration) async throws -> Collaboration.AgentControlState { try await api.registerAgentHost(area: area, request: request) }
    public func control(object: UUID) async throws -> Collaboration.AgentControlState { try await api.agentControl(area: area, object: object) }
    public func change(object: UUID, request: Collaboration.AgentControlMutation) async throws -> Collaboration.AgentControlState { try await api.changeAgentControl(area: area, object: object, request: request) }
    public func send(object: UUID, request: Collaboration.AgentPromptRequest) async throws -> Collaboration.AgentDispatchReceipt { try await api.sendAgentPrompt(area: area, object: object, request: request) }
    public func receipt(id: UUID) async throws -> Collaboration.AgentDispatchReceipt { try await api.agentDispatchReceipt(area: area, id: id) }
    public func pending(host: UUID) async throws -> [Collaboration.AgentDispatchReceipt] { try await api.pendingAgentDispatches(area: area, host: host) }
    public func claim(id: UUID, request: Collaboration.AgentHostClaim) async throws -> Collaboration.AgentDispatchReceipt { try await api.claimAgentDispatch(area: area, id: id, claim: request) }
    public func admit(id: UUID, request: Collaboration.AgentHostClaim) async throws -> Collaboration.AgentDispatchReceipt { try await api.admitAgentDispatch(area: area, id: id, claim: request) }
    public func finish(id: UUID, outcome: Collaboration.AgentHostOutcome) async throws -> Collaboration.AgentDispatchReceipt { try await api.finishAgentDispatch(area: area, id: id, outcome: outcome) }
}

@MainActor
public final class SharedAgentHostDispatcher {
    public typealias Execute = @MainActor (SharedAreaLocalSourceBinding, Collaboration.AgentDispatchCommand) async -> IntentAcceptance
    private let identity: Collaboration.Identity
    private let transport: any SharedAgentHandoffTransport
    private let journal: SharedAgentHostJournal
    private let execute: Execute
    private let bootID: UUID
    private static let processBootID = UUID()
    private var isPolling = false
    private var registrations: [SharedArea.ID<SharedArea.Object>: (binding: SharedAreaLocalSourceBinding, epoch: Int64)] = [:]
    public private(set) var lastError: (any Error)?
    public private(set) var lastReceipts: [Collaboration.AgentDispatchReceipt] = []

    public init(identity: Collaboration.Identity, transport: any SharedAgentHandoffTransport, journal: SharedAgentHostJournal,
                bootID: UUID? = nil, execute: @escaping Execute) {
        self.identity = identity; self.transport = transport; self.journal = journal; self.bootID = bootID ?? Self.processBootID; self.execute = execute
    }

    /// Only the original owning app supplies real local bindings and an actual
    /// supervisor adapter. A recipient's empty list creates no execution path.
    public func pollOnce(bindings: [SharedAreaLocalSourceBinding]) async {
        guard !isPolling, !bindings.isEmpty else { return }
        isPolling = true; defer { isPolling = false }
        do {
            let current = try await transport.state()
            var admitted: [SharedAreaLocalSourceBinding] = []
            for binding in bindings {
                guard binding.agentID != nil,
                      let source = current.document.items.first(where: { $0.id == binding.object && $0.kind == .agentObservation })?.source,
                      source.owner == identity.person, source.host == binding.host, source.binding == binding.binding else { continue }
                if registrations[binding.object]?.binding != binding || registrations[binding.object]?.epoch != current.scope.epoch {
                    let generation = try journal.generation(for: binding)
                    _ = try await transport.register(.init(epoch: current.scope.epoch, object: binding.object, generation: generation))
                    registrations[binding.object] = (binding, current.scope.epoch)
                }
                admitted.append(binding)
            }
            // One command the authority refuses (a stale generation, a revoked
            // requester) must not hold every later command behind it.
            var failure: (any Error)?
            for host in Set(admitted.map(\.host)) {
                for receipt in try await transport.pending(host: host.rawValue) {
                    guard let binding = admitted.first(where: { $0.object == receipt.command.object && $0.host == receipt.command.source.host && $0.binding == receipt.command.source.binding }) else { continue }
                    try Task.checkCancellation()
                    do {
                        if let result = try await dispatch(receipt, binding: binding) {
                            lastReceipts.removeAll { $0.command.id == result.command.id }; lastReceipts.append(result)
                        }
                    } catch is CancellationError { throw CancellationError() }
                    catch { failure = error }
                }
            }
            lastError = failure
        } catch { lastError = error }
    }

    private func dispatch(_ receipt: Collaboration.AgentDispatchReceipt, binding: SharedAreaLocalSourceBinding) async throws -> Collaboration.AgentDispatchReceipt? {
        let command = receipt.command, attempt = try journal.prepare(command)
        let claim = Collaboration.AgentHostClaim(claimID: attempt.claimID, hostGeneration: command.hostGeneration)
        switch attempt.phase {
        case .accepted, .refused, .uncertain:
            let phase: Collaboration.AgentDispatchPhase = attempt.phase == .accepted ? .accepted : attempt.phase == .refused ? .refused : .uncertain
            return try await transport.finish(id: command.id, outcome: .init(claim: claim, phase: phase))
        case .attempting:
            // Another window in this process may still be inside accept. It
            // retains ownership; a replacement process can only report unknown.
            guard attempt.bootID != bootID else { return nil }
            try journal.finish(attempt, phase: .uncertain)
            return try await transport.finish(id: command.id, outcome: .init(claim: claim, phase: .uncertain))
        case .prepared: break
        }
        let claimed = try await transport.claim(id: command.id, request: claim)
        if claimed.phase.isFinal { return claimed }
        guard claimed.phase == .claimed, claimed.command == command, claimed.claimID == claim.claimID else {
            throw SharedAgentHostJournalError.invalidState
        }
        guard try journal.beginAttempt(attempt, bootID: bootID) else { return nil }
        var executing = false
        do {
            let admission = try await transport.admit(id: command.id, request: claim)
            guard admission.phase == .dispatching, admission.command == command, admission.claimID == claim.claimID else {
                throw SharedAgentHostJournalError.invalidState
            }
            try Task.checkCancellation()
            // No task hop or filesystem work is inserted between the fresh
            // authority response and the actual checked supervisor intent.
            executing = true
            let accepted = await execute(binding, command)
            let phase: Collaboration.AgentDispatchPhase = accepted == .accepted ? .accepted : .refused
            try journal.finish(attempt, phase: accepted == .accepted ? .accepted : .refused)
            return try await transport.finish(id: command.id, outcome: .init(claim: claim, phase: phase))
        } catch {
            // The irreversible marker precedes both admission and the provider
            // call. A lost response cannot license another attempt after boot.
            // In this process the provider call is known not to have started
            // when admission failed (membership or generation changed, or a lost
            // reply): nothing was sent, so the honest outcome is a refusal.
            if let saved = try journal.attempts().first(where: { $0.id == command.id }), saved.phase == .attempting {
                let phase: SharedAgentHostJournal.Phase = executing ? .uncertain : .refused
                try journal.finish(attempt, phase: phase)
                _ = try? await transport.finish(id: command.id, outcome: .init(claim: claim, phase: executing ? .uncertain : .refused))
            }
            throw error
        }
    }
}
