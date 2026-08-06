import ContinuumRevivedCore
import Foundation

// Queue 91 / P7 live-snapshot adapter checks. These exercise only the pure
// adapter inputs and CanvasEntityIndex output; no AppKit views, stores, runtime,
// AgentRecord, or host cwd participate.

func runCanvasEntityIndexAdapterP7Checks() {
    runCanvasEntityIndexAdapterWorldFramesCheck()
    runCanvasEntityIndexAdapterCollapsedHiddenCheck()
    runCanvasEntityIndexAdapterDetachedAgentCheck()
    runCanvasEntityIndexAdapterTileRemovalCheck()
    runCanvasEntityIndexAdapterIdentitySeparationCheck()
    runCanvasEntityIndexAdapterNoPathLeakageCheck()
    print("CanvasEntityIndexAdapter P7 checks passed")
}

private let adapterNow = Date(timeIntervalSinceReferenceDate: 910_700_000)
private let adapterProject = UUID(uuidString: "91000000-0000-4000-8000-00000000A001")!
private let adapterZone = UUID(uuidString: "91000000-0000-4000-8000-00000000A002")!
private let adapterTileA = UUID(uuidString: "91000000-0000-4000-8000-00000000A010")!
private let adapterTileB = UUID(uuidString: "91000000-0000-4000-8000-00000000A011")!
private let adapterTileDuplicate = UUID(uuidString: "91000000-0000-4000-8000-00000000A012")!
private let adapterAgent = AgentID(rawValue: UUID(uuidString: "91000000-0000-4000-8000-00000000A0A1")!)
private let adapterDetachedAgent = AgentID(rawValue: UUID(uuidString: "91000000-0000-4000-8000-00000000A0A2")!)

private func adapterSnapshot(
    zones: [CanvasEntityIndexZoneSnapshot] = [],
    tiles: [CanvasEntityIndexTileSnapshot] = [],
    agents: [CanvasEntityIndexAgentSnapshot] = []
) -> CanvasEntityIndexSnapshot {
    CanvasEntityIndexSnapshot(observedAt: adapterNow, zones: zones, tiles: tiles, agents: agents)
}

private func adapterTile(
    _ id: UUID,
    kind: CanvasEntityIndexTileKind = .terminal,
    x: Double,
    y: Double,
    visibility: CanvasEntityVisibility = .visible,
    zoneId: UUID? = nil,
    attachedAgentId: AgentID? = nil,
    relativeWorkingDirectory: String? = "Sources"
) -> CanvasEntityIndexTileSnapshot {
    CanvasEntityIndexTileSnapshot(
        id: id,
        kind: kind,
        label: "tile-\(id.uuidString.suffix(4))",
        worldFrame: CanvasWorldRect(x: x, y: y, width: 25, height: 15),
        visibility: visibility,
        zoneId: zoneId,
        projectId: adapterProject,
        relativeWorkingDirectory: relativeWorkingDirectory,
        checkoutHandle: "checkout-main",
        attachedAgentId: attachedAgentId
    )
}

private func runCanvasEntityIndexAdapterWorldFramesCheck() {
    let index = CanvasEntityIndexSnapshotAdapter.buildIndex(from: adapterSnapshot(tiles: [
        adapterTile(adapterTileA, x: -1_000, y: 200),
        adapterTile(adapterTileB, x: 50, y: 75),
    ]))

    guard case .chosen(.tile(adapterTileB), _) = index.nearest(to: CanvasWorldPoint(x: 55, y: 80)) else {
        expect(false, "P7 adapter world frames: nearest should use supplied world coordinates")
        return
    }
    let entity = index.allEntities.first { $0.id == .tile(adapterTileA) }
    expect(entity?.frame == CanvasWorldRect(x: -1_000, y: 200, width: 25, height: 15),
           "P7 adapter world frames: frame should be preserved exactly without viewport conversion")
}

private func runCanvasEntityIndexAdapterCollapsedHiddenCheck() {
    let index = CanvasEntityIndexSnapshotAdapter.buildIndex(from: adapterSnapshot(
        zones: [CanvasEntityIndexZoneSnapshot(id: adapterZone, label: "collapsed", isCollapsed: true)],
        tiles: [
            adapterTile(adapterTileA, x: 0, y: 0, zoneId: adapterZone),
            adapterTile(adapterTileB, x: 60, y: 0, visibility: .hidden),
        ]
    ))

    expect(index.contains(point: CanvasWorldPoint(x: 5, y: 5)).chosenIDsSnapshot.entityIds.isEmpty,
           "P7 adapter collapsed handling: collapsed-zone tile should not be visible by default")
    expect(index.entity(id: .tile(adapterTileA), options: .addressable).chosenIDsSnapshot.entityIds == [.tile(adapterTileA)],
           "P7 adapter collapsed handling: collapsed-zone tile should remain addressable with hidden included")
    guard case .unavailable(.tile(adapterTileB), let hiddenReason, _) = index.entity(id: .tile(adapterTileB), options: .visibleFresh) else {
        expect(false, "P7 adapter hidden handling: explicitly hidden tile should be filtered by default")
        return
    }
    expect(hiddenReason == "hidden", "P7 adapter hidden handling: wrong filter reason \(hiddenReason)")
    expect(index.entity(id: .tile(adapterTileB), options: .addressable).chosenIDsSnapshot.entityIds == [.tile(adapterTileB)],
           "P7 adapter hidden handling: explicitly hidden tile should be addressable")
}

private func runCanvasEntityIndexAdapterDetachedAgentCheck() {
    let index = CanvasEntityIndexSnapshotAdapter.buildIndex(from: adapterSnapshot(
        tiles: [adapterTile(adapterTileA, kind: .managedAgent, x: 0, y: 0, attachedAgentId: adapterAgent)],
        agents: [
            CanvasEntityIndexAgentSnapshot(
                id: adapterAgent,
                label: "tiled agent",
                associatedTileIds: [adapterTileA],
                projectId: adapterProject,
                relativeWorkingDirectory: "agents/refactor",
                checkoutHandle: "agent-worktree"
            ),
            CanvasEntityIndexAgentSnapshot(id: adapterDetachedAgent, label: "headless", projectId: adapterProject)
        ]
    ))

    expect(index.entity(id: .agent(adapterDetachedAgent), options: .addressable).chosenIDsSnapshot.entityIds == [.agent(adapterDetachedAgent)],
           "P7 adapter detached/headless agent should be addressable without a tile")
    expect(index.nearest(to: CanvasWorldPoint(x: 5, y: 5), options: .addressable).chosenIDsSnapshot.entityIds == [.tile(adapterTileA)],
           "P7 adapter detached/headless agent should not win spatial queries without geometry")
}

private func runCanvasEntityIndexAdapterTileRemovalCheck() {
    let before = CanvasEntityIndexSnapshotAdapter.buildIndex(from: adapterSnapshot(tiles: [
        adapterTile(adapterTileA, x: 0, y: 0),
        adapterTile(adapterTileB, x: 60, y: 0),
    ]))
    let snapshot = before.entity(id: .tile(adapterTileB), options: .addressable).chosenIDsSnapshot
    let after = CanvasEntityIndexSnapshotAdapter.buildIndex(from: adapterSnapshot(tiles: [
        adapterTile(adapterTileA, x: 0, y: 0),
    ]))

    guard case .unavailable(.tile(adapterTileB), let reason, _) = after.validate(snapshot: snapshot) else {
        expect(false, "P7 adapter tile removal: validating a removed tile should fail closed")
        return
    }
    expect(reason == "snapshot-target-not-registered", "P7 adapter tile removal: wrong validation failure reason \(reason)")
}

private func runCanvasEntityIndexAdapterIdentitySeparationCheck() {
    let index = CanvasEntityIndexSnapshotAdapter.buildIndex(from: adapterSnapshot(
        tiles: [
            adapterTile(adapterTileA, kind: .managedAgent, x: 0, y: 0, attachedAgentId: adapterAgent),
            adapterTile(adapterTileB, kind: .managedAgent, x: 40, y: 0, attachedAgentId: adapterAgent),
            adapterTile(adapterTileDuplicate, x: 80, y: 0),
            adapterTile(adapterTileDuplicate, kind: .fileTree, x: 120, y: 0),
        ],
        agents: [CanvasEntityIndexAgentSnapshot(id: adapterAgent, label: "agent", associatedTileIds: [adapterTileA, adapterTileB], projectId: adapterProject)]
    ))

    let ids = index.allEntities.map(\.id)
    expect(ids.contains(.agent(adapterAgent)), "P7 adapter identity separation: agent:A entity missing")
    expect(ids.contains(.tile(adapterTileA)) && ids.contains(.tile(adapterTileB)),
           "P7 adapter identity separation: tile:T entities missing")
    expect(index.allEntities.filter { $0.attachedAgentId == adapterAgent && $0.kind == .tile }.map(\.id).sorted() == [.tile(adapterTileA), .tile(adapterTileB)],
           "P7 adapter identity separation: associated tiles collapsed into agent identity")
    expect(index.duplicateEntityIDs == [.tile(adapterTileDuplicate)],
           "P7 adapter duplicate IDs should be rejected visibly by CanvasEntityIndex policy")
}

private func runCanvasEntityIndexAdapterNoPathLeakageCheck() {
    var pathLabelTile = adapterTile(
        adapterTileA,
        kind: .terminal,
        x: 0,
        y: 0,
        relativeWorkingDirectory: "/Users/qa/private/continuum")
    pathLabelTile.label = "Terminal /Users/qa/private/continuum"
    let index = CanvasEntityIndexSnapshotAdapter.buildIndex(from: adapterSnapshot(zones: [
        CanvasEntityIndexZoneSnapshot(id: adapterZone, label: "/Users/qa/private/zone")
    ], tiles: [
        pathLabelTile,
        adapterTile(adapterTileB, kind: .note, x: 50, y: 0, relativeWorkingDirectory: "/Users/qa/private/notes"),
        CanvasEntityIndexTileSnapshot(
            id: adapterTileDuplicate,
            kind: .browser,
            label: "file:///Users/qa/private/browser",
            worldFrame: CanvasWorldRect(x: 100, y: 0, width: 25, height: 15),
            projectId: adapterProject,
            relativeWorkingDirectory: "../secret",
            checkoutHandle: "/Users/qa/private/checkout"
        ),
    ], agents: [
        CanvasEntityIndexAgentSnapshot(
            id: adapterAgent,
            label: "Agent ~/private/worktree",
            projectId: adapterProject,
            relativeWorkingDirectory: "/Users/qa/private/agent-cwd",
            checkoutHandle: "/Users/qa/private/worktree"
        )
    ]))

    for entity in index.allEntities {
        switch entity.scopeRole {
        case .contextOnly:
            expect(entity.kind == .zone || entity.kind == .note || entity.kind == .browser,
                   "P7 adapter no path leakage: only zone/note/browser fixtures should be context-only here, got \(entity.kind)")
        case .emitsScope(_, let relativeWorkingDirectory, let checkoutHandle):
            expect(relativeWorkingDirectory == nil || relativeWorkingDirectory == "Sources",
                   "P7 adapter no path leakage: absolute/parent relative directory leaked: \(relativeWorkingDirectory ?? "nil")")
            expect(checkoutHandle == nil || checkoutHandle == "checkout-main",
                   "P7 adapter no path leakage: absolute checkout handle leaked: \(checkoutHandle ?? "nil")")
        }
        expect(entity.kind != .note || entity.scopeRole.emitsFilesystemAuthority == false,
               "P7 adapter no path leakage: notes must be context-only")
        expect(entity.kind != .browser || entity.scopeRole.emitsFilesystemAuthority == false,
               "P7 adapter no path leakage: browser must be context-only")
    }

    let dump = index.allEntities.map { entity in
        "\(entity.id.rawValue)|\(entity.label)|\(entity.evidence.joined(separator: ","))"
    }.joined(separator: "\n")
    for forbidden in ["/Users/qa/private", "agent-cwd", "worktree", "cwd", "file://", "~/private"] {
        expect(!dump.contains(forbidden), "P7 adapter no path leakage: output dump leaked \(forbidden)")
    }
    expect(index.allEntities.first(where: { $0.id == .zone(adapterZone) })?.label == "Zone",
           "P7 adapter no path leakage: absolute zone labels should fall back")
    expect(index.allEntities.first(where: { $0.id == .tile(adapterTileA) })?.label == "Tile",
           "P7 adapter no path leakage: embedded absolute tile labels should fall back")
    expect(index.allEntities.first(where: { $0.id == .agent(adapterAgent) })?.label == "Agent",
           "P7 adapter no path leakage: tilde agent labels should fall back")
}
