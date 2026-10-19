import ContinuumRevivedCore
import Foundation

extension WorkspaceAPIService {
    /// Record mutation only: never opens, hydrates, navigates or touches a runner.
    func updateAgent(
        agentId: AgentID, record: AgentRecord, ownHandle: CheckoutHandle, requestId: String,
        payload: [String: Any], runtime: WorkspaceRuntime, canvas: CanvasNSView,
        isCancelled: () -> Bool
    ) -> Reply {
        let request: AgentUpdateRequest
        do {
            request = try JSONDecoder().decode(AgentUpdateRequest.self,
                from: JSONSerialization.data(withJSONObject: payload))
        } catch {
            return .error(WorkspaceAPIError(code: .invalidRequest, message: "agentId and an explicit identityColor (palette name or null) are required."))
        }
        if let color = request.identityColor, !ZoneColorConfig.palette.contains(color) {
            return .error(WorkspaceAPIError(code: .invalidRequest, message: "identityColor must be a palette name or null. Allowed: \(ZoneColorConfig.palette.joined(separator: ", "))."))
        }
        let key = request.idempotencyKey ?? requestId
        var normalized = request
        normalized.idempotencyKey = nil
        guard let encoded = try? Self.encoder.encode(normalized) else {
            return .error(WorkspaceAPIError(code: .invalidRequest, message: "The update could not be encoded."))
        }
        let hash = String(decoding: encoded, as: UTF8.self)
        if let cached = agentUpdateIdempotency[agentId]?[key] {
            guard cached.payloadHash == hash else {
                return .error(WorkspaceAPIError(code: .idempotencyConflict, message: "This idempotencyKey was already used with a different request."))
            }
            return .result(Self.jsonObject(cached.result)!)
        }

        let isSelf = request.agentId == agentId
        // Resolve scope before an approval prompt or any target metadata can leak.
        func targetInScope() -> AgentRecord? {
            guard let target = supervisor.records[request.agentId] else { return nil }
            if isSelf { return target }
            // As in canvas.apply, legacy project stamps resolve through the
            // explicitly bound checkout, never the active project/controller.
            let knownProject = knownCheckouts()[ownHandle]?.projectId
            guard let ownProject = record.projectId ?? knownProject,
                  (target.projectId ?? knownProject) == ownProject,
                  Self.ownCheckoutHandle(target) == ownHandle else { return nil }
            if let tile = target.tileId,
               canvas.installedZoneIds(containing: tile).contains(where: { canvas.projectId(forZone: $0) != ownProject }) {
                return nil
            }
            return target
        }
        guard targetInScope() != nil else {
            return .error(WorkspaceAPIError(code: .permissionDenied, message: "This agent may not change that agent."))
        }
        let generation = revocationGeneration(for: agentId)
        if !isSelf {
            // The exact canvas-write grant, not an inspect/delegate permission.
            let verdict = WorkspaceToolGrantEvaluator.evaluate(
                agentId: agentId, op: .canvasApply, checkout: ownHandle, requested: .preserveAll,
                grants: grants[agentId] ?? [], currentGeneration: generation)
            if case .allowed = verdict {} else {
                let promptId = UUID().uuidString
                // `targetInScope` proved the target is in this agent's own project.
                let decision = decideScope(ScopeApprovalPrompt(
                    requestId: promptId, agentId: agentId, agentDisplayName: record.displayName,
                    checkout: ownHandle, checkoutDisplayName: knownCheckouts()[ownHandle]?.displayName ?? record.displayName,
                    op: .canvasApply, relativePath: nil),
                    withinCallerProject: true)
                if isCancelled() { return cancelledAgentUpdate(agentId: agentId, requestId: requestId) }
                guard supervisor.records[agentId]?.workspaceToolsEnabled == true,
                      revocationGeneration(for: agentId) == generation else {
                    return .error(WorkspaceAPIError(code: .permissionDenied, message: "Workspace tools were revoked before approval completed."))
                }
                guard decision != .deny else {
                    return .error(WorkspaceAPIError(code: .scopeApprovalRequired, message: "The user has not allowed canvas writes. Nothing was applied.", approvalRequestId: promptId))
                }
                mint(WorkspaceToolGrant(
                    agentId: agentId, checkoutHandles: [ownHandle], operations: [.canvasApply],
                    presentationCeiling: .preserveAll,
                    issuer: decision == .allowOnce ? .userApprovalOnce(requestId: promptId) : Self.sessionIssuer(decision, requestId: promptId),
                    revocationGeneration: generation, singleUse: decision == .allowOnce))
            }
            consumeSingleUseApplyGrant(agentId: agentId, checkout: ownHandle)
        }

        _beforeCommitHook?()
        if isCancelled() { return cancelledAgentUpdate(agentId: agentId, requestId: requestId) }
        guard supervisor.records[agentId]?.workspaceToolsEnabled == true,
              revocationGeneration(for: agentId) == generation,
              let target = targetInScope() else {
            return .error(WorkspaceAPIError(code: .permissionDenied, message: "Access or target scope changed before the update."))
        }
        let durability: AgentUpdateResult.Durability
        if target.identityColor == request.identityColor {
            durability = .unchanged
        } else {
            guard supervisor.setIdentityColor(agentID: request.agentId, request.identityColor) else {
                remember(agentId: agentId, WorkspaceRecentOperation(requestId: requestId, op: .agentUpdate, outcome: "durabilityFailed"))
                return .error(WorkspaceAPIError(code: .outcomeUnknown, message: "durability_failed: the colour could not be saved. Re-query before retrying."))
            }
            durability = .committed
        }
        let result = AgentUpdateResult(
            operationId: requestId, agentId: request.agentId, identityColor: supervisor.records[request.agentId]?.identityColor,
            revision: WorkspaceRevision(epoch: epoch, structure: runtime.structuralRevision), durability: durability)
        remember(agentId: agentId, WorkspaceRecentOperation(requestId: requestId, op: .agentUpdate, outcome: durability.rawValue))
        agentUpdateIdempotency[agentId, default: [:]][key] = CachedAgentUpdate(payloadHash: hash, result: result)
        agentUpdateIdempotencyOrder[agentId, default: []].append(key)
        while (agentUpdateIdempotencyOrder[agentId]?.count ?? 0) > Self.idempotencyCapacity {
            let evicted = agentUpdateIdempotencyOrder[agentId]!.removeFirst()
            agentUpdateIdempotency[agentId]?[evicted] = nil
        }
        return .result(Self.jsonObject(result)!)
    }

    private func cancelledAgentUpdate(agentId: AgentID, requestId: String) -> Reply {
        remember(agentId: agentId, WorkspaceRecentOperation(requestId: requestId, op: .agentUpdate, outcome: "cancelledBeforeEffect"))
        return .cancelled(result: nil)
    }
}
