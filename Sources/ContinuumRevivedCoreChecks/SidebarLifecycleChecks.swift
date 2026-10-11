import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Foundation

/// Confidence pass, sidebar stream (`.plans/70`, S4): the pure derivations the
/// sidebar is drawn from. The app leg `--sidebar-truth-check` drives the same
/// facts through the real close paths and the rendered list; this arm pins each
/// rung on its own so a regression names the rung, not just the symptom.
func runSidebarLifecycleChecks() {
    let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func record(
        _ name: String, tile: UUID? = UUID(), parent: AgentID? = nil,
        closeRequestedAt: Date? = nil, archivedAt: Date? = nil
    ) -> AgentRecord {
        AgentRecord(
            id: AgentID(rawValue: UUID()), displayName: name, model: "openai-codex/gpt-5.6-sol",
            thinking: "medium", cwd: "/tmp/sidebar-lifecycle", parentAgentID: parent,
            createdAt: now.addingTimeInterval(-600), lastActivityAt: now.addingTimeInterval(-60),
            tileId: tile, archivedAt: archivedAt, closeRequestedAt: closeRequestedAt)
    }

    // 1 · closeRequestedAt is durable and optional: it round-trips exactly, and a
    // record written before it existed decodes it as absent.
    let closing = record("closing", closeRequestedAt: now.addingTimeInterval(-30))
    do {
        let data = try JSONEncoder().encode(closing)
        let decoded = try JSONDecoder().decode(AgentRecord.self, from: data)
        expect(decoded.closeRequestedAt == closing.closeRequestedAt,
               "closeRequestedAt must round-trip exactly — got \(String(describing: decoded.closeRequestedAt))")
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        expect(object["closeRequestedAtReferenceInterval"] != nil,
               "closeRequestedAt must be written under its reference-interval key")
        object.removeValue(forKey: "closeRequestedAtReferenceInterval")
        let legacy = try JSONDecoder().decode(
            AgentRecord.self, from: JSONSerialization.data(withJSONObject: object))
        expect(legacy.closeRequestedAt == nil, "a record from before the field decodes it as absent")
        object["closeRequestedAtReferenceInterval"] = "not a number"
        let malformed = try JSONDecoder().decode(
            AgentRecord.self, from: JSONSerialization.data(withJSONObject: object))
        expect(malformed.closeRequestedAt == nil && malformed.id == closing.id,
               "a malformed close stamp reads as absent rather than dropping the agent")
    } catch {
        expect(false, "closeRequestedAt codec threw: \(error)")
    }

    // 2 · The rung. Idle + close intent → History, dated by the intent. Busy +
    // close intent → still active, and Finishing.
    let idleFacts = AgentLifecycleFacts()
    let busyFacts = AgentLifecycleFacts(hasLiveRunner: true)
    expect(closing.lifecycle(facts: idleFacts, now: now) == .archived(at: closing.closeRequestedAt!),
           "an idle agent whose tile was closed is History — got \(closing.lifecycle(facts: idleFacts, now: now))")
    expect(closing.closingSince(facts: idleFacts, now: now) == nil,
           "an idle closed agent is not 'Finishing' — it has finished")
    expect(closing.lifecycle(facts: busyFacts, now: now) == .active,
           "a WORKING agent whose tile was closed stays live until its turn ends")
    expect(closing.closingSince(facts: busyFacts, now: now) == closing.closeRequestedAt,
           "…and reads Finishing, counted from the close")
    let pendingFacts = AgentLifecycleFacts(attentionIsYours: true)
    expect(closing.lifecycle(facts: pendingFacts, now: now) == .active,
           "a closed agent holding a question for you is never buried in History")
    let childBlocked = AgentLifecycleFacts(descendantBlockers: .sessionRunning)
    expect(closing.closingSince(facts: childBlocked, now: now) != nil,
           "a closed parent whose subagent is still working is Finishing, not History")

    // 3 · R3: a binding nothing can find is a closed window — but only for a
    // record that HAS a tile, and the date is when it last did anything.
    let lost = record("lost")
    let unreachable = AgentLifecycleFacts(tileUnreachable: true)
    expect(lost.lifecycle(facts: unreachable, now: now) == .archived(at: lost.lastActivityAt),
           "a record naming a tile no document holds derives closed — got \(lost.lifecycle(facts: unreachable, now: now))")
    expect(lost.lifecycle(facts: AgentLifecycleFacts(hasLiveRunner: true, tileUnreachable: true), now: now) == .active,
           "…unless it is working, when it is Finishing")
    let headless = record("headless", tile: nil)
    expect(headless.lifecycle(facts: unreachable, now: now) == .active,
           "a headless agent has no tile to lose — never derived closed")

    // 4 · R2: children follow their topmost present ancestor — section, Finishing
    // and workspace — and a child with no parent in the list keeps its own.
    let parentId = UUID(), childId = UUID(), grandchildId = UUID(), orphanId = UUID()
    func row(_ id: UUID, parent: UUID?, lifecycle: InboxLifecycle,
             closingSince: Date? = nil, workspace: String?) -> AgentInboxRow {
        AgentInboxRow(
            id: id, title: "row", workspaceName: workspace, state: .ready,
            lifecycle: lifecycle, createdAt: now, parentId: parent, closingSince: closingSince)
    }
    let closedAt = now.addingTimeInterval(-10)
    let placed = AgentInboxRowBuilder.placingChildrenWithParents([
        row(parentId, parent: nil, lifecycle: .archived(at: closedAt), workspace: "Alpha"),
        row(childId, parent: parentId, lifecycle: .active, workspace: nil),
        row(grandchildId, parent: childId, lifecycle: .settled(at: now), workspace: "Beta"),
        row(orphanId, parent: UUID(), lifecycle: .active, workspace: nil),
    ])
    let byId = Dictionary(uniqueKeysWithValues: placed.map { ($0.id, $0) })
    expect(byId[childId]?.lifecycle == .archived(at: closedAt) && byId[childId]?.workspaceName == "Alpha",
           "a closed parent's child goes to History with it, in its workspace — got \(String(describing: byId[childId]))")
    expect(byId[grandchildId]?.lifecycle == .archived(at: closedAt),
           "a grandchild follows the ROOT, not just its parent")
    expect(byId[orphanId]?.lifecycle == .active,
           "a child whose parent is absent keeps its own lifecycle — nothing to follow, nothing lost")
    let finishingPlaced = AgentInboxRowBuilder.placingChildrenWithParents([
        row(parentId, parent: nil, lifecycle: .active, closingSince: closedAt, workspace: "Alpha"),
        row(childId, parent: parentId, lifecycle: .active, workspace: "Alpha"),
    ])
    expect(finishingPlaced.last?.closingSince == closedAt && finishingPlaced.last?.variant == .slim,
           "a Finishing parent's child draws slim with it")
    expect(row(parentId, parent: nil, lifecycle: .active, closingSince: closedAt, workspace: nil)
            .presentationLabel == AgentStatusVocabulary.finishing,
           "a Finishing row says Finishing")

    print("SidebarLifecycle: closeRequestedAt round-trips and decodes absent; idle close → History, busy close → Finishing; "
          + "an unreachable binding derives closed (never a headless one); children follow their root's section, Finishing and workspace")
}

/// R4: one unreadable project root must not fail every project's listing.
func runManagedSessionRootIsolationChecks() {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("root-isolation-\(UUID().uuidString)", isDirectory: true)
    let goodRoot = base.appendingPathComponent("good", isDirectory: true)
    let badRoot = base.appendingPathComponent("bad", isDirectory: true)
    let badDir = ProjectStoreLayout(projectRoot: badRoot).managedSessionsDirectory
    defer {
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: badDir.path)
        try? fm.removeItem(at: base)
    }
    let goodTile = UUID(), badTile = UUID()
    do {
        try fm.createDirectory(at: goodRoot, withIntermediateDirectories: true)
        try fm.createDirectory(at: badRoot, withIntermediateDirectories: true)
        try ManagedAgentSessionStore(projectRoot: goodRoot).upsert(ManagedAgentSessionRecord(
            tileId: goodTile, agentKind: .claude, status: .stopped, lastSeenAt: Date()))
        try ManagedAgentSessionStore(projectRoot: badRoot).upsert(ManagedAgentSessionRecord(
            tileId: badTile, agentKind: .claude, status: .stopped, lastSeenAt: Date()))
    } catch {
        expect(false, "root isolation fixture: \(error)")
    }
    let roots = [
        ReconciledManagedSessionSource.Root(projectId: UUID(), projectRoot: goodRoot),
        ReconciledManagedSessionSource.Root(projectId: UUID(), projectRoot: badRoot),
    ]
    let source = ReconciledManagedSessionSource(ttl: 0)
    do {
        try source.reconcile(roots: roots, reason: .continuumRestarted, now: Date())
        let first = try source.records(roots: roots, now: Date())
        expect(Set(first.map(\.record.tileId)) == [goodTile, badTile], "control: both roots list while readable")
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: badDir.path)
        source.invalidateCache()
        let second = try source.records(roots: roots, now: Date().addingTimeInterval(1))
        expect(Set(second.map(\.record.tileId)) == [goodTile, badTile],
               "an unreadable root keeps its LAST GOOD listing and the readable root still lists — got \(second.map(\.record.tileId))")
        expect(source.unreadableRoots == [roots[1]],
               "the unreadable root is named — got \(source.unreadableRoots)")
    } catch {
        expect(false, "one unreadable project root failed the whole managed-session listing: \(error)")
    }
    print("ManagedSessionRootIsolation: an unreadable root keeps its last good listing, is named, and every other root still lists")
}

/// Step 3 (A-history #4): the sidebar tree places a project's tiles by zone
/// MEMBERSHIP — the rule the canvas mounts layers with — never by centre geometry.
func runSidebarTreeMembershipChecks() {
    let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let workspaceId = UUID(), projectId = UUID()
    let zoneOne = UUID(), zoneTwo = UUID()
    func zone(_ id: UUID, x: Double) -> ZonePlacement {
        ZonePlacement(
            zoneId: id, projectId: projectId, origin: ZonePoint(x: x, y: 0),
            size: ZoneSize(width: 100, height: 100), color: "blue", collapsed: false,
            hydrationPolicy: .automatic)
    }
    var registry = Registry.empty()
    registry.workspaces = [WorkspaceEntry(id: workspaceId, name: "W", projectIds: [projectId], createdAt: now, updatedAt: now)]
    registry.projects = [ProjectEntry(id: projectId, name: "P", rootPath: "/tmp/membership", workspaceId: workspaceId,
                                      lastOpenedAt: now, pinned: false, missing: false)]
    let document = WorkspaceDocument(
        viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
        zones: [zone(zoneOne, x: 0), zone(zoneTwo, x: 200)],
        zoneZOrder: [zoneOne, zoneTwo], lastActiveZoneId: zoneTwo)
    func tile(_ id: UUID, x: Double, stamp: UUID?) -> Tile {
        var tile = Tile(
            id: id, kind: .note, title: "t", frame: TileFrame(x: x, y: 10, width: 40, height: 40),
            zPosition: .fromLegacyRank(1), runtimeRef: nil, metadata: TileMetadata())
        tile.zoneId = stamp
        return tile
    }
    // Stamped to zone TWO, lying over zone ONE: membership says two.
    let stampedTile = UUID()
    // No stamp, inside no zone: the canvas rescues it into the HOME zone (two).
    let strayTile = UUID()
    // No stamp, inside zone one: rescued by geometry into one.
    let looseTile = UUID()
    let canvas = CanvasState(
        viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
        tiles: [tile(stampedTile, x: 10, stamp: zoneTwo), tile(strayTile, x: 900, stamp: nil),
                tile(looseTile, x: 30, stamp: nil)],
        groups: [], lastActiveTileId: nil)
    let tree = SidebarTreeBuilder.build(
        registry: registry, documents: [workspaceId: document], projectCanvases: [projectId: canvas])
    let zones = tree.workspaces.first?.zones ?? []
    func ids(_ zoneId: UUID) -> Set<UUID> {
        Set(zones.first { $0.zoneId == zoneId }?.tiles.map(\.tileId) ?? [])
    }
    expect(ids(zoneTwo).contains(stampedTile) && !ids(zoneOne).contains(stampedTile),
           "a tile STAMPED to a zone is listed in that zone, wherever its centre lies — zone one \(ids(zoneOne)), zone two \(ids(zoneTwo))")
    expect(ids(zoneTwo).contains(strayTile),
           "a tile inside no zone is listed where the canvas draws it (the home zone), not nowhere")
    expect(ids(zoneOne) == [looseTile],
           "an unstamped tile inside zone one is listed there and only there — got \(ids(zoneOne))")
    print("SidebarTreeMembership: stamped, stray and loose tiles listed by membership, exactly where the canvas mounts them")
}
