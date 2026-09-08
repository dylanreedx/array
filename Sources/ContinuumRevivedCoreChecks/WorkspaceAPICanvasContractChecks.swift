import ContinuumRevivedCore
import Foundation

// CX-01 Phase 4 (`.plans/59`, §6.2 / §14.2): the PURE half of the geometry
// slice — the paging cursor, the limit clamp, the byte-bounded page, the
// geometry constraint planner and the revision compare. No processes, no
// filesystem, no canvas. The host pipeline is witnessed by the app leg
// `--workspace-api-canvas-check`.
func runWorkspaceAPICanvasContractChecks() {
    checkCanvasOpsAndGrantPreset()
    checkCanvasQueryCursor()
    checkCanvasQueryPaging()
    checkCanvasQueryByteCeiling()
    checkGeometryConstraints()
    checkRevisionCompare()
    checkCanvasDTORoundTrip()
    print("WorkspaceAPICanvasContractChecks passed")
}

private let canvasEncoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
}()

private func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CanvasWorldRect {
    CanvasWorldRect(x: x, y: y, width: w, height: h)
}

private func checkCanvasOpsAndGrantPreset() {
    expect(WorkspaceAPIOp(rawValue: "canvas.query") == .canvasQuery && WorkspaceAPIOp(rawValue: "canvas.apply") == .canvasApply,
           "P4: both geometry ops must parse from their wire names")
    // The whole grant policy in one assertion: the read is free within the
    // agent's own checkout, the write is not — the first apply must reach the
    // trusted approval UI.
    expect(WorkspaceAPIOp.sessionPresetOperations.contains(.canvasQuery)
            && !WorkspaceAPIOp.sessionPresetOperations.contains(.canvasApply),
           "P4: canvas.query is in the session preset and canvas.apply is NOT")
    let preset = WorkspaceToolGrant.phase1Preset(
        agentId: AgentID(rawValue: UUID()), checkout: CheckoutHandle.derive(canonicalRoot: "/tmp/p"), generation: 0)
    expect(preset.operations == WorkspaceAPIOp.sessionPresetOperations,
           "P4: the seeded preset grant must carry exactly the preset operations, got \(preset.operations)")
    expect(WorkspaceAPIError.Code.revisionConflict.rawValue == "revision_conflict"
            && WorkspaceAPIError.Code.cursorExpired.rawValue == "cursor_expired",
           "P4: the two new error codes keep their §14.4 wire spellings")
}

private func checkCanvasQueryCursor() {
    let cursor = CanvasQueryCursor.encode(structure: 7, offset: 12)
    expect(!cursor.contains(":") && !cursor.contains("=") && !cursor.contains("/") && !cursor.contains("+"),
           "P4: a cursor must be opaque and URL-safe, got \(cursor)")
    let decoded = CanvasQueryCursor.decode(cursor)
    expect(decoded?.structure == 7 && decoded?.offset == 12, "P4: a cursor round-trips its revision and offset, got \(String(describing: decoded))")
    expect(CanvasQueryCursor.decode("garbage") == nil, "P4: a cursor Array did not mint must not decode")
    expect(CanvasQueryCursor.decode(Data("v2:1:0".utf8).base64EncodedString()) == nil, "P4: another cursor version must not decode")
    expect(CanvasQueryCursor.decode(Data("v1:1:-3".utf8).base64EncodedString()) == nil, "P4: a negative offset must not decode")

    expect(CanvasQueryPage.resolveCursor(nil, currentStructure: 3) == .start(offset: 0), "P4: no cursor starts at zero")
    expect(CanvasQueryPage.resolveCursor("", currentStructure: 3) == .start(offset: 0), "P4: an empty cursor starts at zero")
    expect(CanvasQueryPage.resolveCursor("nope", currentStructure: 3) == .malformed, "P4: an unparseable cursor is malformed, not expired")
    // The one that matters: a cursor minted before a structural change indexes a
    // stream that no longer exists. Re-basing it would silently skip or repeat.
    expect(CanvasQueryPage.resolveCursor(CanvasQueryCursor.encode(structure: 2, offset: 4), currentStructure: 3) == .expired,
           "P4: a cursor from an older structural revision must expire")
    expect(CanvasQueryPage.resolveCursor(CanvasQueryCursor.encode(structure: 3, offset: 4), currentStructure: 3) == .start(offset: 4),
           "P4: a current cursor resumes at its offset")
}

private func checkCanvasQueryPaging() {
    expect(CanvasQueryPage.clampedLimit(nil) == CanvasQueryPage.defaultLimit, "P4: no limit means the default")
    expect(CanvasQueryPage.clampedLimit(0) == 1 && CanvasQueryPage.clampedLimit(-5) == 1, "P4: a limit below one clamps up")
    expect(CanvasQueryPage.clampedLimit(9999) == CanvasQueryPage.maxLimit, "P4: the cap is \(CanvasQueryPage.maxLimit)")

    let items: [CanvasQueryItem] = (0..<7).map { index in
        .tile(CanvasQueryTile(tileId: UUID(), kind: "note", zoneId: UUID(), worldRect: rect(Double(index), 0, 10, 10), title: "t\(index)"))
    }
    var offset = 0
    var collected: [CanvasQueryItem] = []
    var pages = 0
    while true {
        let page = CanvasQueryPage.page(items: items, offset: offset, limit: 3, structure: 5, encodedSize: { _ in 0 })
        pages += 1
        collected += page.items
        expect(!page.truncated, "P4: a page under the ceiling is never truncated")
        guard let next = page.nextCursor, let decoded = CanvasQueryCursor.decode(next) else { break }
        offset = decoded.offset
        expect(pages <= 4, "P4: paging must terminate")
    }
    expect(pages == 3 && collected == items, "P4: pages of three cover seven items exactly once in order, got \(pages) pages / \(collected.count) items")
    // A page starting past the end is empty and final, never a crash.
    let past = CanvasQueryPage.page(items: items, offset: 99, limit: 3, structure: 5, encodedSize: { _ in 0 })
    expect(past.items.isEmpty && past.nextCursor == nil, "P4: an offset past the end yields an empty final page")
}

private func checkCanvasQueryByteCeiling() {
    let items: [CanvasQueryItem] = (0..<10).map { index in
        .tile(CanvasQueryTile(tileId: UUID(), kind: "note", zoneId: UUID(), worldRect: rect(Double(index), 0, 10, 10), title: String(repeating: "x", count: 64)))
    }
    // 25 bytes per item, ceiling 100: four items fit, the rest follow.
    let page = CanvasQueryPage.page(items: items, offset: 0, limit: 10, structure: 1, byteCeiling: 100, encodedSize: { $0.count * 25 })
    expect(page.items.count == 4 && page.truncated && page.nextCursor != nil,
           "P4: the page sheds trailing items to fit the byte ceiling and says so, got \(page.items.count) truncated=\(page.truncated)")
    expect(CanvasQueryCursor.decode(page.nextCursor ?? "")?.offset == 4, "P4: the continuation resumes exactly where the shed began")
    // One item bigger than the whole ceiling is still delivered: shedding to zero
    // would make the stream unadvanceable.
    let single = CanvasQueryPage.page(items: items, offset: 0, limit: 10, structure: 1, byteCeiling: 1, encodedSize: { $0.count * 25 })
    expect(single.items.count == 1 && single.truncated, "P4: an oversized single item is still delivered rather than looping forever")
}

private func checkGeometryConstraints() {
    let current = rect(3040, 440, 240, 160)
    let minimum = CanvasWorldSize(width: 200, height: 200)
    let revision = WorkspaceRevision(epoch: "e", structure: 1)
    func plan(_ request: CanvasApplyRequest) -> Result<CanvasGeometryConstraints.Plan, CanvasGeometryConstraints.Rejection> {
        CanvasGeometryConstraints.plan(request, currentWorldFrame: current, minimumSize: minimum)
    }

    func accepted(_ request: CanvasApplyRequest, _ what: String) -> CanvasGeometryConstraints.Plan? {
        switch plan(request) {
        case let .success(value): return value
        case let .failure(rejection):
            expect(false, "P4: \(what) must be accepted, got \(rejection)")
            return nil
        }
    }

    // A move keeps the tile's own size, whatever the request says about it.
    let move = accepted(CanvasApplyRequest(op: .move, tileId: UUID(), origin: CanvasWorldPoint(x: -500, y: -900), expectedRevision: revision), "a move to a negative origin")
    expect(move?.target == rect(-500, -900, 240, 160) && move?.clamped == false,
           "P4: a move takes the origin verbatim (negatives included), keeps the size and is never clamped, got \(String(describing: move))")
    let moveViaFrame = accepted(CanvasApplyRequest(op: .move, tileId: UUID(), worldFrame: rect(0, 0, 9999, 9999), expectedRevision: revision), "a move given a whole frame")
    expect(moveViaFrame?.target == rect(0, 0, 240, 160), "P4: a move given a whole frame still only takes its origin, got \(String(describing: moveViaFrame))")

    // A resize keeps the origin unless the request carries one, and clamps up to
    // the kind minimum exactly as the pointer path does.
    let resize = accepted(CanvasApplyRequest(op: .resize, tileId: UUID(), size: CanvasWorldSize(width: 50, height: 400), expectedRevision: revision), "a resize below the minimum")
    expect(resize?.target == rect(3040, 440, 200, 400), "P4: a resize clamps width up to the minimum and keeps the origin, got \(String(describing: resize))")
    expect(resize?.clamped == true && resize?.requested.width == 50, "P4: the clamp is reported and the request is preserved for the caller")

    for rejected in [
        CanvasApplyRequest(op: .move, tileId: UUID(), expectedRevision: revision),
        CanvasApplyRequest(op: .resize, tileId: UUID(), expectedRevision: revision),
        CanvasApplyRequest(op: .move, tileId: UUID(), origin: CanvasWorldPoint(x: .nan, y: 0), expectedRevision: revision),
        CanvasApplyRequest(op: .move, tileId: UUID(), origin: CanvasWorldPoint(x: .infinity, y: 0), expectedRevision: revision),
        CanvasApplyRequest(op: .move, tileId: UUID(), origin: CanvasWorldPoint(x: CanvasGeometryConstraints.worldBound + 1, y: 0), expectedRevision: revision),
        CanvasApplyRequest(op: .resize, tileId: UUID(), size: CanvasWorldSize(width: 0, height: 100), expectedRevision: revision),
        CanvasApplyRequest(op: .resize, tileId: UUID(), size: CanvasWorldSize(width: -10, height: 100), expectedRevision: revision),
    ] {
        if case .success(let accepted) = plan(rejected) {
            expect(false, "P4: \(rejected.op) must be refused before any effect, got \(accepted)")
        }
    }
    // The bound is inclusive, so a legitimate far-flung canvas still works.
    _ = accepted(CanvasApplyRequest(op: .move, tileId: UUID(), origin: CanvasWorldPoint(x: -CanvasGeometryConstraints.worldBound, y: 0), expectedRevision: revision), "the inclusive world bound")
}

private func checkRevisionCompare() {
    let current = WorkspaceRevision(epoch: "epoch-a", structure: 4)
    expect(WorkspaceRevision(epoch: "epoch-a", structure: 4).matches(current), "P4: an exact revision matches")
    expect(!WorkspaceRevision(epoch: "epoch-a", structure: 3).matches(current), "P4: an older structure is a conflict")
    expect(!WorkspaceRevision(epoch: "epoch-a", structure: 5).matches(current), "P4: a newer structure is a conflict too — the caller cannot have read it")
    expect(!WorkspaceRevision(epoch: "epoch-b", structure: 4).matches(current), "P4: another host epoch is a conflict whatever the structure says")
}

private func checkCanvasDTORoundTrip() {
    let handle = CheckoutHandle.derive(canonicalRoot: "/tmp/checkout")
    let zoneId = UUID()
    let response = CanvasQueryResponse(
        checkoutHandle: handle, projectId: UUID(),
        revision: WorkspaceRevision(epoch: "e", structure: 2),
        coverage: WorkspaceCoverage(installedZoneIds: [zoneId], unhydratedZoneIds: [UUID()]),
        zones: [CanvasQueryZone(zoneId: zoneId, projectId: UUID(), worldRect: rect(-40, -80, 900, 700), hydrated: true, collapsed: false)],
        tiles: [CanvasQueryTile(tileId: UUID(), kind: "file", zoneId: zoneId, worldRect: rect(-20, -60, 480, 360), title: "notes.md")],
        nextCursor: CanvasQueryCursor.encode(structure: 2, offset: 2), truncated: true)
    guard let data = try? canvasEncoder.encode(response),
          let decoded = try? JSONDecoder().decode(CanvasQueryResponse.self, from: data) else {
        expect(false, "P4: the query response must round-trip")
        return
    }
    expect(decoded == response && decoded.schema == WorkspaceAPISchema.v1, "P4: the query response round-trips verbatim, negative origins included")
    expect(decoded.coverage.complete == false && decoded.zones[0].stale == false, "P4: coverage and staleness survive the wire")

    // The request decoder must accept the shorthand the pi tool sends.
    let payload: [String: Any] = ["op": "resize", "tileId": UUID().uuidString, "size": ["width": 640, "height": 480],
                                  "expectedRevision": ["epoch": "e", "structure": 9], "idempotencyKey": "k1"]
    guard let requestData = try? JSONSerialization.data(withJSONObject: payload),
          let request = try? JSONDecoder().decode(CanvasApplyRequest.self, from: requestData) else {
        expect(false, "P4: the apply request must decode from the tool's payload")
        return
    }
    expect(request.op == .resize && request.size?.width == 640 && request.worldFrame == nil && request.expectedRevision.structure == 9,
           "P4: origin/size shorthand and the expected revision decode as sent")

    let result = CanvasApplyResult(
        operationId: "op-1", op: .move, tileId: UUID(), requestedWorldRect: rect(-10, -10, 240, 160),
        actualWorldRect: rect(-8, -12, 240, 160), actualZoneId: zoneId, clamped: false,
        durability: .committed, undoRegistered: true, revision: WorkspaceRevision(epoch: "e", structure: 3))
    guard let resultData = try? canvasEncoder.encode(result),
          let decodedResult = try? JSONDecoder().decode(CanvasApplyResult.self, from: resultData) else {
        expect(false, "P4: the apply result must round-trip")
        return
    }
    expect(decodedResult == result && decodedResult.actualWorldRect != decodedResult.requestedWorldRect,
           "P4: the result carries the ACTUAL frame beside the requested one")
}
