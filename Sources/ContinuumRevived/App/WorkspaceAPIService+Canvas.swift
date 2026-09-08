import AppKit
import ContinuumRevivedCore
import Foundation

// CX-01 Phase 4 (`.plans/59`, §14.2 / §14.3): the geometry slice of the host
// pipeline. `canvas.query` is a scoped, paginated read over the SAME projection
// `workspace.context` uses (`snapshot(runtime:canvas:records:)`); `canvas.apply`
// is one validated move or resize through the pointer's own owner route
// (`CanvasNSView.applyProgrammaticTileGeometry`). Both are entered only through
// `dispatch`, after the caller's policy and principal have been established.
extension WorkspaceAPIService {

    // MARK: - canvas.query (§7.2)

    func canvasQuery(
        agentId: AgentID, record: AgentRecord, ownHandle: CheckoutHandle,
        payload: [String: Any], runtime: WorkspaceRuntime, canvas: CanvasNSView
    ) -> Reply {
        let request: CanvasQueryRequest
        do {
            let data = try JSONSerialization.data(withJSONObject: payload)
            request = try JSONDecoder().decode(CanvasQueryRequest.self, from: data)
        } catch {
            return .error(WorkspaceAPIError(code: .invalidRequest, message: "The query could not be decoded: \(error.localizedDescription)"))
        }
        // Scope: the caller's own checkout unless an explicit handle is covered by
        // a grant. An unknown or uncovered handle is a permission_denied that
        // names nothing (§14.4).
        let handle = request.checkoutHandle ?? ownHandle
        guard case .allowed = WorkspaceToolGrantEvaluator.evaluate(
            agentId: agentId, op: .canvasQuery, checkout: handle, requested: .preserveAll,
            grants: grants[agentId] ?? [], currentGeneration: revocationGeneration) else {
            return .error(WorkspaceAPIError(code: .permissionDenied, message: "This agent may not query that checkout's canvas."))
        }
        let known = knownCheckouts()
        guard let projectId = (handle == ownHandle ? record.projectId : nil) ?? known[handle]?.projectId else {
            return .error(WorkspaceAPIError(code: .permissionDenied, message: "This agent may not query that checkout's canvas."))
        }
        let structure = runtime.structuralRevision
        let revision = WorkspaceRevision(epoch: epoch, structure: structure)

        let offset: Int
        switch CanvasQueryPage.resolveCursor(request.cursor, currentStructure: structure) {
        case let .start(value): offset = value
        case .malformed: return .error(WorkspaceAPIError(code: .invalidRequest, message: "The cursor is not one Array issued."))
        case .expired: return .error(WorkspaceAPIError(code: .cursorExpired, message: "The canvas changed since this cursor was issued. Restart the query."))
        }

        let projection: CanvasEntityIndexSnapshot
        switch Self.snapshot(runtime: runtime, canvas: canvas, records: Array(supervisor.records.values)) {
        case let .success(value): projection = value
        case let .failure(error): return .error(error)
        }
        // Zones in document z-order so paging is stable; the projection's zone
        // list is what `renderedZonesInZOrder` painted, which is the same order.
        let projectZones = projection.zones.filter { $0.projectId == projectId }
        if let zoneId = request.zoneId, !projectZones.contains(where: { $0.id == zoneId }) {
            return .error(WorkspaceAPIError(code: .notFound, message: "No such zone in that checkout's project."))
        }
        let scopedZones = projectZones.filter { request.zoneId == nil || $0.id == request.zoneId }
        let installed = canvas.installedZoneIds(forProjectId: projectId)
        let coverage = WorkspaceCoverage(
            installedZoneIds: scopedZones.filter { installed.contains($0.id) }.map(\.id),
            unhydratedZoneIds: scopedZones.filter { !installed.contains($0.id) }.map(\.id))

        var items: [CanvasQueryItem] = scopedZones.map { zone in
            .zone(CanvasQueryZone(
                zoneId: zone.id, projectId: zone.projectId,
                worldRect: zone.frame ?? CanvasWorldRect(x: 0, y: 0, width: 0, height: 0),
                hydrated: installed.contains(zone.id), collapsed: zone.isCollapsed))
        }
        let scopedZoneIds = Set(scopedZones.map(\.id))
        let tiles = projection.tiles
            .filter { tile in tile.zoneId.map { scopedZoneIds.contains($0) } == true }
            .sorted { lhs, rhs in
                let li = scopedZones.firstIndex { $0.id == lhs.zoneId } ?? 0
                let ri = scopedZones.firstIndex { $0.id == rhs.zoneId } ?? 0
                return li != ri ? li < ri : lhs.id.uuidString < rhs.id.uuidString
            }
        items += tiles.map { tile in
            .tile(CanvasQueryTile(
                tileId: tile.id, kind: tile.kind.rawValue, zoneId: tile.zoneId!,
                worldRect: tile.worldFrame, title: tile.label.isEmpty ? nil : tile.label))
        }

        func response(_ page: [CanvasQueryItem], next: String?, truncated: Bool) -> CanvasQueryResponse {
            var zones: [CanvasQueryZone] = []
            var pageTiles: [CanvasQueryTile] = []
            for item in page {
                switch item {
                case let .zone(zone): zones.append(zone)
                case let .tile(tile): pageTiles.append(tile)
                }
            }
            return CanvasQueryResponse(
                checkoutHandle: handle, projectId: projectId, revision: revision, coverage: coverage,
                zones: zones, tiles: pageTiles, nextCursor: next, truncated: truncated)
        }
        let page = CanvasQueryPage.page(
            items: items, offset: offset, limit: CanvasQueryPage.clampedLimit(request.limit), structure: structure,
            encodedSize: { candidate in (try? Self.encoder.encode(response(candidate, next: "", truncated: true)))?.count ?? Int.max })
        guard let object = Self.jsonObject(response(page.items, next: page.nextCursor, truncated: page.truncated)) else {
            return .error(WorkspaceAPIError(code: .unsupported, message: "The page could not be encoded."))
        }
        return .result(object)
    }

    // MARK: - canvas.apply (§14.2 pipeline)

    func canvasApply(
        agentId: AgentID, record: AgentRecord, ownHandle: CheckoutHandle, requestId: String,
        payload: [String: Any], runtime: WorkspaceRuntime, canvas: CanvasNSView,
        isCancelled: () -> Bool
    ) -> Reply {
        // 1. Schema.
        let request: CanvasApplyRequest
        do {
            let data = try JSONSerialization.data(withJSONObject: payload)
            request = try JSONDecoder().decode(CanvasApplyRequest.self, from: data)
        } catch {
            return .error(WorkspaceAPIError(code: .invalidRequest, message: "The apply request could not be decoded: \(error.localizedDescription)"))
        }

        // 2. Idempotency: same key + same payload replays the remembered outcome;
        //    same key + different payload is a new intent behind an old key.
        let idempotencyKey = request.idempotencyKey ?? requestId
        var normalized = request
        normalized.idempotencyKey = nil
        let payloadHash = (try? Self.encoder.encode(normalized)).map { String(decoding: $0, as: UTF8.self) } ?? UUID().uuidString
        if let cached = canvasApplyIdempotency[agentId]?[idempotencyKey] {
            guard cached.payloadHash == payloadHash else {
                return .error(WorkspaceAPIError(code: .idempotencyConflict, message: "This idempotencyKey was already used with a different request. New intent needs a new key."))
            }
            guard let object = Self.jsonObject(cached.result) else {
                return .error(WorkspaceAPIError(code: .unsupported, message: "Cached result could not be encoded."))
            }
            return .result(object)
        }

        // 3. Target: exactly one installed layer of the caller's OWN project. A
        //    zone of another project is a permission_denied that names nothing;
        //    a tile of the caller's project that no layer owns is unhydrated.
        let known = knownCheckouts()
        guard let ownProjectId = record.projectId ?? known[ownHandle]?.projectId else {
            return .error(WorkspaceAPIError(code: .permissionDenied, message: "This agent's checkout is not a project in this workspace."))
        }
        let occurrences = canvas.installedZoneIds(containing: request.tileId)
        if occurrences.contains(where: { canvas.projectId(forZone: $0) != ownProjectId }) {
            return .error(WorkspaceAPIError(code: .permissionDenied, message: "This agent may not change that tile."))
        }
        if occurrences.count > 1 {
            return .error(WorkspaceAPIError(code: .unsupported, message: "duplicate_occurrence"))
        }
        guard let zoneId = occurrences.first else {
            // Not installed anywhere. Consult the project's own store to tell an
            // unhydrated member from a tile that does not exist.
            if let root = known[ownHandle]?.root ?? known.values.first(where: { $0.projectId == ownProjectId })?.root,
               let persisted = try? ProjectStore(projectRoot: root).tryLoadCanvas(),
               let tile = persisted.tiles.first(where: { $0.id == request.tileId }) {
                if let stampedZone = tile.zoneId,
                   runtime.document.zones.contains(where: { $0.zoneId == stampedZone && $0.projectId != ownProjectId }) {
                    return .error(WorkspaceAPIError(code: .permissionDenied, message: "This agent may not change that tile."))
                }
                return .error(WorkspaceAPIError(code: .unsupported, message: "zone_unhydrated"))
            }
            return .error(WorkspaceAPIError(code: .notFound, message: "No tile with that id in this agent's project."))
        }

        // 4. Grant. `canvas.apply` is never in the session preset: the first use
        //    for a checkout goes through the trusted approval UI; "allow once" is
        //    spent by this request whatever it then does.
        var approvalRequestId: String?
        var verdict = WorkspaceToolGrantEvaluator.evaluate(
            agentId: agentId, op: .canvasApply, checkout: ownHandle, requested: .preserveAll,
            grants: grants[agentId] ?? [], currentGeneration: revocationGeneration)
        if case .allowed = verdict {} else {
            let promptId = UUID().uuidString
            approvalRequestId = promptId
            approvalPromptCount += 1
            let decision = approvalHandler(ScopeApprovalPrompt(
                requestId: promptId, agentId: agentId, agentDisplayName: record.displayName,
                checkout: ownHandle, checkoutDisplayName: known[ownHandle]?.displayName ?? record.displayName,
                op: .canvasApply, relativePath: nil))
            guard supervisor.records[agentId]?.workspaceToolsEnabled == true else {
                return .error(WorkspaceAPIError(code: .permissionDenied, message: "Workspace tools were disabled for this agent.", approvalRequestId: promptId))
            }
            switch decision {
            case .deny:
                return .error(WorkspaceAPIError(code: .scopeApprovalRequired, message: "The user has not allowed this agent to move or resize tiles. Nothing was applied.", approvalRequestId: promptId))
            case .allowOnce:
                mint(WorkspaceToolGrant(
                    agentId: agentId, checkoutHandles: [ownHandle], operations: [.canvasApply],
                    presentationCeiling: .preserveAll, issuer: .userApprovalOnce(requestId: promptId),
                    revocationGeneration: revocationGeneration, singleUse: true))
            case .allowForSession:
                mint(WorkspaceToolGrant(
                    agentId: agentId, checkoutHandles: [ownHandle], operations: [.canvasApply],
                    presentationCeiling: .preserveAll, issuer: .userApprovalSession(requestId: promptId),
                    revocationGeneration: revocationGeneration))
            }
            verdict = WorkspaceToolGrantEvaluator.evaluate(
                agentId: agentId, op: .canvasApply, checkout: ownHandle, requested: .preserveAll,
                grants: grants[agentId] ?? [], currentGeneration: revocationGeneration)
            guard case .allowed = verdict else {
                return .error(WorkspaceAPIError(code: .permissionDenied, message: "Approval did not take.", approvalRequestId: promptId))
            }
        }
        consumeSingleUseApplyGrant(agentId: agentId, checkout: ownHandle)
        let generationAtGrant = revocationGeneration

        // 5. Revision, gesture, constraints — before any effect.
        func preflight() -> WorkspaceAPIError? {
            let current = WorkspaceRevision(epoch: epoch, structure: runtime.structuralRevision)
            guard request.expectedRevision.matches(current) else {
                return WorkspaceAPIError(code: .revisionConflict, message: "expectedRevision \(request.expectedRevision.structure) does not match the current structure \(current.structure). Re-query before writing.", approvalRequestId: approvalRequestId)
            }
            if canvas.isGeometryGestureActive {
                return WorkspaceAPIError(code: .targetConflict, message: "gesture_active: the user is moving or resizing on the canvas. Wait, re-query, and try again.", approvalRequestId: approvalRequestId)
            }
            return nil
        }
        if let error = preflight() { return .error(error) }
        guard let currentTile = canvas.tilesInWorldFrames(forZoneId: zoneId)?.first(where: { $0.id == request.tileId }) else {
            return .error(WorkspaceAPIError(code: .notFound, message: "The tile left its zone while the request was being validated."))
        }
        let minimum = CanvasEngine.minimumFrame(for: currentTile.kind)
        let plan: CanvasGeometryConstraints.Plan
        switch CanvasGeometryConstraints.plan(
            request, currentWorldFrame: CanvasWorldRect(currentTile.frame),
            minimumSize: CanvasWorldSize(width: minimum.width, height: minimum.height)) {
        case let .success(value): plan = value
        case let .failure(rejection): return .error(WorkspaceAPIError(code: .invalidRequest, message: rejection.description, approvalRequestId: approvalRequestId))
        }

        // 6. Commit through the owner route. The hook is a checks-only seam; the
        //    rechecks after it are the production guard against anything that ran
        //    between validation and mutation (§14.2: validate and apply are
        //    serialized with native mutations, never checked-then-applied later).
        _beforeCommitHook?()
        if isCancelled() {
            remember(agentId: agentId, WorkspaceRecentOperation(requestId: requestId, op: .canvasApply, outcome: "cancelledBeforeEffect", tileId: request.tileId))
            return .cancelled(result: nil)
        }
        guard supervisor.records[agentId]?.workspaceToolsEnabled == true, revocationGeneration == generationAtGrant else {
            return .error(WorkspaceAPIError(code: .permissionDenied, message: "Workspace tools were revoked before the change was applied.", approvalRequestId: approvalRequestId))
        }
        if let error = preflight() { return .error(error) }
        let target = TileFrame(x: plan.target.x, y: plan.target.y, width: plan.target.width, height: plan.target.height)
        let outcome = canvas.applyProgrammaticTileGeometry(
            tileId: request.tileId, in: zoneId, worldFrame: target,
            action: request.op == .move ? .moveTile : .resizeTile)

        let durability: CanvasApplyResult.Durability
        var undoRegistered = false
        switch outcome {
        case let .committed(undoRecorded):
            durability = .committed
            undoRegistered = undoRecorded
        case .unchanged:
            durability = .unchanged
        case .gestureActive:
            return .error(WorkspaceAPIError(code: .targetConflict, message: "gesture_active: the user began a gesture as the change was applied. Nothing was applied.", approvalRequestId: approvalRequestId))
        case .notInstalled:
            return .error(WorkspaceAPIError(code: .unsupported, message: "zone_unhydrated"))
        case .persistenceFailed:
            remember(agentId: agentId, WorkspaceRecentOperation(requestId: requestId, op: .canvasApply, outcome: "durabilityFailed", tileId: request.tileId))
            return .error(WorkspaceAPIError(code: .outcomeUnknown, message: "durability_failed: the canvas could not be saved, so the change was rolled back. Re-query before retrying.", approvalRequestId: approvalRequestId))
        }

        // 7. Report the ACTUAL geometry, the new revision, and no presentation.
        let actual = canvas.tilesInWorldFrames(forZoneId: canvas.zoneId(containing: request.tileId) ?? zoneId)?
            .first(where: { $0.id == request.tileId })?.frame ?? currentTile.frame
        let result = CanvasApplyResult(
            operationId: requestId, op: request.op, tileId: request.tileId,
            requestedWorldRect: plan.requested, actualWorldRect: CanvasWorldRect(actual),
            actualZoneId: canvas.zoneId(containing: request.tileId), clamped: plan.clamped,
            durability: durability, undoRegistered: undoRegistered,
            revision: WorkspaceRevision(epoch: epoch, structure: runtime.structuralRevision))
        remember(agentId: agentId, WorkspaceRecentOperation(
            requestId: requestId, op: .canvasApply, outcome: durability.rawValue, tileId: request.tileId))
        canvasApplyIdempotency[agentId, default: [:]][idempotencyKey] = CachedCanvasApply(payloadHash: payloadHash, result: result)
        canvasApplyIdempotencyOrder[agentId, default: []].append(idempotencyKey)
        while (canvasApplyIdempotencyOrder[agentId]?.count ?? 0) > Self.idempotencyCapacity {
            let evicted = canvasApplyIdempotencyOrder[agentId]!.removeFirst()
            canvasApplyIdempotency[agentId]?[evicted] = nil
        }
        guard let object = Self.jsonObject(result) else {
            return .error(WorkspaceAPIError(code: .unsupported, message: "Result could not be encoded."))
        }
        return .result(object)
    }

    /// Mirror of `consumeSingleUseGrant` for the apply op: a once-grant is spent
    /// by the request it authorized unless a durable grant also covers it.
    private func consumeSingleUseApplyGrant(agentId: AgentID, checkout: CheckoutHandle) {
        guard var live = grants[agentId] else { return }
        let durable = live.contains { !$0.singleUse && $0.checkoutHandles.contains(checkout) && $0.operations.contains(.canvasApply) && $0.revocationGeneration == revocationGeneration }
        guard !durable, let index = live.firstIndex(where: { $0.singleUse && $0.checkoutHandles.contains(checkout) && $0.operations.contains(.canvasApply) }) else { return }
        live.remove(at: index)
        grants[agentId] = live
    }
}
