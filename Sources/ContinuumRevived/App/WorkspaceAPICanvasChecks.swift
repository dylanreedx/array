import AppKit
import ContinuumRevivedCore
import Foundation

/// CX-01 Phase 4 (`.plans/59`) — `canvas.query` and `canvas.apply` through the
/// PRODUCTION mount and the PRODUCTION dispatch entry, on the Phase 1 fixture
/// (`WorkspaceAPIChecks.makeFixture`): the source agent's checkout Pb sits in
/// zoneB — pinned live, NOT armed, non-zero origin (3000,400) — with a second Pb
/// zone (zoneB2) that has no layer at all.
///
/// `--workspace-api-canvas-check`:
///   Q1 scoped query: Pb zones only, zoneB hydrated, zoneB2 unhydrated with no
///      tiles, coverage incomplete, every tile frame WORLD, page under the ceiling;
///   Q2 pagination: limit 2 → cursor → union equals the whole stream; a foreign
///      zone filter is not_found; a zoneB2 filter lists the zone and zero tiles;
///   A1 grant: the first apply prompts (op canvas.apply); deny →
///      scope_approval_required and nothing moves; allow-for-session → no
///      further prompts;
///   A2 move in zoneB: live WORLD frame == result.actualWorldRect, the store
///      holds that WORLD frame, every untouched tile and unhydrated `hiddenB`
///      survive, structural revision +1, camera/focus/selection/armed zone/
///      interaction generation untouched, undo recorded;
///   A3 stale expectedRevision → revision_conflict, nothing moved or written;
///   A4 gesture active (a real `beginGeometryEdit`) → target_conflict
///      gesture_active, nothing applied;
///   A5 unhydrated target → unsupported zone_unhydrated;
///   A6 another checkout's tile → permission_denied;
///   A7 resize below the kind minimum → clamped to it, as the pointer path does;
///   A8 idempotency: replay returns the same result without a second effect;
///      a changed payload under the old key is idempotency_conflict;
///   A9 the pre-apply cursor is now cursor_expired; non-finite / out-of-bounds
///      frames are invalid_request.
@MainActor
enum WorkspaceAPICanvasChecks {
    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
        var localizedDescription: String { message }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(message: message) }
    }

    private static var requestCounter = 0
    private static func nextRequestId() -> String { requestCounter += 1; return "canvas-req-\(requestCounter)" }

    private static func result(_ reply: WorkspaceAPIService.Reply, _ what: String) throws -> [String: AnyHashableJSON] {
        guard case let .result(object) = reply else { throw Failure(message: "\(what): expected a result, got \(reply)") }
        return object
    }

    private static func error(_ reply: WorkspaceAPIService.Reply, _ code: WorkspaceAPIError.Code, _ what: String) throws -> WorkspaceAPIError {
        guard case let .error(error) = reply else { throw Failure(message: "\(what): expected \(code.rawValue), got \(reply)") }
        try expect(error.code == code, "\(what): expected \(code.rawValue), got \(error.code.rawValue) (\(error.message))")
        return error
    }

    private static func query(_ f: WorkspaceAPIChecks.Fixture, _ payload: [String: Any]) -> WorkspaceAPIService.Reply {
        f.api.dispatch(agentId: f.agentId, requestId: nextRequestId(), op: "canvas.query", payload: payload)
    }

    private static func apply(_ f: WorkspaceAPIChecks.Fixture, _ payload: [String: Any], requestId: String? = nil) -> WorkspaceAPIService.Reply {
        f.api.dispatch(agentId: f.agentId, requestId: requestId ?? nextRequestId(), op: "canvas.apply", payload: payload)
    }

    private static func revision(_ f: WorkspaceAPIChecks.Fixture, structure: UInt64? = nil) -> [String: Any] {
        ["epoch": f.api.epoch, "structure": structure ?? f.runtime.structuralRevision]
    }

    private static func uuid(_ value: AnyHashableJSON?) -> UUID? { value?.string.flatMap(UUID.init(uuidString:)) }

    private static func rect(_ value: AnyHashableJSON?) -> TileFrame? {
        guard let object = value?.object,
              let x = (object["x"]?.value as? NSNumber)?.doubleValue, let y = (object["y"]?.value as? NSNumber)?.doubleValue,
              let w = (object["width"]?.value as? NSNumber)?.doubleValue, let h = (object["height"]?.value as? NSNumber)?.doubleValue
        else { return nil }
        return TileFrame(x: x, y: y, width: w, height: h)
    }

    private static func liveWorldFrame(_ f: WorkspaceAPIChecks.Fixture, _ tileId: UUID) -> TileFrame? {
        f.canvas.zoneId(containing: tileId).flatMap { f.canvas.tilesInWorldFrames(forZoneId: $0) }?.first(where: { $0.id == tileId })?.frame
    }

    private static func zoneBWorldFrames(_ f: WorkspaceAPIChecks.Fixture) -> [UUID: TileFrame] {
        Dictionary(uniqueKeysWithValues: (f.canvas.tilesInWorldFrames(forZoneId: f.zoneB) ?? []).map { ($0.id, $0.frame) })
    }

    private static func persistedFrames(_ f: WorkspaceAPIChecks.Fixture) throws -> [UUID: TileFrame] {
        Dictionary(uniqueKeysWithValues: try f.storePb.loadCanvas().tiles.map { ($0.id, $0.frame) })
    }

    private struct Baselines {
        let armed: UUID?
        let viewportApplies: Int
        let focus: FocusSurfaceID?
        let selection: UUID?
        let generation: UInt64
        let structure: UInt64
        let live: [UUID: TileFrame]
        let persisted: [UUID: TileFrame]
    }

    private static func baselines(_ f: WorkspaceAPIChecks.Fixture) throws -> Baselines {
        Baselines(armed: f.canvas.armedZoneId, viewportApplies: f.canvas.qaViewportApplyCount,
                  focus: f.focusBroker.activeSurface, selection: f.canvas.canvasState.lastActiveTileId,
                  generation: f.runtime.interactionGeneration, structure: f.runtime.structuralRevision,
                  live: zoneBWorldFrames(f), persisted: try persistedFrames(f))
    }

    private static func expectPresentationUntouched(_ f: WorkspaceAPIChecks.Fixture, _ before: Baselines, _ what: String) throws {
        try expect(f.canvas.armedZoneId == before.armed, "\(what): the armed zone must not change")
        try expect(f.canvas.qaViewportApplyCount == before.viewportApplies, "\(what): the camera must not move")
        try expect(f.focusBroker.activeSurface == before.focus, "\(what): keyboard focus must not change")
        try expect(f.canvas.canvasState.lastActiveTileId == before.selection, "\(what): the selection must not change")
        try expect(f.runtime.interactionGeneration == before.generation, "\(what): the interaction generation must not change")
    }

    private static func expectNothingApplied(_ f: WorkspaceAPIChecks.Fixture, _ before: Baselines, _ what: String) throws {
        try expect(zoneBWorldFrames(f) == before.live, "\(what): no live frame may change")
        let onDisk = try persistedFrames(f)
        try expect(onDisk == before.persisted, "\(what): the store must not be written")
        try expect(f.runtime.structuralRevision == before.structure, "\(what): the structural revision must not bump")
        try expectPresentationUntouched(f, before, what)
    }

    static func run() throws {
        let f = try WorkspaceAPIChecks.makeFixture()
        defer { f.tearDown() }
        try expect(f.delegate.qaAgentSupervisor.setWorkspaceToolsEnabled(agentID: f.agentId, true), "enable the policy")
        let original = try persistedFrames(f)
        // 240x160 is `TileGeometry.minimumSize(for: .note)`: the store's own
        // sanitation raises the fixture's 220x140 on load, which is exactly the
        // frame every later assertion must find unchanged.
        try expect(original.count == 5 && original[f.hiddenB] == TileFrame(x: 9040, y: 9040, width: 240, height: 160), "fixture: Pb's canvas.json holds five WORLD-framed tiles, got \(original)")

        // Q1 — scoped read.
        let q1 = try result(query(f, [:]), "default query")
        let q1Zones = q1["zones"]?.array ?? []
        let q1Tiles = q1["tiles"]?.array ?? []
        try expect(Set(q1Zones.compactMap { uuid($0.object?["zoneId"]) }) == [f.zoneB, f.zoneB2], "Q1: exactly the caller's project zones, got \(q1Zones)")
        let zoneBEntry = q1Zones.first { uuid($0.object?["zoneId"]) == f.zoneB }?.object
        let zoneB2Entry = q1Zones.first { uuid($0.object?["zoneId"]) == f.zoneB2 }?.object
        try expect(zoneBEntry?["hydrated"]?.bool == true && zoneBEntry?["stale"]?.bool == false && rect(zoneBEntry?["worldRect"]) == TileFrame(x: 3000, y: 400, width: 1400, height: 1000),
                   "Q1: zoneB is hydrated with its world rect, got \(String(describing: zoneBEntry))")
        try expect(zoneB2Entry?["hydrated"]?.bool == false && zoneB2Entry?["stale"]?.bool == true, "Q1: zoneB2 is reported unhydrated and stale")
        try expect(q1Tiles.count == 4 && q1Tiles.allSatisfy { uuid($0.object?["zoneId"]) == f.zoneB }, "Q1: four zoneB tiles and none for the unhydrated zone, got \(q1Tiles.count)")
        let agentEntry = q1Tiles.first { uuid($0.object?["tileId"]) == f.agentTileB }?.object
        try expect(rect(agentEntry?["worldRect"]) == TileFrame(x: 3040, y: 440, width: 240, height: 160) && agentEntry?["kind"]?.string == "note",
                   "Q1: tile frames are WORLD (zone origin added back), got \(String(describing: agentEntry))")
        let coverage = q1["coverage"]?.object
        try expect(coverage?["complete"]?.bool == false && coverage?["unhydratedZoneIds"]?.array?.compactMap(uuid) == [f.zoneB2], "Q1: coverage names zoneB2 as unhydrated")
        try expect(q1["revision"]?.object?["structure"]?.int == Int(f.runtime.structuralRevision) && q1["nextCursor"] == nil, "Q1: revision carried, single page")
        let q1Bytes = try JSONSerialization.data(withJSONObject: WorkspaceAPIService.plain(q1)).count
        try expect(q1Bytes <= CanvasQueryPage.encodedByteCeiling, "Q1: the page must respect the byte ceiling (\(q1Bytes))")

        // Q2 — pagination and filters.
        let page1 = try result(query(f, ["limit": 2]), "page 1")
        guard let cursor1 = page1["nextCursor"]?.string else { throw Failure(message: "Q2: two of six items must leave a cursor: \(page1)") }
        try expect((page1["zones"]?.array?.count ?? 0) + (page1["tiles"]?.array?.count ?? 0) == 2, "Q2: page 1 holds two items")
        var seen: [UUID] = (page1["zones"]?.array ?? []).compactMap { uuid($0.object?["zoneId"]) } + (page1["tiles"]?.array ?? []).compactMap { uuid($0.object?["tileId"]) }
        var cursor: String? = cursor1
        var pages = 1
        while let next = cursor {
            let page = try result(query(f, ["limit": 2, "cursor": next]), "page \(pages + 1)")
            pages += 1
            seen += (page["zones"]?.array ?? []).compactMap { uuid($0.object?["zoneId"]) } + (page["tiles"]?.array ?? []).compactMap { uuid($0.object?["tileId"]) }
            cursor = page["nextCursor"]?.string
            try expect(pages <= 4, "Q2: pagination must terminate")
        }
        let wholeStream = Set([f.zoneB, f.zoneB2]).union(Set(q1Tiles.compactMap { uuid($0.object?["tileId"]) }))
        try expect(pages == 3 && Set(seen) == wholeStream && seen.count == 6,
                   "Q2: three pages of two reproduce the whole stream exactly once, got \(seen)")
        _ = try error(query(f, ["cursor": "not-a-cursor"]), .invalidRequest, "Q2: a foreign cursor")
        _ = try error(query(f, ["zoneId": f.zoneA.uuidString]), .notFound, "Q2: another project's zone as a filter")
        let onlyB2 = try result(query(f, ["zoneId": f.zoneB2.uuidString]), "zoneB2 filter")
        try expect(onlyB2["zones"]?.array?.count == 1 && onlyB2["tiles"]?.array?.isEmpty == true && onlyB2["coverage"]?.object?["complete"]?.bool == false,
                   "Q2: an unhydrated zone lists itself, zero tiles and incomplete coverage — never an empty proof")
        _ = try error(query(f, ["checkoutHandle": f.paHandle.rawValue]), .permissionDenied, "Q2: another checkout without a grant")

        // A1 — grants. Deny first: nothing moves and the caller learns why.
        var prompts: [WorkspaceAPIService.ScopeApprovalPrompt] = []
        var decisions: [WorkspaceAPIService.ScopeApprovalDecision] = []
        f.api.approvalHandler = { prompt in
            prompts.append(prompt)
            return decisions.isEmpty ? .deny : decisions.removeFirst()
        }
        let before = try baselines(f)
        let moveTarget: [String: Any] = ["x": 4100, "y": 500, "width": 240, "height": 160]
        let denied = try error(apply(f, ["op": "move", "tileId": f.agentTileB.uuidString, "worldFrame": moveTarget, "expectedRevision": revision(f)]), .scopeApprovalRequired, "A1: first apply, user declines")
        try expect(prompts.count == 1 && prompts[0].op == .canvasApply && prompts[0].checkout == f.pbHandle && prompts[0].agentId == f.agentId && denied.approvalRequestId == prompts[0].requestId,
                   "A1: geometry is never in the preset — the trusted prompt ran for canvas.apply on the agent's own checkout: \(prompts)")
        try expectNothingApplied(f, before, "A1 denied")

        // A2 — the move, allowed for the session.
        decisions = [.allowForSession]
        let moved = try result(apply(f, ["op": "move", "tileId": f.agentTileB.uuidString, "worldFrame": moveTarget, "expectedRevision": revision(f)]), "A2: move in zoneB")
        try expect(prompts.count == 2, "A2: the approval prompt ran exactly once more")
        guard let actual = rect(moved["actualWorldRect"]) else { throw Failure(message: "A2: result must carry actualWorldRect: \(moved)") }
        let liveAfter = zoneBWorldFrames(f)
        try expect(liveAfter[f.agentTileB] == actual, "A2: the tile's live WORLD frame equals the result's actualWorldRect (\(String(describing: liveAfter[f.agentTileB])) vs \(actual))")
        try expect(actual != before.live[f.agentTileB] && actual.x > 3900, "A2: the tile actually moved toward the requested origin, got \(actual)")
        try expect(uuid(moved["actualZoneId"]) == f.zoneB && moved["durability"]?.string == "committed" && moved["clamped"]?.bool == false, "A2: committed in zoneB, unclamped: \(moved)")
        try expect(f.runtime.structuralRevision == before.structure + 1 && moved["revision"]?.object?["structure"]?.int == Int(before.structure + 1),
                   "A2: one committed geometry transaction bumps the structural revision once (\(before.structure) → \(f.runtime.structuralRevision))")
        let persisted = try persistedFrames(f)
        try expect(persisted[f.agentTileB] == actual, "A2: canvas.json holds the WORLD frame the result reported, got \(String(describing: persisted[f.agentTileB]))")
        try expect(persisted.count == 5 && persisted[f.hiddenB] == original[f.hiddenB], "A2: cover-then-replace — the unhydrated hiddenB survives untouched: \(persisted.count) tiles")
        for (id, frame) in liveAfter { try expect(persisted[id] == frame, "A2: every zoneB tile on disk equals its live WORLD frame (\(id))") }
        try expect(moved["undoRegistered"]?.bool == true, "A2: the drag's own undo history recorded the edit")
        try expectPresentationUntouched(f, before, "A2")
        try expect(moved["presentationEffects"]?.object?["camera"]?.string == "preserved", "A2: presentation reports preserved")

        // A3 — stale revision applies nothing.
        let afterMove = try baselines(f)
        _ = try error(apply(f, ["op": "move", "tileId": f.fileTileB.uuidString, "origin": ["x": 3300, "y": 1000], "expectedRevision": revision(f, structure: before.structure)]), .revisionConflict, "A3: stale expectedRevision")
        try expectNothingApplied(f, afterMove, "A3")
        try expect(prompts.count == 2, "A3: a session grant prompts nobody")

        // A4 — a live pointer gesture wins. This is the production flag, set the
        // way a mouse-down sets it.
        try expect(f.canvas.beginGeometryEdit(.moveTile, tileIds: [f.fileTileB], includeAllZones: true), "A4: arm a real gesture")
        let busy = try error(apply(f, ["op": "move", "tileId": f.fileTileB.uuidString, "origin": ["x": 3300, "y": 1000], "expectedRevision": revision(f)]), .targetConflict, "A4: gesture active")
        try expect(busy.message.hasPrefix("gesture_active"), "A4: the reason is gesture_active, got \(busy.message)")
        f.canvas.cancelGeometryEdit()
        // The pan half of the guard. `beginGeometryEdit` re-entrancy already
        // refuses a tile drag, so only a pointer PAN can witness
        // `isGeometryGestureActive` itself: nothing else in the owner route
        // knows the camera is under the pointer.
        guard let panEvent = NSEvent.mouseEvent(
            with: .leftMouseDown, location: CGPoint(x: 10, y: 10), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1) else { throw Failure(message: "A4: could not synthesize a mouse event") }
        f.canvas.beginPointerPan(with: panEvent)
        let panning = try error(apply(f, ["op": "move", "tileId": f.fileTileB.uuidString, "origin": ["x": 3300, "y": 1000], "expectedRevision": revision(f)]), .targetConflict, "A4: pointer pan active")
        try expect(panning.message.hasPrefix("gesture_active"), "A4: a live pan is gesture_active too, got \(panning.message)")
        f.canvas.endPointerPan()
        try expectNothingApplied(f, afterMove, "A4")

        // A5 / A6 — unhydrated and foreign targets.
        let unhydrated = try error(apply(f, ["op": "move", "tileId": f.hiddenB.uuidString, "origin": ["x": 9100, "y": 9100], "expectedRevision": revision(f)]), .unsupported, "A5: unhydrated target")
        try expect(unhydrated.message == "zone_unhydrated", "A5: reason zone_unhydrated, got \(unhydrated.message)")
        guard let noteA = try f.storePa.loadCanvas().tiles.first?.id else { throw Failure(message: "A6: Pa must hold a tile") }
        let foreign = try error(apply(f, ["op": "move", "tileId": noteA.uuidString, "origin": ["x": 700, "y": 300], "expectedRevision": revision(f)]), .permissionDenied, "A6: another checkout's tile")
        try expect(!foreign.message.contains("zone") && !foreign.message.contains(noteA.uuidString), "A6: the denial names nothing about the target")
        _ = try error(apply(f, ["op": "move", "tileId": UUID().uuidString, "origin": ["x": 0, "y": 0], "expectedRevision": revision(f)]), .notFound, "A6: an unknown tile")
        try expectNothingApplied(f, afterMove, "A5/A6")

        // A7 — resize below the minimum clamps, as the pointer path does.
        let minimum = CanvasEngine.minimumFrame(for: .file)
        let resized = try result(apply(f, ["op": "resize", "tileId": f.fileTileB.uuidString, "size": ["width": 50, "height": 50], "expectedRevision": revision(f)]), "A7: resize below minimum")
        guard let resizedRect = rect(resized["actualWorldRect"]) else { throw Failure(message: "A7: actualWorldRect missing: \(resized)") }
        try expect(resized["clamped"]?.bool == true && resizedRect.width == minimum.width && resizedRect.height == minimum.height,
                   "A7: the size was raised to the kind minimum \(minimum), got \(resizedRect)")
        let resizedOnDisk = try persistedFrames(f)
        try expect(liveWorldFrame(f, f.fileTileB) == resizedRect && resizedOnDisk[f.fileTileB] == resizedRect, "A7: live and persisted frames agree with the result")
        try expect(rect(resized["requestedWorldRect"])?.width == 50, "A7: the requested rect is reported alongside the actual one")

        // A8 — idempotency.
        let afterResize = try baselines(f)
        let key = "idem-\(UUID().uuidString)"
        let first = try result(apply(f, ["op": "move", "tileId": f.agentTileB.uuidString, "origin": ["x": 4100, "y": 900], "expectedRevision": revision(f), "idempotencyKey": key]), "A8: keyed move")
        let structureAfterFirst = f.runtime.structuralRevision
        let replay = try result(apply(f, ["op": "move", "tileId": f.agentTileB.uuidString, "origin": ["x": 4100, "y": 900], "expectedRevision": revision(f, structure: afterResize.structure), "idempotencyKey": key]), "A8: replay")
        try expect(replay == first && f.runtime.structuralRevision == structureAfterFirst, "A8: a replay returns the remembered result and has no second effect")
        _ = try error(apply(f, ["op": "move", "tileId": f.agentTileB.uuidString, "origin": ["x": 4100, "y": 1000], "expectedRevision": revision(f), "idempotencyKey": key]), .idempotencyConflict, "A8: same key, new intent")

        // A9 — the pre-apply cursor is dead; degenerate frames are refused.
        _ = try error(query(f, ["limit": 2, "cursor": cursor1]), .cursorExpired, "A9: a cursor from before the writes")
        _ = try error(apply(f, ["op": "move", "tileId": f.agentTileB.uuidString, "origin": ["x": 5_000_000, "y": 0], "expectedRevision": revision(f)]), .invalidRequest, "A9: out-of-bounds origin")
        _ = try error(apply(f, ["op": "resize", "tileId": f.agentTileB.uuidString, "size": ["width": 0, "height": 100], "expectedRevision": revision(f)]), .invalidRequest, "A9: non-positive size")
        _ = try error(apply(f, ["op": "move", "tileId": f.agentTileB.uuidString, "expectedRevision": revision(f)]), .invalidRequest, "A9: no geometry at all")
        let history = f.api.qaRecentOperations(for: f.agentId)
        try expect(history.contains { $0.op == .canvasApply && $0.outcome == "committed" && $0.tileId == f.agentTileB }, "A9: workspace.context history remembers the apply")
    }
}
