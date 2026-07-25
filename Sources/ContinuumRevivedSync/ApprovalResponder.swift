import ContinuumRevivedCore
import Foundation

public enum ApprovalRespondResult: Sendable, Equatable {
    case resolved
    case stale
    case unknownRequest
}

public protocol ApprovalResponding: Sendable {
    func respond(agentId: UUID, requestId: String, decision: ApprovalDecision) async -> ApprovalRespondResult
}

public actor ApprovalResponder {
    private let seam: any ApprovalResponding
    private let demux: SyncMessageDemux
    private let authorizedScope: Scope
    private let onAck: (@Sendable (ApprovalResponseAck) async -> Void)?
    private var loopTask: Task<Void, Never>?
    private var completedRequestIds: Set<String> = []

    public init(
        seam: any ApprovalResponding,
        demux: SyncMessageDemux,
        authorizedScope: Scope,
        onAck: (@Sendable (ApprovalResponseAck) async -> Void)? = nil
    ) {
        self.seam = seam
        self.demux = demux
        self.authorizedScope = authorizedScope
        self.onAck = onAck
    }

    public func start() async {
        guard loopTask == nil else { return }
        let stream = await demux.subscribe()
        loopTask = Task { [weak self] in
            await self?.handle(stream)
        }
    }

    public func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    private func handle(_ stream: AsyncStream<SyncMessage>) async {
        for await message in stream {
            guard case .approvalResponse(let request) = message else { continue }
            let outcome: ApprovalResponseOutcome
            do {
                try authorize(.respondToApproval, grantedScopes: authorizedScope)
                if completedRequestIds.contains(request.requestId) {
                    outcome = .stale
                } else {
                    switch await seam.respond(agentId: request.agentId, requestId: request.requestId, decision: request.decision) {
                    case .resolved:
                        completedRequestIds.insert(request.requestId)
                        outcome = .resolved
                    case .stale:
                        completedRequestIds.insert(request.requestId)
                        outcome = .stale
                    case .unknownRequest:
                        outcome = .unknownRequest
                    }
                }
            } catch {
                outcome = .unauthorized
            }
            let ack = ApprovalResponseAck(requestId: request.requestId, outcome: outcome)
            await onAck?(ack)
            try? await demux.send(.approvalResponseAck(ack))
        }
    }
}
