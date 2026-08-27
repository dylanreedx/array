import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Foundation

/// T8 (`.plans/48`) — the agent↔document connector must paint on its endpoints
/// at ANY camera position.
///
/// **The defect.** `updateDocumentRelationshipOverlay` set
/// `documentRelationshipOverlay.frame = worldPlane.bounds` and then fed the
/// segments raw `worldPlane`-space view frames. `worldPlane` implements pan as
/// `setBoundsOrigin(worldOrigin)`, so its `bounds.origin` IS the camera's world
/// position; the overlay's own `bounds.origin` stays (0,0). A path drawn at
/// world `W` therefore painted at `worldOrigin + W` — displaced by exactly the
/// camera pan, growing the further you pan from the world origin, and clipped
/// away entirely once it left the plane. The user saw a curve floating in empty
/// canvas far from either tile.
///
/// **Why the existing coverage could not catch it.**
/// `--file-open-active-context-check` builds its canvas at
/// `viewport: .init(x: 0, y: 0, zoom: 1)`, where the offset is exactly zero, and
/// `checkDocumentRelationshipGeometry` tests the pure `route(for:)` with
/// hand-fed rects — no canvas, no camera, no view hierarchy. **This leg's
/// defining constraint is that it runs at a NON-ZERO viewport and a zoom other
/// than 1.**
///
/// The oracle is deliberately independent: both the painted segment and the tile
/// view are converted into the CANVAS's own coordinate space and compared there.
/// Asserting the segment equals `overlay.convert(view.bounds, from: view)` would
/// only restate the fix.
@MainActor
enum RelationshipGeometryChecks {
    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
        var localizedDescription: String { message }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(message: message) }
    }

    private static func nearly(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat = 0.5) -> Bool {
        abs(lhs.minX - rhs.minX) < tolerance && abs(lhs.minY - rhs.minY) < tolerance
            && abs(lhs.width - rhs.width) < tolerance && abs(lhs.height - rhs.height) < tolerance
    }

    private static func point(_ point: CGPoint, liesOnEdgeOf rect: CGRect, tolerance: CGFloat = 0.75) -> Bool {
        let withinX = point.x >= rect.minX - tolerance && point.x <= rect.maxX + tolerance
        let withinY = point.y >= rect.minY - tolerance && point.y <= rect.maxY + tolerance
        let onVertical = abs(point.x - rect.minX) < tolerance || abs(point.x - rect.maxX) < tolerance
        let onHorizontal = abs(point.y - rect.minY) < tolerance || abs(point.y - rect.maxY) < tolerance
        return (withinY && onVertical) || (withinX && onHorizontal)
    }

    static func run() throws {
        let agentTileId = UUID(uuidString: "00000000-0000-0000-0000-0000000000C1")!
        let fileTileId = UUID(uuidString: "00000000-0000-0000-0000-0000000000C2")!
        let agentId = AgentID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-0000000000C3")!)
        let now = Date(timeIntervalSince1970: 1_900_000_000)

        /// A canvas with a linked agent/file pair anchored near `origin`.
        ///
        /// The pair has to sit near the camera or the overlay culls the segment
        /// (correctly — `updateDocumentRelationshipOverlay` skips links whose union
        /// misses the visible rect). So the zero-viewport regression case and the
        /// panned case need their own fixtures rather than one canvas panned twice.
        func makeCanvas(origin: CGPoint) -> CanvasNSView {
            func note(_ id: UUID, x: Double, y: Double) -> Tile {
                Tile(id: id, kind: .note, title: "t",
                     frame: TileFrame(x: x, y: y, width: 320, height: 240),
                     zPosition: .fromLegacyRank(1), runtimeRef: nil,
                     metadata: TileMetadata(noteId: id))
            }
            let agentTile = note(agentTileId, x: Double(origin.x) + 120, y: Double(origin.y) + 100)
            let fileTile = note(fileTileId, x: Double(origin.x) + 780, y: Double(origin.y) + 380)
            let canvas = CanvasNSView(canvasState: CanvasState(
                viewport: CanvasViewport(x: Double(origin.x), y: Double(origin.y), zoom: 1),
                tiles: [agentTile, fileTile], groups: [], lastActiveTileId: nil))
            canvas.frame = CGRect(x: 0, y: 0, width: 1600, height: 1000)
            canvas.install(tileView: NoteTileNSView(tile: agentTile, noteId: agentTileId, initialBody: ""),
                           for: agentTile)
            canvas.install(tileView: NoteTileNSView(tile: fileTile, noteId: fileTileId, initialBody: ""),
                           for: fileTile)
            canvas.layoutSubtreeIfNeeded()
            canvas.setDocumentRelationships(
                [DocumentAgentLink(agentId: agentId, documentTileId: fileTileId,
                                   createdAt: now, updatedAt: now)],
                agentTileIds: [agentId: agentTileId])
            return canvas
        }

        func assertPaintsOnEndpoints(_ canvas: CanvasNSView, _ label: String) throws {
            canvas.layoutSubtreeIfNeeded()
            let rects = canvas.qaDocumentRelationshipSegmentRects
            try expect(rects.count == 1,
                       "\(label): expected exactly one segment; got \(rects.count)")
            guard let agentRect = canvas.qaTileRectInCanvasSpace(agentTileId),
                  let fileRect = canvas.qaTileRectInCanvasSpace(fileTileId) else {
                throw Failure(message: "\(label): could not read the tile rects")
            }
            let paintedSource = canvas.qaSegmentRectInCanvasSpace(rects[0].source)
            let paintedTarget = canvas.qaSegmentRectInCanvasSpace(rects[0].target)
            try expect(nearly(paintedSource, agentRect),
                       "\(label): the connector's SOURCE must paint on the agent tile. "
                       + "Painted \(paintedSource), tile is at \(agentRect). A difference equal "
                       + "to the camera origin means the segment was handed a worldPlane frame "
                       + "without converting into the overlay's own space.")
            try expect(nearly(paintedTarget, fileRect),
                       "\(label): the connector's TARGET must paint on the file tile. "
                       + "Painted \(paintedTarget), tile is at \(fileRect).")
        }

        // 1. Viewport (0,0), zoom 1 — the only case the old coverage exercised.
        //    It must stay green: the fix cannot be "shift everything".
        let atOrigin = makeCanvas(origin: .zero)
        try assertPaintsOnEndpoints(atOrigin, "viewport (0,0) zoom 1")

        // 2. Panned far from the world origin. RED before the fix, displaced by
        //    exactly the camera origin.
        let canvas = makeCanvas(origin: CGPoint(x: 4000, y: 2900))
        try assertPaintsOnEndpoints(canvas, "panned to (4000, 2900)")

        // 3. Panned AND zoomed. `worldPlane` encodes zoom as a bounds SIZE, so a
        //    conversion that only subtracted the origin would pass 2 and fail here.
        canvas.setViewport(CanvasViewport(x: 4050, y: 2950, zoom: 0.5))
        try assertPaintsOnEndpoints(canvas, "panned + zoom 0.5")

        canvas.setViewport(CanvasViewport(x: 4100, y: 3000, zoom: 1.4))
        try assertPaintsOnEndpoints(canvas, "panned + zoom 1.4")

        // 4. The connector TRACKS the camera rather than drifting with it.
        canvas.setViewport(CanvasViewport(x: 4000, y: 2900, zoom: 1))
        canvas.layoutSubtreeIfNeeded()
        let before = canvas.qaSegmentRectInCanvasSpace(
            canvas.qaDocumentRelationshipSegmentRects[0].source)
        canvas.setViewport(CanvasViewport(x: 4300, y: 2900, zoom: 1))
        canvas.layoutSubtreeIfNeeded()
        let after = canvas.qaSegmentRectInCanvasSpace(
            canvas.qaDocumentRelationshipSegmentRects[0].source)
        try expect(abs((before.minX - after.minX) - 300) < 0.5,
                   "pan tracking: panning 300pt right must move the painted connector 300pt "
                   + "LEFT in canvas space, exactly as the tile moves. Moved "
                   + "\(before.minX - after.minX).")

        // 5. The lineage overlay uses `convert` already; assert it rather than
        //    assume it, at the same non-zero viewport.
        canvas.showContextualAgentLineage(parentTileID: agentTileId, childTileID: fileTileId)
        canvas.layoutSubtreeIfNeeded()
        let singleEndpoints = canvas.qaLineageEndpointsInCanvasSpace
        guard singleEndpoints.count == 1,
              let agentRect = canvas.qaTileRectInCanvasSpace(agentTileId),
              let fileRect = canvas.qaTileRectInCanvasSpace(fileTileId) else {
            throw Failure(message: "lineage: expected exactly one overlay endpoint pair; got \(singleEndpoints.count)")
        }
        let endpoints = singleEndpoints[0]
        try expect(point(endpoints.start, liesOnEdgeOf: agentRect),
                   "lineage: the start point must sit on the parent tile's edge. Got "
                   + "\(endpoints.start), tile \(agentRect)")
        try expect(point(endpoints.end, liesOnEdgeOf: fileRect),
                   "lineage: the end point must sit on the child tile's edge. Got "
                   + "\(endpoints.end), tile \(fileRect)")

        // 6. C11 — N > 1 edges. `CanvasNSView` used to draw exactly one edge
        // (`startPoint`/`endPoint`); `showContextualAgentLineage(edges:)` must
        // paint one per resolved (parent, child) pair, bounded to
        // `InboxSort.maxVisibleChildren` the way the inbox itself bounds a
        // parent's visible children.
        //
        // The fixture size is PINNED to the human fan-out batch, not to a literal
        // "16" or "8": two levels of `AgentSupervisor.maxFanOutBatch` is
        // exactly the "16 live streams" a maxed-out fan-out produces, and
        // two PARENTS' worth of that same cap is exactly
        // `InboxSort.maxVisibleChildren` — the relationship
        // `ContinuumApp.swift:26972-26973` already pins for `maxDepth`. If
        // either cap changes, THIS assertion fails loudly instead of an
        // edge count silently meaning something else.
        try expect(
            AgentSupervisor.maxFanOutBatch * AgentSupervisor.maxFanOutBatch == 16,
            "the 16-live-stream fixture below assumes maxFanOutBatch² == 16; "
            + "maxFanOutBatch is \(AgentSupervisor.maxFanOutBatch)")
        try expect(
            AgentSupervisor.maxFanOutBatch + AgentSupervisor.maxFanOutBatch
                == InboxSort.maxVisibleChildren,
            "InboxSort.maxVisibleChildren (\(InboxSort.maxVisibleChildren)) must equal two parents' worth of "
            + "AgentSupervisor.maxFanOutBatch (\(AgentSupervisor.maxFanOutBatch)) — the canvas lineage "
            + "bound below reuses maxVisibleChildren on exactly that assumption")

        let fanParentTileId = UUID(uuidString: "00000000-0000-0000-0000-0000000000D0")!
        let fanChildTileIds = (0 ..< 16).map { index in
            UUID(uuidString: String(format: "00000000-0000-0000-0000-0000000000%02X", 0xE0 + index))!
        }
        func fanTile(_ id: UUID, x: Double, y: Double) -> Tile {
            Tile(id: id, kind: .note, title: "t",
                 frame: TileFrame(x: x, y: y, width: 120, height: 90),
                 zPosition: .fromLegacyRank(1), runtimeRef: nil,
                 metadata: TileMetadata(noteId: id))
        }
        let fanParentTile = fanTile(fanParentTileId, x: 100, y: 100)
        let fanChildTiles = fanChildTileIds.enumerated().map { index, id in
            fanTile(id, x: 400 + Double(index % 4) * 160, y: 100 + Double(index / 4) * 130)
        }
        let fanCanvas = CanvasNSView(canvasState: CanvasState(
            viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
            tiles: [fanParentTile] + fanChildTiles, groups: [], lastActiveTileId: nil))
        fanCanvas.frame = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        fanCanvas.install(tileView: NoteTileNSView(tile: fanParentTile, noteId: fanParentTileId, initialBody: ""),
                           for: fanParentTile)
        for tile in fanChildTiles {
            fanCanvas.install(tileView: NoteTileNSView(tile: tile, noteId: tile.id, initialBody: ""), for: tile)
        }
        fanCanvas.layoutSubtreeIfNeeded()

        let fanEdges = fanChildTileIds.map { (parentTileID: fanParentTileId, childTileID: $0) }
        fanCanvas.showContextualAgentLineage(edges: fanEdges)
        fanCanvas.layoutSubtreeIfNeeded()
        let fanEndpoints = fanCanvas.qaLineageEndpointsInCanvasSpace
        try expect(fanEndpoints.count == InboxSort.maxVisibleChildren,
                   "a \(fanEdges.count)-edge fan-out must bound to InboxSort.maxVisibleChildren "
                   + "(\(InboxSort.maxVisibleChildren)) painted edges; got \(fanEndpoints.count)")

        guard let fanParentRect = fanCanvas.qaTileRectInCanvasSpace(fanParentTileId) else {
            throw Failure(message: "fan-out lineage: could not read the shared parent's rect")
        }
        for (offset, endpoint) in fanEndpoints.enumerated() {
            try expect(point(endpoint.start, liesOnEdgeOf: fanParentRect),
                       "fan-out lineage edge \(offset): the start point must sit on the shared parent's edge. "
                       + "Got \(endpoint.start), tile \(fanParentRect)")
            guard let childRect = fanCanvas.qaTileRectInCanvasSpace(fanChildTileIds[offset]) else {
                throw Failure(message: "fan-out lineage edge \(offset): could not read child \(offset)'s rect")
            }
            try expect(point(endpoint.end, liesOnEdgeOf: childRect),
                       "fan-out lineage edge \(offset): the end point must sit on child \(offset)'s edge. "
                       + "Got \(endpoint.end), tile \(childRect)")
        }
        try expect(fanCanvas.qaLineageAnimationCount <= 1,
                   "a bounded lineage fan must use at most one Core Animation loop; got "
                   + "\(fanCanvas.qaLineageAnimationCount)")
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            try expect(fanCanvas.qaLineageIsAnimating,
                       "lineage should march when Reduce Motion is off and the canvas is active")
        }
        try expect(fanCanvas.qaLineageHitTestPassesThrough,
                   "the priority-visible lineage overlay must remain click-through")

        print("RelationshipGeometryChecks: the document connector and the lineage overlay both "
              + "paint on their endpoints at a panned, zoomed camera, and track it when it moves; "
              + "a 16-edge fan-out (maxFanOutBatch² live streams) bounds to exactly "
              + "InboxSort.maxVisibleChildren painted edges, each still on its own parent/child pair, "
              + "through one click-transparent animation")
    }
}
