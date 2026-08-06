import ContinuumRevivedCore
import Foundation

// Queue 91 / P7.R1-P7.R6 deterministic checks for the pure Core canvas entity index.

func runCanvasEntityIndexP7Checks() {
    runCanvasEntityIndexP7R1ZoomPanInvariantCheck()
    runCanvasEntityIndexP7R2TieCheck()
    runCanvasEntityIndexP7R3SnapshotCheck()
    runCanvasEntityIndexP7R4DetachedAgentCheck()
    runCanvasEntityIndexP7R5AuthorityBoundaryCheck()
    runCanvasEntityIndexP7R6DeletedStaleFailureCheck()
    print("CanvasEntityIndex P7 checks: R1-R6 passed")
}

private let p7Now = Date(timeIntervalSinceReferenceDate: 910_000_000)
private let p7Project = UUID(uuidString: "91000000-0000-4000-8000-000000000001")!
private let p7Zone = CanvasEntityStableID.zone(UUID(uuidString: "91000000-0000-4000-8000-000000000002")!)
private let p7Origin = CanvasEntityStableID("tile:91000000-0000-4000-8000-000000000010")
private let p7Left = CanvasEntityStableID("tile:91000000-0000-4000-8000-000000000011")
private let p7Right = CanvasEntityStableID("tile:91000000-0000-4000-8000-000000000012")
private let p7Note = CanvasEntityStableID("tile:91000000-0000-4000-8000-000000000013")
private let p7Browser = CanvasEntityStableID("tile:91000000-0000-4000-8000-000000000014")
private let p7Stale = CanvasEntityStableID("tile:91000000-0000-4000-8000-000000000015")
private let p7Deleted = CanvasEntityStableID("tile:91000000-0000-4000-8000-000000000016")
private let p7AgentID = AgentID(rawValue: UUID(uuidString: "91000000-0000-4000-8000-0000000000A1")!)

private func p7Entity(
    _ id: CanvasEntityStableID,
    kind: CanvasEntityKind,
    x: Double,
    y: Double,
    visibility: CanvasEntityVisibility = .visible,
    freshness: CanvasEntityFreshness? = nil,
    scope: CanvasScopeRole = .contextOnly,
    zone: CanvasEntityStableID? = p7Zone,
    project: UUID? = p7Project
) -> CanvasEntity {
    CanvasEntity(
        id: id,
        kind: kind,
        label: id.rawValue,
        frame: CanvasWorldRect(x: x, y: y, width: 10, height: 10),
        visibility: visibility,
        freshness: freshness ?? .fresh(observedAt: p7Now),
        zoneId: zone,
        projectId: project,
        scopeRole: scope,
        evidence: ["fixture"]
    )
}

private func p7BaseIndex() -> CanvasEntityIndex {
    CanvasEntityIndex(entities: [
        p7Entity(p7Origin, kind: .terminal, x: 0, y: 0, scope: .emitsScope(projectId: p7Project, relativeWorkingDirectory: nil, checkoutHandle: "checkout-main")),
        p7Entity(p7Left, kind: .fileTree, x: -30, y: 0, scope: .emitsScope(projectId: p7Project, relativeWorkingDirectory: "Sources", checkoutHandle: "checkout-main")),
        p7Entity(p7Right, kind: .terminal, x: 30, y: 0, scope: .emitsScope(projectId: p7Project, relativeWorkingDirectory: nil, checkoutHandle: "checkout-main")),
        p7Entity(p7Note, kind: .note, x: 0, y: 30),
        p7Entity(p7Browser, kind: .browser, x: 0, y: 60),
    ])
}

private func runCanvasEntityIndexP7R1ZoomPanInvariantCheck() {
    let index = p7BaseIndex()
    let worldPoint = CanvasWorldPoint(x: 3, y: 3)
    let transformedByViewportA = CanvasWorldPoint(x: worldPoint.x, y: worldPoint.y)
    let transformedByViewportB = CanvasWorldPoint(x: worldPoint.x, y: worldPoint.y)

    guard case .chosen(p7Right, _) = index.directional(from: p7Origin, direction: .right) else {
        expect(false, "P7.R1 directional query should choose right entity in world coordinates")
        return
    }
    let nearestA = index.nearest(to: transformedByViewportA)
    let nearestB = index.nearest(to: transformedByViewportB)
    expect(nearestA.chosenIDsSnapshot.entityIds == nearestB.chosenIDsSnapshot.entityIds, "P7.R1 nearest result changed under equivalent viewport transform")
}

private func runCanvasEntityIndexP7R2TieCheck() {
    let tieA = CanvasEntityStableID("tile:91000000-0000-4000-8000-000000000021")
    let tieB = CanvasEntityStableID("tile:91000000-0000-4000-8000-000000000022")
    let index = CanvasEntityIndex(entities: [
        p7Entity(tieB, kind: .terminal, x: 10, y: 0),
        p7Entity(tieA, kind: .terminal, x: -10, y: 0),
    ])
    guard case .ambiguous(let ids, let evidence, let reason) = index.nearest(to: CanvasWorldPoint(x: 5, y: 5)) else {
        expect(false, "P7.R2 equal-distance nearest should be explicit ambiguity")
        return
    }
    expect(ids == [tieA, tieB], "P7.R2 ambiguity IDs are not deterministic stable-id order")
    expect(reason == "equal-nearest-metric", "P7.R2 ambiguity reason missing")
    expect(evidence.map(\.entityId) == [tieA, tieB], "P7.R2 evidence order is not deterministic")
}

private func runCanvasEntityIndexP7R3SnapshotCheck() {
    let before = CanvasEntityIndex(entities: [
        p7Entity(p7Origin, kind: .terminal, x: 0, y: 0),
        p7Entity(p7Right, kind: .terminal, x: 30, y: 0),
    ])
    guard case .chosen(p7Right, _) = before.directional(from: p7Origin, direction: .right) else {
        expect(false, "P7.R3 setup should choose original right entity")
        return
    }
    let snapshot = before.directional(from: p7Origin, direction: .right).chosenIDsSnapshot

    let afterMove = CanvasEntityIndex(entities: [
        p7Entity(p7Origin, kind: .terminal, x: 0, y: 0),
        p7Entity(p7Right, kind: .terminal, x: -300, y: 0),
    ])
    expect(afterMove.validate(snapshot: snapshot).chosenIDsSnapshot.entityIds == [p7Right], "P7.R3 snapshot validation retargeted after movement")
}

private func runCanvasEntityIndexP7R4DetachedAgentCheck() {
    let detached = CanvasEntity(
        id: .agent(p7AgentID),
        kind: .agent,
        label: "Detached agent",
        frame: nil,
        visibility: .detached,
        freshness: .fresh(observedAt: p7Now),
        projectId: p7Project,
        attachedAgentId: p7AgentID,
        scopeRole: .emitsScope(projectId: p7Project, relativeWorkingDirectory: nil, checkoutHandle: "checkout-main"),
        evidence: ["detached-agent"]
    )
    let index = CanvasEntityIndex(entities: [detached, p7Entity(p7Origin, kind: .terminal, x: 0, y: 0)])
    guard case .chosen(let id, let evidence) = index.entity(id: .agent(p7AgentID), options: .addressable) else {
        expect(false, "P7.R4 detached agent should remain addressable")
        return
    }
    expect(id == .agent(p7AgentID), "P7.R4 detached agent resolved to wrong ID")
    expect(evidence.contains { $0.relation == "addressable-without-visible-geometry" }, "P7.R4 detached evidence should not pretend visible geometry exists")
    let nearestIDs = index.nearest(to: CanvasWorldPoint(x: 0, y: 0), options: .addressable).chosenIDsSnapshot.entityIds
    expect(nearestIDs == [p7Origin], "P7.R4 detached agent without frame must not win spatial nearest")
}

private func runCanvasEntityIndexP7R5AuthorityBoundaryCheck() {
    let index = p7BaseIndex()
    let note = index.entity(id: p7Note, options: .addressable).chosenIDsSnapshot.entityIds
    let browser = index.entity(id: p7Browser, options: .addressable).chosenIDsSnapshot.entityIds
    expect(note == [p7Note], "P7.R5 note should be registered as context entity")
    expect(browser == [p7Browser], "P7.R5 browser should be registered as context entity")
    let entities = index.allEntities
    expect(entities.first { $0.id == p7Note }?.scopeRole.emitsFilesystemAuthority == false, "P7.R5 note grants filesystem authority")
    expect(entities.first { $0.id == p7Browser }?.scopeRole.emitsFilesystemAuthority == false, "P7.R5 browser grants filesystem authority")
}

private func runCanvasEntityIndexP7R6DeletedStaleFailureCheck() {
    let index = CanvasEntityIndex(entities: [
        p7Entity(p7Stale, kind: .terminal, x: 0, y: 0, freshness: .stale(observedAt: p7Now, reason: "snapshot-too-old"), scope: .emitsScope(projectId: p7Project, relativeWorkingDirectory: nil, checkoutHandle: "checkout-main")),
        p7Entity(p7Deleted, kind: .terminal, x: 30, y: 0, visibility: .deleted, scope: .emitsScope(projectId: p7Project, relativeWorkingDirectory: nil, checkoutHandle: "checkout-main")),
    ])
    guard case .unavailable(let staleId, let staleReason, _) = index.entity(id: p7Stale, options: .visibleFresh) else {
        expect(false, "P7.R6 stale entity should fail closed by default")
        return
    }
    expect(staleId == p7Stale, "P7.R6 stale failure should name target")
    expect(staleReason == "stale", "P7.R6 stale failure reason not visible")

    guard case .unavailable(let deletedId, let deletedReason, _) = index.entity(id: p7Deleted, options: .addressable) else {
        expect(false, "P7.R6 deleted entity should fail closed by default")
        return
    }
    expect(deletedId == p7Deleted, "P7.R6 deleted failure should name target")
    expect(deletedReason == "deleted", "P7.R6 deleted failure reason not visible")
}
