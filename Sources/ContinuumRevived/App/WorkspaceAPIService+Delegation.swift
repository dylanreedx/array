import AppKit
import ContinuumRevivedCore
import Foundation

// CX-01 Phase 2b (`.plans/59-parallel-product-investigations/canvas-awareness-api-design.md`, §10).
//
// Visible delegation with safe retry. Three ops, one rule: the child is created
// by the supervisor's EXISTING path — `AgentSupervisor.handleSpawnRequest`, the
// same function the pi `spawn_agent` tool drives — and made visible by the
// EXISTING inbox-reveal route (`TileSpawner.spawnManagedAgentForExistingAgent`
// → `installProjectTile`, then `AppDelegate.wireManagedAgentTile`). The supervisor
// owns process launch and Managed helper isolation. Harness/model selectors are
// resolved against the selected CLI catalogue before creation. The operation
// record is reserved BEFORE creation and every step
// is reported separately (§10.3): a child whose tile could not be presented is a
// success with a repairable step, repaired by `agent.reveal`, never by a second
// `agent.delegate`.
extension WorkspaceAPIService {

    // MARK: - agent.delegate (§10)

    ///
    /// Answers through `completion`, once, on main. With `checkoutOffMain` the
    /// supervisor runs the child's git step (`rev-parse`, `worktree add`) on a
    /// background queue and the answer comes later; without it, before return.
    func delegate(
        agentId: AgentID, record: AgentRecord, ownHandle: CheckoutHandle, requestId: String,
        payload: [String: Any], runtime: WorkspaceRuntime, canvas: CanvasNSView,
        checkoutOffMain: Bool, isCancelled: @escaping () -> Bool, completion: @escaping (Reply) -> Void
    ) {
        // 1. Schema.
        let request: AgentDelegateRequest
        do {
            let data = try JSONSerialization.data(withJSONObject: payload)
            request = try JSONDecoder().decode(AgentDelegateRequest.self, from: data)
        } catch {
            return completion(.error(WorkspaceAPIError(code: .invalidRequest, message: "The delegate request could not be decoded: \(error.localizedDescription)")))
        }
        guard !request.task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return completion(.error(WorkspaceAPIError(code: .invalidRequest, message: "task is required.")))
        }
        guard let idempotencyKey = request.idempotencyKey?.trimmingCharacters(in: .whitespacesAndNewlines), !idempotencyKey.isEmpty else {
            return completion(.error(WorkspaceAPIError(code: .invalidRequest, message: "idempotencyKey is required for agent.delegate: a spawn without one cannot be retried safely.")))
        }
        // Never refused: entries Array cannot use are left out and named.
        let prepared = request.contract?.prepared(checkoutRoot: record.checkoutRoot)
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
            if let cached = delegateReplayResults[existing.operationId] { return completion(.result(cached)) }
            return completion(.result(Self.jsonObject(Self.replayResult(from: existing, running: existing.childAgentId.map(supervisor.isRunning))) ?? [:]))
        case .conflict:
            return completion(.error(WorkspaceAPIError(code: .idempotencyConflict, message: "This idempotencyKey was already used for a different delegation. New intent needs a new key.")))
        case let .expired(tombstone):
            let child = tombstone.childAgentId.map { " Its child was \($0.rawValue.uuidString)." } ?? ""
            return completion(.error(WorkspaceAPIError(code: .outcomeUnknown, message: "This idempotencyKey belongs to an expired operation (\(tombstone.operationId)); Array no longer holds its outcome and will not repeat it.\(child) Call operation.get, or use a new key for new intent.")))
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

        if let retryOf = request.retryOf, !supervisor.mayRetry(retryOf, from: agentId) {
            return completion(fail(.invalidRequest, "retryOf must name your failed, stopped or errored child, with no active turn."))
        }

        // Resolve exclusively against the selected CLI's live catalogue.
        guard let parentHarness = record.harness else {
            return completion(fail(.unsupported, "This agent's harness is unresolved, so a child cannot inherit it."))
        }
        func resolveHarness(_ raw: String) -> AgentHarness? {
            AgentHarness.allCases.first { Self.namesHarness(raw, $0) }
        }
        let childHarness: AgentHarness
        if let selector = request.harness ?? request.provider {
            guard let selected = resolveHarness(selector) else {
                return completion(fail(.invalidRequest, "Unknown child harness '\(selector)'. Choose Claude Code, Codex or Pi."))
            }
            childHarness = selected
        } else {
            childHarness = parentHarness
        }
        if let provider = request.provider, resolveHarness(provider) != childHarness {
            return completion(fail(.invalidRequest, "harness and provider must name the same CLI."))
        }
        if let reason = AgentSupervisor.readinessRefusal(for: childHarness, retry: "delegate again") {
            return completion(fail(.unsupported, reason))
        }
        if let reason = supervisor.delegationQuotaRefusal(for: childHarness) {
            return completion(fail(.unsupported, reason))
        }
        let catalog = AgentModelCatalog.shared.snapshot(for: childHarness)
        guard let childModel = request.model ?? (childHarness == parentHarness ? record.model : catalog.seedModel),
              catalog.models.contains(childModel),
              (request.model == nil && childHarness == parentHarness || childModel.contains("/")) else {
            // Name the offered ids verbatim: the caller cannot see the catalogue
            // otherwise, and a guessed bare id ("claude-haiku-5-5") never matches.
            let offered = catalog.models.prefix(24).joined(separator: ", ")
            return completion(fail(.unsupported, "\(childHarness.rawValue) does not offer the requested child model. Use an exact fully qualified id from its live catalogue: \(offered.isEmpty ? "none offered" : offered). No other CLI was tried."))
        }

        func effortRefusal() -> String? {
            guard let effort = request.effort else { return nil }
            guard let accepted = AgentModelCatalog.shared.efforts(for: childModel, harness: childHarness), !accepted.isEmpty else {
                return "The live catalogue has no effort data for \(childModel); explicit effort is unavailable. Omit effort to use the CLI default."
            }
            return accepted.contains(effort) ? nil : "Unsupported effort '\(effort)' for \(childModel). Accepted values: \(accepted.joined(separator: ", "))."
        }
        if let reason = effortRefusal() { return completion(fail(.unsupported, reason)) }

        // 4. Grant (§14.1). Delegation is outside the Phase 1 preset: the first
        //    request per agent session goes through the trusted approval UI.
        let effectivePolicy: WorkspacePresentationPolicy
        var approvalRequestId: String?
        switch WorkspaceToolGrantEvaluator.evaluate(
            agentId: agentId, op: .agentDelegate, checkout: ownHandle,
            requested: request.presentationPolicy, grants: grants[agentId] ?? [],
            currentGeneration: revocationGeneration(for: agentId)) {
        case let .allowed(_, policy):
            effectivePolicy = policy
        case .denied, .scopeApprovalRequired:
            let promptId = UUID().uuidString
            approvalRequestId = promptId
            // A child is always created in this agent's own project.
            let decision = decideScope(ScopeApprovalPrompt(
                requestId: promptId, agentId: agentId, agentDisplayName: record.displayName,
                checkout: ownHandle, checkoutDisplayName: URL(fileURLWithPath: record.checkoutRoot).lastPathComponent,
                op: .agentDelegate, relativePath: nil),
                withinCallerProject: true)
            if isCancelled() {
                operations.release(operationId: requestId)
                remember(agentId: agentId, WorkspaceRecentOperation(requestId: requestId, op: .agentDelegate, outcome: "cancelledBeforeEffect"))
                return completion(.cancelled(result: nil))
            }
            guard supervisor.records[agentId]?.workspaceToolsEnabled == true else {
                return completion(fail(.permissionDenied, "Workspace tools were disabled for this agent.", approvalRequestId: promptId))
            }
            switch decision {
            case .deny:
                return completion(fail(.permissionDenied, "The user declined to let this agent delegate.", approvalRequestId: promptId))
            case .allowOnce:
                mint(WorkspaceToolGrant(
                    agentId: agentId, checkoutHandles: [ownHandle], operations: [.agentDelegate],
                    presentationCeiling: WorkspaceToolGrant.phase1Ceiling,
                    issuer: .userApprovalOnce(requestId: promptId),
                    revocationGeneration: revocationGeneration(for: agentId), singleUse: true))
            case .allowForSession, .allowForProjectSession, .allowByPolicy:
                mint(WorkspaceToolGrant(
                    agentId: agentId, checkoutHandles: [ownHandle], operations: [.agentDelegate],
                    presentationCeiling: WorkspaceToolGrant.phase1Ceiling,
                    issuer: Self.sessionIssuer(decision, requestId: promptId),
                    revocationGeneration: revocationGeneration(for: agentId)))
            }
            guard case let .allowed(_, policy) = WorkspaceToolGrantEvaluator.evaluate(
                agentId: agentId, op: .agentDelegate, checkout: ownHandle,
                requested: request.presentationPolicy, grants: grants[agentId] ?? [],
                currentGeneration: revocationGeneration(for: agentId)) else {
                return completion(fail(.permissionDenied, "Approval did not take.", approvalRequestId: promptId))
            }
            effectivePolicy = policy
        }
        consumeSingleUseGrant(agentId: agentId, checkout: ownHandle, op: .agentDelegate)
        let generationAtGrant = revocationGeneration(for: agentId)

        // 5. Recheck immediately before the effect; cancellation before it means
        //    nothing happens and the key stays free.
        guard supervisor.records[agentId]?.workspaceToolsEnabled == true, revocationGeneration(for: agentId) == generationAtGrant else {
            return completion(fail(.permissionDenied, "Access was revoked before the child was created.", approvalRequestId: approvalRequestId))
        }
        if isCancelled() {
            operations.release(operationId: requestId)
            remember(agentId: agentId, WorkspaceRecentOperation(requestId: requestId, op: .agentDelegate, outcome: "cancelledBeforeEffect"))
            return completion(.cancelled(result: nil))
        }
        _beforeCommitHook?()

        // Approval can run a nested event loop; validate again at the effect seam.
        if let reason = AgentSupervisor.readinessRefusal(for: childHarness, retry: "delegate again") {
            return completion(fail(.unsupported, reason))
        }
        if let reason = supervisor.delegationQuotaRefusal(for: childHarness) { return completion(fail(.unsupported, reason)) }
        guard AgentModelCatalog.shared.models(for: childHarness).contains(childModel) else {
            return completion(fail(.unsupported, "The selected child model is no longer offered by \(childHarness.rawValue). Delegate again with an exact catalogue id."))
        }

        if let reason = effortRefusal() { return completion(fail(.unsupported, reason)) }

        // Approval may have let the old helper resume or disappear.
        var prompt = request.task
        // A retry continues the same work: it keeps the failed helper's stored
        // effort unless this call names its own. The inherited value is not
        // refused here; launch leaves it off if the catalogue no longer lists it.
        var retryEffort: String?
        var retryContract: AgentDelegationContract?
        if let retryOf = request.retryOf {
            guard supervisor.mayRetry(retryOf, from: agentId), let old = supervisor.records[retryOf] else {
                return completion(fail(.invalidRequest, "retryOf must name your failed, stopped or errored child, with no active turn."))
            }
            retryEffort = old.thinking
            retryContract = old.delegationContext?.contract
            let files = try? WorktreeManager().changedFiles(
                repo: URL(fileURLWithPath: old.checkoutRoot), since: old.delegationContext?.baseHead)
            prompt += "\n\n" + AgentDelegationContext.handoff(from: old, changedFiles: files)
        }
        // Told once, after the task; a retry keeps the failed helper's contract
        // unless this call states its own.
        let contract = prepared?.contract ?? retryContract
        if let contract { prompt += "\n\n" + contract.promptText }
        if request.readOnly == true && supervisor.chooserEnabled(for: agentId) {
            prompt += "\n\nRead-only helper: investigate or review; do not edit checkout files."
        }
        // A Managed lead's helper reports through array_report (.plans/102).
        if supervisor.effectiveMode(for: agentId) == .managed {
            prompt += "\n\n" + ManagedLeadHookState.helperReportLine
        }

        let chooserPending = supervisor.chooserWillDelegate(agentId, source: requestId, readOnly: request.readOnly == true)
        // 6. Creation, through the supervisor's one child-creation path. The
        //    request id doubles as the spawn-result handle, so `wait_agents` can
        //    collect this child exactly like a `spawn_agent` one.
        let spawnRequest = SpawnRequest(
            role: nil, prompt: prompt, isolated: false, sourceItemID: requestId,
            displayLabel: request.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty)
        func created(_ childId: AgentID) -> Reply {
            let chooserAdvice = supervisor.chooserDelegated(agentId, source: requestId, pending: chooserPending, child: childId)
            if supervisor.qaRunLedgerRecording, let child = supervisor.records[childId] {
                // `.plans/116` part 8: shadow evidence of the child's own tool calls,
                // through the supervisor's observer seam; nothing reads it back.
                supervisor.runLedger.delegated(parent: agentId.rawValue, child: childId.rawValue, source: requestId,
                    root: child.checkoutRoot, base: child.delegationContext?.baseHead,
                    shared: WorktreeManager.resolved(URL(fileURLWithPath: child.checkoutRoot))
                        == WorktreeManager.resolved(URL(fileURLWithPath: record.checkoutRoot)),
                    contract: child.delegationContext?.contract, protectedPaths: supervisor.chooserEnabled(for: agentId))
                let ledger = supervisor.runLedger
                _ = supervisor.addRuntimeObservationObserver(for: childId) { [weak supervisor] observation in
                    guard supervisor?.qaRunLedgerRecording == true, let sighting = HelperEvidence.Sighting(observation) else { return }
                    ledger.observeTool(agent: childId.rawValue, sighting)
                }
            }
            operations.update(operationId: requestId) { op in
                op.steps.creation = .succeeded
                op.childAgentId = childId
            }
            // The child's first turn is agent-started too: it continues the chain.
            recordMessageChain(target: childId, hops: messageChainHops(for: agentId) + 1)
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

            result.coordinationNote = supervisor.resultDelivery(for: agentId) == .push
                ? "Continue independent work or end this turn. Array delivers this helper's result to you by itself; do not poll, wait or message it to check."
                : "Array does not run this agent, so it delivers no helper results to it. Continue independent work, then collect the result with a short wait_agents when needed; do not poll."
            result.checkoutRoot = child?.checkoutRoot
            result.worktreeBranch = child?.worktreeBranch
            result.checkoutNotice = child?.delegationContext?.checkoutNotice
            // Advice, never a refusal: paths a live sibling's contract also claims.
            // Records are already in memory; nothing waits on disk. Past the size
            // where comparing could cost the main actor about a millisecond, the
            // result says so instead of comparing.
            var notes = prepared?.notes ?? []
            if let chooserAdvice { notes.append(chooserAdvice) }
            if let contract, !(contract.owns.isEmpty && contract.shared.isEmpty) {
                let siblings = supervisor.children(of: agentId).compactMap { sibling -> (AgentID, AgentRecord, AgentDelegationContract)? in
                    guard sibling != childId, supervisor.isRunning(sibling) || supervisor.turnPresence(for: sibling)?.phase.isLive == true,
                          let record = supervisor.records[sibling], let theirs = record.delegationContext?.contract else { return nil }
                    return (sibling, record, theirs)
                }
                let claims = siblings.reduce(contract.owns.count + contract.shared.count) { $0 + $1.2.owns.count + $1.2.shared.count }
                if claims > Self.overlapClaimBudget {
                    notes.append("ownership overlap not computed: \(claims) claimed paths across live siblings")
                } else {
                    let overlaps = siblings.compactMap { sibling, record, theirs -> AgentDelegateResult.OwnershipOverlap? in
                        let paths = contract.claimOverlap(with: theirs)
                        return paths.isEmpty ? nil : .init(agentId: sibling, title: record.humanDisplayName, paths: paths)
                    }
                    if !overlaps.isEmpty { result.ownershipOverlaps = overlaps }
                }
            }
            if !notes.isEmpty { result.contractNotes = notes }


            // 7. Attachment: a tile in the PARENT's zone, framed against that zone
            //    (hazard 9), through the existing managed-agent tile route.
            if record.mode == .managed {
                // A full Array runner and courier, with presentation deliberately absent.
                result.steps.attachment = .skipped
                result.steps.durability = .succeeded
                result.steps.presentation = .skipped
            } else {
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
                    && revocationGeneration(for: agentId) == generationAtGrant
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
        // The gate repeats step 5's authorization, and the retry eligibility
        // checked after approval, at the moment of creation: the git step ran in
        // between, and access revoked or an old helper resumed during it creates
        // nothing.
        // Cancellation is not re-checked: past the commit boundary the child is
        // committed, and step 8 reports it truthfully.
        let gate: () -> String? = { [weak self] in
            guard let self else { return "revoked" }
            guard self.supervisor.records[agentId]?.workspaceToolsEnabled == true,
                  self.revocationGeneration(for: agentId) == generationAtGrant else { return "revoked" }
            if let retryOf = request.retryOf, !self.supervisor.mayRetry(retryOf, from: agentId) { return "retryIneligible" }
            return nil
        }
        supervisor.handleSpawnRequestAsync(spawnRequest, from: agentId, childSelection: AgentLaunchSelection(harness: childHarness, model: childModel, thinking: request.effort ?? retryEffort ?? (childHarness == parentHarness ? record.thinking : AgentModelConfig.defaultThinking)), mode: .free, retryOf: request.retryOf, originalBrief: request.task, contract: contract, checkoutOffMain: checkoutOffMain, gate: gate) { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case let .spawned(childId):
                completion(created(childId))
            case .refused:
                _ = self.supervisor.chooserDelegated(agentId, source: requestId, pending: chooserPending, child: nil)
                let reason = self.supervisor.spawnRefusal(for: agentId)?.reason ?? "the supervisor refused the spawn"
                completion(fail(.unsupported, "Array did not start a child: \(reason).", approvalRequestId: approvalRequestId, keep: true))
            case .gateClosed("retryIneligible"):
                _ = self.supervisor.chooserDelegated(agentId, source: requestId, pending: chooserPending, child: nil)
                completion(fail(.invalidRequest, "retryOf must name your failed, stopped or errored child, with no active turn."))
            case .gateClosed:
                _ = self.supervisor.chooserDelegated(agentId, source: requestId, pending: chooserPending, child: nil)
                completion(fail(.permissionDenied, "Access was revoked before the child was created.", approvalRequestId: approvalRequestId))
            }
        }
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
        if let slot = canvas.visibleSpawnSlot(size: CanvasEngine.defaultFrame(for: .managedAgent),
                                              anchor: canvas.spawnAnchorWorldPoint, zoneId: targetZoneId) {
            worldPoint = CGPoint(x: slot.midX, y: slot.midY)
        }
        let anchorId = placement?.nearTileId ?? parent.tileId
        if worldPoint == nil, let anchorId, canvas.zoneId(containing: anchorId) == targetZoneId,
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
            grants: grants[agentId] ?? [], currentGeneration: revocationGeneration(for: agentId)) else {
            return .error(WorkspaceAPIError(code: .permissionDenied, message: "This agent may not reveal agents."))
        }
        // Own children (and itself) only. Anything else is refused without
        // confirming whether the id exists.
        guard let target = supervisor.records[request.agentId].map(resolvedRecord),
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

    // MARK: - agent.message (§10)

    /// One text message into another agent, delivered through the supervisor's
    /// own send path (`AgentSupervisor.send` — the function the composer's Send
    /// button drives). Nothing here writes to a provider, and nothing here waits
    /// for an answer: the result reports DELIVERY only, and the caller collects
    /// the reply the existing way (`wait_agents`, or `agent.inspect`).
    ///
    /// Reach depends on Agent permissions (`mayMessage`). Under `free`, any
    /// other agent in the caller's own project — a child, its parent, a sibling,
    /// one the user started — so "message the agent to our right" works. Under
    /// `askFirst`/`off`, only the caller's own children and its own parent.
    /// Never an agent in another project. A target out of reach is
    /// `permission_denied` with a message that names no id and no path, so a
    /// refusal never even confirms which ids exist. Messaging SELF is
    /// `invalid_request`, because an agent continues its own turn instead.
    ///
    /// `agent.message` is deliberately NOT in `sessionPresetOperations`: writing
    /// into another agent's run is an effect. Under `askFirst` the first message
    /// per agent session goes through the trusted approval UI, and an approved
    /// DELEGATION grants nothing here. A chain of agent-started turns with no
    /// prompt from the user in between stops at `messageHopLimit`, so two agents
    /// that can reach each other cannot keep each other running forever.
    func message(
        agentId: AgentID, record: AgentRecord, ownHandle: CheckoutHandle, requestId: String,
        payload: [String: Any], runtime: WorkspaceRuntime, canvas: CanvasNSView,
        isCancelled: () -> Bool
    ) -> Reply {
        // 1. Schema and pure bounds (the 8 KB text ceiling, the required key).
        let request: AgentMessageRequest
        do {
            let data = try JSONSerialization.data(withJSONObject: payload)
            request = try JSONDecoder().decode(AgentMessageRequest.self, from: data)
        } catch {
            return .error(WorkspaceAPIError(code: .invalidRequest, message: "The message request could not be decoded: \(error.localizedDescription)"))
        }
        if let failure = request.validationFailure() {
            return .error(WorkspaceAPIError(code: .invalidRequest, message: failure))
        }
        guard let idempotencyKey = request.idempotencyKey?.trimmingCharacters(in: .whitespacesAndNewlines), !idempotencyKey.isEmpty else {
            return .error(WorkspaceAPIError(code: .invalidRequest, message: "idempotencyKey is required for agent.message: a retry without one would prompt the child twice."))
        }
        let text = request.text
        let generationAtDispatch = runtime.interactionGeneration

        // 2. Scope, BEFORE the operation store and before the user is asked:
        //    nobody is prompted about a target that was never messageable.
        guard request.agentId != agentId else {
            return .error(WorkspaceAPIError(
                code: .invalidRequest,
                message: "An agent cannot message itself: continue your own turn instead of starting a second one."))
        }
        // One message for "out of reach" and for "does not exist", so a refusal
        // discloses no identity (§14.4).
        let permission = supervisor.workspaceToolsPermission()
        let notYours = WorkspaceAPIError(
            code: .permissionDenied,
            message: permission == .free
                ? "This agent may message only agents in its own project. An agent in another project is out of scope."
                : "This agent may message only the children it created and the agent that created it, because Agent permissions is set to Ask first. A sibling, an unrelated agent and an agent in another project are out of scope.")
        guard let target = supervisor.records[request.agentId].map(resolvedRecord),
              Self.mayMessage(from: record, to: target, permission: permission) else {
            return .error(notYours)
        }
        // The service's field names predate wider reach: `childId` is the target.
        let childId = target.id

        // 3. Reserve BEFORE any effect (§10.2). EXACTLY ONE DELIVERY PER KEY:
        //    the same key with the same text replays the first outcome and sends
        //    nothing; the same key with different text is a conflict.
        let payloadHash = Self.messagePayloadHash(request)
        do {
            if let entry = try supervisor.queuedAgentMessage(caller: agentId, key: idempotencyKey) {
                guard entry.context.payloadHash == payloadHash else {
                    return .error(WorkspaceAPIError(code: .idempotencyConflict, message: "This key already admitted a different message."))
                }
                let replay = AgentMessageResult(operationId: entry.context.operationId, delivery: .queued,
                    childAgentId: entry.context.recipient, parentAgentId: agentId,
                    childName: target.humanDisplayName, childRunning: supervisor.isRunning(childId), queuePosition: entry.queuePosition)
                return .result(Self.jsonObject(replay) ?? [:])
            }
        } catch {
            return .error(WorkspaceAPIError(code: .durabilityFailed, message: "The durable message admission could not be read; nothing was repeated."))
        }
        switch operations.reserve(
            agentId: agentId, op: .agentMessage, idempotencyKey: idempotencyKey,
            payloadHash: payloadHash, operationId: requestId) {
        case let .replay(existing):
            if let cached = messageReplayResults[existing.operationId] { return .result(cached) }
            let replay = AgentMessageResult(
                operationId: existing.operationId,
                delivery: existing.steps.creation == .succeeded ? .delivered : .refused,
                childAgentId: existing.childAgentId ?? childId, parentAgentId: agentId,
                childName: supervisor.records[existing.childAgentId ?? childId]?.humanDisplayName,
                childRunning: supervisor.records[childId] != nil ? supervisor.isRunning(childId) : nil,
                refusalReason: existing.failureMessage)
            return .result(Self.jsonObject(replay) ?? [:])
        case .conflict:
            return .error(WorkspaceAPIError(code: .idempotencyConflict, message: "This idempotencyKey was already used for a different message. New text needs a new key; reusing one is what stops a retry from prompting the child twice."))
        case let .expired(tombstone):
            return .error(WorkspaceAPIError(code: .outcomeUnknown, message: "This idempotencyKey belongs to an expired operation (\(tombstone.operationId)); Array no longer holds its outcome and will not repeat the delivery. Call operation.get, or ask the user."))
        case .reserved:
            break
        }
        /// A failure that delivered NOTHING keeps the key usable: `reserve`
        /// re-opens a `failed` record whose creation step never succeeded, so a
        /// retry after the cause is gone still cannot double-deliver.
        func failNothingDelivered(_ code: WorkspaceAPIError.Code, _ message: String, approvalRequestId: String? = nil) -> Reply {
            operations.update(operationId: requestId) { op in
                op.status = .failed
                op.steps.creation = .failed
                op.childAgentId = childId
                op.failureCode = code.rawValue
                op.failureMessage = message
            }
            remember(agentId: agentId, WorkspaceRecentOperation(requestId: requestId, op: .agentMessage, outcome: "error:\(code.rawValue)"))
            return .error(WorkspaceAPIError(code: code, message: message, approvalRequestId: approvalRequestId))
        }

        // 4. Grant (§14.1). Outside the preset, so the first message per agent
        //    session reaches the trusted approval UI; the alert names the child.
        let effectivePolicy: WorkspacePresentationPolicy
        var approvalRequestId: String?
        switch WorkspaceToolGrantEvaluator.evaluate(
            agentId: agentId, op: .agentMessage, checkout: ownHandle,
            requested: request.presentationPolicy, grants: grants[agentId] ?? [],
            currentGeneration: revocationGeneration(for: agentId)) {
        case let .allowed(_, policy):
            effectivePolicy = policy
        case .denied, .scopeApprovalRequired:
            let promptId = UUID().uuidString
            approvalRequestId = promptId
            // `mayMessage` proved the target is in this agent's own project.
            let decision = decideScope(ScopeApprovalPrompt(
                requestId: promptId, agentId: agentId, agentDisplayName: record.displayName,
                checkout: ownHandle, checkoutDisplayName: URL(fileURLWithPath: record.checkoutRoot).lastPathComponent,
                op: .agentMessage, relativePath: nil,
                targetAgentId: childId, targetAgentDisplayName: target.displayName),
                withinCallerProject: true)
            if isCancelled() {
                operations.release(operationId: requestId)
                remember(agentId: agentId, WorkspaceRecentOperation(requestId: requestId, op: .agentMessage, outcome: "cancelledBeforeEffect"))
                return .cancelled(result: nil)
            }
            guard supervisor.records[agentId]?.workspaceToolsEnabled == true else {
                return failNothingDelivered(.permissionDenied, "Workspace tools were disabled for this agent.", approvalRequestId: promptId)
            }
            switch decision {
            case .deny:
                return failNothingDelivered(.permissionDenied, "The user declined to let this agent message that agent.", approvalRequestId: promptId)
            case .allowOnce:
                mint(WorkspaceToolGrant(
                    agentId: agentId, checkoutHandles: [ownHandle], operations: [.agentMessage],
                    presentationCeiling: WorkspaceToolGrant.phase1Ceiling,
                    issuer: .userApprovalOnce(requestId: promptId),
                    revocationGeneration: revocationGeneration(for: agentId), singleUse: true))
            case .allowForSession, .allowForProjectSession, .allowByPolicy:
                mint(WorkspaceToolGrant(
                    agentId: agentId, checkoutHandles: [ownHandle], operations: [.agentMessage],
                    presentationCeiling: WorkspaceToolGrant.phase1Ceiling,
                    issuer: Self.sessionIssuer(decision, requestId: promptId),
                    revocationGeneration: revocationGeneration(for: agentId)))
            }
            guard case let .allowed(_, policy) = WorkspaceToolGrantEvaluator.evaluate(
                agentId: agentId, op: .agentMessage, checkout: ownHandle,
                requested: request.presentationPolicy, grants: grants[agentId] ?? [],
                currentGeneration: revocationGeneration(for: agentId)) else {
                return failNothingDelivered(.permissionDenied, "Approval did not take.", approvalRequestId: promptId)
            }
            effectivePolicy = policy
        }
        consumeSingleUseGrant(agentId: agentId, checkout: ownHandle, op: .agentMessage)
        let generationAtGrant = revocationGeneration(for: agentId)

        // 5. Recheck the grant generation immediately before delivery, so a
        //    revocation that landed while the alert was up still wins.
        guard supervisor.records[agentId]?.workspaceToolsEnabled == true, revocationGeneration(for: agentId) == generationAtGrant else {
            return failNothingDelivered(.permissionDenied, "Access was revoked before the message was delivered.", approvalRequestId: approvalRequestId)
        }
        // The target must still be in reach at the moment of delivery, under the
        // setting as it is now.
        guard let caller = supervisor.records[agentId], let current = supervisor.records[childId],
              Self.mayMessage(from: caller, to: current, permission: supervisor.workspaceToolsPermission()) else {
            return .error(notYours)
        }
        let hops = messageChainHops(for: agentId) + 1
        guard hops <= Self.messageHopLimit else {
            return failNothingDelivered(.unsupported, "Array did not deliver the message: it would be agent-to-agent turn \(hops) in a row with no prompt from the user, and Array stops chains at \(Self.messageHopLimit) so agents cannot keep each other running forever. Report back to the user and let them continue.", approvalRequestId: approvalRequestId)
        }
        if isCancelled() {
            operations.release(operationId: requestId)
            remember(agentId: agentId, WorkspaceRecentOperation(requestId: requestId, op: .agentMessage, outcome: "cancelledBeforeEffect"))
            return .cancelled(result: nil)
        }
        _beforeCommitHook?()

        // 6. The known seam (`AgentSupervisor.sendRefusal`): the send path
        //    refuses unless the catalogue reports the child's harness ready AND
        //    lists its model. That is a host condition, not the model's fault
        //    and not a silent success — it is a structured `unsupported`, and
        //    nothing was delivered.
        if let refusal = supervisor.sendRefusal(for: childId) {
            return failNothingDelivered(.unsupported, "Array did not deliver the message: \(refusal)", approvalRequestId: approvalRequestId)
        }

        // 7. Busy delivery is admitted durably before it becomes a queued result.
        var result = AgentMessageResult(
            operationId: requestId, delivery: .refused, childAgentId: childId, parentAgentId: agentId,
            childName: current.humanDisplayName, childRunning: supervisor.isRunning(childId))
        let childWasRunning = supervisor.isRunning(childId)
        let context = AgentMessageQueueContext(caller: agentId, recipient: childId,
            operationId: requestId, idempotencyKey: idempotencyKey, payloadHash: payloadHash)
        let delivery = supervisor.deliverAgentMessage(text, from: agentId, to: childId, hops: hops, context: context)
        if let error = delivery.error {
            return failNothingDelivered(.durabilityFailed, error)
        }
        if delivery.delivery != .refused {
            result.delivery = delivery.delivery
            result.queuePosition = delivery.position
            result.childRunning = supervisor.isRunning(childId)
            operations.update(operationId: requestId) { op in
                op.status = .committed
                op.steps.creation = .succeeded
                op.childAgentId = childId
            }
        } else {
            let reason = supervisor.sendRefusal(for: childId)
                ?? (childWasRunning
                    ? "the child is mid-turn and its follow-up queue is unavailable."
                    : "the child's send path declined the message.")
            result.refusalReason = reason
            result.childRunning = supervisor.isRunning(childId)
            operations.update(operationId: requestId) { op in
                op.status = .failed
                op.steps.creation = .failed
                op.childAgentId = childId
                op.failureCode = "delivery_refused"
                op.failureMessage = reason
            }
        }

        // 8. Presentation: preserve-all by default (a message must not steal the
        //    user's view); only what the effective policy permits, and only while
        //    still authorized.
        if let tileId = supervisor.records[childId]?.tileId, canvas.zoneId(containing: tileId) != nil {
            _beforePresentationHook?()
            let stillAllowed = supervisor.records[agentId]?.workspaceToolsEnabled == true
                && revocationGeneration(for: agentId) == generationAtGrant
            if stillAllowed {
                let (presentation, effects) = present(
                    tileId: tileId, policy: effectivePolicy, generationAtDispatch: generationAtDispatch,
                    runtime: runtime, canvas: canvas)
                result.presentation = presentation
                result.presentationEffects = effects
            } else {
                result.presentation = .unavailable
            }
        } else {
            result.presentation = .unavailable
        }

        guard let object = Self.jsonObject(result) else {
            return .error(WorkspaceAPIError(code: .unsupported, message: "Result could not be encoded."))
        }
        if result.delivery != .refused {
            messageReplayResults[requestId] = object
            messageReplayResults = messageReplayResults.filter { operations.record(operationId: $0.key) != nil }
        }
        remember(agentId: agentId, WorkspaceRecentOperation(
            requestId: requestId, op: .agentMessage,
            outcome: result.delivery == .refused ? "refused" : result.delivery.rawValue))
        return .result(object)
    }

    // MARK: - Message reach and chains

    /// Who `agent.message` may reach. Never self, never another project (an
    /// agent with no project stamp reaches only its own checkout). Under `free`,
    /// anyone else in the project; otherwise only the caller's children and
    /// parent.
    static func mayMessage(from caller: AgentRecord, to target: AgentRecord, permission: WorkspaceToolsPermission) -> Bool {
        guard target.id != caller.id else { return false }
        guard sameProject(caller, target.projectId) || ownCheckoutHandle(caller) == ownCheckoutHandle(target) else { return false }
        if permission == .free { return true }
        return target.parentAgentID == caller.id || caller.parentAgentID == target.id
    }

    /// The most agent-started turns in a row, with no prompt from the user
    /// between them, that `agent.message` will start.
    static let messageHopLimit = 20

    /// How many agent-started turns led to this agent's CURRENT turn: zero once
    /// anything else (the user, a queued draft) has prompted it since.
    func messageChainHops(for agentId: AgentID) -> Int {
        if let hops = supervisor.startedMessageHops(for: agentId) { return hops }
        guard let chain = messageChains[agentId],
              chain.promptAt == supervisor.records[agentId]?.latestPromptAt else { return 0 }
        return chain.hops
    }

    /// Stamped right after a send succeeds, against the prompt time that send
    /// just wrote, so the next prompt from anywhere else breaks the chain.
    func recordMessageChain(target: AgentID, hops: Int) {
        messageChains[target] = MessageChain(hops: hops, promptAt: supervisor.records[target]?.latestPromptAt)
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
            grants: grants[agentId] ?? [], currentGeneration: revocationGeneration(for: agentId)) else {
            return .error(WorkspaceAPIError(code: .permissionDenied, message: "This agent may not read operations."))
        }
        // Authenticated, grant-checked read of the caller only; no queue content
        // or other agent's pending input crosses the bridge.
        if request.pendingInputOnly == true {
            return .result(["pendingInput": AnyHashableJSON(any: supervisor.helperWaitPendingInput(for: agentId).map { $0 as Any } ?? NSNull())])
        }
        do {
            if let entry = try supervisor.queuedAgentMessage(caller: agentId, key: request.idempotencyKey, operationId: request.operationId) {
                var snapshot = entry.result
                if entry.phase == .started && !supervisor.isQueuedAgentMessageActive(entry.context) && snapshot == nil {
                    snapshot = SpawnResultFile(toolCallId: entry.context.operationId,
                        status: .interrupted, agentId: entry.context.recipient.rawValue,
                        reason: "The app restarted after message start; delivery outcome is unknown and will not be replayed.",
                        turnIdentity: "uncertain:\(entry.message.id.uuidString)", recipientId: agentId.rawValue)
                }
                let childResult: OperationChildResult?
                if let snapshot, let cwd = supervisor.records[agentId]?.cwd {
                    childResult = try SpawnResultFile.collect(parentCwd: cwd, handle: entry.context.operationId,
                        recipient: agentId.rawValue, requestId: requestId, receipt: request.deliveryReceipt,
                        acknowledge: request.acknowledgeDelivery == true, now: supervisor.helperCompletionNow(),
                        snapshot: snapshot,
                        // One channel: a push lead gets a pointer here, never the body.
                        pushed: supervisor.resultDelivery(for: agentId) == .push).map(childResultForParent)
                } else { childResult = nil }
                let result = OperationGetResult(operationId: entry.context.operationId, op: .agentMessage,
                    status: .committed, steps: nil, childAgentId: entry.context.recipient, tileId: nil,
                    childRunning: entry.phase == .queued || (entry.phase == .started && childResult == nil),
                    createdAt: entry.message.queuedAt, childResult: childResult)
                return .result(Self.jsonObject(result) ?? [:])
            }
        } catch {
            return .error(WorkspaceAPIError(code: .outcomeUnknown, message: "Helper delivery storage or receipt unavailable; retry the same lookup request."))
        }
        let lookup: WorkspaceOperationStore.Lookup
        if let operationId = request.operationId, !operationId.isEmpty {
            lookup = operations.lookup(agentId: agentId, operationId: operationId)
        } else if let key = request.idempotencyKey, !key.isEmpty {
            lookup = operations.lookup(agentId: agentId, idempotencyKey: key)
        } else {
            return .error(WorkspaceAPIError(code: .invalidRequest, message: "operationId or idempotencyKey is required."))
        }
        func collect(_ cwd: String, _ handle: String) throws -> OperationChildResult? {
            try SpawnResultFile.collect(parentCwd: cwd, handle: handle, recipient: agentId.rawValue,
                requestId: requestId, receipt: request.deliveryReceipt, acknowledge: request.acknowledgeDelivery == true,
                now: supervisor.helperCompletionNow(),
                pushed: supervisor.resultDelivery(for: agentId) == .push).map(childResultForParent)
        }
        do {
        let result: OperationGetResult
        switch lookup {
        case let .found(record):
            var childRunning = record.childAgentId.map { supervisor.records[$0] != nil && supervisor.isRunning($0) }
            // A delegation's operationId IS its spawn-result handle (step 6 of
            // `delegate`), so an idle child's settled answer is the courier the
            // supervisor wrote under the PARENT's cwd. The same channel pi's
            // `wait_agents` reads; the MCP `wait_agents` polls this instead.
            var childResult: OperationChildResult?
            if record.op == .agentDelegate, childRunning == false, let parentCwd = supervisor.records[agentId]?.cwd {
                childResult = try collect(parentCwd, record.operationId)
            }
            if record.op == .agentMessage, let cwd = supervisor.records[agentId]?.cwd,
               let file = SpawnResultFile.read(parentCwd: cwd, handle: record.operationId), file.status != .spawned {
                childResult = try collect(cwd, record.operationId)
                childRunning = false
            }
            result = OperationGetResult(
                operationId: record.operationId, op: record.op, status: record.status, steps: record.steps,
                childAgentId: record.childAgentId, tileId: record.tileId,
                childRunning: childRunning,
                failureCode: record.failureCode, failureMessage: record.failureMessage, createdAt: record.createdAt,
                childResult: childResult,
                deviceBuild: record.op == .deviceBuildRun ? deviceBuildResult(operationId: record.operationId, agentId: agentId, checkout: ownHandle) : nil)
        case let .expired(tombstone):
            result = OperationGetResult(
                operationId: tombstone.operationId, op: nil, status: .expired, steps: nil,
                childAgentId: tombstone.childAgentId, tileId: nil,
                childRunning: tombstone.childAgentId.map { supervisor.records[$0] != nil && supervisor.isRunning($0) },
                failureCode: "expired",
                failureMessage: "This operation was evicted from the host's bounded store. Its outcome is unknown here; do not repeat the request.")
        case .unknown:
            // Legacy Pi spawn handles have no operation-store record. The host
            // still authenticates their recipient before exposing any courier.
            guard let handle = request.operationId, let cwd = supervisor.records[agentId]?.cwd,
                  let file = SpawnResultFile.read(parentCwd: cwd, handle: handle),
                  file.recipientId == agentId.rawValue else {
                return .error(WorkspaceAPIError(code: .notFound, message: "No operation of yours matches that id."))
            }
            if let helper = file.agentId {
                guard let child = supervisor.records[AgentID(rawValue: helper)],
                      child.parentAgentID == agentId, child.spawnResultHandle == handle else {
                    return .error(WorkspaceAPIError(code: .notFound, message: "No operation of yours matches that id."))
                }
            } else if file.status != .refused {
                return .error(WorkspaceAPIError(code: .notFound, message: "No operation of yours matches that id."))
            }
            result = OperationGetResult(operationId: handle, op: .agentDelegate, status: .committed, steps: nil,
                childAgentId: file.agentId.map(AgentID.init(rawValue:)), tileId: nil,
                childRunning: file.status == .spawned, failureCode: nil, failureMessage: nil, createdAt: nil,
                childResult: try collect(cwd, handle))
        }
        guard let object = Self.jsonObject(result) else {
            return .error(WorkspaceAPIError(code: .unsupported, message: "Result could not be encoded."))
        }
        return .result(object)
        } catch {
            return .error(WorkspaceAPIError(code: .outcomeUnknown, message: "Helper delivery storage or receipt unavailable; retry the same lookup request."))
        }
    }

    // MARK: - Helpers

    /// The key binds the TEXT: the same key with different text is a conflict,
    /// never a second delivery. The presentation policy is deliberately part of
    /// the normalized payload for the same reason the delegate hash is.
    private static func messagePayloadHash(_ request: AgentMessageRequest) -> String {
        var normalized = request
        normalized.idempotencyKey = nil
        guard let data = try? encoder.encode(normalized) else { return UUID().uuidString }
        return String(decoding: data, as: UTF8.self)
    }

    /// Claimed paths (the new contract's plus its live siblings') above which
    /// the overlap comparison is skipped and the result says so; measured to
    /// stay near a millisecond on the main actor (about 0.35 µs a path, optimized).
    static let overlapClaimBudget = 3_000

    private static func payloadHash(_ request: AgentDelegateRequest) -> String {
        var normalized = request
        normalized.idempotencyKey = nil
        guard let data = try? encoder.encode(normalized) else { return UUID().uuidString }
        return String(decoding: data, as: UTF8.self)
    }

    /// Op-aware twin of the open path's `consumeSingleUseGrant`.
    private func consumeSingleUseGrant(agentId: AgentID, checkout: CheckoutHandle, op: WorkspaceAPIOp) {
        guard var live = grants[agentId] else { return }
        let durable = live.contains { !$0.singleUse && $0.checkoutHandles.contains(checkout) && $0.operations.contains(op) && $0.revocationGeneration == revocationGeneration(for: agentId) }
        guard !durable, let index = live.firstIndex(where: { $0.singleUse && $0.checkoutHandles.contains(checkout) && $0.operations.contains(op) }) else { return }
        live.remove(at: index)
        grants[agentId] = live
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
