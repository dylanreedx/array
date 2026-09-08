import AppKit
import ContinuumRevivedCore
import Foundation

// CX-01 Phase 2b (`.plans/59-parallel-product-investigations/canvas-awareness-api-design.md`, §10).
//
// Visible delegation with safe retry. Three ops, one rule: the child is created
// by the supervisor's EXISTING path — `AgentSupervisor.handleSpawnRequest`, the
// same function the pi `spawn_agent` tool drives — and made visible by the
// EXISTING inbox-reveal route (`TileSpawner.spawnManagedAgentForExistingAgent`
// → `installProjectTile`, then `AppDelegate.wireManagedAgentTile`). Nothing here
// launches a process, creates a worktree, or picks a provider or model of its
// own (§10.1). The operation record is reserved BEFORE creation and every step
// is reported separately (§10.3): a child whose tile could not be presented is a
// success with a repairable step, repaired by `agent.reveal`, never by a second
// `agent.delegate`.
extension WorkspaceAPIService {

    // MARK: - agent.delegate (§10)

    func delegate(
        agentId: AgentID, record: AgentRecord, ownHandle: CheckoutHandle, requestId: String,
        payload: [String: Any], runtime: WorkspaceRuntime, canvas: CanvasNSView,
        isCancelled: () -> Bool
    ) -> Reply {
        // 1. Schema.
        let request: AgentDelegateRequest
        do {
            let data = try JSONSerialization.data(withJSONObject: payload)
            request = try JSONDecoder().decode(AgentDelegateRequest.self, from: data)
        } catch {
            return .error(WorkspaceAPIError(code: .invalidRequest, message: "The delegate request could not be decoded: \(error.localizedDescription)"))
        }
        guard !request.task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .error(WorkspaceAPIError(code: .invalidRequest, message: "task is required."))
        }
        guard let idempotencyKey = request.idempotencyKey?.trimmingCharacters(in: .whitespacesAndNewlines), !idempotencyKey.isEmpty else {
            return .error(WorkspaceAPIError(code: .invalidRequest, message: "idempotencyKey is required for agent.delegate: a spawn without one cannot be retried safely."))
        }
        let generationAtDispatch = runtime.interactionGeneration

        // 2. Reserve the operation BEFORE any effect (§10.2). Same key + same
        //    payload replays; same key + different payload conflicts; an evicted
        //    key is never "safe to repeat".
        let payloadHash = Self.payloadHash(request)
        let reservation = operations.reserve(
            agentId: agentId, op: .agentDelegate, idempotencyKey: idempotencyKey,
            payloadHash: payloadHash, operationId: requestId)
        switch reservation {
        case let .replay(existing):
            if let cached = delegateReplayResults[existing.operationId] { return .result(cached) }
            return .result(Self.jsonObject(Self.replayResult(from: existing, running: existing.childAgentId.map(supervisor.isRunning))) ?? [:])
        case .conflict:
            return .error(WorkspaceAPIError(code: .idempotencyConflict, message: "This idempotencyKey was already used for a different delegation. New intent needs a new key."))
        case let .expired(tombstone):
            let child = tombstone.childAgentId.map { " Its child was \($0.rawValue.uuidString)." } ?? ""
            return .error(WorkspaceAPIError(code: .outcomeUnknown, message: "This idempotencyKey belongs to an expired operation (\(tombstone.operationId)); Array no longer holds its outcome and will not repeat it.\(child) Call operation.get, or use a new key for new intent."))
        case .reserved:
            break
        }
        func fail(_ code: WorkspaceAPIError.Code, _ message: String, approvalRequestId: String? = nil, keep: Bool = false) -> Reply {
            if keep {
                operations.update(operationId: requestId) { op in
                    op.status = .failed
                    op.steps.creation = .failed
                    op.failureCode = code.rawValue
                    op.failureMessage = message
                }
            } else {
                operations.release(operationId: requestId)
            }
            return .error(WorkspaceAPIError(code: code, message: message, approvalRequestId: approvalRequestId))
        }

        // 3. Inheritance only (§10.1): the child runs the parent's harness and
        //    model. An override that differs is refused explicitly, never applied
        //    silently and never downgraded.
        guard let parentHarness = record.harness else {
            return fail(.unsupported, "This agent's harness is unresolved, so a child cannot inherit it.")
        }
        if let provider = request.provider, !Self.namesHarness(provider, parentHarness) {
            return fail(.unsupported, "Array delegates with the parent's own provider (\(parentHarness.rawValue)); a different provider for the child is not supported.")
        }
        if let model = request.model, model != record.model {
            return fail(.unsupported, "Array delegates with the parent's own model (\(record.model)); a per-child model override is not supported.")
        }

        // 4. Grant (§14.1). Delegation is outside the Phase 1 preset: the first
        //    request per agent session goes through the trusted approval UI.
        let effectivePolicy: WorkspacePresentationPolicy
        var approvalRequestId: String?
        switch WorkspaceToolGrantEvaluator.evaluate(
            agentId: agentId, op: .agentDelegate, checkout: ownHandle,
            requested: request.presentationPolicy, grants: grants[agentId] ?? [],
            currentGeneration: revocationGeneration) {
        case let .allowed(_, policy):
            effectivePolicy = policy
        case .denied, .scopeApprovalRequired:
            let promptId = UUID().uuidString
            approvalRequestId = promptId
            approvalPromptCount += 1
            let decision = approvalHandler(ScopeApprovalPrompt(
                requestId: promptId, agentId: agentId, agentDisplayName: record.displayName,
                checkout: ownHandle, checkoutDisplayName: URL(fileURLWithPath: record.checkoutRoot).lastPathComponent,
                op: .agentDelegate, relativePath: nil))
            guard supervisor.records[agentId]?.workspaceToolsEnabled == true else {
                return fail(.permissionDenied, "Workspace tools were disabled for this agent.", approvalRequestId: promptId)
            }
            switch decision {
            case .deny:
                return fail(.permissionDenied, "The user declined to let this agent delegate.", approvalRequestId: promptId)
            case .allowOnce:
                mint(WorkspaceToolGrant(
                    agentId: agentId, checkoutHandles: [ownHandle], operations: [.agentDelegate],
                    presentationCeiling: WorkspaceToolGrant.phase1Ceiling,
                    issuer: .userApprovalOnce(requestId: promptId),
                    revocationGeneration: revocationGeneration, singleUse: true))
            case .allowForSession:
                mint(WorkspaceToolGrant(
                    agentId: agentId, checkoutHandles: [ownHandle], operations: [.agentDelegate],
                    presentationCeiling: WorkspaceToolGrant.phase1Ceiling,
                    issuer: .userApprovalSession(requestId: promptId),
                    revocationGeneration: revocationGeneration))
            }
            guard case let .allowed(_, policy) = WorkspaceToolGrantEvaluator.evaluate(
                agentId: agentId, op: .agentDelegate, checkout: ownHandle,
                requested: request.presentationPolicy, grants: grants[agentId] ?? [],
                currentGeneration: revocationGeneration) else {
                return fail(.permissionDenied, "Approval did not take.", approvalRequestId: promptId)
            }
            effectivePolicy = policy
        }
        consumeSingleUseGrant(agentId: agentId, checkout: ownHandle, op: .agentDelegate)
        let generationAtGrant = revocationGeneration

        // 5. Recheck immediately before the effect; cancellation before it means
        //    nothing happens and the key stays free.
        guard supervisor.records[agentId]?.workspaceToolsEnabled == true, revocationGeneration == generationAtGrant else {
            return fail(.permissionDenied, "Access was revoked before the child was created.", approvalRequestId: approvalRequestId)
        }
        if isCancelled() {
            operations.release(operationId: requestId)
            remember(agentId: agentId, WorkspaceRecentOperation(requestId: requestId, op: .agentDelegate, outcome: "cancelledBeforeEffect"))
            return .cancelled(result: nil)
        }
        _beforeCommitHook?()

        // 6. Creation, through the supervisor's one child-creation path. The
        //    request id doubles as the spawn-result handle, so `wait_agents` can
        //    collect this child exactly like a `spawn_agent` one.
        let spawnRequest = SpawnRequest(
            role: nil, prompt: request.task, isolated: false, sourceItemID: requestId,
            displayLabel: request.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty)
        guard let childId = supervisor.handleSpawnRequest(spawnRequest, from: agentId) else {
            let reason = supervisor.spawnRefusal(for: agentId)?.reason ?? "the supervisor refused the spawn"
            return fail(.unsupported, "Array did not start a child: \(reason).", approvalRequestId: approvalRequestId, keep: true)
        }
        operations.update(operationId: requestId) { op in
            op.steps.creation = .succeeded
            op.childAgentId = childId
        }
        let child = supervisor.records[childId]
        var result = AgentDelegateResult(
            operationId: requestId,
            status: .partial,
            childAgentId: childId,
            parentAgentId: agentId,
            tileId: nil,
            provider: (child?.harness ?? parentHarness).rawValue,
            model: child?.model ?? record.model,
            steps: WorkspaceOperationSteps(creation: .succeeded),
            presentation: .unavailable,
            presentationEffects: .allPreserved,
            actualWorldRect: nil,
            actualZoneId: nil,
            childRunning: supervisor.isRunning(childId),
            partial: false)

        // 7. Attachment: a tile in the PARENT's zone, framed against that zone
        //    (hazard 9), through the existing managed-agent tile route.
        let attachment = attachTile(
            for: childId, parent: record, placement: request.placement, runtime: runtime, canvas: canvas)
        switch attachment {
        case let .attached(tileId, zoneId):
            result.tileId = tileId
            result.actualZoneId = zoneId
            if let snapshot = canvas.navigationTileSnapshot(for: tileId) {
                result.actualWorldRect = CanvasWorldRect(snapshot.worldFrame)
            }
            result.steps.attachment = .succeeded
            // `spawnManagedAgent` persisted the canvas and the managed-session
            // record before returning `.spawned`; `attach` persisted the child's
            // record. Durable state crossed its barrier inside those owners.
            result.steps.durability = .succeeded
        case let .failed(message):
            result.steps.attachment = .failed
            result.steps.durability = .skipped
            result.steps.presentation = .skipped
            result.partial = true
            result.failureMessage = message
        }
        operations.update(operationId: requestId) { op in
            op.steps = result.steps
            op.tileId = result.tileId
            op.failureMessage = result.failureMessage
            op.failureCode = result.partial ? "attachment_failed" : nil
        }

        // 8. Cancellation after creation: report the child truthfully — it keeps
        //    running — and present nothing.
        if isCancelled() {
            result.presentation = .deferred
            result.steps.presentation = .skipped
            result.status = result.partial ? .partial : .committed
            result.childRunning = supervisor.isRunning(childId)
            finish(agentId: agentId, requestId: requestId, result: result, outcome: "committedAfterCancel")
            return .cancelled(result: Self.jsonObject(result))
        }

        // 9. Presentation: only what the policy permits, only while authorized.
        //    A failure here is a repairable step — `agent.reveal(childId)`.
        if let tileId = result.tileId {
            _beforePresentationHook?()
            let stillAllowed = supervisor.records[agentId]?.workspaceToolsEnabled == true
                && revocationGeneration == generationAtGrant
            if !stillAllowed {
                result.presentation = .unavailable
                result.steps.presentation = .skipped
            } else if let injected = _injectPresentationFailure?(tileId) {
                result.presentation = .unavailable
                result.steps.presentation = .failed
                result.partial = true
                result.retryOp = .agentReveal
                result.failureMessage = injected
            } else {
                let (presentation, effects) = present(
                    tileId: tileId, policy: effectivePolicy, generationAtDispatch: generationAtDispatch,
                    runtime: runtime, canvas: canvas)
                result.presentation = presentation
                result.presentationEffects = effects
                result.steps.presentation = .succeeded
            }
        }
        result.status = result.partial ? .partial : .committed
        result.childRunning = supervisor.isRunning(childId)
        finish(agentId: agentId, requestId: requestId, result: result, outcome: result.partial ? "partial" : "ok")
        guard let object = Self.jsonObject(result) else {
            return .error(WorkspaceAPIError(code: .unsupported, message: "Result could not be encoded."))
        }
        return .result(object)
    }

    private enum Attachment {
        case attached(tileId: UUID, zoneId: UUID)
        case failed(String)
    }

    /// The inbox-reveal route (`AppDelegate.attachTileToAgentFromInbox`) with an
    /// explicit creation scope: the PARENT's zone when it has one in this
    /// workspace, otherwise the project's installed zone. One `zoneId` for framing
    /// (`makeProjectTilePlacement`), siblings, z-order and `installProjectTile`
    /// (`.plans/47`). No arming, no camera, no focus.
    private func attachTile(
        for childId: AgentID, parent: AgentRecord, placement: AgentDelegateRequest.Placement?,
        runtime: WorkspaceRuntime, canvas: CanvasNSView
    ) -> Attachment {
        let parentZone = parent.tileId.flatMap { canvas.zoneId(containing: $0) }
        guard let projectId = parent.projectId
            ?? parentZone.flatMap({ id in runtime.document.zones.first(where: { $0.zoneId == id })?.projectId }) else {
            return .failed("project_unavailable: the parent belongs to no registered project, so its child has no zone to appear in.")
        }
        let projectZones = runtime.document.zonesInZOrder.filter { $0.projectId == projectId }
        guard !projectZones.isEmpty else {
            return .failed("project_not_in_workspace: the parent's project has no zone in this workspace; the child is in the inbox.")
        }
        let targetZoneId: UUID
        if let parentZone, projectZones.contains(where: { $0.zoneId == parentZone }) {
            targetZoneId = parentZone
        } else if let installed = projectZones.last(where: { canvas.installedZonePlacement(for: $0.zoneId) != nil }) {
            targetZoneId = installed.zoneId
        } else {
            return .failed("zone_unhydrated: the parent's zone has no installed layer; the child is in the inbox.")
        }
        guard let zonePlacement = canvas.installedZonePlacement(for: targetZoneId),
              let zone = projectZones.first(where: { $0.zoneId == targetZoneId }) else {
            return .failed("zone_unhydrated: the parent's zone has no installed layer; the child is in the inbox.")
        }
        let scope = CreationScope(
            projectId: projectId,
            projectRoot: parent.projectRoot ?? parent.checkoutRoot,
            homeRelativePath: zone.homeRelativePath,
            source: .zone,
            zoneId: targetZoneId)

        // Beside the anchor (the named tile, else the parent) when the anchor is
        // in the target zone and the docked frame stays inside it; otherwise the
        // zone's own automatic, clamped placement.
        var worldPoint: CGPoint?
        let anchorId = placement?.nearTileId ?? parent.tileId
        if let anchorId, canvas.zoneId(containing: anchorId) == targetZoneId,
           let anchor = canvas.navigationTileSnapshot(for: anchorId) {
            let size = CanvasEngine.defaultFrame(for: .managedAgent)
            let docked = CGRect(
                x: anchor.worldFrame.x + anchor.worldFrame.width + TileSpawner.anchoredFileGap,
                y: anchor.worldFrame.y, width: size.width, height: size.height)
            let zoneRect = CGRect(
                x: zonePlacement.origin.x, y: zonePlacement.origin.y,
                width: zonePlacement.size.width, height: zonePlacement.size.height)
            if zoneRect.contains(docked) {
                worldPoint = CGPoint(x: docked.midX, y: docked.midY)
            }
        }

        let spawner: TileSpawner
        do {
            spawner = try runtime.ensureSpawner(forProjectId: projectId)
        } catch {
            return .failed("project_unavailable: \(error.localizedDescription)")
        }
        switch spawner.spawnManagedAgentForExistingAgent(childId, supervisor: supervisor, at: worldPoint, creationScope: scope) {
        case let .spawned(tileId):
            // The durable record binding first (P2A.5's one site is the wiring,
            // which repeats it idempotently), then the view binding.
            supervisor.attach(agentID: childId, to: tileId)
            tileWiring?(tileId, childId)
            runtime.noteStructuralCommit()
            return .attached(tileId: tileId, zoneId: canvas.zoneId(containing: tileId) ?? targetZoneId)
        case let .failure(error):
            return .failed("attachment_failed: \(error.localizedDescription)")
        }
    }

    private func finish(agentId: AgentID, requestId: String, result: AgentDelegateResult, outcome: String) {
        operations.update(operationId: requestId) { op in
            op.status = result.status
            op.steps = result.steps
            op.tileId = result.tileId
            op.failureMessage = result.failureMessage
            if result.steps.presentation == .failed { op.failureCode = "presentation_failed" }
        }
        if let object = Self.jsonObject(result) { delegateReplayResults[requestId] = object }
        // Prune replays whose records the bounded store has evicted.
        delegateReplayResults = delegateReplayResults.filter { operations.record(operationId: $0.key) != nil }
        remember(agentId: agentId, WorkspaceRecentOperation(requestId: requestId, op: .agentDelegate, outcome: outcome, tileId: result.tileId))
    }

    /// A replay for a record whose encoded result is gone (never in practice —
    /// both are pruned together — but a record must never be answered with a
    /// fresh spawn).
    private static func replayResult(from record: WorkspaceOperationRecord, running: Bool?) -> AgentDelegateResult {
        AgentDelegateResult(
            operationId: record.operationId, status: record.status, childAgentId: record.childAgentId,
            parentAgentId: record.agentId, tileId: record.tileId, provider: nil, model: nil,
            steps: record.steps, presentation: .unavailable, presentationEffects: .allPreserved,
            actualWorldRect: nil, actualZoneId: nil, childRunning: running,
            partial: record.status == .partial,
            retryOp: record.steps.presentation == .failed ? .agentReveal : nil,
            failureMessage: record.failureMessage)
    }

    private static func namesHarness(_ raw: String, _ harness: AgentHarness) -> Bool {
        let wanted = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return wanted == harness.rawValue.lowercased()
            || wanted == harness.rawValue.lowercased().replacingOccurrences(of: " ", with: "-")
            || wanted == harness.rawValue.lowercased().replacingOccurrences(of: " ", with: "")
    }

    // MARK: - agent.reveal (§10.3)

    func reveal(
        agentId: AgentID, record: AgentRecord, ownHandle: CheckoutHandle, requestId: String,
        payload: [String: Any], runtime: WorkspaceRuntime, canvas: CanvasNSView
    ) -> Reply {
        let request: AgentRevealRequest
        do {
            let data = try JSONSerialization.data(withJSONObject: payload)
            request = try JSONDecoder().decode(AgentRevealRequest.self, from: data)
        } catch {
            return .error(WorkspaceAPIError(code: .invalidRequest, message: "The reveal request could not be decoded: \(error.localizedDescription)"))
        }
        let generationAtDispatch = runtime.interactionGeneration
        guard case let .allowed(_, policy) = WorkspaceToolGrantEvaluator.evaluate(
            agentId: agentId, op: .agentReveal, checkout: ownHandle, requested: request.presentationPolicy,
            grants: grants[agentId] ?? [], currentGeneration: revocationGeneration) else {
            return .error(WorkspaceAPIError(code: .permissionDenied, message: "This agent may not reveal agents."))
        }
        // Own children (and itself) only. Anything else is refused without
        // confirming whether the id exists.
        guard let target = supervisor.records[request.agentId],
              request.agentId == agentId || target.parentAgentID == agentId else {
            return .error(WorkspaceAPIError(code: .permissionDenied, message: "This agent may only reveal itself or its own children."))
        }
        guard let tileId = target.tileId else {
            return .error(WorkspaceAPIError(code: .notFound, message: "That agent has no tile on the canvas. It is still in the inbox; nothing was created."))
        }
        guard let zoneId = canvas.zoneId(containing: tileId) else {
            if let projectId = target.projectId,
               let projectWorkspaceId = (try? registryStoreProvider()?.loadOrEmpty())?.projects
                   .first(where: { $0.id == projectId && !$0.missing })?.workspaceId,
               projectWorkspaceId != runtime.workspaceId {
                return .error(WorkspaceAPIError(
                    code: .presentationRequired,
                    message: "That agent's tile lives in another workspace (\(projectWorkspaceId.uuidString)); revealing it would switch workspaces, which this operation does not do.",
                    requiredEffects: WorkspacePresentationEffects(workspace: .changed)))
            }
            return .error(WorkspaceAPIError(code: .unsupported, message: "zone_unhydrated: that agent's tile is not installed in this workspace right now; nothing was changed."))
        }
        // Recheck immediately before presentation (§14.1).
        guard supervisor.records[agentId]?.workspaceToolsEnabled == true else {
            return .error(WorkspaceAPIError(code: .permissionDenied, message: "Access was revoked before the reveal."))
        }
        let (presentation, effects) = present(
            tileId: tileId, policy: policy, generationAtDispatch: generationAtDispatch, runtime: runtime, canvas: canvas)
        var result = AgentRevealResult(
            operationId: requestId, agentId: request.agentId, tileId: tileId, actualZoneId: zoneId,
            actualWorldRect: nil, presentation: presentation, presentationEffects: effects)
        if let snapshot = canvas.navigationTileSnapshot(for: tileId) {
            result.actualWorldRect = CanvasWorldRect(snapshot.worldFrame)
        }
        remember(agentId: agentId, WorkspaceRecentOperation(requestId: requestId, op: .agentReveal, outcome: "ok", tileId: tileId))
        guard let object = Self.jsonObject(result) else {
            return .error(WorkspaceAPIError(code: .unsupported, message: "Result could not be encoded."))
        }
        return .result(object)
    }

    // MARK: - operation.get (§10.3)

    func operationGet(agentId: AgentID, ownHandle: CheckoutHandle, requestId: String, payload: [String: Any]) -> Reply {
        let request: OperationGetRequest
        do {
            let data = try JSONSerialization.data(withJSONObject: payload)
            request = try JSONDecoder().decode(OperationGetRequest.self, from: data)
        } catch {
            return .error(WorkspaceAPIError(code: .invalidRequest, message: "The operation.get request could not be decoded: \(error.localizedDescription)"))
        }
        guard case .allowed = WorkspaceToolGrantEvaluator.evaluate(
            agentId: agentId, op: .operationGet, checkout: ownHandle, requested: .preserveAll,
            grants: grants[agentId] ?? [], currentGeneration: revocationGeneration) else {
            return .error(WorkspaceAPIError(code: .permissionDenied, message: "This agent may not read operations."))
        }
        let lookup: WorkspaceOperationStore.Lookup
        if let operationId = request.operationId, !operationId.isEmpty {
            lookup = operations.lookup(agentId: agentId, operationId: operationId)
        } else if let key = request.idempotencyKey, !key.isEmpty {
            lookup = operations.lookup(agentId: agentId, idempotencyKey: key)
        } else {
            return .error(WorkspaceAPIError(code: .invalidRequest, message: "operationId or idempotencyKey is required."))
        }
        let result: OperationGetResult
        switch lookup {
        case let .found(record):
            result = OperationGetResult(
                operationId: record.operationId, op: record.op, status: record.status, steps: record.steps,
                childAgentId: record.childAgentId, tileId: record.tileId,
                childRunning: record.childAgentId.map { supervisor.records[$0] != nil && supervisor.isRunning($0) },
                failureCode: record.failureCode, failureMessage: record.failureMessage, createdAt: record.createdAt)
        case let .expired(tombstone):
            result = OperationGetResult(
                operationId: tombstone.operationId, op: nil, status: .expired, steps: nil,
                childAgentId: tombstone.childAgentId, tileId: nil,
                childRunning: tombstone.childAgentId.map { supervisor.records[$0] != nil && supervisor.isRunning($0) },
                failureCode: "expired",
                failureMessage: "This operation was evicted from the host's bounded store. Its outcome is unknown here; do not repeat the request.")
        case .unknown:
            return .error(WorkspaceAPIError(code: .notFound, message: "No operation of yours matches that id."))
        }
        guard let object = Self.jsonObject(result) else {
            return .error(WorkspaceAPIError(code: .unsupported, message: "Result could not be encoded."))
        }
        return .result(object)
    }

    // MARK: - Helpers

    private static func payloadHash(_ request: AgentDelegateRequest) -> String {
        var normalized = request
        normalized.idempotencyKey = nil
        guard let data = try? encoder.encode(normalized) else { return UUID().uuidString }
        return String(decoding: data, as: UTF8.self)
    }

    /// Op-aware twin of the open path's `consumeSingleUseGrant`.
    private func consumeSingleUseGrant(agentId: AgentID, checkout: CheckoutHandle, op: WorkspaceAPIOp) {
        guard var live = grants[agentId] else { return }
        let durable = live.contains { !$0.singleUse && $0.checkoutHandles.contains(checkout) && $0.operations.contains(op) && $0.revocationGeneration == revocationGeneration }
        guard !durable, let index = live.firstIndex(where: { $0.singleUse && $0.checkoutHandles.contains(checkout) && $0.operations.contains(op) }) else { return }
        live.remove(at: index)
        grants[agentId] = live
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
