import ContinuumRevivedCore
import Foundation

// Ticket: docs/38-tickets/77-canvas-mirror-magic-polish.md
// Pure checks for the iOS mirror decisions: first-snapshot framing,
// freshness labels, status overlays, and Show on canvas focus/highlight.

private func mirrorTile(
    id: UUID,
    title: String = "Agent",
    frame: TileFrame,
    z: Double = 0.5
) -> CanvasSceneTile {
    CanvasSceneTile(
        tileId: id,
        title: title,
        frame: frame,
        zPosition: FracIndex(value: z),
        zoneId: nil,
        kindGlyphToken: "terminal"
    )
}

private func mirrorZone(id: UUID, origin: ZonePoint, size: ZoneSize) -> CanvasSceneZone {
    CanvasSceneZone(
        zoneId: id,
        name: "Workspace",
        origin: origin,
        size: size,
        tintToken: "mint",
        zPosition: FracIndex(value: 0.2)
    )
}

private func mirrorSample(publishedAt: Date) -> CompanionFreshnessSample {
    CompanionFreshnessSample(
        metadata: CompanionFreshnessMetadata(
            instanceId: UUID(uuidString: "77000000-0000-4000-8000-000000000001")!,
            desktopReplicaId: "desktop",
            bootId: "boot",
            sequence: Int64(publishedAt.timeIntervalSince1970),
            publishedAt: publishedAt,
            receivedAt: publishedAt,
            powerHint: .active,
            spatialWatermark: nil,
            activityWatermark: nil
        )
    )
}

private func mirrorSession(scopes: Scope = .operator) -> PairedCompanionSessionState {
    .paired(PairedCompanionSession(
        instanceId: UUID(uuidString: "77000000-0000-4000-8000-000000000011")!,
        userId: UUID(uuidString: "77000000-0000-4000-8000-000000000012")!,
        deviceId: UUID(uuidString: "77000000-0000-4000-8000-000000000013")!,
        sessionId: UUID(uuidString: "77000000-0000-4000-8000-000000000014")!,
        token: "session-token",
        scopes: scopes,
        issuedAt: Date(timeIntervalSinceReferenceDate: 0),
        expiresAt: Date(timeIntervalSinceReferenceDate: 10_000)
    ))
}

private func mirrorFreshness(
    spatial: CompanionFreshnessSample?,
    activity: CompanionFreshnessSample?,
    transport: CompanionTransportAvailability = .available,
    now: Date
) -> CompanionFreshness {
    CompanionFreshness.derive(CompanionFreshnessInput(
        sessionState: mirrorSession(),
        spatialSnapshot: spatial,
        activitySnapshot: activity,
        transportAvailability: transport,
        now: now
    ))
}

func runCanvasMirrorFramingChecks() {
    let viewportSize = CanvasMirrorViewportSize(width: 390, height: 720)
    let existing = CanvasMirrorViewport(scale: 0.35, panX: 12, panY: 34)

    let empty = CanvasScene(zones: [], tiles: [])
    let emptyResult = CanvasMirrorPresentation.firstSnapshotViewport(
        scene: empty,
        viewportSize: viewportSize,
        current: existing,
        framingState: .waitingForFirstSnapshot
    )
    expect(emptyResult.viewport == existing, "Canvas mirror framing: empty scene keeps current viewport")
    expect(emptyResult.framingState == .waitingForFirstSnapshot, "Canvas mirror framing: empty scene stays waiting")

    let tileId = UUID(uuidString: "77000000-0000-4000-8000-000000000101")!
    let singleTile = CanvasScene(
        zones: [],
        tiles: [mirrorTile(id: tileId, frame: TileFrame(x: 500, y: 300, width: 220, height: 140))]
    )
    let singleResult = CanvasMirrorPresentation.firstSnapshotViewport(
        scene: singleTile,
        viewportSize: viewportSize,
        current: existing,
        framingState: .waitingForFirstSnapshot
    )
    let singleCenter = CanvasMirrorPresentation.screenCenter(
        of: singleTile.tiles[0].frame,
        viewport: singleResult.viewport
    )
    expect(singleResult.framingState == .autoFramedFirstSnapshot, "Canvas mirror framing: first non-empty scene is marked auto-framed")
    expect(singleResult.viewport.scale >= 0.65, "Canvas mirror framing: single tile gets readable zoom, got \(singleResult.viewport.scale)")
    expect(abs(singleCenter.x - viewportSize.width / 2) < 0.001 && abs(singleCenter.y - viewportSize.height / 2) < 0.001, "Canvas mirror framing: single tile centers in viewport")

    let zoneId = UUID(uuidString: "77000000-0000-4000-8000-000000000102")!
    let multiScene = CanvasScene(
        zones: [mirrorZone(id: zoneId, origin: ZonePoint(x: -100, y: 50), size: ZoneSize(width: 800, height: 360))],
        tiles: [
            mirrorTile(id: tileId, frame: TileFrame(x: 620, y: 330, width: 180, height: 120))
        ]
    )
    let fit = CanvasMirrorPresentation.fitAllViewport(scene: multiScene, viewportSize: viewportSize)
    let projected = CanvasMirrorPresentation.projectedBounds(scene: multiScene, viewport: fit)
    expect(projected.minX >= 39.999 && projected.minY >= 39.999, "Canvas mirror framing: fit-all keeps top/left margin, got \(projected)")
    expect(projected.maxX <= viewportSize.width - 39.999 && projected.maxY <= viewportSize.height - 39.999, "Canvas mirror framing: fit-all keeps bottom/right margin, got \(projected)")

    let userControlled = CanvasMirrorPresentation.firstSnapshotViewport(
        scene: singleTile,
        viewportSize: viewportSize,
        current: existing,
        framingState: .userControlled
    )
    expect(userControlled.viewport == existing, "Canvas mirror framing: user-controlled viewport does not auto-snap")
    expect(userControlled.framingState == .userControlled, "Canvas mirror framing: user-controlled state is preserved")

    print("CanvasMirrorPresentation framing checks: empty preserved, single centered/readable, multi fit-all, user-controlled preserved")
}

func runCanvasMirrorFreshnessLabelChecks() {
    let now = Date(timeIntervalSinceReferenceDate: 1_000)
    let liveSpatial = mirrorSample(publishedAt: now.addingTimeInterval(-10))
    let staleSpatial = mirrorSample(publishedAt: now.addingTimeInterval(-240))
    let liveActivity = mirrorSample(publishedAt: now.addingTimeInterval(-5))

    let waiting = CanvasMirrorPresentation.freshnessDisplay(
        freshness: mirrorFreshness(spatial: nil, activity: nil, now: now),
        hasCanvasData: false,
        spatialSample: nil,
        activitySample: nil,
        now: now
    )
    expect(waiting.title == "Waiting for desktop canvas", "Canvas mirror freshness: no data waits for desktop canvas")

    let live = CanvasMirrorPresentation.freshnessDisplay(
        freshness: mirrorFreshness(spatial: liveSpatial, activity: liveActivity, now: now),
        hasCanvasData: true,
        spatialSample: liveSpatial,
        activitySample: liveActivity,
        now: now
    )
    expect(live.title == "Live", "Canvas mirror freshness: recent spatial data is live")

    let mixed = CanvasMirrorPresentation.freshnessDisplay(
        freshness: mirrorFreshness(spatial: staleSpatial, activity: liveActivity, now: now),
        hasCanvasData: true,
        spatialSample: staleSpatial,
        activitySample: liveActivity,
        now: now
    )
    expect(mixed.title == "Canvas stale · Agents live", "Canvas mirror freshness: stale spatial + live activity is explicit")
    expect(mixed.asOf == staleSpatial.metadata.publishedAt, "Canvas mirror freshness: mixed stale label keeps spatial as-of date")

    let offline = CanvasMirrorPresentation.freshnessDisplay(
        freshness: mirrorFreshness(spatial: staleSpatial, activity: liveActivity, transport: .networkUnavailable, now: now),
        hasCanvasData: true,
        spatialSample: staleSpatial,
        activitySample: liveActivity,
        now: now
    )
    expect(offline.title == "Offline", "Canvas mirror freshness: offline stays offline")
    expect(offline.detail == "Showing cached canvas", "Canvas mirror freshness: offline cached canvas copy is honest")

    print("CanvasMirrorPresentation freshness checks: waiting/live/mixed-stale/offline labels")
}

func runCanvasMirrorStatusJoinChecks() {
    let tileA = UUID(uuidString: "77000000-0000-4000-8000-000000000201")!
    let tileB = UUID(uuidString: "77000000-0000-4000-8000-000000000202")!
    let external = UUID(uuidString: "77000000-0000-4000-8000-000000000203")!
    let scene = CanvasScene(
        zones: [],
        tiles: [
            mirrorTile(id: tileA, frame: TileFrame(x: 0, y: 0, width: 160, height: 100)),
            mirrorTile(id: tileB, frame: TileFrame(x: 200, y: 0, width: 160, height: 100)),
        ]
    )
    let rows = [
        AgentsBoardRow(
            tileId: tileA,
            status: .needsAttention,
            lastSummary: "Needs approval",
            recent: [],
            updatedAt: Date(timeIntervalSinceReferenceDate: 1),
            presentation: AgentsBoardProjection.presentation(for: .needsAttention)
        ),
        AgentsBoardRow(
            tileId: external,
            status: .working,
            lastSummary: "Not on canvas",
            recent: [],
            updatedAt: Date(timeIntervalSinceReferenceDate: 2),
            presentation: AgentsBoardProjection.presentation(for: .working)
        )
    ]

    let joined = CanvasMirrorPresentation.statusOverlays(scene: scene, rows: rows)
    expect(joined[tileA]?.presentation.colorToken == "orange", "Canvas mirror status join: tile activity uses AgentsBoard color token")
    expect(joined[tileA]?.status == .needsAttention, "Canvas mirror status join: tile activity keeps status")
    expect(joined[tileB]?.status == .stale, "Canvas mirror status join: missing activity gets neutral stale status")
    expect(joined[external] == nil, "Canvas mirror status join: non-spatial activity is not projected onto canvas")

    print("CanvasMirrorPresentation status checks: activity join, neutral fallback, external rows ignored")
}

func runCanvasMirrorShowOnCanvasChecks() {
    let viewportSize = CanvasMirrorViewportSize(width: 390, height: 720)
    let tileId = UUID(uuidString: "77000000-0000-4000-8000-000000000301")!
    let missing = UUID(uuidString: "77000000-0000-4000-8000-000000000302")!
    let scene = CanvasScene(
        zones: [],
        tiles: [mirrorTile(id: tileId, frame: TileFrame(x: 400, y: 120, width: 200, height: 120))]
    )

    let focus = CanvasMirrorPresentation.showOnCanvas(
        tileId: tileId,
        scene: scene,
        viewportSize: viewportSize,
        currentScale: 0.8
    )
    expect(focus.highlightedTileId == tileId, "Canvas mirror Show on canvas: present tile is highlighted")
    expect(focus.message == nil, "Canvas mirror Show on canvas: present tile has no error message")
    let center = CanvasMirrorPresentation.screenCenter(of: scene.tiles[0].frame, viewport: focus.viewport)
    expect(abs(center.x - viewportSize.width / 2) < 0.001 && abs(center.y - viewportSize.height / 2) < 0.001, "Canvas mirror Show on canvas: present tile centers in viewport")

    let miss = CanvasMirrorPresentation.showOnCanvas(
        tileId: missing,
        scene: scene,
        viewportSize: viewportSize,
        currentScale: 0.8
    )
    expect(miss.highlightedTileId == nil, "Canvas mirror Show on canvas: absent tile is not highlighted")
    expect(miss.message == "Tile not synced to canvas yet", "Canvas mirror Show on canvas: absent tile has user-visible message")

    print("CanvasMirrorPresentation show-on-canvas checks: present centers/highlights, absent reports message")
}
